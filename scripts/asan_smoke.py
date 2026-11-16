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
BINARY = os.path.join(ROOT, "bin", "miraidb-asan" + (".exe" if os.name == "nt" else ""))

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

    built = subprocess.run(
        [args.odin, "build", "src/cli", "-debug", "-sanitize:address", f"-out:{BINARY}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if built.returncode != 0:
        print("asan_smoke: build failed\n" + built.stdout + built.stderr)
        return 1

    env = dict(os.environ)
    env["ASAN_OPTIONS"] = "windows_hook_rtl_allocators=true:halt_on_error=1"
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    database = os.path.join(WORK, "db")
    statements = differential.SETUP + [q if isinstance(q, str) else q[0] for q in differential.QUERIES] + EXTRA
    reports = []
    for statement in statements:
        done = subprocess.run(
            [BINARY, "sql", database, statement], cwd=ROOT, env=env,
            capture_output=True, encoding="utf-8", errors="replace",
        )
        if "AddressSanitizer" in done.stderr:
            reports.append(f"{statement}\n{done.stderr[:4000]}")
    for command in (["check", database], ["compact", database], ["check", database]):
        done = subprocess.run(
            [BINARY, *command], cwd=ROOT, env=env, capture_output=True, encoding="utf-8", errors="replace",
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
