#!/usr/bin/env python3
"""Assemble the files someone needs to use the engine without the repository.

The package is deliberately plain: two programs, the shared library, the C
header, the Python binding, the licence and notice files, the version, and a
pkg-config file. No build system, no generated code, nothing that has to be kept
in sync beyond the version string the library itself reports.

    python scripts/package.py             # write dist/miraidb-<version>-<target>.zip
    python scripts/package.py --check     # build and verify the manifest
    python scripts/package.py --target linux-x86_64

The version is read from the string `miraidb_version` returns, so the archive can
never disagree with the library it carries.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")

VERSION_SOURCE = os.path.join(ROOT, "src", "capi", "capi.odin")


def version() -> str:
    text = open(VERSION_SOURCE, encoding="utf-8").read()
    match = re.search(r'miraidb ([0-9][0-9.]*)', text)
    if not match:
        raise SystemExit(f"cannot read the version from {VERSION_SOURCE}")
    return match.group(1)


def default_target() -> str:
    # The build directory decides: a Windows build produces .exe files, and the
    # packaging script may itself run under WSL or another host.
    if os.path.exists(os.path.join(ROOT, "bin", "miraidb.exe")):
        return "windows-x86_64"
    system = platform.system().lower()
    if system == "darwin":
        return "darwin-arm64" if platform.machine() in ("arm64", "aarch64") else "darwin-x86_64"
    return f"{system}-{platform.machine().lower()}"


def binary(name: str, target: str) -> str:
    """The built binary, with the extension the target uses."""
    suffix = ".exe" if target.startswith("windows") else ""
    path = os.path.join(ROOT, "bin", name + suffix)
    if not os.path.exists(path):
        raise SystemExit(f"missing {path}; run scripts/build.py first")
    return path


def pkg_config(version: str) -> str:
    return f"""prefix=/usr/local
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: miraidb
Description: Embedded database with an append-only log and a C ABI
Version: {version}
Libs: -L${{libdir}} -lmiraidb
Cflags: -I${{includedir}}
"""


def build(target: str, check: bool) -> int:
    current = version()
    name = f"miraidb-{current}-{target}"
    stage = os.path.join(DIST, name)
    archive = os.path.join(DIST, name + ".zip")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage, exist_ok=True)
    os.makedirs(os.path.join(stage, "bin"), exist_ok=True)
    os.makedirs(os.path.join(stage, "include"), exist_ok=True)
    os.makedirs(os.path.join(stage, "sdk", "python"), exist_ok=True)

    copies = [
        (binary("miraidb", target), os.path.join("bin", os.path.basename(binary("miraidb", target)))),
        (binary("miraidb-server", target), os.path.join("bin", os.path.basename(binary("miraidb-server", target)))),
        (
            os.path.join(ROOT, "bin", "miraidb.dll" if target.startswith("windows") else "libmiraidb.so"),
            os.path.join("lib", "miraidb.dll" if target.startswith("windows") else "libmiraidb.so"),
        ),
        (os.path.join(ROOT, "include", "miraidb.h"), os.path.join("include", "miraidb.h")),
        (os.path.join(ROOT, "sdk", "python", "miraidb.py"), os.path.join("sdk", "python", "miraidb.py")),
        (os.path.join(ROOT, "README.md"), "README.md"),
        (os.path.join(ROOT, "LICENSE-MIT"), "LICENSE-MIT"),
        (os.path.join(ROOT, "LICENSE-APACHE"), "LICENSE-APACHE"),
        (os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"), "THIRD_PARTY_NOTICES.md"),
        (os.path.join(ROOT, "CHANGELOG.md"), "CHANGELOG.md"),
    ]
    for source, relative in copies:
        if not os.path.exists(source):
            raise SystemExit(f"missing {source}")
        destination = os.path.join(stage, relative)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copy2(source, destination)

    with open(os.path.join(stage, "miraidb.pc"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(pkg_config(current))
    with open(os.path.join(stage, "VERSION"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(current + "\n")

    if os.path.exists(archive):
        os.remove(archive)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for base, _, files in os.walk(stage):
            for file in sorted(files):
                full = os.path.join(base, file)
                bundle.write(full, os.path.relpath(full, stage))

    expected = [
        "bin/" + os.path.basename(binary("miraidb", target)),
        "bin/" + os.path.basename(binary("miraidb-server", target)),
        "include/miraidb.h",
        "sdk/python/miraidb.py",
        "miraidb.pc",
        "VERSION",
        "CHANGELOG.md",
        "README.md",
        "LICENSE-MIT",
        "LICENSE-APACHE",
        "THIRD_PARTY_NOTICES.md",
    ]
    with zipfile.ZipFile(archive) as bundle:
        names = set(bundle.namelist())
    missing = [entry for entry in expected if entry not in names]
    if missing:
        print(f"package: the archive is missing {', '.join(missing)}", file=sys.stderr)
        return 1
    size = os.path.getsize(archive)
    print(f"{os.path.relpath(archive, ROOT)}  ({size // 1024} KiB, {len(names)} files)")
    for entry in sorted(names):
        print(f"  {entry}")
    if check:
        readme = open(os.path.join(stage, "VERSION"), encoding="utf-8").read().strip()
        if readme != current:
            print("package: VERSION and the library disagree", file=sys.stderr)
            return 1
        print("package: manifest ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default=default_target())
    parser.add_argument("--check", action="store_true", help="verify the archive manifest")
    args = parser.parse_args()
    return build(args.target, args.check)


if __name__ == "__main__":
    sys.exit(main())
