import datetime
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation"))

import voice_memory as vm  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "screens" / "grandma"


def jsonl(path, events):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(e) + "\n" for e in events))


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.support = self.root / "support"
        self.home = self.root / "grandma"
        (self.home / "proposals").mkdir(parents=True)
        for d in ("acme", "global"):
            (self.home / d).mkdir()
        (self.home / "acme" / "facts.md").write_text("---\nscope: acme\n---\nAcme sells shoes.\n")
        (self.home / "acme" / "projects.md").write_text("---\nscope: acme\n---\n\n## spring-launch\n- what: launch\n")
        (self.home / "global" / "identity.md").write_text("---\nscope: global\n---\nSam.\n")
        (self.home / "global" / "style.md").write_text("---\nscope: global\n---\n## Deliverable\n- short\n")

    def tearDown(self):
        self._tmp.cleanup()


class SecretsTest(Base):
    def test_sweater_memory_sent_to_claude_leaves_out_credentials(self):
        (self.home / "acme" / "api-tokens.md").write_text("---\nscope: acme\n---\nTOKEN_ABC")
        (self.home / "acme" / "linked.md").symlink_to(self.home / "global" / "identity.md")
        memory = vm.scope_memory(self.home, "acme")
        self.assertIn("Acme sells shoes.", memory)
        self.assertNotIn("TOKEN_ABC", memory)
        self.assertNotIn("linked.md", memory)


class DaysTest(Base):
    def test_pending_days_are_finished_and_not_yet_distilled(self):
        for day in ("2026-10-10", "2026-10-11", "2026-10-12"):
            jsonl(self.support / "interactions" / f"{day}.jsonl", [{"kind": "screen"}])
        (self.support / "interactions" / "notes.jsonl").write_text("")
        days = vm.pending_days(self.support, "2026-10-12", {"distilled": ["2026-10-10"]})
        self.assertEqual(days, ["2026-10-11"])

    def test_prune_deletes_old_style_dictations_even_when_never_read(self):
        for day in ("2026-08-01", "2026-10-01"):
            jsonl(self.support / "style" / f"{day}.jsonl", [{"text": "x"}])
        vm.prune(self.support, {}, "2026-10-12")
        self.assertEqual([f.stem for f in (self.support / "style").glob("*.jsonl")], ["2026-10-01"])

    def test_render_survives_damaged_lines(self):
        text = vm.render([{"question": "q", "memory": "acme", "opened": [1], "fields": "x", "fill": "y",
                           "answer_kind": "fill"}])
        self.assertIn("asked: q", text)
        self.assertEqual(vm.scope_for({"memory": "acme"}, []), "global")

    def test_prune_deletes_old_distilled_logs_only(self):
        for day in ("2026-08-01", "2026-08-02", "2026-10-01"):
            jsonl(self.support / "interactions" / f"{day}.jsonl", [{}])
        vm.prune(self.support, {"distilled": ["2026-08-01", "2026-10-01"]}, "2026-10-12")
        left = sorted(f.stem for f in (self.support / "interactions").glob("*.jsonl"))
        self.assertEqual(left, ["2026-08-02", "2026-10-01"])


class RoutingTest(Base):
    def items(self):
        return vm.grandma_context.entries(self.home)

    def test_an_interaction_goes_to_the_sweater_whose_memory_it_used(self):
        self.assertEqual(vm.scope_for({"memory": ["acme"]}, self.items()), "acme")
        self.assertEqual(vm.scope_for({"opened": ["spring-launch"]}, self.items()), "acme")
        self.assertEqual(vm.scope_for({"memory": []}, self.items()), "global")
        self.assertEqual(vm.scope_for({"memory": ["gone"]}, self.items()), "global")

    def test_render_keeps_corrections_with_what_they_correct(self):
        text = vm.render([
            {"at": "2026-10-12T10:00:00", "id": "a", "question": "fill this", "answer_kind": "fill",
             "fields": [{"label": "Logo", "file": "team.jpg", "skip": False}, {"label": "SKU", "skip": True}],
             "confirmed": False, "memory": ["acme"]},
            {"at": "2026-10-12T10:01:00", "id": "b", "question": "no, use the wide photo", "follows": "a",
             "answer_kind": "answer", "answer": "ok"},
            {"at": "2026-10-12T11:00:00", "kind": "flag", "raw": "talk to a nut", "pasted": "talk to a nut"},
        ])
        self.assertIn("planned a fill: Logo=team.jpg; SKU=[skip]", text)
        self.assertIn("user cancelled the plan", text)
        self.assertIn("(a follow-up to a a moment before)", text)
        self.assertIn("flagged a dictation", text)
        self.assertIn("[10:01]", text)


