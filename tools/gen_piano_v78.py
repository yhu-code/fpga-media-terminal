# -*- coding: utf-8 -*-
"""gen_piano_v78.py —— 三声部钢琴合成器（FPGA RTL）+ 比特级模拟

输入：tools/sheet_v69.json（v69.1 谱子版三声部：旋律 113 / 中声部 470 / 低音 376 事件，
      三表总长严格相等 = 30080 个 5ms 单位 = 150.40 秒，可无缝循环）

输出：
  1) top_tf_hdmi_audio.v 中的 melody_player 模块被替换为 piano_player
  2) tools/preview_rtl_v78.wav —— 按 RTL 规则逐样本模拟（48kHz），就是上板听到的声音
"""
import io
import json
import sys
import os
import re
import wave

import numpy as np

ROOT = r'D:\lab_ex4_tffff111'
# v79：谱面可切换。PIANO_SHEET=canon 时读 sheet_canon.json（卡农三声部手写，
#   不再走和声引擎 —— 卡农的低音进行是固定的，交给 DP 会配成"好听但不像卡农"）。
_WHICH = os.environ.get('PIANO_SHEET', 'v69').strip().lower()
if _WHICH == 'canon':
    JSON_IN = os.path.join(ROOT, 'tools', 'sheet_canon.json')
else:
    JSON_IN = os.path.join(ROOT, 'tools', 'sheet_v69.json')
TOP = os.path.join(ROOT, 'src', 'user_source', 'hdl_source', 'top_tf_hdmi_audio.v')
WAV_OUT = os.path.join(ROOT, 'tools',
                       'preview_rtl_canon.wav' if _WHICH == 'canon' else 'preview_rtl_v78.wav')

SR = 48000
UNIT_MS = 5.0
UNIT_SAMPLES = 240
MIDI_MIN, MIDI_MAX = 36, 90
N_INC = 55                      # MIDI 36..90 共 55 项（6 位索引够用）

SCALE = 1.0
YOUNG_SH = 1      # 起音瞬间（音高 < MIDI72）的亮表移位（=1/2，亮）
OLD_SH   = 3      # 稳定段 / 高音的亮表移位（=1/8，暗）
BRT_AMP  = 1200.0
N_BASE = 4
N_BRT  = 11
A_BASE = 1.50
A_BRT  = 1.05
GAIN = {'melody': 0.80, 'middle': 0.26, 'bass': 0.30}


def pitch_gain(m):
    """音高越高，力度越收（0.72~1.0）。这是"高音不刺"的一半原因。"""
    if m is None:
        return 1.0
    if m >= 78:
        return 1.0
    return 1.0


def vel_of(name, idx, u, bar=0, u_pitch=None):
    """v78：力度（让演奏有起伏，而不是每一颗音一样重）。

    按小节给重音：一小节 2.4s 分成 4 个 0.6s 的拍，第 1 拍重、其余收。
    再叠一层 6 个一组的微小力度起伏 —— 每个音一模一样会有机械感。
    RTL 侧就是两个小计数器 + 一个 6 项小 ROM，十几 LUT。
    """
    if name == 'bass':
        v = 1.10 if (idx % 2) == 0 else 0.90        # 每小节第 1 拍抬 10%
    elif name == 'middle':
        v = (1.00, 0.90, 0.96, 0.92)[idx % 4]      # 上行琶音的层次
    else:
        v = 0.95
    # v78：高音要"轻"。真钢琴越往高音区，演奏者给的力度越小；
    #   我们的合成器却给每个音一样的电平，于是 C5 以上特别扎耳
    #   （实测 C5 以上 2~8kHz 能量是低音区的 11 倍，音量还一样大）。
    v *= pitch_gain(u_pitch)
    # 乐句力度：4 小节一呼一吸（起、推、顶、收），太平均就听不出"演奏"
    v *= (0.94, 0.98, 1.02, 0.96)[bar % 4]
    return v * (1.0 + (0.025, -0.030, 0.010, -0.015, 0.030, -0.020)[idx % 6])
# v78【修 bug】ENV0 必须由 GAIN 导出。之前两处各写一份常量，
#   ENV0 是固定死的 {52428, 22937, 32768}（= 0.80/0.35/0.50），
#   所以历次"把低音调小"（GAIN 改到 0.22~0.30）在音频里【完全没生效】，
#   低音一直按 0.50 满电平在响 —— 这是它显得突兀的一半原因。
ENV0 = {k: int(round(v * 65536)) for k, v in GAIN.items()}
SHIFT = {'melody': 11, 'middle': 10, 'bass': 9}
BRT0 = {'melody': 1, 'middle': 2, 'bass': 3}

