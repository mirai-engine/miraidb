#!/usr/bin/env python3
"""What keeping a .sqlite mirror current costs.

A database opened from a .sqlite file patches the pages a commit touched instead
of re-encoding the whole file. This script measures that: it builds a table with
`--rows` rows in a real SQLite file, opens it through the CLI, commits one row,
and reads the mirror counters the engine reports in `PRAGMA stats`.

    python scripts/mirror_cost.py                 # measure and print
    python scripts/mirror_cost.py --check         # fail when a commit is not a patch

The check is the point: a one-row commit must write a handful of pages, not the
file. It is the twentieth-first CI gate.
"""

import argparse
import os
import re
import shutil
import sqlite3
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "_mirror_cost")
DB = os.path.join(WORK, "mirror.db")


def build(rows: int, text: int) -> None:
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    raw = sqlite3.connect(DB)
    raw.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)")
    # A wide `name` is how a small file still needs a three-level b-tree: a few
    # rows per leaf, so the parent of a leaf is an interior page rather than the
    # root, which is the case the patcher has to get right.
    filler = "'row' || i || ' ' || substr(hex(zeroblob(?)), 1, ?)" if text else "'row' || i"
    statement = (
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) "
        f"INSERT INTO items (id, name, score) SELECT i, {filler}, i % 10 FROM n"
    )
    raw.execute(statement, (rows, text // 2, text) if text else (rows,))
    raw.commit()
    raw.close()


def run_statement(binary: str, sql: str) -> str:
    # The binary may be a Windows one: a path relative to the repository works
    # for both, which is how the other scripts solve the same problem.
    relative = os.path.relpath(DB, ROOT)
    proc = subprocess.run(
        [binary, "sql", "--mirror-report", relative, sql], cwd=ROOT, capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise SystemExit(f"mirror_cost: {sql} failed: {proc.stderr.strip()}")
    return proc.stdout + proc.stderr


def mirror_counters(output: str) -> tuple[int, int]:
    pages = re.search(r"^mirror-pages: (\d+)$", output, re.MULTILINE)
    rewrites = re.search(r"^mirror-rewrites: (\d+)$", output, re.MULTILINE)
    return (int(pages.group(1)) if pages else -1, int(rewrites.group(1)) if rewrites else -1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=os.path.join(ROOT, "bin", "miraidb.exe"))
    parser.add_argument("--rows", type=int, default=10000)
    parser.add_argument(
        "--text",
        type=int,
        default=0,
        help="bytes of filler in each name, so a small table still needs a three-level b-tree",
    )
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    binary = options.bin
    if not os.path.exists(binary) and os.path.exists(os.path.join(ROOT, "bin", "miraidb")):
        binary = os.path.join(ROOT, "bin", "miraidb")

    build(options.rows, options.text)
    file_bytes = os.path.getsize(DB)
    # One row of each kind, then the counters. Every statement is its own
    # process, so the map is rebuilt each time; the bytes are what a commit
    # writes either way.
    pages = 0
    rewrites = 0
    late = options.rows * 10 + 1
    for sql in (
        f"INSERT INTO items (id, name, score) VALUES ({late}, 'late', 3)",
        f"UPDATE items SET name = 'renamed' WHERE id = {late}",
        "DELETE FROM items WHERE id = 5",
    ):
        statement_pages, statement_rewrites = mirror_counters(run_statement(binary, sql))
        pages += max(statement_pages, 0)
        rewrites += max(statement_rewrites, 0)
    page_size = 4096
    written = pages * page_size
    print(f"mirror_cost: rows={options.rows} text={options.text} file={file_bytes // 1024} KiB "
          f"pages={pages} written={written // 1024} KiB rewrites={rewrites}")

    raw = sqlite3.connect(DB)
    integrity = raw.execute("PRAGMA integrity_check").fetchone()[0]
    count = raw.execute("SELECT count(*) FROM items").fetchone()[0]
    renamed = raw.execute("SELECT name FROM items WHERE id = ?", (late,)).fetchone()
    deleted = raw.execute("SELECT count(*) FROM items WHERE id = 5").fetchone()[0]
    raw.close()
    shutil.rmtree(WORK, ignore_errors=True)
    if integrity != "ok":
        print(f"mirror_cost: SQLite says the file is broken: {integrity}", file=sys.stderr)
        return 1
    if count != options.rows or not renamed or renamed[0] != "renamed" or deleted != 0:
        print(f"mirror_cost: SQLite reads the wrong rows ({count}, {renamed}, {deleted})", file=sys.stderr)
        return 1
    if not options.check:
        return 0
    # Four commits (three patches plus the counters read) at four pages each is
    # the bound: a commit must not rewrite the table.
    if pages <= 0:
        print("mirror_cost: no pages were written, so nothing was patched", file=sys.stderr)
        return 1
    if written >= file_bytes:
        print(
            f"mirror_cost: three commits wrote {written} bytes for a {file_bytes}-byte file",
            file=sys.stderr,
        )
        return 1
    print("mirror_cost: a commit patches pages instead of rewriting the file")
    return 0


if __name__ == "__main__":
    sys.exit(main())
