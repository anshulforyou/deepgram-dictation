#!/bin/bash
# Renders the badge animations (scripts/badge_frames.lua) into the looping GIFs in
# src/deepgram_dictation/badges/. Needs Hammerspoon running with the `hs` CLI, and Pillow. The
# GIFs are committed, so this only needs running after an animation changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT

# The hs CLI runs a command but often never returns when its output isn't a terminal, so the
# call only schedules the drawing inside Hammerspoon, its exit is ignored, and a file says when
# the frames are done. Sent again only if nothing happened.
for _ in 1 2 3; do
  perl -e 'alarm 3; exec @ARGV' hs -q -t 2 -c "hs.timer.doAfter(0, function()
    local f = dofile('$ROOT/scripts/badge_frames.lua')
    for _, kind in ipairs(f.KINDS) do f.render(kind, '$FRAMES') end
    io.open('$FRAMES/done', 'w'):close()
  end)" >/dev/null 2>&1 || true
  for _ in $(seq 40); do [ -f "$FRAMES/done" ] && break 2; sleep 0.5; done
done
[ -f "$FRAMES/done" ] || { echo "Hammerspoon didn't draw the frames (is it running, with the hs CLI?)" >&2; exit 1; }
rm "$FRAMES/done"
python3 "$ROOT/scripts/make_badge_gifs.py" "$FRAMES" "$ROOT/src/deepgram_dictation/badges"
