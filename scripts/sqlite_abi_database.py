"""The database as a whole, driven the same way through the facade and SQLite:
sqlite3_serialize and sqlite3_deserialize (an image taken from one connection
and given to another answers the same rows, views, triggers, AUTOINCREMENT
counter and user_version), sqlite3_backup_* (a copy replaces what the
destination held; the refusals SQLite makes when it starts), sqlite3_db_filename,
sqlite3_db_name, sqlite3_db_readonly, sqlite3_txn_state and sqlite3_close_v2.

Foreign keys too: off until PRAGMA foreign_keys = ON, then a violation is
SQLITE_CONSTRAINT_FOREIGNKEY with SQLite's words, and a key that names no
unique key of its parent is declared but fails with "foreign key mismatch".

The images themselves are not compared byte for byte: each library lays its own
pages out. What is compared is what reading them answers, and that each is a
whole number of 4096-byte pages.

Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes
import os
import tempfile

c_void_p, c_int, c_char_p, c_longlong, c_uint = (
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_longlong, ctypes.c_uint,
)

SIGNATURES = {
    "sqlite3_serialize": ([c_void_p, c_char_p, ctypes.POINTER(c_longlong), c_uint], c_void_p),
    "sqlite3_deserialize": ([c_void_p, c_char_p, c_void_p, c_longlong, c_longlong, c_uint], c_int),
    "sqlite3_backup_init": ([c_void_p, c_char_p, c_void_p, c_char_p], c_void_p),
    "sqlite3_backup_step": ([c_void_p, c_int], c_int),
    "sqlite3_backup_finish": ([c_void_p], c_int),
    "sqlite3_backup_remaining": ([c_void_p], c_int),
    "sqlite3_backup_pagecount": ([c_void_p], c_int),
    "sqlite3_db_filename": ([c_void_p, c_char_p], c_char_p),
    "sqlite3_db_name": ([c_void_p, c_int], c_char_p),
    "sqlite3_db_readonly": ([c_void_p, c_char_p], c_int),
    "sqlite3_txn_state": ([c_void_p, c_char_p], c_int),
    "sqlite3_close_v2": ([c_void_p], c_int),
    "sqlite3_extended_errcode": ([c_void_p], c_int),
    "sqlite3_extended_result_codes": ([c_void_p, c_int], c_int),
}

NOCOPY = 1
FREEONCLOSE, RESIZEABLE = 1, 2
ROW, DONE = 100, 101

SETUP = (
    b"CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);"
    b"CREATE TABLE log (m TEXT);"
    b"CREATE TABLE k (a TEXT PRIMARY KEY, b INTEGER UNIQUE);"
    b"CREATE INDEX k_b ON k (b);"
    b"INSERT INTO s (v) VALUES ('a'), ('b'), ('c');"
    b"DELETE FROM s WHERE id = 3;"
    b"INSERT INTO k VALUES ('x', 1), ('y', 2);"
    b"CREATE VIEW sv AS SELECT upper(v) AS u FROM s;"
    b"CREATE TRIGGER tr AFTER INSERT ON s BEGIN INSERT INTO log VALUES (new.v); END;"
    b"PRAGMA user_version = 31;"
)

# What a copy is asked once it lands, in this order.
PROBES = (
    b"SELECT group_concat(id || v, ',') FROM s",
    b"SELECT group_concat(u, ',') FROM sv",
    b"SELECT group_concat(a || b, ',') FROM k WHERE b > 0",
    b"PRAGMA user_version",
    b"INSERT INTO s (v) VALUES ('d')",
    b"SELECT max(id) FROM s",
    b"SELECT group_concat(m, ',') FROM log",
    b"SELECT count(*) FROM sqlite_master WHERE type IN ('view', 'trigger')",
    b"INSERT INTO k VALUES ('z', 2)",
)


def bind(lib) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result


def open_db(lib, path: bytes = b":memory:") -> c_void_p:
    db = c_void_p()
    assert lib.sqlite3_open(path, ctypes.byref(db)) == 0
    return db


def answers(lib, db, sql: bytes):
    """The rows a statement answers as text, or its error code and message."""
    stmt = c_void_p()
    code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
    if code:
        return code, lib.sqlite3_errmsg(db)
    rows = []
    while True:
        code = lib.sqlite3_step(stmt)
        if code != ROW:
            break
        rows.append(lib.sqlite3_column_text(stmt, 0))
    lib.sqlite3_finalize(stmt)
    return rows if code == DONE else (code, lib.sqlite3_errmsg(db))


def probe(lib, db) -> list:
    return [answers(lib, db, sql) for sql in PROBES]


def observe(lib, seen: dict) -> None:
    bind(lib)
    source = open_db(lib)
    assert lib.sqlite3_exec(source, SETUP, None, None, None) == 0

    # serialize: a whole number of pages, NULL for NOCOPY on a database kept
    # in pages and for a name the connection does not hold.
    size = c_longlong()
    image = lib.sqlite3_serialize(source, b"main", ctypes.byref(size), 0)
    seen["serialize"] = (image is not None, size.value > 0 and size.value % 4096 == 0)
    seen["serialize nocopy"] = lib.sqlite3_serialize(source, None, None, NOCOPY)
    seen["serialize of no such database"] = lib.sqlite3_serialize(source, b"nosuch", None, 0)
    empty = open_db(lib)
    empty_size = c_longlong()
    empty_image = lib.sqlite3_serialize(empty, None, ctypes.byref(empty_size), 0)
    # SQLite before 3.48 answers no page for a database nothing was written to,
    # and one page since; either is at most one.
    seen["serialize of an empty database"] = 0 <= empty_size.value <= 4096
    lib.sqlite3_free(empty_image)

    # deserialize: the image, handed over to be freed, answers what the source
    # does; a table the target had is gone.
    target = open_db(lib)
    assert lib.sqlite3_exec(target, b"CREATE TABLE gone (a)", None, None, None) == 0
    copy = lib.sqlite3_malloc(size.value)
    ctypes.memmove(copy, image, size.value)
    lib.sqlite3_free(image)
    seen["deserialize"] = lib.sqlite3_deserialize(target, b"main", copy, size.value, size.value, FREEONCLOSE | RESIZEABLE)
    seen["deserialized answers"] = probe(lib, target)
    seen["deserialized table gone"] = answers(lib, target, b"SELECT * FROM gone")
    seen["deserialize of no such database"] = lib.sqlite3_deserialize(target, b"nosuch", None, 0, 0, 0)
    seen["deserialize empty"] = (
        lib.sqlite3_deserialize(target, None, None, 0, 0, 0),
        answers(lib, target, b"SELECT count(*) FROM sqlite_master"),
    )
    # READONLY: reads answer, a write is SQLITE_READONLY; bytes that are not a
    # database are taken, and every statement after says so.
    image = lib.sqlite3_serialize(source, b"main", ctypes.byref(size), 0)
    copy = lib.sqlite3_malloc(size.value)
    ctypes.memmove(copy, image, size.value)
    lib.sqlite3_free(image)
    seen["deserialize readonly"] = (
        lib.sqlite3_deserialize(target, b"main", copy, size.value, size.value, FREEONCLOSE | 4),
        answers(lib, target, b"SELECT count(*) FROM k"),
        answers(lib, target, b"INSERT INTO k VALUES ('w', 9)"),
    )
    garbage = ctypes.create_string_buffer(b"not a database at all" * 50)
    # (A statement that reads no table, SELECT 1, runs in some SQLite
    # versions and not in others; one that reads the schema fails in all.)
    seen["deserialize of bytes that are no database"] = (
        lib.sqlite3_deserialize(target, b"main", garbage, len(garbage), len(garbage), 0),
        answers(lib, target, b"SELECT count(*) FROM sqlite_master"),
    )
    lib.sqlite3_close(target)

    # backup: what the destination held is replaced; a second step after the
    # last answers DONE again.
    dest = open_db(lib)
    assert lib.sqlite3_exec(dest, b"CREATE TABLE gone (a); INSERT INTO gone VALUES (1)", None, None, None) == 0
    backup = lib.sqlite3_backup_init(dest, b"main", source, b"main")
    steps = []
    while True:
        code = lib.sqlite3_backup_step(backup, -1)
        steps.append(code)
        if code != 0:
            break
    steps.append(lib.sqlite3_backup_step(backup, 5))
    seen["backup steps"] = (steps, lib.sqlite3_backup_remaining(backup), lib.sqlite3_backup_pagecount(backup) > 0)
    seen["backup finish"] = lib.sqlite3_backup_finish(backup)
    seen["backed up answers"] = probe(lib, dest)
    seen["backed up table gone"] = answers(lib, dest, b"SELECT * FROM gone")
    # A copy taken a few pages at a time ends the same way.
    paced = open_db(lib)
    backup = lib.sqlite3_backup_init(paced, b"main", source, b"main")
    codes = set()
    for _ in range(1000):
        code = lib.sqlite3_backup_step(backup, 1)
        codes.add(code)
        if code != 0:
            break
    seen["paced backup"] = (sorted(codes), lib.sqlite3_backup_remaining(backup), lib.sqlite3_backup_finish(backup))
    seen["paced answers"] = answers(lib, paced, b"SELECT group_concat(id || v, ',') FROM s")
    lib.sqlite3_close(paced)
    # The refusals at the start: the same connection, a name it does not hold.
    seen["backup into itself"] = (lib.sqlite3_backup_init(source, b"main", source, b"main"), lib.sqlite3_errmsg(source))
    seen["backup into no such database"] = (lib.sqlite3_backup_init(dest, b"nosuch", source, b"main"), lib.sqlite3_errmsg(dest))
    lib.sqlite3_close(dest)

    # The names a connection holds.
    seen["db_name"] = [lib.sqlite3_db_name(source, i) for i in (0, 1, 2, -1)]
    seen["db_filename in memory"] = (lib.sqlite3_db_filename(source, b"main"), lib.sqlite3_db_filename(source, None), lib.sqlite3_db_filename(source, b"nosuch"))
    seen["db_readonly"] = (lib.sqlite3_db_readonly(source, b"main"), lib.sqlite3_db_readonly(source, None), lib.sqlite3_db_readonly(source, b"nosuch"))
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "named.db")
        named = open_db(lib, path.encode())
        filename = lib.sqlite3_db_filename(named, b"main")
        seen["db_filename of a file"] = filename is not None and os.path.normcase(os.path.realpath(filename.decode())) == os.path.normcase(os.path.realpath(path))
        lib.sqlite3_close(named)

    # txn_state follows a deferred transaction: none at BEGIN, a read once a
    # table is read, a write once one is written.
    states = [lib.sqlite3_txn_state(source, None)]
    for sql in (b"BEGIN", b"SELECT count(*) FROM k", b"INSERT INTO log VALUES ('t')", b"COMMIT"):
        answers(lib, source, sql)
        states.append((lib.sqlite3_txn_state(source, None), lib.sqlite3_txn_state(source, b"main")))
    states.append(lib.sqlite3_txn_state(source, b"nosuch"))
    seen["txn_state"] = states

    # close_v2 with a statement still open: OK, the statement still runs, and
    # its finalize closes the connection.
    zombie = open_db(lib)
    stmt = c_void_p()
    assert lib.sqlite3_prepare_v2(zombie, b"SELECT 41 + 1", -1, ctypes.byref(stmt), None) == 0
    closed = lib.sqlite3_close_v2(zombie)
    stepped = lib.sqlite3_step(stmt)
    value = lib.sqlite3_column_int64(stmt, 0)
    seen["close_v2 with a statement open"] = (closed, stepped, value, lib.sqlite3_finalize(stmt))
    seen["close_v2"] = lib.sqlite3_close_v2(empty)
    lib.sqlite3_close(source)
    observe_foreign_keys(lib, seen)


def observe_foreign_keys(lib, seen: dict) -> None:
    db = open_db(lib)
    lib.sqlite3_extended_result_codes(db, 1)

    def run(sql: bytes):
        code = lib.sqlite3_exec(db, sql, None, None, None)
        return (code, lib.sqlite3_extended_errcode(db), lib.sqlite3_errmsg(db) if code else None)

    steps = [
        b"CREATE TABLE p (id INTEGER PRIMARY KEY, k)",
        b"CREATE TABLE c (pid INTEGER REFERENCES p(id), n)",
        b"CREATE TABLE p2 (id INTEGER PRIMARY KEY, k)",
        b"CREATE TABLE m (r REFERENCES p2(k))",
        b"INSERT INTO c VALUES (9, 1)",
        b"INSERT INTO m VALUES (1)",
        b"PRAGMA foreign_keys",
        b"PRAGMA foreign_keys = ON",
        b"PRAGMA foreign_keys",
        b"INSERT INTO c VALUES (8, 1)",
        b"INSERT INTO p VALUES (1, 1)",
        b"INSERT INTO c VALUES (1, 2)",
        b"DELETE FROM p WHERE id = 1",
        b"UPDATE p SET id = 5 WHERE id = 1",
        b"INSERT INTO m VALUES (1)",
        b"BEGIN",
        b"PRAGMA foreign_keys = OFF",
        b"COMMIT",
        b"INSERT INTO c VALUES (7, 3)",
        b"PRAGMA foreign_keys = OFF",
        b"INSERT INTO c VALUES (7, 3)",
    ]
    seen["foreign keys"] = [(step, run(step)) for step in steps]
    seen["foreign keys pragma"] = answers(lib, db, b"PRAGMA foreign_keys")
    lib.sqlite3_close(db)
