"""Turns the frames scripts/render_badges.sh drew into one looping GIF per badge animation.

  python3 scripts/make_badge_gifs.py FRAMES_DIR OUT_DIR

Each frame is trimmed to the part inside the pill's rounded ends (badge_frames.lua INSET), all
frames of an animation share one palette so colours don't flicker, and the badge colour is made
transparent: the strokes keep their edges smoothed against that same colour, and the pill under
the GIF, drawn by badge.lua, shows through everywhere else."""

import re
import sys
from collections import defaultdict
from pathlib import Path

from PIL import Image

BG = (0x1D, 0x1A, 0x1C)
INSET = (10, 3)  # points trimmed from each side; must match badge_frames.lua
NO_INSET = {"needles"}  # drawn in the middle of the pill, not across its ends
FPS = 20


def main(frames_dir, out_dir):
    groups = defaultdict(list)
    for path in sorted(Path(frames_dir).glob("*.png")):
        kind, n = re.match(r"(.+)-(\d+)\.png$", path.name).groups()
        groups[kind].append((int(n), path))
    out_dir.mkdir(parents=True, exist_ok=True)
    for kind, items in sorted(groups.items()):
        frames = [Image.open(p).convert("RGB") for _, p in sorted(items)]
        w, h = frames[0].size
        scale = h / 34  # Retina renders at 2x
        ix, iy = (0, INSET[1]) if kind in NO_INSET else INSET
        box = (round(ix * scale), round(iy * scale), w - round(ix * scale), h - round(iy * scale))
        frames = [f.crop(box) for f in frames]
        sheet = Image.new("RGB", (frames[0].width, frames[0].height * len(frames)))
        for i, f in enumerate(frames):
            sheet.paste(f, (0, i * f.height))
        palette = sheet.quantize(colors=64, method=Image.Quantize.MEDIANCUT)
        quantized = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
        colours = palette.getpalette()[:64 * 3]
        bg = min(range(64), key=lambda i: sum((colours[3 * i + k] - BG[k]) ** 2 for k in range(3)))
        out = out_dir / f"{kind}.gif"
        quantized[0].save(out, save_all=True, append_images=quantized[1:], duration=1000 // FPS, loop=0,
                          transparency=bg, disposal=2, optimize=False)
        print(f"{out.name}  {len(frames)} frames  {frames[0].size[0]}x{frames[0].size[1]}  "
              f"{out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]))
