"""Asks grandma questions about made-up screens and checks her answers (calls Anthropic's API).

Each case in tests/screens/cases.json names a screen (a PNG rendered from the HTML next to it
by scripts/render_screens.sh), a spoken-style question, whether the answer should be pasted
("insert"), shown ("answer"), filled ("fill") or handed to a background agent ("task"), words
it must contain and words it must not, and for a task what it must say about it ("task"). The request is
the one the app sends: same prompt file, same JPEG conversion, same answer format. Standard
library plus macOS's sips.

Memory comes from a made-up grandma home (tests/screens/grandma), read by the app's own
grandma_context.py, including the open_memory step. A case with "memory" lists the sweaters and
projects that must be sent or opened for it ([] for none); "memory_any" accepts any of a few.

  python3 scripts/eval_screen.py
  python3 scripts/eval_screen.py --screen email --show
  python3 scripts/eval_screen.py --effort medium --model claude-opus-5-5
  python3 scripts/eval_screen.py --no-memory
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
GRANDMA = SCREENS / "grandma"
MAX_OPENS = 1  # same as screen.lua
MEMORY_CHARS, MIN_OPEN_CHARS = 240_000, 20_000  # same as screen.lua

sys.path.insert(0, str(REPO / "src" / "deepgram_dictation"))
import grandma_context  # noqa: E402
PROMPT = REPO / "src" / "deepgram_dictation" / "screen_prompt.txt"
MAX_EDGE = 1920  # same as screen.lua
JPEG_QUALITY = 60

SCHEMA = {  # same as core.SCREEN_SCHEMA
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": ["insert", "answer", "fill", "task", "work"]},
        "text": {"type": "string"},
        "fields": {"type": "array", "items": {
            "type": "object",
            "properties": {"label": {"type": "string"}, "value": {"type": "string"},
                           "upload": {"type": "string"}, "skip": {"type": "boolean"}},
            "required": ["label", "value", "upload", "skip"], "additionalProperties": False}},
        "task": {"type": "object", "properties": {
            "title": {"type": "string"}, "goal": {"type": "string"}, "target": {"type": "string"},
            "memory": {"type": "string"}, "edits": {"type": "boolean"}, "minutes": {"type": "integer"}},
            "required": ["title", "goal", "target", "memory", "edits", "minutes"], "additionalProperties": False},
    },
    "required": ["kind", "text", "fields", "task"],
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


def request_body(model, effort, system, question, image, memory=None):
    """Same as core.screenRequest in the app."""
    system_blocks = [{"type": "text", "text": system}]
    content, tools = [], None
    if memory:
        about = []
        if memory.get("profile"):
            about.append(f"<profile>\n{memory['profile']}\n</profile>")
        if memory.get("catalog"):
            about.append(f"<memory_catalog>\n{memory['catalog']}\n</memory_catalog>")
        if about:
            system_blocks.append({"type": "text", "text": "\n\n".join(about)})
        for m in memory.get("memory", []):
            content.append({"type": "text", "text": f'<memory name="{m["name"]}" kind="{m["kind"]}">\n{m["text"]}\n</memory>'})
        content += image_blocks(memory.get("images", []))
        if content:
            content[-1]["cache_control"] = {"type": "ephemeral"}
        if memory.get("openable"):
            tools = [{
                "name": "open_memory",
                "description": "Read the user's memory for one of their sweaters or projects from the catalog. "
                               "Use it when the screen or question is about one whose memory isn't included yet.",
                "input_schema": {"type": "object", "properties": {"name": {"type": "string", "enum": memory["openable"]}},
                                 "required": ["name"], "additionalProperties": False},
            }]
    system_blocks[-1]["cache_control"] = {"type": "ephemeral"}
    content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image}})
    content.append({"type": "text", "text": f"<question>{question}</question>"})
    body = {
        "model": model, "max_tokens": 4096,
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": SCHEMA}},
        "system": system_blocks,
        "messages": [{"role": "user", "content": content}],
    }
    if tools:
        body["tools"] = tools
    return body


def image_blocks(images):
    """Same as core.imageBlocks."""
    out = []
    for img in images:
        if img.get("thumb"):
            out.append({"type": "text", "text": f'<memory_image id="{img["id"]}" file="{img["name"]}" '
                                                f'size="{img["width"]}x{img["height"]}">{img["note"]}</memory_image>'})
            out.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img["thumb"]}})
    return out


def memory_results(resp, opens, home, sent_chars=0, seen_images=None):
    """Tool results for the open_memory calls in `resp` (same as screen.lua), the names opened, and
    the number of opens so far."""
    results, opened = [], []
    for block in resp.get("content", []):
        if block.get("type") != "tool_use":
            continue
        name = (block.get("input") or {}).get("name")
        opens += 1
        if opens > MAX_OPENS or block.get("name") != "open_memory":
            results.append({"type": "tool_result", "tool_use_id": block["id"], "is_error": True,
                            "content": "No more memory can be opened for this question. Answer with what you have."})
            continue
        try:
            item = grandma_context.open_item(home, str(name), max(MIN_OPEN_CHARS, MEMORY_CHARS - sent_chars))
            opened.append(item["name"])
            pictures = image_blocks(item.get("images", []))
            if seen_images is not None:
                seen_images += item.get("images", [])
            content = [{"type": "text", "text": item["text"]}] + pictures if pictures else item["text"]
            results.append({"type": "tool_result", "tool_use_id": block["id"], "content": content})
        except (grandma_context.ContextError, OSError) as e:
            results.append({"type": "tool_result", "tool_use_id": block["id"], "is_error": True, "content": str(e)})
    return results, opened, opens


def parse_answer(resp, images=()):
    """Same as core.parseScreenAnswer: (kind, text), or (None, why). A fill plan's text is one
    "label: value" line per field, with "[skip]" for a field it won't fill."""
    if resp.get("type") == "error":
        return None, f"api error: {resp.get('error', {}).get('message')}"
    if resp.get("stop_reason") == "refusal":
        return None, "Claude declined to answer"
    if resp.get("stop_reason") != "end_turn":
        return None, f"stopped: {resp.get('stop_reason')}"
    raw = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text").strip()
    if not raw:
        return None, "empty answer"
    try:
        value = json.loads(raw)
    except ValueError:
        return "answer", raw
    if not isinstance(value, dict):
        return "answer", raw
    if value.get("kind") == "fill":
        lines = []
        names = {img["id"]: img["name"] for img in images}
        for f in value.get("fields") or []:
            if isinstance(f, dict) and isinstance(f.get("label"), str) and f["label"].strip():
                v = f.get("value") if isinstance(f.get("value"), str) else ""
                upload = names.get(f.get("upload") or "")
                skip = f.get("skip") is True or not (upload or v.strip())
                shown = "[skip]" if skip else f"[upload {upload}]" if upload else v
                lines.append(f"{f['label'].strip()}: {shown}")
        if lines:
            return "fill", "\n".join(lines)
    if value.get("kind") == "work" and isinstance(value.get("text"), str) and value["text"].strip():
        return "work", value["text"].strip()
    task = value.get("task")
    if value.get("kind") == "task" and isinstance(task, dict) and str(task.get("goal", "")).strip():
        # One "key: value" line each, so a case can check them like a fill plan.
        return "task", "\n".join(f"{k}: {task.get(k)}" for k in ("title", "goal", "target", "memory", "edits",
                                                                    "minutes"))
    if value.get("kind") in ("insert", "answer") and isinstance(value.get("text"), str) and value["text"].strip():
        return value["kind"], value["text"].strip()
    return "answer", raw


