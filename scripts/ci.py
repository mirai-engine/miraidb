#!/usr/bin/env python3
"""Run every gate in one command: build, tests, conformance, smokes, vet, roadmap.

    python3 scripts/ci.py
    python3 scripts/ci.py --skip-dll          # no Windows Python available
    python3 scripts/ci.py --odin /path/to/odin --windows-python /path/to/python.exe

Each gate is reported on its own line with its duration; the run keeps going
after a failure so one pass shows everything that is wrong, and the exit code is
1 if any gate failed.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import shutil
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The compiler comes from $ODIN, then from PATH. Pass --odin when neither finds
# it, so nothing here depends on one machine's layout.
DEFAULT_ODIN = os.environ.get("ODIN") or shutil.which("odin") or "odin"
# A Windows binary cannot be driven by a WSL Python: set MIRAIDB_WINDOWS_PYTHON
# (or --windows-python) to the interpreter that can load the DLL. Without it the
# DLL smokes are skipped with a message.
DEFAULT_WINDOWS_PYTHON = os.environ.get("MIRAIDB_WINDOWS_PYTHON", "")
PACKAGES = ["src/engine", "src/cli", "src/capi", "src/sqlite_compat", "src/server", "src/tests"]


class Gate:
    def __init__(self, name: str, command: list[str], env: dict[str, str] | None = None):
        self.name = name
        self.command = command
        self.env = env or {}

    def run(self) -> tuple[bool, str, float]:
        started = time.time()
        environment = {**os.environ, **self.env}
        done = subprocess.run(
            self.command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            env=environment,
        )
        elapsed = time.time() - started
        output = (done.stdout + done.stderr).strip()
        return done.returncode == 0, output, elapsed


def tail(text: str, lines: int = 6) -> str:
    return "\n".join(text.splitlines()[-lines:])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--odin", default=os.environ.get("ODIN", DEFAULT_ODIN))
    parser.add_argument("--windows-python", default=DEFAULT_WINDOWS_PYTHON)
    parser.add_argument("--skip-dll", action="store_true", help="skip the DLL smokes")
    parser.add_argument("--skip-build", action="store_true", help="reuse the existing binaries")
    args = parser.parse_args()

    if not os.path.exists(args.odin):
        print(f"ci: odin not found at {args.odin}; pass --odin", file=sys.stderr)
        return 2
    odin_env = {"ODIN": args.odin}
    gates: list[Gate] = []
    if not args.skip_build:
        gates.append(Gate("build (binaries + suite)", [sys.executable, "scripts/build.py"], odin_env))
    gates.append(Gate("unit tests", [args.odin, "test", "src/tests"]))
    gates.append(
        Gate("conformance (20 cases)", [sys.executable, "scripts/conformance.py", "--bin", "./bin/miraidb.exe"])
    )
    gates.append(Gate("shell smoke", [sys.executable, "scripts/shell_smoke.py"]))
    gates.append(Gate("performance baseline", [sys.executable, "scripts/bench.py", "--check"]))
    gates.append(Gate("package manifest", [sys.executable, "scripts/package.py", "--check"]))
    gates.append(
        Gate("page memory", [sys.executable, "scripts/page_rss.py", "--check", "--bin", "./bin/miraidb.exe"])
    )
    gates.append(
        Gate("plan regression", [sys.executable, "scripts/plan_check.py", "--bin", "./bin/miraidb.exe"])
    )
    if not args.skip_dll:
        if os.path.exists(args.windows_python):
            gates.append(Gate("C ABI smoke", [args.windows_python, "scripts/capi_smoke.py"]))
            gates.append(
                Gate("sqlite3_* smoke", [args.windows_python, "scripts/sqlite_abi_smoke.py"])
            )
            gates.append(
                Gate("Python SDK smoke", [args.windows_python, "scripts/sdk_smoke.py"])
            )
            gates.append(
                Gate("writer lock (two processes)", [args.windows_python, "scripts/lock_smoke.py"])
            )
            gates.append(
                Gate("broker (two processes)", [args.windows_python, "scripts/broker_smoke.py"])
            )
        else:
            print(f"ci: no Windows Python at {args.windows_python}; skipping the DLL smokes")
    for package in PACKAGES:
        gates.append(
            Gate(f"vet {package}", [args.odin, "check", package, "-no-entry-point", "-vet"])
        )
    gates.append(Gate("roadmap is consistent", [sys.executable, "scripts/roadmap.py", "--check"]))

    failed: list[str] = []
    print(f"ci: {len(gates)} gates\n")
    for gate in gates:
        ok, output, elapsed = gate.run()
        mark = "ok  " if ok else "FAIL"
        print(f"{mark} {gate.name:<32} {elapsed:6.1f}s")
        if not ok:
            failed.append(gate.name)
            if output:
                # More than the last few lines: a suite that fails once in ten runs
                # is only diagnosable if the reason survives the report.
                for line in tail(output, 20).splitlines():
                    print(f"     | {line}")
    if failed:
        print(f"\nci: {len(failed)} gate(s) failed: {', '.join(failed)}")
        return 1
    print(f"\nci: all {len(gates)} gates passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
