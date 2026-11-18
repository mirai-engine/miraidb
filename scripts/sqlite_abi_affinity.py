"""SQLite's typing, driven the same way through the facade and SQLite (S7).

What is compared: the storage class each declared type gives a value
(affinity, an untyped column, multi-word and unknown type names), comparisons
across storage classes with and without a column's affinity, min/max and
ORDER BY over mixed classes, the text form of reals, STRICT tables, WITHOUT
ROWID tables, the DDL errors SQLite gives at prepare, and a zero-byte file
opened as an empty database. Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes
import os
import tempfile

c_void_p = ctypes.c_void_p

STATEMENTS = [
    b"CREATE TABLE a (i INTEGER, t TEXT, r REAL, b BLOB, n NUMERIC, x, s STRING, v VARCHAR2(10), "
    b"u UNSIGNED BIG INT, f FLOATING POINT, bo BOOLEAN, d DATETIME)",
    b"INSERT INTO a VALUES ('12', 34, '5.5', 'bl', '7', '8', '9', 10, '11', '12.5', 'true', '2020-01-01')",
    b"INSERT INTO a VALUES ('abc', 'x', 'y', 1, 'z', 2.5, 3, 'q', 'w', 'e', 1, 5)",
    b"INSERT INTO a VALUES (1.0, 1.5, 3, x'01', '1.0', NULL, NULL, NULL, '3.0', '4', 0, 1.5)",
    b"INSERT INTO a (i, n) VALUES (' 42 ', '  -7.25e1 ')",
    b"SELECT typeof(i), typeof(t), typeof(r), typeof(b), typeof(n), typeof(x), typeof(s), typeof(v), "
    b"typeof(u), typeof(f), typeof(bo), typeof(d) FROM a",
    b"SELECT i, t, r, n, x, u, f FROM a",
    b"SELECT '1' = 1, 1 = '1', 1 < 'a', 'a' < x'00', NULL < 1, 2 > 'abc', 1 = 1.0, x'01' > 'zzz'",
    b"SELECT i = '12', t = 34, n = '7.0', i < '5', t > 3 FROM a",
    b"SELECT count(*) FROM a WHERE i > 5",
    b"SELECT x FROM a ORDER BY x",
    b"SELECT max(x), min(x), max(i), min(t) FROM a",
    b"SELECT 3.0, 0.1 + 0.2, 1e20, 1e15, 123456789012345678.0, -2.5, 1.0 / 3, 1e-5, 2.0e-7, 100.0, -0.0",
    b"CREATE TABLE s (i INTEGER, r REAL, t TEXT, b BLOB, a ANY) STRICT",
    b"INSERT INTO s VALUES ('12', '1.5', 34, x'01', 'x')",
    b"INSERT INTO s VALUES ('abc', 1, 'y', x'02', 2)",
    b"INSERT INTO s VALUES ('1.5', 2, 'z', x'03', 3)",
    b"INSERT INTO s VALUES (3, 'q', 'z', x'03', 3)",
    b"INSERT INTO s VALUES (4, 4, 'z', 'notblob', 4)",
    b"SELECT typeof(i), i, typeof(r), r, typeof(t), t, typeof(a) FROM s",
    b"CREATE TABLE w (k TEXT PRIMARY KEY, v) WITHOUT ROWID",
    b"INSERT INTO w VALUES ('b', 2), ('a', 1)",
    b"SELECT k, v FROM w ORDER BY k",
    b"SELECT rowid FROM w",
    b"CREATE TABLE both (k INTEGER PRIMARY KEY, v TEXT) STRICT, WITHOUT ROWID",
    b"INSERT INTO both VALUES (1, 'one')",
    b"SELECT k, v FROM both",
    b"ALTER TABLE w ADD COLUMN extra",
    b"ALTER TABLE w ADD COLUMN v",
    b"INSERT INTO w VALUES ('c', 3, '4')",
    b"SELECT typeof(extra) FROM w ORDER BY k",
    # DDL that SQLite refuses at prepare.
    b"CREATE VIEW vw AS SELECT k FROM w",
    b"CREATE INDEX wi ON w (v)",
    b"CREATE TABLE w (x)",
    b"CREATE TABLE IF NOT EXISTS w (x)",
    b"CREATE TABLE vw (x)",
    b"CREATE VIEW vw AS SELECT 1",
    b"CREATE VIEW w AS SELECT 1",
    b"CREATE INDEX wi ON w (k)",
    b"CREATE INDEX w2 ON missing (a)",
    b"CREATE INDEX w3 ON w (nope)",
    b"DROP TABLE missing",
    b"DROP VIEW missing",
    b"DROP INDEX missing",
    b"DROP TABLE vw",
    b"DROP VIEW w",
    b"CREATE TABLE bad (x VARCHAR) STRICT",
    b"CREATE TABLE nk (x) WITHOUT ROWID",
    b"CREATE TABLE dup (x, x)",
    b"CREATE TRIGGER tr AFTER INSERT ON missing BEGIN SELECT 1; END",
    b"ALTER TABLE missing ADD COLUMN c",
    b"DROP TABLE IF EXISTS missing",
]


def run(lib, db, sql: bytes):
    stmt = c_void_p()
    code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
    if code:
        return "prepare", code, lib.sqlite3_errmsg(db)
    rows = []
    while (step := lib.sqlite3_step(stmt)) == 100:
        rows.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
    message = lib.sqlite3_errmsg(db) if step != 101 else None
    lib.sqlite3_finalize(stmt)
    return "step", step, message, rows


def observe(lib, seen: dict) -> None:
    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0
    for sql in STATEMENTS:
        seen[f"affinity: {sql!r}"] = run(lib, db, sql)
    lib.sqlite3_close(db)

    # A file of zero bytes is an empty database, and the first write makes it
    # a database SQLite reads, NULLs in a column without a type included.
    directory = tempfile.mkdtemp()
    path = os.path.join(directory, "empty.db")
    open(path, "wb").close()
    empty = c_void_p()
    seen["open a zero-byte file"] = lib.sqlite3_open(path.encode(), ctypes.byref(empty))
    if seen["open a zero-byte file"] == 0:
        seen["write to it"] = run(lib, empty, b"CREATE TABLE m (x, y INTEGER)")[:2]
        run(lib, empty, b"INSERT INTO m VALUES (1, 1), ('a', 2), (x'00', 3), (NULL, 4)")
        lib.sqlite3_close(empty)
        again = c_void_p()
        lib.sqlite3_open(path.encode(), ctypes.byref(again))
        seen["read it back"] = run(lib, again, b"SELECT typeof(x), y FROM m ORDER BY y")
        lib.sqlite3_close(again)
    for name in os.listdir(directory):
        os.remove(os.path.join(directory, name))
    os.rmdir(directory)
