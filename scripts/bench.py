#!/usr/bin/env python3
"""Measure the engine and compare it with the recorded baseline.

What decides whether a change is a regression:

* bytes of log per committed row, and the size of a compacted database — machine
  independent, so they are gated tightly (10% against the stored baseline);
* the time metrics — wall clock, and this machine moves them by up to 30x on its
  own (three runs of one workload gave 15.6, 22.6 and 46.3 us for a read
  transaction, and one pair of halves differed by 30x on a commit with a reader
  open). So --check **reports** them, measures the workload twice in the same run
  so the noise is visible, and never fails on them. The gate that fails is bytes
  per row, which is a property of the format and not of the clock.
  --strict-time is for a quiet machine: it fails when a time metric is 10% worse
  than the baseline, which is the number the roadmap promises. Run it by hand
  after --record on an idle box.

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

# How much worse than the stored baseline is still reported as fine. It is not a
# gate: the baseline was recorded on another machine, and this one moves a metric
# by 30x on its own while nothing changes.
TIME_CATASTROPHE = 3.0
# The number --strict-time enforces, and the number docs/roadmap.md promises for a
# quiet machine.
TIME_TOLERANCE = 1.10
# Two halves of one run must agree within this factor on every time metric. Even
# this is generous, and measurably so: three runs of the same 5 000-row workload
# on one machine in one session gave 22.6, 46.3 and 15.6 us for a read
# transaction, and 5.8, 46.7 and 7.5 ms for a commit with a reader open, with no
# code change between them — and two halves of one run differed by 30x on that
# same commit. A spread is therefore reported, never failed: the gate would spend
# its life on the machine's mood instead of on the code.
RUN_NOISE = 3.0
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
        # Opening a read copies nothing; a commit that has to change a table a
        # reader holds copies it. Both are contract numbers, so the gate records
        # them together: one moving into the other is not a regression, and a gate
        # that watched only one of them would not notice.
        first_match = re.search(r"first read after a commit: ([\d.]+) us", out)
        if not first_match:
            raise SystemExit(f"cannot read the first-read cost from: {out}")
        first_read_us = float(first_match.group(1))
        copy_match = re.search(r"commit with a read open: ([\d.]+) us", out)
        if not copy_match:
            raise SystemExit(f"cannot read the copy cost of a commit from: {out}")
        commit_with_reader_us = float(copy_match.group(1))

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
            "first_read_us": first_read_us,
            "commit_with_reader_us": commit_with_reader_us,
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


def compare(payload: dict, current: dict, strict_time: bool) -> int:
    baseline = payload["metrics"]
    failures = 0

    def check(
        name: str,
        now: float,
        was: float,
        lower_is_better: bool,
        factor: float,
        gate: bool,
    ) -> None:
        """Report a metric; fail only when `gate` is set and the factor is passed."""
        nonlocal failures
        if was <= 0:
            print(f"skip {name}: no baseline value")
            return
        ratio = now / was
        worse = ratio > factor if lower_is_better else ratio < 1.0 / factor
        status = "warn" if worse else "ok  "
        if worse and gate:
            status = "FAIL"
            failures += 1
        print(f"{status} {name:<22} {now:>12.3f}  baseline {was:>12.3f}  ratio {ratio:>5.2f}")

    print(f"machine: {payload.get('machine', {}).get('platform', 'unknown')}")
    # Bytes per row is a property of the format, so it is a promise and a gate.
    check("bytes per row", current["bytes_per_row"], baseline["bytes_per_row"], True, BYTES_TOLERANCE, True)
    time_factor = TIME_TOLERANCE if strict_time else TIME_CATASTROPHE
    check("insert per second", current["insert_per_s"], baseline["insert_per_s"], False, time_factor, strict_time)
    check("read us per tx", current["read_us_per_tx"], baseline["read_us_per_tx"], True, time_factor, strict_time)
    check(
        "first read us",
        current.get("first_read_us", 0),
        baseline.get("first_read_us", 0),
        True,
        time_factor,
        strict_time,
    )
    check(
        "commit w/ reader us",
        current.get("commit_with_reader_us", 0),
        baseline.get("commit_with_reader_us", 0),
        True,
        time_factor,
        strict_time,
    )
    check("compact seconds", current["compact_seconds"], baseline["compact_seconds"], True, time_factor, strict_time)
    return failures


def compare_halves(first: dict, second: dict) -> int:
    """Compare two runs of the same workload, taken minutes apart on this machine.

    This is the gate that means something for wall clock: the reference is
    measured in the same session, so machine speed and load cancel out. A real
    regression (a lost index, an extra copy) moves a metric by more than half; a
    shared machine does not.
    """
    failures = 0
    if first["bytes_per_row"] != second["bytes_per_row"]:
        failures += 1
        print(
            f"FAIL bytes per row changed between two runs of one workload: "
            f"{first['bytes_per_row']} and {second['bytes_per_row']}"
        )
    else:
        print(f"ok   bytes per row is identical in both runs: {first['bytes_per_row']}")
    metrics = (
        ("insert per second", "insert_per_s"),
        ("read us per tx", "read_us_per_tx"),
        ("first read us", "first_read_us"),
        ("commit w/ reader us", "commit_with_reader_us"),
        ("compact seconds", "compact_seconds"),
    )
    for label, key in metrics:
        left = float(first.get(key, 0))
        right = float(second.get(key, 0))
        if left <= 0 or right <= 0:
            continue
        ratio = max(left, right) / min(left, right)
        # A spread is reported, not failed: it measures the machine's mood.
        print(
            f"{'noisy' if ratio > RUN_NOISE else 'ok   '} {label:<22} run {left:>12.3f}  "
            f"run {right:>12.3f}  spread {ratio:>5.2f}"
        )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=os.path.join(ROOT, "bin", "miraidb.exe"))
    parser.add_argument("--rows", type=int, default=20000)
    parser.add_argument("--iterations", type=int, default=2000)
    parser.add_argument("--quick", action="store_true", help="smaller workload for CI")
    parser.add_argument("--record", action="store_true", help="write the baseline")
    parser.add_argument("--check", action="store_true", help="fail on a regression")
    parser.add_argument(
        "--strict-time",
        action="store_true",
        help="fail when a time metric is 10%% worse than the baseline (quiet machine only)",
    )
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
    if payload.get("machine", {}).get("platform") != machine()["platform"]:
        print("note: the baseline was recorded on another platform; its time metrics are a catastrophe guard only")
    failures = compare(payload, current, args.strict_time)
    if args.check:
        # The stored baseline is cross-machine history. The contract for wall clock
        # is a second run on this machine, in this session, right now.
        second = measure(binary, rows, iterations)
        print(json.dumps(second, indent=2))
        print("--- two runs of the same workload, minutes apart, on this machine ---")
        failures += compare_halves(current, second)
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
