#!/usr/bin/env python3
"""Fuzz the `.sqlite` mirror: random DDL and DML, the file checked after each chunk.

The same seeded stream of statements runs on two files: one through the facade
(CPython's sqlite3 module loading `sqlite3_miraidb` as its SQLite, as
scripts/python_sqlite3.py stages it) and one through SQLite itself. The stream
creates tables of every shape the mirror writes (rowid, INTEGER PRIMARY KEY,
WITHOUT ROWID), indexes (unique, partial, over expressions, DESC, NOCASE),
alters and drops them, and writes rows small and large (overflow chains, page
splits), inside and outside explicit transactions. A statement must succeed on
both sides or fail on both. After each chunk:

  * SQLite's own `PRAGMA integrity_check` on the facade's file answers `ok`;
  * every table holds the same rows on both files, and both catalogs name the
    same objects.

    python scripts/mirror_fuzz.py [--seed N] [--seeds N] [--statements N] [--chunk N] [facade]

Exit code 0 means every chunk held. A failure prints the seed and the statement
number, which replays it.
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import sqlite3
import sys
import tempfile
from contextlib import closing

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from python_sqlite3 import stage  # noqa: E402
from sqlite_processes import Side, facade_libversion  # noqa: E402


class Model:
    """What the stream has created, so most statements name what exists."""

    def __init__(self, rng: random.Random):
        self.rng = rng
        self.tables: dict[str, list[str]] = {}
        self.indexes: dict[str, str] = {}
        self.serial = 0
        self.in_tx = False

    def name(self, prefix: str) -> str:
        self.serial += 1
        return f"{prefix}{self.serial}"

    def value(self) -> str:
        r = self.rng.random()
        if r < 0.10:
            return "NULL"
        if r < 0.45:
            return str(self.rng.randint(-5, 40))
        if r < 0.60:
            return repr(round(self.rng.uniform(-100, 100), 3))
        if r < 0.85:
            word = "".join(self.rng.choice("abcXYZ") for _ in range(self.rng.randint(0, 6)))
            return f"'{word}'"
        if r < 0.95:
            # Large enough to spill into overflow pages, or to split a leaf.
            return f"'{self.rng.choice('pq') * self.rng.choice([700, 1500, 3000, 6000])}'"
        return f"zeroblob({self.rng.choice([0, 10, 2000, 9000])})"

    def table(self) -> str | None:
        return self.rng.choice(sorted(self.tables)) if self.tables else None

    def column(self, table: str) -> str:
        return self.rng.choice(self.tables[table])

    def create_table(self) -> str:
        name = self.name("t")
        shape = self.rng.choice(["rowid", "alias", "without", "textkey"])
        if shape == "rowid":
            self.tables[name] = ["a", "b", "c"]
            return f"CREATE TABLE {name} (a INTEGER, b TEXT, c)"
        if shape == "alias":
            self.tables[name] = ["k", "a", "b"]
            return f"CREATE TABLE {name} (k INTEGER PRIMARY KEY, a INTEGER, b TEXT)"
        if shape == "without":
            self.tables[name] = ["a", "b", "c"]
            return f"CREATE TABLE {name} (a INTEGER NOT NULL, b TEXT NOT NULL, c, PRIMARY KEY (a, b)) WITHOUT ROWID"
        self.tables[name] = ["s", "a", "c"]
        return f"CREATE TABLE {name} (s TEXT PRIMARY KEY, a INTEGER, c)"

    def create_index(self, table: str) -> str:
        name = self.name("i")
        self.indexes[name] = table
        column = self.column(table)
        other = self.column(table)
        unique = "UNIQUE " if self.rng.random() < 0.3 else ""
        part = self.rng.choice([
            column,
            f"{column} DESC",
            f"{column} COLLATE NOCASE",
            f"{column}, {other}" if other != column else column,
            f"({column} + 1)",
            f"lower({column})",
        ])
        where = f" WHERE {column} > {self.rng.randint(0, 20)}" if self.rng.random() < 0.25 else ""
        return f"CREATE {unique}INDEX {name} ON {table} ({part}){where}"

    def statement(self) -> str:
        r = self.rng.random()
        table = self.table()
        if table is None or r < 0.05:
            return self.create_table()
        if r < 0.12:
            return self.create_index(table)
        if r < 0.14 and self.indexes:
            index = self.rng.choice(sorted(self.indexes))
            del self.indexes[index]
            return f"DROP INDEX {index}"
        if r < 0.15 and len(self.tables) > 2:
            del self.tables[table]
            for index in [i for i, t in self.indexes.items() if t == table]:
                del self.indexes[index]
            return f"DROP TABLE {table}"
        if r < 0.17:
            column = self.name("x")
            self.tables[table].append(column)
            return f"ALTER TABLE {table} ADD COLUMN {column} INTEGER DEFAULT {self.rng.randint(0, 3)}"
        if r < 0.19 and not self.in_tx:
            self.in_tx = True
            return "BEGIN"
        if r < 0.22 and self.in_tx:
            self.in_tx = False
            return self.rng.choice(["COMMIT", "COMMIT", "ROLLBACK"])
        columns = self.tables[table]
        if r < 0.62:
            verb = self.rng.choice(["INSERT", "INSERT", "INSERT OR REPLACE", "INSERT OR IGNORE"])
            rows = ", ".join(
                "(" + ", ".join(self.value() for _ in columns) + ")"
                for _ in range(self.rng.choice([1, 1, 2, 5]))
            )
            return f"{verb} INTO {table} ({', '.join(columns)}) VALUES {rows}"
        if r < 0.82:
            column = self.column(table)
            target = self.column(table)
            # SQLite's UPDATE OR IGNORE of a rowid to a real drops the row; an
            # INTEGER PRIMARY KEY is updated to integers only.
            value = str(self.rng.randint(-5, 60)) if target == "k" else self.value()
            return f"UPDATE {table} SET {target} = {value} WHERE {column} < {self.rng.randint(-5, 40)}"
        column = self.column(table)
        return f"DELETE FROM {table} WHERE {column} = {self.value()}"



def catalog(path: str) -> list:
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True)) as cx:
        return cx.execute("SELECT type, name, tbl_name FROM sqlite_master ORDER BY name").fetchall()


def contents(path: str, tables: list[str]) -> dict:
    out = {}
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True)) as cx:
        for table in tables:
            count = len(cx.execute(f"PRAGMA table_info({table})").fetchall())
            order = ", ".join(str(i + 1) for i in range(count))
            out[table] = cx.execute(f"SELECT * FROM {table} ORDER BY {order}").fetchall()
    return out


def integrity(path: str) -> list:
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True)) as cx:
        return [row[0] for row in cx.execute("PRAGMA integrity_check").fetchall()]


def run_seed(args: argparse.Namespace, seed: int) -> list[str] | None:
    """Runs one seed's stream; None when a side did not load what it should."""
    staged = tempfile.mkdtemp(prefix="mirror_fuzz_")
    reference_dir = tempfile.mkdtemp(prefix="mirror_fuzz_sqlite_")
    failures: list[str] = []
    try:
        stage(os.path.abspath(args.facade), staged)
        ours = os.path.join(staged, "ours.sqlite")
        # Not in the staged directory: a process started there loads the
        # facade as its SQLite (Windows searches the working directory).
        theirs = os.path.join(reference_dir, "theirs.sqlite")
        facade = Side("facade", ours, staged)
        sqlite = Side("sqlite", theirs, None)
        if facade.version != facade_libversion(args.facade):
            print(f"mirror fuzz: the facade side loaded SQLite {facade.version}, not the facade")
            return None
        if sqlite.run("SELECT sqlite_source_id()") == facade.run("SELECT sqlite_source_id()"):
            print("mirror fuzz: the SQLite side loaded the facade")
            return None
        model = Model(random.Random(seed))
        for number in range(1, args.statements + 1):
            sql = model.statement()
            got = facade.run(sql)
            want = sqlite.run(sql)
            if ("error" in got) != ("error" in want):
                failures.append(f"statement {number}: {sql}\n    facade {got}\n    SQLite {want}")
                break
            if number % args.chunk and number != args.statements:
                continue
            if model.in_tx:
                continue
            problems = integrity(ours)
            if problems != ["ok"]:
                failures.append(f"after statement {number}: integrity_check: {problems[:5]}")
                break
            listed = catalog(theirs)
            if catalog(ours) != listed:
                failures.append(f"after statement {number}: catalogs differ\n    facade {catalog(ours)}\n    SQLite {listed}")
                break
            tables = [name for kind, name, _ in listed if kind == "table" and not name.startswith("sqlite_")]
            mine, reference = contents(ours, tables), contents(theirs, tables)
            for table in tables:
                if mine[table] != reference[table]:
                    pairs = list(zip(mine[table], reference[table]))
                    first = next((p for p in pairs if p[0] != p[1]), None)
                    shown = (tuple(str(v)[:40] for v in first[0]), tuple(str(v)[:40] for v in first[1])) if first else ("", "")
                    failures.append(f"after statement {number}: {table} differs: facade {len(mine[table])} rows, SQLite {len(reference[table])}; first: facade {shown[0]} SQLite {shown[1]}")
            if failures:
                break
        facade.close()
        sqlite.close()
    finally:
        shutil.rmtree(staged, ignore_errors=True)
        shutil.rmtree(reference_dir, ignore_errors=True)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("facade", nargs="?", default=os.path.join("bin", "sqlite3_miraidb.dll" if os.name == "nt" else "sqlite3_miraidb.so"))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--seeds", type=int, default=1, help="run this many seeds from --seed on")
    parser.add_argument("--statements", type=int, default=600)
    parser.add_argument("--chunk", type=int, default=40)
    args = parser.parse_args()
    if not os.path.isfile(args.facade):
        print(f"mirror fuzz: no facade at {args.facade}")
        return 2
    failed = 0
    for seed in range(args.seed, args.seed + args.seeds):
        failures = run_seed(args, seed)
        if failures is None:
            return 2
        for failure in failures:
            print(f"FAIL (seed {seed}) {failure}")
        print(f"mirror fuzz: seed {seed}, {args.statements} statements, {len(failures)} failure(s)", flush=True)
        failed += bool(failures)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
