#!/usr/bin/env python3
"""SQLite's own command-line shell, built against the facade and against SQLite.

The shell is SQLite's shell.c (generated from the SQLite source tree it ships
with, the same release the facade answers as), compiled twice: once linked to
a SQLite library built from that tree, once linked to the facade. Each case in
scripts/shell_cases/ is fed to both on a fresh database file, and the outputs
are compared line by line. C is only the harness here: it is SQLite's own
client and SQLite's own library, the yardstick; the facade is Odin.

What the build needs, found on PATH or under --sqlite-src: SQLite's source tree
(../sqlite by default), tclsh, sh, a C compiler (gcc or cc) and make (gmake or
make). The reference library and the two shells are built once into
bin/shell_compare/ and reused. Without them the gate says what is missing and
passes, as the DLL smokes do without a Windows Python.

KNOWN lists the differences that have a reason, with the reason; any other
difference fails the gate, and so does a known one that no longer happens.

    python scripts/sqlite_shell.py [path/to/sqlite3_miraidb.dll]
    python scripts/sqlite_shell.py --sqlite-src ../sqlite --rebuild
"""

from __future__ import annotations

import argparse
import ctypes
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "scripts", "shell_cases")
CACHE = os.path.join(ROOT, "bin", "shell_compare")
LIBRARY = "sqlite3_miraidb.dll" if os.name == "nt" else "libsqlite3_miraidb.so"

# A difference is known when SQLite's line matches the pattern: the reason is
# what the engine does instead.
KNOWN: list[tuple[str, str]] = [
    (r"WITHOUT ROWID",
     "a WITHOUT ROWID table keeps the engine's text in sqlite_schema, not the one it was "
     "created with, because an export writes it as a rowid table (S7)"),
]


def tool(*names: str) -> str | None:
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return None


def run(command: list[str], cwd: str, log: str) -> None:
    with open(log, "w", encoding="utf-8", errors="replace") as out:
        done = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    if done.returncode != 0:
        tail = open(log, encoding="utf-8", errors="replace").read()[-800:]
        raise SystemExit(f"sqlite shell: {' '.join(command[:3])} failed:\n{tail}")


def build(sqlite_src: str, facade: str, rebuild: bool) -> tuple[str, str, str]:
    """Build the reference library and both shells; answer their paths."""
    version = open(os.path.join(sqlite_src, "VERSION"), encoding="utf-8").read().strip()
    cache = os.path.join(CACHE, version)
    if rebuild and os.path.exists(cache):
        shutil.rmtree(cache)
    os.makedirs(cache, exist_ok=True)
    tclsh, sh = tool("tclsh", "tclsh8.6", "tclsh86"), tool("sh", "bash")
    cc, make = tool("gcc", "cc", "clang"), tool("gmake", "make", "mingw32-make")
    shared = "sqlite3_ref.dll" if os.name == "nt" else "libsqlite3_ref.so"
    reference = os.path.join(cache, shared)
    amalgamation = os.path.join(cache, "amalgamation")
    if not os.path.exists(reference):
        os.makedirs(amalgamation, exist_ok=True)
        if not os.path.exists(os.path.join(amalgamation, "sqlite3.c")):
            configure = os.path.join(sqlite_src, "configure").replace("\\", "/")
            run([sh, configure, "--disable-tcl"], amalgamation, os.path.join(cache, "configure.log"))
            run([make, "sqlite3.c"], amalgamation, os.path.join(cache, "make.log"))
        options = ["-DSQLITE_ENABLE_FTS4", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_RTREE",
                   "-DSQLITE_ENABLE_MATH_FUNCTIONS", "-DSQLITE_ENABLE_PERCENTILE",
                   "-DSQLITE_ENABLE_COLUMN_METADATA", "-DSQLITE_DQS=0"]
        flags = ["-shared"] if os.name == "nt" else ["-shared", "-fPIC"]
        run([cc, "-O1", "-w", *flags, *options, "sqlite3.c", "-o", reference], amalgamation,
            os.path.join(cache, "library.log"))
    # shell.c lives apart from any sqlite3.h, so each build reads its own header.
    source = os.path.join(cache, "shell")
    os.makedirs(source, exist_ok=True)
    shell_c = os.path.join(source, "shell.c")
    if not os.path.exists(shell_c):
        with open(shell_c, "w", encoding="utf-8", newline="\n") as out:
            done = subprocess.run([tclsh, "tool/mkshellc.tcl"], cwd=sqlite_src, stdout=out)
        if done.returncode != 0:
            raise SystemExit("sqlite shell: mkshellc.tcl failed")
    reference_header = os.path.join(amalgamation, "sqlite3.h")
    # The facade's build reads SQLite's header with the facade's source id: the
    # shell refuses a library whose id does not match its header's.
    facade_id = facade_source_id(facade)
    facade_include = os.path.join(cache, "facade_include")
    os.makedirs(facade_include, exist_ok=True)
    header = open(reference_header, encoding="utf-8").read()
    header = re.sub(r'#define SQLITE_SOURCE_ID\s+"[^"]*"', f'#define SQLITE_SOURCE_ID      "{facade_id}"', header)
    with open(os.path.join(facade_include, "sqlite3.h"), "w", encoding="utf-8", newline="\n") as out:
        out.write(header)
    shell_ref = os.path.join(cache, "shell_ref.exe" if os.name == "nt" else "shell_ref")
    shell_fac = os.path.join(cache, "shell_facade.exe" if os.name == "nt" else "shell_facade")
    common = ["-O1", "-w", "-DSQLITE_OMIT_LOAD_EXTENSION"]
    libraries = [] if os.name == "nt" else ["-lm", "-lpthread", "-Wl,-rpath," + cache]
    if not os.path.exists(shell_ref):
        run([cc, *common, "-I" + amalgamation, shell_c, reference, "-o", shell_ref, *libraries], cache,
            os.path.join(cache, "shell_ref.log"))
    # The facade's shell is rebuilt each run: the facade changes under it.
    shutil.copy(facade, os.path.join(cache, os.path.basename(facade)))
    run([cc, *common, "-I" + facade_include, shell_c, os.path.join(cache, os.path.basename(facade)), "-o", shell_fac,
         *libraries], cache, os.path.join(cache, "shell_facade.log"))
    return cache, shell_ref, shell_fac


