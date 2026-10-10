#!/usr/bin/env python3
"""Transcribe a DeepgramRecorder meeting session into a Markdown transcript.

    meeting_transcribe.py SESSION_DIR --output-dir DIR [options]

Reads SESSION_DIR/status.json, mic.m4a and (for online meetings) system.m4a, sends each track to
Deepgram with speaker diarization, merges them on one timeline, and writes a Markdown file.
With --organize-with-claude, Claude files it into a topic folder (see meeting_organize.py).
Prints one JSON line: {"path": ..., "words": N, "speakers": [...], "folder": ...} or {"error": ...}.

Deepgram responses are cached in the session dir, so re-running after a failure later in the
pipeline does not pay for the audio twice. Uses only the Python standard library.
"""

import argparse
import bisect
import json
import re
import statistics
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import meeting_organize

API_URL = "https://api.deepgram.com/v1/listen"
TRACKS = ("mic", "system")
ECHO_WINDOW = 3.0       # seconds around a mic utterance to look for the same words on system audio
ECHO_OVERLAP = 0.6      # fraction of a mic utterance's words that must appear in system audio
MERGE_GAP = 2.0         # merge consecutive same-speaker utterances closer than this (seconds)
MIN_TRACK_BYTES = 2048  # smaller files contain no usable audio
ALIGN_NGRAM = 4         # words in a row that must match to count as the mic hearing the speakers
ALIGN_MIN_MATCHES = 20  # fewer matches than this: no echo to align on (e.g. headphones)
ALIGN_WINDOW = 180.0    # seconds either side of an utterance whose matches set its correction
FEW_REMOTE_WORDS = 0.03 # computer audio with fewer words than this share of the mic's is suspect


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


def words_from_response(resp, offset=0.0):
    """[(word, start)] on the session timeline, lowercased and without punctuation."""
    channels = (resp.get("results") or {}).get("channels") or [{}]
    words = ((channels[0].get("alternatives") or [{}])[0]).get("words") or []
    out = []
    for w in words:
        token = re.sub(r"[^\w']", "", (w.get("punctuated_word") or w.get("word") or "").lower())
        if token:
            out.append((token, float(w.get("start", 0)) + offset))
    return out


def echo_lags(mic_words, system_words, n=ALIGN_NGRAM):
    """[(system time, lag)] wherever the mic heard the speakers play the same run of `n` words
    that appears exactly once in each track; lag = mic time - system time."""
    def unique_ngrams(words):
        seen = {}
        for i in range(len(words) - n + 1):
            key = tuple(w for w, _ in words[i:i + n])
            seen[key] = None if key in seen else words[i][1]
        return {k: t for k, t in seen.items() if t is not None}

    on_mic = unique_ngrams(mic_words)
    return sorted((t, on_mic[k] - t) for k, t in unique_ngrams(system_words).items() if k in on_mic)


def align_to_mic(system, lags, window=ALIGN_WINDOW):
    """Shifts computer-audio utterances onto the mic's timeline using the echo the mic picked
    up. Undoes drift between the tracks (e.g. the system audio tap skipping time), which would
    otherwise break echo removal and the order of turns. Without enough echo, returns `system`
    unchanged."""
    if len(lags) < ALIGN_MIN_MATCHES:
        return system
    times = [t for t, _ in lags]
    out = []
    for u in system:
        lo = bisect.bisect_left(times, u["start"] - window)
        hi = bisect.bisect_right(times, u["start"] + window)
        if lo == hi:  # no echo nearby: use the closest matches
            i = bisect.bisect_left(times, u["start"])
            lo, hi = max(0, i - ALIGN_MIN_MATCHES), min(len(times), i + ALIGN_MIN_MATCHES)
        shift = statistics.median(lag for _, lag in lags[lo:hi])
        out.append({**u, "start": u["start"] + shift, "end": u["end"] + shift})
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


def word_count(utterances):
    return sum(len(u["text"].split()) for u in utterances)


