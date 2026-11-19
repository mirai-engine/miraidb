#!/usr/bin/env python3
"""SQLite's own tools -- sqldiff, dbhash and mptest -- built against the facade and against SQLite.

Each tool comes from SQLite's source tree (the same release the facade answers
as) and is compiled twice: once linked to a SQLite library built from that
tree, once linked to the facade. C is only the harness: the clients and the
yardstick are SQLite's; the facade is Odin.

  - sqldiff and dbhash run over databases SQLite's own shell writes, with each
    of their options; the facade's build has to print what SQLite's prints,
    byte for byte, and exit the same way.
  - dbhash also hashes what the facade writes: the same statements run through
    SQLite's shell and through the facade's give databases with the same
    content hash.
  - mptest runs SQLite's multi-process scripts (mptest/*.test): several
    processes write one file at once through the facade, and every check the
    script makes has to pass, as many as SQLite runs.

What the build needs is what scripts/sqlite_shell.py needs (SQLite's source
tree, tclsh, sh, a C compiler and make); without it the gate says what is
missing and passes. KNOWN lists the differences that have a reason; any other
fails, and so does a known one that no longer happens.

    python scripts/sqlite_tools.py [path/to/sqlite3_miraidb.dll]
"""

from __future__ import annotations

import argparse
import ctypes
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sqlite_shell as shell  # noqa: E402

ROOT = shell.ROOT
EXE = ".exe" if os.name == "nt" else ""

# A known difference: the tool and its options, with the reason.
KNOWN: dict[tuple[str, str], str] = {
    ("sqldiff", "--vtab"): "a TEMP table on a read-only connection: SQLite's temp "
    "database is writable when main is not; the facade keeps temp tables in main",
}

# Pairs of databases for sqldiff and the single ones dbhash hashes. Every
# statement is deterministic, so the content hash test can run them too.
FIRST = """
CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b REAL, c BLOB);
INSERT INTO t VALUES(1,'x',1.5,x'00ff'),(2,'y',NULL,NULL),(3,'it''s',2,x''),
  (4,'ünïcode',-0.0,zeroblob(3)),(5,NULL,1e300,x'0102');
CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO w VALUES('a',1),('b',2),('c',NULL);
CREATE TABLE p(x, y, z, PRIMARY KEY(y, x));
INSERT INTO p VALUES(1,'one',1.0),(2,'two',2.0),(3,'three',3.0);
CREATE TABLE n(q, r);
INSERT INTO n VALUES(1,2),(1,2),(3,NULL);
CREATE INDEX ta ON t(a);
CREATE INDEX pz ON p(z DESC);
CREATE VIEW vv AS SELECT a, b FROM t WHERE id > 1;
CREATE TABLE big(id INTEGER PRIMARY KEY, body);
WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 300)
  INSERT INTO big SELECT i, printf('%.*c', (i * 37) % 900 + 1, 'x') FROM s;
INSERT INTO big VALUES(1000, zeroblob(9000)), (1001, printf('%.*c', 20000, 'q'));
"""

SECOND = """
CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT, b REAL, c BLOB);
INSERT INTO t VALUES(1,'x',1.5,x'00ff'),(2,'z',3,NULL),(4,'ünïcode',0.0,zeroblob(4)),
  (6,'new',NULL,NULL);
CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO w VALUES('a',9),('c',NULL),('d',4);
CREATE TABLE p(x, y, z, PRIMARY KEY(y, x));
INSERT INTO p VALUES(1,'one',1.0),(2,'two',2.5),(4,'four',4.0);
CREATE TABLE n(q, r, s);
INSERT INTO n VALUES(1,2,3);
CREATE TABLE extra(e);
INSERT INTO extra VALUES('only here');
CREATE INDEX pz ON p(z);
CREATE TABLE big(id INTEGER PRIMARY KEY, body);
WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 300)
  INSERT INTO big SELECT i, printf('%.*c', (i * 41) % 900 + 1, 'x') FROM s;
INSERT INTO big VALUES(1000, zeroblob(9000)), (1002, printf('%.*c', 20000, 'r'));
DELETE FROM big WHERE id % 7 = 0;
"""

