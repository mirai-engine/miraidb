#!/usr/bin/env python3
"""Builds the CLI, the server, the shared libraries and runs the tests.

Only Odin code ships in the engine; this script is the single auxiliary helper,
kept in Python so the repository has no shell or make dependency.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = "bin"


def run(*args: str) -> None:
    print("+", " ".join(args))
    subprocess.run(args, cwd=ROOT, check=True)


def main() -> int:
    odin = os.environ.get("ODIN", "odin")
    if shutil.which(odin) is None:
        print(f"odin not found (looked for {odin!r}); set ODIN to its path", file=sys.stderr)
        return 2
    # The Odin binary decides the output extension: a Windows build wants .exe,
    # which also matters when Odin runs through WSL interop.
    suffix = ".exe" if os.name == "nt" or odin.lower().endswith(".exe") else ""
    os.makedirs(os.path.join(ROOT, BIN), exist_ok=True)
    run(odin, "build", "src/cli", f"-out:bin/miraidb{suffix}")
    run(odin, "build", "examples/todo", f"-out:bin/todo{suffix}")
    run(odin, "build", "src/server", f"-out:bin/miraidb-server{suffix}")
    # Shared libraries carry a fixed extension on every platform the consumers
    # expect, so a Windows build always produces .dll.
    library = ".dll" if odin.lower().endswith(".exe") or os.name == "nt" else ".so"
    run(odin, "build", "src/capi", "-build-mode:dll", f"-out:bin/miraidb{library}")
    run(odin, "build", "src/sqlite_compat", "-build-mode:dll", f"-out:bin/sqlite3_miraidb{library}")
    run(odin, "test", "src/tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