def grade(case, kind, text, used=None):
    """Everything wrong with an answer, as a list of reasons (empty when it passes). `used` is
    the memory sent or opened, checked against the case's "memory" when it has one."""
    problems = []
    if "memory" in case and used is not None and sorted(set(used)) != sorted(case["memory"]):
        problems.append(f"memory {sorted(set(used))}, expected {sorted(case['memory'])}")
    if "memory_any" in case and used is not None and (not used or not set(used) <= set(case["memory_any"])):
        problems.append(f"memory {sorted(set(used))}, expected some of {sorted(case['memory_any'])}")
    if kind != case["kind"] and not case.get("kind_any"):
        problems.append(f"kind {kind}, expected {case['kind']}")
    lower = text.lower()
    for options in case.get("include", []):
        if not any(o.lower() in lower for o in options):
            problems.append("missing " + " / ".join(repr(o) for o in options))
    for word in case.get("exclude", []):
        if word.lower() in lower:
            problems.append(f"contains {word!r}")
    if kind == "fill":
        plan = {}
        for line in text.splitlines():
            label, _, value = line.partition(": ")
            plan[label.strip().lower()] = value
        def field(label):
            return next((v for k, v in plan.items() if label.lower() in k), None)
        for label, options in case.get("fill", {}).items():
            value = field(label)
            if value is None or value == "[skip]" or not any(o.lower() in value.lower() for o in options):
                problems.append(f"{label} is {value!r}, expected one of {options}")
        for label in case.get("skip", []):
            value = field(label)
            if value not in (None, "[skip]"):
                problems.append(f"{label} was filled with {value!r} but the memory has no value for it")
    if kind == "task":
        got = dict(line.partition(": ")[::2] for line in text.splitlines())
        for key, want in case.get("task", {}).items():
            have = got.get(key, "")
            if isinstance(want, bool):
                if have != str(want):
                    problems.append(f"task {key} is {have}, expected {want}")
            elif not any(w.lower() in have.lower() for w in want):
                problems.append(f"task {key} is {have!r}, expected one of {want}")
    if case.get("check") == "password":
        if len(text.strip()) < 10 or not any(c.isdigit() for c in text):
            problems.append("password would not pass the form's rules")
    return problems