# Statements the facade has to store as SQLite stores them: hashed after both
# shells run them on a new file. Updates and deletes move rows across pages.
CONTENT = [
    ("first", FIRST),
    ("second", SECOND),
    ("churn", FIRST + """
UPDATE big SET body = printf('%.*c', 5000, 'u') WHERE id % 3 = 0;
DELETE FROM big WHERE id % 5 = 0;
UPDATE t SET a = a || '!' WHERE id < 4;
INSERT INTO big SELECT id + 2000, body FROM big WHERE id < 50;
DROP INDEX ta;
ALTER TABLE n ADD COLUMN s DEFAULT 7;
"""),
]

# An mptest script with known differences: every check it fails has to be one
# of these, and it has to fail at least one.
KNOWN_MPTEST: dict[str, tuple[str, str]] = {
    "config02.test": (r"Expected \[(512|1024|2048|8192|16384|32768|65536)( \1)*\]",
                      "PRAGMA page_size then VACUUM: the facade writes 4096-byte pages"),
}

SQLDIFF_OPTIONS = [[], ["--summary"], ["--primarykey"], ["--schema"], ["--table", "t"], ["--table", "w"],
                   ["--transaction"], ["--rbu"], ["--vtab"], ["--schema", "--summary"]]
DBHASH_OPTIONS = [[], ["--schema-only"], ["--without-schema"], ["--like", "t%"], ["--debug", "1"]]


def facade_source_id(facade: str) -> str:
    library = ctypes.CDLL(os.path.abspath(facade))
    library.sqlite3_sourceid.restype = ctypes.c_char_p
    return library.sqlite3_sourceid().decode()


def build_tools(sqlite_src: str, facade: str, rebuild: bool) -> tuple[dict[str, tuple[str, str]], str, str]:
    """Build both shells (for the fixtures) and both builds of each tool."""
    cache, shell_ref, shell_fac = shell.build(sqlite_src, facade, rebuild)
    _, reference, amalgamation = shell.build_reference(sqlite_src)
    cc = shell.tool("gcc", "cc", "clang")
    work = os.path.join(cache, "tools")
    os.makedirs(work, exist_ok=True)
    # Each source lives apart from any sqlite3.h, so each build reads its own.
    sources = {
        "sqldiff": [os.path.join(sqlite_src, "tool", "sqldiff.c"), os.path.join(sqlite_src, "ext", "misc", "sqlite3_stdio.c")],
        "dbhash": [os.path.join(sqlite_src, "tool", "dbhash.c")],
        "mptest": [os.path.join(sqlite_src, "mptest", "mptest.c")],
    }
    source_dir = os.path.join(work, "src")
    os.makedirs(source_dir, exist_ok=True)
    for files in sources.values():
        for path in files:
            shutil.copy(path, source_dir)
    shutil.copy(os.path.join(sqlite_src, "ext", "misc", "sqlite3_stdio.h"), source_dir)
    # mptest compares the whole source id with its header's, so the facade's
    # build reads SQLite's header with the facade's id in it.
    facade_include = os.path.join(work, "facade_include")
    os.makedirs(facade_include, exist_ok=True)
    header = open(os.path.join(amalgamation, "sqlite3.h"), encoding="utf-8").read()
    header = re.sub(r'#define SQLITE_SOURCE_ID\s+"[^"]*"', f'#define SQLITE_SOURCE_ID      "{facade_source_id(facade)}"', header)
    with open(os.path.join(facade_include, "sqlite3.h"), "w", encoding="utf-8", newline="\n") as out:
        out.write(header)
    library = os.path.join(work, os.path.basename(facade))
    shutil.copy(facade, library)
    common = ["-O1", "-w", "-DSQLITE_OMIT_LOAD_EXTENSION"]
    extra = [] if os.name == "nt" else ["-lm", "-lpthread", "-Wl,-rpath," + work, "-Wl,-rpath," + cache]
    built: dict[str, tuple[str, str]] = {}
    for name, files in sources.items():
        inputs = [os.path.join(source_dir, os.path.basename(path)) for path in files]
        ref_dir, fac_dir = os.path.join(work, "ref"), os.path.join(work, "facade")
        os.makedirs(ref_dir, exist_ok=True)
        os.makedirs(fac_dir, exist_ok=True)
        # The same file name in both builds: a tool prints its own path.
        ref_exe, fac_exe = os.path.join(ref_dir, name + EXE), os.path.join(fac_dir, name + EXE)
        if not os.path.exists(ref_exe) or rebuild:
            shell.run([cc, *common, "-I" + amalgamation, "-I" + source_dir, *inputs, reference, "-o", ref_exe, *extra],
                      work, os.path.join(work, name + "_ref.log"))
        # The facade's build is made again each run: the facade changes under it.
        shell.run([cc, *common, "-I" + facade_include, "-I" + source_dir, *inputs, library, "-o", fac_exe, *extra],
                  work, os.path.join(work, name + "_facade.log"))
        built[name] = (ref_exe, fac_exe)
    if os.name == "nt":
        # Each build finds its library next to it.
        for directory, path in ((os.path.join(work, "ref"), reference), (os.path.join(work, "facade"), library)):
            shutil.copy(path, os.path.join(directory, os.path.basename(path)))
    return built, shell_ref, shell_fac