def facade_source_id(facade: str) -> str:
    library = ctypes.CDLL(os.path.abspath(facade))
    library.sqlite3_sourceid.restype = ctypes.c_char_p
    # The first 84 characters are SQLite's id: the date, the time and the hash.
    return library.sqlite3_sourceid().decode()[:84]


def run_case(shell: str, case: str, directory: str) -> list[str]:
    os.makedirs(directory, exist_ok=True)
    with open(case, "rb") as text:
        done = subprocess.run([shell, "t.db"], cwd=directory, stdin=text, capture_output=True, timeout=120)
    output = (done.stdout + done.stderr).decode("utf-8", errors="replace")
    # The database's own path differs between the two runs; nothing else may.
    output = output.replace(os.path.abspath(directory), "<dir>")
    return output.replace("\r\n", "\n").split("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("facade", nargs="?", default=os.path.join(ROOT, "bin", LIBRARY))
    parser.add_argument("--sqlite-src", default=os.environ.get("MIRAIDB_SQLITE_SRC", os.path.join(ROOT, "..", "sqlite")))
    parser.add_argument("--rebuild", action="store_true", help="build the reference again")
    args = parser.parse_args()
    missing = [name for name, found in [
        ("SQLite's source tree", os.path.exists(os.path.join(args.sqlite_src, "VERSION"))),
        ("tclsh", tool("tclsh", "tclsh8.6", "tclsh86")),
        ("sh", tool("sh", "bash")),
        ("a C compiler", tool("gcc", "cc", "clang")),
        ("make", tool("gmake", "make", "mingw32-make")),
        ("the facade", os.path.exists(args.facade)),
    ] if not found]
    if missing:
        print(f"sqlite shell: skipped, missing {', '.join(missing)}")
        return 0
    _, shell_ref, shell_fac = build(os.path.abspath(args.sqlite_src), os.path.abspath(args.facade), args.rebuild)
    failures: list[str] = []
    used = [False] * len(KNOWN)
    compared = 0
    for case in sorted(glob.glob(os.path.join(CASES, "*.sql"))):
        name = os.path.basename(case)
        with tempfile.TemporaryDirectory() as work:
            want = run_case(shell_ref, case, os.path.join(work, "sqlite"))
            got = run_case(shell_fac, case, os.path.join(work, "facade"))
        if len(want) != len(got):
            failures.append(f"{name}: SQLite wrote {len(want)} lines, the facade {len(got)}")
        for k, (expected, actual) in enumerate(zip(want, got)):
            compared += 1
            if expected == actual:
                continue
            reason = next((i for i, (pattern, _) in enumerate(KNOWN) if re.search(pattern, expected)), None)
            if reason is not None:
                used[reason] = True
                continue
            failures.append(f"{name}:{k + 1}: SQLite {expected!r}, facade {actual!r}")
    for i, (pattern, why) in enumerate(KNOWN):
        if not used[i]:
            failures.append(f"known difference {pattern!r} no longer happens; take it out of KNOWN ({why})")
    for line in failures[:40]:
        print(line)
    print(f"sqlite shell: {compared} lines compared over {len(glob.glob(os.path.join(CASES, '*.sql')))} cases, "
          f"{sum(used)} known difference(s), {len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
