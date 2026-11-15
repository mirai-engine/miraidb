#!/usr/bin/env python3
"""Settle the leak report: are the tracker's `+++ leak` lines real?

The debug tracker prints a line for every block it still knows when a process
exits, which mixes a statement's leftovers with the process's own setup. This gate
asks the question two ways:

  * `tools/leakcheck` wraps the allocator the engine allocates from in a tracking
    allocator, runs one statement two hundred times and counts what is still live
    after the last result is destroyed. That is exact, and it is where the leaks
    were found: the lexer leaked a quoted token's text, the read set and the plan
    were never freed, and the projection names were cloned without freeing the
    original.
  * the CLI runs one statement N times in one process (`--repeat`) and reports the
    working set before and after, which covers the write path the tracking
    allocator cannot see and the allocations that go around it.

Exit code 0 means every shape is within the budget it declares in
`tools/leakcheck/main.odin`. The working set the CLI reports is printed as well:
it is the number a user feels, and it still grows on the write path (about 0.8 KB
per UPDATE, which is a lead rather than a gate - see docs/status.md), so it is
reported and only enforced with `--cli-budget`.

    python3 scripts/leaks.py
    python3 scripts/leaks.py --repeat 5000 --skip-tool
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

RSS = re.compile(r"rss-(?:before|after-first|after-last)-bytes: (\d+)")


def build(odin: str, out: str) -> None:
    done = subprocess.run([odin, "build", "tools/leakcheck", f"-out:{out}"],
                          text=True, capture_output=True)
    if done.returncode != 0:
        # Odin refuses an output path it does not like (a temp directory outside
        # the repo needs an extension), so a failure here is reported, not raised.
        print(done.stdout + done.stderr, file=sys.stderr)
        raise SystemExit(2)


def run_tool(binary: str, repeat: int) -> int:
    done = subprocess.run([binary, str(repeat)], text=True, capture_output=True)
    for line in done.stdout.splitlines():
        if line.strip():
            print(f"    {line}")
    if done.returncode != 0:
        for line in done.stderr.splitlines()[-6:]:
            print(f"    {line}", file=sys.stderr)
    return done.returncode


def working_set(binary: str, database: str, statement: str, repeat: int) -> tuple[int, int]:
    done = subprocess.run(
        [binary, "sql", database, statement, f"--repeat={repeat}", "--memory-report"],
        text=True, capture_output=True,
    )
    values = {match.group(0).split(":")[0]: int(match.group(1)) for match in RSS.finditer(done.stdout)}
    return values.get("rss-after-first-bytes", 0), values.get("rss-after-last-bytes", 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--bin", default=None, help="the CLI binary; default is per platform")
    parser.add_argument("--repeat", type=int, default=4000)
    parser.add_argument("--cli-budget", type=int, default=0,
                        help="fail when the workingset grows more than this per statement (0: report only)")
    parser.add_argument("--skip-tool", action="store_true")
    parser.add_argument("--skip-cli", action="store_true")
    args = parser.parse_args()

    if not args.skip_tool:
        if True:
            # The tools directory is written inside the repo so the output name keeps
            # an extension Odin accepts on every platform.
            # The extension follows the toolchain, not the shell: this script runs
            # under one platform's Python and may drive another platform's Odin.
            suffix = ".exe" if args.odin.lower().endswith(".exe") else ""
            tool = os.path.join("bin", "leakcheck" + suffix)
            os.makedirs("bin", exist_ok=True)
            build(args.odin, tool)
            print("tracked allocations per statement:")
            if run_tool(tool, 200) != 0:
                print("leaks: a shape left more allocations than its budget", file=sys.stderr)
                return 1

    if not args.skip_cli:
        suffix = ".exe" if args.odin.lower().endswith(".exe") else ""
        binary = args.bin or os.path.join("bin", "miraidb" + suffix)
        if not os.path.exists(binary):
            print(f"leaks: {binary} not found; build first", file=sys.stderr)
            return 2
        database = os.path.join("bin", "_leaks_db")
        import shutil
        shutil.rmtree(database, ignore_errors=True)
        setup = [
            "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)",
            "INSERT INTO t (id, v) VALUES (1, 1)",
        ]
        for statement in setup:
            subprocess.run([binary, "sql", database, statement], check=True,
                           stdout=subprocess.DEVNULL)
        for statement in ("SELECT 1", "SELECT count(*) FROM t",
                          "INSERT OR REPLACE INTO t (id, v) VALUES (1, 2)"):
            first, last = working_set(binary, database, statement, args.repeat)
            per_statement = (last - first) / max(args.repeat - 1, 1)
            print(f"    {statement}: {per_statement:.1f} B/statement over {args.repeat}")
            if args.cli_budget and per_statement > args.cli_budget:
                print(f"leaks: {statement} grew {per_statement:.1f} B per statement "
                      f"(budget {args.cli_budget})", file=sys.stderr)
                return 1
        shutil.rmtree(database, ignore_errors=True)
    print("leaks: every measured shape within budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
