#!/usr/bin/env python3
"""Documentation consistency gate.

Documentation drifts: three of the findings in the audit of this tree were
sentences that had stopped being true (a test count, a gate count, a matrix row
that claimed a feature nobody had written). Nothing watched them, so nothing
failed when the engine moved on.

This gate checks the claims that can be checked mechanically:

- the version the library reports matches the top section of CHANGELOG.md;
- the number of tests in the suite matches the number docs/status.md states;
- the number of CI gates matches every document that states it;
- the CLI commands the usage text lists are the ones status.md lists;
- every relative link in README.md and docs/*.md resolves to a file;
- every `D<n>` a roadmap item names exists in docs/backlog.md, and every open
  roadmap row has the five cells the table needs;
- no document is orphaned (every docs/*.md is linked from somewhere);
- the forbidden names stay out of the tree.

Usage: python3 scripts/docs_check.py [--verbose]
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Assembled from pieces so this file can scan itself: a gate that exempts itself
# from the rule it enforces is not a gate.
FORBIDDEN = re.compile("|".join(["spacetime" + "db", "clock" + "work", "source" + "trail"]), re.IGNORECASE)
TEXT_SUFFIXES = {".md", ".odin", ".py", ".h", ".txt", ".json", ".yml", ".yaml", ".toml"}

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def read(path: str) -> str:
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def check_version() -> None:
    capi = read("src/capi/capi.odin")
    match = re.search(r'miraidb ([0-9][0-9.]*)', capi)
    if not match:
        fail("the version string is not in src/capi/capi.odin")
        return
    version = match.group(1)
    changelog = read("CHANGELOG.md")
    top = re.search(r"^## ([0-9][0-9.]*)$", changelog, re.MULTILINE)
    if not top:
        fail("CHANGELOG.md has no '## <version>' section")
        return
    if top.group(1) != version:
        fail(f"version drift: the library reports {version}, CHANGELOG.md starts at {top.group(1)}")


def test_count() -> int:
    count = 0
    for name in os.listdir(os.path.join(ROOT, "src", "tests")):
        if not name.endswith(".odin"):
            continue
        text = read(os.path.join("src", "tests", name))
        count += len(re.findall(r"^@\(test\)", text, re.MULTILINE))
    return count


def check_tests() -> None:
    actual = test_count()
    status = read("docs/status.md")
    stated = re.search(r"(\d+) integration tests", status)
    if not stated:
        fail("docs/status.md does not state how many integration tests there are")
    elif int(stated.group(1)) != actual:
        fail(f"test count drift: {actual} tests in src/tests, docs/status.md says {stated.group(1)}")


def gate_count() -> int:
    done = subprocess.run(
        [sys.executable, "scripts/ci.py", "--list"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if done.returncode != 0:
        fail(f"ci.py --list failed: {done.stderr.strip()}")
        return 0
    return len([line for line in done.stdout.splitlines() if line.strip()])


def check_gates() -> None:
    actual = gate_count()
    if actual == 0:
        return
    for path in ("README.md", "docs/status.md", "docs/roadmap.md"):
        text = read(path)
        for match in re.finditer(r"(\d+) (?:CI )?gates", text):
            if int(match.group(1)) != actual:
                line = text[: match.start()].count("\n") + 1
                fail(f"{path}:{line} says {match.group(1)} gates, ci.py has {actual}")


def cli_commands() -> list[str]:
    text = read("src/cli/main.odin")
    usage = text[text.index("USAGE ::"): text.index("main :: proc()")]
    commands = []
    for line in usage.splitlines():
        match = re.match(r"^\s{2}miraidb ([a-z][a-z-]*)", line)
        if match:
            name = match.group(1)
            if name not in commands:
                commands.append(name)
    return commands


def check_commands() -> None:
    usage = cli_commands()
    status = read("docs/status.md")
    match = re.search(r"`miraidb` has (\d+) commands: (.+?)\.\n", status, re.DOTALL)
    if not match:
        fail("docs/status.md does not start the command list with 'has <n> commands:'")
        return
    if int(match.group(1)) != len(usage):
        fail(f"command count drift: the usage text lists {len(usage)}, status.md says {match.group(1)}")
    listed = re.findall(r"`([a-z][a-z-]*)`", match.group(2))
    missing = [name for name in usage if name not in listed]
    extra = [name for name in listed if name not in usage]
    if missing:
        fail(f"docs/status.md does not list these commands: {', '.join(missing)}")
    if extra:
        fail(f"docs/status.md lists commands the CLI does not have: {', '.join(extra)}")


def documents() -> list[str]:
    found = ["README.md", "CONTRIBUTING.md", "CHANGELOG.md"]
    for name in sorted(os.listdir(os.path.join(ROOT, "docs"))):
        if name.endswith(".md"):
            found.append(os.path.join("docs", name))
    return found


def check_links() -> None:
    for path in documents():
        text = read(path)
        base = os.path.dirname(path)
        for match in re.finditer(r"\]\(([^)]+)\)", text):
            target = match.group(1).split("#")[0].strip()
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            resolved = os.path.normpath(os.path.join(base, target))
            if not os.path.exists(os.path.join(ROOT, resolved)):
                line = text[: match.start()].count("\n") + 1
                fail(f"{path}:{line} links to a file that does not exist: {target}")


def check_roadmap() -> None:
    text = read("docs/roadmap.md")
    backlog = read("docs/backlog.md")
    known = set(re.findall(r"^## (D[0-9]+)", backlog, re.MULTILINE))
    for match in re.finditer(r"\bD[0-9]+[a-z]?\b", text):
        item = match.group(0)
        base = re.match(r"D[0-9]+", item).group(0)
        if base not in known:
            line = text[: match.start()].count("\n") + 1
            fail(f"docs/roadmap.md:{line} names {item}, which backlog.md does not describe")
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not re.match(r"^\| \d+ \|", line):
            continue
        cells = line.strip().strip("|").split("|")
        if len(cells) != 5:
            fail(f"docs/roadmap.md:{line_number} has {len(cells)} cells, the table needs 5")


def check_orphans() -> None:
    linked: set[str] = set()
    for path in documents():
        text = read(path)
        for match in re.finditer(r"\]\(([^)]+)\)", text):
            target = os.path.normpath(os.path.join(os.path.dirname(path), match.group(1).split("#")[0]))
            linked.add(target)
    for name in sorted(os.listdir(os.path.join(ROOT, "docs"))):
        if not name.endswith(".md"):
            continue
        path = os.path.join("docs", name)
        if path not in linked and name != "README.md":
            fail(f"{path} is not linked from any document")


def check_forbidden() -> None:
    for directory, _, files in os.walk(ROOT):
        if ".git" in directory.split(os.sep) or os.sep + "bin" in directory or os.sep + "dist" in directory:
            continue
        for name in files:
            if os.path.splitext(name)[1] not in TEXT_SUFFIXES:
                continue
            path = os.path.relpath(os.path.join(directory, name), ROOT)
            try:
                text = open(os.path.join(directory, name), encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            if FORBIDDEN.search(text):
                fail(f"{path} mentions a name the project does not use")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    checks = [
        ("version", check_version),
        ("tests", check_tests),
        ("gates", check_gates),
        ("commands", check_commands),
        ("links", check_links),
        ("roadmap", check_roadmap),
        ("orphans", check_orphans),
        ("forbidden", check_forbidden),
    ]
    for name, check in checks:
        before = len(problems)
        check()
        if args.verbose or len(problems) > before:
            state = "ok  " if len(problems) == before else "FAIL"
            print(f"{state} {name}")
    if problems:
        for problem in problems:
            print(f"     | {problem}")
        print(f"docs: {len(problems)} problem(s)")
        return 1
    print(f"docs: consistent ({test_count()} tests, {gate_count()} gates, {len(cli_commands())} commands)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
