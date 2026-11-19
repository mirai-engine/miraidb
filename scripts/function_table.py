#!/usr/bin/env python3
"""The function table the SQLite face checks a call against at prepare.

SQLite refuses at prepare a call to a function it does not have ("no such
function: f") and a call with a number of arguments the function does not take
("wrong number of arguments to function f()"). This script writes
src/engine/function_table.odin with what that check needs:

  * SQLITE_FUNCTION_ARITIES: every function SQLite 3.54.1 has (as built by
    scripts/sqlite_shell.py from ../sqlite), with the argument counts it takes,
    measured by preparing a call with 0 to 8 arguments against SQLite itself;
  * ENGINE_FUNCTION_NAMES: the names the engine's own dispatch knows (every
    `case "name"` of its function switches), so a function the engine adds is
    never refused for being unknown. Over-listing only makes the check miss an
    error; it never refuses a call that runs.

    python scripts/function_table.py            # write the file
    python scripts/function_table.py --check    # fail when it is out of date
"""

from __future__ import annotations

import argparse
import ctypes
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
OUT = os.path.join(ROOT, "src", "engine", "function_table.odin")
MAX_ARGS = 8


def sqlite_arities(library: str) -> dict[str, int]:
    """name -> bitmask of the counts 0..MAX_ARGS SQLite prepares; bit MAX_ARGS+1
    set when it takes any number beyond (read as MAX_ARGS working)."""
    lib = ctypes.CDLL(library)
    lib.sqlite3_initialize()
    lib.sqlite3_errmsg.restype = ctypes.c_char_p
    db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0

    def rows(sql: bytes) -> list[tuple]:
        stmt = ctypes.c_void_p()
        assert lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None) == 0
        lib.sqlite3_column_text.restype = ctypes.c_char_p
        out = []
        while lib.sqlite3_step(stmt) == 100:
            out.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
        lib.sqlite3_finalize(stmt)
        return out

    names = sorted({row[0].decode() for row in rows(b"SELECT name FROM pragma_function_list")})
    table: dict[str, int] = {}
    for name in names:
        mask = 0
        for count in range(MAX_ARGS + 1):
            args = ", ".join(["NULL"] * count)
            stmt = ctypes.c_void_p()
            sql = f"SELECT \"{name}\"({args})".encode()
            rc = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
            message = lib.sqlite3_errmsg(db).decode()
            if rc == 0:
                lib.sqlite3_finalize(stmt)
            if rc == 0 or not message.startswith("wrong number of arguments"):
                mask |= 1 << count
        table[name] = mask
    lib.sqlite3_close(db)
    return table


def engine_names() -> list[str]:
    names: set[str] = set()
    for path in glob.glob(os.path.join(ROOT, "src", "engine", "*.odin")):
        if path == OUT:
            continue
        text = open(path, encoding="utf-8").read()
        for match in re.finditer(r'^\s*case\s+((?:"[a-z_0-9]+"\s*,\s*)*"[a-z_0-9]+")\s*:', text, re.M):
            for name in re.findall(r'"([a-z_0-9]+)"', match.group(1)):
                names.add(name)
    return sorted(names)


def render(arities: dict[str, int], engine: list[str]) -> str:
    lines = [
        "package engine",
        "",
        "// Written by scripts/function_table.py; do not edit by hand.",
        "",
        "// SQLITE_FUNCTION_ARITIES are SQLite 3.54.1's functions, each with the",
        "// argument counts it takes as a bitmask (bit n: n arguments, for n up to",
        f"// {MAX_ARGS}; a function that takes {MAX_ARGS} takes any number beyond), sorted",
        "// by name.",
        "SQLITE_FUNCTION_ARITIES := [?]Sqlite_Function_Arity {",
    ]
    for name, mask in sorted(arities.items()):
        lines.append(f'\t{{"{name}", 0x{mask:03x}}},')
    lines.append("}")
    lines.append("")
    lines.append("// ENGINE_FUNCTION_NAMES are the names the engine's function switches know.")
    lines.append("ENGINE_FUNCTION_NAMES := []string {")
    row = "\t"
    for name in engine:
        item = f'"{name}", '
        if len(row) + len(item) > 100:
            lines.append(row.rstrip())
            row = "\t"
        row += item
    if row.strip():
        lines.append(row.rstrip())
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def current_arities() -> dict[str, int]:
    """The SQLite part of the file as it stands, for --check without a build."""
    if not os.path.exists(OUT):
        return {}
    text = open(OUT, encoding="utf-8").read()
    return {name: int(mask, 16) for name, mask in re.findall(r'^\t\{"([^"]+)", 0x([0-9a-f]+)\},$', text, re.M)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        arities = current_arities()
        if not arities:
            print("function table: src/engine/function_table.odin is missing")
            return 1
        wanted = render(arities, engine_names())
        if open(OUT, encoding="utf-8").read() != wanted:
            print("function table: out of date; run python scripts/function_table.py")
            return 1
        print(f"function table: {len(arities)} SQLite functions, {len(engine_names())} engine names, current")
        return 0
    import sqlite_shell

    source = os.path.abspath(sqlite_shell.default_source())
    missing = sqlite_shell.missing_tools(source)
    if missing:
        print(f"function table: cannot build SQLite, missing {', '.join(missing)}")
        return 1
    library = sqlite_shell.build_reference(source)[1]
    text = render(sqlite_arities(library), engine_names())
    with open(OUT, "w", encoding="utf-8", newline="\n") as out:
        out.write(text)
    print(f"function table: wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
