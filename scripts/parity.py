#!/usr/bin/env python3
"""Hold the engine to its speed: the parity workloads may not get slower.

benchmarks/parity runs the workloads the reference measures with its own suite,
the same shapes and sizes, in memory. This gate builds it with `-o:speed`, runs
it three times, takes each workload's best median (as benchmarks/parity/RESULTS.md
has since round four: medians in memory move by under 10% between runs, the best
of three by less) and compares it with benchmarks/parity/baseline.json:

  * a workload more than 15% slower than its baseline fails the gate, with
    0.2 us of slack for the ones that take well under a microsecond, where the
    timer's step is a tenth of one. The machine has slow stretches that move
    every run of a measurement at once (up to +19% for an unchanged build), so a
    workload over its baseline is measured again and keeps its better number: a
    regression of the code survives that, a slow stretch does not. The
    regressions this gate is for were 24-41%;
  * the reference's and SQLite's numbers, measured on the same machine on
    2026-11-19, are printed beside each one with the ratio; how many workloads
    are still slower than the reference is reported (the target is 1x or
    better), and fails the gate only with --require-target;
  * a workload that reached the reference is held there: baseline.json lists
    them under "reached", and one more than 10% slower than the reference fails
    the gate (with the same 0.2 us of slack), even while its own baseline would
    still allow it. The baseline's 15% follows this machine's numbers; this rule
    keeps a gain over the reference from being given back a step at a time.
    `--record` adds a workload to the list once its recorded number is at or
    under the reference, and never takes one off: that is a decision for a
    person, made by editing the file. `--self-test` checks these rules on
    made-up numbers, without building anything.

The baseline holds this machine's numbers. When a change makes the engine
faster, `--record` writes the new numbers (the median of five rounds of
best-of-three, a typical good run rather than the luckiest), so the gain cannot
be lost again without the gate saying so; a slower machine records its own once.

    python3 scripts/parity.py
    python3 scripts/parity.py --record
    python3 scripts/parity.py --self-test
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
# How far a workload that reached the reference may fall back behind it.
REACHED_TOLERANCE = 0.10


def build(odin: str, out: str) -> None:
    done = subprocess.run([odin, "build", "benchmarks/parity", "-o:speed", f"-out:{out}"],
                          cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"parity: build failed\n{done.stdout}{done.stderr}")


def over(value: float, base: float | None) -> bool:
    """Whether `value` is slower than the baseline allows."""
    return bool(base) and value > max(base * (1 + TOLERANCE), base + SLACK_NS)


def slipped(value: float, ref: float | None) -> bool:
    """Whether a workload that reached the reference `ref` has fallen back behind it."""
    return bool(ref) and value > max(ref * (1 + REACHED_TOLERANCE), ref + SLACK_NS)


def judge(now: dict[str, float], baseline: dict) -> tuple[list[str], list[str], list[str]]:
    """The workloads slower than their baseline, the ones that reached the
    reference and fell back behind it, and the ones still slower than it."""
    engine, reference = baseline["engine_ns"], baseline["reference_ns"]
    reached = set(baseline.get("reached", []))
    regressions, fell_back, above_target = [], [], []
    for name in sorted(now):
        value, base, ref = now[name], engine.get(name), reference.get(name)
        short = name.removeprefix("miraidb/mem/")
        if over(value, base):
            regressions.append(f"{short}: {value / 1000:.2f} us against {base / 1000:.2f} us")
        if name in reached and slipped(value, ref):
            fell_back.append(f"{short}: {value / ref:.2f}x the reference ({value / 1000:.2f} us against {ref / 1000:.2f} us)")
        if ref and value > ref:
            above_target.append(short)
    return regressions, fell_back, above_target


def failing(now: dict[str, float], baseline: dict) -> bool:
    """Whether `now` breaks either rule."""
    regressions, fell_back, _ = judge(now, baseline)
    return bool(regressions or fell_back)


def reached_after_record(now: dict[str, float], baseline: dict) -> list[str]:
    """The list --record writes: the workloads listed before, and the ones now
    at or under the reference."""
    reference = baseline["reference_ns"]
    reached = set(baseline.get("reached", []))
    reached |= {name for name, value in now.items() if reference.get(name) and value <= reference[name]}
    return sorted(reached)


def self_test() -> int:
    """The rules on made-up numbers: a workload that reached the reference fails
    past 1.10x of it even inside its own baseline's 15%; one that did not is held
    to its baseline only; a sub-microsecond one has the timer's slack."""
    baseline = {
        "engine_ns": {"a": 1_000_000, "b": 1_500_000, "tiny": 500},
        "reference_ns": {"a": 1_000_000, "b": 1_000_000, "tiny": 530},
        "reached": ["a", "tiny"],
    }
    # label, numbers, (slower than the baseline, fell back behind the reference)
    cases = [
        ("a at the reference", {"a": 1_000_000}, (0, 0)),
        ("a at 1.10x", {"a": 1_100_000}, (0, 0)),
        ("a at 1.12x, inside its baseline's 15%", {"a": 1_120_000}, (0, 1)),
        ("a past both", {"a": 1_200_000}, (1, 1)),
        ("b at 1.6x, never reached", {"b": 1_600_000}, (0, 0)),
        ("b past its baseline", {"b": 1_800_000}, (1, 0)),
        ("tiny within the timer's slack", {"tiny": 700}, (0, 0)),
        ("tiny past the slack", {"tiny": 800}, (1, 1)),
    ]
    bad = 0
    for label, now, want in cases:
        regressions, fell_back, _ = judge(now, baseline)
        got = (len(regressions), len(fell_back))
        if got != want or failing(now, baseline) != any(got):
            print(f"parity self-test: {label}: got {got}, want {want}")
            bad += 1
    # --record lists a workload once it is at or under the reference, and keeps
    # one that fell behind again.
    listed = reached_after_record({"a": 1_050_000, "b": 990_000, "tiny": 500}, baseline)
    if listed != ["a", "b", "tiny"]:
        print(f"parity self-test: --record lists {listed}, want ['a', 'b', 'tiny']")
        bad += 1
    print(f"parity self-test: {len(cases) + 1 - bad} of {len(cases) + 1} cases hold")
    return 1 if bad else 0


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
    parser.add_argument("--self-test", action="store_true", help="check the rules on made-up numbers and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()

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
    if not args.record and failing(now, baseline):
        # The machine has slow stretches (a background load) that move every run
        # of one measurement together: best-of-five did not remove a +14% one.
        # A regression of the code is still there when measured again; a slow
        # stretch is not. Each workload keeps its better measurement.
        print("parity: a workload is over its baseline or behind the reference it reached; measuring again")
        again = measure(binary, args.runs)
        now = {name: min(value, again.get(name, value)) for name, value in now.items()}
    reference = baseline["reference_ns"]
    sqlite = baseline["sqlite_ns"]
    missing = sorted(set(engine) - set(now))
    unknown = sorted(set(now) - set(engine))
    if missing or unknown:
        print(f"parity: the workloads changed (missing {missing}, new {unknown}); record a baseline")
        if not args.record:
            return 1

    reached = set(baseline.get("reached", []))
    # A * marks a workload held at the reference it reached.
    print(f"{'workload':58} {'now us':>9} {'base us':>9} {'change':>7} {'ref us':>8} {'x ref':>7}")
    for name in sorted(now):
        value = now[name]
        base = engine.get(name)
        ref = reference.get(name)
        change = f"{100 * (value - base) / base:+6.1f}%" if base else "    new"
        ratio = f"{value / ref:5.2f}x" if ref else "     -"
        held = "*" if name in reached else " "
        short = name.removeprefix("miraidb/mem/")
        print(f"{short:58} {value / 1000:9.2f} {base / 1000 if base else 0:9.2f} {change:>7} {ref / 1000 if ref else 0:8.2f} {ratio:>6}{held}")
    regressions, fell_back, above_target = judge(now, baseline)

    # The SQL workloads have no reference figure: they are held to the baseline only.
    compared = [name for name in now if reference.get(name)]
    print(f"parity: {len(compared) - len(above_target)} of {len(compared)} workloads at or under the reference "
          f"({len(reached)} held there); {len(regressions)} slower than the baseline, "
          f"{len(fell_back)} fell back behind the reference")
    if args.record:
        baseline["reached"] = reached_after_record(now, baseline)
        baseline["engine_ns"] = {name: round(value) for name, value in sorted(now.items())}
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as out:
            json.dump(baseline, out, indent=2)
            out.write("\n")
        print(f"parity: recorded {len(now)} workloads in {os.path.relpath(BASELINE, ROOT)}")
        return 0
    for line in regressions:
        print("  slower:", line)
    for line in fell_back:
        print("  fell back:", line)
    if regressions or fell_back:
        return 1
    if args.require_target and above_target:
        print("  above the reference:", ", ".join(above_target))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
