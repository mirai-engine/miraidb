#!/usr/bin/env python3
"""Runs the CLI under AddressSanitizer with the Windows heap intercepted.

Odin's heap allocator calls HeapAlloc/HeapFree, which AddressSanitizer does not
watch on Windows by default, so a use-after-free of heap memory went unseen:
`tx_commit` cleared a flag through a transaction `tx_discard` had already freed,
and the only symptom was a process that died about once in ten commits with no
message. `ASAN_OPTIONS=windows_hook_rtl_allocators=true` makes the sanitizer hook
the heap, and that bug is reported on the first run.

This gate builds the CLI with `-sanitize:address`, replays the differential
corpus (its setup, then every query) plus writes, a reopen and a compaction,
one process per statement as the CLI is used, and fails on any report.

    python scripts/asan_smoke.py
"""

import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import differential  # noqa: E402  (the corpus lives there)

WORK = os.path.join(ROOT, "_asan_smoke")


def windows_path(path: str) -> str:
    """A Windows binary cannot open /mnt/c/...; it wants C:/..."""
    if path.startswith("/mnt/") and len(path) > 7 and path[6] == "/":
        return f"{path[5].upper()}:/{path[7:]}"
    return path


def build_paths(odin: str) -> tuple[str, str]:
    """Where the sanitized CLI lands, and the `-out:` to ask for.

    A Windows compiler run from another system (WSL, git-bash) still produces a
    Windows executable, so both follow the compiler rather than the host: with
    `odin` from PATH on Linux the answer is an ELF file and the path as it is,
    and with odin.exe it is `miraidb-asan.exe` and a Windows path.
    """
    windows = os.name == "nt" or os.path.basename(odin).lower().startswith("odin.exe")
    binary = os.path.join(ROOT, "bin", "miraidb-asan" + (".exe" if windows else ""))
    return binary, windows_path(binary) if windows else binary

EXTRA = [
    "UPDATE nums SET m = m * 2 WHERE n = 1",
    "DELETE FROM emp WHERE id = 6",
    "INSERT INTO kv (k, v) VALUES ('c', 3) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
    "CREATE INDEX by_dept ON emp (dept)",
    "BEGIN; INSERT INTO dept (id, name) VALUES (9, 'x'); ROLLBACK",
    "SELECT dept, count(*) FROM emp GROUP BY dept ORDER BY dept",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    args = parser.parse_args()
    binary, output = build_paths(args.odin)

    built = subprocess.run(
        [args.odin, "build", "src/cli", "-debug", "-sanitize:address", f"-out:{output}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if built.returncode != 0:
        print("asan_smoke: build failed\n" + built.stdout + built.stderr)
        return 1
    if not os.path.exists(binary):
        print(f"asan_smoke: the build left no binary at {binary}")
        return 1

    env = dict(os.environ)
    env["ASAN_OPTIONS"] = "windows_hook_rtl_allocators=true:halt_on_error=1"
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    database = os.path.join(WORK, "db")
    if binary.endswith(".exe"):
        database = windows_path(database)

    # A binary that cannot start reports nothing that looks like a sanitizer
    # finding, so the run would pass while proving nothing: this one statement
    # has to answer.
    smoke = subprocess.run(
        [binary, "sql", database, "SELECT 1 AS one", "--json"], cwd=ROOT, env=env,
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if smoke.returncode != 0 or "1" not in smoke.stdout:
        print(f"asan_smoke: the sanitized CLI did not run\n{smoke.stdout}{smoke.stderr}"[:4000])
        return 1
    statements = differential.SETUP + [q if isinstance(q, str) else q[0] for q in differential.QUERIES] + EXTRA
    reports = []
    for statement in statements:
        done = subprocess.run(
            [binary, "sql", database, statement], cwd=ROOT, env=env,
            capture_output=True, encoding="utf-8", errors="replace",
        )
        if "AddressSanitizer" in done.stderr:
            reports.append(f"{statement}\n{done.stderr[:4000]}")
    for command in (["check", database], ["compact", database], ["check", database]):
        done = subprocess.run(
            [binary, *command], cwd=ROOT, env=env, capture_output=True, encoding="utf-8", errors="replace",
        )
        if "AddressSanitizer" in done.stderr:
            reports.append(f"{' '.join(command)}\n{done.stderr[:4000]}")
    shutil.rmtree(WORK, ignore_errors=True)

    if reports:
        print(f"asan_smoke: {len(reports)} report(s); the first:\n{reports[0]}")
        return 1
    print(f"asan_smoke: {len(statements) + 3} commands under AddressSanitizer, no report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