class DistillTest(Base):
    def test_one_proposal_per_sweater_with_a_scope_header(self):
        jsonl(self.support / "interactions" / "2026-10-11.jsonl", [
            {"at": "2026-10-11T09:00:00", "question": "q1", "answer_kind": "answer", "memory": ["acme"]},
            {"at": "2026-10-11T09:05:00", "question": "q2", "answer_kind": "answer"},
        ])
        replies = iter(["1. target: acme/facts.md\n   text: Acme photos are in acme/brand.", vm.NONE])
        with mock.patch.object(vm.meeting_organize, "run_claude_text", side_effect=lambda *a, **k: next(replies)) as run:
            paths = vm.distill_day(self.home, self.support, "2026-10-11", "claude")
        self.assertEqual(len(paths), 1)
        self.assertEqual(paths[0].name, "acme-voice-20261011.md")
        text = paths[0].read_text()
        self.assertTrue(text.startswith("# grandma memory proposal\n# scope=acme  project=voice"))
        prompts = [c.args[1] for c in run.call_args_list]
        self.assertIn('<memory scope="acme">', prompts[0])
        self.assertIn("q1", prompts[0])
        self.assertNotIn("q2", prompts[0])

    def test_dry_run_writes_elsewhere(self):
        jsonl(self.support / "interactions" / "2026-10-11.jsonl", [{"question": "q", "memory": ["acme"]}])
        out = self.root / "dry"
        with mock.patch.object(vm.meeting_organize, "run_claude_text", return_value="1. a fact"):
            paths = vm.distill_day(self.home, self.support, "2026-10-11", "claude", out_dir=out)
        self.assertEqual(paths[0].parent, out)
        self.assertEqual(list((self.home / "proposals").iterdir()), [])

    def test_cli_marks_days_done(self):
        jsonl(self.support / "interactions" / "2000-01-01.jsonl", [{"question": "q"}])
        with mock.patch.object(vm.meeting_organize, "run_claude_text", return_value=vm.NONE), \
                mock.patch("sys.stdout"):
            code = vm.main(["--grandma-home", str(self.home), "--support", str(self.support), "--distill",
                            "--claude", "claude"])
        self.assertEqual(code, 0)
        self.assertIn("2000-01-01", vm.load_state(self.support)["distilled"])


    def run_cli(self, *extra):
        with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            return vm.main(["--grandma-home", str(self.home), "--support", str(self.support), "--distill",
                            "--claude", "claude", *extra])

    def test_a_failed_sweater_is_retried_without_proposing_the_others_again(self):
        jsonl(self.support / "interactions" / "2000-01-01.jsonl", [
            {"question": "q1", "memory": ["acme"]}, {"question": "q2"}])
        calls = []

        def flaky(claude, prompt, **kw):
            calls.append(prompt)
            if 'scope="global"' in prompt and len(calls) == 2:
                raise vm.meeting_organize.OrganizeError("Claude took too long to respond")
            return "1. target: acme/facts.md\n   text: a fact"
        with mock.patch.object(vm.meeting_organize, "run_claude_text", side_effect=flaky):
            self.assertEqual(self.run_cli(), 1)
            self.assertNotIn("2000-01-01", vm.load_state(self.support).get("distilled", []))
            self.assertEqual(self.run_cli(), 0)
        self.assertEqual(len(calls), 3)
        self.assertNotIn('scope="acme"', calls[2])
        names = sorted(p.name for p in (self.home / "proposals").iterdir())
        self.assertEqual(names, ["acme-voice-20000101.md", "global-voice-20000101.md"])
        state = vm.load_state(self.support)
        self.assertIn("2000-01-01", state["distilled"])
        self.assertEqual(state["partial"], {})

    def test_a_second_run_waits_for_the_first(self):
        jsonl(self.support / "interactions" / "2000-01-01.jsonl", [{"question": "q"}])
        with vm.locked(self.support) as only, \
                mock.patch.object(vm.meeting_organize, "run_claude_text") as run:
            self.assertTrue(only)
            self.assertEqual(self.run_cli(), 0)
        run.assert_not_called()
        self.assertNotIn("distilled", vm.load_state(self.support))

    def test_rejects_a_day_that_is_not_a_date(self):
        self.assertEqual(self.run_cli("--day", "../../etc"), 1)

    def test_never_quotes_a_flagged_dictation(self):
        jsonl(self.support / "interactions" / "2026-10-11.jsonl", [
            {"at": "2026-10-11T11:00:00", "kind": "flag", "raw": "tell Sam the Acme deal closes on the ninth",
             "pasted": "Tell Sam the Acme deal closes on the ninth."}])
        reply = "1. target: global/identity.md\n   text: The Acme deal closes on the ninth."
        with mock.patch.object(vm.meeting_organize, "run_claude_text", return_value=reply), \
                mock.patch("sys.stderr"):
            self.assertEqual(vm.distill_day(self.home, self.support, "2026-10-11", "claude"), [])


