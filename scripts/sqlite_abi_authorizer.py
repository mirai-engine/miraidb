"""sqlite3_set_authorizer, driven the same way through the facade and SQLite.

Two things are compared. The questions: for each statement, the set of
(action, arg1, arg2, database) the authorizer is asked while the statement is
prepared. Their order is SQLite's compiler's, so it is not compared, and the
questions SQLite asks about its own tables (sqlite_master, sqlite_stat1) have
no counterpart in this engine and are left out. And the answers: what DENY and
IGNORE do to a read, an assignment, an insert, a function, a transaction and a
pragma. Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes

c_void_p, c_int, c_char_p = ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p

AUTHORIZER = ctypes.CFUNCTYPE(c_int, c_void_p, c_int, c_char_p, c_char_p, c_char_p, c_char_p)
READ, INSERT, UPDATE, FUNCTION, TRANSACTION, PRAGMA = 20, 18, 23, 31, 22, 19

STATEMENTS = [
    b"SELECT a FROM t WHERE b > 1",
    b"SELECT count(*) FROM t",
    b"SELECT * FROM t",
    b"SELECT t.a, u.v FROM t JOIN u ON u.k = t.id",
    b"SELECT upper(a), (SELECT max(v) FROM u) FROM t",
    b"SELECT a FROM t ORDER BY b LIMIT 1",
    b"SELECT * FROM (SELECT a FROM t)",
    b"SELECT a FROM t WHERE id IN (SELECT k FROM u)",
    b"SELECT rowid FROM t",
    b"SELECT 1",
    b"INSERT INTO t (a, b) VALUES ('x', 1)",
    b"INSERT INTO u SELECT id, a FROM t",
    b"UPDATE t SET a = 'y', b = b + 1 WHERE id = 1",
    b"UPDATE t SET a = 'y'",
    b"DELETE FROM t WHERE b = 2",
    b"DELETE FROM u",
    b"CREATE TABLE w (x INTEGER)",
    b"CREATE VIEW vv AS SELECT a FROM t",
    b"CREATE INDEX tb ON t (b)",
    b"DROP TABLE u",
    b"BEGIN",
    b"COMMIT",
    b"SAVEPOINT s",
    b"RELEASE s",
    b"PRAGMA user_version",
    b"PRAGMA user_version = 3",
]


def observe(lib, seen: dict) -> None:
    lib.sqlite3_set_authorizer.argtypes = [c_void_p, c_void_p, c_void_p]
    lib.sqlite3_set_authorizer.restype = c_int
    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0
    for sql in (b"CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER)", b"CREATE TABLE u (k INTEGER, v TEXT)",
                b"INSERT INTO t (a, b) VALUES ('p', 1), ('q', 2)", b"INSERT INTO u VALUES (1, 'one')"):
        assert lib.sqlite3_exec(db, sql, None, None, None) == 0

    asked: list = []
    rule: dict = {}

    def authorize(arg, action, arg1, arg2, database, inner):
        asked.append((action, arg1, arg2, database))
        return rule.get((action, arg1, arg2), rule.get((action, arg1), rule.get(action, 0)))

    callback = AUTHORIZER(authorize)
    lib._authorizer_callback = callback
    assert lib.sqlite3_set_authorizer(db, ctypes.cast(callback, c_void_p), None) == 0

    def prepare(sql: bytes):
        stmt = c_void_p()
        code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
        return code, stmt

    def rows(sql: bytes):
        code, stmt = prepare(sql)
        out = []
        if code == 0:
            while lib.sqlite3_step(stmt) == 100:
                out.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
            lib.sqlite3_finalize(stmt)
        return code, lib.sqlite3_errmsg(db) if code else None, out

    def internal(question) -> bool:
        return any(isinstance(part, bytes) and part.startswith(b"sqlite_") for part in question[1:3])

    for sql in STATEMENTS:
        asked.clear()
        code, stmt = prepare(sql)
        lib.sqlite3_finalize(stmt)
        seen[f"authorizer asked for {sql!r}"] = (code, sorted({q for q in asked if not internal(q)}, key=repr))
    lib.sqlite3_exec(db, b"ROLLBACK", None, None, None)

    # What each answer does.
    rule.clear()
    rule[(READ, b"t", b"b")] = 1
    seen["deny a column: reading it"] = rows(b"SELECT a FROM t WHERE b > 1")[:2]
    seen["deny a column: not reading it"] = rows(b"SELECT a FROM t ORDER BY id")
    rule.clear()
    rule[(READ, b"t", b"b")] = 2
    seen["ignore a column"] = rows(b"SELECT a, b FROM t ORDER BY id")
    rule.clear()
    rule[(UPDATE, b"t", b"b")] = 2
    seen["ignore an assigned column"] = rows(b"UPDATE t SET a = 'z', b = 99 WHERE id = 1")
    rule.clear()
    seen["after it"] = rows(b"SELECT a, b FROM t WHERE id = 1")
    rule[(INSERT, b"t")] = 1
    seen["deny an insert"] = rows(b"INSERT INTO t (a, b) VALUES ('d', 5)")[:2]
    rule.clear()
    rule[(INSERT, b"t")] = 2
    seen["ignore an insert"] = rows(b"INSERT INTO t (a, b) VALUES ('i', 6)")
    rule.clear()
    seen["rows after both"] = rows(b"SELECT count(*) FROM t")
    rule[FUNCTION] = 1
    seen["deny functions"] = rows(b"SELECT upper(a) FROM t")[:2]
    rule.clear()
    rule[TRANSACTION] = 1
    seen["deny a transaction"] = rows(b"BEGIN")[:2]
    rule.clear()
    rule[PRAGMA] = 1
    seen["deny a pragma"] = rows(b"PRAGMA user_version")[:2]
    rule.clear()
    lib.sqlite3_set_authorizer(db, None, None)
    asked.clear()
    rows(b"SELECT a FROM t")
    seen["removed: nothing asked"] = list(asked)
    lib.sqlite3_close(db)
