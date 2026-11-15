#!/usr/bin/env python3
"""Run the claims `docs/sqlite.md` makes about compatibility.

The block between a line starting with ```` ```compat ```` and the closing fence
is the table this script executes. Each row is

    claim | statement | expectation

and `claim` is one of:

    matches  the answer must equal what sqlite3 answers, and the expectation
    ours     the answer must equal the expectation, and sqlite3 must answer
             something else (a difference the document states on purpose)
    refused  the statement must fail, and its message must contain expectation

A claim in the document that this script cannot pass is a document that lies, so
the table is a gate (`scripts/ci.py`, "documented compatibility") and the same
words are what a reader sees. Nothing here needs a database on disk: every
statement runs on its own in-memory database through the CLI and through
PySQLite, which is also what makes the block a second opinion on both.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "sqlite.md")
OPEN_FENCE = "```compat"
CLAIMS = ("matches", "ours", "refused")


def read_claims(path: str) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    inside = False
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            text = line.rstrip("\n")
            if not inside:
                if text.strip().startswith(OPEN_FENCE):
                    inside = True
                continue
            if text.strip() == "```":
                inside = False
                continue
            text = text.strip()
            if not text or text.startswith("#"):
                continue
            cells = [cell.strip() for cell in text.split("|")]
            if len(cells) != 3:
                raise SystemExit(
                    "%s:%d: a claim needs three cells (claim | statement | expectation): %r"
                    % (path, number, text)
                )
            claim, statement, expected = cells
            if claim not in CLAIMS:
                raise SystemExit("%s:%d: unknown claim %r" % (path, number, claim))
            rows.append((claim, statement, expected))
    if not rows:
        raise SystemExit("%s: no ```compat block found" % path)
    return rows


def normalize(value):
    """A boolean is 1 or 0 in SQL, and sqlite3 says so."""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def same(left, right) -> bool:
    left, right = normalize(left), normalize(right)
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(same(a, b) for a, b in zip(left, right))
    if isinstance(left, float) and isinstance(right, float):
        return abs(left - right) <= 1e-12 * max(1.0, abs(left), abs(right))
    return left == right


def run_ours(binary: str, statement: str) -> tuple[object, str]:
    done = subprocess.run(
        [binary, "sql", ":memory:", statement, "--json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if done.returncode != 0:
        return None, (done.stderr or done.stdout).strip()
    return json.loads(done.stdout), ""


def run_sqlite(statement: str) -> object:
    connection = sqlite3.connect(":memory:")
    try:
        return [list(row) for row in connection.execute(statement).fetchall()]
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=os.path.join(ROOT, "bin", "miraidb.exe"))
    parser.add_argument("--doc", default=DOC)
    args = parser.parse_args()

    failures = 0
    for claim, statement, expected in read_claims(args.doc):
        ours, message = run_ours(args.bin, statement)
        if claim == "refused":
            if ours is not None:
                print("FAIL refused  %s\n     answered %s" % (statement, json.dumps(ours, ensure_ascii=False)))
                failures += 1
                continue
            if expected.lower() not in message.lower():
                print("FAIL refused  %s\n     said %r, expected %q" % (statement, message, expected))
                failures += 1
                continue
            print("ok   refused  %s (%s)" % (statement, expected))
            continue
        if ours is None:
            print("FAIL %-8s %s\n     refused: %s" % (claim, statement, message))
            failures += 1
            continue
        wanted = json.loads(expected)
        if not same(ours, wanted):
            print(
                "FAIL %-8s %s\n     this engine answered %s, the document says %s"
                % (claim, statement, json.dumps(ours, ensure_ascii=False), expected)
            )
            failures += 1
            continue
        reference = run_sqlite(statement)
        if claim == "matches":
            if not same(ours, reference):
                print(
                    "FAIL matches  %s\n     this engine %s, sqlite3 %s"
                    % (statement, json.dumps(ours, ensure_ascii=False), json.dumps(reference, ensure_ascii=False))
                )
                failures += 1
                continue
            print("ok   matches  %s" % statement)
        else:
            if same(reference, wanted):
                print(
                    "FAIL ours     %s\n     the document says it differs, and sqlite3 now agrees"
                    % statement
                )
                failures += 1
                continue
            print("ok   ours     %s (sqlite3: %s)" % (statement, json.dumps(reference, ensure_ascii=False)))

    if failures:
        print("documented compatibility: %d claim(s) contradicted" % failures)
        return 1
    print("documented compatibility: every claim in docs/sqlite.md answers as written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
