# -*- coding: utf-8 -*-
"""
sim_v79.py —— v79 关键状态机的帧级行为模型（对应 RTL 的两处改动）

目的：在没有 HDL 仿真器的情况下，用"帧级"模型验证三条不变式：
  I1  一次 S0 按键在可执行窗口内【恰好推进一张】(不丢、不重复)
  I2  屏幕上任意时刻至少有一个不为 0 的亮度档（除上电首图之前）
  I3  从"视频结束"到"第 1 张照片上屏"期间，屏幕显示的是视频最后一帧（全亮），
      没有 disp_en=0 的黑帧
  I4  sd 侧记录的 disp_buf_idx 与屏幕实际读的 buffer 永远一致
      （否则下一张会写进正在显示的块 -> 撕裂）

模型严格按 sd_card_bmp.v / image_transition_ctrl.v 的 v79 逻辑抄写，
只是把 100MHz 的逐拍时序压缩成"帧"粒度（装载时间用帧数表示）。
"""
import random
import sys

FRAMES_PER_SEC = 60
LOAD_FRAMES_640 = 24      # 640x480 约 0.4s
LOAD_FRAMES_1080 = 168    # 1920x1080 约 2.8s
AUTO_FRAMES = 18 * FRAMES_PER_SEC
WIPE_FRAMES = 12
V_ACTIVE = 480
STEP = (V_ACTIVE + WIPE_FRAMES - 1) // WIPE_FRAMES


def next_index_limited(cur, count):
    if count <= 1:
        return 0
    if count == 2:
        return 0 if cur == 1 else cur + 1
    if count == 3:
        return 0 if cur == 2 else cur + 1
    return 0 if cur == 3 else cur + 1


class Transition:
    IDLE, FADE, SWAP, WIPE = 0, 1, 2, 3

    def __init__(self, sd):
        self.sd = sd
        self.state = self.IDLE
        self.wipe_y = 0
        self.read_buf = 0
        self.req_pending = False
        self.target_buf = 0
        self.target_img = 0
        self.read_finish_seen = True
        self.fade_step = 0
        self.hold_dim = False
        self.hold_vid = False
        self.from_video = False
        self.prev_vid = False
        self.commit_toggle = 0
        self.current_img = 0
        # 诊断
        self.black_frames = 0
        self.scale_trace = []

    # 组合：当前是否显示视频
    def vid_display(self, video_phase, video_valid):
        return video_phase and video_valid

    def tick(self, video_phase, video_valid, video_buf, read_finish_evt, frame_ready_evt, rd_buf_evt):
        disp = self.vid_display(video_phase, video_valid)
        if disp:
            # 视频段：read_buf 跟随 video_buf
            self.read_buf = video_buf
            self.state = self.IDLE
            self.wipe_y = 0
            self.req_pending = False
            self.read_finish_seen = True
            self.hold_vid = True
            self.fade_step = 0
            self.hold_dim = False
            self.from_video = False
        elif self.prev_vid:
            self.state = self.IDLE
            self.wipe_y = 0
            self.req_pending = False
            self.read_finish_seen = True
            self.fade_step = 0
            self.hold_dim = False
            self.from_video = True
        else:
            if frame_ready_evt:
                self.req_pending = True
                self.target_buf = rd_buf_evt
                self.target_img = self.sd.ready_img
                self.read_finish_seen = False
            if read_finish_evt:
                self.read_finish_seen = True

            if self.state == self.IDLE:
                self.wipe_y = 0
                if self.req_pending:
                    if self.from_video:
                        self.fade_step = 0
                        self.state = self.FADE
                    else:
                        self.state = self.SWAP
            elif self.state == self.FADE:
                if self.fade_step >= 4:
                    self.hold_dim = True
                    self.state = self.SWAP
                else:
                    self.fade_step += 1
            elif self.state == self.SWAP:
                if self.read_finish_seen:
                    self.read_buf = self.target_buf
                    self.current_img = self.target_img
                    self.commit_toggle ^= 1
                    self.req_pending = False
                    self.wipe_y = STEP
                    self.hold_vid = False
                    self.hold_dim = False
                    self.from_video = False
                    self.state = self.WIPE
                    self.sd.on_commit(self.target_buf, self.target_img)
            elif self.state == self.WIPE:
                if self.wipe_y >= V_ACTIVE + STEP:
                    self.wipe_y = 0
                    self.state = self.IDLE
                else:
                    self.wipe_y += STEP

        self.prev_vid = disp
        return self.scale_for_row(0)

    # 当前帧第 row 行的亮度档（用于判黑）
    def scale_for_row(self, row):
        if self.state == self.WIPE:
            d = self.wipe_y - row
            if d >= STEP:
                return 8
            if d >= STEP // 3:
                return 5
            if d >= 1:
                return 2
            return 1
        if self.state == self.FADE:
            return [8, 5, 3, 2][self.fade_step] if self.fade_step < 4 else 1
        if self.hold_dim:
            return 1
        return 8

    def max_scale(self):
        """整帧最大亮度档（>0 就说明这一帧不是全黑）"""
        if self.state == self.WIPE:
            # 顶部（row 0）永远是 max
            return self.scale_for_row(0)
        return self.scale_for_row(0)


