# -*- coding: utf-8 -*-
"""make_canon.py —— 帕赫贝尔《卡农》(Canon in D) 三声部钢琴改编 v2

v1 的两个问题（用户反馈「跑调」「不丰富」）：
  1) 跑调：音高其实一个都没错（112 个音用 FFT 逐音验过），错在【和声】——
     · 第 1 遍中声部是低音的八度重复（D3 跟 D2 同向走），成了平行八度，
       没有三音/五音支撑，听着"空、没调性"；
     · 第 2 遍起中声部改成"低八度跟随主题"，可它的音和当前低音的和弦常常
       对不上（例如 Bm 的低音上出现 G3），而且一响就是 1.88 秒，
       不是"经过的不协和"，是"错音"。
  2) 不丰富：每个声部都是 1.88 秒一个长音，三个声部加起来才 3 个音，
     整首非常空。

v2 的做法：
  · 中声部从"跟旋律"改成【和弦琶音】：按和声表，每半小节弹 4 或 8 个和弦音，
    一个声部就能铺出一片和声——这才是"多重单音组合"该有的样子；
  · 低音从"同音重复"改成【根音—五度交替】，低音有了进行感；
  · 和声表按【主题的位置】排，不按低音排：卡农第 5 小节低音是 D、和声却是
    G（G/D 四六和弦），照低音配就会配错——这是 v1 听着"跑调"的根源之一；
  · 第 3 遍留一遍真正的"卡农追逐"（中声部延迟 2 小节跟随主题，非和弦音
    就近吸到和弦音上），保住卡农的识别度；
  · 所有中声部音都要过一道"与旋律不撞"的检查（小二度/小九度），撞了就换八度。
"""
import io
import json
import os

ROOT = r'D:\lab_ex4_tffff111'
OUT = os.path.join(ROOT, 'tools', 'sheet_canon.json')

UNIT_MS = 5.0
BARS = 40
BAR_U = 752                 # 3.76s
CH_U = 376                  # 半小节 = 一个和弦
TOTAL = BARS * BAR_U        # 30080
assert TOTAL == 30080, TOTAL

# ---------------- 低音（通奏低音）：根音 + 五度 ----------------
BASS = [38, 45, 47, 42, 43, 38, 43, 45]          # D2 A2 B2 F#2 G2 D2 G2 A2
BASS5 = [45, 52, 54, 49, 50, 45, 50, 52]         # 各和弦的五度（低八度内）

# ---------------- 和声表：按【主题位置】排，8 小节 x 2 半小节 ----------------
#   第 5 小节低音是 D、和声是 G/D；第 6 小节低音 A、和声是 D/A（第二转位）。
#   照低音根音去配，第 5 小节就会拿 D 和弦去对 G4，F# 和 G 顶成小二度。
HARM16 = ['D', 'A', 'Bm', 'F#m', 'G', 'D', 'G', 'A',
          'G', 'A', 'Bm', 'D', 'G', 'G', 'G', 'A']

# 各和弦的琶音音（音区 F#3..D5，比旋律低一个层次，不抢）
ARP = {
    'D':   [62, 66, 69, 74],     # D4 F#4 A4 D5
    'A':   [57, 61, 64, 69],     # A3 C#4 E4 A4
    'Bm':  [59, 62, 66, 71],     # B3 D4 F#4 B4
    'F#m': [54, 57, 61, 66],     # F#3 A3 C#4 F#4
    'G':   [55, 59, 62, 67],     # G3 B3 D4 G4
}
PC = {'D': {2, 6, 9}, 'A': {9, 1, 4}, 'Bm': {11, 2, 6}, 'F#m': {6, 9, 1}, 'G': {7, 11, 2}}

# 主题（第一小提琴，8 小节 = 16 个二分音符）
THEME = [78, 76, 74, 73, 71, 69, 69, 66,
         67, 69, 71, 74, 74, 71, 76, 73]

D_SCALE = [62, 64, 66, 67, 69, 71, 73, 74, 76, 78, 79, 81]   # D4..A5


def scale_up(m):
    for x in D_SCALE:
        if x > m:
            return x
    return m + 2


def bar_pass(bar):
    return bar // 8


def theme_note(bar, k):
    return THEME[((bar % 8) * 2 + k) % 16]


def harm_of(bar, k):
    return HARM16[((bar % 8) * 2 + k) % 16]


def clash(m, ref):
    """与参考音构成小二度/小九度/三全音"""
    for x in ref:
        if abs(m - x) in (1, 13) or min((m - x) % 12, (x - m) % 12) == 6:
            return True
    return False


