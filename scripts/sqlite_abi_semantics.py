"""SQLite's answers where the engine's own rules differ, driven the same way
through the facade and SQLite: division by zero, integer overflow, CAST of a
text, ASCII case folding, text in arithmetic, and a HAVING that names an alias
(docs/sqlite-semantics.md).

Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes

c_void_p = ctypes.c_void_p

QUERIES = [
 "SELECT 1/0", "SELECT 5 % 0", "SELECT 1.0/0", "SELECT 0/0", "SELECT -9223372036854775808 / -1",
 "SELECT 9223372036854775807 + 1", "SELECT -9223372036854775808 - 1", "SELECT 9223372036854775807 * 2", "SELECT abs(-9223372036854775808)", "SELECT sum(x) FROM (SELECT 9223372036854775807 AS x UNION ALL SELECT 1)", "SELECT -(-9223372036854775808)",
 "SELECT CAST('abc' AS INTEGER)", "SELECT CAST('12abc' AS INTEGER)", "SELECT CAST(' 7x' AS INTEGER)", "SELECT CAST('1e3' AS INTEGER)", "SELECT CAST('3.9' AS INTEGER)", "SELECT CAST('abc' AS REAL)", "SELECT CAST('1.5x' AS REAL)", "SELECT CAST('9999999999999999999' AS INTEGER)", "SELECT CAST(x'3132' AS INTEGER)", "SELECT CAST('12abc' AS NUMERIC)",
 "SELECT upper(char(233)), lower(char(201)), upper('straße'), like('É', 'é')",
 "CREATE TABLE tw (a TINYINT, b SMALLINT, c VARCHAR(2))", "INSERT INTO tw VALUES (300, 70000, 'abcdef')", "SELECT a, b, c FROM tw",
 "SELECT x, count(*) AS c FROM (SELECT 1 AS x UNION ALL SELECT 1 UNION ALL SELECT 2) GROUP BY x HAVING c > 1", "SELECT x % 2 AS k, sum(x) AS s FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3) GROUP BY k HAVING s > 3 AND k = 1", "SELECT upper(5), lower(x'41'), upper(NULL), 1 + '2', '3' * '4'",
 "SELECT 'a' || 1/0", "SELECT typeof(1/0)", "SELECT 10 % 3.5, -7 % 3, 7 / 2, -7 / 2",
 "SELECT 2147483647 * 2147483647 * 4",
 "SELECT 1.0 || '', 2.5e20 || '', 1e-7 || '', x'41' || 'b', 5 || NULL, CAST(0.5 AS TEXT), CAST(x'41' AS TEXT)",
]


def observe(lib, seen: dict) -> None:
    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0
    for sql in QUERIES:
        stmt = c_void_p()
        code = lib.sqlite3_prepare_v2(db, sql.encode(), -1, ctypes.byref(stmt), None)
        if code:
            seen[f"semantics: {sql}"] = (code, lib.sqlite3_errmsg(db))
            continue
        rows = []
        while (code := lib.sqlite3_step(stmt)) == 100:
            rows.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
        lib.sqlite3_finalize(stmt)
        seen[f"semantics: {sql}"] = rows if code == 101 else (code, lib.sqlite3_errmsg(db))
    lib.sqlite3_close(db)
