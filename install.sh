#!/usr/bin/env bash
# Installs deepgram-dictation into Hammerspoon. Safe to re-run: it upgrades the module and
# leaves your dictionary, API key and other Hammerspoon config untouched.
#
#   ./install.sh            install dependencies (Homebrew), module, and prompt for API key
#   ./install.sh --no-deps  skip Homebrew installs (Hammerspoon and sox must already exist)
#
# HAMMERSPOON_DIR overrides the target directory (default ~/.hammerspoon).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="${HAMMERSPOON_DIR:-$HOME/.hammerspoon}"
KEYCHAIN_SERVICE="deepgram-api-key"
MARKER="-- deepgram-dictation"
INSTALL_DEPS=1

for arg in "$@"; do
  case "$arg" in
    --no-deps) INSTALL_DEPS=0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

if [[ "$(uname)" != "Darwin" ]]; then
  echo "deepgram-dictation only supports macOS." >&2
  exit 1
fi

if [[ $INSTALL_DEPS -eq 1 ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required: https://brew.sh (or re-run with --no-deps)." >&2
    exit 1
  fi
  if [[ ! -d /Applications/Hammerspoon.app ]]; then
    say "Installing Hammerspoon"
    brew install --cask hammerspoon
  fi
  if ! command -v rec >/dev/null 2>&1; then
    say "Installing sox (audio recording)"
    brew install sox
  fi
fi

say "Installing module into $HS_DIR"
mkdir -p "$HS_DIR"
rm -rf "$HS_DIR/deepgram_dictation"
cp -R "$REPO_DIR/src/deepgram_dictation" "$HS_DIR/deepgram_dictation"

if [[ ! -f "$HS_DIR/deepgram-dictionary.json" ]]; then
  cp "$REPO_DIR/dictionary.example.json" "$HS_DIR/deepgram-dictionary.json"
  say "Created $HS_DIR/deepgram-dictionary.json (edit it to add your own words)"
fi

if ! grep -qF -e "$MARKER" "$HS_DIR/init.lua" 2>/dev/null; then
  cat >> "$HS_DIR/init.lua" <<'EOF'

-- deepgram-dictation (https://github.com/anshulforyou/deepgram-dictation)
deepgramDictation = require("deepgram_dictation")
deepgramDictation.start({
  -- hotkey = "fn",        -- or "rightOption", "rightCommand", "rightControl", "rightShift"
  -- language = "en",      -- or "multi" for mixed-language speech
})
EOF
  say "Added deepgram-dictation to $HS_DIR/init.lua"
fi

if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  say "Deepgram API key already in Keychain"
elif [[ -t 0 ]]; then
  say "Paste your Deepgram API key (input hidden; get one at https://console.deepgram.com)"
  security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w
else
  say "No API key found. Add it later with:"
  echo "    security add-generic-password -s $KEYCHAIN_SERVICE -a \"\$USER\" -w"
fi

if [[ -z "${HAMMERSPOON_DIR:-}" ]]; then
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    say "Hammerspoon is running: click its menu bar icon → Reload Config to apply changes"
  else
    open -a Hammerspoon || true
  fi
fi

cat <<EOF

Done. Next steps:
  1. System Settings → Privacy & Security → Accessibility: enable Hammerspoon.
     (If it was already on, quit and reopen Hammerspoon.)
  2. Hold Fn, speak, release. Allow microphone access the first time.
  3. System Settings → Keyboard → "Press 🌐 key to": set to "Do Nothing".
EOF
