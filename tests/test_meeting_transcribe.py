import json
import sys
import tempfile
import unittest
import urllib.parse
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src" / "deepgram_dictation"))

import meeting_transcribe as mt  # noqa: E402


def utt(track, speaker, start, end, text):
    return {"track": track, "speaker": speaker, "start": start, "end": end, "text": text}


def deepgram_response(*utterances):
    return {"results": {"utterances": [
        {"speaker": s, "start": a, "end": b, "transcript": t} for s, a, b, t in utterances
    ]}}


class BuildUrlTest(unittest.TestCase):
    def test_includes_diarization_and_keyterms(self):
        url = mt.build_url("nova-3", "en", ["Jane Doe", "Hammerspoon"])
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        self.assertEqual(query["model"], ["nova-3"])
        self.assertEqual(query["diarize"], ["true"])
        self.assertEqual(query["utterances"], ["true"])
        self.assertEqual(query["keyterm"], ["Jane Doe", "Hammerspoon"])
        self.assertIn("keyterm=Jane%20Doe", url)


class UtterancesTest(unittest.TestCase):
    def test_applies_offset_and_skips_empty(self):
        resp = deepgram_response((0, 1.0, 2.0, "Hello"), (1, 3.0, 4.0, "  "))
        out = mt.utterances_from_response(resp, "system", offset=0.5)
        self.assertEqual(out, [utt("system", 0, 1.5, 2.5, "Hello")])

    def test_handles_missing_results(self):
        self.assertEqual(mt.utterances_from_response({}, "mic"), [])
        self.assertEqual(mt.utterances_from_response({"results": {}}, "mic"), [])


class DropEchoTest(unittest.TestCase):
    def test_drops_mic_copy_of_remote_speech(self):
        system = [utt("system", 0, 10.0, 12.0, "Let's review the budget today.")]
        mic = [utt("mic", 0, 10.2, 12.1, "let's review the budget today"),
               utt("mic", 0, 13.0, 14.0, "Sounds good to me.")]
        kept = mt.drop_echo(mic, system)
        self.assertEqual([m["text"] for m in kept], ["Sounds good to me."])

    def test_keeps_mic_speech_far_from_matching_system_speech(self):
        system = [utt("system", 0, 0.0, 1.0, "yes")]
        mic = [utt("mic", 0, 30.0, 31.0, "yes")]
        self.assertEqual(mt.drop_echo(mic, system), mic)

    def test_keeps_partial_overlap(self):
        system = [utt("system", 0, 5.0, 6.0, "the budget")]
        mic = [utt("mic", 0, 5.0, 7.0, "I think the budget needs more marketing spend")]
        self.assertEqual(mt.drop_echo(mic, system), mic)


class RecordingNotesTest(unittest.TestCase):
    @staticmethod
    def utt(words, track="mic"):
        return {"start": 0.0, "end": 1.0, "text": " ".join(["word"] * words), "speaker": 0, "track": track}

    def test_keeps_recorder_warnings(self):
        notes = mt.recording_notes({"warnings": ["mic blocked"]}, [], [], online=False)
        self.assertEqual(notes, ["mic blocked"])

    def test_mentions_pauses(self):
        notes = mt.recording_notes({"pausedSeconds": 192.4}, [self.utt(5)], [], online=False)
        self.assertEqual(len(notes), 1)
        self.assertIn("paused for 03:12", notes[0])
        self.assertEqual(mt.recording_notes({"pausedSeconds": 0.2}, [], [], online=False), [])

    def test_warns_when_computer_audio_is_nearly_silent(self):
        notes = mt.recording_notes({}, [self.utt(2807)], [self.utt(1, "system")], online=True)
        self.assertEqual(len(notes), 1)
        self.assertIn("only 1 word against 2807", notes[0])

    def test_no_warning_for_a_normal_conversation(self):
        self.assertEqual(mt.recording_notes({}, [self.utt(500)], [self.utt(300, "system")], online=True), [])
        # Short meetings are too small to judge.
        self.assertEqual(mt.recording_notes({}, [self.utt(50)], [self.utt(1, "system")], online=True), [])

    def test_in_person_never_warns_about_computer_audio(self):
        self.assertEqual(mt.recording_notes({}, [self.utt(500)], [], online=False), [])


