#!/usr/bin/env python3
"""Import a Wispr Flow custom dictionary into a deepgram-dictation dictionary file.

Wispr Flow entries without a replacement become Deepgram keyterms (spelling hints);
entries with a replacement (including snippets) become text replacements.
Existing entries in the output file are kept; imported entries are merged in.
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = Path.home() / "Library/Application Support/Wispr Flow/flow.sqlite"
DEFAULT_OUTPUT = Path.home() / ".hammerspoon/deepgram-dictionary.json"


def read_wispr_dictionary(db_path):
    """Return (keyterms, replacements) from a Wispr Flow database, opened read-only."""
    uri = f"file:{Path(db_path).resolve()}?mode=ro"
    with sqlite3.connect(uri, uri=True) as db:
        rows = db.execute(
            "SELECT phrase, replacement FROM Dictionary WHERE isDeleted = 0 ORDER BY createdAt"
        ).fetchall()
    keyterms = [phrase for phrase, replacement in rows if not replacement]
    replacements = [{"from": phrase, "to": replacement} for phrase, replacement in rows if replacement]
    return keyterms, replacements


def merge(existing, keyterms, replacements):
    """Merge imported entries into an existing dictionary dict without duplicates."""
    merged_terms = list(existing.get("keyterms", []))
    for term in keyterms:
        if term not in merged_terms:
            merged_terms.append(term)

    merged_repl = list(existing.get("replacements", []))
    known = {r["from"].lower() for r in merged_repl}
    for r in replacements:
        if r["from"].lower() not in known:
            merged_repl.append(r)
            known.add(r["from"].lower())

    return {"keyterms": merged_terms, "replacements": merged_repl}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="Wispr Flow flow.sqlite path")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="dictionary JSON to write")
    args = parser.parse_args(argv)

    if not args.db.exists():
        print(f"Wispr Flow database not found at {args.db}", file=sys.stderr)
        return 1

    keyterms, replacements = read_wispr_dictionary(args.db)
    existing = json.loads(args.output.read_text()) if args.output.exists() else {}
    result = merge(existing, keyterms, replacements)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"Imported {len(keyterms)} keyterms and {len(replacements)} replacements into {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
