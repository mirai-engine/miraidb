#!/usr/bin/env python3
"""Differential runner: the same statements through this engine and SQLite.

A hand-written suite tests what its author thought of. This runner feeds one
schema, one set of rows and one corpus of queries to both engines and compares
the answers: equal rows, or a refusal this file lists with a reason. It is the
class of test that catches "the answer came back and it was wrong", which the
unit suite cannot see because it asserts what its author expected.

Three lists keep it honest:

- `QUERIES` must answer identically (order matters when the query says
  `ORDER BY`, otherwise the rows are compared as a multiset).
- `REFUSED` must fail in this engine and succeed in SQLite, with the stated
  reason. A refusal that stops refusing fails the gate, so the list shrinks as
  the engine grows.
- `DIFFERENT` must answer *differently* on purpose; if the answers converge the
  entry is stale and fails the gate.

Usage: python3 scripts/differential.py [--bin ./bin/miraidb.exe] [--verbose]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The binaries run with cwd=ROOT: the Windows miraidb.exe cannot read a /mnt/...
# path, so every path it is given is relative to the repository.
WORK = "_differential"
MIRAIDB_DB = WORK + "/miraidb_db"
SQLITE_DB = WORK + "/sqlite.db"

# The schema and the rows go through each engine's own parser. Rows include
# duplicates (for DISTINCT), NULLs (for three-valued logic) and numbers of both
# kinds (for comparison and formatting).
SETUP = [
    "CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
    "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary REAL, hired TEXT)",
    "INSERT INTO dept (id, name) VALUES (1, 'eng'), (2, 'sales'), (3, 'empty')",
    "INSERT INTO emp (id, name, dept, salary, hired) VALUES "
    "(1, 'ana', 1, 100.5, '2020-01-01'), (2, 'luis', 1, NULL, '2021-06-15'), "
    "(3, 'maria', 2, 90.0, NULL), (4, 'ana', 2, 75.25, '2019-03-02'), "
    "(5, NULL, 3, 50.0, '2022-07-07'), (6, 'zoe', NULL, 0.0, NULL)",
    "CREATE TABLE nums (n INTEGER, m REAL, t TEXT)",
    "INSERT INTO nums (n, m, t) VALUES (1, 1.5, 'a'), (1, 2.0, 'b'), (2, NULL, 'A'), "
    "(3, 3.5, NULL), (NULL, 4.0, 'c'), (2, 2.0, 'a')",
    "CREATE TABLE kv (k TEXT PRIMARY KEY, v INTEGER)",
    "INSERT INTO kv (k, v) VALUES ('a', 1), ('b', 2)",
    "CREATE TABLE audit (id INTEGER PRIMARY KEY, k TEXT, old_v INTEGER, new_v INTEGER)",
    "CREATE TRIGGER kv_audit AFTER UPDATE ON kv BEGIN INSERT INTO audit (k, old_v, new_v) VALUES (OLD.k, OLD.v, NEW.v); END",
]

QUERIES = [
    # Projection, ordering, NULL placement.
    "SELECT * FROM dept ORDER BY id",
    "SELECT id, name FROM emp ORDER BY name",
    "SELECT id, name FROM emp ORDER BY name DESC",
    "SELECT id, salary FROM emp ORDER BY salary",
    "SELECT id FROM emp ORDER BY id DESC LIMIT 2",
    "SELECT id FROM emp ORDER BY id LIMIT 2 OFFSET 2",
    "SELECT 1 + 2, 7 / 2, 7 % 2, -3, 2 * 3",
    "SELECT 1.5 + 1, 1 / 3.0",
    # Aggregates, DISTINCT and grouping.
    "SELECT count(*), count(salary), sum(salary), avg(salary), min(salary), max(salary) FROM emp",
    "SELECT count(DISTINCT dept), sum(DISTINCT dept), avg(DISTINCT dept) FROM emp",
    "SELECT dept AS d, count(*) FROM emp GROUP BY d ORDER BY d",
    # A join written with USING: the merged column appears once in `SELECT *`,
    # the left relation supplies it, and a qualified star still lists them all.
    "SELECT * FROM emp JOIN dept USING (id) ORDER BY emp.id",
    "SELECT count(*) FROM emp JOIN dept USING (id)",
    "SELECT dept.* FROM emp JOIN dept USING (id) ORDER BY emp.id",
    "SELECT emp.name, dept.name FROM emp LEFT JOIN dept USING (id) ORDER BY emp.id",
    # Frames: a run of peer groups, and a band of the ordering value.
    "SELECT id, sum(salary) OVER (ORDER BY id RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM emp ORDER BY id",
    "SELECT id, count(*) OVER (ORDER BY dept GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM emp ORDER BY id",
    "SELECT id, sum(salary) OVER (ORDER BY id RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM emp ORDER BY id",
    "SELECT id, first_value(salary) OVER (ORDER BY id DESC RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM emp ORDER BY id",
    "SELECT dept, count(*), sum(salary) FROM emp GROUP BY dept ORDER BY dept",
    "SELECT dept, count(*) FROM emp GROUP BY dept HAVING count(*) > 1 ORDER BY dept",
    "SELECT DISTINCT n FROM nums ORDER BY n",
    "SELECT n, count(*) FROM nums GROUP BY n ORDER BY n",
    "SELECT count(*) FROM emp WHERE salary > 60",
    "SELECT count(*), sum(salary), avg(salary) FROM emp WHERE id > 99",
    "SELECT min(n), max(n) FROM nums WHERE n > 99",
    # Subqueries, EXISTS and IN, including the three-valued edge.
    "SELECT id FROM emp WHERE dept IN (1, 2) ORDER BY id",
    "SELECT id FROM emp WHERE dept NOT IN (1, 2) ORDER BY id",
    "SELECT id FROM emp WHERE dept NOT IN (1, NULL) ORDER BY id",
    "SELECT id FROM emp WHERE dept IN (SELECT id FROM dept WHERE id = 2) ORDER BY id",
    "SELECT id FROM emp WHERE dept NOT IN (SELECT id FROM dept WHERE id = 1) ORDER BY id",
    "SELECT id, (SELECT count(*) FROM dept) AS d FROM emp WHERE id = 1",
    # Joins.
    "SELECT e.id, d.name FROM emp e JOIN dept d ON e.dept = d.id ORDER BY e.id",
    "SELECT e.id FROM emp e LEFT JOIN dept d ON e.dept = d.id WHERE d.id IS NULL ORDER BY e.id",
    "SELECT e.id, d.id FROM emp e LEFT JOIN dept d ON e.dept = d.id ORDER BY e.id",
    "SELECT e.id, d.id FROM emp e, dept d WHERE e.id = 1 AND d.id = 2",
    # Predicates.
    "SELECT id FROM emp WHERE salary BETWEEN 60 AND 100 ORDER BY id",
    "SELECT id FROM emp WHERE salary IS NULL ORDER BY id",
    "SELECT id FROM emp WHERE name IS NULL ORDER BY id",
    "SELECT id FROM emp WHERE name LIKE 'a%' ORDER BY id",
    "SELECT id FROM emp WHERE name LIKE 'A%' ORDER BY id",
    "SELECT id FROM emp WHERE name GLOB 'a*' ORDER BY id",
    "SELECT 1 IN (1, 2), 1 NOT IN (1, 2), 2 IN (1, NULL), 2 NOT IN (1, NULL)",
    "SELECT NULL IS NULL, NULL = NULL, 1 = 1.0",
    # Strings, numbers and functions.
    "SELECT upper(name), lower(name), length(name), substr(name, 1, 2) FROM emp WHERE id = 3",
    "SELECT name || '!' FROM emp WHERE name IS NOT NULL ORDER BY id",
    "SELECT coalesce(salary, -1), ifnull(dept, -1) FROM emp ORDER BY id",
    "SELECT nullif(dept, 2), nullif(name, 'ana') FROM emp ORDER BY id",
    "SELECT CAST('12' AS INTEGER), CAST(1.9 AS INTEGER), CAST(42 AS TEXT)",
    "SELECT abs(-3), round(2.567, 1), min(2, 3), max(2, 3)",
    "SELECT replace('banana', 'an', 'X'), trim('  hi  '), ltrim('xxa', 'x'), rtrim('axx', 'x')",
    "SELECT ltrim('  hi  '), rtrim('  hi  ')",
    "SELECT instr('hello', 'll'), hex('AB'), length(hex(zeroblob(3)))",
    "SELECT concat('a', NULL, 'b')",
    # Common table expression and a window frame.
    "WITH big AS (SELECT * FROM emp WHERE salary > 60) SELECT name FROM big ORDER BY name",
    "SELECT id, sum(salary) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM emp WHERE salary IS NOT NULL ORDER BY id",
    # CASE, both forms and as a grouping expression.
    "SELECT id, CASE WHEN salary IS NULL THEN 'none' WHEN salary > 90 THEN 'high' ELSE 'low' END AS band FROM emp ORDER BY id",
    "SELECT id, CASE dept WHEN 1 THEN 'eng' WHEN 2 THEN 'sales' ELSE 'other' END FROM emp ORDER BY id",
    "SELECT CASE WHEN dept = 2 THEN 1 ELSE 0 END AS s, count(*) FROM emp GROUP BY CASE WHEN dept = 2 THEN 1 ELSE 0 END ORDER BY s",
    "SELECT count(CASE WHEN dept = 1 THEN 1 END), sum(CASE WHEN dept = 2 THEN salary ELSE 0 END) FROM emp",
    "SELECT id FROM emp WHERE CASE WHEN salary IS NULL THEN 0 ELSE 1 END = 1 ORDER BY id",
    "SELECT CASE WHEN 1 = 0 THEN 1 / 0 ELSE 7 END",
    "SELECT CASE WHEN NULL THEN 1 ELSE 2 END, CASE WHEN 1 THEN 'a' END",
    # JSON and dates.
    "SELECT typeof(1), typeof(1.5), typeof('a'), typeof(NULL)",
    "SELECT json_extract('{\"a\":[10,20]}', '$.a[1]'), json_valid('[1,2]'), json_type('{\"a\":1}')",
    "SELECT date('2020-01-02'), strftime('%Y', '2020-01-02'), date('2020-01-02', '+1 day')",
    # DML that returns rows.
    "INSERT INTO kv (k, v) VALUES ('c', 3) RETURNING k, v",
    "INSERT INTO kv (k, v) VALUES ('a', 99) ON CONFLICT (k) DO UPDATE SET v = excluded.v RETURNING k, v",
    "UPDATE kv SET v = 5 WHERE k = 'b' RETURNING k, v",
    "SELECT k, v FROM kv ORDER BY k",
    "SELECT k, old_v, new_v FROM audit ORDER BY id",
]

# The engine refuses these and says why; SQLite answers them. A refusal that
# starts working fails the gate, which is how the list shrinks.
REFUSED = {
    "SELECT emp.id FROM emp RIGHT JOIN dept ON emp.dept = dept.id": "RIGHT joins are refused, not approximated",
    "SELECT emp.id FROM emp FULL JOIN dept ON emp.dept = dept.id": "FULL joins are refused, not approximated",
    "SELECT emp.id FROM emp NATURAL JOIN dept": "NATURAL joins are refused, not approximated",

    "SELECT * FROM (SELECT id FROM emp) AS sub": "a subquery in FROM is not supported",
    "SELECT id FROM emp WHERE EXISTS (SELECT 1 FROM dept WHERE dept.id = emp.dept)": "a correlated reference is not resolved (features.md E2)",

}

# Both engines answer, differently, on purpose. These are the decisions listed
# in docs/sqlite.md; if one converges, the entry is stale.
DIFFERENT = {
    "SELECT 1 / 0": "division by zero is an error here, NULL in SQLite",
    "SELECT CAST('abc' AS INTEGER)": "a cast that cannot hold its value is an error here, 0 in SQLite",
    "SELECT 9223372036854775807 + 1": "integer arithmetic wraps here, becomes a float in SQLite",
    "SELECT 1 = '1'": "comparing a number with text is an error here, false in SQLite",
}


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, **kwargs)


def sqlite_available() -> str:
    path = shutil.which("sqlite3")
    return path or ""


def miraidb_query(binary: str, statement: str) -> tuple[list, str, int]:
    done = run([binary, "sql", "--json", MIRAIDB_DB, statement])
    if done.returncode != 0:
        return [], done.stderr.strip() or done.stdout.strip(), done.returncode
    text = done.stdout.strip()
    if not text:
        return [], "", 0
    try:
        return json.loads(text), "", 0
    except json.JSONDecodeError as error:
        return [], f"unparseable output ({error}): {text[:200]}", 1


def sqlite_query(statement: str) -> tuple[list, str, int]:
    done = run(["sqlite3", "-json", SQLITE_DB, statement])
    if done.returncode != 0:
        return [], done.stderr.strip(), done.returncode
    text = done.stdout.strip()
    if not text:
        return [], "", 0
    try:
        parsed = json.loads(text, object_pairs_hook=lambda pairs: pairs)
    except json.JSONDecodeError:
        return [], f"unparseable sqlite output: {text[:200]}", 1
    # sqlite3 -json emits one object per row. object_pairs_hook keeps the select
    # order and the duplicate names a query like `SELECT e.id, d.id` produces.
    return [[value for _, value in row] for row in parsed], "", 0


def same_cell(left, right) -> bool:
    if left is None or right is None:
        return left is None and right is None
    if isinstance(left, bool):
        left = int(left)
    if isinstance(right, bool):
        right = int(right)
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        if isinstance(left, int) and isinstance(right, int):
            return left == right
        return math.isclose(float(left), float(right), rel_tol=1e-12, abs_tol=1e-12)
    if isinstance(left, str) and isinstance(right, str):
        return left == right
    return left == right


def canon(row) -> str:
    return json.dumps([canon_cell(cell) for cell in row], sort_keys=True)


def canon_cell(cell):
    if isinstance(cell, bool):
        return ["n", int(cell)]
    if isinstance(cell, (int, float)):
        return ["n", repr(float(cell)) if isinstance(cell, float) else cell]
    return ["v", cell]


def compare(statement: str, mine: list, theirs: list) -> str:
    ordered = "order by" in statement.lower()
    if not ordered:
        mine = sorted(mine, key=canon)
        theirs = sorted(theirs, key=canon)
    if len(mine) != len(theirs):
        return f"{len(theirs)} row(s) from sqlite, {len(mine)} from miraidb"
    for index, (left, right) in enumerate(zip(mine, theirs)):
        if len(left) != len(right):
            return f"row {index}: {len(right)} cell(s) from sqlite, {len(left)} from miraidb"
        for column, (a, b) in enumerate(zip(left, right)):
            if not same_cell(a, b):
                return f"row {index}, column {column}: sqlite {json.dumps(b)}, miraidb {json.dumps(a)}"
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=os.path.join("bin", "miraidb.exe"))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    binary = args.bin if os.path.exists(os.path.join(ROOT, args.bin)) else os.path.join(ROOT, "bin", "miraidb")
    if not os.path.exists(binary):
        print(f"differential: no binary at {args.bin}; build first")
        return 1
    if not sqlite_available():
        print("differential: sqlite3 is not on PATH")
        return 1

    shutil.rmtree(os.path.join(ROOT, WORK), ignore_errors=True)
    os.makedirs(os.path.join(ROOT, WORK))

    failures: list[str] = []
    # Setup: one process per engine, the same statements.
    for statement in SETUP:
        done = run([binary, "sql", MIRAIDB_DB, statement])
        if done.returncode != 0:
            failures.append(f"setup failed in miraidb: {statement}: {done.stderr.strip()}")
    script = ";\n".join(SETUP) + ";\n"
    done = run(["sqlite3", SQLITE_DB], input=script)
    if done.returncode != 0:
        failures.append(f"setup failed in sqlite: {done.stderr.strip()}")

    compared = 0
    for statement in QUERIES:
        mine, my_error, my_status = miraidb_query(binary, statement)
        theirs, their_error, their_status = sqlite_query(statement)
        if their_status != 0:
            failures.append(f"the corpus is not SQLite's: {statement}: {their_error}")
            continue
        if my_status != 0:
            failures.append(f"miraidb refused a query in QUERIES: {statement}: {my_error}")
            continue
        difference = compare(statement, mine, theirs)
        compared += 1
        if difference:
            failures.append(f"{statement}\n     sqlite:  {json.dumps(theirs)}\n     miraidb: {json.dumps(mine)}\n     {difference}")
        elif args.verbose:
            print(f"ok   {statement[:70]}")

    refused = 0
    for statement, reason in REFUSED.items():
        mine, my_error, my_status = miraidb_query(binary, statement)
        theirs, their_error, their_status = sqlite_query(statement)
        if my_status == 0:
            failures.append(f"no longer refused, move it to QUERIES: {statement} ({reason})")
            continue
        if their_status != 0:
            failures.append(f"REFUSED lists a statement SQLite does not accept either: {statement}: {their_error}")
            continue
        refused += 1

    different = 0
    for statement, reason in DIFFERENT.items():
        mine, my_error, my_status = miraidb_query(binary, statement)
        theirs, their_error, their_status = sqlite_query(statement)
        if their_status != 0:
            failures.append(f"DIFFERENT lists a statement SQLite does not accept: {statement}: {their_error}")
            continue
        if my_status == 0:
            same = compare(statement, mine, theirs)
            if not same:
                failures.append(f"the answers converged, move it to QUERIES: {statement} ({reason})")
                continue
        different += 1

    shutil.rmtree(os.path.join(ROOT, WORK), ignore_errors=True)
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        print(f"differential: {len(failures)} problem(s)")
        return 1
    print(
        f"differential: {compared} queries agree, {refused} refusals as documented, "
        f"{different} intentional differences"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
