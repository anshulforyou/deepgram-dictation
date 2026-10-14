import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation"))

import task_agent as ta  # noqa: E402
from test_grandma_context import make_home  # noqa: E402


def task(**over):
    t = {"question": "grandma, review this PR", "title": "Review PR 12", "goal": "Review pull request 12",
         "target": "https://github.com/acme/shop/pull/12", "memory": "", "edits": False, "stamp": "1015-101500"}
    t.update(over)
    return t


class PlanTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.home = make_home(self.root)
        self.workspace = self.root / "workspace"
        self.project = self.home / "acme" / "projects" / "fund-raise"

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_project_task_runs_in_the_project_folder(self):
        where = ta.plan(task(memory="fund-raise"), self.home, self.workspace)
        self.assertEqual(self.project, where["cwd"])
        self.assertIsNone(where["worktree"])
        self.assertEqual("fund-raise", where["item"]["name"])

    def test_a_task_with_no_project_runs_in_its_own_workspace_folder(self):
        where = ta.plan(task(memory="acme"), self.home, self.workspace)
        self.assertEqual(self.workspace / "1015-101500-review-pr-12", where["cwd"])
        self.assertEqual("acme", where["item"]["name"])

    def test_an_edit_task_in_a_repository_gets_its_own_worktree(self):
        subprocess.run(["git", "init", "-q", str(self.project)], check=True)
        where = ta.plan(task(memory="fund-raise", edits=True), self.home, self.workspace)
        self.assertEqual(self.project, where["cwd"])
        self.assertEqual("grandma-review-pr-12-1015-101500", where["worktree"])

    def test_an_edit_task_never_edits_a_project_folder_that_is_not_a_repository(self):
        where = ta.plan(task(memory="fund-raise", edits=True), self.home, self.workspace)
        self.assertEqual(self.workspace, where["cwd"].parent)
        self.assertIsNone(where["worktree"])

    def test_unknown_memory_names_fall_back_to_the_workspace(self):
        where = ta.plan(task(memory="nope"), self.home, self.workspace)
        self.assertIsNone(where["item"])
        self.assertEqual(self.workspace, where["cwd"].parent)


class PromptTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = make_home(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_the_prompt_carries_global_memory_and_the_project(self):
        where = ta.plan(task(memory="fund-raise"), self.home, Path(self._tmp.name) / "w")
        text = ta.system_prompt(task(), self.home, where)
        self.assertIn("You are grandma, working in the background", text)
        self.assertIn("Sam.", text)  # global/identity.md
        self.assertIn("Raising $2M seed.", text)  # the project's CLAUDE.md
        self.assertIn("Trailrunner costs $139.", text)  # its sweater's facts
        self.assertNotIn("own git worktree", text)

    def test_the_prompt_never_carries_secrets(self):
        where = ta.plan(task(memory="acme"), self.home, Path(self._tmp.name) / "w")
        text = ta.system_prompt(task(), self.home, where)
        self.assertNotIn("PASSPORT", text)
        self.assertNotIn("TOKEN_ABC", text)

    def test_with_no_item_the_catalog_is_sent(self):
        where = ta.plan(task(), self.home, Path(self._tmp.name) / "w")
        self.assertIn("<memory_catalog>", ta.system_prompt(task(), self.home, where))

    def test_edit_rules_are_added_for_an_edit_task(self):
        where = {"edits": True, "worktree": "grandma-x", "item": None, "cwd": Path("/x")}
        self.assertIn("own git worktree", ta.system_prompt(task(edits=True), None, where))

    def test_the_first_message_has_their_words_the_goal_and_the_target(self):
        msg = ta.first_message(task())
        self.assertIn("grandma, review this PR", msg)
        self.assertIn("Review pull request 12", msg)
        self.assertIn("https://github.com/acme/shop/pull/12", msg)


class PermissionsTest(unittest.TestCase):
    def test_read_only_tasks_can_look_but_not_change_anything(self):
        perms = ta.settings(False)["permissions"]
        self.assertIn("Bash(gh pr diff:*)", perms["allow"])
        self.assertNotIn("Edit", perms["allow"])
        self.assertFalse(any(r.startswith("Bash(cat") for r in perms["allow"]))
        for denied in ("git push", "gh pr comment", "gh pr review", "gh pr merge", "gh api"):
            self.assertIn(f"Bash({denied}:*)", perms["deny"])

    def test_edit_tasks_get_edits_and_tests_but_outward_actions_stay_denied(self):
        perms = ta.settings(True)["permissions"]
        self.assertIn("Edit", perms["allow"])
        self.assertIn("Bash(git commit:*)", perms["allow"])
        self.assertIn("Bash(git push:*)", perms["deny"])

    def test_commits_carry_no_attribution(self):
        s = ta.settings(True)
        self.assertFalse(s["includeCoAuthoredBy"])
        self.assertEqual({"commit": "", "pr": ""}, s["attribution"])

    def test_the_session_is_restricted_and_never_prompts(self):
        where = {"edits": False, "worktree": None, "cwd": Path("/x")}
        args = ta.claude_args("claude", task(), where, Path("/p/system.md"), "opus")
        self.assertEqual(["claude", "--bg", "--restricted", "--permission-mode", "dontAsk"], args[:5])
        self.assertEqual("Read,Grep,Glob,WebFetch,WebSearch,Bash", args[args.index("--tools") + 1])
        self.assertEqual("/p/system.md", args[args.index("--append-system-prompt-file") + 1])
        self.assertEqual("opus", args[args.index("--model") + 1])
        self.assertNotIn("-w", args)
        self.assertEqual(ta.first_message(task()), args[-1])

    def test_an_edit_session_gets_the_edit_tools_and_its_worktree(self):
        where = {"edits": True, "worktree": "grandma-x", "cwd": Path("/x")}
        args = ta.claude_args("claude", task(), where, Path("/p"))
        self.assertIn("Edit", args[args.index("--tools") + 1])
        self.assertEqual("grandma-x", args[args.index("-w") + 1])


class SessionTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.jobs = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def job(self, state):
        (self.jobs / "abc12345").mkdir()
        (self.jobs / "abc12345" / "state.json").write_text(json.dumps(
            {"state": state, "sessionId": "abc12345-0000", "cwd": "/repo"}))

    def test_reads_the_id_claude_prints(self):
        self.assertEqual("c77e0c48", ta.started_id("backgrounded · c77e0c48 · grandma: x\n  claude agents"))
        self.assertIsNone(ta.started_id("Workspace not trusted."))

    def test_explains_an_untrusted_folder(self):
        reason = ta.explain("Workspace not trusted. Run `claude` in /w/x once and accept the trust prompt, then retry.")
        self.assertIn("doesn't trust /w/x", reason)

    def test_a_reply_stops_the_session_then_resumes_it_with_the_answer(self):
        self.job("blocked")
        calls = []

        def run(args, cwd=None, timeout=60):
            calls.append((args, cwd))
            return 0, "backgrounded · abc12345 · grandma: x" if "--resume" in args else "stopped abc12345"

        with mock.patch.object(ta, "run", run):
            self.assertEqual({"id": "abc12345"}, ta.reply("abc12345", "the second one", "claude", self.jobs))
        self.assertEqual((["claude", "stop", "abc12345"], "/repo"), calls[0])
        self.assertEqual((["claude", "--bg", "--resume", "abc12345-0000", "the second one"], "/repo"), calls[1])

    def test_no_reply_while_she_is_still_working(self):
        self.job("working")
        with mock.patch.object(ta, "run") as run:
            with self.assertRaises(ta.TaskError):
                ta.reply("abc12345", "x", "claude", self.jobs)
            run.assert_not_called()

    def test_start_writes_the_prompt_and_returns_the_session(self):
        out = self.jobs / "out"
        ws = self.jobs / "ws"
        with mock.patch.object(ta, "run", return_value=(0, "backgrounded · abc12345 · grandma: x")) as run:
            result = ta.start(task(), None, ws, out, "claude")
        self.assertEqual("abc12345", result["id"])
        self.assertTrue((out / "system.md").read_text().startswith("You are grandma"))
        self.assertTrue(Path(result["cwd"]).is_dir())
        self.assertEqual(result["cwd"], str(run.call_args.kwargs["cwd"]))

    def test_start_reports_why_claude_did_not_start(self):
        with mock.patch.object(ta, "run", return_value=(1, "Workspace not trusted. Run `claude` in /w once and")):
            with self.assertRaisesRegex(ta.TaskError, "doesn't trust /w"):
                ta.start(task(), None, self.jobs / "ws", self.jobs / "out", "claude")

    def test_children_get_a_user_and_homebrew_on_the_path(self):
        with mock.patch.dict(ta.os.environ, {"PATH": "/usr/bin"}, clear=True):
            e = ta.env()
        self.assertTrue(e["USER"])
        self.assertIn("/opt/homebrew/bin", e["PATH"].split(":"))


if __name__ == "__main__":
    unittest.main()
