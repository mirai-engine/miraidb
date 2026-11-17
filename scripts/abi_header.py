#!/usr/bin/env python3
"""The public headers must declare exactly what the libraries export.

A shared library with symbols and no header is not an API: a C program cannot
compile against it, and nothing notices when a function is exported and never
declared (or declared and never exported). This gate reads the two Odin sources
that carry the `@(export)` procedures, reads the two headers, and compares.

    python3 scripts/abi_header.py
    python3 scripts/abi_header.py --cc /usr/bin/cc     # also compile the headers

It also compiles each header on its own when a C compiler is available, which is
the only way to know that a declaration is well formed and the header is
self-contained.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Each package, every .odin file in it, against its header.
PAIRS = [
    ("src/sqlite_compat", "include/sqlite3_miraidb.h", "sqlite3_"),
    ("src/capi", "include/miraidb.h", "miraidb_"),
]

COMMENT = re.compile(r"/\*.*?\*/", re.S)


def exported(package: str, prefix: str) -> set[str]:
    """Names a package exports: `@(export)` then `name :: proc "c"`, in any file."""
    directory = os.path.join(ROOT, package)
    text = "".join(
        open(os.path.join(directory, name), encoding="utf-8").read()
        for name in sorted(os.listdir(directory))
        if name.endswith(".odin")
    )
    names = set()
    for match in re.finditer(r"@\(export\)\s*\n\s*([a-z0-9_]+)\s*::\s*proc", text):
        name = match.group(1)
        if name.startswith(prefix):
            names.add(name)
    return names


def declared(header_path: str, prefix: str) -> set[str]:
    """Names a header declares: a name followed by an argument list."""
    text = open(os.path.join(ROOT, header_path), encoding="utf-8").read()
    text = COMMENT.sub("", text)
    # Drop the include guard and macro values: only a call-like occurrence counts.
    return set(re.findall(rf"\b({prefix}[a-z0-9_]+)\s*\(", text))


def compiles(cc: str, header_path: str) -> tuple[bool, str]:
    program = (
        f'#include "{os.path.join(ROOT, header_path)}"\n'
        "int main(void) { return 0; }\n"
    )
    done = subprocess.run(
        [cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-fsyntax-only", "-x", "c", "-"],
        input=program, capture_output=True, text=True,
    )
    return done.returncode == 0, (done.stdout + done.stderr).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default=shutil.which("cc") or shutil.which("gcc"))
    args = parser.parse_args()

    problems = 0
    for source, header, prefix in PAIRS:
        codes = exported(source, prefix)
        names = declared(header, prefix)
        missing = sorted(codes - names)
        extra = sorted(names - codes)
        if missing:
            print(f"{header}: exports not declared: {', '.join(missing)}")
            problems += 1
        if extra:
            print(f"{header}: declared but not exported: {', '.join(extra)}")
            problems += 1
        if not missing and not extra:
            print(f"{header}: {len(codes)} symbols, all declared")

    if args.cc:
        for _, header, _ in PAIRS:
            ok, output = compiles(args.cc, header)
            if not ok:
                print(f"{header}: does not compile on its own:\n{output}")
                problems += 1
            else:
                print(f"{header}: compiles on its own")
    else:
        print("no C compiler found: skipped the standalone compile")

    if problems:
        print(f"abi header: {problems} problem(s)")
        return 1
    print("abi header: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
