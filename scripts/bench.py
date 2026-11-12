#!/usr/bin/env python3
"""Measure the engine and compare it with the recorded baseline.

Three numbers decide whether a change is a regression, and only one of them is a
wall clock:

* bytes of log per committed row, and the size of a compacted database — machine
  independent, so they are gated tightly (10%);
* the insert rate and the cost of a read transaction — wall clock, so they are
  gated with a catastrophe guard (3x) and reported in full. The 10% rule for these
  two is checked by hand on a quiet machine with --record, because a shared CI
  machine cannot promise it.

    python scripts/bench.py            # measure, print, compare, do not write
    python scripts/bench.py --check    # same, but exit 1 on a regression
    python scripts/bench.py --record   # rewrite benchmarks/baseline.json
    python scripts/bench.py --quick    # smaller workload, for CI

The baseline records the machine it was taken on, so a different number is not
mistaken for a regression.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "benchmarks", "baseline.json")

# A time metric may not be worse than this factor before the gate fails. The
# bytes metrics use BYTES_TOLERANCE.
TIME_CATASTROPHE = 3.0
BYTES_TOLERANCE = 1.10


def run(binary: str, *args: str) -> str:
    done = subprocess.run(
        [binary, *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if done.returncode != 0:
        raise SystemExit(f"{binary} {' '.join(args)} failed:\n{done.stdout}{done.stderr}")
    return done.stdout


def database_bytes(path: str) -> int:
    total = 0
    for base, _, files in os.walk(path):
        for name in files:
            total += os.path.getsize(os.path.join(base, name))
    return total


def measure(binary: str, rows: int, iterations: int) -> dict:
    # The database lives inside the repository so the path the engine receives is
    # relative and means the same to a native binary under WSL and to a POSIX one.
    directory = os.path.join(ROOT, "_bench_tmp")
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "db")
    relative = os.path.relpath(path, ROOT)
    try:
        started = time.time()
        out = run(binary, "bench", relative, str(rows), "--no-sync")
        insert_match = re.search(r"\((\d+)/s\)", out)
        if not insert_match:
            raise SystemExit(f"cannot read the insert rate from: {out}")
        insert_per_s = float(insert_match.group(1))
        insert_seconds = time.time() - started

        out = run(binary, "bench-read", relative, str(rows), str(iterations), "--no-sync")
        read_match = re.search(r"\(([\d.]+) us each", out)
        if not read_match:
            raise SystemExit(f"cannot read the read cost from: {out}")
        read_us = float(read_match.group(1))

        started = time.time()
        run(binary, "compact", relative, "--no-sync")
        compact_seconds = time.time() - started

        size = database_bytes(path)
        return {
            "rows": rows,
            "iterations": iterations,
            "insert_per_s": insert_per_s,
            "insert_seconds": round(insert_seconds, 3),
            "read_us_per_tx": read_us,
            "compact_seconds": round(compact_seconds, 3),
            "database_bytes": size,
            "bytes_per_row": round(size / rows, 3),
        }
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def machine() -> dict:
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
    }


def record(binary: str, rows: int, iterations: int) -> int:
    metrics = measure(binary, rows, iterations)
    payload = {"machine": machine(), "metrics": metrics}
    os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
    with open(BASELINE, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    print(json.dumps(payload, indent=2))
    print(f"baseline written to {os.path.relpath(BASELINE, ROOT)}")
    return 0


def compare(payload: dict, current: dict) -> int:
    baseline = payload["metrics"]
    failures = 0

    def check(name: str, now: float, was: float, lower_is_better: bool, factor: float) -> None:
        """`factor` is how much worse than the baseline is still accepted."""
        nonlocal failures
        if was <= 0:
            print(f"skip {name}: no baseline value")
            return
        ratio = now / was
        bad = ratio > factor if lower_is_better else ratio < 1.0 / factor
        if bad:
            failures += 1
        print(f"{'FAIL' if bad else 'ok  '} {name:<22} {now:>12.3f}  baseline {was:>12.3f}  ratio {ratio:>5.2f}")

    print(f"machine: {payload.get('machine', {}).get('platform', 'unknown')}")
    check("bytes per row", current["bytes_per_row"], baseline["bytes_per_row"], True, BYTES_TOLERANCE)
    check("insert per second", current["insert_per_s"], baseline["insert_per_s"], False, TIME_CATASTROPHE)
    check("read us per tx", current["read_us_per_tx"], baseline["read_us_per_tx"], True, TIME_CATASTROPHE)
    check("compact seconds", current["compact_seconds"], baseline["compact_seconds"], True, TIME_CATASTROPHE)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=os.path.join(ROOT, "bin", "miraidb.exe"))
    parser.add_argument("--rows", type=int, default=20000)
    parser.add_argument("--iterations", type=int, default=2000)
    parser.add_argument("--quick", action="store_true", help="smaller workload for CI")
    parser.add_argument("--record", action="store_true", help="write the baseline")
    parser.add_argument("--check", action="store_true", help="fail on a regression")
    args = parser.parse_args()

    binary = args.bin if os.path.isabs(args.bin) else os.path.join(ROOT, args.bin)
    if not os.path.exists(binary):
        print(f"bench: no binary at {binary}; run scripts/build.py first", file=sys.stderr)
        return 2
    rows, iterations = args.rows, args.iterations
    if args.quick:
        rows, iterations = min(rows, 5000), min(iterations, 500)

    if args.record:
        return record(binary, rows, iterations)

    current = measure(binary, rows, iterations)
    print(json.dumps(current, indent=2))
    if not os.path.exists(BASELINE):
        print(f"bench: no baseline at {os.path.relpath(BASELINE, ROOT)}; run --record")
        return 1
    with open(BASELINE, encoding="utf-8") as handle:
        payload = json.load(handle)
    failures = compare(payload, current)
    if not args.check:
        print("bench: report only (pass --check to gate)")
        return 0
    if failures:
        print(f"bench: {failures} regression(s)")
        return 1
    print("bench: no regression")
    return 0


if __name__ == "__main__":
    sys.exit(main())