d = json.load(io.open(JSON_IN, encoding='utf-8'))
TABLES = {k: [(int(m), int(u)) for m, u in d[k]] for k in ('melody', 'middle', 'bass')}
TOTAL0 = sum(u for _, u in TABLES['melody'])
# v79：locked=True 的谱面表示"三声部已经手写好了"，直接用，不再让和声引擎重排。
LOCKED = bool(d.get('locked', False))
BAR_U_CFG = int(d.get('bar_units', 480))

# ================================================================ v78 和声引擎
#  诊断：v78 听着"平、不够和谐"，根子不在音色，而在【全曲大部分小节停在
#        F# 大三和弦】，低音也是固定模板 —— 没有和声进行，音色再好也是原地踏步。
#  做法（三条配器常识）：
#    1) 以小节(2.4s)为单位，用动态规划替旋律配和声（F# 大调 6 个级和弦）；
#       评分 = 旋律契合度 − 冲突罚分 + 和声进行奖分 + 句尾终止式；
#    2) 低音 = 该小节和弦的根音/五度（40..51，0.6s 一换）→ 有和声脉搏；
#    3) 中声部 = 该和弦的和弦音上行琶音，且【严格压在旋律下方】——
#       v78 的中声部顶到 C#5，经常跑到旋律上面去，两声部纠缠 = 听着糊。
BAR_U = 480                      # 2.4s 一小节
PHRASE = 4                       # 4 小节一乐句，句尾落 I 或 V

# F# 大调：I ii iii IV V vi（不用 vii° 减三和弦，太冲）
DEGS = [('I', 6, 'maj'), ('ii', 8, 'min'), ('iii', 10, 'min'),
        ('IV', 11, 'maj'), ('V', 1, 'maj'), ('vi', 3, 'min')]


def chord_pcs(root, qual):
    third = 4 if qual == 'maj' else 3
    return [root % 12, (root + third) % 12, (root + 7) % 12]


def fold_register(seq, lo, hi):
    out = []
    for m, u in seq:
        while m > hi:
            m -= 12
        while m < lo:
            m += 12
        out.append((m, u))
    return out


# 旋律先归到 C#4..G5：保留曲谱音级，又不让低音区发闷
TABLES['melody'] = fold_register(TABLES['melody'], 61, 79)


def windowed(tab, start, length):
    """该窗口内的 (音高, 持续单位)"""
    out = []
    pos = 0
    for m, u in tab:
        a, b = max(pos, start), min(pos + u, start + length)
        if b > a:
            out.append((m, b - a))
        pos += u
    return out


def harmonize(mel, total):
    """动态规划：为每一小节选和弦，旋律最贴合 + 和声进行自然。"""
    nbars = (total + BAR_U - 1) // BAR_U
    emis = []
    for bi in range(nbars):
        seg = windowed(mel, bi * BAR_U, min(BAR_U, total - bi * BAR_U))
        cc = np.zeros(12)
        for m, u in seg:
            cc[m % 12] += u
        tot = cc.sum() + 1e-9
        main = int(np.argmax(cc))
        e = np.zeros(len(DEGS))
        for i, (nm_, r, q) in enumerate(DEGS):
            t = chord_pcs(r, q)
            e[i] = sum(cc[x] for x in t) / tot
            if cc[main] / tot > 0.5 and main not in t:
                e[i] -= 0.35                      # 主音不在和弦内 = 打架
            for x in range(12):
                # 半音冲突（小二度）是最刺耳的：只要旋律里出现一点，就重罚。
                #   典型例子：旋律停在 F#（主音）上时配 V 和弦，和弦的三音 E#
                #   正好在它下面一个半音 —— 听着像"错音"，必须换和弦。
                if cc[x] / tot > 0.10 and x not in t and \
                        any((x - y) % 12 in (1, 11) for y in t):
                    e[i] -= 0.28
        # v78：长高音（>=C5 且 >=0.6s）必须是和弦音。
        #   它们是旋律的"高光"，如果和弦里没有这个音，就会跟伴奏撞出
        #   大七度/小九度，听着"突兀且不和谐"（实测 35.2s 的 F#5 配 G#m、
        #   147.2s 的 F5 配 B 大三和弦就是这种）。这里重罚，逼 DP 换和弦。
        strong_hi = set(mm % 12 for mm, uu in seg if mm >= 72 and uu >= 120)
        for i, (nm_, r, q) in enumerate(DEGS):
            t = chord_pcs(r, q)
            for pc in strong_hi:
                if pc in t:
                    continue
                # 只罚真正"撞"的音：小二度/大二度/三全音。
                #   七度、九度、六度是色彩音（比如 F# 配 G#m = G#m7），留着更好听。
                if any(min((pc - y) % 12, (y - pc) % 12) in (1, 2, 6) for y in t):
                    e[i] -= 0.40
        emis.append(e)

    def trans(a, b):
        d = (DEGS[b][1] - DEGS[a][1]) % 12
        if d == 0:
            return -0.05                          # 原地重复略罚
        if d in (5, 7):
            return 0.12                           # 四/五度：最自然
        if d in (2, 10):
            return 0.05                           # 级进
        if d in (3, 9):
            return 0.03                           # 三度
        if d in (4, 8):
            return 0.02
        if d == 6:
            return -0.18                          # 三全音
        return -0.06

    bonus = np.zeros((nbars, len(DEGS)))
    for bi in range(nbars):
        if bi % PHRASE == PHRASE - 1:             # 句尾落 I 或 V
            bonus[bi][0] += 0.06
            bonus[bi][4] += 0.05
    bonus[-1][0] += 0.5                           # 结尾=循环起点，必须落 I
    bonus[0][0] += 0.3

    NEG = -1e9
    dp = np.full((nbars, len(DEGS)), NEG)
    bk = np.zeros((nbars, len(DEGS)), dtype=int)
    dp[0] = emis[0] + bonus[0]
    for bi in range(1, nbars):
        for j in range(len(DEGS)):
            best, arg = NEG, 0
            for i in range(len(DEGS)):
                v = dp[bi - 1][i] + trans(i, j)
                if v > best:
                    best, arg = v, i
            dp[bi][j] = best + emis[bi][j] + bonus[bi][j]
            bk[bi][j] = arg
    j = int(np.argmax(dp[-1]))
    path = [j]
    for bi in range(nbars - 1, 0, -1):
        j = bk[bi][j]
        path.append(j)
    return path[::-1]


