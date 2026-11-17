#!/usr/bin/env python3
"""Measures how much of SQLite's surface this engine answers.

Every built-in function and pragma named in docs/sqlite-inventory.md, and a
list of statements that exercise the grammar, is run through the CLI on an
in-memory database. A function counts as present when the engine does not
answer "unknown function"; a pragma when it does not answer "unknown pragma";
a statement when it runs. The result is printed as Markdown for
docs/sqlite-roadmap.md, and `--check` fails when the counts that document
states are not the counts measured now: a regression fails, and so does a
feature that landed without the document saying so.

    python scripts/sqlite_gaps.py              # print the report
    python scripts/sqlite_gaps.py --missing    # only what is missing
    python scripts/sqlite_gaps.py --check      # CI: the document matches
"""

import argparse
import os
import re
import subprocess
import sys

from binpath import binary_path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROADMAP = os.path.join(ROOT, "docs", "sqlite-roadmap.md")
# The sentence in the roadmap that carries the counts --check compares.
CLAIM = re.compile(r"functions \*\*(\d+) / (\d+)\*\*, pragmas \*\*(\d+) / (\d+)\*\*, grammar \*\*(\d+) / (\d+)\*\*")

# Functions SQLite only builds for its own tests or debugging; not surface a
# user calls, so they are not counted.
INTERNAL = {
    "datedebug", "expr_compare", "expr_implies_expr", "fpdecode",
    "implies_nonnull_row", "oom", "parseuri", "sqlite_filestat",
    "sqlite_walstat", "unknown",
}

