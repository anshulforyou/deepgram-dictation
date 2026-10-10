#!/usr/bin/env bash
# Builds DeepgramRecorder.app into the given directory (default: recorder/build).
# Skips the build when the sources are unchanged, because every rebuild changes the ad-hoc
# signature and makes macOS ask for Microphone / System Audio permission again.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SRC_DIR/build}"
APP="$OUT_DIR/DeepgramRecorder.app"
STAMP="$APP/Contents/Resources/source.sha256"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

HASH="$(cat "$SRC_DIR/main.swift" "$SRC_DIR/Logic.swift" "$SRC_DIR/Info.plist" | shasum -a 256 | cut -d' ' -f1)"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "DeepgramRecorder.app is up to date"
  exit 0
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.2" \
  -o "$APP/Contents/MacOS/DeepgramRecorder" "$SRC_DIR/main.swift" "$SRC_DIR/Logic.swift"
echo "$HASH" > "$STAMP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || { echo "codesign failed" >&2; exit 1; }
echo "Built $APP"
