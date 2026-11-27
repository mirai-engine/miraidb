#!/usr/bin/env python3
"""Counts what reaches into an index from outside its module (A2.1).

An index is one structure behind a contract (docs/architecture.md, A2): the
memory tree, the integer accelerator, the equality map and the pages are its
own business. Two things are counted in the engine's files outside the
index's module:

- fields: a structure field of `Index` (`tree`, `pages`, `lookup`, `ints`,
  `int_keyed`) read or written, on `indexes[...]` or on a name bound to an
  element of `.indexes` in the same file, table.odin included;
- table indexes: `.indexes[...]` on a table, which is a `[]Index`. The
  `indexes` of a `Table_Schema` and of the other catalog records are
  `[]Index_Schema`, metadata, and do not count; neither do `schema` and
  `unique`, read through an `Index`, for the same reason.

Each count has a baseline below. A count over its baseline fails: something
new reaches into an index. A count under it fails too, until the baseline is
lowered to it, so the gain is held.

    python3 scripts/index_boundary.py            # check against the baselines
    python3 scripts/index_boundary.py --list     # print every place counted
"""

from __future__ import annotations

import os
import re
import sys

ENGINE = "src/engine"
# The index's module: index.odin (Index and its procedures), index_btree.odin,
# index_page.odin, every other index*.odin, and int_keys.odin. table.odin keeps
# the rows and reaches the index through index.odin's procedures.
MODULE = {"int_keys.odin"}
BASELINE = {"fields": 0, "table indexes": 0}

FIELDS = r"(?:tree|pages|lookup|ints|int_keyed)"
# A name bound to an element of `.indexes`: `for index in t.indexes`,
# `for &index in ...`, `candidate := &table.indexes[i]`.
BIND_RE = re.compile(
    r"for\s+&?(\w+)(?:\s*,\s*\w+)?\s+in\s+[\w.]*\bindexes\b"
    r"|(\w+)\s*:=\s*&?[\w.]*\bindexes\s*\["
)
INDEXED_FIELD_RE = re.compile(r"\bindexes\s*\[[^\]]*\]\s*\.\s*" + FIELDS + r"\b")
TABLE_INDEXES_RE = re.compile(r"(\w+)\s*\.\s*indexes\s*\[")
# Receivers whose `indexes` are `[]Index_Schema`: a schema, and the catalog
# records the SQLite file code and the schema copy keep.
SCHEMA_RECEIVERS = re.compile(r"schema|^entry$|^ctx$|^out$|^normalized$|^original$")


def code_lines(path: str):
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            # A comment names fields in prose; only code counts.
            cut = line.find("//")
            yield number, line if cut < 0 else line[:cut]


def count(engine: str = ENGINE):
    found = {"fields": [], "table indexes": []}
    for name in sorted(os.listdir(engine)):
        if not name.endswith(".odin") or name in MODULE or name.startswith("index"):
            continue
        path = os.path.join(engine, name)
        lines = list(code_lines(path))
        bound = set()
        for _, line in lines:
            for match in BIND_RE.finditer(line):
                bound.add(match.group(1) or match.group(2))
        bound_re = (
            re.compile(r"(?<![\w.])(?:" + "|".join(sorted(map(re.escape, bound))) + r")\s*\.\s*" + FIELDS + r"\b")
            if bound
            else None
        )
        for number, line in lines:
            where = f"{path}:{number}: {line.strip()}"
            hits = len(INDEXED_FIELD_RE.findall(line))
            if bound_re is not None:
                hits += len(bound_re.findall(line))
            found["fields"].extend([where] * hits)
            for match in TABLE_INDEXES_RE.finditer(line):
                if SCHEMA_RECEIVERS.search(match.group(1)):
                    continue
                found["table indexes"].append(where)
    return found


def main() -> int:
    found = count()
    if "--list" in sys.argv:
        for what, places in found.items():
            print(f"== {what}: {len(places)}")
            for place in places:
                print("  " + place)
        return 0
    failed = False
    for what, places in found.items():
        base = BASELINE[what]
        have = len(places)
        if have > base:
            print(f"index boundary: {have} {what} outside the index's module, baseline {base}")
            for place in places:
                print("  " + place)
            failed = True
        elif have < base:
            print(f"index boundary: {have} {what}, under the baseline {base}: lower BASELINE in {__file__}")
            failed = True
        else:
            print(f"index boundary: {what} {have} (baseline {base})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
