#!/usr/bin/env python3
"""Recomputes the weighted roadmap totals in docs/pending.md.

The table is the source of truth for progress, so it must never drift: a row
counts fully when its state starts with `done`, and by the number it leads with
otherwise (`2.5: ...` counts 2.5 points). Run this after editing a row.

    python3 scripts/roadmap.py          # rewrite docs/pending.md
    python3 scripts/roadmap.py --check  # fail when it is stale
"""

from __future__ import annotations

import re
import sys

PATH = "docs/pending.md"
PHASE_RE = re.compile(r"^## (P\d) — (.+?) \((\d+)\) — ([\d.]+)\s*$")
ROW_RE = re.compile(r"^\| (\d+) \|")
DONE_RE = re.compile(r"^done\b")
POINTS_RE = re.compile(r"^([\d.]+)")


def parse(text: str):
    phases: list[dict] = []
    for line in text.split("\n"):
        header = PHASE_RE.match(line)
        if header:
            phases.append({"name": header.group(1), "title": header.group(2),
                           "weight": float(header.group(3)), "rows": []})
            continue
        if not phases:
            continue
        row = ROW_RE.match(line)
        if not row:
            continue
        parts = [part.strip() for part in line.strip("|").split("|")]
        if len(parts) != 4:
            raise SystemExit(f"row {row.group(1)} has {len(parts)} cells, not 4: {line[:90]}")
        weight = float(parts[2])
        state = parts[3]
        if DONE_RE.match(state.lower()):
            earned, status = weight, "done"
        else:
            points = POINTS_RE.match(state)
            if not points:
                earned, status = 0.0, "todo"
            else:
                earned, status = float(points.group(1)), "partial"
        phases[-1]["rows"].append({"number": int(row.group(1)), "weight": weight,
                                   "earned": earned, "status": status})
    return phases


def main() -> int:
    check = "--check" in sys.argv
    text = open(PATH, encoding="utf-8").read()
    phases = parse(text)
    total_weight = sum(phase["weight"] for phase in phases)
    total_earned = sum(row["earned"] for phase in phases for row in phase["rows"])
    problems: list[str] = []
    lines = text.split("\n")
    for phase in phases:
        weight = sum(row["weight"] for row in phase["rows"])
        if abs(weight - phase["weight"]) > 1e-9:
            problems.append(f"{phase['name']} rows add up to {weight:g}, header says {phase['weight']:g}")
        earned = sum(row["earned"] for row in phase["rows"])
        phase["earned"] = earned
        pattern = re.compile(rf"^## {phase['name']} — {re.escape(phase['title'])} \({phase['weight']:g}\) — [\d.]+\s*$")
        for index, line in enumerate(lines):
            if pattern.match(line):
                lines[index] = f"## {phase['name']} — {phase['title']} ({phase['weight']:g}) — {earned:g}"
                break
    # Replace the totals table body.
    start = next(i for i, line in enumerate(lines) if line.startswith("| Phase | Weight | Earned |"))
    end = start + 2
    while end < len(lines) and lines[end].startswith("|"):
        end += 1
    table = ["| Phase | Weight | Earned |", "|---|---|---|"]
    for phase in phases:
        table.append(f"| {phase['name']} {phase['title']} | {phase['weight']:g} | {phase['earned']:g} |")
    table.append(f"| **Total** | **{total_weight:g}** | **{total_earned:g}** |")
    lines[start:end] = table
    percent = round(total_earned / total_weight * 100) if total_weight else 0
    for index, line in enumerate(lines):
        if line.startswith("**Current state:"):
            lines[index] = f"**Current state: {total_earned:g} / {total_weight:g} = {percent}%.**"
            break
    updated = "\n".join(lines)
    if check:
        if updated != text or problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            print("docs/pending.md is stale; run python3 scripts/roadmap.py", file=sys.stderr)
            return 1
        print(f"roadmap consistent: {total_earned:g}/{total_weight:g}")
        return 0
    for problem in problems:
        print(f"warning: {problem}", file=sys.stderr)
    if updated != text:
        open(PATH, "w", encoding="utf-8", newline="").write(updated)
    for phase in phases:
        print(f"{phase['name']}: {phase['earned']:g}/{phase['weight']:g}")
    print(f"total: {total_earned:g}/{total_weight:g} = {percent}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
