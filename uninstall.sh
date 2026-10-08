#!/usr/bin/env bash
# Removes deepgram-dictation from Hammerspoon. Keeps your dictionary file and Keychain entry
# unless --purge is given. Does not uninstall Hammerspoon or sox.
set -euo pipefail

HS_DIR="${HAMMERSPOON_DIR:-$HOME/.hammerspoon}"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

rm -rf "$HS_DIR/deepgram_dictation"

if [[ -f "$HS_DIR/init.lua" ]]; then
  # Drop the block install.sh appended: from the marker comment through the closing "})".
  awk '
    /^-- deepgram-dictation/ { skip = 1; next }
    skip && /^}\)/           { skip = 0; next }
    !skip
  ' "$HS_DIR/init.lua" > "$HS_DIR/init.lua.tmp"
  mv "$HS_DIR/init.lua.tmp" "$HS_DIR/init.lua"
fi

if [[ $PURGE -eq 1 ]]; then
  rm -f "$HS_DIR/deepgram-dictionary.json"
  security delete-generic-password -s deepgram-api-key >/dev/null 2>&1 || true
  echo "Removed module, dictionary and API key."
else
  echo "Removed module. Kept $HS_DIR/deepgram-dictionary.json and the Keychain API key (use --purge to remove)."
fi
