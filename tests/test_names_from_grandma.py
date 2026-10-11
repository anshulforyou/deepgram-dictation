import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation"))

import names_from_grandma as nfg  # noqa: E402

FACTS = "---\nscope: {name}\n---\n\n# facts\n\n{body}\n"


def make_home(root):
    """A grandma home with two sweaters, global, and everything the extractor must never read."""
    home = root / "grandma"
    (home / "acme").mkdir(parents=True)
    (home / "acme" / "facts.md").write_text(FACTS.format(name="acme", body="Anant runs Acme. Anant met Moksh."))
    (home / "acme" / "people.md").write_text("- Moksh, Go engineer\n")
    (home / "acme" / "meetings").mkdir()
    (home / "acme" / "meetings" / "call.md").write_text("Zed from the call")
    (home / "acme" / "log").mkdir()
    (home / "acme" / "log" / "2026-10-11.md").write_text("Yara in the log")
    (home / "acme" / ".env.md").write_text("Hidden")
    (home / "acme" / "api-secrets.md").write_text("Secretkeeper")
    (home / "acme" / "tokens.md").write_text("Tokenholder")
    (home / "home-ops").mkdir()
    (home / "home-ops" / "facts.md").write_text(FACTS.format(name="home-ops", body="Plumber is Ravi."))
    (home / "global").mkdir()
    (home / "global" / "identity.md").write_text("---\nscope: global\n---\nName: Anshul.\n")
    (home / "secrets").mkdir()
    (home / "secrets" / "personal.md").write_text("---\nscope: secrets\n---\nDOB and passwords")
    (home / "proposals").mkdir()
    (home / "proposals" / "acme-meeting.md").write_text("---\nscope: acme\n---\nProposed Quinn")
    (home / "notes").mkdir()
    (home / "notes" / "random.md").write_text("Not a sweater, no scope")
    (home / ".env").write_text("ANTHROPIC_API_KEY=sk-test")
    return home


class MemoryFilesTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = make_home(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def rel(self):
        return sorted(str(f.relative_to(self.home)) for f in nfg.memory_files(self.home))

    def test_reads_only_root_memory_of_global_and_sweaters(self):
        self.assertEqual(self.rel(), ["acme/facts.md", "acme/people.md", "global/identity.md", "home-ops/facts.md"])

    def test_never_reads_secrets_even_when_it_looks_like_a_sweater(self):
        notes = nfg.build_notes(self.home, nfg.memory_files(self.home))
        for never in ("passwords", "sk-test", "Secretkeeper", "Tokenholder", "Hidden", "Zed", "Yara", "Quinn"):
            self.assertNotIn(never, notes)

    def test_notes_are_tagged_with_their_path(self):
        notes = nfg.build_notes(self.home, nfg.memory_files(self.home))
        self.assertIn('<file path="acme/facts.md">', notes)
        self.assertIn("Anant runs Acme.", notes)


class RankTest(unittest.TestCase):
    def test_most_mentioned_first_and_drops_names_not_in_notes(self):
        notes = "Anant and Moksh. Anant again. Ravi once. Anantha is someone else."
        self.assertEqual(nfg.rank(["Ravi", "Moksh", "Anant", "Invented"], notes), ["Anant", "Moksh", "Ravi"])

    def test_dedupes_case_insensitively(self):
        self.assertEqual(nfg.rank(["Moksh", "moksh", " Moksh "], "Moksh"), ["Moksh"])

    def test_keyterms_leave_out_common_single_words(self):
        self.assertEqual(nfg.keyterms(["Anant", "Go", "Slack", "Claude Code"], {"go", "slack", "claude"}),
                         ["Anant", "Claude Code"])


class MainTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.home = make_home(self.root)
        self.out = self.root / "support" / "names.json"

    def tearDown(self):
        self._tmp.cleanup()

    def run_main(self):
        argv = ["--grandma-home", str(self.home), "--out", str(self.out)]
        with mock.patch.object(nfg, "read_api_key", return_value="k"), \
                mock.patch.object(nfg, "common_words", return_value={"go"}), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            return nfg.main(argv)

    def test_writes_ranked_names_and_keyterms(self):
        with mock.patch.object(nfg, "ask_claude", return_value=["Moksh", "Go", "Anant", "Ravi"]) as ask:
            self.assertEqual(self.run_main(), 0)
        self.assertNotIn("passwords", ask.call_args[0][0])
        data = json.loads(self.out.read_text())
        self.assertEqual(data["names"], ["Anant", "Moksh", "Go", "Ravi"])
        self.assertEqual(data["keyterms"], ["Anant", "Moksh", "Ravi"])
        self.assertIn("generated", data)

    def test_failure_keeps_the_previous_file(self):
        self.out.parent.mkdir(parents=True)
        self.out.write_text('{"names": ["Old"]}')
        with mock.patch.object(nfg, "ask_claude", side_effect=nfg.ExtractError("down")):
            self.assertEqual(self.run_main(), 1)
        self.assertEqual(json.loads(self.out.read_text())["names"], ["Old"])


class AskClaudeTest(unittest.TestCase):
    def reply(self, payload):
        resp = mock.MagicMock()
        resp.__enter__.return_value = resp
        resp.read.return_value = json.dumps(payload).encode()
        return resp

    def test_parses_structured_output(self):
        payload = {"stop_reason": "end_turn", "content": [{"type": "text", "text": '{"names": ["Anant", 3]}'}]}
        with mock.patch("urllib.request.urlopen", return_value=self.reply(payload)) as urlopen:
            self.assertEqual(nfg.ask_claude("notes", "k", "claude-haiku-5-5"), ["Anant"])
        body = json.loads(urlopen.call_args[0][0].data)
        self.assertEqual(body["output_config"]["format"]["type"], "json_schema")

    def test_rejects_truncated_answers(self):
        payload = {"stop_reason": "max_tokens", "content": [{"type": "text", "text": '{"names": ['}]}
        with mock.patch("urllib.request.urlopen", return_value=self.reply(payload)):
            with self.assertRaises(nfg.ExtractError):
                nfg.ask_claude("notes", "k", "m")


if __name__ == "__main__":
    unittest.main()
