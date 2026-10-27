#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_raw_video.py —— 把视频 / GIF / 图片序列转成 FPGA 能直接播放的 RAW565 帧序列

板端格式（raw_player.v 里解析的那套）：
    扇区 0 (512B) : 头部
        0..3   'R','A','W','V'
        4      version = 1
        5      format  = 0 (RGB565, little-endian)
        6      fps
        7      reserved
        8..11  width        (uint32 LE)
        12..15 height       (uint32 LE)
        16..19 frame_count  (uint32 LE)
        20..23 frame_bytes  (uint32 LE) = width*height*2
        24..27 data_start   (uint32 LE) = 1
        28..31 flags        (uint32 LE) bit0 = 循环播放
    扇区 1 起 : frame_count 帧，每帧按 512B 对齐（320x240x2 = 153600B = 300 扇区，正好整除）

用法示例：
    # 从 mp4 转，取 6 秒
    python build_raw_video.py demo.mp4 -o demo.raw --seconds 6

    # 从图片序列转（文件名排序）
    python build_raw_video.py frames/ -o demo.raw --fps 12 --hold 1

    # 生成一段自检图案（不需要任何外部素材，用于首次上板验证）
    python build_raw_video.py --pattern -o selftest.raw --seconds 8
"""
import argparse
import os
import struct
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SECTOR = 512
MAGIC = b"RAWV"
HDR_VER = 1
FMT_RGB565 = 0

VIDEO_EXT = {".mp4", ".avi", ".mov", ".mkv", ".webm", ".flv", ".m4v", ".ts", ".mpg", ".mpeg"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".bmp", ".webp", ".tif", ".tiff"}


# ---------------------------------------------------------------- helpers
def fit_image(img: Image.Image, w: int, h: int, mode: str) -> Image.Image:
    """mode: cover / contain / stretch"""
    if mode == "stretch":
        return img.resize((w, h), Image.LANCZOS)
    iw, ih = img.size
    if mode == "cover":
        scale = max(w / iw, h / ih)
        nw, nh = max(1, int(round(iw * scale))), max(1, int(round(ih * scale)))
        img = img.resize((nw, nh), Image.LANCZOS)
        left = (nw - w) // 2
        top = (nh - h) // 2
        return img.crop((left, top, left + w, top + h))
    # contain
    scale = min(w / iw, h / ih)
    nw, nh = max(1, int(round(iw * scale))), max(1, int(round(ih * scale)))
    img = img.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (w, h), (0, 0, 0))
    canvas.paste(img, ((w - nw) // 2, (h - nh) // 2))
    return canvas


def to_rgb565_bytes(img: Image.Image) -> bytes:
    a = np.asarray(img.convert("RGB"), dtype=np.uint16)
    r = a[..., 0]
    g = a[..., 1]
    b = a[..., 2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return v.astype("<u2").tobytes()


def ffmpeg_exe() -> str:
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


def iter_video(path: str, w: int, h: int, fps: int, start: float,
               seconds: float | None, fit: str):
    """用 ffmpeg 解码成 rgb24 原始流，逐帧 yield PIL Image"""
    if fit == "cover":
        vf = (f"fps={fps},scale={w}:{h}:force_original_aspect_ratio=increase,"
              f"crop={w}:{h}")
    elif fit == "stretch":
        vf = f"fps={fps},scale={w}:{h}"
    else:
        vf = (f"fps={fps},scale={w}:{h}:force_original_aspect_ratio=decrease,"
              f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color=black")

    cmd = [ffmpeg_exe(), "-v", "error", "-nostdin"]
    if start and start > 0:
        cmd += ["-ss", str(start)]
    cmd += ["-i", path]
    if seconds:
        cmd += ["-t", str(seconds)]
    cmd += ["-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                bufsize=w * h * 3 * 4)
    except FileNotFoundError:
        raise SystemExit("[!] 找不到 ffmpeg。装一个：pip install imageio-ffmpeg "
                         "（或用 conda/apt 装 ffmpeg 并加进 PATH）")
    frame_bytes = w * h * 3
    try:
        while True:
            buf = proc.stdout.read(frame_bytes)
            if not buf or len(buf) < frame_bytes:
                break
            yield Image.frombytes("RGB", (w, h), buf)
    finally:
        try:
            proc.stdout.close()
        except Exception:
            pass
        err = proc.stderr.read().decode("utf-8", "ignore").strip()
        proc.wait()
        if proc.returncode not in (0, None) and err:
            print("[ffmpeg] " + err, file=sys.stderr)


def iter_gif(path: str, w: int, h: int, fps: int, fit: str):
    im = Image.open(path)
    n = getattr(im, "n_frames", 1)
    src_fps = 1000.0 / max(1, im.info.get("duration", 100))
    step = max(1, int(round(src_fps / fps)))
    for i in range(0, n, step):
        im.seek(i)
        yield fit_image(im.convert("RGB"), w, h, fit)


def natural_key(name: str):
    """把文件名里的数字按数值排序：frame_2 < frame_10（字典序会反过来）"""
    import re
    return [int(t) if t.isdigit() else t.lower()
            for t in re.split(r"(\d+)", name)]


def iter_dir(path: str, w: int, h: int, fps: int, hold: int, fit: str):
    names = sorted(
        (f for f in os.listdir(path)
         if os.path.splitext(f)[1].lower() in IMAGE_EXT),
        key=natural_key
    )
    if not names:
        raise SystemExit(f"[!] 目录里没有图片: {path}")
    for f in names:
        img = fit_image(Image.open(os.path.join(path, f)).convert("RGB"), w, h, fit)
        for _ in range(max(1, hold)):
            yield img


# ---------------------------------------------------------------- 自检图案
def pattern_frames(w: int, h: int, fps: int, seconds: float, frames: int | None):
    """动态自检图：8 色竖条 + 移动方块 + 大字帧号 + 时间码
    用来第一次上板时判断：颜色对不对（R/B 有没有交换）、行序对不对（会不会上下颠倒）、
    帧率对不对（帧号增长速度）、有没有撕裂。"""
    total = frames or max(1, int(round(fps * seconds)))
    try:
        font_big = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 64)
        font_mid = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 22)
        font_sm = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 16)
    except Exception:
        font_big = font_mid = font_sm = ImageFont.load_default()

    bars = [(255, 0, 0), (255, 128, 0), (255, 255, 0), (0, 255, 0),
            (0, 255, 255), (0, 0, 255), (255, 0, 255), (255, 255, 255)]
    for i in range(total):
        img = Image.new("RGB", (w, h), (16, 16, 16))
        d = ImageDraw.Draw(img)
        bw = w // 8
        for k, c in enumerate(bars):
            d.rectangle([k * bw, 0, (k + 1) * bw - 1, 44], fill=c)

        # 移动方块：横向扫过，用来判断水平方向有没有镜像
        x = int((i * 7) % max(1, w - 40))
        d.rectangle([x, h - 56, x + 39, h - 17], fill=(255, 255, 255))

        # 帧号
        txt = f"{i:04d}"
        bb = d.textbbox((0, 0), txt, font=font_big)
        d.text(((w - (bb[2] - bb[0])) // 2, 62), txt, font=font_big, fill=(255, 255, 255))
        # 时间码
        t = i / fps
        tc = f"{int(t // 60):02d}:{t % 60:05.2f}  {fps}fps  {w}x{h} RGB565"
        bb = d.textbbox((0, 0), tc, font=font_sm)
        d.text(((w - (bb[2] - bb[0])) // 2, 140), tc, font=font_sm, fill=(0, 255, 128))
        # 顶部/底部标记，判断上下是否颠倒
        d.text((4, 48), "TOP", font=font_mid, fill=(255, 255, 0))
        d.rectangle([0, h - 6, w - 1, h - 1], fill=(255, 0, 0))
        # 左右不对称标记，判断水平镜像
        d.rectangle([0, h // 2 - 8, 8, h // 2 + 8], fill=(0, 255, 255))
        yield img


# ---------------------------------------------------------------- 主流程
def cfg_fps_note(args):
    return "(12fps 直切)"


def main():
    ap = argparse.ArgumentParser(description="视频/图片 -> FPGA RAW565 帧序列")
    ap.add_argument("input", nargs="?", help="视频文件 / GIF / 图片目录 / 单张图片")
    ap.add_argument("-o", "--out", required=True, help="输出 .raw 路径")
    ap.add_argument("--w", type=int, default=320)
    ap.add_argument("--h", type=int, default=240)
    ap.add_argument("--fps", type=int, default=12)
    ap.add_argument("--start", type=float, default=0.0, help="起始秒（仅视频）")
    ap.add_argument("--seconds", type=float, default=None, help="时长（仅视频/自检图）")
    ap.add_argument("--max-frames", type=int, default=None)
    ap.add_argument("--fit", choices=["cover", "contain", "stretch"], default="cover")
    ap.add_argument("--hold", type=int, default=1, help="图片序列每张重复帧数")
    ap.add_argument("--no-loop", action="store_true",
                    help="把头部 loop 标志写成 0（v40 起固件不读这个位，播完都停在最后一帧）")
    ap.add_argument("--pattern", action="store_true", help="生成自检图案（不需要 input）")
    ap.add_argument("--sector-bytes", type=int, default=SECTOR)
    ap.add_argument("--force-size", action="store_true",
                    help="允许生成非 320x240 的文件（板端不认，仅供离线检查）")
    ap.add_argument("--photos", default=None,
                    help="片头照片：逗号分隔的图片路径（最多 8 张），播完再接视频，循环")
    ap.add_argument("--photo-hold", type=float, default=5.0,
                    help="每张照片定格秒数（默认 5s）")
    args = ap.parse_args()

    # ---- 参数校验（先校验，别等写了几百 MB 才报错）----
    if args.fps < 1 or args.fps > 30:
        raise SystemExit(f"[!] --fps 必须在 1..30（当前 {args.fps}）")
    if args.w < 16 or args.h < 16:
        raise SystemExit(f"[!] 分辨率太小：{args.w}x{args.h}")
    if (args.w, args.h) != (320, 240):
        msg = (f"[!] 板端硬编码只认 320x240（raw_player 的 hdr_ok 会核对宽高），"
               f"{args.w}x{args.h} 的文件上板会被判为照片模式。")
        if not args.force_size:
            raise SystemExit(msg + "\n    确实要生成请加 --force-size")
        print(msg + " 已按 --force-size 继续。", file=sys.stderr)
    if args.seconds is not None and args.seconds <= 0:
        raise SystemExit("[!] --seconds 必须 > 0")
    if args.hold < 1:
        raise SystemExit("[!] --hold 必须 >= 1")

    # ---- 片头照片（v34）----
    photos = []
    if args.photos:
        for q in [t.strip() for t in args.photos.split(",") if t.strip()]:
            if not os.path.isfile(q):
                raise SystemExit(f"[!] 找不到照片: {q}")
            if os.path.splitext(q)[1].lower() not in IMAGE_EXT:
                raise SystemExit(f"[!] 不是图片: {q}")
            photos.append(q)
        if len(photos) > 8:
            raise SystemExit(f"[!] 照片最多 8 张（板端 hdr_ok 限制），当前 {len(photos)} 张")
        if args.photo_hold < 0.2:
            raise SystemExit("[!] --photo-hold 至少 0.2 秒（板端会拒绝 < 200ms）")

    frame_bytes = args.w * args.h * 2
    frame_sectors = (frame_bytes + SECTOR - 1) // SECTOR
    pad = frame_sectors * SECTOR - frame_bytes

    # ---- 帧源 ----
    if args.pattern:
        src = pattern_frames(args.w, args.h, args.fps, args.seconds or 8, args.max_frames)
        src_desc = "内置自检图案"
    elif not args.input:
        raise SystemExit("[!] 需要 input，或加 --pattern")
    else:
        p = args.input
        if os.path.isdir(p):
            src = iter_dir(p, args.w, args.h, args.fps, args.hold, args.fit)
            src_desc = f"图片目录 {p}"
        elif not os.path.isfile(p):
            raise SystemExit(f"[!] 找不到输入: {p}")
        else:
            ext = os.path.splitext(p)[1].lower()
            if ext == ".gif":
                src = iter_gif(p, args.w, args.h, args.fps, args.fit)
            elif ext in VIDEO_EXT:
                src = iter_video(p, args.w, args.h, args.fps, args.start,
                                 args.seconds, args.fit)
            elif ext in IMAGE_EXT:
                img = fit_image(Image.open(p).convert("RGB"), args.w, args.h, args.fit)
                n = args.max_frames or (args.fps * (args.seconds or 1))
                src = (img for _ in range(max(1, int(n))))
            else:
                raise SystemExit(f"[!] 不认识的扩展名: {ext}")
            src_desc = p

    # ---- 写文件 ----
    tmp = args.out + ".tmp"
    nframes = 0
    try:
        _build(args, src, src_desc, tmp, frame_bytes, frame_sectors, pad, photos)
    except (SystemExit, KeyboardInterrupt):
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    except OSError as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise SystemExit(f"[!] 写文件失败：{e}\n    目标目录是否可写？磁盘是否满了？")


def _build(args, src, src_desc, tmp, frame_bytes, frame_sectors, pad, photos=()):
    nframes = 0
    with open(tmp, "wb") as f:
        f.write(b"\x00" * SECTOR)          # 头部占位，最后回填

        # ---- 片头照片：一张一帧，紧跟在头后面 ----
        for q in photos:
            img = fit_image(Image.open(q).convert("RGB"), args.w, args.h, args.fit)
            f.write(to_rgb565_bytes(img))
            if pad:
                f.write(b"\x00" * pad)
            print(f"\r  已写入片头照片 {photos.index(q) + 1}/{len(photos)}", end="",
                  file=sys.stderr)
        if photos:
            print(file=sys.stderr)

        for img in src:
            f.write(to_rgb565_bytes(img))
            if pad:
                f.write(b"\x00" * pad)
            nframes += 1
            if args.max_frames and nframes >= args.max_frames:
                break
            if nframes % 24 == 0:
                print(f"\r  已写入 {nframes} 帧 ({nframes / args.fps:5.1f}s)", end="",
                      file=sys.stderr)
        print(file=sys.stderr)

        if nframes == 0:
            raise SystemExit("[!] 一帧都没读到，检查输入文件")

        # 回填头部
        hdr = bytearray(SECTOR)
        hdr[0:4] = MAGIC
        hdr[4] = 2 if photos else HDR_VER
        hdr[5] = FMT_RGB565
        hdr[6] = args.fps & 0xFF
        hdr[7] = 0
        struct.pack_into("<I", hdr, 8, args.w)
        struct.pack_into("<I", hdr, 12, args.h)
        struct.pack_into("<I", hdr, 16, nframes)
        struct.pack_into("<I", hdr, 20, frame_bytes)
        data_start = 1 + len(photos) * frame_sectors
        struct.pack_into("<I", hdr, 24, data_start)
        struct.pack_into("<I", hdr, 28, 0 if args.no_loop else 1)
        # v34 片头照片字段
        struct.pack_into("<I", hdr, 32, len(photos))
        struct.pack_into("<I", hdr, 36, int(round(args.photo_hold * 1000)))
        struct.pack_into("<I", hdr, 40, 1 if photos else 0)
        f.seek(0)
        f.write(bytes(hdr))
        f.flush()
        os.fsync(f.fileno())

    os.replace(tmp, args.out)

    total = os.path.getsize(args.out)
    dur = nframes / args.fps
    need_rate = frame_sectors * SECTOR * args.fps / 1e6
    print()
    print("=" * 62)
    print(f"输入      : {src_desc}")
    print(f"输出      : {args.out}")
    print(f"分辨率    : {args.w} x {args.h}  RGB565")
    if photos:
        print(f"片头照片  : {len(photos)} 张，每张定格 {args.photo_hold:g}s "
              f"-> 共 {len(photos) * args.photo_hold:g}s")
        for k, q in enumerate(photos):
            print(f"            [{k}] {os.path.basename(q)}")
        print(f"播放顺序  : 照片 1..{len(photos)}（淡入淡出）-> 视频 {cfg_fps_note(args)} -> 循环")
        print("            [注意] v40/v41 板端【不再播放片头照片】：照片改由 TF 卡")
        print("                   FAT32 分区里的 4 个 BMP 提供，视频只播后面的帧。")
    print(f"帧率      : {args.fps} fps")
    print(f"帧数      : {nframes}   (时长 {dur:.2f} s)")
    print(f"每帧      : {frame_bytes} B = {frame_sectors} 扇区")
    print(f"文件大小  : {total} B ({total / 1048576:.2f} MB)")
    print(f"SD 读取率 : {need_rate:.2f} MB/s  (SPI 25MHz 实测上限约 2.2 MB/s)")
    if need_rate > 2.2:
        print("            [!!] 超出 SD 带宽，板端会掉帧，请降 fps 或分辨率")
    # v41：板端 raw_player 的播放语义是"播到最后一帧就停在那一帧，按 S0 回第一张照片"，
    #   头部里的 loop 标志固件并不使用。这里如实写出来，别让人以为会自己循环。
    print(f"播完行为  : 停在最后一帧，按 S0 回到第 1 张照片"
          f"（头部 loop 位={'0' if args.no_loop else '1'}，固件不读）")
    print("=" * 62)
    print("下一步：插卡 -> 查磁盘号（管理员）")
    print("        python tools\\rawcard\\write_rawcard.py --list")
    print("        写视频到 LBA 524288（不动 4 张 BMP）：")
    print(f"        tools\\rawcard\\put_video.bat {os.path.basename(args.out)} <磁盘号>")
    print("        整卡重建（含 4 张 BMP）：tools\\rawcard\\prep_card.bat <磁盘号>")


if __name__ == "__main__":
    main()