def build_voices(mel, total):
    path = harmonize(mel, total)
    bass, mid = [], []
    acc = 0
    for bi, di in enumerate(path):
        nm_, r, q = DEGS[di]
        seg = min(BAR_U, total - acc)

        # ---- 低音：根音 / 五度，0.6s 一换。
        #   根音锁在 D2..C#3(38..49)：再高就跟中声部撞了；
        #   五度超过 F#3(54) 就原地重复（宁可不动，也不要爬上去抢中声部的位置）。
        b = r
        while b < 38:
            b += 12
        while b > 49:
            b -= 12
        fifth = b + 7 if b + 7 <= 54 else b
        # 一小节两拍：根音(1.2s) + 五度(1.2s)。比 0.6s 一换安静得多，
        #   0.6s 的根-五交替会变成"蹦蹦"的泵动感（上一版被嫌古怪就是这个）。
        for k in range(2):
            u = seg // 2 + (seg - (seg // 2) * 2 if k == 1 else 0)
            bass.append((b if k == 0 else fifth, u))

        # ---- 中声部：和弦音取【紧贴旋律下方的三个】（F3..E4），上行。
        #   音区固定在 F3..E4(53..64)：伴奏手位稳定，声音才"抱得住"；
        #   同时离旋律 ≥3 个半音（2 度会打架）。
        segm = windowed(mel, bi * BAR_U, seg)
        mel_low = min(m for m, u in segm) if segm else 66
        hi = min(64, max(60, mel_low - 3))
        cand = [m for m in range(53, hi + 1) if m % 12 in chord_pcs(r, q)]
        # 避开与旋律"半音相邻"的和弦音：例如旋律有 E#(F) 时，不能同时响 F#，
        #   那是小二度，一听就"错音"。这是最影响"和谐"的一个细节。
        mel_pc = {}
        for mm, uu in segm:
            mel_pc[mm % 12] = mel_pc.get(mm % 12, 0) + uu
        tots = sum(mel_pc.values()) + 1e-9
        crisp = [x for x in mel_pc if mel_pc[x] / tots > 0.15]
        safe = [m for m in cand
                if not any(min((m - x) % 12, (x - m) % 12) == 1 for x in crisp)]
        if len(safe) >= 3:
            cand = safe
        if len(cand) < 3:                          # 空间不够：往下借一个八度
            cand = [m for m in range(hi - 12, hi + 1)
                    if m % 12 in chord_pcs(r, q)]
        notes = sorted(cand)[-3:]                  # 靠上取三个 = 密集排列
        if bi % PHRASE == PHRASE - 1:
            # 乐句末小节：收成 3 个慢音（0.8s 一个），像一口气放下来
            for k in range(3):
                u = seg // 3 + (seg - (seg // 3) * 3 if k == 2 else 0)
                mid.append((notes[k], u))
        else:
            pick = [notes[0], notes[1], notes[2], notes[1]]
            for k in range(4):
                u = seg // 4 + (seg - (seg // 4) * 4 if k == 3 else 0)
                mid.append((pick[k], u))
        acc += seg
    return bass, mid, path


