#!/usr/bin/env python3
"""Read a table far larger than the page pool and watch the memory it costs.

The claim the page store makes is that a scan is bounded by the buffer pool, not
by the table: a table ten times the pool must not cost ten times the memory. This
gate builds two paged tables, one four times the other, reads each with the same
small pool, and compares the memory the *statement* added over the process after
opening the database (the open already read the log, so that is the baseline).

    python scripts/page_rss.py            # measure and print
    python scripts/page_rss.py --check    # exit 1 when a bound is broken

The engine reports its own peak and current working set (`--memory-report`), so
the numbers do not depend on the host Python finding a process handle.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "_page_rss")
PAGE_SIZE = 4096
POOL_FRAMES = 8
SMALL_ROWS = 15000
BIG_ROWS = 60000
# How much a statement may add over the post-open process, and how much more the
# four-times-larger table may add than the small one.
GROWTH_CAP = 8 * 1024 * 1024
GROWTH_SLACK = 4 * 1024 * 1024
# The file has to be far larger than the pool for the reading to mean anything.
FILE_FLOOR = 10 * POOL_FRAMES * PAGE_SIZE


def run(binary: str, *args: str) -> str:
    import subprocess

    done = subprocess.run([binary, *args], cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"{binary} {' '.join(args)} failed:\n{done.stdout}{done.stderr}")
    return done.stdout


def measure(binary: str, rows: int) -> dict:
    relative = os.path.relpath(os.path.join(WORK, str(rows), "db"), ROOT)
    directory = os.path.join(WORK, str(rows))
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(directory, exist_ok=True)
    options = ["--paged", f"--page-frames={POOL_FRAMES}"]
    run(binary, "create", relative)
    run(binary, "bench", *options, "--no-sync", relative, str(rows))
    out = run(binary, "sql", *options, "--memory-report", relative, "SELECT count(*), sum(v) FROM bench")

    result = re.search(r"^(\d+)\s+(\d+)\s*$", out, re.M)
    growth = re.search(r"query-growth-bytes: (\d+)", out)
    peak = re.search(r"peak-rss-bytes: (\d+)", out)
    if not result or not growth or not peak:
        raise SystemExit(f"cannot read the report from:\n{out}")
    file_bytes = os.path.getsize(os.path.join(directory, "db", "tables", "bench"))
    return {
        "rows": rows,
        "count": int(result.group(1)),
        "sum": int(result.group(2)),
        "growth": int(growth.group(1)),
        "peak": int(peak.group(1)),
        "file_bytes": file_bytes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=os.path.join(ROOT, "bin", "miraidb.exe"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not os.path.exists(args.bin):
        raise SystemExit(f"missing {args.bin}; run scripts/build.py first")

    pool_bytes = POOL_FRAMES * PAGE_SIZE
    try:
        small = measure(args.bin, SMALL_ROWS)
        big = measure(args.bin, BIG_ROWS)
    finally:
        shutil.rmtree(WORK, ignore_errors=True)

    for label, metric in (("small", small), ("big", big)):
        print(
            f"{label}: rows={metric['rows']} file={metric['file_bytes'] // 1024} KiB "
            f"({metric['file_bytes'] // pool_bytes}x pool) "
            f"growth={metric['growth'] // 1024} KiB peak={metric['peak'] // 1024} KiB"
        )

    failures: list[str] = []
    for label, metric in (("small", small), ("big", big)):
        if metric["count"] != metric["rows"]:
            failures.append(f"{label}: count is {metric['count']}, expected {metric['rows']}")
        if metric["sum"] != metric["rows"]:
            failures.append(f"{label}: sum is {metric['sum']}, expected {metric['rows']}")
        if metric["growth"] > GROWTH_CAP:
            failures.append(
                f"{label}: the statement added {metric['growth'] // 1024} KiB over the open, "
                f"over the {GROWTH_CAP // 1024} KiB cap"
            )
    if big["file_bytes"] < FILE_FLOOR:
        failures.append(f"big: the file is smaller than ten times the pool ({FILE_FLOOR} bytes)")
    if big["growth"] > small["growth"] + GROWTH_SLACK:
        failures.append(
            f"big: four times the rows added {big['growth'] // 1024} KiB against "
            f"{small['growth'] // 1024} KiB for the small table"
        )

    if failures:
        for failure in failures:
            print(f"page_rss: {failure}", file=sys.stderr)
        return 1
    if args.check:
        print("page_rss: the pool bounds the read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
