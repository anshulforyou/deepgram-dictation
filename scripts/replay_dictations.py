"""Replays saved dictations through the current cleanup prompt, to see what a change does.

Dictations are saved when `keepDictations` is set (see the README). For each one this prints
what Deepgram heard, what was pasted at the time, and what cleanup produces now. With
--deepgram the saved audio is transcribed again too, with the current keyterms. Uses the same
prompt file as the app (src/deepgram_dictation/cleanup_prompt.txt). Standard library only.

  python3 scripts/replay_dictations.py --last 20
  python3 scripts/replay_dictations.py --flagged --deepgram
  python3 scripts/replay_dictations.py --text "we go life with the the app"
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUPPORT = Path.home() / "Library" / "Application Support" / "deepgram-dictation"
PROMPT = REPO / "src" / "deepgram_dictation" / "cleanup_prompt.txt"
DICTIONARY = Path.home() / ".hammerspoon" / "deepgram-dictionary.json"


def keychain(name):
    out = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", name, "-w"],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        sys.exit(f"no key in Keychain ('{name}')")
    return out


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def names_and_keyterms(dictionary, extracted, limit):
    """Same merge as core.mergeNames in the app."""
    def unique(items):
        seen, out = set(), []
        for n in items:
            n = n.strip() if isinstance(n, str) else ""
            if n and n.lower() not in seen:
                seen.add(n.lower())
                out.append(n)
        return out
    names = unique(dictionary.get("names", []) + extracted.get("names", []))
    keyterms = unique(dictionary.get("keyterms", []) + dictionary.get("names", [])
                      + extracted.get("keyterms", [])[:limit])
    return names, keyterms


def post_json(url, body, headers):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        return {"type": "error", "error": {"message": f"HTTP {e.code} {e.read()[:200]!r}"}}


def clean(text, names, key, model):
    system = PROMPT.read_text().rstrip()
    if names:
        system += "\n\nNames list:\n" + ", ".join(names) + "\n"
    body = {
        "model": model, "max_tokens": 64 + (len(text) + 1) // 2,
        "thinking": {"type": "disabled"}, "output_config": {"effort": "low"},
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": f"<transcript>{text}</transcript>"}],
    }
    started = time.time()
    resp = post_json("https://api.anthropic.com/v1/messages", body, {
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    ms = int((time.time() - started) * 1000)
    if resp.get("type") == "error":
        return f"[error: {resp['error'].get('message')}]", ms
    return "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text").strip(), ms


def transcribe(wav, keyterms, key, model="nova-3", language="en"):
    params = [("model", model), ("language", language), ("punctuate", "true"), ("smart_format", "true")]
    params += [("keyterm", t) for t in keyterms]
    req = urllib.request.Request("https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(params),
                                 data=wav.read_bytes(),
                                 headers={"Authorization": f"Token {key}", "Content-Type": "audio/wav"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)["results"]["channels"][0]["alternatives"][0]["transcript"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", type=Path, default=SUPPORT / "dictations")
    parser.add_argument("--last", type=int, default=20, help="how many recent dictations (default 20)")
    parser.add_argument("--flagged", action="store_true", help="only dictations flagged as wrong")
    parser.add_argument("--deepgram", action="store_true", help="re-transcribe the saved audio as well")
    parser.add_argument("--text", action="append", default=[], help="clean this text instead")
    parser.add_argument("--dictionary", type=Path, default=DICTIONARY)
    parser.add_argument("--names", type=Path, default=SUPPORT / "names.json")
    parser.add_argument("--keyterm-names", type=int, default=50)
    parser.add_argument("--model", default="claude-haiku-5-5")
    args = parser.parse_args()

    names, keyterms = names_and_keyterms(load_json(args.dictionary, {}), load_json(args.names, {}),
                                         args.keyterm_names)
    anthropic = keychain("anthropic-api-key")
    records = [{"raw": t} for t in args.text]
    if not records:
        files = sorted(args.dir.glob("*.json"))
        records = [dict(load_json(f, {}), _stem=f.stem) for f in files]
        if args.flagged:
            records = [r for r in records if r.get("flagged")]
        records = [r for r in records if r.get("raw")][-args.last:]
    if not records:
        sys.exit("nothing to replay")
    deepgram = keychain("deepgram-api-key") if args.deepgram else None

    for r in records:
        print(f"--- {r.get('_stem', 'text')}{'  [flagged]' if r.get('flagged') else ''}")
        raw = r["raw"]
        print(f"heard:     {raw}")
        if deepgram and r.get("audio"):
            raw = transcribe(args.dir / r["audio"], keyterms, deepgram, r.get("model", "nova-3"),
                             r.get("language", "en"))
            print(f"heard now: {raw}")
        if "pasted" in r:
            print(f"pasted:    {r['pasted']}")
        text, ms = clean(raw, names, anthropic, args.model)
        print(f"now:       {text}   ({ms} ms)")


if __name__ == "__main__":
    main()