class RememberTest(Base):
    def reply(self, line, kind="fact"):
        return {"content": [{"type": "text", "text": json.dumps({"line": line, "kind": kind})}]}

    def test_routes_to_a_named_sweater(self):
        with mock.patch.object(vm.nfg, "post_messages", return_value=self.reply("Acme photos are in ~/photos.")):
            r = vm.remember(self.home, "the acme photos are in ~/photos", "k", "m", today="2026-10-12")
        self.assertEqual((r["scope"], r["target"]), ("acme", "acme/facts.md"))
        text = Path(r["path"]).read_text()
        self.assertIn("# scope=acme  project=voice  source=remember", text)
        self.assertIn("text: Acme photos are in ~/photos.", text)

    def test_named_project_and_global_preferences(self):
        with mock.patch.object(vm.nfg, "post_messages", return_value=self.reply("Launch moved to May.")):
            r = vm.remember(self.home, "spring launch moved to May", "k", "m")
        self.assertEqual(r["scope"], "acme")
        self.assertIn("spring-launch", r["target"])
        with mock.patch.object(vm.nfg, "post_messages", return_value=self.reply("Prefers calls.", "preference")):
            r = vm.remember(self.home, "I prefer calls to email", "k", "m")
        self.assertEqual((r["scope"], r["target"]), ("global", "global/preferences.md"))

    def test_rejects_empty_or_malformed_answers(self):
        with mock.patch.object(vm.nfg, "post_messages", return_value={"content": [{"type": "text", "text": "x"}]}):
            with self.assertRaises(vm.VoiceError):
                vm.remember(self.home, "something", "k", "m")


class StyleTest(Base):
    def buffer(self, n, text="We should ship the pricing page on Friday after the review with design"):
        jsonl(self.support / "style" / "2026-10-12.jsonl",
              [{"at": "2026-10-12T10:00:00", "app": "Slack", "text": f"{text} {i}"} for i in range(n)])

    def test_due_after_enough_dictations_or_a_week(self):
        now = datetime.datetime(2026, 10, 12)
        self.assertTrue(vm.style_due(150, "2026-10-11T00:00:00", now))
        self.assertFalse(vm.style_due(19, None, now))
        self.assertTrue(vm.style_due(20, None, now))
        self.assertFalse(vm.style_due(40, "2026-10-10T00:00:00", now))
        self.assertTrue(vm.style_due(40, "2026-10-01T00:00:00", now))

    def test_finds_six_words_in_a_row_from_a_dictation(self):
        samples = ["Hey Priya, can we move the pricing call to Thursday?"]
        self.assertEqual(vm.leaks("They often ask: can we move the pricing call to later", samples),
                         "can we move the pricing call")
        self.assertIsNone(vm.leaks("Opens with a greeting and asks to reschedule.", samples))

    def test_leak_check_ignores_case_punctuation_and_curly_apostrophes(self):
        samples = ["I don't think we can make Friday, José."]
        self.assertEqual(vm.leaks("I DON\u2019T think: we can make it", samples), "i dont think we can make")
        self.assertEqual(vm.leaks("we can make Friday jose", samples), None)
        self.assertEqual(vm.leaks("think we can make friday josé", samples), "think we can make friday josé")

    def test_writes_a_global_proposal_and_clears_the_buffer(self):
        self.buffer(160)
        with mock.patch.object(vm.meeting_organize, "run_claude_text",
                               return_value="Spoken: short asks, opens with the request.") as run:
            r = vm.style(self.home, self.support, "claude", now=datetime.datetime(2026, 10, 12))
        self.assertIn("[Slack] We should ship", run.call_args.args[1])
        self.assertIn("## Deliverable", run.call_args.args[1])
        text = Path(r["path"]).read_text()
        self.assertIn("# scope=global  project=style", text)
        self.assertEqual(list((self.support / "style").glob("*.jsonl")), [])
        self.assertEqual(vm.load_state(self.support)["style_last"], "2026-10-12T00:00:00")

    def test_refuses_a_proposal_that_quotes_a_dictation(self):
        self.buffer(160)
        leak = "Example: We should ship the pricing page on Friday."
        with mock.patch.object(vm.meeting_organize, "run_claude_text", return_value=leak):
            r = vm.style(self.home, self.support, "claude")
        self.assertIn("refused", r["skipped"])
        self.assertEqual(list((self.home / "proposals").iterdir()), [])

    def test_not_due_does_nothing(self):
        self.buffer(5)
        with mock.patch.object(vm.meeting_organize, "run_claude_text") as run:
            r = vm.style(self.home, self.support, "claude")
        run.assert_not_called()
        self.assertIn("not due", r["skipped"])
        self.assertEqual(len(list((self.support / "style").glob("*.jsonl"))), 1)


if __name__ == "__main__":
    unittest.main()