class LabelAndMergeTest(unittest.TestCase):
    def test_online_mic_is_me_and_remote_numbered_by_appearance(self):
        utts = [utt("system", 3, 5.0, 6.0, "b"), utt("mic", 0, 0.0, 1.0, "a"), utt("system", 1, 2.0, 3.0, "c")]
        labelled = mt.label_speakers(utts, online=True)
        by_text = {u["text"]: u["label"] for u in labelled}
        self.assertEqual(by_text, {"a": "Me", "c": "Speaker 1", "b": "Speaker 2"})

    def test_in_person_numbers_mic_speakers(self):
        utts = [utt("mic", 1, 0.0, 1.0, "a"), utt("mic", 0, 2.0, 3.0, "b"), utt("mic", 1, 4.0, 5.0, "c")]
        labels = [u["label"] for u in mt.label_speakers(utts, online=False)]
        self.assertEqual(labels, ["Speaker 1", "Speaker 2", "Speaker 1"])

    def test_merges_close_same_speaker_turns_only(self):
        utts = [dict(utt("mic", 0, 0.0, 1.0, "Hi."), label="Me"),
                dict(utt("mic", 0, 1.5, 2.0, "How are you?"), label="Me"),
                dict(utt("system", 0, 2.2, 3.0, "Good."), label="Speaker 1"),
                dict(utt("system", 0, 9.0, 10.0, "Anyway."), label="Speaker 1")]
        merged = mt.merge_consecutive(utts)
        self.assertEqual([(m["label"], m["text"]) for m in merged], [
            ("Me", "Hi. How are you?"), ("Speaker 1", "Good."), ("Speaker 1", "Anyway."),
        ])


