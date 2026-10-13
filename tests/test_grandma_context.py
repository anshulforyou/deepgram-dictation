import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation"))

import grandma_context as gc  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "screens" / "grandma"


def make_home(root):
    home = root / "grandma"
    for d in ("global/profiles", "acme/projects/fund-raise", "garden", "secrets", "notes"):
        (home / d).mkdir(parents=True)
    (home / "INDEX.md").write_text("## acme  (shoe company)\n## garden\n")
    (home / "global" / "identity.md").write_text("---\nscope: global\n---\nSam.\n")
    (home / "global" / "profiles" / "screen.md").write_text("PROFILE TEXT")
    (home / "acme" / "facts.md").write_text("---\nscope: acme\n---\nTrailrunner costs $139.\n")
    (home / "acme" / "projects.md").write_text(
        "---\nscope: acme\n---\n\n## fund-raise\n- what: seed round\n- source: acme/projects/fund-raise/CLAUDE.md\n\n"
        "## spring-launch\n- what: launch\n")
    (home / "acme" / "projects" / "fund-raise" / "CLAUDE.md").write_text("Raising $2M seed.")
    (home / "acme" / "api-tokens.md").write_text("---\nscope: acme\n---\nTOKEN_ABC")
    (home / "acme" / "linked.md").symlink_to(home / "secrets" / "personal.md")
    (home / "garden" / "facts.md").write_text("---\nscope: garden\n---\nPlot 14.\n")
    (home / "secrets" / "personal.md").write_text("---\nscope: secrets\n---\nPASSPORT")
    (home / "notes" / "random.md").write_text("no scope here")
    return home


class RoutingTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = make_home(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def sent(self, question):
        return [(m["name"], m["kind"]) for m in gc.context(self.home, question)["memory"]]

    def test_a_named_sweater_sends_its_root_memory(self):
        self.assertEqual(self.sent("fill in the Acme product details"), [("acme", "sweater")])
        text = gc.context(self.home, "acme")["memory"][0]["text"]
        self.assertIn("Trailrunner costs $139.", text)
        self.assertIn('<file path="acme/projects.md">', text)

    def test_a_named_project_wins_over_its_sweater(self):
        self.assertEqual(self.sent("acme fund raise deck"), [("fund-raise", "project")])
        text = gc.context(self.home, "fund-raise")["memory"][0]["text"]
        self.assertIn("seed round", text)
        self.assertIn("Raising $2M seed.", text)

    def test_names_match_whole_words_only(self):
        self.assertEqual(self.sent("where is billing"), [])
        self.assertEqual(self.sent("the acmes are here"), [])
        self.assertEqual(self.sent("gardening tips"), [])
        self.assertEqual(self.sent("my GARDEN plot"), [("garden", "sweater")])

    def test_a_project_without_a_source_sends_its_catalog_entry(self):
        self.assertIn("- what: launch", gc.context(self.home, "spring launch")["memory"][0]["text"])

    def test_never_sends_secrets_symlinks_or_credentials(self):
        everything = json.dumps([gc.open_item(self.home, n)["text"] for n in gc.context(self.home, "x")["openable"]])
        for never in ("TOKEN_ABC", "PASSPORT"):
            self.assertNotIn(never, everything)
        self.assertNotIn("secrets", gc.context(self.home, "secrets")["openable"])

    def test_catalog_has_descriptions_and_projects(self):
        ctx = gc.context(self.home, "x")
        self.assertEqual(ctx["catalog"], "- acme: shoe company. Projects: fund-raise, spring-launch\n- garden")
        self.assertEqual(ctx["openable"], ["acme", "fund-raise", "spring-launch", "garden"])
        self.assertEqual(ctx["profile"], "PROFILE TEXT")

    def test_open_is_case_insensitive_and_rejects_unknown_names(self):
        self.assertEqual(gc.open_item(self.home, "ACME")["name"], "acme")
        with self.assertRaises(gc.ContextError):
            gc.open_item(self.home, "secrets")

    def test_memory_is_capped(self):
        with mock.patch.object(gc, "MAX_CHARS", 50):
            text = gc.context(self.home, "acme")["memory"][0]["text"]
        self.assertTrue(text.endswith("[cut short]"))
        self.assertLessEqual(len(text), 50 + len("\n[cut short]"))

    def test_the_committed_eval_memory_never_leaks_its_decoys(self):
        everything = json.dumps([gc.open_item(FIXTURE, n)["text"] for n in gc.context(FIXTURE, "x")["openable"]])
        self.assertNotIn("TOKEN_VALUE", everything)
        self.assertNotIn("P1234567", everything)


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = make_home(Path(self._tmp.name))
        self.profile = self.home / gc.PROFILE

    def tearDown(self):
        self._tmp.cleanup()

    def age(self, path, seconds):
        t = time.time() - seconds
        os.utime(path, (t, t))

    def test_stale_only_when_a_global_file_is_newer(self):
        self.age(self.home / "global" / "identity.md", 100)
        self.assertFalse(gc.profile_stale(self.home))
        self.age(self.profile, 200)
        self.assertTrue(gc.profile_stale(self.home))
        self.profile.unlink()
        self.assertTrue(gc.profile_stale(self.home))

    def test_refresh_writes_a_generated_profile_from_global_only(self):
        self.profile.unlink()
        reply = {"stop_reason": "end_turn", "content": [{"type": "text", "text": "## Who\n- Sam"}]}
        with mock.patch.object(gc.nfg, "read_api_key", return_value="k"), \
                mock.patch.object(gc.nfg, "post_messages", return_value=reply) as post:
            gc.refresh_profile(self.home, "anthropic-api-key", "claude-haiku-5-5")
        prompt = post.call_args[0][0]["messages"][0]["content"]
        self.assertIn("Sam.", prompt)
        self.assertNotIn("Trailrunner", prompt)
        text = self.profile.read_text()
        self.assertTrue(text.startswith("---\nscope: global\ntype: profile\n"))
        self.assertTrue(text.endswith("## Who\n- Sam\n"))

    def test_refresh_does_nothing_when_current(self):
        self.age(self.home / "global" / "identity.md", 100)
        with mock.patch.object(gc.nfg, "post_messages") as post:
            self.assertEqual(gc.refresh_profile(self.home, "k", "m"), "profile is current")
        post.assert_not_called()

    def test_a_failed_refresh_keeps_the_old_profile(self):
        self.age(self.profile, 200)
        with mock.patch.object(gc.nfg, "read_api_key", return_value="k"), \
                mock.patch.object(gc.nfg, "post_messages", return_value={"stop_reason": "max_tokens"}):
            with self.assertRaises(gc.ContextError):
                gc.refresh_profile(self.home, "k", "m")
        self.assertEqual(self.profile.read_text(), "PROFILE TEXT")


class CliTest(unittest.TestCase):
    def test_question_prints_json(self):
        with mock.patch("sys.stdout") as out:
            self.assertEqual(gc.main(["--grandma-home", str(FIXTURE), "--question", "acme"]), 0)
        printed = "".join(c.args[0] for c in out.write.call_args_list)
        self.assertEqual(json.loads(printed)["memory"][0]["name"], "acme")

    def test_unknown_open_fails(self):
        with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            self.assertEqual(gc.main(["--grandma-home", str(FIXTURE), "--open", "nope"]), 1)


if __name__ == "__main__":
    unittest.main()
