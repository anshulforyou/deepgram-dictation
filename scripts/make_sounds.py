"""Builds grandma's sounds into src/deepgram_dictation/sounds/: soft music-box notes and wooden
knitting-needle clicks, quiet and short so they never get in the way.

  python3 scripts/make_sounds.py

Standard library only. The WAVs are committed, so this only runs when a sound is changed."""

import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation" / "sounds"

# Notes (Hz), a warm register around the middle of the piano.
C5, D5, E5, G5, A4, G4, C4 = 523.25, 587.33, 659.25, 783.99, 440.0, 392.0, 261.63


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def note(freq, seconds, level=1.0, decay=7.0):
    """A music-box note: a sine with a faint octave and twelfth, a 6 ms attack and an
    exponential decay, so it rings softly rather than beeps."""
    out = []
    n = int(RATE * seconds)
    attack = int(RATE * 0.006)
    for i in range(n):
        t = i / RATE
        env = min(1.0, i / attack) * math.exp(-decay * t)
        tail = min(1.0, (n - i) / (RATE * 0.02))  # no click at the end
        s = (math.sin(2 * math.pi * freq * t)
             + 0.18 * math.sin(2 * math.pi * freq * 2 * t)
             + 0.06 * math.sin(2 * math.pi * freq * 3 * t))
        out.append(level * env * tail * s / 1.24)
    return out


def click(level=1.0, pitch=2200.0, seconds=0.035, seed=1):
    """A wooden needle tap: a short noise burst through a damped resonance."""
    rng = random.Random(seed)
    out = []
    n = int(RATE * seconds)
    for i in range(n):
        t = i / RATE
        env = math.exp(-140 * t)
        noise = rng.uniform(-1, 1) * math.exp(-400 * t)
        tone = math.sin(2 * math.pi * pitch * t) * env
        out.append(level * (0.55 * tone + 0.45 * noise))
    return out


def mix(*parts):
    """Lays (offset_seconds, samples) parts over each other."""
    length = max(int(RATE * off) + len(s) for off, s in parts)
    out = [0.0] * length
    for off, s in parts:
        start = int(RATE * off)
        for i, v in enumerate(s):
            out[start + i] += v
    return out


def write(name, samples, peak):
    """Writes 16-bit mono, normalised to `peak` of full scale."""
    top = max(abs(v) for v in samples) or 1.0
    frames = b"".join(struct.pack("<h", int(v / top * peak * 32767)) for v in samples)
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


SOUNDS = {
    # Fn+Control: grandma looks up. Two notes rising.
    "ask": (mix((0, note(C5, 0.35, decay=9)), (0.09, note(G5, 0.45, decay=8))), 0.5),
    # While she thinks: two needles tapping, knit-knit.
    "think": (mix((0, click(pitch=2100, seed=3)), (0.11, click(0.7, pitch=1800, seed=4))), 0.32),
    # An answer in the panel: a warm chime.
    "answer": (mix((0, note(E5, 0.7, decay=5)), (0.0, note(C5, 0.7, 0.5, decay=5))), 0.45),
    # Text pasted at the cursor: one soft high note.
    "insert": (note(G5, 0.25, decay=14), 0.4),
    # A fill starts: one needle tap.
    "fill": (click(pitch=2000, seed=5), 0.4),
    # A fill is done, or a meeting is saved: three notes settling down.
    "done": (mix((0, note(G5, 0.4, 0.8, decay=8)), (0.1, note(E5, 0.4, 0.8, decay=8)),
                 (0.2, note(C5, 0.6, decay=6))), 0.45),
    # "Grandma, remember ...": a low warm note.
    "noted": (mix((0, note(A4, 0.6, decay=6)), (0.0, note(E5, 0.6, 0.25, decay=6))), 0.45),
    # Something went wrong: two notes falling, low.
    "error": (mix((0, note(D5, 0.3, decay=10)), (0.13, note(A4, 0.5, decay=7))), 0.45),
    # A meeting starts recording.
    "record": (mix((0, note(G4, 0.4, decay=8)), (0.1, note(C5, 0.6, decay=6))), 0.45),
    # Plain dictation, on press and on paste (off unless dictationSounds is set): barely there.
    "tick": (click(0.8, pitch=2600, seconds=0.02, seed=7), 0.22),
}


def main():
    for name, (samples, peak) in SOUNDS.items():
        write(name, samples + silence(0.01), peak)
        print(f"{name}.wav  {len(samples) / RATE:.2f}s")


if __name__ == "__main__":
    main()
