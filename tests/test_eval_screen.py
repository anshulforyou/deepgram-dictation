import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import eval_screen as ev  # noqa: E402


class GradeTest(unittest.TestCase):
    CASE = {"kind": "answer", "include": [["Billing"], ["sidebar", "left"]], "exclude": ["**"]}

    def test_passes_when_every_group_matches(self):
        self.assertEqual(ev.grade(self.CASE, "answer", "Click billing in the left menu."), [])

    def test_reports_wrong_kind_missing_words_and_forbidden_ones(self):
        problems = ev.grade(self.CASE, "insert", "**Settings**")
        self.assertEqual(problems, ["kind insert, expected answer", "missing 'Billing'",
                                    "missing 'sidebar' / 'left'", "contains '**'"])

    def test_memory_must_match_when_the_case_says(self):
        case = {"kind": "answer", "memory": ["acme"]}
        self.assertEqual(ev.grade(case, "answer", "x", ["acme"]), [])
        self.assertEqual(ev.grade(case, "answer", "x", ["acme", "spring-launch"]),
                         ["memory ['acme', 'spring-launch'], expected ['acme']"])
        self.assertEqual(ev.grade({"kind": "answer"}, "answer", "x", ["acme"]), [])

    def test_memory_any(self):
        case = {"kind": "answer", "memory_any": ["acme", "spring-launch"]}
        self.assertEqual(ev.grade(case, "answer", "x", ["spring-launch"]), [])
        self.assertTrue(ev.grade(case, "answer", "x", []))
        self.assertTrue(ev.grade(case, "answer", "x", ["garden-club"]))

    def test_fill_plans(self):
        case = {"kind": "fill", "fill": {"price": ["139"]}, "skip": ["sku"]}
        self.assertEqual(ev.grade(case, "fill", "Title: Trailrunner 2\nPrice: $139\nSKU: [skip]"), [])
        self.assertTrue(ev.grade(case, "fill", "Price: [skip]"))
        self.assertTrue(ev.grade(case, "fill", "Price: 139\nSKU: TR2-001"))
        reply = '{"kind": "fill", "text": "x", "fields": [{"label": "Price", "value": "139", "skip": false},' \
                ' {"label": "SKU", "value": "", "skip": false}]}'
        self.assertEqual(ev.parse_answer(self.reply_like(reply)), ("fill", "Price: 139\nSKU: [skip]"))

    def reply_like(self, text):
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}

    def test_kind_any(self):
        self.assertEqual(ev.grade({"kind": "answer", "kind_any": True}, "insert", "x"), [])

    def test_password_check(self):
        case = {"kind": "insert", "check": "password"}
        self.assertEqual(ev.grade(case, "insert", "Harbor7Window42"), [])
        self.assertTrue(ev.grade(case, "insert", "sunshine"))


class TaskTest(unittest.TestCase):
    TASK = ('{"kind": "task", "text": "x", "fields": [], "task": {"title": "Review PR 42", "goal": "Review it",'
            ' "target": "github.com/acme/storefront/pull/42", "memory": "storefront", "edits": false, "minutes": 5}}')

    def test_reads_a_task_and_grades_what_it_says(self):
        reply = {"stop_reason": "end_turn", "content": [{"type": "text", "text": self.TASK}]}
        kind, text = ev.parse_answer(reply)
        self.assertEqual("task", kind)
        case = {"kind": "task", "include": [], "exclude": [],
                "task": {"target": ["pull/42"], "memory": ["storefront"], "edits": False}}
        self.assertEqual([], ev.grade(case, kind, text))
        case["task"]["edits"] = True
        self.assertEqual(["task edits is False, expected True"], ev.grade(case, kind, text))


class ParseAnswerTest(unittest.TestCase):
    def reply(self, text, stop="end_turn"):
        return {"stop_reason": stop, "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": text}]}

    def test_reads_structured_answers(self):
        self.assertEqual(ev.parse_answer(self.reply('{"kind": "insert", "text": " Hi "}')), ("insert", "Hi"))

    def test_falls_back_to_an_answer_like_the_app(self):
        self.assertEqual(ev.parse_answer(self.reply("Click Billing.")), ("answer", "Click Billing."))
        self.assertEqual(ev.parse_answer(self.reply('{"kind": "shout", "text": "x"}'))[0], "answer")

    def test_non_object_json_is_still_an_answer(self):
        self.assertEqual(ev.parse_answer(self.reply("[1, 2]")), ("answer", "[1, 2]"))
        self.assertEqual(ev.parse_answer(self.reply('{"kind": "insert", "text": 3}'))[0], "answer")

    def test_refusal(self):
        self.assertEqual(ev.parse_answer(self.reply("", "refusal")), (None, "Claude declined to answer"))

    def test_reports_stops(self):
        self.assertEqual(ev.parse_answer(self.reply("{", "max_tokens")), (None, "stopped: max_tokens"))

    def test_every_case_names_a_rendered_screen(self):
        import json
        for case in json.loads((ev.SCREENS / "cases.json").read_text()):
            self.assertTrue((ev.SCREENS / f"{case['screen']}.png").exists(), case["screen"])
            self.assertIn(case["kind"], ("insert", "answer", "fill", "task"))


if __name__ == "__main__":
    unittest.main()
