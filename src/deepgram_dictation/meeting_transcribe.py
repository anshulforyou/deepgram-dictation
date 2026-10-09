#!/usr/bin/env python3
"""Transcribe a DeepgramRecorder meeting session into a Markdown transcript.

    meeting_transcribe.py SESSION_DIR --output-dir DIR [options]

Reads SESSION_DIR/status.json, mic.m4a and (for online meetings) system.m4a, sends each track to
Deepgram with speaker diarization, merges them on one timeline, and writes a Markdown file.
Prints one JSON line: {"path": ..., "words": N, "speakers": [...]} or {"error": ...}.

Deepgram responses are cached in the session dir, so re-running after a failure later in the
pipeline does not pay for the audio twice. Uses only the Python standard library.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API_URL = "https://api.deepgram.com/v1/listen"
TRACKS = ("mic", "system")
ECHO_WINDOW = 2.0       # seconds around a mic utterance to look for the same words on system audio
ECHO_OVERLAP = 0.6      # fraction of a mic utterance's words that must appear in system audio
MERGE_GAP = 2.0         # merge consecutive same-speaker utterances closer than this (seconds)
MIN_TRACK_BYTES = 2048  # smaller files contain no usable audio


class TranscribeError(Exception):
    pass


# ---------------------------------------------------------------------------- Deepgram

def build_url(model, language, keyterms=()):
    params = [
        ("model", model),
        ("language", language),
        ("smart_format", "true"),
        ("punctuate", "true"),
        ("diarize", "true"),
        ("utterances", "true"),
    ]
    params += [("keyterm", term) for term in keyterms]
    return API_URL + "?" + urllib.parse.urlencode(params, quote_via=urllib.parse.quote)


def read_api_key(keychain_name):
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", keychain_name, "-w"],
            check=True, capture_output=True, text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        raise TranscribeError(f"Deepgram API key not found in Keychain ('{keychain_name}')")
    return out.stdout.strip()


def post_audio(path, url, api_key, timeout=900):
    """Streams an audio file to Deepgram and returns the decoded JSON response."""
    size = path.stat().st_size
    with path.open("rb") as body:
        request = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": f"Token {api_key}",
            "Content-Type": "audio/mp4",
            "Content-Length": str(size),
        })
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            raise TranscribeError(f"Deepgram error {e.code}: {detail}")
        except urllib.error.URLError as e:
            raise TranscribeError(f"Could not reach Deepgram: {e.reason}")


def transcribe_track(session_dir, track, url, api_key):
    """Returns the Deepgram response for a track, using the cached copy if present."""
    cache = session_dir / f"deepgram-{track}.json"
    if cache.exists():
        return json.loads(cache.read_text())
    resp = post_audio(session_dir / f"{track}.m4a", url, api_key)
    cache.write_text(json.dumps(resp))
    return resp


# ---------------------------------------------------------------------------- transcript logic

def utterances_from_response(resp, track, offset=0.0):
    """Flattens Deepgram utterances into dicts on the shared session timeline."""
    out = []
    for u in (resp.get("results") or {}).get("utterances") or []:
        text = (u.get("transcript") or "").strip()
        if not text:
            continue
        out.append({
            "track": track,
            "speaker": u.get("speaker", 0),
            "start": float(u.get("start", 0)) + offset,
            "end": float(u.get("end", 0)) + offset,
            "text": text,
        })
    return out


def _words(text):
    return set(re.findall(r"[\w']+", text.lower()))


def drop_echo(mic, system):
    """Removes mic utterances that are just the speakers' playback of remote participants
    (happens when not wearing headphones): same words on system audio at the same time."""
    kept = []
    for m in mic:
        mic_words = _words(m["text"])
        nearby = set()
        for s in system:
            if s["end"] >= m["start"] - ECHO_WINDOW and s["start"] <= m["end"] + ECHO_WINDOW:
                nearby |= _words(s["text"])
        if mic_words and len(mic_words & nearby) / len(mic_words) >= ECHO_OVERLAP:
            continue
        kept.append(m)
    return kept


def label_speakers(utterances, online):
    """Assigns display names. Online: the mic is "Me", remote people are "Speaker N".
    In person: everyone on the mic is "Speaker N". Numbered by first appearance."""
    names = {}
    for u in sorted(utterances, key=lambda u: u["start"]):
        if online and u["track"] == "mic":
            u["label"] = "Me"
            continue
        key = (u["track"], u["speaker"])
        if key not in names:
            names[key] = f"Speaker {len(names) + 1}"
        u["label"] = names[key]
    return utterances


def merge_consecutive(utterances, max_gap=MERGE_GAP):
    merged = []
    for u in sorted(utterances, key=lambda u: u["start"]):
        prev = merged[-1] if merged else None
        if prev and prev["label"] == u["label"] and u["start"] - prev["end"] <= max_gap:
            prev["text"] += " " + u["text"]
            prev["end"] = max(prev["end"], u["end"])
        else:
            merged.append(dict(u))
    return merged


def format_timestamp(seconds):
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def speakers_in_order(utterances):
    seen = []
    for u in utterances:
        if u["label"] not in seen:
            seen.append(u["label"])
    return seen


def render_markdown(utterances, started_at, duration, online, notes=()):
    lines = [
        f"# Meeting transcript: {started_at.strftime('%a %-d %b %Y, %H:%M')}",
        "",
        f"- **Duration:** {format_timestamp(duration)}",
        f"- **Recorded:** {'microphone + computer audio' if online else 'microphone (in person)'}",
    ]
    speakers = speakers_in_order(utterances)
    if speakers:
        lines.append(f"- **Speakers:** {', '.join(speakers)}")
    lines.append("")
    for note in notes:
        lines += [f"> {note}", ""]
    lines += ["---", ""]
    if not utterances:
        lines += ["_No speech detected._", ""]
    for u in utterances:
        lines += [f"**{u['label']}** · {format_timestamp(u['start'])}", u["text"], ""]
    return "\n".join(lines)


def transcript_path(output_dir, started_at):
    base = started_at.strftime("%Y-%m-%d %H-%M") + " Meeting"
    path = output_dir / f"{base}.md"
    n = 2
    while path.exists():
        path = output_dir / f"{base} ({n}).md"
        n += 1
    return path


# ---------------------------------------------------------------------------- pipeline

def load_keyterms(dictionary_path):
    if not dictionary_path or not Path(dictionary_path).exists():
        return []
    try:
        data = json.loads(Path(dictionary_path).read_text())
    except ValueError:
        return []
    return [t for t in data.get("keyterms", []) if isinstance(t, str) and t.strip()]


def parse_started_at(status):
    raw = status.get("startedAt")
    if raw:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
    return datetime.now(timezone.utc).astimezone()


def run(session_dir, output_dir, model, language, keychain_name, dictionary=None,
        keep_audio=False, api_key=None):
    status_file = session_dir / "status.json"
    if not status_file.exists():
        raise TranscribeError(f"No recording found in {session_dir}")
    status = json.loads(status_file.read_text())
    online = bool(status.get("captureSystem"))

    tracks = [t for t in TRACKS
              if (session_dir / f"{t}.m4a").exists() and (session_dir / f"{t}.m4a").stat().st_size >= MIN_TRACK_BYTES]
    if "mic" not in tracks and "system" not in tracks:
        raise TranscribeError("The recording contains no audio")

    url = build_url(model, language, load_keyterms(dictionary))
    by_track = {}
    for track in tracks:
        cached = (session_dir / f"deepgram-{track}.json").exists()
        if not cached and api_key is None:
            api_key = read_api_key(keychain_name)
        resp = transcribe_track(session_dir, track, url, api_key)
        by_track[track] = utterances_from_response(resp, track, status.get(f"{track}Offset") or 0.0)

    mic, system = by_track.get("mic", []), by_track.get("system", [])
    notes = list(status.get("warnings") or [])
    if online:
        mic = drop_echo(mic, system)
        if not system:
            notes.append("No speech was captured from computer audio. If others spoke over Zoom/Meet, check "
                         "that DeepgramRecorder is allowed under System Settings → Privacy & Security → "
                         "System Audio Recording Only.")

    utterances = merge_consecutive(label_speakers(mic + system, online))
    started_at = parse_started_at(status)
    markdown = render_markdown(utterances, started_at, status.get("duration") or 0, online, notes)

    output_dir.mkdir(parents=True, exist_ok=True)
    path = transcript_path(output_dir, started_at)
    path.write_text(markdown)

    if not keep_audio:
        for f in session_dir.iterdir():
            f.unlink()
        session_dir.rmdir()
    else:
        (session_dir / "transcript.txt").write_text(str(path))

    return {
        "path": str(path),
        "words": sum(len(u["text"].split()) for u in utterances),
        "speakers": speakers_in_order(utterances),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("session_dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model", default="nova-3")
    parser.add_argument("--language", default="en")
    parser.add_argument("--keychain-name", default="deepgram-api-key")
    parser.add_argument("--dictionary", type=Path)
    parser.add_argument("--keep-audio", action="store_true")
    args = parser.parse_args(argv)

    try:
        result = run(args.session_dir, args.output_dir.expanduser(), args.model, args.language,
                     args.keychain_name, args.dictionary, args.keep_audio)
    except TranscribeError as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