# Statements per grammar feature. A feature is present when every statement
# of its list runs (they share one database, in order).
GRAMMAR = [
    ("CTE and WITH RECURSIVE", ["WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<3) SELECT x FROM c"]),
    ("SAVEPOINT / RELEASE", ["BEGIN", "SAVEPOINT a", "RELEASE a", "COMMIT"]),
    ("UPSERT with excluded", ["CREATE TABLE u(id INTEGER PRIMARY KEY, v INT)", "INSERT INTO u VALUES (1,1) ON CONFLICT(id) DO UPDATE SET v = excluded.v"]),
    ("INSERT OR IGNORE", ["CREATE TABLE oi(id INTEGER PRIMARY KEY)", "INSERT OR IGNORE INTO oi VALUES (1)"]),
    ("UPDATE ... FROM", ["CREATE TABLE f1(id INT, v INT)", "CREATE TABLE f2(id INT, v INT)", "UPDATE f1 SET v = f2.v FROM f2 WHERE f1.id = f2.id"]),
    ("RETURNING", ["CREATE TABLE r(id INTEGER PRIMARY KEY, v INT)", "INSERT INTO r(v) VALUES (1) RETURNING id"]),
    ("Window functions", ["SELECT row_number() OVER (ORDER BY 1)"]),
    ("Window FILTER", ["SELECT count(*) FILTER (WHERE 1) OVER ()"]),
    ("Named WINDOW clause", ["CREATE TABLE w(x INT)", "SELECT sum(x) OVER win FROM w WINDOW win AS (ORDER BY x)"]),
    ("Aggregate ORDER BY", ["CREATE TABLE ao(x TEXT)", "SELECT group_concat(x ORDER BY x) FROM ao"]),
    ("NULLS FIRST / LAST", ["CREATE TABLE n(x INT)", "SELECT x FROM n ORDER BY x NULLS LAST"]),
    ("IS / IS NOT a value", ["SELECT 1 IS 1, 1 IS NOT 2"]),
    ("IS DISTINCT FROM", ["SELECT 1 IS DISTINCT FROM 2"]),
    ("Row values", ["SELECT (1,2) = (1,2)"]),
    ("Bitwise operators", ["SELECT 6 & 3, 6 | 3, ~6, 1 << 2, 8 >> 1"]),
    ("COLLATE NOCASE", ["SELECT 'a' = 'A' COLLATE NOCASE"]),
    ("CAST", ["SELECT CAST('12' AS INTEGER)"]),
    ("CASE", ["SELECT CASE WHEN 1 THEN 'y' ELSE 'n' END"]),
    ("EXISTS / IN subquery", ["SELECT EXISTS (SELECT 1), 1 IN (SELECT 1)"]),
    ("UNION", ["SELECT 1 UNION SELECT 2"]),
    ("INTERSECT / EXCEPT", ["SELECT 1 INTERSECT SELECT 1", "SELECT 1 EXCEPT SELECT 2"]),
    ("VALUES as a table", ["SELECT * FROM (VALUES (1),(2))"]),
    ("LEFT / RIGHT / FULL JOIN", ["CREATE TABLE j1(a INT)", "CREATE TABLE j2(a INT)", "SELECT * FROM j1 LEFT JOIN j2 ON j1.a=j2.a", "SELECT * FROM j1 RIGHT JOIN j2 ON j1.a=j2.a", "SELECT * FROM j1 FULL JOIN j2 ON j1.a=j2.a"]),
    ("NATURAL JOIN", ["CREATE TABLE na1(a INT)", "CREATE TABLE na2(a INT)", "SELECT * FROM na1 NATURAL JOIN na2"]),
    ("Table-valued json_each", ["SELECT value FROM json_each('[1,2]')"]),
    ("Table-valued json_tree", ["SELECT key FROM json_tree('{\"a\":1}')"]),
    ("generate_series", ["SELECT value FROM generate_series(1,3)"]),
    ("JSON operators -> ->>", ["SELECT '{\"a\":1}' ->> '$.a'"]),
    ("CREATE VIEW", ["CREATE TABLE v0(x INT)", "CREATE VIEW v1 AS SELECT x FROM v0"]),
    ("CREATE TRIGGER", ["CREATE TABLE tg(x INT)", "CREATE TRIGGER tg1 AFTER INSERT ON tg BEGIN SELECT 1; END"]),
    ("INSTEAD OF trigger on a view", ["CREATE TABLE it(x INT)", "CREATE VIEW itv AS SELECT x FROM it", "CREATE TRIGGER itt INSTEAD OF INSERT ON itv BEGIN INSERT INTO it VALUES (new.x); END", "INSERT INTO itv VALUES (1)"]),
    ("RAISE in a trigger", ["CREATE TABLE ra(x INT)", "CREATE TRIGGER rat BEFORE INSERT ON ra BEGIN SELECT RAISE(IGNORE); END"]),
    ("Partial index", ["CREATE TABLE pi(x INT)", "CREATE INDEX pi_x ON pi(x) WHERE x > 0"]),
    ("Expression index", ["CREATE TABLE ei(x TEXT)", "CREATE INDEX ei_x ON ei(lower(x))"]),
    ("CREATE INDEX IF NOT EXISTS", ["CREATE TABLE ie(x INT)", "CREATE INDEX IF NOT EXISTS ie_x ON ie(x)"]),
    ("UNIQUE INDEX", ["CREATE TABLE ui(x INT)", "CREATE UNIQUE INDEX ui_x ON ui(x)"]),
    ("CHECK constraint", ["CREATE TABLE ck(x INT CHECK (x > 0))", "CREATE TABLE ck2(x INT, CHECK (x > 0))"]),
    ("Named constraints (CONSTRAINT name)", ["CREATE TABLE cn(x INT CONSTRAINT pk PRIMARY KEY)"]),
    ("Index column DESC", ["CREATE TABLE id_(a INT, b INT)", "CREATE INDEX id_a ON id_(a DESC, b)"]),
    ("REPLACE INTO", ["CREATE TABLE ri(id INTEGER PRIMARY KEY)", "REPLACE INTO ri VALUES (1)"]),
    ("DEFAULT (expression)", ["CREATE TABLE de(x INT DEFAULT (1+1))"]),
    ("CURRENT_TIMESTAMP / _DATE / _TIME", ["SELECT CURRENT_TIMESTAMP, CURRENT_DATE, CURRENT_TIME", "CREATE TABLE dt(t TEXT DEFAULT CURRENT_TIMESTAMP)"]),
    ("GENERATED columns", ["CREATE TABLE ge(x INT, y INT GENERATED ALWAYS AS (x*2))"]),
    ("STRICT tables", ["CREATE TABLE st(x INT) STRICT"]),
    ("WITHOUT ROWID", ["CREATE TABLE wr(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID"]),
    ("FOREIGN KEY table constraint", ["CREATE TABLE fp(id INTEGER PRIMARY KEY)", "CREATE TABLE fc(p INT, FOREIGN KEY (p) REFERENCES fp(id))"]),
    ("Column REFERENCES", ["CREATE TABLE fp2(id INTEGER PRIMARY KEY)", "CREATE TABLE fc2(p INT REFERENCES fp2(id))"]),
    ("DEFERRABLE foreign keys", ["CREATE TABLE fp3(id INTEGER PRIMARY KEY)", "CREATE TABLE fc3(p INT, FOREIGN KEY (p) REFERENCES fp3(id) DEFERRABLE INITIALLY DEFERRED)"]),
    ("ALTER TABLE RENAME / ADD / DROP COLUMN", ["CREATE TABLE al(x INT, y INT)", "ALTER TABLE al ADD COLUMN z INT", "ALTER TABLE al RENAME COLUMN z TO w", "ALTER TABLE al DROP COLUMN w", "ALTER TABLE al RENAME TO al2"]),
    ("TEMP tables", ["CREATE TEMP TABLE tt(x INT)"]),
    ("Dynamic typing (no declared type)", ["CREATE TABLE dy(x)", "INSERT INTO dy VALUES (1), ('a'), (2.5)"]),
    ("ATTACH ':memory:' / DETACH", ["ATTACH ':memory:' AS aux", "DETACH aux"]),
    ("VACUUM (in memory: a no-op in SQLite)", ["VACUUM"]),
    ("ANALYZE", ["ANALYZE"]),
    ("REINDEX", ["REINDEX"]),
    ("EXPLAIN", ["EXPLAIN SELECT 1"]),
    ("EXPLAIN QUERY PLAN", ["EXPLAIN QUERY PLAN SELECT 1"]),
    ("BEGIN IMMEDIATE / EXCLUSIVE", ["BEGIN IMMEDIATE", "COMMIT", "BEGIN EXCLUSIVE", "COMMIT"]),
    ("FTS5 virtual table", ["CREATE VIRTUAL TABLE ft USING fts5(body)", "SELECT * FROM ft WHERE ft MATCH 'a'"]),
    ("R*Tree virtual table", ["CREATE VIRTUAL TABLE rt USING rtree(id, x0, x1, y0, y1)"]),
    ("Blob literals", ["SELECT x'00ff'"]),
    ("LIMIT with OFFSET and comma form", ["SELECT 1 LIMIT 1 OFFSET 0", "SELECT 1 LIMIT 0, 1"]),
    ("INDEXED BY / NOT INDEXED", ["CREATE TABLE ib(x INT)", "CREATE INDEX ib_x ON ib(x)", "SELECT * FROM ib INDEXED BY ib_x WHERE x = 1", "SELECT * FROM ib NOT INDEXED"]),
]


