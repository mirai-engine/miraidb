#!/usr/bin/env python3
"""Smoke test for the Python binding over the C ABI.

Runs the query path a user would: create, bind, read, update, read again, and a
prepared statement reused with different arguments. It is deliberately small; the
point is that a program written in another language can drive the engine through
the ABI without knowing anything about its internals.
"""

from __future__ import annotations

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sdk", "python"))

import miraidb


def main() -> int:
    directory = tempfile.mkdtemp(prefix="miraidb-sdk-")
    path = os.path.join(directory, "sdk.db")
    failures = 0

    def check(name: str, condition: bool, detail: str = "") -> None:
        nonlocal failures
        if condition:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name} {detail}")

    print(f"miraidb {miraidb.version()}")

    with miraidb.connect(path) as db:
        db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL, score INTEGER NOT NULL)")
        db.execute("INSERT INTO notes (id, body, score) VALUES (?, ?, ?)", 1, "hello", 7)
        db.execute("INSERT INTO notes (id, body, score) VALUES (?, ?, ?)", 2, "world", 9)

        rows = list(db.query("SELECT id, body, score FROM notes ORDER BY id"))
        check("two rows", len(rows) == 2, str(len(rows)))
        check("by name", rows[0]["body"] == "hello", rows[0].get("body"))
        check("by position", rows[1][0] == 2, str(rows[1][0]))
        check("integer type", rows[0]["score"] == 7, repr(rows[0]["score"]))

        db.execute("UPDATE notes SET body = ? WHERE id = ?", "HELLO", 1)
        updated = list(db.query("SELECT body FROM notes WHERE id = 1"))
        check("bound update", updated[0]["body"] == "HELLO", updated[0]["body"])

        # One prepared statement, several executions.
        with db.prepare("SELECT body FROM notes WHERE score > ?") as statement:
            statement.bind(8)
            check("prepared first run", [row["body"] for row in statement] == ["world"])
        with db.prepare("SELECT count(*) FROM notes WHERE score > ?") as statement:
            statement.bind(5)
            check("aggregate", [row[0] for row in statement] == [2])

        try:
            db.execute("SELECT * FROM missing")
        except miraidb.Error as error:
            check("error is raised", "missing" in str(error).lower(), str(error))
        else:
            check("error is raised", False, "no error")

    db = miraidb.connect(path, create=False)
    reopened = list(db.query("SELECT count(*) FROM notes"))
    check("reopen keeps rows", reopened[0][0] == 2, str(reopened[0][0]))
    db.close()

    print(f"sdk smoke: {'ok' if failures == 0 else f'{failures} failure(s)'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
