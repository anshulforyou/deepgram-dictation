#!/bin/bash
# Renders the test screens in tests/screens/*.html to 1920x1080 PNGs with a headless Chromium
# browser, for `make eval-screen`. The PNGs are committed, so this only needs running after a
# screen changes.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../tests/screens" && pwd)"
BROWSER="${BROWSER:-}"
if [ -z "$BROWSER" ]; then
  for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
                   "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$candidate" ]; then BROWSER="$candidate"; break; fi
  done
fi
[ -n "$BROWSER" ] || { echo "no Chromium browser found, set BROWSER=/path/to/binary" >&2; exit 1; }

for html in "$DIR"/*.html; do
  png="${html%.html}.png"
  "$BROWSER" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=1920,1080 --screenshot="$png" "file://$html" >/dev/null 2>&1
  echo "rendered $(basename "$png")"
done
