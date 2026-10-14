"""Starts grandma's background agents: a Claude Code session in the background (`claude --bg`) for
a task the user asked for out loud, such as reviewing the pull request on screen.

Each agent gets the user's grandma memory (global memory plus the sweater or project the task
belongs to) and runs in that project's folder when there is one, otherwise in a workspace folder.
Claude Code runs it in restricted mode with an allowlist: it can read, search, use git and gh to
look, and fetch web pages. A task that may change code also gets the edit tools and runs in its
own git worktree, so the user's checkout is never touched. Pushing, commenting on or merging pull
requests, and gh api are denied either way.

Claude Code keeps each background session's state in ~/.claude/jobs/<id>/state.json (working,
blocked with what it needs, done with its result), which the app watches. A reply stops the
session and resumes it, under the same id and with its saved options, with the user's answer.

  task_agent.py start --task FILE --grandma-home ~/.grandma --workspace ~/Documents/grandma-tasks \
      --out-dir DIR --claude PATH
  task_agent.py reply --id ID --text "use the second one" --claude PATH
  task_agent.py stop --id ID --claude PATH

Each prints one line of JSON. Standard library only."""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import grandma_context as gc
import names_from_grandma as nfg

PROMPT_FILE = Path(__file__).resolve().parent / "task_prompt.txt"
JOBS = Path.home() / ".claude" / "jobs"
MEMORY_CHARS = 240_000

# Commands an agent may run. Matching is by prefix, so "git diff" also allows "git diff main".
# Files are read with Claude Code's own tools, which restricted mode keeps inside the working
# folder, so nothing like cat or find is here. Build and test commands run the project's own
# code, so for a task that edits, the blocked list is a guard against mistakes, not a sandbox.
READ_COMMANDS = [
    "git status", "git diff", "git log", "git show", "git blame", "git branch", "git fetch",
    "git rev-parse", "git ls-files", "git grep", "git clone",
    "gh pr view", "gh pr diff", "gh pr checks", "gh pr list", "gh pr status",
    "gh issue view", "gh issue list", "gh repo view", "gh repo clone", "gh run view", "gh run list",
    "gh release view", "gh release list", "gh search",
]
EDIT_COMMANDS = [
    "git add", "git commit", "git checkout -b", "git switch -c", "git restore", "git stash", "git mv", "git rm",
    "make", "npm test", "npm run", "pnpm test", "pnpm run", "yarn test", "yarn run", "go test", "go build",
    "go vet", "gofmt", "cargo test", "cargo build", "pytest", "python3 -m pytest", "python3 -m unittest",
    "busted", "luacheck", "shellcheck", "mkdir",
]
# Denied even when another rule would allow them (deny wins in Claude Code).
DENIED_COMMANDS = [
    "git push", "git remote", "git config", "git reset --hard", "git clean", "git checkout main",
    "gh pr create", "gh pr comment", "gh pr review", "gh pr merge", "gh pr close", "gh pr edit",
    "gh pr ready", "gh pr checkout", "gh issue create", "gh issue comment", "gh issue close", "gh issue edit",
    "gh api", "gh release create", "gh repo create", "gh repo delete", "gh repo edit", "gh gist", "gh secret",
    "gh auth", "curl", "wget", "ssh", "scp", "rm -rf", "sudo",
]

EDIT_RULES = """
This task may change code. You are in your own git worktree on a new branch made for this task, so the user's checkout is untouched. Commit your work there in small steps as you go, with plain messages that say what changed, and no trailers or attribution lines. Run the project's tests and linters before you finish. Never push. In your report, name the branch, list the commits, and say what the tests showed."""

WORKSPACE_EDIT_RULES = """
This task may change code. Your working folder belongs to this task. If the work needs a repository, clone it here with gh repo clone, make a new branch, and commit your work there in small steps, with plain messages and no trailers or attribution lines. Run its tests before you finish. Never push. In your report, say where the clone is, name the branch, and list the commits."""


class TaskError(Exception):
    pass