def call(binary, statements):
    """Runs statements in one in-memory session; answers (ok, first error)."""
    # The REPL keeps one session across lines, so BEGIN/SAVEPOINT and the DDL
    # a later statement depends on carry over; `sql` takes one statement.
    done = subprocess.run(
        [binary, "repl", ":memory:"],
        input="".join(s + ";\n" for s in statements) + ".quit\n",
        cwd=ROOT, capture_output=True, encoding="utf-8", errors="replace",
    )
    for line in (done.stdout + done.stderr).splitlines():
        if "error:" in line:
            return False, line.split("error:", 1)[1].strip()
    return done.returncode == 0, ""


def inventory():
    text = open(os.path.join(ROOT, "docs", "sqlite-inventory.md"), encoding="utf-8").read()
    sections = {}
    for title in ("Keywords", "Built-in functions", "Pragmas"):
        body = text.split("## " + title, 1)[1].split("##", 1)[0]
        sections[title] = re.findall(r"`([^`]+)`", body)
    return sections


def function_present(binary, name):
    # Arity does not matter: an unknown name is refused before the arguments
    # are counted, so any error other than "unknown function" means present.
    for args in ("", "1", "1, 1", "'a', 'b', 'c'"):
        ok, error = call(binary, [f"SELECT {name}({args})"])
        if ok:
            return True
        if "unknown function" not in error and "no such function" not in error:
            return True
    return False


def pragma_present(binary, name):
    ok, error = call(binary, [f"PRAGMA {name}"])
    return ok or "unknown pragma" not in error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=binary_path("miraidb"))
    parser.add_argument("--missing", action="store_true", help="print only what is missing")
    parser.add_argument("--check", action="store_true", help="fail unless docs/sqlite-roadmap.md states these counts")
    args = parser.parse_args()

    names = inventory()
    functions = [f for f in names["Built-in functions"] if f not in INTERNAL]
    missing_functions = [f for f in functions if not function_present(args.bin, f)]
    missing_pragmas = [p for p in names["Pragmas"] if not pragma_present(args.bin, p)]
    grammar = []
    for feature, statements in GRAMMAR:
        ok, error = call(args.bin, statements)
        # A probe that fails with no message still has to report something: this
        # once indexed an empty list and took the gate down with it.
        detail = "" if ok else (error.splitlines()[-1].replace("|", "/") if error.strip() else "(no message)")
        grammar.append((feature, ok, detail))

    have_f = len(functions) - len(missing_functions)
    have_p = len(names["Pragmas"]) - len(missing_pragmas)
    have_g = sum(1 for _, ok, _ in grammar if ok)
    measured = (have_f, len(functions), have_p, len(names["Pragmas"]), have_g, len(grammar))
    if args.check:
        found = CLAIM.search(open(ROADMAP, encoding="utf-8").read())
        if not found:
            print("sqlite_gaps: docs/sqlite-roadmap.md has no measured counts", file=sys.stderr)
            return 1
        stated = tuple(int(n) for n in found.groups())
        if stated != measured:
            print(f"sqlite_gaps: the roadmap states {stated}, measured {measured}; "
                  "update docs/sqlite-roadmap.md from `python scripts/sqlite_gaps.py`", file=sys.stderr)
            return 1
        print(f"sqlite_gaps: functions {have_f}/{len(functions)}, pragmas {have_p}/{len(names['Pragmas'])}, "
              f"grammar {have_g}/{len(grammar)}, as documented")
        return 0
    print(f"Functions: {have_f} / {len(functions)} (SQLite's internal test functions not counted)")
    print(f"Pragmas: {have_p} / {len(names['Pragmas'])}")
    print(f"Grammar features: {have_g} / {len(grammar)}")
    print()
    print("Missing functions: " + (", ".join(f"`{f}`" for f in missing_functions) or "none"))
    print()
    print("Missing pragmas: " + (", ".join(f"`{p}`" for p in missing_pragmas) or "none"))
    print()
    print("| Grammar feature | Runs | Answer when refused |")
    print("|---|---|---|")
    for feature, ok, error in grammar:
        if ok and args.missing:
            continue
        print(f"| {feature} | {'yes' if ok else '**no**'} | {error} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
