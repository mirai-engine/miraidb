"""Where a built binary lives, on every platform the scripts run on.

`scripts/build.py` lets the compiler decide the extension: `odin.exe` (on Windows,
or through WSL interop) writes `bin/miraidb.exe`, a Linux or macOS `odin` writes
`bin/miraidb`. A script that hardcodes one of the two finds nothing on the other,
so every default path is resolved here.
"""

from __future__ import annotations

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def executable_suffix(odin: str = "") -> str:
    """The extension the given compiler gives an executable, as build.py decides it."""
    if os.name == "nt" or os.path.basename(odin).lower().endswith(".exe"):
        return ".exe"
    return ""


def binary_path(name: str, odin: str = "") -> str:
    """The absolute path of `bin/<name>`.

    With a compiler, the path follows it, like the build does. Without one, the
    binary that exists wins: a native build first, then a Windows one, so a WSL
    shell driving a Windows build still finds it. When neither exists the native
    name is returned, and the caller's own "missing binary" message names it.
    """
    base = os.path.join(ROOT, "bin", name)
    if odin:
        return base + executable_suffix(odin)
    native = base + (".exe" if os.name == "nt" else "")
    if os.path.exists(native):
        return native
    if os.path.exists(base + ".exe"):
        return base + ".exe"
    return native
