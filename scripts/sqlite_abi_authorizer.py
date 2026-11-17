"""sqlite3_set_authorizer, driven the same way through the facade and SQLite.

Two things are compared. The questions: for each statement, the set of
(action, arg1, arg2, database, trigger or view) the authorizer is asked while
the statement is prepared, the bodies of the views it reads and of the
triggers it fires included. Their order is SQLite's compiler's, so it is not compared, and the
questions SQLite asks about its own tables (sqlite_master, sqlite_stat1) have
no counterpart in this engine and are left out. And the answers: what DENY and
IGNORE do to a read (through a name, `*` and a view), an assignment, an
insert, a function, a transaction and a pragma. Used by scripts/sqlite_abi_reference.py.
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
    b"SELECT * FROM vv",
    b"SELECT a FROM vv",
    b"SELECT count(*) FROM vv",
    b"SELECT * FROM t JOIN u ON u.k = t.id",
    b"SELECT u.* FROM t, u",
    b"WITH c AS (SELECT a, b FROM t) SELECT * FROM c WHERE b > 0",
    b"SELECT x.a FROM (SELECT a FROM t) AS x",
    b"DELETE FROM log",
    b"INSERT INTO t (a, b) VALUES ('x', 1)",
    b"INSERT INTO u SELECT id, a FROM t",
    b"UPDATE t SET a = 'y', b = b + 1 WHERE id = 1",
    b"UPDATE t SET a = 'y'",
    b"UPDATE t SET b = 0 WHERE id = 2",
    b"DELETE FROM t WHERE b = 2",
    b"DELETE FROM u",
    b"CREATE TABLE w (x INTEGER)",
    b"CREATE VIEW vw AS SELECT a FROM t",
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
                b"CREATE TABLE log (x TEXT)", b"CREATE VIEW vv AS SELECT a, b FROM t WHERE b > 0",
                b"CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.a); END",
                b"CREATE TRIGGER tu AFTER UPDATE ON t WHEN new.b > 0 BEGIN UPDATE u SET v = new.a WHERE k = old.id; END",
                b"CREATE TRIGGER td BEFORE DELETE ON log BEGIN SELECT old.x; END",
                b"INSERT INTO t (a, b) VALUES ('p', 1), ('q', 2)", b"INSERT INTO u VALUES (1, 'one')"):
        assert lib.sqlite3_exec(db, sql, None, None, None) == 0

    asked: list = []
    rule: dict = {}

    def authorize(arg, action, arg1, arg2, database, inner):
        asked.append((action, arg1, arg2, database, inner))
        return rule.get((action, arg1, arg2, inner),
                        rule.get((action, arg1, arg2), rule.get((action, arg1), rule.get(action, 0))))

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
            out.append(tuple(lib.sqlite3_column_name(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
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
    seen["ignore a column through *"] = rows(b"SELECT * FROM t ORDER BY id")
    seen["ignore a column through t.*"] = rows(b"SELECT t.*, u.v FROM t JOIN u ON u.k = t.id")
    seen["ignore a column inside a view"] = rows(b"SELECT * FROM vv")
    seen["ignore a column through a CTE"] = rows(b"WITH c AS (SELECT * FROM t) SELECT * FROM c ORDER BY id")
    rule.clear()
    rule[(READ, b"vv", b"a")] = 2
    seen["ignore a column of a view"] = rows(b"SELECT a, b FROM vv ORDER BY b")
    rule.clear()
    rule[(READ, b"t", b"a", b"vv")] = 1
    seen["deny a column inside a view"] = rows(b"SELECT b FROM vv")[:2]
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
    # Inside a trigger's body: what the answers do each time it fires.
    rule[(READ, b"t", b"a", b"tr")] = 2
    rows(b"INSERT INTO t (a, b) VALUES ('w', 7)")
    rule.clear()
    rule[(INSERT, b"log", None, b"tr")] = 2
    rows(b"INSERT INTO t (a, b) VALUES ('v', 8)")
    rule.clear()
    seen["ignore inside a trigger"] = rows(b"SELECT x FROM log ORDER BY rowid")
    rule[(READ, b"t", b"b", b"tu")] = 2
    rows(b"UPDATE t SET a = 'when', b = 9 WHERE id = 1")
    rule.clear()
    seen["ignore in a trigger's WHEN"] = rows(b"SELECT k, v FROM u")
    rule[(READ, b"t", b"a", b"tr")] = 1
    seen["deny inside a trigger"] = rows(b"INSERT INTO t (a, b) VALUES ('d', 1)")[:2]
    rule.clear()
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