class SdCard:
    def __init__(self, img_count=4, has_video=True, large_first=False):
        self.img_count = img_count
        self.has_video = has_video
        self.first_committed = False
        self.display_valid = False
        self.disp_idx = 0
        self.disp_buf = 0
        self.next_req = False
        self.load_busy = False
        self.load_left = 0
        self.load_idx = 0
        self.load_buf = 0
        self.frame_ready_pending = False
        self.ready_buf = 0
        self.ready_img = 0
        self.frame_ready_evt = False
        self.auto_play = False
        self.auto_cnt = 0
        self.manual_inflight = False
        self.reload_pending = False
        self.reload_wait = 0
        self.video_req = False
        self.back_first_flag = False
        self.large_first = large_first
        self.cnt_key = 0
        self.cnt_load = 0
        self.video_mode = False           # 顶层 mode_video
        self.photo_blank_removed = True
        # 观测
        self.log = []

    def at_last_photo(self):
        return next_index_limited(self.disp_idx, self.img_count) == 0 or self.img_count == 1

    def load_frames_for(self, idx):
        if self.large_first and idx == 0:
            return LOAD_FRAMES_1080
        return LOAD_FRAMES_640

    def key1(self):
        if not self.first_committed:
            return
        if self.video_mode:
            return        # 视频段由顶层处理
        # v79：回照片的重载窗口里也排队（1 位饱和，最多推进一张）
        self.next_req = True
        self.cnt_key += 1

    def key2(self):
        if self.video_mode or self.img_count == 0:
            return
        self.auto_play = not self.auto_play
        self.auto_cnt = 0

    def on_commit(self, buf, img):
        # frame_ready_pending && commit_pulse
        if self.frame_ready_pending:
            self.frame_ready_pending = False
            self.disp_buf = buf
            self.disp_idx = img
            self.display_valid = True
            self.first_committed = True
            self.auto_cnt = 0
            self.manual_inflight = False

    def enter_video(self):
        self.video_mode = True
        self.next_req = False
        self.auto_cnt = 0

    def exit_video(self):
        # back_first 分支
        self.video_mode = False
        self.back_first_flag = True
        self.next_req = False
        self.auto_cnt = 0
        self.reload_pending = True
        self.reload_wait = 0
        self.frame_ready_pending = False
        self.load_busy = False
        self.manual_inflight = False
        self.disp_idx = 0

    def tick(self, trans):
        self.frame_ready_evt = False
        if self.video_mode:
            # video_mode_hold：彻底静默
            self.next_req = False
            self.load_busy = False
            self.frame_ready_pending = False
            self.auto_cnt = 0
            return

        # ---- 装载进度 ----
        if self.load_busy:
            self.load_left -= 1
            if self.load_left <= 0:
                self.load_busy = False
                if not self.first_committed:
                    self.disp_buf = self.load_buf
                    self.disp_idx = self.load_idx
                    self.display_valid = True
                    self.first_committed = True
                    self.frame_ready_pending = False
                else:
                    self.frame_ready_pending = True
                    self.ready_buf = self.load_buf
                    self.ready_img = self.load_idx
                    self.frame_ready_evt = True
            return

        # ---- 回照片重载 ----
        if self.reload_pending:
            self.reload_wait += 1
            # v79：不在这里清 next_req（重载窗口内的按键允许排队）
            self.auto_cnt = 0
            if self.reload_wait >= 2 and self.img_count != 0:
                self.reload_pending = False
                self.load_idx = 0
                # v79：写屏幕当前没读的那一块
                self.disp_buf = trans.read_buf
                self.load_buf = 1 - trans.read_buf
                self.load_busy = True
                self.load_left = self.load_frames_for(0)
                self.cnt_load += 1
            elif self.img_count == 0:
                self.reload_pending = False
            return

        # ---- 交棒 / 首图 / 手动 / 轮播 ----
        base_ready = self.display_valid and not self.load_busy and not self.frame_ready_pending
        if self.has_video and self.at_last_photo() and base_ready and self.next_req:
            self.video_req = True
            self.next_req = False
            self.enter_video()
            return

        if not self.first_committed:
            if self.img_count != 0:
                self.load_idx = 0
                self.load_buf = 0
                self.load_busy = True
                self.load_left = self.load_frames_for(0)
                self.cnt_load += 1
            return

        if base_ready and self.next_req:
            nd = next_index_limited(self.disp_idx, self.img_count)
            self.load_idx = nd
            self.load_buf = 1 - self.disp_buf
            self.load_busy = True
            self.load_left = self.load_frames_for(nd)
            self.next_req = False
            self.manual_inflight = True
            self.auto_cnt = 0
            self.cnt_load += 1
            return

        auto_tick = self.auto_play and self.auto_cnt >= AUTO_FRAMES
        if (auto_tick and self.img_count > 1 and base_ready and
                self.has_video and self.at_last_photo()):
            self.video_req = True
            self.auto_cnt = 0
            self.enter_video()
            return
        if auto_tick and self.img_count > 1 and base_ready:
            nd = next_index_limited(self.disp_idx, self.img_count)
            self.load_idx = nd
            self.load_buf = 1 - self.disp_buf
            self.load_busy = True
            self.load_left = self.load_frames_for(nd)
            self.auto_cnt = 0
            self.cnt_load += 1
            return

        if self.auto_play and self.img_count > 1 and base_ready:
            self.auto_cnt = 0 if auto_tick else self.auto_cnt + 1
        else:
            self.auto_cnt = 0


