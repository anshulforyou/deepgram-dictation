#!/usr/bin/env bash
# Manual integration test (needs a Mac with Hammerspoon running and microphone permission; not
# run in CI). Reproduces the bug where recording an online meeting knocked out the call app's
# microphone:
#   1. a simulated call app holds the default mic in voice-processing mode (like Meet/Zoom),
#   2. DeepgramRecorder records an online meeting at the same time,
#   3. checks the call app still received real audio, our mic track isn't digital silence
#      (a call app switches the mic to multi-channel, which once made our recording all zeros),
#      the computer-audio track is complete and has sound (online mode), and DeepgramRecorder's
#      CPU use stays low.
# Run it with your usual mic (built-in, then AirPods) selected as the input.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${RECORDER_APP:-$HOME/Library/Application Support/deepgram-dictation/DeepgramRecorder.app}"
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
WORK="$(mktemp -d)"
trap 'pkill -INT -f "DeepgramRecorder --out $WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
MAX_CPU="${MAX_CPU:-10}"   # % of one core
PLAY_AUDIO="${PLAY_AUDIO:-1}" # play speech so the computer-audio path is busy, as in a real call

xcrun swiftc -O -swift-version 5 -o "$WORK/callsim" "$REPO/tests/integration/callsim.swift"

# Run the call simulator from Hammerspoon so it gets Hammerspoon's microphone permission.
for attempt in 1 2; do  # Hammerspoon's CLI link is occasionally flaky
  timeout 6 "$HS" -q -t 4 -c "
    hs.task.new('$WORK/callsim', function(_, out) local f = io.open('$WORK/callsim.json', 'w') f:write(out) f:close() end,
      { '20' }):start()
    return 'ok'" >/dev/null && break
  [[ $attempt == 2 ]] && { echo "FAIL: could not reach Hammerspoon"; exit 1; }
  sleep 2
done
sleep 3
recorder_args=(--out "$WORK/session")
[[ "${SYSTEM_AUDIO:-1}" == 1 ]] && recorder_args+=(--system)  # SYSTEM_AUDIO=0 tests an in-person recording
open -n -a "$APP" --args "${recorder_args[@]}"
for _ in $(seq 1 40); do grep -q '"recording"' "$WORK/session/status.json" 2>/dev/null && break; sleep 0.25; done

if [[ "$PLAY_AUDIO" == 1 ]]; then
  say -r 160 "This is the remote participant speaking during the test call. We are checking that recording \
the meeting does not interfere with the call app and does not use too much processor time." &
fi
cpu_samples=()
for _ in $(seq 1 12); do
  sleep 1
  cpu_samples+=("$(ps -o pcpu= -p "$(cat "$WORK/session/recorder.pid")" | tr -d ' ')")
done
kill -INT "$(cat "$WORK/session/recorder.pid")"
for _ in $(seq 1 40); do [[ -f "$WORK/callsim.json" ]] && break; sleep 0.25; done
sleep 1

fail=0
call_zero=$(python3 -c "import json; print(json.load(open('$WORK/callsim.json'))['zeroFraction'])")
ffmpeg -v error -y -i "$WORK/session/mic.m4a" -ac 1 -ar 16000 "$WORK/mic.wav"
ours_zero=$(python3 - "$WORK/mic.wav" <<'PY'
import sys, wave, struct
w = wave.open(sys.argv[1]); n = w.getnframes(); s = struct.unpack("<%dh" % n, w.readframes(n))[16000:]
print(sum(1 for x in s if x == 0) / max(1, len(s)))
PY
)
system_check="skipped"
if [[ "${SYSTEM_AUDIO:-1}" == 1 && "$PLAY_AUDIO" == 1 ]]; then
  ffmpeg -v error -y -i "$WORK/session/system.m4a" -ac 1 -ar 16000 "$WORK/system.wav"
  system_check=$(python3 - "$WORK/system.wav" "$WORK/session/status.json" <<'PY'
import sys, wave, struct, json, math
w = wave.open(sys.argv[1]); n = w.getnframes(); s = struct.unpack("<%dh" % n, w.readframes(n))
recorded = json.load(open(sys.argv[2]))["duration"]
peak = max((abs(x) for x in s), default=0) / 32768
ok = n / 16000 >= recorded * 0.8 and peak > 0.01
print("%s (%.1fs of %.1fs, peak %.3f)" % ("ok" if ok else "BAD", n / 16000, recorded, peak))
PY
)
fi
avg_cpu=$(printf '%s\n' "${cpu_samples[@]}" | awk '{s+=$1} END {printf "%.1f", s/NR}')
warnings=$(python3 -c "import json; print(json.load(open('$WORK/session/status.json')).get('warnings', []))")

echo "call app silence:      $call_zero   (must stay < 0.95)"
echo "our mic silence:       $ours_zero   (must stay < 0.95)"
echo "computer audio track:  $system_check"
echo "recorder CPU (avg %):  $avg_cpu    (must stay < $MAX_CPU)"
echo "warnings:              $warnings"
python3 -c "import sys; sys.exit(0 if $call_zero < 0.95 else 1)" || { echo "FAIL: recording knocked out the call app's mic"; fail=1; }
python3 -c "import sys; sys.exit(0 if $ours_zero < 0.95 else 1)" || { echo "FAIL: our mic track is silent"; fail=1; }
[[ "$system_check" != BAD* ]] || { echo "FAIL: computer audio track is incomplete or silent"; fail=1; }
python3 -c "import sys; sys.exit(0 if $avg_cpu < $MAX_CPU else 1)" || { echo "FAIL: recorder CPU too high"; fail=1; }
[[ $fail -eq 0 ]] && echo "PASS"
exit $fail
