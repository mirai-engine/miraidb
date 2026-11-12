#!/usr/bin/env python3
"""Smoke test for the REPL shell commands: .read, .mode, .headers, .dump,
.output and .timer. It drives the binary through stdin and checks the output,
so the behaviour is covered without a unit test for the CLI."""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, "bin", "miraidb.exe")


def windows_path(path: str) -> str:
    """The binary is a Windows process: /mnt/c/... is not a path it can open."""
    if path.startswith("/mnt/") and len(path) > 7 and path[6] == "/":
        drive = path[5].upper()
        return f"{drive}:/{path[7:]}"
    return path


def main() -> int:
    if not os.path.exists(BINARY):
        print(f"missing binary: {BINARY}")
        return 1
    work = tempfile.mkdtemp(dir=ROOT)
    try:
        # Python runs under WSL and needs POSIX paths; the binary needs Windows
        # ones. Both name the same files.
        database = os.path.join(work, "shell.db")
        script = os.path.join(work, "script.sql")
        with open(script, "w", encoding="utf-8") as handle:
            handle.write("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, note TEXT);\n")
            handle.write("INSERT INTO t (name, note) VALUES ('a', 'x, y');\n")
            handle.write("INSERT INTO t (name, note) VALUES ('b c', NULL);\n")
        csv_path = os.path.join(work, "rows.csv")
        with open(csv_path, "w", encoding="utf-8") as handle:
            handle.write('"widget, large",3\n')
            handle.write('"say ""hi""",4\n')
        output_path = os.path.join(work, "dump.sql")
        commands = [
            f".read {windows_path(script)}",
            ".mode list",
            "SELECT id, name FROM t;",
            ".mode csv",
            ".headers on",
            "SELECT id, name, note FROM t;",
            ".mode tabs",
            "SELECT id, name FROM t;",
            ".headers off",
            ".mode column",
            "SELECT 1 AS one;",
            "CREATE TABLE imported (name TEXT, qty INTEGER);",
            f".import {windows_path(csv_path)} imported",
            "SELECT count(*) AS rows FROM imported;",
            f".output {windows_path(output_path)}",
            ".dump",
            ".output stdout",
            ".timer on",
            "SELECT count(*) FROM t;",
            ".timer off",
            ".quit",
        ]
        result = subprocess.run(
            [BINARY, "repl", windows_path(database)],
            input="\n".join(commands) + "\n",
            capture_output=True,
            text=True,
            timeout=120,
        )
        out = result.stdout
        with open(output_path, encoding="utf-8") as handle:
            dumped = handle.read()

        # A piped script whose last statement has no trailing newline must still
        # run: losing it silently would be the worst kind of shell bug.
        tail = subprocess.run(
            [BINARY, "repl", windows_path(database)],
            input="SELECT 'tail-without-newline' AS marker;",
            capture_output=True,
            text=True,
            timeout=120,
        )

        checks = {
            "last line without newline": "tail-without-newline" in tail.stdout,
            "list mode": "id = 1\nname = a\n\nid = 2\nname = b c" in out,
            "csv quoting": '1,a,"x, y"' in out and "2,b c,NULL" in out,
            "tab separator": "id\tname\n1\ta\n2\tb c" in out,
            "headers off": "-\n1" not in out and "(1 row)" in out,
            "dump create": "CREATE TABLE t (" in dumped,
            "dump insert": "INSERT INTO t VALUES (2, 'b c', NULL);" in dumped,
            "timer": "Run Time: real" in out,
            "import": "imported 2 rows into imported" in out,
            "import clean": "line " not in out,
            "output redirected": dumped.count("INSERT INTO t") == 2,
        }
        failed = [name for name, ok in checks.items() if not ok]
        for name, ok in checks.items():
            print(f"{'ok  ' if ok else 'FAIL'} {name}")
        if failed:
            print("\n--- shell output ---")
            print(out)
            print("--- dump ---")
            print(dumped)
            return 1
        print("shell smoke: all checks passed")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