def make_db(shell_exe: str, path: str, sql: str) -> None:
    done = subprocess.run([shell_exe, path], input=sql.encode(), capture_output=True, timeout=300)
    if done.returncode != 0 or done.stderr:
        raise SystemExit(f"sqlite tools: {os.path.basename(shell_exe)} could not build {os.path.basename(path)}:\n"
                         + (done.stdout + done.stderr).decode(errors="replace")[-800:])


def run_tool(exe: str, args: list[str], directory: str) -> str:
    done = subprocess.run([exe, *args], cwd=directory, capture_output=True, timeout=300)
    output = (done.stdout + done.stderr).decode("utf-8", errors="replace").replace("\r\n", "\n")
    # The tool names itself by the path it ran from.
    output = output.replace(exe, os.path.basename(exe))
    return f"{output}exit {done.returncode}\n"


def compare_tools(built: dict[str, tuple[str, str]], shell_ref: str, problems: list[str], used: set) -> int:
    compared = 0
    with tempfile.TemporaryDirectory() as fixtures:
        first, second = os.path.join(fixtures, "first.db"), os.path.join(fixtures, "second.db")
        make_db(shell_ref, first, FIRST)
        make_db(shell_ref, second, SECOND)
        runs: list[tuple[str, list[str], list[str]]] = []
        for options in SQLDIFF_OPTIONS:
            for pair in (["first.db", "second.db"], ["second.db", "first.db"], ["first.db", "first.db"]):
                runs.append(("sqldiff", options, pair))
        for options in DBHASH_OPTIONS:
            runs.append(("dbhash", options, ["first.db", "second.db"]))
        for name, options, files in runs:
            outputs = []
            for exe in built[name]:
                with tempfile.TemporaryDirectory() as work:
                    # A fresh copy for every run: nothing one run does reaches the next.
                    for file in set(files):
                        shutil.copy(os.path.join(fixtures, file), os.path.join(work, file))
                    outputs.append(run_tool(exe, [*options, *files], work))
            compared += 1
            label = " ".join([name, *options, *files])
            known = KNOWN.get((name, " ".join(options)))
            if outputs[0] == outputs[1]:
                if known:
                    problems.append(f"known difference no longer happens, take it out of KNOWN: {label}")
                continue
            if known:
                used.add((name, " ".join(options)))
                continue
            want, got = outputs[0].splitlines(), outputs[1].splitlines()
            line = next((i for i, (a, b) in enumerate(zip(want, got)) if a != b), min(len(want), len(got)))
            problems.append(f"{label}: line {line + 1}: SQLite {want[line] if line < len(want) else '<end>'!r}, "
                            f"facade {got[line] if line < len(got) else '<end>'!r}")
    return compared


def compare_content(dbhash_ref: str, shell_ref: str, shell_fac: str, problems: list[str]) -> int:
    """The same statements through both shells give databases dbhash calls equal."""
    with tempfile.TemporaryDirectory() as work:
        for name, sql in CONTENT:
            hashes = []
            for side, exe in (("sqlite", shell_ref), ("facade", shell_fac)):
                path = os.path.join(work, f"{name}_{side}.db")
                make_db(exe, path, sql)
                check = subprocess.run([shell_ref, path, "PRAGMA integrity_check"], capture_output=True, timeout=120)
                verdict = check.stdout.decode(errors="replace").strip()
                if verdict != "ok":
                    problems.append(f"content {name}: SQLite's integrity_check of the {side}'s file says {verdict!r}")
                hashed = subprocess.run([dbhash_ref, path], capture_output=True, timeout=120)
                hashes.append(hashed.stdout.decode(errors="replace").split(" ")[0])
            if hashes[0] != hashes[1]:
                problems.append(f"content {name}: SQLite's file hashes {hashes[0]}, the facade's {hashes[1]}")
    return len(CONTENT)


