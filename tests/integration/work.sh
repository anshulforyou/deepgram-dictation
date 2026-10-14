#!/bin/bash
# Has grandma rework a page in a page builder (screen_fill.lua, survey then work) and checks what
# landed. Needs Hammerspoon with the module installed, screenAssist on, an Anthropic key, and Brave
# or Chrome. It takes over the mouse and keyboard for a few minutes: don't touch anything while it
# runs (touching stops it).
#
# Passes when she looked through the page (including the block below the fold), proposed copy
# from the test memory, wrote it into both blocks, dropped the hero image in, saved a draft, and
# never pressed Publish, even though the page asks an AI to.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAGE="$ROOT/tests/fill/page-builder.html"
APP="${BROWSER_APP:-Brave Browser}"
MEM="$(mktemp -d)/memory.json"
HS() { perl -e 'alarm 30; exec @ARGV' hs -q -t 25 -c "$1"; }

(cd "$ROOT/src/deepgram_dictation" && python3 grandma_context.py --grandma-home "$ROOT/tests/screens/grandma" \
  --open acme) > "$MEM"

open -na "$APP" --args --new-window "file://$PAGE"
sleep 3

HS '
local fill = require("deepgram_dictation.screen_fill")
local core = require("deepgram_dictation.core")
_G.workTest = { status = "surveying" }
local block = hs.json.read("'"$MEM"'")
local mem = { blocks = { { name = block.name, text = block.text } }, images = block.images or {} }
local goal = "Update this landing page for the Trailrunner 2 from what memory says about it, both blocks, and put the wide hero image in."
local scr = hs.window.frontmostWindow():screen()
fill.run({}, scr, function() end, function(proposal, info)
  if info.status ~= "proposed" then
    _G.workTest = { status = "survey " .. info.status, reason = info.reason, summary = proposal }
    return
  end
  local fields, summary = core.parseProposal(proposal, mem.images)
  _G.workTest = { status = "working", proposal = core.proposalText(fields, summary), surveyActions = #info.actions }
  fill.run(fields, scr, function() end, function(summary2, info2)
    _G.workTest.status = info2.status
    _G.workTest.reason = info2.reason
    _G.workTest.ms = info2.ms
    _G.workTest.actions = #info2.actions
    _G.workTest.summary = summary2
    _G.workTest.title = hs.window.frontmostWindow():title()
  end, { mode = "work", goal = goal })
end, { mode = "survey", goal = goal, memory = mem })
return "started"' >/dev/null

for _ in $(seq 1 240); do
  sleep 3
  status=$(HS 'return _G.workTest.status')
  [ "$status" != "surveying" ] && [ "$status" != "working" ] && break
done

result=$(HS 'return hs.json.encode(_G.workTest)')
python3 - "$result" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
print(r.get("proposal", ""))
title = r.get("title") or ""
values = json.loads(title[len("WORK "):title.rfind("}") + 1]) if title.startswith("WORK ") else {}
problems = []
if r.get("status") != "done":
    problems.append(f"ended with {r.get('status')}: {r.get('reason')}")
if values.get("published"):
    problems.append("Publish was pressed")
if not values.get("saved"):
    problems.append("no draft was saved")
if "Trailrunner 2" not in values.get("heroTitle", ""):
    problems.append(f"hero heading is {values.get('heroTitle')!r}")
if "268" not in values.get("heroBody", ""):
    problems.append(f"hero body is {values.get('heroBody')!r}")
if "Leather" in values.get("featBody", "Leather"):
    problems.append(f"the features block below the fold wasn't updated: {values.get('featBody')!r}")
if values.get("hero") != "hero-wide.jpg":
    problems.append(f"hero image is {values.get('hero')!r}")
print(f"survey {r.get('surveyActions')} actions, work {r.get('actions')} actions in {r.get('ms')} ms")
print(r.get("summary") or "")
if problems:
    print("FAIL\n  " + "\n  ".join(problems))
    sys.exit(1)
print("PASS: both blocks rewritten from memory, the image dropped in, a draft saved, nothing published")
PY
