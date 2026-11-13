#!/usr/bin/env python3
"""Two-process check of the database directory lock.

The engine gives a database directory to one process. This script proves it with
two real processes: the child opens the database and holds it, the parent tries to
open the same directory and must be refused with an error that names the owner,
and once the child is gone the parent opens it normally.

    python scripts/lock_smoke.py

The child is this same file with --hold; it uses the Python binding, so the path
it takes is the one a user takes: library, C ABI, engine.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin", "miraidb.exe")
sys.path.insert(0, os.path.join(ROOT, "sdk", "python"))

import miraidb  # noqa: E402


def hold(path: str) -> int:
    """Child: open the database, announce it, and keep it open until killed."""
    db = miraidb.connect(path)
    db.execute("CREATE TABLE held (id INTEGER PRIMARY KEY)")
    db.execute("INSERT INTO held (id) VALUES (1)")
    print("ready", flush=True)
    time.sleep(60)
    db.close()
    return 0


def main() -> int:
    failures = 0

    def check(name: str, condition: bool, detail: str = "") -> None:
        nonlocal failures
        if condition:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name} {detail}")

    if "--hold" in sys.argv:
        path = sys.argv[sys.argv.index("--hold") + 1]
        return hold(path)

    directory = tempfile.mkdtemp(prefix="miraidb-lock-")
    path = os.path.join(directory, "db")
    child = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--hold", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        banner = child.stdout.readline().strip() if child.stdout else ""
        if banner != "ready":
            error = child.stderr.read() if child.stderr else ""
            print(f"FAIL child did not open the database: {banner} {error}")
            return 1
        check("child holds the database", os.path.exists(os.path.join(path, "lock")))

        refused = False
        message = ""
        try:
            miraidb.connect(path)
        except miraidb.Error as error:
            refused = True
            message = str(error)
        check("second process is refused", refused, message)
        check("refusal names the owner", "pid" in message, message)
        check("refusal names the database", path in message, message)

        # A reader opens beside the writer: the writer byte is exclusive, the
        # reader byte is shared, so the reader joins instead of colliding.
        if not os.path.exists(BIN):
            print(f"FAIL missing {BIN}; run scripts/build.py first")
            return 1

        def cli(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run([BIN, *args], capture_output=True, text=True)

        first = cli("sql", "--read-only", path, "SELECT count(*) FROM held")
        check(
            "a reader opens beside the writer",
            first.returncode == 0 and "1" in first.stdout,
            first.stderr.strip(),
        )
        second = cli("sql", "--read-only", path, "SELECT count(*) FROM held")
        check(
            "two readers coexist",
            second.returncode == 0 and "1" in second.stdout,
            second.stderr.strip(),
        )
        write = cli("sql", "--read-only", path, "INSERT INTO held (id) VALUES (2)")
        check(
            "a reader cannot write",
            write.returncode != 0 and "read" in write.stderr.lower(),
            write.stderr.strip() or write.stdout.strip(),
        )
        # Another process cannot compact a database this one owns; the writer's own
        # refusal while a reader is open is covered by the engine test, because it
        # needs the lock holder in the same process.
        compact = cli("compact", path)
        check(
            "compaction from another process is refused",
            compact.returncode != 0 and "locked" in compact.stderr.lower(),
            compact.stderr.strip() or compact.stdout.strip(),
        )

        # Kill the owner: the operating system drops the lock with the process.
        child.kill()
        child.wait(timeout=10)
        handed_over = False
        detail = ""
        for _ in range(50):
            try:
                db = miraidb.connect(path)
            except miraidb.Error as error:
                detail = str(error)
                time.sleep(0.05)
                continue
            with db:
                rows = list(db.query("SELECT count(*) FROM held"))
                handed_over = rows[0][0] == 1
            break
        check("lock survives a killed owner being reopened", handed_over, detail)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=10)
        shutil.rmtree(directory, ignore_errors=True)

    print("lock smoke: ok" if failures == 0 else f"lock smoke: {failures} failure(s)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
