#!/usr/bin/env python3
"""Two processes on one SQLite file: the facade with itself, and with SQLite.

Each side is a child Python process that runs the statements it is sent on
one connection to the same file and answers each with a JSON line. A side
runs on the facade (CPython's _sqlite3 loading sqlite3_miraidb as its SQLite)
or on the SQLite the interpreter ships. The script checks what SQLite's own
file locking promises across processes:

  * a second writer waits for its busy timeout and fails with "database is
    locked" while another process's transaction holds the file;
  * a reader in another process sees a commit as soon as it is made;
  * the same holds between the facade and SQLite itself, in both directions.

Exit code 0 means every check held.

    python scripts/sqlite_processes.py [path/to/sqlite3_miraidb.dll]
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from python_sqlite3 import stage  # noqa: E402

CHILD = r"""
import json, sqlite3, sys
path, timeout = sys.argv[1], float(sys.argv[2])
cx = sqlite3.connect(path, timeout=timeout, isolation_level=None)
print(json.dumps({"ready": sqlite3.sqlite_version}), flush=True)
for line in sys.stdin:
    sql = json.loads(line)
    try:
        rows = cx.execute(sql).fetchall()
        print(json.dumps({"rows": rows}), flush=True)
    except Exception as error:  # the message is what is checked
        print(json.dumps({"error": str(error)}), flush=True)
cx.close()
"""


class Side:
    def __init__(self, name: str, path: str, staged: str | None, timeout: float = 0.0):
        self.name = name
        env = dict(os.environ)
        if staged:
            env["PYTHONPATH"] = staged + os.pathsep + env.get("PYTHONPATH", "")
            if os.name != "nt":
                env["LD_LIBRARY_PATH"] = staged + os.pathsep + env.get("LD_LIBRARY_PATH", "")
        self.process = subprocess.Popen(
            [sys.executable, "-c", CHILD, path, str(timeout)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env,
            cwd=staged or os.path.dirname(path),
        )
        self.version = self.answer()["ready"]

    def answer(self) -> dict:
        line = self.process.stdout.readline()
        if not line:
            raise SystemExit(f"{self.name}: the child process ended")
        return json.loads(line)

    def run(self, sql: str) -> dict:
        self.process.stdin.write(json.dumps(sql) + "\n")
        self.process.stdin.flush()
        return self.answer()

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait(timeout=30)


def expect(failures: list[str], what: str, got: dict, rows=None, error: str | None = None) -> None:
    if error is not None:
        if error not in got.get("error", ""):
            failures.append(f"{what}: want an error with {error!r}, got {got}")
    elif "error" in got or (rows is not None and [list(r) for r in got["rows"]] != rows):
        failures.append(f"{what}: want {rows}, got {got}")


def scenario(failures: list[str], label: str, path: str, first: Side, second: Side) -> None:
    expect(failures, f"{label}: create", first.run("CREATE TABLE IF NOT EXISTS t (x INTEGER)"))
    expect(failures, f"{label}: clear", first.run("DELETE FROM t"))
    expect(failures, f"{label}: second reads the table", second.run("SELECT count(*) FROM t"), [[0]])
    expect(failures, f"{label}: begin", first.run("BEGIN IMMEDIATE"))
    expect(failures, f"{label}: first writes", first.run("INSERT INTO t VALUES (1)"))
    expect(failures, f"{label}: second cannot write", second.run("INSERT INTO t VALUES (2)"), error="database is locked")
    expect(failures, f"{label}: second reads the last commit", second.run("SELECT count(*) FROM t"), [[0]])
    expect(failures, f"{label}: commit", first.run("COMMIT"))
    expect(failures, f"{label}: second sees the commit", second.run("SELECT x FROM t"), [[1]])
    expect(failures, f"{label}: second writes now", second.run("INSERT INTO t VALUES (2)"))
    expect(failures, f"{label}: first sees it", first.run("SELECT x FROM t ORDER BY x"), [[1], [2]])


def main() -> int:
    facade = sys.argv[1] if len(sys.argv) > 1 else os.path.join("bin", "sqlite3_miraidb.dll")
    if not os.path.exists(facade):
        print(f"sqlite processes: no facade at {facade}")
        return 1
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as staged, tempfile.TemporaryDirectory() as work:
        stage(os.path.abspath(facade), staged)
        pairs = [
            ("facade and facade", True, True),
            ("facade writes, SQLite waits", True, False),
            ("SQLite writes, facade waits", False, True),
        ]
        for k, (label, first_facade, second_facade) in enumerate(pairs):
            path = os.path.join(work, f"shared_{k}.db")
            first = Side(f"{label} (first)", path, staged if first_facade else None)
            second = Side(f"{label} (second)", path, staged if second_facade else None)
            try:
                scenario(failures, label, path, first, second)
            finally:
                first.close()
                second.close()
    for line in failures:
        print(line)
    print(f"sqlite processes: {len(pairs)} pairings, {len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