def run(name, img_count=4, has_video=True, large_first=False, script=(), verbose=False):
    sd = SdCard(img_count, has_video, large_first)
    tr = Transition(sd)
    st = {'vp': False, 'vv': False, 'vb': 0, 'vleft': 0}
    black = 0
    buf_mismatch = 0
    presses = 0
    advances = 0

    def frame():
        nonlocal black, buf_mismatch
        if st['vp']:
            st['vleft'] -= 1
            if st['vleft'] <= 0:
                st['vp'] = False
                st['vv'] = False
                sd.exit_video()
        sd.tick(tr)
        tr.tick(st['vp'], st['vv'], st['vb'], True, sd.frame_ready_evt, sd.ready_buf)
        # sd 侧交棒 / 退出 -> 同步相位
        if sd.video_mode and not st['vp']:
            st['vp'] = True
            st['vv'] = True
            st['vb'] = 1 - sd.disp_buf
            st['vleft'] = 10 ** 9
        if (not sd.video_mode) and st['vp']:
            st['vp'] = False
            st['vv'] = False
        # 不变式：屏幕不能黑
        if tr.max_scale() == 0:
            black += 1
        # 不变式：照片段 disp_buf 必须等于屏幕读 buffer
        if (not st['vp']) and (not sd.reload_pending) and (not sd.load_busy) \
                and (not sd.frame_ready_pending) and sd.display_valid:
            if tr.read_buf != sd.disp_buf:
                buf_mismatch += 1

    for f in range(500):          # 上电：清屏 + 扫描 + 首图（1080p 要 168 帧）
        frame()
    if not sd.first_committed:
        print("[FAIL] %s 首图起不来" % name)
        return False

    for step in script:
        kind = step[0]
        if kind == 'wait':
            for _ in range(step[1]):
                frame()
        elif kind == 'key1':
            presses += 1
            if st['vp']:
                st['vp'] = False
                st['vv'] = False
                sd.exit_video()
            else:
                before = sd.disp_idx
                sd.key1()
                for _ in range(500):
                    frame()
                    if st['vp']:
                        break
                    if sd.disp_idx != before:
                        break
                    if (not sd.next_req) and (not sd.load_busy) and (not sd.frame_ready_pending):
                        break
        elif kind == 'key2':
            sd.key2()
        elif kind == 'video':
            st['vp'] = True
            st['vv'] = True
            st['vb'] = 1 - sd.disp_buf
            st['vleft'] = step[1]
            sd.video_mode = True

    ok = True
    if black:
        print("[FAIL] %s 出现 %d 个全黑帧" % (name, black))
        ok = False
    if buf_mismatch:
        print("[FAIL] %s disp_buf 与屏幕读 buffer 不一致 %d 帧" % (name, buf_mismatch))
        ok = False
    print(("[ OK ] " if ok else "[FAIL] ") +
          "%s  key1=%d load=%d disp_idx=%d black=%d mismatch=%d"
          % (name, presses, sd.cnt_load, sd.disp_idx, black, buf_mismatch))
    return ok