def post(body, key):
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(), headers={
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"type": "error", "error": {"message": f"HTTP {e.code} {e.read()[:300]!r}"}}


def ask(case, key, model, effort, system, images, home):
    """(kind, text, ms, memory used) for one case, opening memory the way the app does."""
    started = time.time()
    memory = grandma_context.context(home, case["question"]) if home else None
    used = [m["name"] for m in memory["memory"]] if memory else []
    seen_images = list(memory.get("images", [])) if memory else []
    body = request_body(model, effort, system, case["question"], images[case["screen"]], memory)
    opens = 0
    while True:
        resp = post(body, key)
        if resp.get("stop_reason") != "tool_use":
            break
        sent_chars = sum(len(m["text"]) for m in memory["memory"])
        results, opened, opens = memory_results(resp, opens, home, sent_chars, seen_images)
        used += opened
        body["messages"] += [{"role": "assistant", "content": resp["content"]}, {"role": "user", "content": results}]
        if opens >= MAX_OPENS:
            body["tool_choice"] = {"type": "none"}
    kind, text = parse_answer(resp, seen_images)
    return kind, text, int((time.time() - started) * 1000), used


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--screen", action="append", help="only cases on this screen (repeatable)")
    parser.add_argument("--model", default="claude-sonnet-5-5")
    parser.add_argument("--effort", default="low", choices=["low", "medium", "high"])
    parser.add_argument("--show", action="store_true", help="print every answer in full")
    parser.add_argument("--no-memory", action="store_true", help="ask without grandma memory")
    parser.add_argument("--keychain-name", default="anthropic-api-key")
    args = parser.parse_args(argv)

    cases = json.loads((SCREENS / "cases.json").read_text())
    if args.screen:
        cases = [c for c in cases if c["screen"] in args.screen]
    if args.no_memory:
        cases = [c for c in cases if not c.get("memory")]  # these need memory to be answerable
    if not cases:
        sys.exit("no cases")
    key = keychain(args.keychain_name)
    system = PROMPT.read_text()
    images = {s: jpeg_base64(SCREENS / f"{s}.png") for s in {c["screen"] for c in cases}}

    home = None if args.no_memory else GRANDMA
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda c: ask(c, key, args.model, args.effort, system, images, home), cases))

    passed = 0
    for case, (kind, text, ms, used) in zip(cases, results):
        problems = grade(case, kind, text, None if args.no_memory else used) if kind else [text]
        passed += not problems
        mark = "PASS" if not problems else "FAIL"
        memo = f"  [{', '.join(used)}]" if used else ""
        print(f"{mark} {case['screen']:<11} {ms:>6} ms  {kind or '-':<6} {case['question']}{memo}")
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
