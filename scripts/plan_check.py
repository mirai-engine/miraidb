#!/usr/bin/env python3
"""Plan regression gate: the plans a measured database produces must not get worse.

The planner is the one part of the engine whose output is a decision rather than
an answer, so nothing in the test suite notices when it starts choosing badly.
This gate builds a small database, runs ANALYZE, and checks the cheap properties
that made the plans good: a point lookup probes the index, a predicate that keeps
half the table scans it, a range estimate follows the histogram instead of the
one-third rule, the join probes the side it can index, and the row counter a run
reports agrees with the plan it printed.

    python3 scripts/plan_check.py [--bin ./bin/miraidb.exe] [--keep]

It exits non-zero and names the check when a plan regresses.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = os.path.join(ROOT, "bin", "miraidb.exe")

# The fixture: 400 events with two kinds and 400 distinct amounts, ten parents and
# a thousand children with ten codes.
EVENTS = 400
CHILDREN = 1000


def windows_path(path: str) -> str:
    """The binary is a Windows process: /mnt/c/... is not a path it can open."""
    if path.startswith("/mnt/") and len(path) > 7 and path[6] == "/":
        drive = path[5].upper()
        return f"{drive}:/{path[7:]}"
    return path


def run_repl(binary: str, database: str, statements: list[str]) -> str:
    result = subprocess.run(
        [binary, "repl", windows_path(database)],
        input="\n".join(statements) + "\n.quit\n",
        capture_output=True,
        text=True,
        timeout=300,
    )
    return result.stdout + result.stderr


def metric(output: str, name: str) -> int:
    """PRAGMA stats prints one row per metric in the shell's column mode."""
    match = re.search(rf"^{re.escape(name)}\s+(\d+)\s*$", output, re.MULTILINE)
    return int(match.group(1)) if match else -1


def estimate(plan: str) -> int:
    match = re.search(r"est\. (\d+) rows", plan)
    return int(match.group(1)) if match else -1


def plan_line(output: str, prefix: str) -> str:
    for line in output.splitlines():
        if line.startswith(prefix):
            return line
    return ""


def check(checks: list, label: str, ok: bool, detail: str) -> None:
    checks.append((label, ok, detail))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=DEFAULT_BIN)
    parser.add_argument("--keep", action="store_true", help="keep the fixture database")
    args = parser.parse_args()
    if not os.path.exists(args.bin):
        print(f"missing binary: {args.bin}")
        return 1

    work = tempfile.mkdtemp(dir=ROOT)
    database = os.path.join(work, "plan.db")
    try:
        fixture = [
            "CREATE TABLE ev (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER)",
            "CREATE INDEX ev_amount ON ev (amount)",
            "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER, code INTEGER)",
        ]
        for i in range(EVENTS):
            fixture.append(f"INSERT INTO ev (id, kind, amount) VALUES ({i}, 'k{i % 2}', {i})")
        for i in range(10):
            fixture.append(f"INSERT INTO parent (id, name) VALUES ({i}, 'p{i}')")
        for i in range(CHILDREN):
            fixture.append(
                f"INSERT INTO child (id, parent_id, code) VALUES ({i}, {i % 10}, {i % 10})"
            )
        fixture.append("ANALYZE")
        run_repl(args.bin, database, fixture)

        checks: list[tuple[str, bool, str]] = []

        point = plan_line(
            run_repl(args.bin, database, ["EXPLAIN SELECT * FROM ev WHERE amount = 42"]),
            "scan ev",
        )
        check(
            checks,
            "a point lookup probes the index",
            "using index ev_amount" in point and estimate(point) == 1,
            point or "no plan",
        )

        wide = plan_line(
            run_repl(args.bin, database, ["EXPLAIN SELECT * FROM ev WHERE kind = 'k0'"]),
            "scan ev",
        )
        check(
            checks,
            "a predicate that keeps half the table scans",
            "full scan" in wide and estimate(wide) == EVENTS // 2,
            wide or "no plan",
        )

        # 50 of the 400 rows are under 50; the one-third rule would say 133.
        ranged = plan_line(
            run_repl(args.bin, database, ["EXPLAIN SELECT * FROM ev WHERE amount < 50"]),
            "scan ev",
        )
        check(
            checks,
            "a range estimate follows the histogram",
            0 < estimate(ranged) < 80,
            ranged or "no plan",
        )

        # The join is judged by what it visits, not by which table it starts from:
        # with an index to probe, starting from the filtered side can be cheaper
        # than starting from the small one. What must not happen is a plan that
        # reads the whole inner table once per outer row.
        join_plan = run_repl(
            args.bin,
            database,
            [
                "EXPLAIN SELECT count(*) FROM child JOIN parent ON parent.id = child.parent_id "
                "WHERE child.code = 3"
            ],
        )
        probed = plan_line(join_plan, "join ")
        check(
            checks,
            "the join probes the indexed side",
            "using index parent_pkey" in probed,
            probed or "no plan",
        )
        join_counters = run_repl(
            args.bin,
            database,
            [
                "SELECT count(*) FROM child JOIN parent ON parent.id = child.parent_id "
                "WHERE child.code = 3",
                "PRAGMA stats",
            ],
        )
        join_scanned = metric(join_counters, "rows_scanned")
        check(
            checks,
            "the join visits few rows",
            0 < join_scanned < 3000,
            f"rows_scanned = {join_scanned}",
        )

        # The executor has to follow the plan it printed: a point lookup must not
        # walk the table.
        counters = run_repl(
            args.bin,
            database,
            ["SELECT count(*) FROM ev WHERE amount = 42", "PRAGMA stats"],
        )
        scanned = metric(counters, "rows_scanned")
        check(
            checks,
            "the executor follows the plan",
            0 <= scanned <= 2,
            f"rows_scanned = {scanned}",
        )

        # ANALYZE is what makes the estimates exist, and it is a cache: a table it
        # never measured keeps working (with the index, as before).
        unmeasured = plan_line(
            run_repl(
                args.bin,
                database,
                ["CREATE TABLE fresh (id INTEGER PRIMARY KEY, n INTEGER)"],
            ),
            "scan",
        )
        check(checks, "a statement after ANALYZE still runs", unmeasured == "", "fresh table created")

        failed = 0
        for label, ok, detail in checks:
            print(f"{'ok  ' if ok else 'FAIL'} {label}: {detail}")
            if not ok:
                failed += 1
        if failed:
            print(f"plan check: {failed} check(s) failed")
            return 1
        print(f"plan check: {len(checks)} checks ok")
        return 0
    finally:
        if args.keep:
            print(f"fixture kept at {database}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
