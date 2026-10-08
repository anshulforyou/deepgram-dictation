import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import import_wispr_dictionary as importer  # noqa: E402


def make_wispr_db(path, rows):
    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TABLE Dictionary (phrase TEXT, replacement TEXT, isDeleted INTEGER, createdAt TEXT)"
        )
        db.executemany("INSERT INTO Dictionary VALUES (?, ?, ?, ?)", rows)


class ImportWisprDictionaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.db = self.dir / "flow.sqlite"
        make_wispr_db(self.db, [
            ("Hammerspoon", None, 0, "2026-01-01"),
            ("btw", "by the way", 0, "2026-01-02"),
            ("Jane Doe", "", 0, "2026-01-03"),
            ("deleted", None, 1, "2026-01-04"),
        ])

    def tearDown(self):
        self.tmp.cleanup()

    def test_reads_keyterms_and_replacements(self):
        keyterms, replacements = importer.read_wispr_dictionary(self.db)
        self.assertEqual(keyterms, ["Hammerspoon", "Jane Doe"])
        self.assertEqual(replacements, [{"from": "btw", "to": "by the way"}])

    def test_merge_keeps_existing_and_skips_duplicates(self):
        existing = {
            "keyterms": ["Hammerspoon", "Kubernetes"],
            "replacements": [{"from": "BTW", "to": "custom"}],
        }
        result = importer.merge(existing, ["Hammerspoon", "Jane Doe"], [{"from": "btw", "to": "by the way"}])
        self.assertEqual(result["keyterms"], ["Hammerspoon", "Kubernetes", "Jane Doe"])
        self.assertEqual(result["replacements"], [{"from": "BTW", "to": "custom"}])

    def test_main_writes_output_file(self):
        out = self.dir / "nested" / "dict.json"
        code = importer.main(["--db", str(self.db), "--output", str(out)])
        self.assertEqual(code, 0)
        data = json.loads(out.read_text())
        self.assertEqual(data["keyterms"], ["Hammerspoon", "Jane Doe"])

    def test_main_fails_when_db_missing(self):
        code = importer.main(["--db", str(self.dir / "missing.sqlite"), "--output", str(self.dir / "o.json")])
        self.assertEqual(code, 1)

    def test_does_not_modify_database(self):
        before = self.db.read_bytes()
        importer.read_wispr_dictionary(self.db)
        self.assertEqual(before, self.db.read_bytes())


if __name__ == "__main__":
    unittest.main()
