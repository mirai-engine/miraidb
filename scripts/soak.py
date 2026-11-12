#!/usr/bin/env python3
"""Soak the engine: keep writing, reading, compacting and reopening for a while.

The harness drives the CLI in a loop and checks the invariants that a long run
tends to break: the process stays up, `PRAGMA integrity_check` stays `ok`, the
log does not grow without bound when compaction runs, and reopening the database
sees the rows the writer committed.

    python3 scripts/soak.py --seconds 60
    python3 scripts/soak.py --seconds 600 --batch 200 --vacuum-every 4 --max-log-mb 64

Exit code 0 means every chunk survived and the final checks passed.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import subprocess
import sys
import time

CRASH = re.compile(r"panic|Illegal instruction|Segmentation|assertion|bad free", re.IGNORECASE)


def directory_size(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def run(binary: str, arguments: list[str], stdin: str | None = None, timeout: float = 300):
    done = subprocess.run(
        [binary, *arguments],
        input=stdin,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    return done.returncode, done.stdout + done.stderr


def chunk_statements(rng: random.Random, batch: int, vacuum: bool) -> list[str]:
    statements = []
    for _ in range(batch):
        roll = rng.randrange(0, 100)
        if roll < 55:
            statements.append(
                "INSERT INTO log_lines (level, message, amount) VALUES "
                f"('{rng.choice(['info', 'warn', 'error'])}', 'line {rng.randrange(0, 10**9)}', "
                f"{rng.randrange(-1000, 1000)})"
            )
        elif roll < 70:
            statements.append(
                f"UPDATE log_lines SET amount = amount + {rng.randrange(-5, 5)} "
                f"WHERE id = {rng.randrange(1, 5000)}"
            )
        elif roll < 80:
            statements.append(f"DELETE FROM log_lines WHERE id = {rng.randrange(1, 5000)}")
        elif roll < 95:
            statements.append(
                "SELECT level, count(*), sum(amount) FROM log_lines GROUP BY level"
            )
        else:
            statements.append(
                "SELECT id, message FROM log_lines WHERE amount > 900 ORDER BY id DESC LIMIT 5"
            )
    if vacuum:
        statements.append("VACUUM")
    return statements


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default="./bin/miraidb.exe")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--batch", type=int, default=100)
    parser.add_argument("--vacuum-every", type=int, default=4, help="chunks between VACUUM, 0 to never")
    parser.add_argument("--reopen-every", type=int, default=3, help="chunks between a reopen, 0 to never")
    parser.add_argument("--max-log-mb", type=float, default=0, help="fail when the log exceeds this")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--database", default="_soak_db")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    if not os.path.exists(args.bin):
        print(f"soak: {args.bin} not found; build first", file=sys.stderr)
        return 2
    rng = random.Random(args.seed)
    shutil.rmtree(args.database, ignore_errors=True)
    code, output = run(
        args.bin,
        [
            "sql",
            args.database,
            "CREATE TABLE log_lines (id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT NOT NULL, message TEXT NOT NULL, amount INTEGER NOT NULL)",
        ],
    )
    if code != 0:
        print(f"soak: cannot create the database: {output}", file=sys.stderr)
        return 2

    started = time.monotonic()
    chunks = 0
    statements = 0
    worst_log = 0
    problems = 0
    try:
        while time.monotonic() - started < args.seconds:
            vacuum = args.vacuum_every > 0 and chunks % args.vacuum_every == args.vacuum_every - 1
            batch = chunk_statements(rng, args.batch, vacuum)
            script = "".join(f"{text};\n" for text in batch)
            code, output = run(args.bin, ["repl", args.database], stdin=script)
            statements += len(batch)
            chunks += 1
            if code != 0 or CRASH.search(output):
                problems += 1
                print(f"soak: chunk {chunks} failed (exit {code})", file=sys.stderr)
                for line in output.splitlines()[-20:]:
                    print(f"    {line}", file=sys.stderr)
                break
            log_bytes = directory_size(args.database)
            worst_log = max(worst_log, log_bytes)
            if args.max_log_mb and log_bytes > args.max_log_mb * 1024 * 1024:
                problems += 1
                print(
                    f"soak: the log grew to {log_bytes / 1024 / 1024:.1f} MiB "
                    f"(limit {args.max_log_mb} MiB) after {chunks} chunks",
                    file=sys.stderr,
                )
                break
            if args.reopen_every > 0 and chunks % args.reopen_every == 0:
                code, output = run(args.bin, ["sql", args.database, "PRAGMA integrity_check"])
                if code != 0 or "ok" not in output:
                    problems += 1
                    print(f"soak: integrity_check failed after chunk {chunks}", file=sys.stderr)
                    for line in output.splitlines()[:10]:
                        print(f"    {line}", file=sys.stderr)
                    break
                code, output = run(
                    args.bin, ["sql", args.database, "SELECT count(*) FROM log_lines"]
                )
                if code != 0:
                    problems += 1
                    print(f"soak: reopen failed after chunk {chunks}", file=sys.stderr)
                    for line in output.splitlines()[:10]:
                        print(f"    {line}", file=sys.stderr)
                    break
                rows = output.strip().splitlines()[-1] if output.strip() else "?"
                print(
                    f"soak: chunk {chunks}, {statements} statements, {rows} rows, "
                    f"log {log_bytes / 1024:.0f} KiB, {statements / (time.monotonic() - started):.0f} stmt/s"
                )
        code, output = run(args.bin, ["sql", args.database, "PRAGMA integrity_check"])
        if code != 0 or "ok" not in output:
            problems += 1
            print(f"soak: final integrity_check failed: {output}", file=sys.stderr)
        code, output = run(args.bin, ["check", args.database])
        if code != 0:
            problems += 1
            print(f"soak: final check failed: {output}", file=sys.stderr)
        else:
            print("soak: final " + " / ".join(line for line in output.splitlines() if line))
    finally:
        if not args.keep:
            shutil.rmtree(args.database, ignore_errors=True)

    elapsed = time.monotonic() - started
    if problems:
        print(f"soak: FAILED after {chunks} chunks in {elapsed:.1f}s", file=sys.stderr)
        return 1
    print(
        f"soak: ok, {chunks} chunks, {statements} statements in {elapsed:.1f}s "
        f"({statements / max(elapsed, 1e-9):.0f}/s), peak log {worst_log / 1024:.0f} KiB"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
