#!/usr/bin/env bash
# Compiles and runs the recorder's unit tests (recorder/Tests) against recorder/Logic.swift.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(mktemp -d)/recorder-tests"
trap 'rm -rf "$(dirname "$BIN")"' EXIT

xcrun swiftc -swift-version 5 -o "$BIN" "$SRC_DIR/Logic.swift" "$SRC_DIR/Tests/main.swift"
"$BIN"