class RenderTest(unittest.TestCase):
    def test_format_timestamp(self):
        self.assertEqual(mt.format_timestamp(0), "00:00")
        self.assertEqual(mt.format_timestamp(65.9), "01:05")
        self.assertEqual(mt.format_timestamp(3723), "1:02:03")

    def test_markdown_contains_header_notes_and_turns(self):
        utts = [dict(utt("mic", 0, 0.0, 1.0, "Hello."), label="Me"),
                dict(utt("system", 0, 65.0, 66.0, "Hi!"), label="Speaker 1")]
        md = mt.render_markdown(utts, datetime(2026, 10, 9, 14, 30), 125, True, ["Heads up"])
        self.assertIn("# Meeting transcript\n", md)
        self.assertIn("- **Date:** Fri 9 Oct 2026, 14:30", md)
        self.assertIn("## Transcript", md)
        self.assertNotIn("## Summary", md)
        self.assertIn("- **Duration:** 02:05", md)
        self.assertIn("- **Speakers:** Me, Speaker 1", md)
        self.assertIn("> Heads up", md)
        self.assertIn("**Speaker 1** · 01:05\nHi!", md)

    def test_markdown_with_claude_summary(self):
        md = mt.render_markdown([], datetime(2026, 10, 9, 14, 30), 10, True, title="Launch plan sync",
                                summary="We agreed on Friday.", action_items=["Asha: send deck"])
        self.assertTrue(md.startswith("# Launch plan sync\n"))
        self.assertIn("## Summary\n\nWe agreed on Friday.", md)
        self.assertIn("## Action items\n\n- [ ] Asha: send deck", md)
        self.assertLess(md.index("## Action items"), md.index("## Transcript"))

    def test_markdown_for_silence(self):
        md = mt.render_markdown([], datetime(2026, 10, 9, 14, 30), 10, False)
        self.assertIn("_No speech detected._", md)
        self.assertIn("microphone (in person)", md)

    def test_transcript_path_avoids_overwriting(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            first = mt.transcript_path(out, datetime(2026, 10, 9, 14, 30))
            first.write_text("x")
            second = mt.transcript_path(out, datetime(2026, 10, 9, 14, 30))
            self.assertEqual(first.name, "2026-10-09 14-30 Meeting.md")
            self.assertEqual(second.name, "2026-10-09 14-30 Meeting (2).md")
            titled = mt.transcript_path(out, datetime(2026, 10, 9, 14, 30), "Q3 / Q4 plan: draft")
            self.assertEqual(titled.name, "2026-10-09 14-30 Q3 - Q4 plan- draft.md")


class RefileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        utts = [dict(utt("mic", 0, 4.0, 5.0, "Morning, can you hear me?"), label="Me"),
                dict(utt("system", 0, 65.0, 66.0, "Yes. Let's review the launch."), label="Speaker 1")]
        self.md = mt.render_markdown(utts, datetime(2026, 10, 9, 18, 1), 2501, True, ["A note"])
        self.path = self.root / "2026-10-09 18-01 Meeting.md"
        self.path.write_text(self.md)

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse_round_trips_render_markdown(self):
        started_at, duration, online, notes, utts = mt.parse_transcript_markdown(self.md)
        self.assertEqual(started_at, datetime(2026, 10, 9, 18, 1))
        self.assertEqual(duration, 2501)
        self.assertTrue(online)
        self.assertEqual(notes, ["A note"])
        self.assertEqual([(u["label"], u["start"], u["text"]) for u in utts], [
            ("Me", 4.0, "Morning, can you hear me?"), ("Speaker 1", 65.0, "Yes. Let's review the launch."),
        ])

    def test_parse_rejects_other_markdown(self):
        with self.assertRaises(mt.TranscribeError):
            mt.parse_transcript_markdown("# Shopping list\n- milk\n")

    def test_refile_moves_into_folder_and_indexes(self):
        answer = {"folder": "Product Launch", "title": "Launch review", "summary": "Reviewed it.",
                  "action_items": []}
        with mock.patch.object(mt.meeting_organize, "run_claude", return_value=answer):
            result = mt.refile(self.path, self.root, "/bin/claude")
        new = Path(result["path"])
        self.assertFalse(self.path.exists())
        self.assertEqual(new.parent, self.root / "Product Launch")
        self.assertIn("# Launch review", new.read_text())
        self.assertIn("**Me** · 00:04\nMorning, can you hear me?", new.read_text())
        self.assertIn("[Launch review](", (self.root / "Product Launch" / "meetings.md").read_text())

    def test_refile_failure_leaves_transcript_in_place(self):
        with mock.patch.object(mt.meeting_organize, "run_claude",
                               side_effect=mt.meeting_organize.OrganizeError("offline")):
            with self.assertRaisesRegex(mt.TranscribeError, "offline"):
                mt.refile(self.path, self.root, "/bin/claude")
        self.assertTrue(self.path.exists())


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.session = root / "session"
        self.out = root / "out"
        self.session.mkdir()
        (self.session / "mic.m4a").write_bytes(b"\0" * 4096)
        (self.session / "system.m4a").write_bytes(b"\0" * 4096)
        (self.session / "status.json").write_text(json.dumps({
            "state": "stopped", "captureSystem": True, "startedAt": "2026-10-09T09:00:00Z",
            "duration": 30.0, "micOffset": 0.1, "systemOffset": 0.2,
        }))
        self.responses = {
            "mic.m4a": deepgram_response((0, 1.0, 2.0, "Can everyone hear me?"),
                                         (0, 5.0, 6.0, "Great, let's start.")),
            "system.m4a": deepgram_response((0, 3.0, 4.0, "Yes, loud and clear."),
                                            (1, 4.0, 4.6, "Same here.")),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def fake_post(self, path, url, api_key, timeout=900):
        self.assertEqual(api_key, "secret")
        return self.responses[path.name]

    def test_end_to_end_writes_transcript_and_removes_audio(self):
        with mock.patch.object(mt, "post_audio", self.fake_post), \
             mock.patch.object(mt, "read_api_key", return_value="secret"):
            result = mt.run(self.session, self.out, "nova-3", "en", "deepgram-api-key")

        md = Path(result["path"]).read_text()
        self.assertEqual(result["speakers"], ["Me", "Speaker 1", "Speaker 2"])
        self.assertLess(md.index("Can everyone hear me?"), md.index("Yes, loud and clear."))
        self.assertLess(md.index("Same here."), md.index("Great, let's start."))
        self.assertFalse(self.session.exists())

    def test_keep_audio_and_cached_responses_skip_the_api(self):
        for track, resp in (("mic", self.responses["mic.m4a"]), ("system", self.responses["system.m4a"])):
            (self.session / f"deepgram-{track}.json").write_text(json.dumps(resp))
        with mock.patch.object(mt, "post_audio", side_effect=AssertionError("API called")), \
             mock.patch.object(mt, "read_api_key", side_effect=AssertionError("key read")):
            result = mt.run(self.session, self.out, "nova-3", "en", "k", keep_audio=True)
        self.assertTrue((self.session / "mic.m4a").exists())
        self.assertEqual((self.session / "transcript.txt").read_text(), result["path"])

    def test_warns_when_online_meeting_has_no_computer_audio(self):
        self.responses["system.m4a"] = deepgram_response()
        with mock.patch.object(mt, "post_audio", self.fake_post), \
             mock.patch.object(mt, "read_api_key", return_value="secret"):
            result = mt.run(self.session, self.out, "nova-3", "en", "k")
        self.assertIn("No speech was captured from computer audio", Path(result["path"]).read_text())

    def test_organizes_into_folder_with_index(self):
        claude_answer = {"folder": "product launch", "title": "Launch kickoff",
                         "summary": "Kicked off the launch.", "action_items": ["Me: book venue"]}
        (self.out / "Product Launch").mkdir(parents=True)
        with mock.patch.object(mt, "post_audio", self.fake_post), \
             mock.patch.object(mt, "read_api_key", return_value="secret"), \
             mock.patch.object(mt.meeting_organize, "run_claude", return_value=claude_answer) as claude:
            result = mt.run(self.session, self.out, "nova-3", "en", "k", claude_path="/bin/claude")

        self.assertEqual(result["folder"], "Product Launch")  # reused existing folder despite case
        path = Path(result["path"])
        self.assertEqual(path.parent, self.out / "Product Launch")
        self.assertIn("Launch kickoff", path.name)
        self.assertIn("## Summary", path.read_text())
        index = (self.out / "Product Launch" / "meetings.md").read_text()
        self.assertIn("[Launch kickoff](", index)
        self.assertIn("Can everyone hear me?", claude.call_args[0][1])  # transcript sent to Claude

    def test_organize_failure_still_saves_transcript(self):
        with mock.patch.object(mt, "post_audio", self.fake_post), \
             mock.patch.object(mt, "read_api_key", return_value="secret"), \
             mock.patch.object(mt.meeting_organize, "run_claude",
                               side_effect=mt.meeting_organize.OrganizeError("not logged in")):
            result = mt.run(self.session, self.out, "nova-3", "en", "k", claude_path="/bin/claude")
        self.assertEqual(result["organizeError"], "not logged in")
        self.assertEqual(Path(result["path"]).parent, self.out)
        self.assertNotIn("folder", result)

    def test_main_reports_errors_as_json(self):
        (self.session / "status.json").unlink()
        with mock.patch("builtins.print") as printed:
            code = mt.main([str(self.session), "--output-dir", str(self.out)])
        self.assertEqual(code, 1)
        self.assertIn('"error"', printed.call_args[0][0])


if __name__ == "__main__":
    unittest.main()