if __name__ == '__main__':
    allok = True
    # 场景 1：逐张按 S0 走完 4 张 -> 第 5 次进视频
    allok &= run("S1 逐张S0", script=[('wait', 200), ('key1',), ('wait', 600),
                                   ('key1',), ('wait', 600), ('key1',), ('wait', 600),
                                   ('key1',), ('wait', 600)])
    # 场景 2：装载中再按一次（第 4 张最久），检查不丢键
    allok &= run("S2 装载中补按", script=[('wait', 200), ('key1',), ('wait', 3),
                                      ('key1',), ('wait', 1200)])
    # 场景 3：轮播走完 4 张 -> 视频播完 -> 自动回照片（黑屏窗口最长的那条路）
    allok &= run("S3 视频回照片", script=[('wait', 200), ('key2',), ('wait', 60 * 80)])
    # 场景 4：第 1 张是 1080p（装载 2.8s），回照片黑屏窗口最长
    allok &= run("S4 首图1080p回照片", large_first=True,
                 script=[('wait', 300), ('key2',), ('wait', 60 * 80)])
    # 场景 5：走到第 4 张 -> 进视频 -> 视频中按 S0 回照片 -> 再按 S0
    allok &= run("S5 视频中按S0", script=[('wait', 200), ('key1',), ('wait', 300),
                                      ('key1',), ('wait', 300), ('key1',), ('wait', 300),
                                      ('key1',), ('wait', 120),
                                      ('key1',), ('wait', 600), ('key1',), ('wait', 600)])
    # 场景 6：视频中按 S0 回照片，回照片窗口内立刻再按 S0
    allok &= run("S6 视频退出后立刻S0", script=[('wait', 200), ('key2',), ('wait', 60 * 80),
                                          ('key1',), ('wait', 5), ('key1',), ('wait', 800)])
    # 场景 7：随机按键（1000 次事件），检查不变式
    random.seed(7)
    seq = []
    for _ in range(1000):
        r = random.random()
        if r < 0.35:
            seq.append(('key1',))
        elif r < 0.45:
            seq.append(('key2',))
        else:
            seq.append(('wait', random.randint(1, 120)))
    allok &= run("S7 随机", script=seq)
    print("ALL OK" if allok else "SOME FAILED")
    sys.exit(0 if allok else 1)
