"""Asks grandma questions about made-up screens and checks her answers (calls Anthropic's API).

Each case in tests/screens/cases.json names a screen (a PNG rendered from the HTML next to it
by scripts/render_screens.sh), a spoken-style question, whether the answer should be pasted
("insert") or shown ("answer"), words it must contain and words it must not. The request is
the one the app sends: same prompt file, same JPEG conversion, same answer format. Standard
library plus macOS's sips.

  python3 scripts/eval_screen.py
  python3 scripts/eval_screen.py --screen email --show
  python3 scripts/eval_screen.py --effort medium --model claude-opus-5-5
"""

import argparse
import base64
import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCREENS = REPO / "tests" / "screens"
PROMPT = REPO / "src" / "deepgram_dictation" / "screen_prompt.txt"
MAX_EDGE = 1920  # same as screen.lua
JPEG_QUALITY = 75

SCHEMA = {
    "type": "object",
    "properties": {"kind": {"type": "string", "enum": ["insert", "answer"]}, "text": {"type": "string"}},
    "required": ["kind", "text"],
    "additionalProperties": False,
}


def keychain(name):
    out = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", name, "-w"],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        sys.exit(f"no key in Keychain ('{name}')")
    return out


def jpeg_base64(png):
    """The screenshot as the app sends it: JPEG, no more than MAX_EDGE pixels on the long side."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "screen.jpg"
        subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", str(JPEG_QUALITY),
                        "-Z", str(MAX_EDGE), str(png), "--out", str(out)], check=True, capture_output=True)
        return base64.b64encode(out.read_bytes()).decode()


def request_body(model, effort, system, question, image):
    """Same as core.screenRequest in the app."""
    return {
        "model": model, "max_tokens": 4096,
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": SCHEMA}},
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image}},
            {"type": "text", "text": f"<question>{question}</question>"},
        ]}],
    }


def parse_answer(resp):
    """Same as core.parseScreenAnswer: (kind, text), or (None, why)."""
    if resp.get("type") == "error":
        return None, f"api error: {resp.get('error', {}).get('message')}"
    if resp.get("stop_reason") != "end_turn":
        return None, f"stopped: {resp.get('stop_reason')}"
    raw = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text").strip()
    if not raw:
        return None, "empty answer"
    try:
        value = json.loads(raw)
    except ValueError:
        return "answer", raw
    if value.get("kind") in ("insert", "answer") and str(value.get("text", "")).strip():
        return value["kind"], value["text"].strip()
    return "answer", raw


def grade(case, kind, text):
    """Everything wrong with an answer, as a list of reasons (empty when it passes)."""
    problems = []
    if kind != case["kind"]:
        problems.append(f"kind {kind}, expected {case['kind']}")
    lower = text.lower()
    for options in case.get("include", []):
        if not any(o.lower() in lower for o in options):
            problems.append("missing " + " / ".join(repr(o) for o in options))
    for word in case.get("exclude", []):
        if word.lower() in lower:
            problems.append(f"contains {word!r}")
    if case.get("check") == "password":
        if len(text.strip()) < 10 or not any(c.isdigit() for c in text):
            problems.append("password would not pass the form's rules")
    return problems


def ask(case, key, model, effort, system, images):
    body = request_body(model, effort, system, case["question"], images[case["screen"]])
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(), headers={
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        resp = {"type": "error", "error": {"message": f"HTTP {e.code} {e.read()[:300]!r}"}}
    ms = int((time.time() - started) * 1000)
    kind, text = parse_answer(resp)
    return kind, text, ms, resp.get("usage", {})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--screen", action="append", help="only cases on this screen (repeatable)")
    parser.add_argument("--model", default="claude-sonnet-5-5")
    parser.add_argument("--effort", default="low", choices=["low", "medium", "high"])
    parser.add_argument("--show", action="store_true", help="print every answer in full")
    parser.add_argument("--keychain-name", default="anthropic-api-key")
    args = parser.parse_args(argv)

    cases = json.loads((SCREENS / "cases.json").read_text())
    if args.screen:
        cases = [c for c in cases if c["screen"] in args.screen]
    if not cases:
        sys.exit("no cases")
    key = keychain(args.keychain_name)
    system = PROMPT.read_text().strip()
    images = {s: jpeg_base64(SCREENS / f"{s}.png") for s in {c["screen"] for c in cases}}

    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda c: ask(c, key, args.model, args.effort, system, images), cases))

    passed = 0
    for case, (kind, text, ms, usage) in zip(cases, results):
        problems = grade(case, kind, text) if kind else [text]
        passed += not problems
        mark = "PASS" if not problems else "FAIL"
        print(f"{mark} {case['screen']:<10} {ms:>6} ms  {kind or '-':<6} {case['question']}")
        if problems:
            print("     " + "; ".join(problems))
        if problems or args.show:
            print("     > " + str(text).replace("\n", "\n     > "))
    times = sorted(r[2] for r in results)
    print(f"\n{passed}/{len(cases)} passed · median {times[len(times) // 2]} ms · slowest {times[-1]} ms"
          f" · {args.model}, effort {args.effort}")
    return 0 if passed == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
