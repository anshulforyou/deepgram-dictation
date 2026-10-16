"""Builds src/deepgram_dictation/badges/grandma.gif, the badge while grandma thinks: her mascot,
knitting, in the round bubble the pill becomes. Made from the mascot in the grandma repo.

  python3 scripts/make_grandma_badge.py /path/to/grandma/assets/grandma-mascot.gif

Shown at 84 points, so it is drawn at 168 pixels for Retina. Transparent, the mascot's own 40
frames, played slower than the mascot (FRAME_MS): at its own 130 ms she read as hurried."""

import sys
from pathlib import Path

from PIL import Image, ImageSequence

SIZE = 168
FRAME_MS = 200
OUT = Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation" / "badges" / "grandma.gif"


def main(src):
    im = Image.open(src)
    frames = []
    for frame in ImageSequence.Iterator(im):
        f = frame.convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)
        alpha = f.getchannel("A").point(lambda a: 255 if a >= 128 else 0)  # GIF alpha is on or off
        f.putalpha(alpha)
        frames.append(f)
    frames[0].save(OUT, save_all=True, append_images=frames[1:], duration=FRAME_MS, loop=0, disposal=2)
    print(f"{OUT.name}  {len(frames)} frames  {SIZE}x{SIZE}  {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1])
