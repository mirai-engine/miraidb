#!/usr/bin/env python3
"""Run every gate in one command: build, tests, conformance, smokes, vet, docs.

    python3 scripts/ci.py
    python3 scripts/ci.py --skip-dll          # no Windows Python available
    python3 scripts/ci.py --odin /path/to/odin --windows-python /path/to/python.exe
    python3 scripts/ci.py --linux-odin /opt/odin/odin   # under WSL: the Linux gates too
    python3 scripts/ci.py --list              # print the gate names and exit

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

from binpath import binary_path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The compiler comes from $ODIN, then from PATH. Pass --odin when neither finds
# it, so nothing here depends on one machine's layout.
DEFAULT_ODIN = os.environ.get("ODIN") or shutil.which("odin") or "odin"
# A Windows binary cannot be driven by a WSL Python: set MIRAIDB_WINDOWS_PYTHON
# (or --windows-python) to the interpreter that can load the DLL. Without it the
# DLL smokes are skipped with a message.
DEFAULT_WINDOWS_PYTHON = os.environ.get("MIRAIDB_WINDOWS_PYTHON", "")
# A run under WSL can also build for Linux: set MIRAIDB_LINUX_ODIN (or
# --linux-odin) to a Linux Odin compiler and the suite and the cross-process
# gate run on Linux too (scripts/linux_gates.py). Without it they are skipped.
DEFAULT_LINUX_ODIN = os.environ.get("MIRAIDB_LINUX_ODIN", "")
# A gate that runs longer than this is stopped and fails: a hang (a test that
# spins under a lock) used to keep the whole run waiting with no report.
GATE_TIMEOUT_SECONDS = 1800
# What Python prints when the system would not start a program at all (ENOEXEC).
REFUSED_LAUNCH = "[Errno 8] Exec format error"
PACKAGES = ["src/engine", "src/cli", "src/capi", "src/sqlite_compat", "src/server", "src/tests"]


class Gate:
    def __init__(
        self,
        name: str,
        command: list[str],
        env: dict[str, str] | None = None,
        refuse: tuple[str, ...] = (),
        timeout: float = GATE_TIMEOUT_SECONDS,
    ):
        self.name = name
        self.command = command
        self.env = env or {}
        # Lines the output must not hold even when the command exits 0: the
        # test runner reports a bad free or a leak and still passes the test.
        self.refuse = refuse
        self.timeout = timeout

    def run(self) -> tuple[bool, str, float]:
        started = time.time()
        environment = {**os.environ, **self.env}
        try:
            done = subprocess.run(
                self.command,
                cwd=ROOT,
                capture_output=True,
                text=True,
                env=environment,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired as expired:
            elapsed = time.time() - started
            partial = expired.stdout or ""
            if isinstance(partial, bytes):
                partial = partial.decode(errors="replace")
            report = [partial.strip(), f"stopped after {self.timeout:.0f}s: the gate hung"]
            return False, "\n".join(line for line in report if line), elapsed
        except OSError as error:
            # The gate's own program did not start (main() runs it again when
            # the system refused it); the rest of the gates still run.
            return False, f"could not start {self.command[0]}: {error}", time.time() - started
        elapsed = time.time() - started
        output = (done.stdout + done.stderr).strip()
        refused = [line for line in output.splitlines() if any(word in line for word in self.refuse)]
        if refused:
            report = [*refused[:10], f"{len(refused)} line(s) hold one of {self.refuse!r}"]
            return False, "\n".join(report), elapsed
        return done.returncode == 0, output, elapsed


def tail(text: str, lines: int = 6) -> str:
    return "\n".join(text.splitlines()[-lines:])


def build_gates(args: argparse.Namespace) -> list[Gate]:
    """The gates, in the order they run. `--list` prints them; docs_check.py counts them."""
    odin_env = {"ODIN": args.odin}
    # The CLI's name follows the compiler, as scripts/build.py writes it.
    cli = binary_path("miraidb", args.odin)
    gates: list[Gate] = []
    if not args.skip_build:
        # The suite is the next gate; the build does not run it a second time.
        gates.append(Gate("build (binaries)", [sys.executable, "scripts/build.py", "--no-tests"], odin_env))
    gates.append(Gate("unit tests", [args.odin, "test", "src/tests"], refuse=("+++ bad free", "+++ leak"), timeout=900))
    gates.append(
        Gate("conformance (20 cases)", [sys.executable, "scripts/conformance.py", "--bin", cli])
    )
    gates.append(Gate("shell smoke", [sys.executable, "scripts/shell_smoke.py"]))
    gates.append(Gate("performance baseline", [sys.executable, "scripts/bench.py", "--check"]))
    gates.append(Gate("package manifest", [sys.executable, "scripts/package.py", "--check"]))
    gates.append(
        Gate("page memory", [sys.executable, "scripts/page_rss.py", "--check", "--bin", cli])
    )
    gates.append(
        Gate("plan regression", [sys.executable, "scripts/plan_check.py", "--bin", cli])
    )
    gates.append(
        Gate("differential vs sqlite3", [sys.executable, "scripts/differential.py", "--bin", cli])
    )
    # The compatibility matrix is a table this runs: a claim in docs/sqlite.md that
    # stops being true fails here, which is what keeps the document honest (D26).
    gates.append(
        Gate(
            "documented compatibility",
            [sys.executable, "scripts/compat_check.py", "--bin", cli],
        )
    )
    # How much of SQLite's function, pragma and grammar surface answers; the
    # counts docs/sqlite-roadmap.md states have to be the measured ones.
    gates.append(
        Gate("SQLite surface", [sys.executable, "scripts/sqlite_gaps.py", "--check", "--bin", cli])
    )
    # The CLI under AddressSanitizer with the Windows heap hooked: a use-after-free
    # of heap memory is invisible to it otherwise, and one shipped that way.
    gates.append(Gate("heap sanitizer", [sys.executable, "scripts/asan_smoke.py", "--odin", args.odin]))
    gates.append(
        Gate(
            "mirror cost",
            [
                sys.executable,
                "scripts/mirror_cost.py",
                "--check",
                "--rows",
                "10000",
                "--text",
                "200",
            ],
        )
    )
    if not args.skip_dll:
        # --list enumerates every gate, even when this machine cannot run the DLL
        # smokes, so the count docs_check.py compares against does not depend on
        # where it runs.
        if args.list or os.path.exists(args.windows_python):
            gates.append(Gate("C ABI smoke", [args.windows_python, "scripts/capi_smoke.py"]))
            gates.append(
                Gate("sqlite3_* smoke", [args.windows_python, "scripts/sqlite_abi_smoke.py"])
            )
            # Python's own sqlite3 module, linked against the facade, runs
            # CPython's tests of it: each that passes with SQLite has to pass.
            gates.append(
                Gate("Python's sqlite3 suite", [args.windows_python, "scripts/python_sqlite3.py"])
            )
            # Two processes on one SQLite file, through the facade and through
            # SQLite itself: SQLite's locks and change counter, across processes.
            gates.append(
                Gate("SQLite file across processes", [args.windows_python, "scripts/sqlite_processes.py"])
            )
            # SQLite's own command-line shell, built against SQLite and against
            # the facade: the same cases give the same output.
            gates.append(
                Gate("SQLite's shell on the facade", [args.windows_python, "scripts/sqlite_shell.py"])
            )
            # SQLite's sqldiff, dbhash and mptest, built against SQLite and
            # against the facade: the same output, the same file content, and
            # every multi-process check passing.
            gates.append(
                Gate("SQLite's tools on the facade", [args.windows_python, "scripts/sqlite_tools.py"])
            )
            # Random DDL and DML through the facade and through SQLite, with
            # SQLite's integrity_check on the facade's file after each chunk
            # and the same rows on both: twenty fixed seeds (D24).
            gates.append(
                Gate(
                    "mirror fuzz",
                    [args.windows_python, "scripts/mirror_fuzz.py", "--seeds", "20", "--statements", "400"],
                    timeout=1800,
                )
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
            # Who a client is, on HTTP, WebSocket and PostgreSQL: a server with
            # credentials refuses one that does not prove it, and no client reaches
            # the key that signs tokens or the grants.
            gates.append(
                Gate("auth (three fronts)", [args.windows_python, "scripts/auth_smoke.py"])
            )
            # COPY moves rows through the wire's own messages; the gate speaks
            # them, so it needs no driver installed.
            gates.append(
                Gate("COPY over the wire", [args.windows_python, "scripts/pg_copy_smoke.py"])
            )
            # LISTEN and NOTIFY need two connections: one hears what the other
            # says, and the server pushes it without being asked.
            gates.append(
                Gate("LISTEN/NOTIFY over the wire", [args.windows_python, "scripts/pg_notify_smoke.py"])
            )
        else:
            print(f"ci: no Windows Python at {args.windows_python}; skipping the DLL smokes")
    if args.list or (args.linux_odin and sys.platform.startswith("linux")):
        # The suite on Linux, where the locks are POSIX's and the allocator
        # another; and two processes on one SQLite file through the Linux
        # facade and Linux's own SQLite.
        gates.append(
            Gate(
                "unit tests (Linux)",
                [sys.executable, "scripts/linux_gates.py", "tests", "--odin", args.linux_odin],
                timeout=900,
            )
        )
        gates.append(
            Gate(
                "SQLite file across processes (Linux)",
                [sys.executable, "scripts/linux_gates.py", "processes", "--odin", args.linux_odin],
            )
        )
    elif args.linux_odin:
        print("ci: --linux-odin needs a Linux Python (run under WSL); skipping the Linux gates")
    for package in PACKAGES:
        gates.append(
            Gate(f"vet {package}", [args.odin, "check", package, "-no-entry-point", "-vet"])
        )
    gates.append(
        Gate(
            "leak budgets",
            [sys.executable, "scripts/leaks.py", "--odin", args.odin, "--repeat", "1000"],
        )
    )
    # The parity workloads may not get slower than the baseline this machine
    # recorded (benchmarks/parity/baseline.json): a gain R1-R4 makes is recorded
    # and held. A workload that reached the reference is held under 1.10x of it;
    # the self-test checks those rules on made-up numbers.
    gates.append(Gate("parity rules", [sys.executable, "scripts/parity.py", "--self-test"]))
    gates.append(Gate("parity budget", [sys.executable, "scripts/parity.py", "--odin", args.odin]))
    # A library with symbols and no header is not an API: this compares each
    # header with what its package exports, and compiles both on their own.
    gates.append(Gate("ABI headers", [sys.executable, "scripts/abi_header.py"]))
    # The SQLite face checks a call against SQLite's functions at prepare; the
    # table it reads lists the engine's own names too, and goes stale with them.
    gates.append(Gate("function table", [sys.executable, "scripts/function_table.py", "--check"]))
    gates.append(Gate("documentation consistency", [sys.executable, "scripts/docs_check.py"]))
    gates.append(Gate("roadmap is consistent", [sys.executable, "scripts/roadmap.py", "--check"]))
    return gates


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--odin", default=os.environ.get("ODIN", DEFAULT_ODIN))
    parser.add_argument("--windows-python", default=DEFAULT_WINDOWS_PYTHON)
    parser.add_argument("--linux-odin", default=DEFAULT_LINUX_ODIN, help="a Linux Odin for the Linux gates")
    parser.add_argument("--skip-dll", action="store_true", help="skip the DLL smokes")
    parser.add_argument("--skip-build", action="store_true", help="reuse the existing binaries")
    parser.add_argument("--list", action="store_true", help="print the gate names and exit")
    args = parser.parse_args()

    if args.list:
        for gate in build_gates(args):
            print(gate.name)
        return 0
    if not os.path.exists(args.odin):
        print(f"ci: odin not found at {args.odin}; pass --odin", file=sys.stderr)
        return 2

    gates = build_gates(args)
    failed: list[str] = []
    print(f"ci: {len(gates)} gates\n")
    for gate in gates:
        ok, output, elapsed = gate.run()
        if not ok and REFUSED_LAUNCH in output:
            # Under WSL a Windows program starts through the handler WSL
            # registers for them, which something on the machine clears now and
            # then (another distribution's shutdown does) until it is registered
            # again; a gate that starts one in that gap fails with ENOEXEC
            # before the program ran, so it proved nothing either way. It runs
            # once more after a pause, and a failure of the code fails again.
            print(f"     {gate.name}: a launch was refused (Exec format error); running it again")
            time.sleep(5)
            ok, output, again = gate.run()
            elapsed += again
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