def slug(text, limit=32):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:limit].rstrip("-") or "task"


def find_item(home, name):
    """The catalog entry (sweater or project) called `name`, or None."""
    if not name:
        return None
    for i in gc.entries(home):
        if i["name"].lower() == name.lower() or any(a.lower() == name.lower() for a in i.get("aliases", [])):
            return i
    return None


def project_dir(home, item):
    """The folder of a project's CLAUDE.md, when the catalog points at a safe one."""
    if not item or item["kind"] != "project" or not item.get("source"):
        return None
    src = gc.resolve_source(home, item["source"])
    return src.parent if src else None


def is_repo(path):
    try:
        out = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], capture_output=True,
                             text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return out.returncode == 0


def memory_text(home, item):
    """The user's global memory, then the task's sweater or project (with its sweater's facts)."""
    blocks = [gc.file_block(home, f) for f in nfg.root_files(home / "global")]
    if item:
        blocks.append(gc.open_item(home, item["name"], MEMORY_CHARS)["text"])
    else:
        blocks.append("<memory_catalog>\n" + gc.catalog(gc.entries(home)) + "\n</memory_catalog>")
    text = "\n\n".join(blocks)
    return text[:MEMORY_CHARS]


def plan(task, home, workspace):
    """Where and how the agent runs: { cwd, worktree (name or None), edits, item }."""
    item = find_item(home, task.get("memory")) if home else None
    folder = project_dir(home, item) if home else None
    edits = bool(task.get("edits"))
    if folder and folder.is_dir() and (not edits or is_repo(folder)):
        cwd, worktree = folder, (f"grandma-{slug(task['title'], 24)}-{task['stamp']}" if edits else None)
    else:
        cwd, worktree = Path(workspace).expanduser() / f"{task['stamp']}-{slug(task['title'])}", None
    return {"cwd": cwd, "worktree": worktree, "edits": edits, "item": item}


def system_prompt(task, home, where):
    rules = PROMPT_FILE.read_text().strip()
    if where["edits"]:
        rules += "\n" + (EDIT_RULES if where["worktree"] else WORKSPACE_EDIT_RULES)
    if home:
        rules += "\n\n<memory>\n" + memory_text(home, where["item"]) + "\n</memory>"
    return rules + "\n"


def first_message(task):
    lines = [f"What they said: {task['question']}", f"The task: {task['goal']}"]
    if task.get("target"):
        lines.append(f"On their screen: {task['target']}")
    return "\n".join(lines)


def settings(edits):
    allow = ["Read", "Grep", "Glob", "WebFetch", "WebSearch"] + [f"Bash({c}:*)" for c in READ_COMMANDS]
    if edits:
        allow += ["Edit", "Write", "NotebookEdit"] + [f"Bash({c}:*)" for c in EDIT_COMMANDS]
    return {
        "permissions": {"allow": allow, "deny": [f"Bash({c}:*)" for c in DENIED_COMMANDS]},
        "includeCoAuthoredBy": False,
        "attribution": {"commit": "", "pr": ""},
    }


def claude_args(claude, task, where, prompt_file, model=None):
    tools = "Read,Grep,Glob,WebFetch,WebSearch,Bash" + (",Edit,Write,NotebookEdit" if where["edits"] else "")
    args = [claude, "--bg", "--restricted", "--permission-mode", "dontAsk", "--tools", tools,
            "--settings", json.dumps(settings(where["edits"])), "--append-system-prompt-file", str(prompt_file),
            "--name", f"grandma: {task['title']}"]
    if where["worktree"]:
        args += ["-w", where["worktree"]]
    if model:
        args += ["--model", model]
    return args + [first_message(task)]


PATHS = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]


def env():
    """What `claude` needs when started from Hammerspoon: USER/LOGNAME find its Keychain login, and a
    PATH with Homebrew on it, which the agent's git and gh are found by."""
    e = dict(os.environ)
    user = e.get("USER") or e.get("LOGNAME") or Path.home().name
    e.setdefault("USER", user)
    e.setdefault("LOGNAME", user)
    have = e.get("PATH", "").split(":")
    e["PATH"] = ":".join(have + [os.path.expanduser(p) for p in PATHS if os.path.expanduser(p) not in have])
    return e


