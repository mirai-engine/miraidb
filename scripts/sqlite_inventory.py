#!/usr/bin/env python3
"""Extracts the SQLite feature inventory from a SQLite source tree.

The generated document lists keywords, built-in functions and pragmas so the
port can be checked against the reference implementation instead of memory.

Usage:
    python3 scripts/sqlite_inventory.py [--sqlite DIR] [--out FILE]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

FUNC_PATTERN = re.compile(
    r"\b(?:FUNCTION|PURE_DATE|DFUNCTION|TEST_FUNC|MFUNCTION|WAGGREGATE|JFUNCTION|INLINE_FUNC|AGGR)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)"
)

PRAGMAS = """application_id auto_vacuum automatic_index busy_timeout cache_size
cache_spill case_sensitive_like cell_size_check checkpoint_fullfsync
collation_list compile_options count_changes data_store_directory
data_version database_list defer_foreign_keys encoding foreign_key_check
foreign_key_list foreign_keys freelist_count full_column_names
fullfsync function_list hard_heap_limit ignore_check_constraints
incremental_vacuum integrity_check journal_mode journal_size_limit
legacy_alter_table legacy_file_format locking_mode max_page_count
mmap_size module_list optimize page_count page_size pragma_list
query_only quick_check read_uncommitted recursive_triggers
reverse_unordered_selects schema_version secure_delete short_column_names
shrink_memory soft_heap_limit soft_heap_limit64 synchronous table_info
table_list table_xinfo temp_store temp_store_directory threads
trusted_schema user_version wal_autocheckpoint wal_checkpoint
writable_schema""".split()


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def keywords(source: str) -> list[str]:
    words: set[str] = set()
    for match in re.finditer(r"%token\s+([^\.\n]+)", source):
        for word in match.group(1).split():
            if word.isupper() and word.isalpha():
                words.add(word.lower())
    for match in re.finditer(r"%fallback\s+\w+\s*\n(.*?)(?=\n%|\Z)", source, re.S):
        for word in match.group(1).replace("\n", " ").split():
            if word.isupper() and word.isalpha():
                words.add(word.lower())
    return sorted(words)


def functions(sources: list[str]) -> list[str]:
    names: set[str] = set()
    for source in sources:
        for match in FUNC_PATTERN.finditer(source):
            names.add(match.group(1).lower())
    return sorted(names)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sqlite", default=os.path.join("..", "sqlite"))
    parser.add_argument("--out", default=os.path.join("docs", "sqlite-inventory.md"))
    args = parser.parse_args()

    src = os.path.join(args.sqlite, "src")
    if not os.path.isdir(src):
        print(f"sqlite source not found at {src}", file=sys.stderr)
        return 2
    version = read(os.path.join(args.sqlite, "VERSION")).strip()
    grammar = read(os.path.join(src, "parse.y"))
    c_files = [os.path.join(src, name) for name in sorted(os.listdir(src)) if name.endswith(".c")]
    noise = {
        "eq", "ne", "lt", "le", "gt", "ge", "isnot", "isnull", "notnull",
        "columnkw", "comment", "space", "illegal", "like_kw", "ctime_kw",
        "id", "uminus", "uplus", "bitnot", "truefalse", "fallback",
    }
    words = [word for word in keywords(grammar) if word not in noise]
    names = functions([read(path) for path in c_files])
    lines = []
    lines.append("# SQLite feature inventory")
    lines.append("")
    lines.append(f"Generated from SQLite **{version}** (`{args.sqlite}`) by `scripts/sqlite_inventory.py`.")
    lines.append("Do not edit by hand: run the script again.")
    lines.append("")
    lines.append(f"- Keywords: **{len(words)}**")
    lines.append(f"- Built-in function names: **{len(names)}**")
    lines.append(f"- Pragmas: **{len(PRAGMAS)}**")
    lines.append("")
    lines.append("## Keywords")
    lines.append("")
    lines.append(", ".join(f"`{word}`" for word in words))
    lines.append("")
    lines.append("## Built-in functions")
    lines.append("")
    lines.append(", ".join(f"`{name}`" for name in names))
    lines.append("")
    lines.append("## Pragmas")
    lines.append("")
    lines.append(", ".join(f"`{name}`" for name in sorted(PRAGMAS)))
    lines.append("")
    with open(args.out, "w", encoding="utf-8", newline="") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"wrote {args.out}: {len(words)} keywords, {len(names)} functions, {len(PRAGMAS)} pragmas")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
