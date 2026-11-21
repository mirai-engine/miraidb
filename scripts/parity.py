#!/usr/bin/env python3
"""Hold the engine to its speed: the parity workloads may not get slower.

benchmarks/parity runs the workloads the reference measures with its own suite,
the same shapes and sizes, in memory. This gate builds it with `-o:speed`, runs
it three times, takes each workload's best median (as benchmarks/parity/RESULTS.md
has since round four: medians in memory move by under 10% between runs, the best
of three by less) and compares it with benchmarks/parity/baseline.json:

  * a workload more than 15% slower than its baseline fails the gate, with
    0.2 us of slack for the ones that take well under a microsecond, where the
    timer's step is a tenth of one;
  * the reference's and SQLite's numbers, measured on the same machine on
    2026-11-19, are printed beside each one with the ratio; how many workloads
    are still slower than the reference is reported (the target is 1x or
    better), and fails the gate only with --require-target.

The baseline holds this machine's numbers. When a change makes the engine
faster, `--record` writes the new numbers (the median of five rounds of
best-of-three, a typical good run rather than the luckiest), so the gain cannot
be lost again without the gate saying so; a slower machine records its own once.

    python3 scripts/parity.py
    python3 scripts/parity.py --record
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "benchmarks", "parity", "baseline.json")
TOLERANCE = 0.15
SLACK_NS = 200.0


def build(odin: str, out: str) -> None:
    done = subprocess.run([odin, "build", "benchmarks/parity", "-o:speed", f"-out:{out}"],
                          cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"parity: build failed\n{done.stdout}{done.stderr}")


def measure(binary: str, runs: int) -> dict[str, float]:
    best: dict[str, float] = {}
    for _ in range(runs):
        done = subprocess.run([binary, "mem", "--json"], cwd=ROOT, capture_output=True, text=True)
        if done.returncode != 0:
            raise SystemExit(f"parity: the bench failed\n{done.stdout}{done.stderr}")
        for sample in json.loads(done.stdout):
            name = sample["name"]
            best[name] = min(best.get(name, float("inf")), float(sample["median_ns"]))
    return best


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--record", action="store_true", help="write today's numbers as the baseline")
    parser.add_argument("--require-target", action="store_true", help="fail while a workload is slower than the reference")
    args = parser.parse_args()

    # The extension follows the toolchain, and the path is relative to the root:
    # this script may run under WSL's Python and drive Windows' Odin, which cannot
    # write to a /mnt/c path.
    exe = ".exe" if args.odin.lower().endswith(".exe") or os.name == "nt" else ""
    relative = os.path.join("bin", "parity" + exe)
    os.makedirs(os.path.join(ROOT, "bin"), exist_ok=True)
    build(args.odin, relative.replace("\\", "/"))
    binary = os.path.join(ROOT, relative)
    if args.record:
        # A baseline is what the engine does on a typical good run, not on its
        # luckiest one: five rounds of best-of-three, and the median of those.
        # One lucky round as the baseline left a workload 13-15% over it on the
        # next ordinary runs.
        rounds = [measure(binary, args.runs) for _ in range(5)]
        now = {name: sorted(r[name] for r in rounds)[2] for name in rounds[0]}
    else:
        now = measure(binary, args.runs)

    baseline = json.load(open(BASELINE, encoding="utf-8"))
    engine = baseline["engine_ns"]
    reference = baseline["reference_ns"]
    sqlite = baseline["sqlite_ns"]
    missing = sorted(set(engine) - set(now))
    unknown = sorted(set(now) - set(engine))
    if missing or unknown:
        print(f"parity: the workloads changed (missing {missing}, new {unknown}); record a baseline")
        if not args.record:
            return 1

    regressions, above_target = [], []
    print(f"{'workload':58} {'now us':>9} {'base us':>9} {'change':>7} {'ref us':>8} {'x ref':>6}")
    for name in sorted(now):
        value = now[name]
        base = engine.get(name)
        ref = reference.get(name)
        change = f"{100 * (value - base) / base:+6.1f}%" if base else "    new"
        ratio = f"{value / ref:5.1f}x" if ref else "     -"
        short = name.removeprefix("miraidb/mem/")
        print(f"{short:58} {value / 1000:9.2f} {base / 1000 if base else 0:9.2f} {change:>7} {ref / 1000 if ref else 0:8.2f} {ratio:>6}")
        if base and value > max(base * (1 + TOLERANCE), base + SLACK_NS):
            regressions.append(f"{short}: {value / 1000:.2f} us against {base / 1000:.2f} us")
        if ref and value > ref:
            above_target.append(short)

    print(f"parity: {len(now) - len(above_target)} of {len(now)} workloads at or under the reference; "
          f"{len(regressions)} slower than the baseline")
    if args.record:
        baseline["engine_ns"] = {name: round(value) for name, value in sorted(now.items())}
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as out:
            json.dump(baseline, out, indent=2)
            out.write("\n")
        print(f"parity: recorded {len(now)} workloads in {os.path.relpath(BASELINE, ROOT)}")
        return 0
    for line in regressions:
        print("  slower:", line)
    if regressions:
        return 1
    if args.require_target and above_target:
        print("  above the reference:", ", ".join(above_target))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