def run(args, cwd=None, timeout=60):
    try:
        out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env())
    except subprocess.TimeoutExpired:
        raise TaskError(f"{Path(args[0]).name} {args[1]} did not return in {timeout} s")
    except OSError as e:
        raise TaskError(str(e))
    return out.returncode, out.stdout + out.stderr


def started_id(output):
    m = re.search(r"backgrounded\s*·\s*([0-9a-f]{6,})", output)
    return m.group(1) if m else None


def explain(output):
    """A short reason from what `claude --bg` printed when it didn't start."""
    trust = re.search(r"Workspace not trusted\. Run `claude` in (.+?) once", output)
    if trust:
        return (f"Claude Code doesn't trust {trust.group(1)} yet. Open a terminal there, run claude once and "
                "accept, then ask again.")
    line = next((l.strip() for l in output.splitlines() if l.strip()), "no output")
    return f"claude didn't start: {line[:200]}"


def start(task, home, workspace, out_dir, claude, model=None):
    where = plan(task, home, workspace)
    where["cwd"].mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    prompt_file = out_dir / "system.md"
    prompt_file.write_text(system_prompt(task, home, where))
    code, output = run(claude_args(claude, task, where, prompt_file, model), cwd=where["cwd"])
    job = started_id(output)
    if code != 0 or not job:
        raise TaskError(explain(output))
    return {"id": job, "cwd": str(where["cwd"]), "worktree": where["worktree"], "edits": where["edits"],
            "memory": where["item"]["name"] if where["item"] else None}


def job_state(job, jobs=JOBS):
    try:
        return json.loads((jobs / job / "state.json").read_text())
    except (OSError, ValueError):
        raise TaskError(f"no background session {job}")


def reply(job, text, claude, jobs=JOBS):
    """Stops the session (it may still be waiting) and continues it with the user's answer. Without
    flags, `claude --bg --resume` wakes it under the same id with the options it started with."""
    state = job_state(job, jobs)
    session, cwd = state.get("sessionId"), state.get("cwd")
    if not session or not cwd:
        raise TaskError(f"background session {job} has no saved conversation")
    if state.get("state") == "working":
        raise TaskError("she is still working on it")
    run([claude, "stop", job], cwd=cwd)
    code, output = run([claude, "--bg", "--resume", session, text], cwd=cwd)
    again = started_id(output)
    if code != 0 or not again:
        raise TaskError(explain(output))
    return {"id": again}


def stop(job, claude, jobs=JOBS):
    state = job_state(job, jobs)
    code, output = run([claude, "stop", job], cwd=state.get("cwd"))
    if code != 0:
        raise TaskError(explain(output))
    return {"id": job}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("start")
    s.add_argument("--task", required=True, type=Path, help="JSON: question, title, goal, target, memory, edits, stamp")
    s.add_argument("--grandma-home", type=Path)
    s.add_argument("--workspace", required=True)
    s.add_argument("--out-dir", required=True, type=Path)
    s.add_argument("--claude", required=True)
    s.add_argument("--model")
    r = sub.add_parser("reply")
    r.add_argument("--id", required=True)
    r.add_argument("--text", required=True)
    r.add_argument("--claude", required=True)
    t = sub.add_parser("stop")
    t.add_argument("--id", required=True)
    t.add_argument("--claude", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "start":
            home = args.grandma_home.expanduser() if args.grandma_home else None
            if home and not home.is_dir():
                home = None
            result = start(json.loads(args.task.read_text()), home, args.workspace, args.out_dir, args.claude,
                           args.model)
        elif args.command == "reply":
            result = reply(args.id, args.text, args.claude)
        else:
            result = stop(args.id, args.claude)
    except (TaskError, gc.ContextError, nfg.ExtractError, OSError, ValueError, KeyError) as e:
        print(json.dumps({"error": str(e)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
