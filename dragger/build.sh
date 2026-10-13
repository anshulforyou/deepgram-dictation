#!/usr/bin/env bash
# Builds GrandmaDrag (drag and drop for form uploads) into the given directory (default:
# dragger/build). Skips the build when the source is unchanged. Kept apart from
# DeepgramRecorder.app so changing it never re-signs the recorder, which would make macOS ask for
# microphone permission again.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SRC_DIR/build}"
BIN="$OUT_DIR/GrandmaDrag"
STAMP="$OUT_DIR/GrandmaDrag.sha256"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

HASH="$(shasum -a 256 "$SRC_DIR/main.swift" | cut -d' ' -f1)"
if [[ -x "$BIN" && -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "GrandmaDrag is up to date"
  exit 0
fi

mkdir -p "$OUT_DIR"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.2" -o "$BIN" "$SRC_DIR/main.swift"
codesign --force --sign - "$BIN" >/dev/null 2>&1 || { echo "codesign failed" >&2; exit 1; }
echo "$HASH" > "$STAMP"
echo "Built $BIN"