if LOCKED:
    print('谱面 locked：直接使用手写三声部（%s）' % d.get('note', ''))
    for _k in ('melody', 'middle', 'bass'):
        _ms = sorted(set(m for m, u in TABLES[_k]))
        print('  %-7s %d 事件 %d..%d' % (_k, len(TABLES[_k]), _ms[0], _ms[-1]))
else:
    TABLES['bass'], TABLES['middle'], _path = build_voices(TABLES['melody'], TOTAL0)
    import collections as _c
    _pick = [DEGS[d][0] for d in _path]
    print('和声进行：%d 小节 %s' % (len(_path), dict(_c.Counter(_pick))))
    print('前 12 小节：%s' % ' '.join(_pick[:12]))
    _bp = sorted(set(m for m, u in TABLES['bass']))
    _mp = sorted(set(m for m, u in TABLES['middle']))
    print('低音 %d 事件 %d..%d   中声部 %d 事件 %d..%d'
          % (len(TABLES['bass']), _bp[0], _bp[-1],
         len(TABLES['middle']), _mp[0], _mp[-1]))

TOTAL = sum(u for _, u in TABLES['melody'])
assert TOTAL == TOTAL0, '旋律总长被改动过'
assert all(sum(u for _, u in TABLES[k]) == TOTAL for k in TABLES), '三表总长必须相等'
LOOP_UNITS = TOTAL

# ---------------------------------------------------------------- 波形表
def make_wave(base=True, n=256):
    """曲谱版 piano_note 在 MIDI 60 附近的频谱：ak = 1/k^alpha，零相位。

    零相位有两个好处：
      1) 表首样本严格等于 0 —— 起音时把相位清零，波形从 0 爬升，
         天然是一段"琴槌"渐入，不会有跳变咔哒声；
      2) 各泛音在 t=0 同相叠加 = 真实的击弦瞬态（亮、有力度感）。
    base  = 琴体（低次泛音为主，1/k^1.28）
    bright= 击弦瞬态（2..12 次泛音，1/k^1.02）
    """
    acc = np.zeros(n)
    k = np.arange(n)
    if base:
        hs = [(h, 1.0 / h ** A_BASE) for h in range(1, N_BASE + 1)]
    else:
        # v78：亮表的能量往 2~5 次泛音靠（八度/十二度/十五度），
        #   起音听起来"往上拔"、透亮，而不是发糊
        emph = {2: 1.35, 3: 1.00, 4: 0.75, 5: 0.58, 6: 0.40,
                7: 0.26, 8: 0.17, 9: 0.11, 10: 0.07, 11: 0.04}
        hs = [(h, emph.get(h, 0.0) / h ** (A_BRT - 1.0))
              for h in range(2, N_BRT + 1)]
    for h, a in hs:
        acc += a * np.sin(2 * np.pi * h * k / n)
    return acc / np.abs(acc).max()


wv = np.concatenate([np.round(make_wave(True) * SCALE * 1750.0),
                     np.round(make_wave(False) * SCALE * BRT_AMP)]).astype(int)
wv = np.clip(wv, -2048, 2047)

incs = [int(round(440.0 * 2 ** ((m - 69) / 12.0) * (1 << 32) / SR))
        for m in range(MIDI_MIN, MIDI_MAX + 1)]
incs += [0] * (N_INC - len(incs))

