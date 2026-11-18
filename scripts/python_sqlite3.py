#!/usr/bin/env python3
"""Python's own sqlite3 module, and CPython's tests of it, on the facade.

The module (`_sqlite3.pyd` on Windows, `_sqlite3.*.so` elsewhere) is linked
against SQLite's library. This copies it next to the facade, named as SQLite's
library is, puts that directory first on the module path, and runs CPython's
`test.test_sqlite3` suite module by module: each test that passes with SQLite
has to pass here too.

`KNOWN` lists the tests that do not, each with the reason. The gate fails on a
test that fails and is not listed, on a module that crashes or hangs, and on a
listed test that now passes (move it out of the list).

Usage:
    python scripts/python_sqlite3.py [path/to/sqlite3_miraidb.dll]
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile



def suite_modules() -> list[str]:
    """The modules of this Python's test.test_sqlite3 (3.12 adds test_cli)."""
    import importlib.util
    # Found, not imported: importing the package prints the SQLite this
    # process loaded, which is not the facade.
    spec = importlib.util.find_spec("test.test_sqlite3")
    directory = list(spec.submodule_search_locations)[0]
    return sorted(name[:-3] for name in os.listdir(directory) if name.startswith("test_") and name.endswith(".py"))


# test id (module.Class.test) -> why it differs from SQLite here.
KNOWN: dict[str, str] = {
}


def module_binary() -> str:
    """The _sqlite3 extension this Python loads."""
    import _sqlite3  # noqa: F401 -- what is wanted is its file
    return sys.modules["_sqlite3"].__file__


def stage(facade: str, directory: str) -> None:
    binary = module_binary()
    shutil.copy(binary, directory)
    library = "sqlite3.dll" if os.name == "nt" else "libsqlite3.so.0"
    shutil.copy(facade, os.path.join(directory, library))


def run_module(directory: str, module: str, timeout: int = 300) -> tuple[dict[str, str], str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = directory + os.pathsep + env.get("PYTHONPATH", "")
    if os.name != "nt":
        env["LD_LIBRARY_PATH"] = directory + os.pathsep + env.get("LD_LIBRARY_PATH", "")
    try:
        done = subprocess.run(
            [sys.executable, "-m", "unittest", "-v", f"test.test_sqlite3.{module}"],
            cwd=directory, env=env, capture_output=True, text=True, encoding="utf-8",
            errors="replace", timeout=timeout,
        )
    except subprocess.TimeoutExpired as expired:
        return {}, f"timed out after {timeout}s; last output: {(expired.stderr or '')[-300:]!r}"
    outcomes: dict[str, str] = {}
    for line in done.stderr.splitlines():
        match = re.match(r"^(test\w+) \(test\.test_sqlite3\.(\w+)\.(\w+)\.(test\w+)\)", line)
        if not match:
            continue
        verdict = line.rsplit(" ... ", 1)[-1] if " ... " in line else ""
        outcomes[f"{match.group(2)}.{match.group(3)}.{match.group(1)}"] = verdict.strip()
    problem = ""
    if done.returncode not in (0, 1):
        problem = f"exited with {done.returncode}; last output: {done.stderr[-300:]!r}"
    elif "Ran " not in done.stderr:
        problem = f"did not finish; last output: {done.stderr[-300:]!r}"
    return outcomes, problem


def main() -> int:
    facade = sys.argv[1] if len(sys.argv) > 1 else os.path.join("bin", "sqlite3_miraidb.dll")
    if not os.path.exists(facade):
        print(f"python sqlite3: no facade at {facade}")
        return 1
    failures: list[str] = []
    passed = 0
    with tempfile.TemporaryDirectory() as directory:
        stage(os.path.abspath(facade), directory)
        for module in suite_modules():
            outcomes, problem = run_module(directory, module)
            if problem:
                failures.append(f"{module}: {problem}")
            for test, verdict in sorted(outcomes.items()):
                failing = verdict in ("FAIL", "ERROR", "unexpected success")
                if failing and test not in KNOWN:
                    failures.append(f"{test}: {verdict}")
                elif not failing and test in KNOWN and verdict == "ok":
                    failures.append(f"{test} passes now; take it out of KNOWN ({KNOWN[test]})")
                elif verdict == "ok":
                    passed += 1
    for line in failures:
        print(line)
    print(f"python sqlite3: {passed} tests pass, {len(KNOWN)} known differences, {len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
