#!/usr/bin/env bash
# Smoke test for install.sh / uninstall.sh against a throwaway Hammerspoon directory.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAMMERSPOON_DIR="$(mktemp -d)"
export HAMMERSPOON_DIR
trap 'rm -rf "$HAMMERSPOON_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo 'print("existing config")' > "$HAMMERSPOON_DIR/init.lua"
echo '{"keyterms":["Mine"],"replacements":[]}' > "$HAMMERSPOON_DIR/deepgram-dictionary.json"

"$REPO_DIR/install.sh" --no-deps < /dev/null > /dev/null
"$REPO_DIR/install.sh" --no-deps < /dev/null > /dev/null  # idempotent

[[ -f "$HAMMERSPOON_DIR/deepgram_dictation/init.lua" ]] || fail "module not installed"
[[ -f "$HAMMERSPOON_DIR/deepgram_dictation/core.lua" ]] || fail "core not installed"
grep -q '"Mine"' "$HAMMERSPOON_DIR/deepgram-dictionary.json" || fail "existing dictionary overwritten"
grep -q 'existing config' "$HAMMERSPOON_DIR/init.lua" || fail "existing init.lua lost"
[[ $(grep -c 'require("deepgram_dictation")' "$HAMMERSPOON_DIR/init.lua") -eq 1 ]] || fail "init block not added exactly once"

"$REPO_DIR/uninstall.sh" > /dev/null

[[ ! -e "$HAMMERSPOON_DIR/deepgram_dictation" ]] || fail "module not removed"
! grep -q 'deepgram' "$HAMMERSPOON_DIR/init.lua" || fail "init block not removed"
grep -q 'existing config' "$HAMMERSPOON_DIR/init.lua" || fail "uninstall removed unrelated config"
[[ -f "$HAMMERSPOON_DIR/deepgram-dictionary.json" ]] || fail "dictionary removed without --purge"

echo "install/uninstall smoke test passed"