def recording_notes(status, mic, system, online):
    """Notes shown at the top of the transcript: recorder warnings, pauses, and computer audio
    that captured nothing (or almost nothing) in an online meeting."""
    notes = list(status.get("warnings") or [])
    paused = status.get("pausedSeconds") or 0
    if paused >= 1:
        notes.append(f"Recording was paused for {format_timestamp(paused)}; that part isn't in the transcript.")
    if online:
        mic_words, system_words = word_count(mic), word_count(system)
        if not system:
            notes.append("No speech was captured from computer audio. If others spoke over Zoom/Meet, check "
                         "that DeepgramRecorder is allowed under System Settings → Privacy & Security → "
                         "System Audio Recording Only.")
        elif mic_words >= 100 and system_words < FEW_REMOTE_WORDS * mic_words:
            notes.append(f"Computer audio captured only {system_words} word{'s' if system_words != 1 else ''} "
                         f"against {mic_words} from your microphone, so other participants' speech is "
                         "probably missing.")
    return notes


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


def render_markdown(utterances, started_at, duration, online, notes=(), title=None, summary=None,
                    action_items=()):
    lines = [
        f"# {title or 'Meeting transcript'}",
        "",
        f"- **Date:** {started_at.strftime('%a %-d %b %Y, %H:%M')}",
        f"- **Duration:** {format_timestamp(duration)}",
        f"- **Recorded:** {'microphone + computer audio' if online else 'microphone (in person)'}",
    ]
    speakers = speakers_in_order(utterances)
    if speakers:
        lines.append(f"- **Speakers:** {', '.join(speakers)}")
    lines.append("")
    for note in notes:
        lines += [f"> {note}", ""]
    if summary:
        lines += ["## Summary", "", summary, ""]
    if action_items:
        lines += ["## Action items", ""] + [f"- [ ] {item}" for item in action_items] + [""]
    lines += ["## Transcript", ""]
    if not utterances:
        lines += ["_No speech detected._", ""]
    for u in utterances:
        lines += [f"**{u['label']}** · {format_timestamp(u['start'])}", u["text"], ""]
    return "\n".join(lines)


def transcript_path(output_dir, started_at, title=None):
    base = started_at.strftime("%Y-%m-%d %H-%M") + " " + meeting_organize.safe_name(title, "Meeting")
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


def organize(utterances, output_dir, started_at, session_dir, claude_path, claude_model):
    """Asks Claude for folder, title, summary and action items. Returns (info, error)."""
    if not utterances:
        return None, None
    folders = meeting_organize.list_folders(output_dir)
    prompt = meeting_organize.build_prompt(utterances, folders, started_at)
    try:
        info = meeting_organize.run_claude(claude_path, prompt, cwd=session_dir, model=claude_model)
    except meeting_organize.OrganizeError as e:
        return None, str(e)
    info["folder"] = meeting_organize.resolve_folder(info["folder"], [name for name, _ in folders])
    return info, None


def run(session_dir, output_dir, model, language, keychain_name, dictionary=None,
        keep_audio=False, api_key=None, claude_path=None, claude_model=None):
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
    by_track, words_by_track = {}, {}
    for track in tracks:
        cached = (session_dir / f"deepgram-{track}.json").exists()
        if not cached and api_key is None:
            api_key = read_api_key(keychain_name)
        resp = transcribe_track(session_dir, track, url, api_key)
        offset = status.get(f"{track}Offset") or 0.0
        by_track[track] = utterances_from_response(resp, track, offset)
        words_by_track[track] = words_from_response(resp, offset)

    mic, system = by_track.get("mic", []), by_track.get("system", [])
    if online:
        system = align_to_mic(system, echo_lags(words_by_track.get("mic", []), words_by_track.get("system", [])))
        mic = drop_echo(mic, system)
    notes = recording_notes(status, mic, system, online)

    utterances = merge_consecutive(label_speakers(mic + system, online))
    started_at = parse_started_at(status)
    duration = status.get("duration") or 0

    info, organize_error = None, None
    if claude_path:
        info, organize_error = organize(utterances, output_dir, started_at, session_dir, claude_path, claude_model)
    info = info or {}

    markdown = render_markdown(utterances, started_at, duration, online, notes, title=info.get("title"),
                               summary=info.get("summary"), action_items=info.get("action_items", ()))
    dest_dir = output_dir / info["folder"] if info.get("folder") else output_dir
    dest_dir.mkdir(parents=True, exist_ok=True)
    path = transcript_path(dest_dir, started_at, info.get("title"))
    path.write_text(markdown)
    if info.get("folder"):
        meeting_organize.update_index(dest_dir, info["folder"], path, started_at, duration,
                                      info["title"], info["summary"])

    if not keep_audio:
        for f in session_dir.iterdir():
            f.unlink()
        session_dir.rmdir()
    else:
        (session_dir / "transcript.txt").write_text(str(path))

    result = {
        "path": str(path),
        "words": sum(len(u["text"].split()) for u in utterances),
        "speakers": speakers_in_order(utterances),
    }
    if info.get("folder"):
        result.update(folder=info["folder"], title=info["title"])
    if organize_error:
        result["organizeError"] = organize_error
    return result


