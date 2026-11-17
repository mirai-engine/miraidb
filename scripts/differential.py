#!/usr/bin/env python3
"""Differential runner: the same statements through this engine and SQLite.

A hand-written suite tests what its author thought of. This runner feeds one
schema, one set of rows and one corpus of queries to both engines and compares
the answers: equal rows, or a refusal this file lists with a reason. It is the
class of test that catches "the answer came back and it was wrong", which the
unit suite cannot see because it asserts what its author expected.

Three lists keep it honest:

- `QUERIES` must answer identically: values *and* types (order matters when the
  statement's own top-level `ORDER BY` decides it, otherwise the rows are
  compared as a multiset).
- `REFUSED` must fail in this engine and succeed in SQLite, with the stated
  reason. A refusal that stops refusing fails the gate, so the list shrinks as
  the engine grows.
- `DIFFERENT` must answer *differently* on purpose; if the answers converge the
  entry is stale and fails the gate.
- `REJECTED` must fail in both engines: a statement that names something that
  is not there is refused before it runs, whatever the table holds.

Usage: python3 scripts/differential.py [--bin ./bin/miraidb.exe] [--verbose]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import sqlite3
import subprocess
import sys

from binpath import binary_path

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
    # Partial and expression indexes exist while every query runs: a planner
    # that read one where it holds only some rows would answer differently.
    "CREATE INDEX emp_lower_name ON emp (lower(name)) WHERE dept IS NOT NULL",
    "CREATE INDEX nums_partial ON nums (n) WHERE m > 2",
    "CREATE TABLE kv (k TEXT PRIMARY KEY, v INTEGER)",
    "INSERT INTO kv (k, v) VALUES ('a', 1), ('b', 2)",
    "CREATE TABLE audit (id INTEGER PRIMARY KEY, k TEXT, old_v INTEGER, new_v INTEGER)",
    "CREATE TRIGGER kv_audit AFTER UPDATE ON kv BEGIN INSERT INTO audit (k, old_v, new_v) VALUES (OLD.k, OLD.v, NEW.v); END",
    "CREATE TABLE empty_t (a INTEGER, b TEXT)",
]

QUERIES = [
    # Outer joins on both sides: the unmatched side answers NULL, on whichever
    # side that is.
    "SELECT emp.id, dept.id FROM emp RIGHT JOIN dept ON emp.dept = dept.id ORDER BY dept.id, emp.id",
    "SELECT emp.id, dept.id FROM emp FULL JOIN dept ON emp.dept = dept.id ORDER BY dept.id, emp.id",
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
    # printf('%.0f', 2.5) is not here: SQLite rounds a tie at zero digits to even
    # in 3.45 and away from zero in 3.53, so the answer depends on which SQLite
    # runs the corpus. docs/sqlite.md declares the claim with the versions it
    # holds for, and scripts/compat_check.py runs it against the one installed.
    "INSERT INTO kv (k, v) VALUES ('c', 3) RETURNING k, v",
    "INSERT INTO kv (k, v) VALUES ('a', 99) ON CONFLICT (k) DO UPDATE SET v = excluded.v RETURNING k, v",
    "UPDATE kv SET v = 5 WHERE k = 'b' RETURNING k, v",
    "SELECT k, v FROM kv ORDER BY k",
    "SELECT k, old_v, new_v FROM audit ORDER BY id",
    # IN and BETWEEN compare under the left operand's collation.
    "SELECT id FROM emp WHERE name COLLATE NOCASE IN ('ANA', 'Zoe') ORDER BY id",
    "SELECT id FROM emp WHERE name COLLATE NOCASE BETWEEN 'L' AND 'MARIA' ORDER BY id",
    # Common table expressions on a write (D38): in front of it, and inside an
    # INSERT's SELECT; recursive too; seen by the WHERE of an UPDATE and a DELETE.
    "WITH c AS (SELECT 'd' AS k, 4 AS v) INSERT INTO kv (k, v) SELECT k, v FROM c RETURNING k, v",
    "INSERT INTO kv (k, v) WITH c AS (SELECT 'e' AS k, 5 AS v) SELECT k, v FROM c RETURNING k, v",
    "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 3) INSERT INTO kv (k, v) SELECT 'r' || x, x FROM n RETURNING k, v",
    "WITH c AS (SELECT 'd' AS k) UPDATE kv SET v = v * 10 WHERE k IN (SELECT k FROM c) RETURNING k, v",
    "WITH c AS (SELECT 'e' AS k) DELETE FROM kv WHERE k IN (SELECT k FROM c) RETURNING k, v",
    "SELECT k, v FROM kv ORDER BY k",
    # Edge cases the second audit pass measured. A text is a number where truth
    # is asked, a position is a character, and a real keeps its type.
    "SELECT substr('abcdef', -3), substr('abcdef', 2, -2), substr('abcdef', 0, 3)",
    "SELECT substr('abcdef', -99), substr('abcdef', 99), substr('abcdef', 3, 0)",
    "SELECT length(char(233) || 'llo'), instr(char(233) || 'llo', 'llo'), substr(char(233) || 'llo', 2, 2)",
    "SELECT 1 WHERE 'a'",
    "SELECT 1 WHERE '1'",
    "SELECT count(*) FROM nums WHERE t",
    "SELECT typeof(1.0), typeof(1), typeof('1'), typeof(x'00')",
    "SELECT 1.0, 1, 1.5, 0.1 + 0.2",
    "SELECT -0.0, 0.0",
    # A window's own ORDER BY does not order the result: these rows come back in
    # an unspecified order and must compare as a multiset (AUDIT-10 P-B4).
    "SELECT n, row_number() OVER (ORDER BY n) FROM nums",
    "SELECT n, rank() OVER (ORDER BY n) FROM nums",
    "SELECT n, lag(n) OVER (ORDER BY n) FROM nums",
    "SELECT n, sum(n) OVER (PARTITION BY m ORDER BY n ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM nums",
    # Scalar edges around casting, rounding, rendering and formatting.
    "SELECT CAST('12' AS INTEGER), CAST(2.9 AS INTEGER), CAST('2.9' AS REAL)",
    "SELECT round(1.5), round(2.5), round(-2.5)",
    "SELECT hex(x'00ff'), hex('abc'), quote(1.5), quote(NULL)",
    "SELECT json_extract('{\"a\":{\"b\":2}}', '$.a.b'), json_type('[]'), json_type('1'), json_type('1.0')",
    "SELECT date('2020-01-01', '+1 day'), strftime('%Y-%m', '2020-05-06')",
    "SELECT printf('%05.2f', 3.14159), 3.0 = 3",
    "SELECT printf('%05.2f|%-5s|%+.3d|%x|%.2e|%q', 3.14159, 'ab', 7, 255, 1234.5, 'it''s')",
    "SELECT printf('%10.4f|%-10.4f|%08x|%g', 3.14159265, 3.14159265, 255, 1000000.0)",
    # NULLs sort first in both engines, and a SUM of integers stays an integer.
    "SELECT n, m FROM nums ORDER BY m",
    "SELECT typeof(SUM(n)) FROM nums",
    # IS between values: NULL is an ordinary value on both sides.
    "SELECT id, dept IS 1, dept IS NOT 2, dept IS NULL FROM emp ORDER BY id",
    "SELECT id, salary IS DISTINCT FROM 90.0, salary IS NOT DISTINCT FROM NULL FROM emp ORDER BY id",
    "SELECT count(*) FROM emp WHERE dept IS NOT 1",
    # Bitwise operators, their precedence and their NULLs.
    "SELECT n, n & 1, n | 4, ~n, n << 2, n >> 1 FROM nums ORDER BY n, m",
    "SELECT 1 + 2 & 3, 1 << 2 + 1, -8 >> 1, 1 << 64, 6.7 & 3",
    # JSON operators: a path, a key and an array slot.
    "SELECT '{\"a\":{\"b\":[1,2]}}' -> '$.a', '{\"a\":{\"b\":[1,2]}}' ->> '$.a.b[1]', '{\"a\":\"x\"}' ->> 'a', '[5,6]' ->> 1",
    "SELECT json_extract('{\"A\":1}', '$.a'), json_extract('{\"A\":1}', '$.A')",
    # LIMIT <offset>, <count>.
    "SELECT id FROM emp ORDER BY id LIMIT 2, 3",
    # INTERSECT and EXCEPT, and a chain applied left to right.
    "SELECT dept FROM emp INTERSECT SELECT id FROM dept",
    "SELECT id FROM dept EXCEPT SELECT dept FROM emp",
    "SELECT dept FROM emp UNION SELECT 1 UNION ALL SELECT 1",
    "SELECT n FROM nums EXCEPT SELECT 1 UNION SELECT 9 ORDER BY 1",
    # NULLS FIRST / LAST, in a statement and in a window.
    "SELECT id, dept FROM emp ORDER BY dept NULLS LAST, id",
    "SELECT id, salary FROM emp ORDER BY salary DESC NULLS FIRST, id",
    "SELECT id, row_number() OVER (ORDER BY dept DESC NULLS LAST, id) FROM emp ORDER BY id",
    # Derived tables and VALUES.
    "SELECT * FROM (SELECT id FROM emp) AS sub",
    "SELECT s.dept, count(*) FROM (SELECT dept FROM emp WHERE dept IS NOT NULL) AS s GROUP BY s.dept ORDER BY s.dept",
    "SELECT * FROM (VALUES (1, 'a'), (2, 'b'))",
    "VALUES (1, 2), (3, NULL)",
    "SELECT emp.name, v.column2 FROM emp JOIN (VALUES (1, 'one'), (2, 'two')) v ON v.column1 = emp.dept ORDER BY emp.id",
    # Row values.
    "SELECT id FROM emp WHERE (dept, name) = (1, 'ana')",
    "SELECT id FROM emp WHERE (dept, id) > (1, 1) ORDER BY id",
    "SELECT id FROM emp WHERE (dept, name) IN ((1, 'luis'), (2, 'ana')) ORDER BY id",
    "SELECT id FROM emp WHERE (dept, name) IN (SELECT id, 'maria' FROM dept) ORDER BY id",
    "SELECT (1, NULL) = (1, 2), (1, 2) < (1, 3), (1, 2) IS (1, 2)",
    # Queries a partial or an expression index could be tempted to answer.
    "SELECT id FROM emp WHERE lower(name) = 'ana' ORDER BY id",
    "SELECT n FROM nums WHERE n = 2 ORDER BY n",
    "SELECT n FROM nums WHERE n > 0 ORDER BY n",
    # A NULL argument gives NULL, not an error.
    "SELECT lower(NULL), upper(NULL), replace(NULL, 'a', 'b'), instr(NULL, 'a'), sign(NULL), sqrt(NULL), printf(NULL), hex(char(NULL))",    # SQLite's other spellings and its planner hints.
    "SELECT ceiling(1.2), power(2, 10), ln(1), ln(0), likely(5), unlikely(NULL), likelihood(3, 0.5)",
    # A correlated reference reads the row of the statement it is written in.
    "SELECT id FROM emp WHERE EXISTS (SELECT 1 FROM dept WHERE dept.id = emp.dept)",
    "SELECT name FROM emp WHERE salary > (SELECT avg(salary) FROM emp WHERE dept = emp.dept)",
]

# The engine refuses these and says why; SQLite answers them. A refusal that
# starts working fails the gate, which is how the list shrinks.
REFUSED = {
    "SELECT emp.id FROM emp NATURAL JOIN dept": "NATURAL joins are refused, not approximated",

    "SELECT sum(n) FILTER (WHERE n > 1) FROM nums": "an aggregate FILTER is not implemented; windows accept one",

}

# Both engines refuse these. A name that is not there is refused before the
# statement runs, so an empty table does not hide it (D37).
REJECTED = {
    "SELECT nope FROM empty_t": "a misspelled column in the projection",
    "SELECT a FROM empty_t WHERE nope = 1": "a misspelled column in WHERE",
    "SELECT a FROM empty_t ORDER BY nope": "a misspelled column in ORDER BY",
    "SELECT a FROM empty_t GROUP BY nope": "a misspelled column in GROUP BY",
    "SELECT * FROM missing_t": "a table that does not exist",
    "SELECT e.nope FROM empty_t AS e": "a qualified column that does not exist",
    "SELECT a FROM empty_t WHERE a IN (SELECT nope FROM empty_t)": "a misspelled column in a subquery",
    "UPDATE empty_t SET nope = 1": "an assigned column that does not exist",
    "DELETE FROM empty_t WHERE nope = 1": "a misspelled column in a DELETE",
    "INSERT INTO empty_t (nope) VALUES (1)": "an inserted column that does not exist",
}

# Both engines answer, differently, on purpose. These are the decisions listed
# in docs/sqlite.md; if one converges, the entry is stale.
DIFFERENT = {
    "SELECT upper(char(233)), lower(char(201))": "SQLite folds ASCII only; this engine applies Unicode case mapping",
    "SELECT CAST('12abc' AS INTEGER)": "a cast takes a whole number here, the numeric prefix in SQLite",
    "SELECT 1 / 0": "division by zero is an error here, NULL in SQLite",
    "SELECT CAST('abc' AS INTEGER)": "a cast that cannot hold its value is an error here, 0 in SQLite",
    "SELECT 9223372036854775807 + 1": "integer arithmetic wraps here, becomes a float in SQLite",
    "SELECT 1 = '1'": "comparing a number with text is an error here, false in SQLite",
}


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=ROOT, capture_output=True, encoding="utf-8", errors="replace", **kwargs)


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
    """Ask SQLite through Python's module, which hands back typed values.

    The `sqlite3 -json` shell was used here first, and it prints a real with no
    fraction as an integer (`90.0` comes out as `90`), so a type-aware comparison
    reported thirteen differences that were the shell's formatting, not SQLite's
    answer. The module keeps `int` and `float` apart, which is what the cell
    comparison below needs.
    """
    connection = sqlite3.connect(os.path.join(ROOT, SQLITE_DB))
    try:
        rows = connection.execute(statement).fetchall()
        # The corpus writes too (RETURNING, UPSERT): keep what it wrote, as the
        # shell did, so the statements after it read the same rows.
        connection.commit()
    except sqlite3.Error as error:
        return [], str(error), 1
    finally:
        connection.close()
    return [list(row) for row in rows], "", 0


def same_cell(left, right) -> bool:
    """Compare a cell by value and by type.

    SQLite keeps 1 and 1.0 apart and so does this runner: comparing them
    as equal let a query that returned the wrong type pass, which is how a real
    type bug stayed invisible (AUDIT-10 P-B5).
    """
    # SQLite has no boolean type: a true or a false is the number 1 or 0.
    if isinstance(left, bool):
        left = int(left)
    if isinstance(right, bool):
        right = int(right)
    if left is None or right is None:
        return left is None and right is None
    if isinstance(left, int) and isinstance(right, int):
        return left == right
    if isinstance(left, float) and isinstance(right, float):
        return math.isclose(left, right, rel_tol=1e-12, abs_tol=1e-12)
    if isinstance(left, str) and isinstance(right, str):
        return left == right
    return type(left) is type(right) and left == right


def canon(row) -> str:
    return json.dumps([canon_cell(cell) for cell in row], sort_keys=True)


def canon_cell(cell):
    if isinstance(cell, bool):
        return ["i", int(cell)]
    if isinstance(cell, int):
        return ["i", cell]
    if isinstance(cell, float):
        return ["f", repr(cell)]
    if cell is None:
        return ["z"]
    if isinstance(cell, str):
        return ["s", cell]
    return ["x", json.dumps(cell, sort_keys=True)]


def top_level_words(statement: str) -> list[str]:
    """The words of a statement that sit outside every parenthesis and literal."""
    words: list[str] = []
    word: list[str] = []
    depth = 0
    at, length = 0, len(statement)
    while at < length:
        c = statement[at]
        if c in "'\"":
            quote = c
            at += 1
            while at < length:
                if statement[at] == quote:
                    if at + 1 < length and statement[at + 1] == quote:
                        at += 2
                        continue
                    at += 1
                    break
                at += 1
            continue
        if c == "[":
            while at < length and statement[at] != "]":
                at += 1
            at += 1
            continue
        if c == "(":
            if depth == 0 and word:
                words.append("".join(word).lower())
                word = []
            depth += 1
            at += 1
            continue
        if c == ")":
            if depth == 0 and word:
                words.append("".join(word).lower())
                word = []
            depth = max(depth - 1, 0)
            at += 1
            continue
        if depth > 0:
            at += 1
            continue
        if c.isalnum() or c == "_":
            word.append(c)
        else:
            if word:
                words.append("".join(word).lower())
                word = []
        at += 1
    if word and depth == 0:
        words.append("".join(word).lower())
    return words


def has_top_level_order_by(statement: str) -> bool:
    """Whether the statement itself decides the row order.

    "order by" as a substring is not the question: a window's
    `OVER (… ORDER BY …)` or a subquery's own ORDER BY orders something else, so
    treating it as the result's order compared an unordered result position by
    position — three window queries were reported as differences in AUDIT-10
    P-B4 while their multisets were identical.
    """
    words = top_level_words(statement)
    return any(
        words[i] == "order" and words[i + 1] == "by" for i in range(len(words) - 1)
    )


def compare(statement: str, mine: list, theirs: list) -> str:
    ordered = has_top_level_order_by(statement)
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
    parser.add_argument("--bin", default=binary_path("miraidb"))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    binary = args.bin if os.path.exists(os.path.join(ROOT, args.bin)) else os.path.join(ROOT, "bin", "miraidb")
    if not os.path.exists(binary):
        print(f"differential: no binary at {args.bin}; build first")
        return 1

    shutil.rmtree(os.path.join(ROOT, WORK), ignore_errors=True)
    os.makedirs(os.path.join(ROOT, WORK))

    failures: list[str] = []
    # Setup: one process per engine, the same statements.
    for statement in SETUP:
        done = run([binary, "sql", MIRAIDB_DB, statement])
        if done.returncode != 0:
            failures.append(f"setup failed in miraidb: {statement}: {done.stderr.strip()}")
    connection = sqlite3.connect(os.path.join(ROOT, SQLITE_DB))
    try:
        connection.executescript(";\n".join(SETUP) + ";\n")
        connection.commit()
    except sqlite3.Error as error:
        failures.append(f"setup failed in sqlite: {error}")
    finally:
        connection.close()

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

    rejected = 0
    for statement, reason in REJECTED.items():
        mine, my_error, my_status = miraidb_query(binary, statement)
        theirs, their_error, their_status = sqlite_query(statement)
        if their_status == 0:
            failures.append(f"REJECTED lists a statement SQLite accepts: {statement} ({reason})")
            continue
        if my_status == 0:
            failures.append(f"miraidb accepted a statement both should refuse: {statement} ({reason})")
            continue
        rejected += 1

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
        f"{rejected} rejected by both, {different} intentional differences"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
