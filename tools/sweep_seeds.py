# -*- coding: utf-8 -*-
"""sweep_seeds.py —— 依次用多个 place seed 跑 P&R，记录 SWNS/HWNS/冲突数，保留 bit

TD 的 td_commands_prompt.exe 跑完 tcl 不会自己退出（会停在交互提示），
所以这里用「监控 final_timing.rpt + 日志停止增长」判断运行结束，再强制结束进程。
"""
import os
import re
import shutil
import subprocess
import sys
import time

RUN = r'D:\lab_ex4_tffff111\src\td_project\lab_ex5_i2s_v1.0_Runs\phy_1'
TD = r'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe'
TCL = 'lab_ex5_i2s_v1.0.tcl'
SEEDS = [int(x) for x in (sys.argv[1:] or ['19', '37', '41', '43'])]
RES = os.path.join(RUN, 'sweep_v71.txt')


def read_any(path):
    b = open(path, 'rb').read()
    for enc in ('utf-8', 'utf-16', 'latin-1'):
        try:
            return b.decode(enc)
        except Exception:
            continue
    return b.decode('latin-1', 'ignore')


def set_seed(seed):
    p = os.path.join(RUN, 'settings.cfg')
    s = open(p, encoding='utf-8', errors='ignore').read()
    s = re.sub(r'place seed \d+', 'place seed %d' % seed, s)
    open(p, 'w', encoding='utf-8', newline='').write(s)


def run_once(seed):
    log = os.path.join(RUN, 'phy_seed%d.v71.log' % seed)
    rpt = os.path.join(RUN, 'final_timing.rpt')
    bit = os.path.join(RUN, 'lab_ex5_i2s_v1.0.bit')
    for f in (rpt, bit):
        if os.path.exists(f):
            os.remove(f)
    with open(log, 'wb') as fh:
        p = subprocess.Popen([TD, TCL], cwd=RUN, stdout=fh, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL)
    t0 = time.time()
    last_size, last_change = -1, time.time()
    sw = hw = cf = 'NA'
    while True:
        time.sleep(5)
        time_used = time.time() - t0
        # 日志增长检测
        try:
            size = os.path.getsize(log)
        except OSError:
            size = 0
        if size != last_size:
            last_size, last_change = size, time.time()
        # v79：route 失败（PHY-8023）时 bit 不会生成，原来的判据会白等 900s。
        #   这里再看一眼日志尾部：出现提示符 / route 结束行就视为本次跑完。
        tail = ''
        try:
            with open(log, 'rb') as fh:
                fh.seek(max(0, size - 600))
                tail = fh.read().decode('latin-1', 'ignore')
        except OSError:
            pass
        finished = ('td > ' in tail) or ('finish command "route"' in tail)
        done = (os.path.exists(rpt) and os.path.exists(bit)
                and time.time() - last_change > 12)
        if done or (finished and time.time() - last_change > 15) or time_used > 900:
            p.terminate()
            try:
                p.wait(timeout=10)
            except Exception:
                p.kill()
            break
    vw = 'NA'
    sw2 = 'NA'
    if os.path.exists(rpt):
        t = read_any(rpt)
        mv = re.search(r'video_clk -> video_clk.*?Max\s*:\s*SWNS\s*(-?[\d.]+)ns', t, re.S)
        if mv:
            vw = mv.group(1)
        ms = re.search(r'sd_card_clk -> sd_card_clk.*?Max\s*:\s*SWNS\s*(-?[\d.]+)ns,\s*STNS\s*(-?[\d.]+)ns,\s*(\d+) Viol', t, re.S)
        if ms:
            sw2 = '%s/%s' % (ms.group(1), ms.group(3))
        m = re.search(r'SWNS:\s*(-?[\d.]+)ns,\s*STNS:\s*(-?[\d.]+)ns', t)
        if m:
            sw = m.group(1)
        m2 = re.search(r'HWNS:\s*(-?[\d.]+)ns,\s*HTNS:\s*(-?[\d.]+)ns', t)
        if m2:
            hw = m2.group(1)
    if os.path.exists(log):
        raw = read_any(log)
        cf = raw.count('8023')
    if os.path.exists(bit):
        shutil.copyfile(bit, os.path.join(RUN, 'bit_v71_s%d.bit' % seed))
    dt = time.time() - t0
    line = 'seed %-3d SWNS %-8s HWNS %-8s video %-7s sd %-12s cf %-4s %.0fs' % (
        seed, sw, hw, vw, sw2, cf, dt)
    print(line, flush=True)
    with open(RES, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


if __name__ == '__main__':
    open(RES, 'a', encoding='utf-8').write('\n=== sweep %s ===\n' % time.strftime('%H:%M:%S'))
    for s in SEEDS:
        set_seed(s)
        run_once(s)
    print('SWEEP DONE', flush=True)
