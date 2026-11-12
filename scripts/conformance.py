#!/usr/bin/env python3
"""SQL conformance runner.

Runs a small corpus of statements through the CLI against a throwaway
database and checks the observable output. The corpus is intentionally
readable: every case is one statement with the substrings its output must
contain. It grows with the engine; it is not a substitute for the unit suite.

Usage: python3 scripts/conformance.py [--bin bin/miraidb]
"""

import argparse
import os
import shutil
import subprocess
import sys

CASES = [
    ("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)", ["ok"]),
    ("INSERT INTO t (name) VALUES ('a')", ["affected"]),
    ("INSERT INTO t (name) VALUES ('b')", ["affected"]),
    ("SELECT count(*) AS n FROM t", ["n", "2"]),
    ("SELECT name FROM t ORDER BY name DESC LIMIT 1", ["b"]),
    ("SELECT concat('a', 'b') AS j FROM t LIMIT 1", ["ab"]),
    ("SELECT 1 + 2 AS s", ["3"]),
    ("SELECT substr('hello', 2, 3) AS part", ["ell"]),
    ("SELECT CAST('12' AS INTEGER) AS n", ["12"]),
    ("UPDATE t SET name = 'c' WHERE id = 1", ["affected"]),
    ("SELECT name FROM t WHERE id = 1", ["c"]),
    ("CREATE VIEW v AS SELECT name FROM t", ["ok"]),
    ("SELECT count(*) AS n FROM v", ["2"]),
    ("EXPLAIN SELECT * FROM t WHERE id = 1", ["t"]),
    ("DELETE FROM t WHERE id = 2", ["affected"]),
    ("SELECT count(*) AS n FROM t", ["1"]),
    ("TRUNCATE TABLE t", ["affected"]),
    ("SELECT count(*) AS n FROM t", ["0"]),
    ("CREATE TABLE parent (id INTEGER PRIMARY KEY, label TEXT)", ["ok"]),
    ("CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER, CONSTRAINT child_parent UNIQUE (parent_id))", ["ok"]),
]


def run(binary, database, statement):
    proc = subprocess.run([binary, "sql", database, statement], capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default="bin/miraidb.exe")
    options = parser.parse_args()
    binary = options.bin
    if not os.path.exists(binary) and os.path.exists("bin/miraidb"):
        binary = "bin/miraidb"
    if not os.path.exists(binary):
        print(f"conformance: binary not found: {binary}")
        return 1
    database = "_conformance_db"
    shutil.rmtree(database, ignore_errors=True)
    failures = 0
    for statement, expected in CASES:
        code, output = run(binary, database, statement)
        missing = [item for item in expected if item not in output]
        if code != 0 or missing:
            failures += 1
            print(f"FAIL {statement}")
            print(f"  exit {code} missing {missing}")
            print("  " + output.strip().replace("\n", "\n  ")[:400])
        else:
            print(f"ok   {statement[:72]}")
    shutil.rmtree(database, ignore_errors=True)
    print(f"\n{len(CASES) - failures}/{len(CASES)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