# ---------------------------------------------------------------- 比特级模拟
def simulate(seconds=None):
    n_units = LOOP_UNITS if seconds is None else int(seconds * 1000 / UNIT_MS)
    total = n_units * UNIT_SAMPLES
    out = np.zeros(total)
    voices = []
    for name in ('melody', 'middle', 'bass'):
        m0 = TABLES[name][0][0]
        voices.append(dict(name=name, tab=TABLES[name], ptr=0, mi=m0 - MIDI_MIN,
                           left=TABLES[name][0][1] - 1,
                           env=float(ENV0[name]), k=BRT0[name], ph=0.0,
                           inc=440.0 * 2 ** ((m0 - 69) / 12.0) / SR))
    ecnt = 0
    for i in range(total):
        acc = 0
        for v in voices:
            idx = int(v['ph'] * 256) & 255
            # v78：三段亮度。之前只有"亮/暗"两段且亮的持续 0.4s，
            #   结果是又闷又糊（3k~8k 几乎为 0）。真实钢琴的清晰度来自
            #   【音头那一瞬】的高频，之后迅速收暗 —— 所以把亮度集中在起音：
            #     env >= 51200（约 25ms）：全亮   -> 音头有"叮"的颗粒
            #     env >= 32768（到约 0.47s）：1/4
            #     更暗之后：1/8
            _e = v['env']
            # v78：亮表衰减档位随音高递增。
            #   mi 是相对 MIDI_MIN(36) 的索引：36 = C5、39 = D#5、42 = F#5。
            #   高音的谐波本来就落在 1~8kHz，再叠 2~5 次泛音就会"嘶"，
            #   所以每高一个三度就多压一档（>>4 = 1/16）。
            if v['mi'] >= 42:                 # F#5 以上
                _sh = 4
            elif v['mi'] >= 39:               # D#5~F5
                _sh = 3
            elif v['mi'] >= 36:               # C5~D5
                _sh = 2
            else:
                _sh = 0 if _e >= 51200 else (1 if _e >= 32768 else 2)
            bri = wv[256 + idx] >> _sh
            ws = wv[idx] + bri
            p = (ws * int(v['env'])) >> 16
            acc += p
            v['ph'] += v['inc']
            if v['ph'] >= 1.0:
                v['ph'] -= 1.0
        s = acc * 12
        out[i] = max(-32768, min(32767, s))
        ecnt += 1
        if ecnt == 32:
            ecnt = 0
            for v, name in zip(voices, ('melody', 'middle', 'bass')):
                # v78：高音衰减更快。真钢琴的高音弦阻尼大、余音短；
                #   我们的高音原来和低音一样长（1.4s），高频能量拖着不放，
                #   听感就是"刺"。这里 >=C5 的音把衰减加快一档。
                if name == 'melody' and v.get('mi', 0) >= 44:
                    sh = max(2, SHIFT[name] - 1)
                else:
                    sh = 4 if v['left'] <= 8 else SHIFT[name]
                v['env'] = float(v['env'] - int(v['env']) // (1 << sh))
        if (i + 1) % UNIT_SAMPLES == 0:
            for v in voices:
                if v['left'] == 0:
                    v['ptr'] = (v['ptr'] + 1) % len(v['tab'])
                    m, u = v['tab'][v['ptr']]
                    v['left'] = max(0, u - 1)
                    v['env'] = float(ENV0[v['name']] * vel_of(v['name'], v['ptr'], u, i // (480 * UNIT_SAMPLES), m))
                    v['k'] = BRT0[v['name']]
                    v['inc'] = 440.0 * 2 ** ((m - 69) / 12.0) / SR
                    v['ph'] = 0.0            # v78：起音相位清零
                    v['mi'] = min(N_INC - 1, max(0, m - MIDI_MIN))
                else:
                    v['left'] -= 1
    return out


# ---------------------------------------------------------------- Verilog
def emit_module():
    L = []
    A = L.append
    A('// ============================================================')
    A('// piano_player —— 三声部钢琴合成器（v78）')
    A('// ------------------------------------------------------------')
    A('// 音符来自曲谱转录（v69.1）：旋律 %d / 中声部 %d / 低音 %d 个事件。'
      % (len(TABLES['melody']), len(TABLES['middle']), len(TABLES['bass'])))
    A('// 三张表总长严格相等 = %d 个 5ms 单位 = %.2f 秒 -> 循环时三轨永不错位。'
      % (LOOP_UNITS, LOOP_UNITS * UNIT_MS / 1000.0))
    A('// 音高：32 位相位累加 + 48 项增量表（MIDI 43..90），数学上不会走音。')
    A('// 音色：512x12 波形表（低 256=基波主体，高 256=高次谐波），亮度按 k=1..5 衰减。')
    A('// 包络：16 位指数衰减 + 音符尾部 40ms 快速释放（不出咔哒）。')
    A('// 面积：单个共用乘法器（3 声部时分复用）。')
    A('// ============================================================')
    A('module piano_player (')
    A('    input  wire clk,              // audio_mclk 12.288MHz')
    A('    input  wire rst,')
    A('    input  wire play,')
    A('    output reg  i2s_bclk,')
    A('    output reg  i2s_lrclk,')
    A('    output reg  i2s_data,')
    A('    output wire [8:0] dbg_note')
    A(');')
    A('')
    A("localparam [9:0] MEL_N = 10'd%d;" % len(TABLES['melody']))
    A("localparam [9:0] MID_N = 10'd%d;" % len(TABLES['middle']))
    A("localparam [9:0] BAS_N = 10'd%d;" % len(TABLES['bass']))
    A('')
    for name, key in (('mel', 'melody'), ('mid', 'middle'), ('bas', 'bass')):
        tab = TABLES[key]
        A('// %s：{midi-43[5:0], 单位数[9:0]}' % key)
        A('reg [15:0] %s_tab [0:%d];' % (name, len(tab) - 1))
        A('initial begin')
        for i, (m, u) in enumerate(tab):
            A("    %s_tab[%3d] = 16'h%04X;  // MIDI %d, %d 单位"
              % (name, i, (((m - MIDI_MIN) & 0x3F) << 10) | (u & 0x3FF), m, u))
        A('end')
        A('')
    A('// 波形表：0..255 基波主体，256..511 高次谐波')
    A('reg [11:0] wave_rom [0:511];')
    A('initial begin')
    for i in range(0, 512, 8):
        parts = ['wave_rom[%3d]=12\'h%03X;' % (j, int(wv[j]) & 0xFFF)
                 for j in range(i, min(i + 8, 512))]
        A('    ' + ' '.join(parts))
    A('end')
    A('')
    A('// 音高增量表：inc = round(f * 2^32 / 48000)')
    A('reg [31:0] inc_rom [0:%d];' % (N_INC - 1))
    A('initial begin')
    for i in range(0, N_INC, 4):
        parts = ['inc_rom[%2d]=32\'h%08X;' % (j, incs[j])
                 for j in range(i, min(i + 4, N_INC))]
        A('    ' + ' '.join(parts))
    A('end')
    A('')
    eng = ENGINE.replace('(wr >>> 1) : (wr >>> 2)',
                        '(wr >>> %d) : (wr >>> %d)' % (YOUNG_SH, OLD_SH))
    A(eng)
    return '\n'.join(L)


ENGINE = r'''
wire bclk_fall = i2s_bclk;
reg  [5:0] bit_cnt;
reg        lr;
wire slot_end = (bit_cnt == 6'd63);
wire smp_new  = bclk_fall && slot_end && lr;    // 离开右声道 = 出一个新样本

reg [5:0]  st;
reg [9:0]  a;                     // 走表地址
reg [8:0]  a2;                    // 波形表地址（bit8=1 取高次谐波段）
reg signed [11:0] wb, wr;
reg signed [12:0] ws0, ws1, ws2;
reg signed [12:0] ma;
reg signed [16:0] mb;
reg signed [31:0] acc;
reg [15:0] out16;
reg [15:0] sr_hold;

reg [31:0] ph0, ph1, ph2;
reg [31:0] inc0, inc1, inc2;
reg [15:0] env0, env1, env2;
reg [9:0]  ptr0, ptr1, ptr2;
reg [9:0]  left0, left1, left2;
reg [5:0]  ecnt;                  // 32 样本 = 包络节拍
reg [7:0]  cnt5;                  // 240 样本 = 5ms
reg        adv;

reg [15:0] rd0, rd1, rd2;
reg [5:0]  m0, m1, m2;
reg [9:0]  u0, u1, u2;
reg        nx0, nx1, nx2;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        i2s_bclk <= 1'b0; i2s_lrclk <= 1'b0; i2s_data <= 1'b0;
        bit_cnt <= 6'd0; lr <= 1'b0; sr_hold <= 16'd0;
        st <= 6'd0; out16 <= 16'd0; acc <= 32'sd0;
        ph0 <= 32'd0; ph1 <= 32'd0; ph2 <= 32'd0;
        inc0 <= 32'd0; inc1 <= 32'd0; inc2 <= 32'd0;
        ptr0 <= 10'd0; ptr1 <= 10'd0; ptr2 <= 10'd0;
        left0 <= 10'd0; left1 <= 10'd0; left2 <= 10'd0;
        env0 <= 16'd0; env1 <= 16'd0; env2 <= 16'd0;
        ecnt <= 6'd0; cnt5 <= 8'd0; adv <= 1'b1;
        nx0 <= 1'b0; nx1 <= 1'b0; nx2 <= 1'b0;
    end else if (!play) begin
        i2s_bclk <= 1'b0; i2s_lrclk <= 1'b0; i2s_data <= 1'b0;
        bit_cnt <= 6'd0; lr <= 1'b0; st <= 6'd0;
    end else begin
        // ---------------- I2S 串行输出 ----------------
        i2s_bclk <= ~i2s_bclk;
        if (bclk_fall) begin
            if (slot_end) begin
                bit_cnt <= 6'd0;
                lr <= ~lr;
                i2s_lrclk <= ~lr;
                i2s_data <= 1'b0;         // LRCLK 变化后的 1 bit 延迟
                sr_hold <= out16;
            end else begin
                bit_cnt  <= bit_cnt + 6'd1;
                i2s_data <= sr_hold[15];
                sr_hold  <= {sr_hold[14:0], 1'b0};
            end
        end

        // ---------------- 合成状态机 ----------------
        case (st)
        6'd0: if (smp_new) begin
                  ph0 <= ph0 + inc0;
                  ph1 <= ph1 + inc1;
                  ph2 <= ph2 + inc2;
                  st  <= 6'd1;
              end
        6'd1:  begin a  <= {2'b00, ph0[31:24]};               st <= 6'd2; end
        6'd2:  begin a2 <= {1'b1, a[7:0]}; wb <= wave_rom[{1'b0, a[7:0]}]; st <= 6'd3; end
        6'd3:  begin wr <= wave_rom[a2];
                     ws0 <= wb + ((m0 >= 6'd42) ? (wr >>> 4) :
                                  (m0 >= 6'd39) ? (wr >>> 3) :
                                  (m0 >= 6'd36) ? (wr >>> 2) :
                                  (env0[15] ? (wr >>> 1) : (wr >>> 2)));
                     a   <= {2'b00, ph1[31:24]};              st <= 6'd4; end
        6'd4:  begin a2 <= {1'b1, a[7:0]}; wb <= wave_rom[{1'b0, a[7:0]}]; st <= 6'd5; end
        6'd5:  begin wr <= wave_rom[a2];
                     ws1 <= wb + (env1[15] ? (wr >>> 1) : (wr >>> 2));
                     a   <= {2'b00, ph2[31:24]};              st <= 6'd6; end
        6'd6:  begin a2 <= {1'b1, a[7:0]}; wb <= wave_rom[{1'b0, a[7:0]}]; st <= 6'd7; end
        6'd7:  begin wr <= wave_rom[a2];
                     ws2 <= wb + (env2[15] ? (wr >>> 1) : (wr >>> 2));
                     ma <= ws0; mb <= {1'b0, env0};           st <= 6'd8; end
        6'd8:  begin acc <= (ma * mb) >>> 16; ma <= ws1; mb <= {1'b0, env1}; st <= 6'd9;  end
        6'd9:  begin acc <= acc + ((ma * mb) >>> 16); ma <= ws2; mb <= {1'b0, env2}; st <= 6'd10; end
        6'd10: begin acc <= acc + ((ma * mb) >>> 16);                        st <= 6'd11; end
        6'd11: begin                                                         st <= 6'd12; end
        6'd12: begin
            if (acc > 32'sd4095)       out16 <= 16'd32767;
            else if (acc < -32'sd4096) out16 <= 16'h8000;
            else                       out16 <= {acc[12:0], 3'b000};
            st <= adv ? 6'd13 : 6'd0;
        end
        // ---- 5ms 走表：melody ----
        6'd13: begin
            nx0 <= (left0 == 10'd0);
            if (left0 == 10'd0)
                a <= (ptr0 == MEL_N - 10'd1) ? 10'd0 : ptr0 + 10'd1;
            st <= 6'd14;
        end
        6'd14: begin
            if (nx0) begin rd0 <= mel_tab[a]; st <= 6'd15; end
            else     begin left0 <= left0 - 10'd1; st <= 6'd17; end
        end
        6'd15: begin ptr0 <= a; m0 <= rd0[15:10]; u0 <= rd0[9:0]; st <= 6'd16; end
        6'd16: begin inc0 <= inc_rom[m0];
                     left0 <= (u0 == 10'd0) ? 10'd0 : u0 - 10'd1;
                     env0 <= 16'd49807; nx0 <= 1'b0;   // 0.80 x 0.95
                     ph0  <= 32'd0;            // v78：起音相位清零 = 软起音
                     st   <= 6'd17; end
        // ---- middle ----
        6'd17: begin
            nx1 <= (left1 == 10'd0);
            if (left1 == 10'd0)
                a <= (ptr1 == MID_N - 10'd1) ? 10'd0 : ptr1 + 10'd1;
            st <= 6'd18;
        end
        6'd18: begin
            if (nx1) begin rd1 <= mid_tab[a]; st <= 6'd19; end
            else     begin left1 <= left1 - 10'd1; st <= 6'd21; end
        end
        6'd19: begin ptr1 <= a; m1 <= rd1[15:10]; u1 <= rd1[9:0]; st <= 6'd20; end
        6'd20: begin inc1 <= inc_rom[m1];
                     left1 <= (u1 == 10'd0) ? 10'd0 : u1 - 10'd1;
                     // 中声部：0.26 x (1.00/0.90/0.96/0.92) —— 上行琶音的层次
                     env1 <= (ptr1[1:0] == 2'd0) ? 16'd17039 :
                             (ptr1[1:0] == 2'd1) ? 16'd15335 :
                             (ptr1[1:0] == 2'd2) ? 16'd16357 : 16'd15676;
                     nx1 <= 1'b0;
                     ph1  <= 32'd0;
                     st   <= 6'd21; end
        // ---- bass ----
        6'd21: begin
            nx2 <= (left2 == 10'd0);
            if (left2 == 10'd0)
                a <= (ptr2 == BAS_N - 10'd1) ? 10'd0 : ptr2 + 10'd1;
            st <= 6'd22;
        end
        6'd22: begin
            if (nx2) begin rd2 <= bas_tab[a]; st <= 6'd23; end
            else     begin left2 <= left2 - 10'd1; adv <= 1'b0; st <= 6'd0; end
        end
        6'd23: begin ptr2 <= a; m2 <= rd2[15:10]; u2 <= rd2[9:0]; st <= 6'd24; end
        6'd24: begin inc2 <= inc_rom[m2];
                     left2 <= (u2 == 10'd0) ? 10'd0 : u2 - 10'd1;
                     // 低音：0.30 x (1.10/0.90) —— 每小节第 1 拍重音
                     env2 <= (ptr2[0] == 1'b0) ? 16'd21627 : 16'd17695;
                     nx2 <= 1'b0;
                     ph2  <= 32'd0;
                     adv <= 1'b0; st <= 6'd0; end
        default: st <= 6'd0;
        endcase

        // ---------------- 包络 / 5ms 计时 ----------------
        if (smp_new) begin
            cnt5 <= (cnt5 == 8'd239) ? 8'd0 : cnt5 + 8'd1;
            if (cnt5 == 8'd239) adv <= 1'b1;
        end
        if (st == 6'd0 && smp_new) begin
            if (ecnt == 6'd31) begin
                ecnt <= 6'd0;
                env0 <= (left0 <= 10'd8) ? (env0 - (env0 >> 4)) : (env0 - (env0 >> 11));
                env1 <= (left1 <= 10'd8) ? (env1 - (env1 >> 4)) : (env1 - (env1 >> 10));
                env2 <= (left2 <= 10'd8) ? (env2 - (env2 >> 4)) : (env2 - (env2 >> 9));
            end else begin
                ecnt <= ecnt + 6'd1;
            end
        end
    end
end

endmodule
'''


def patch_top():
    src = io.open(TOP, encoding='utf-8').read()
    m = re.search(r'module (?:melody_player|piano_player) \(.*?\nendmodule\n', src, re.S)
    assert m, '没找到 melody_player / piano_player 模块'
    new_mod = emit_module() + '\n'
    src = src[:m.start()] + new_mod + src[m.end():]
    src = src.replace('melody_player u_melody_player (', 'piano_player u_piano_player (', 1)
    io.open(TOP, 'w', encoding='utf-8', newline='').write(src)
    print('已替换顶层模块（%d 字符）' % len(new_mod))


if __name__ == '__main__':
    print('三表事件数 %s，总长 %.2f 秒' %
          ({k: len(v) for k, v in TABLES.items()}, LOOP_UNITS * UNIT_MS / 1000.0))
    # v78：两抽头回声（89ms=4272 样本，137ms=6576 样本）。
    #   RTL 侧：一个 8192x16 的延时 RAM + 两次读 + 移位相加（约 15 个 BRAM9k，
    #   当前只用了 29/64，放得下）。这里逐样本按同样的定点规则算：
    #     out = (y>>1) + (y>>2) + (d89>>3) + (d137>>4)
    ysum = np.clip(np.round(simulate()).astype(np.int32), -32768, 32767)
    # v78：三抽头（89/137/211ms）+ 湿声一阶低通，空间感更柔
    D1, D2, D3 = 4272, 6576, 10128
    d1 = np.roll(ysum, D1)
    d2 = np.roll(ysum, D2)
    d3 = np.roll(ysum, D3)
    wet = ((d1 >> 3) + (d2 >> 4) + (d3 >> 5)).astype(np.int64)
    lp = np.zeros_like(wet)
    prev = 0
    for i in range(0, len(wet), 1):    # 一阶低通 y += (x-y)/4
        prev = prev + ((int(wet[i]) - prev) >> 2)
        lp[i] = prev
    y = np.clip((ysum >> 1) + (ysum >> 2) + lp,
                -32768, 32767).astype('<i2')
    with wave.open(WAV_OUT, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(y.tobytes())
    rms = np.sqrt((y.astype(np.float64) ** 2).mean()) / 32768.0
    print('RTL 模拟 %s：%.2f 秒，RMS %.3f，峰值 %.2f' %
          (os.path.basename(WAV_OUT), len(y) / SR, rms, np.abs(y).max() / 32768.0))
    if '--rtl' in sys.argv:
        patch_top()
    else:
        print('（只出音频；确认音色后再加 --rtl 写进顶层）')
