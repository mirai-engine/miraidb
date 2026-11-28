#!/usr/bin/env python3
"""Counts the consumers of a commit that recompute what it changed (A3).

A commit publishes the list of its changes (`Store_Op`, `on_commit`, the
mirror's flush). A consumer that reads the whole table, re-runs a query or
reloads a table to learn what changed pays for the table where the commit paid
for the rows it wrote. Each place that does is listed below, by the procedure
it lives in and the call that does the recomputing; this script counts the
calls in each.

The total has a baseline. A count over it fails: something new recomputes a
commit. A count under it fails too, until the baseline is lowered to it, so the
gain is held. A3 takes the subscriptions and the event reader off the list;
the mirror and the shared file are A4's.

    python3 scripts/change_consumers.py          # check against the baseline
    python3 scripts/change_consumers.py --list   # print every place counted
"""

from __future__ import annotations

import os
import re
import sys

ENGINE = "src/engine"

# (file, procedure, call, what it recomputes)
SITES = [
    ("sqlite_mirror.odin", "mirror_rebuild_indexes", r"\btable_collect\(",
     "the mirror rebuilds every index of a table it touched from all its rows"),
    ("host.odin", "host_on_commit", r"\bhost_evaluate\(",
     "a subscription runs its query again and compares the results"),
    ("host.odin", "host_agg_recompute", r"\bhost_agg_group_sources\(",
     "an aggregate subscription reads the rows of a group whose running values"
     " cannot follow a commit (a REAL in a sum, the extreme of min or max leaving)"),
    ("sqlite_share.odin", "sqlite_share_catch_up", r"\btx_truncate\(",
     "a file another process wrote is reloaded table by table"),
]
BASELINE = 4


def body(path: str, proc: str) -> str:
    with open(path, encoding="utf-8") as handle:
        text = handle.read().replace("\r\n", "\n")
    start = re.search(rf"^{re.escape(proc)} :: proc", text, re.MULTILINE)
    if start is None:
        return ""
    end = text.find("\n}\n", start.start())
    code = text[start.start(): end if end >= 0 else len(text)]
    # A comment names calls in prose; only code counts.
    return "\n".join(line.split("//", 1)[0] for line in code.split("\n"))


def count(engine: str = ENGINE):
    found = []
    for name, proc, call, what in SITES:
        path = os.path.join(engine, name)
        code = body(path, proc)
        if not code:
            print(f"change consumers: {name} has no procedure {proc}; update SITES in {__file__}")
            found.append((name, proc, what, -1))
            continue
        found.append((name, proc, what, len(re.findall(call, code))))
    return found


def main() -> int:
    found = count()
    if any(n < 0 for *_, n in found):
        return 1
    total = sum(n for *_, n in found)
    if "--list" in sys.argv:
        for name, proc, what, n in found:
            print(f"  {n}  {name}:{proc}: {what}")
        print(f"== {total}")
        return 0
    if total > BASELINE:
        print(f"change consumers: {total} places recompute a commit's changes, baseline {BASELINE}")
        for name, proc, what, n in found:
            if n:
                print(f"  {n}  {name}:{proc}: {what}")
        return 1
    if total < BASELINE:
        print(f"change consumers: {total}, under the baseline {BASELINE}: lower BASELINE in {__file__}")
        return 1
    print(f"change consumers: {total} places recompute a commit's changes (baseline {BASELINE})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
