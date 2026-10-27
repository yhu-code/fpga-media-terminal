# -*- coding: utf-8 -*-
"""uart_s0_mon.py —— 在 COM7 上实时解读 FPGA 的 S0 诊断字。

用法：
    python uart_s0_mon.py            # 默认 COM7, 115200
    python uart_s0_mon.py COM7
    python uart_s0_mon.py COM7 115200 --raw   # 原始行也打印

读的是什么：
    板子每 115200 波特持续发 6 行，形如
        [0001] A=00000000
        [0001] B=00000010
        [0001] C=21000000      <- 照片链路空闲时这就是 S0 诊断字
        ...
    C 字（空闲时）位定义：
        [31:30] disp_idx            屏幕上是第几张（0..3）
        [29:28] disp_buf_idx        正在显示哪块 SDRAM buffer
        [27:26] next_disp           下一次 S0 会去的张号
        [25]    frame_ready_pending 图已装好、等转场确认（1 = 正在等）
        [24]    bus_ok              允许发起装载的总线条件
        [23]    sd_bus_idle         SD 控制器真的空闲
        [22]    next_req            有按键待办（按过 S0 且还没兑现）
        [21:14] cnt_key             S0 按下次数（消抖后）
        [13:6]  cnt_load            真正发起的换图装载次数
        [5:0]   cnt_hand            交棒视频次数
    A 字：[31] load_busy，[9:0] 空闲时 = {clear_done, clear_active, scan_kicked,
        bmp_ready, scan_done, auto_play_en, next_req, key_auto_seen,
        key_next_seen, 0}
"""
import re
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else 'COM7'
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
RAW = '--raw' in sys.argv

pat = re.compile(r'\[(\d+)\]\s*([A-F])=([0-9A-Fa-f]{8})')

try:
    ser = serial.Serial(PORT, BAUD, timeout=1)
except Exception as e:
    print('打不开 %s：%s' % (PORT, e))
    print('（检查：串口号对不对、有没有被别的串口助手占用）')
    sys.exit(1)

print('已打开 %s @ %d。现在按板子上的 S0，观察下面输出。Ctrl+C 结束。' % (PORT, BAUD))
print('%-8s %-4s %-8s %-6s %-5s %-5s %-5s %-4s %-5s | %-5s %-4s %-4s' % (
    '时间', '键数', '装载', '交棒', 'disp', 'next', 'fpend', 'req', '总线',
    'busy', '状态', '图片'))
print('-' * 92)

blk = {}
last_print = 0.0
prev = None
t0 = time.time()

try:
    while True:
        line = ser.readline().decode('latin-1', 'ignore').strip()
        if not line:
            continue
        if RAW:
            print('  ', line)
        m = pat.search(line)
        if not m:
            continue
        idx, key, val = int(m.group(1)), m.group(2), int(m.group(3), 16)
        blk[key] = val
        if key != 'F':
            continue
        now = time.time()
        if now - last_print < 0.35:
            continue
        last_print = now
        a, c = blk.get('A', 0), blk.get('C', 0)
        load_busy = (a >> 31) & 1
        if load_busy:
            print('%-8.1f 装载中…（A=%08X）' % (now - t0, a))
            blk = {}
            continue
        clear_done = (a >> 9) & 1
        bmp_ready = (a >> 6) & 1
        scan_done = (a >> 5) & 1
        auto_on = (a >> 4) & 1
        tail_req = (a >> 3) & 1
        key_seen = (a >> 1) & 1
        found = (a >> 24) & 0x7          # img_found_count
        st = (a >> 27) & 0xF             # 照片链路状态机编号
        disp = (c >> 30) & 0x3
        buf = (c >> 28) & 0x3
        nxt = (c >> 26) & 0x3
        fpend = (c >> 25) & 1
        busok = (c >> 24) & 1
        idle = (c >> 23) & 1
        req = (c >> 22) & 1
        ck = (c >> 14) & 0xFF
        cl = (c >> 6) & 0xFF
        ch = c & 0x3F
        bus = ('idle' if idle else ('ok' if busok else 'block'))
        row = ('%-8.1f %-4d %-8d %-6d %-5d %-5d %-5d %-4d %-5s | %-5d %-4d %-4d' % (
            now - t0, ck, cl, ch, disp, nxt, fpend, req, bus, load_busy, st, found))
        if prev is not None and row[9:] != prev:
            row += '  <- %s' % ('buf%d' % buf)
        prev = row[9:]
        print(row)
        blk = {}
        _ = (clear_done, bmp_ready, scan_done, auto_on, tail_req, key_seen)
except KeyboardInterrupt:
    print('\n结束。')
finally:
    ser.close()