def safe(m, ref, lo=48, hi=84):
    """把音挪到不与 ref 冲突的位置（优先原音，其次 ±12）"""
    for d in (0, -12, 12, -24):
        x = m + d
        if lo <= x <= hi and not clash(x, ref):
            return x
    return m


melody, middle, bass = [], [], []

for bar in range(BARS):
    p = bar_pass(bar)
    mel_here = [theme_note(bar, 0), theme_note(bar, 1)]

    # ---------------- melody ----------------
    for k in range(2):
        m = theme_note(bar, k)
        if p == 3:
            # 第 4 遍：巴洛克回音，四个八分音符（本音-上邻-本音-下邻）
            up = scale_up(m)
            dn = up - (2 if (up - m) == 2 else 3)
            for x in (m, up, m, dn):
                melody.append((x, 94))
        else:
            melody += [(m, CH_U)]

    # ---------------- bass：根 - 五 - 根(八度) - 五 ----------------
    # 每个和弦 4 个音（0.47s 一下）。通奏低音本来就有八分音符的走法，
    # 比"一拍一个长音"有脉搏得多；第 3 个音抬一个八度，低音线条才有形状。
    for k in range(2):
        i = (bar % 4) * 2 + k
        r, f5 = BASS[i], BASS5[i]
        r8 = r + 12 if r + 12 <= 60 else r
        for x in (r, f5, r8, f5):
            bass.append((x, 94))

    # ---------------- middle ----------------
    if p == 2:
        # 第 3 遍：真正的卡农追逐（延迟 2 小节），非和弦音就近吸到和弦音
        sbar = max(0, bar - 2)
        for k in range(2):
            raw = theme_note(sbar, k) - 12
            h = harm_of(bar, k)
            order = sorted(range(-4, 5), key=lambda d: (abs(d), d))
            for d in order:
                x = raw + d
                if x % 12 in PC[h] and not clash(x, mel_here):
                    break
            middle.append((x, CH_U))
    else:
        # 其它遍：和弦琶音。密度按遍递增：4 音 -> 8 音 -> 8 音 -> 4 音
        n = 4 if p == 0 else 8
        idx = [0, 1, 2, 3, 2, 1, 0, 1][:n] if n == 8 else [0, 1, 2, 3]
        for k in range(2):
            h = harm_of(bar, k)
            notes = [safe(x, mel_here) for x in ARP[h]]
            unit = CH_U // n
            for j, t in enumerate(idx):
                u = unit if j < n - 1 else (CH_U - unit * (n - 1))
                middle.append((notes[t], u))

# ---------------- 自检 ----------------
for name, tab in (('melody', melody), ('middle', middle), ('bass', bass)):
    tot = sum(u for _, u in tab)
    assert tot == TOTAL, '%s 总长 %d != %d' % (name, tot, TOTAL)
    ms = [m for m, _ in tab]
    assert 36 <= min(ms) and max(ms) <= 90, '%s 音域越界 %d..%d' % (name, min(ms), max(ms))
    assert len(tab) <= 1000, '%s 事件数 %d 超过 RTL 的 10 位地址' % (name, len(tab))
    print('%-7s %4d 事件  总长 %d 音域 %d..%d' % (name, len(tab), tot, min(ms), max(ms)))

# 和声自检：中声部每个音都必须是当前和弦音；三个声部两两不得小二度/小九度
def val(tab, pos):
    p = 0
    for m, u in tab:
        if pos < p + u:
            return m
        p += u
    return None

bad_h = bad_c = 0
for bar in range(BARS):
    for k in range(2):
        a = bar * BAR_U + k * CH_U
        h = harm_of(bar, k)
        for t in range(a, a + CH_U, 47):
            mi = val(middle, t)
            if mi is not None and mi % 12 not in PC[h]:
                bad_h += 1
        for t in range(a, a + CH_U, 23):
            ms = [val(melody, t), val(middle, t), val(bass, t)]
            for i in range(3):
                for j in range(i + 1, 3):
                    if ms[i] is None or ms[j] is None:
                        continue
                    if abs(ms[i] - ms[j]) in (1, 13):
                        bad_c += 1
print('中声部非和弦音采样点：%d   声部间小二度/小九度采样点：%d' % (bad_h, bad_c))

d = dict(melody=melody, middle=middle, bass=bass,
         unit_ms=UNIT_MS, bar_units=BAR_U, key='D major',
         bars=[{'bar': i, 'pass': bar_pass(i)} for i in range(BARS)],
         locked=True,
         note='Pachelbel Canon in D — 3-voice piano arrangement v2 (arp middle), 40 bars, 150.4s')
io.open(OUT, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False))
print('写入', OUT)
