#!/usr/bin/env python3
"""The gates that need a Linux build: the test suite, and two processes on one
SQLite file through the Linux facade.

The tree is copied to a temporary directory on the Linux file system first:
the suite opens thousands of files, and a Windows mount served through WSL
makes that slow; the copy is also a clean tree, nothing a Windows build left.

    python3 scripts/linux_gates.py tests --odin /opt/odin/odin
    python3 scripts/linux_gates.py processes --odin /opt/odin/odin

`tests` fails on a failing test or on a bad free the runner reports; it prints
the runner's random seed with the failures, so a failure can be run again.
`processes` builds libsqlite3_miraidb.so and runs scripts/sqlite_processes.py
with this Python, whose sqlite3 module then loads the facade.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def copy_tree(target: str) -> None:
    # Everything but what builds and tests leave behind.
    ignore = shutil.ignore_patterns(".git", "bin", "_test*", "__pycache__", "*.exe", "*.pdb", "*.dll", "*.obj")
    for name in os.listdir(ROOT):
        if ignore(ROOT, [name]):
            continue
        source = os.path.join(ROOT, name)
        if os.path.isdir(source):
            shutil.copytree(source, os.path.join(target, name), ignore=ignore)
        else:
            shutil.copy2(source, target)


def run_tests(odin: str, work: str) -> int:
    done = subprocess.run([odin, "test", "src/tests", "-out:" + os.path.join(work, "tests.bin")],
                          cwd=work, capture_output=True, text=True, errors="replace")
    output = done.stdout + done.stderr
    lines = output.splitlines()
    summary = [line for line in lines if line.startswith("Finished") or line.startswith(" - ")]
    bad_frees = [line for line in lines if "+++ bad free" in line]
    seed = [line for line in lines if "random seed" in line]
    for line in summary + bad_frees[:10]:
        print(line)
    if done.returncode != 0 or bad_frees:
        for line in seed:
            print(line)
        if not summary:
            print("\n".join(lines[-20:]))
        print(f"linux tests: failed ({len(bad_frees)} bad free(s))")
        return 1
    print("linux tests: ok")
    return 0


def run_processes(odin: str, work: str) -> int:
    library = os.path.join(work, "bin", "libsqlite3_miraidb.so")
    os.makedirs(os.path.dirname(library), exist_ok=True)
    built = subprocess.run([odin, "build", "src/sqlite_compat", "-build-mode:shared", "-out:" + library, "-o:speed"],
                           cwd=work, capture_output=True, text=True, errors="replace")
    if built.returncode != 0:
        print((built.stdout + built.stderr)[-2000:])
        print("linux processes: the facade does not build")
        return 1
    done = subprocess.run([sys.executable, "scripts/sqlite_processes.py", library], cwd=work)
    return done.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("part", choices=["tests", "processes"])
    parser.add_argument("--odin", default=os.environ.get("MIRAIDB_LINUX_ODIN", shutil.which("odin") or "odin"))
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        print("linux gates: not on Linux")
        return 1
    with tempfile.TemporaryDirectory(prefix="miraidb-linux-") as work:
        copy_tree(work)
        if args.part == "tests":
            return run_tests(args.odin, work)
        return run_processes(args.odin, work)


if __name__ == "__main__":
    raise SystemExit(main())