def parse_transcript_markdown(text):
    """Reads back a transcript written by render_markdown: (started_at, duration, online, notes,
    utterances). Used to file a transcript that couldn't be organized when it was made."""
    date = re.search(r"^- \*\*Date:\*\* (.+)$", text, flags=re.M)
    if not date:
        raise TranscribeError("Not a deepgram-dictation transcript (no Date line)")
    started_at = datetime.strptime(date.group(1).strip(), "%a %d %b %Y, %H:%M")
    duration = 0
    match = re.search(r"^- \*\*Duration:\*\* ([\d:]+)$", text, flags=re.M)
    if match:
        for part in match.group(1).split(":"):
            duration = duration * 60 + int(part)
    online = "computer audio" in text.split("## Transcript", 1)[0]
    notes = re.findall(r"^> (.+)$", text.split("## Transcript", 1)[0], flags=re.M)
    utterances = []
    body = text.split("## Transcript", 1)[1] if "## Transcript" in text else ""
    for label, stamp, said in re.findall(r"^\*\*(.+?)\*\* · ([\d:]+)\n(.+)$", body, flags=re.M):
        seconds = 0
        for part in stamp.split(":"):
            seconds = seconds * 60 + int(part)
        utterances.append({"label": label, "start": float(seconds), "end": float(seconds), "text": said})
    return started_at, duration, online, notes, utterances


def refile(path, output_dir, claude_path, claude_model=None):
    """Files an existing, unorganized transcript with Claude: adds title, summary and action items,
    moves it into a topic folder and updates that folder's meetings.md."""
    started_at, duration, online, notes, utterances = parse_transcript_markdown(path.read_text())
    info, error = organize(utterances, output_dir, started_at, path.parent, claude_path, claude_model)
    if error or not info:
        raise TranscribeError(error or "Nothing to file: the transcript has no speech")
    markdown = render_markdown(utterances, started_at, duration, online, notes, title=info["title"],
                               summary=info["summary"], action_items=info["action_items"])
    dest_dir = output_dir / info["folder"]
    dest_dir.mkdir(parents=True, exist_ok=True)
    new_path = transcript_path(dest_dir, started_at, info["title"])
    new_path.write_text(markdown)
    meeting_organize.update_index(dest_dir, info["folder"], new_path, started_at, duration,
                                  info["title"], info["summary"])
    path.unlink()
    return {"path": str(new_path), "folder": info["folder"], "title": info["title"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("session_dir", type=Path, nargs="?")
    parser.add_argument("--refile", type=Path, metavar="TRANSCRIPT",
                        help="file an existing unorganized transcript (needs --organize-with-claude)")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model", default="nova-3")
    parser.add_argument("--language", default="en")
    parser.add_argument("--keychain-name", default="deepgram-api-key")
    parser.add_argument("--dictionary", type=Path)
    parser.add_argument("--keep-audio", action="store_true")
    parser.add_argument("--organize-with-claude", metavar="CLAUDE_PATH", type=Path,
                        help="file the transcript into a topic folder using this `claude` CLI")
    parser.add_argument("--claude-model")
    args = parser.parse_args(argv)

    if args.refile:
        if not args.organize_with_claude:
            parser.error("--refile needs --organize-with-claude")
        try:
            result = refile(args.refile, args.output_dir.expanduser(), args.organize_with_claude, args.claude_model)
        except TranscribeError as e:
            print(json.dumps({"error": str(e)}))
            return 1
        print(json.dumps(result))
        return 0
    if not args.session_dir:
        parser.error("session_dir is required")
    try:
        result = run(args.session_dir, args.output_dir.expanduser(), args.model, args.language,
                     args.keychain_name, args.dictionary, args.keep_audio,
                     claude_path=args.organize_with_claude, claude_model=args.claude_model)
    except TranscribeError as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