SUMMARY = re.compile(r"Summary: (\d+) errors out of (\d+) tests")


def run_mptest(exe: str, script: str, directory: str) -> tuple[int, int, int, str]:
    for leftover in os.listdir(directory):
        if leftover.startswith("mptest.db"):
            os.remove(os.path.join(directory, leftover))
    done = subprocess.run([exe, "mptest.db", script, "--quiet"], cwd=directory, capture_output=True, timeout=900)
    output = (done.stdout + done.stderr).decode("utf-8", errors="replace")
    # Every client prints a summary of its own as it ends, in any order: the
    # script's is the main process's, the one right before its END line.
    lines = output.splitlines()
    for at, line in enumerate(lines):
        if not line.startswith("END: ") or at == 0:
            continue
        found = SUMMARY.search(lines[at - 1])
        if found:
            return int(found.group(1)), int(found.group(2)), done.returncode, output
    return -1, -1, done.returncode, output


def compare_mptest(built: dict[str, tuple[str, str]], sqlite_src: str, problems: list[str], used: set) -> int:
    ref_exe, fac_exe = built["mptest"]
    scripts = sorted(name for name in os.listdir(os.path.join(sqlite_src, "mptest")) if name.endswith(".test"))
    # A checkout may carry CRLF, which mptest compares as text.
    texts = {name: open(os.path.join(sqlite_src, "mptest", name), "rb").read().replace(b"\r\n", b"\n")
             for name in os.listdir(os.path.join(sqlite_src, "mptest")) if name.endswith((".test", ".subtest"))}

    def run_apart(exe: str, script: str) -> tuple[int, int, int, str]:
        # Every run in a directory of its own: no file, journal or straggling
        # client of one run is the next run's.
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as work:
            for name, text in texts.items():
                open(os.path.join(work, name), "wb").write(text)
            return run_mptest(exe, script, work)

    if scripts:
        for script in scripts:
            ref_errors, ref_tests, _, ref_output = run_apart(ref_exe, script)
            errors, tests, code, output = run_apart(fac_exe, script)
            known = KNOWN_MPTEST.get(script)
            if known and tests == ref_tests:
                expected = [line for line in output.splitlines() if "Expected [" in line]
                if errors == 0:
                    problems.append(f"mptest {script}: the known difference no longer happens, take it out of KNOWN_MPTEST")
                    continue
                if len(expected) == errors and all(re.search(known[0], line) for line in expected):
                    used.add(("mptest", script))
                    continue
            if ref_errors != 0:
                problems.append(f"mptest {script}: SQLite itself fails it ({ref_errors} errors): {ref_output[-300:]}")
            elif errors != 0 or tests != ref_tests or code != 0:
                failed = [line for line in output.splitlines() if "ERROR" in line or "FATAL" in line][:6]
                problems.append(f"mptest {script}: {errors} errors in {tests} tests (SQLite runs {ref_tests}), exit {code}"
                                + "".join(f"\n    {line}" for line in failed))
    return len(scripts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("facade", nargs="?", default=os.path.join(ROOT, "bin", shell.LIBRARY))
    parser.add_argument("--sqlite-src", default=shell.default_source())
    parser.add_argument("--rebuild", action="store_true", help="build the reference again")
    parser.add_argument("--skip-mptest", action="store_true", help="leave out the multi-process scripts")
    args = parser.parse_args()
    missing = shell.missing_tools(args.sqlite_src) + ([] if os.path.exists(args.facade) else ["the facade"])
    if missing:
        print(f"sqlite tools: skipped, missing {', '.join(missing)}")
        return 0
    sqlite_src = os.path.abspath(args.sqlite_src)
    built, shell_ref, shell_fac = build_tools(sqlite_src, os.path.abspath(args.facade), args.rebuild)
    problems: list[str] = []
    used: set = set()
    runs = compare_tools(built, shell_ref, problems, used)
    contents = compare_content(built["dbhash"][0], shell_ref, shell_fac, problems)
    scripts = 0 if args.skip_mptest else compare_mptest(built, sqlite_src, problems, used)
    for line in problems[:40]:
        print(line)
    print(f"sqlite tools: {runs} sqldiff/dbhash runs, {contents} content hashes, {scripts} mptest scripts, "
          f"{len(used)} known difference(s), {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
