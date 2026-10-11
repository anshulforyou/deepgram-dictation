import json
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation"))

import meeting_grandma as mg  # noqa: E402
import meeting_transcribe as mt  # noqa: E402
from test_meeting_transcribe import deepgram_response  # noqa: E402

INDEX = """\
# INDEX

## global (always loaded)
- [global/identity.md] — who the user is

## acme  (client work, billing platform)
- [acme/facts.md] — stack and conventions
- [acme/log/2026-09-01.md] — session log

## home-ops
- [home-ops/facts.md] — what this context is
"""

FACTS = "---\nscope: {name}\ntype: facts\n---\n\n# facts\n\n## What it is\n- {what}\n"


def make_home(root):
    """A small grandma memory home with two sweaters and the folders grandma owns."""
    home = root / "grandma"
    for name, what in (("acme", "A client."), ("home-ops", "Running the house: repairs, bills, the garden.")):
        (home / name).mkdir(parents=True)
        (home / name / "facts.md").write_text(FACTS.format(name=name, what=what))
    (home / "global").mkdir()
    (home / "global" / "identity.md").write_text("---\nscope: global\n---\n")
    (home / "proposals").mkdir()
    (home / "proposals" / "acme-x.md").write_text("---\nscope: acme\n---\n")
    (home / "assets").mkdir()  # media only, not a sweater
    (home / "INDEX.md").write_text(INDEX)
    return home


class SweaterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = make_home(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_lists_only_sweaters_with_descriptions(self):
        sweaters = mg.list_sweaters(self.home)
        self.assertEqual([(n, d) for n, d, _ in sweaters], [
            ("acme", "client work, billing platform"),             # from INDEX.md
            ("home-ops", "Running the house: repairs, bills, the garden."),  # facts.md fallback
        ])

    def test_missing_home_has_no_sweaters(self):
        self.assertEqual(mg.list_sweaters(self.home / "nope"), [])

    def test_resolves_only_existing_sweaters(self):
        sweaters = mg.list_sweaters(self.home)
        self.assertEqual(mg.resolve_sweater("Home-Ops", sweaters), "home-ops")
        self.assertIsNone(mg.resolve_sweater("", sweaters))
        self.assertIsNone(mg.resolve_sweater("New Venture", sweaters), "never invents a sweater")
        self.assertIsNone(mg.resolve_sweater("global", sweaters))

    def test_prompt_lists_sweaters_and_recent_meetings(self):
        (self.home / "acme" / "meetings").mkdir()
        (self.home / "acme" / "meetings" / "meetings.md").write_text(
            "# acme meetings\n\n- **2026-10-01 10:00** · [Billing review](x.md) · 30 min\n")
        prompt = mg.build_prompt([{"start": 0, "label": "Me", "text": "Hi"}], mg.list_sweaters(self.home),
                                 datetime(2026, 10, 11, 9, 0))
        self.assertIn("- acme: client work, billing platform (recent meetings: Billing review)", prompt)
        self.assertIn("- home-ops: Running the house", prompt)
        self.assertIn("[00:00] Me: Hi", prompt)

    def test_index_pointer_goes_under_the_sweater_once(self):
        mg.ensure_index_pointer(self.home, "acme")
        mg.ensure_index_pointer(self.home, "acme")
        lines = (self.home / "INDEX.md").read_text().split("\n")
        pointer = [i for i, l in enumerate(lines) if "[acme/meetings/meetings.md]" in l]
        self.assertEqual(len(pointer), 1)
        self.assertEqual(lines[pointer[0] - 1], "- [acme/log/2026-09-01.md] — session log")
        self.assertEqual(lines[pointer[0] + 2], "## home-ops", "home-ops section untouched")

    def test_index_pointer_adds_a_section_when_missing(self):
        (self.home / "INDEX.md").write_text("# INDEX\n")
        mg.ensure_index_pointer(self.home, "acme")
        self.assertIn("## acme\n- [acme/meetings/meetings.md]", (self.home / "INDEX.md").read_text())

    def test_memory_is_the_sweater_root_only_and_capped(self):
        (self.home / "acme" / "log").mkdir()
        (self.home / "acme" / "log" / "2026-09-01.md").write_text("LOG ONLY")
        memory = mg.sweater_memory(self.home, "acme")
        self.assertIn("## acme/facts.md", memory)
        self.assertNotIn("LOG ONLY", memory)
        self.assertTrue(mg.sweater_memory(self.home, "acme", cap=10).endswith("[memory truncated]"))

    def test_proposal_names_never_collide(self):
        start = datetime(2026, 10, 11, 17, 29)
        first = mg.proposal_path(self.home, "Acme", start)
        self.assertEqual(first.name, "acme-meeting-20261011-1729.md")
        first.write_text("x")
        self.assertEqual(mg.proposal_path(self.home, "Acme", start).name, "acme-meeting-20261011-1729-2.md")

    def test_doctrine_falls_back_without_an_engine(self):
        with mock.patch.dict("os.environ", {"GRANDMA_ENGINE": str(self.home / "no-engine")}):
            self.assertEqual(mg.capture_doctrine(), mg.FALLBACK_DOCTRINE)


class GrandmaRunTest(unittest.TestCase):
    ANSWER = {"folder": "Home-Ops", "title": "Boiler repair quote", "summary": "Got a quote.",
              "action_items": ["Me: book the plumber"]}
    PROPOSAL = "1. home-ops/facts.md, new-fact: Plumber is Dana. Why: recurring contact."

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = make_home(root)
        self.out = root / "unfiled"
        self.session = root / "session"
        self.session.mkdir()
        (self.session / "mic.m4a").write_bytes(b"\0" * 4096)
        (self.session / "status.json").write_text(json.dumps({
            "state": "stopped", "captureSystem": False, "startedAt": "2026-10-11T12:00:00Z", "duration": 60.0,
        }))
        resp = deepgram_response((0, 1.0, 2.0, "The boiler quote came in."))
        (self.session / "deepgram-mic.json").write_text(json.dumps(resp))  # cached: no API call

    def tearDown(self):
        self.tmp.cleanup()

    def run_meeting(self, answer=None, proposal=None, proposal_error=None):
        text = mock.patch.object(mt.meeting_organize, "run_claude_text",
                                 side_effect=proposal_error, return_value=proposal or self.PROPOSAL)
        with mock.patch.object(mt.meeting_organize, "run_claude", return_value=answer or self.ANSWER), \
             text as text_call, mock.patch.dict("os.environ", {"GRANDMA_ENGINE": str(self.home / "none")}):
            result = mt.run(self.session, self.out, "nova-3", "en", "k", claude_path="/bin/claude",
                            grandma_home=self.home)
        return result, text_call

    def test_files_into_the_sweaters_meetings_folder(self):
        result, _ = self.run_meeting()
        path = Path(result["path"])
        self.assertEqual(path.parent, self.home / "home-ops" / "meetings")
        self.assertEqual(result["folder"], "home-ops")
        self.assertTrue(result["grandma"])
        self.assertIn("# Boiler repair quote", path.read_text())
        index = (self.home / "home-ops" / "meetings" / "meetings.md").read_text()
        self.assertIn("[Boiler repair quote](", index)
        self.assertIn("[home-ops/meetings/meetings.md]", (self.home / "INDEX.md").read_text())
        # Nothing new at the sweater root, which grandma loads into every session.
        self.assertEqual(sorted(p.name for p in (self.home / "home-ops").glob("*.md")), ["facts.md"])

    def test_writes_a_proposal_grandma_review_can_find(self):
        result, text_call = self.run_meeting()
        proposal = Path(result["proposal"])
        self.assertEqual(proposal.parent, self.home / "proposals")
        lines = proposal.read_text().split("\n")
        self.assertEqual(lines[0], "# grandma memory proposal")
        self.assertTrue(lines[1].startswith("# scope=home-ops  project=meetings  transcript="))
        self.assertIn(self.PROPOSAL, proposal.read_text())
        prompt = text_call.call_args[0][1]
        self.assertIn("The boiler quote came in.", prompt)
        self.assertIn("Running the house", prompt, "sweater memory is in the prompt")

    def test_no_durable_learnings_writes_no_proposal(self):
        result, _ = self.run_meeting(proposal="NO DURABLE LEARNINGS")
        self.assertNotIn("proposal", result)
        self.assertEqual(sorted(p.name for p in (self.home / "proposals").iterdir()), ["acme-x.md"])

    def test_proposal_failure_keeps_the_transcript(self):
        result, _ = self.run_meeting(proposal_error=mt.meeting_organize.OrganizeError("rate limited"))
        self.assertEqual(result["proposalError"], "rate limited")
        self.assertTrue(Path(result["path"]).exists())

    def test_no_sweater_fits_leaves_it_unfiled(self):
        result, text_call = self.run_meeting(answer={**self.ANSWER, "folder": ""})
        self.assertEqual(Path(result["path"]).parent, self.out)
        self.assertNotIn("folder", result)
        self.assertNotIn("proposal", result)
        text_call.assert_not_called()
        self.assertNotIn("meetings.md]", (self.home / "INDEX.md").read_text())

    def test_refile_moves_an_unfiled_transcript_into_a_sweater(self):
        result, _ = self.run_meeting(answer={**self.ANSWER, "folder": ""})
        unfiled = Path(result["path"])
        with mock.patch.object(mt.meeting_organize, "run_claude", return_value=self.ANSWER), \
             mock.patch.object(mt.meeting_organize, "run_claude_text", return_value=self.PROPOSAL):
            refiled = mt.refile(unfiled, self.out, "/bin/claude", grandma_home=self.home)
        self.assertFalse(unfiled.exists())
        self.assertEqual(Path(refiled["path"]).parent, self.home / "home-ops" / "meetings")
        self.assertIn("proposal", refiled)

    def test_refile_without_a_fitting_sweater_leaves_the_file(self):
        result, _ = self.run_meeting(answer={**self.ANSWER, "folder": ""})
        unfiled = Path(result["path"])
        with mock.patch.object(mt.meeting_organize, "run_claude", return_value={**self.ANSWER, "folder": "x"}):
            with self.assertRaisesRegex(mt.TranscribeError, "No grandma sweater"):
                mt.refile(unfiled, self.out, "/bin/claude", grandma_home=self.home)
        self.assertTrue(unfiled.exists())


if __name__ == "__main__":
    unittest.main()
