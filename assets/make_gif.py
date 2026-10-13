"""Builds assets/grandma-yawn.gif: grandma's mascot, unchanged, with her voice coming in as sound
waves on the left, a strand of yarn into her knitting, lines of text knitting up on the right,
and a few sleepy z's. Transparent, 8 fps, loops with the mascot's 40 frames.

  python3 assets/make_gif.py /path/to/grandma/assets/grandma-mascot.gif

Needs Pillow and ffmpeg. Also writes preview-light.png and preview-dark.png (frame 30 on GitHub's
light and dark backgrounds) for review; those aren't committed."""

import math
import sys
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "grandma-mascot.gif"
OUT = HERE
W, H, S = 720, 440, 2  # canvas, drawn at 2x then downscaled
MASCOT_X = 140
LIGHT, ROSE, DEEP = (0xfe, 0xb1, 0xbb), (0xfa, 0x98, 0xa3), (0xd2, 0x62, 0x6f)
N = 40


def mascot_frames():
    im = Image.open(SRC)
    frames = []
    for i in range(im.n_frames):
        im.seek(i)
        frames.append(im.convert("RGBA").copy())
    return frames


def bar(d, x, y0, y1, width, color):
    r = width / 2
    d.rounded_rectangle([x - r, min(y0, y1), x + r, max(y0, y1)], radius=r, fill=color)


def bezier(p0, p1, p2, p3, steps=80):
    pts = []
    for k in range(steps + 1):
        t = k / steps
        a, b, c, e = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + e * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + e * p3[1]))
    return pts


def thick_line(d, pts, width, color):
    d.line(pts, fill=color, width=width, joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def overlay(i):
    """Everything drawn around grandma for frame i, at 2x."""
    img = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    phase = 2 * math.pi * i / N

    # Voice: seven bars pulsing like speech.
    cx0, cy = 52, 250
    for k in range(7):
        h = 14 + 34 * (0.5 + 0.5 * math.sin(phase * 2 + k * 0.9)) * (0.55 + 0.45 * math.sin(phase + k * 1.7) ** 2)
        x = (cx0 + k * 16) * S
        bar(d, x, (cy - h / 2) * S, (cy + h / 2) * S, 6 * S, ROSE + (255,))

    # What she knits becomes text: lines typed one after another, then fading out.
    lines = [(1.0, 0), (0.85, 1), (0.95, 2), (0.55, 3)]
    x0, y0, full, gap = 596, 196, 112, 22
    t = i / (N - 1)
    fade = 1.0 if i < N - 5 else (N - 1 - i) / 5
    typed = min(1.0, t / 0.8) * len(lines)
    caret = None
    for frac, row in lines:
        progress = max(0.0, min(1.0, typed - row))
        if progress <= 0:
            continue
        length = full * frac * progress
        y = y0 + row * gap
        alpha = int(255 * 0.85 * fade)
        bar_img = ImageDraw.Draw(img)
        bar_img.rounded_rectangle([x0 * S, (y - 4) * S, (x0 + max(length, 8)) * S, (y + 4) * S], radius=4 * S,
                                  fill=ROSE + (alpha,))
        if progress < 1:
            caret = (x0 + length + 6, y)
    if caret is None and typed >= len(lines):
        last_frac, last_row = lines[-1]
        caret = (x0 + full * last_frac + 6, y0 + last_row * gap)
    if caret and (i // 3) % 2 == 0 and fade > 0.5:
        bar(d, caret[0] * S, (caret[1] - 8) * S, (caret[1] + 8) * S, 2 * S, DEEP + (int(255 * fade),))

    # Sleepy z's, drifting up and fading.
    for k in range(3):
        u = ((i / N) + k / 3) % 1.0
        size = 11 + 8 * k / 2
        x, y = 418 + 14 * k + 10 * u, 92 - 46 * u - 6 * k
        a = int(255 * math.sin(math.pi * u))
        zx, zy, zs = x * S, y * S, size * S
        d.line([(zx, zy), (zx + zs, zy), (zx, zy + zs), (zx + zs, zy + zs)], fill=DEEP + (a,), width=int(3.4 * S),
               joint="curve")
    return img.resize((W, H), Image.LANCZOS)


def strand(i):
    """The yarn from her voice to her hands, drawn over her, with a wave travelling towards her."""
    img = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    phase = 2 * math.pi * i / N
    p0, p3 = (52 + 6 * 16 + 16, 250), (318, 284)
    base = bezier(p0, (p0[0] + 50, 310), (p3[0] - 80, 330), p3)
    pts = []
    for k, (x, y) in enumerate(base):
        t = k / (len(base) - 1)
        amp = 6 * math.sin(math.pi * t)
        pts.append((x * S, (y + amp * math.sin(t * 4 * math.pi - phase * 2)) * S))
    thick_line(d, pts, 6 * S, DEEP + (255,))
    d.line([(x, y - 1.5 * S) for x, y in pts], fill=LIGHT + (230,), width=int(1.5 * S), joint="curve")
    return img.resize((W, H), Image.LANCZOS)


def main():
    OUT.mkdir(exist_ok=True)
    frames = mascot_frames()
    assert len(frames) == N, len(frames)
    with tempfile.TemporaryDirectory() as tmp:
        for i, m in enumerate(frames):
            canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            canvas.alpha_composite(overlay(i))
            canvas.alpha_composite(m, (MASCOT_X, 0))
            canvas.alpha_composite(strand(i))
            canvas.save(f"{tmp}/f{i:03d}.png")
            if i == 30:
                for name, bg in (("light", (255, 255, 255)), ("dark", (13, 17, 23))):
                    prev = Image.new("RGBA", (W, H), bg + (255,))
                    prev.alpha_composite(canvas)
                    prev.convert("RGB").save(OUT / f"preview-{name}.png")
        ff = "/opt/homebrew/bin/ffmpeg"
        subprocess.run([ff, "-y", "-loglevel", "error", "-framerate", "8", "-i", f"{tmp}/f%03d.png",
                        "-vf", "palettegen=reserve_transparent=1:stats_mode=full", f"{tmp}/pal.png"], check=True)
        subprocess.run([ff, "-y", "-loglevel", "error", "-framerate", "8", "-i", f"{tmp}/f%03d.png",
                        "-i", f"{tmp}/pal.png", "-lavfi", "paletteuse=alpha_threshold=128:dither=none",
                        "-loop", "0", str(OUT / "grandma-yawn.gif")], check=True)
    gif = OUT / "grandma-yawn.gif"
    print(gif, N, "frames", gif.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
