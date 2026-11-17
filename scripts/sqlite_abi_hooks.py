"""Connection hooks, driven the same way through the facade and SQLite.

Every callback appends an event to one list, so what is compared is the order
and the content of what each library reported: the rows a statement changed,
the commits a hook saw (and vetoed), and the rollbacks. Used by
scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes

c_void_p, c_int, c_char_p, c_longlong = ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_longlong

COMMIT = ctypes.CFUNCTYPE(c_int, c_void_p)
ROLLBACK = ctypes.CFUNCTYPE(None, c_void_p)
UPDATE = ctypes.CFUNCTYPE(None, c_void_p, c_int, c_char_p, c_char_p, c_longlong)
PROGRESS = ctypes.CFUNCTYPE(c_int, c_void_p)

SIGNATURES = {
    "sqlite3_commit_hook": ([c_void_p, c_void_p, c_void_p], c_void_p),
    "sqlite3_rollback_hook": ([c_void_p, c_void_p, c_void_p], c_void_p),
    "sqlite3_update_hook": ([c_void_p, c_void_p, c_void_p], c_void_p),
    "sqlite3_progress_handler": ([c_void_p, c_int, c_void_p, c_void_p], None),
}


def bind(lib) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result


def observe(lib, db, seen: dict) -> None:
    events: list = []
    veto = [False]

    def on_commit(arg):
        events.append(("commit", arg))
        return 1 if veto[0] else 0

    def on_rollback(arg):
        events.append(("rollback", arg))

    def on_update(arg, op, database, table, rowid):
        events.append(("row", op, database, table, rowid))

    callbacks = (COMMIT(on_commit), ROLLBACK(on_rollback), UPDATE(on_update))
    lib._hook_callbacks = callbacks
    commit, rollback, update = (ctypes.cast(cb, c_void_p) for cb in callbacks)

    seen["first registrations answer NULL"] = (
        lib.sqlite3_commit_hook(db, commit, c_void_p(1)),
        lib.sqlite3_rollback_hook(db, rollback, c_void_p(2)),
        lib.sqlite3_update_hook(db, update, c_void_p(3)),
    )

    def run(label: str, sql: bytes) -> None:
        events.clear()
        code = lib.sqlite3_exec(db, sql, None, None, None)
        seen[f"hooks: {label}"] = (code, lib.sqlite3_errcode(db) if code else 0, list(events))

    run("create", b"CREATE TABLE h (id INTEGER PRIMARY KEY, v INTEGER)")
    run("insert two", b"INSERT INTO h (v) VALUES (10), (20)")
    run("update one", b"UPDATE h SET v = v + 1 WHERE id = 1")
    run("update none", b"UPDATE h SET v = 0 WHERE id = 99")
    run("delete one", b"DELETE FROM h WHERE id = 2")
    run("insert at id 7", b"INSERT INTO h (id, v) VALUES (7, 70)")
    run("begin, insert, rollback", b"BEGIN; INSERT INTO h (v) VALUES (30); ROLLBACK;")
    run("begin, insert, commit", b"BEGIN; INSERT INTO h (v) VALUES (40); COMMIT;")
    run("begin and commit, nothing written", b"BEGIN; COMMIT;")
    run("begin and rollback, nothing written", b"BEGIN; ROLLBACK;")
    run("a failing insert inside BEGIN", b"BEGIN; INSERT INTO h (id, v) VALUES (1, 0);")
    run("then rollback", b"ROLLBACK")
    run("a failing insert", b"INSERT INTO h (id, v) VALUES (1, 0)")
    run("replace a row", b"INSERT OR REPLACE INTO h (id, v) VALUES (1, 99)")
    run("no primary key", b"CREATE TABLE n (a TEXT); INSERT INTO n (a) VALUES ('x'), ('y');")
    run("delete with a WHERE", b"DELETE FROM n WHERE a = 'x'")

    veto[0] = True
    run("vetoed insert", b"INSERT INTO h (v) VALUES (50)")
    seen["vetoed: extended code"] = lib.sqlite3_extended_errcode(db)
    run("vetoed explicit commit", b"BEGIN; INSERT INTO h (v) VALUES (60); COMMIT;")
    veto[0] = False
    lib.sqlite3_exec(db, b"ROLLBACK", None, None, None)
    reader = c_void_p()
    lib.sqlite3_prepare_v2(db, b"SELECT count(*), sum(v) FROM h", -1, ctypes.byref(reader), None)
    lib.sqlite3_step(reader)
    seen["hooks: rows left"] = (lib.sqlite3_column_int64(reader, 0), lib.sqlite3_column_int64(reader, 1))
    lib.sqlite3_finalize(reader)

    seen["replacing answers the previous argument"] = (
        lib.sqlite3_commit_hook(db, None, None),
        lib.sqlite3_rollback_hook(db, None, None),
        lib.sqlite3_update_hook(db, None, None),
    )
    run("no hook left", b"BEGIN; INSERT INTO h (v) VALUES (1); ROLLBACK;")

    # The progress handler: called while a statement runs, a zero answer lets it
    # finish and a non-zero one interrupts it. How often it is called is not
    # compared: SQLite counts bytecode instructions, this engine rows.
    calls = [0]
    stop = [0]

    def on_progress(arg):
        calls[0] += 1
        return stop[0]

    progress = PROGRESS(on_progress)
    lib._progress_callback = progress
    lib.sqlite3_exec(db, b"CREATE TABLE p (x INTEGER)", None, None, None)
    values = b", ".join(b"(%d)" % i for i in range(1, 201))
    assert lib.sqlite3_exec(db, b"INSERT INTO p (x) VALUES " + values, None, None, None) == 0
    lib.sqlite3_progress_handler(db, 1, ctypes.cast(progress, c_void_p), None)
    code = lib.sqlite3_exec(db, b"SELECT count(*) FROM p WHERE x % 3 = 0", None, None, None)
    seen["progress: a handler that answers 0"] = (code, calls[0] > 0)
    stop[0] = 1
    calls[0] = 0
    code = lib.sqlite3_exec(db, b"SELECT count(*) FROM p WHERE x % 3 = 0", None, None, None)
    seen["progress: a handler that answers 1"] = (code, lib.sqlite3_errmsg(db), calls[0] > 0)
    stop[0] = 0
    code = lib.sqlite3_exec(db, b"SELECT count(*) FROM p", None, None, None)
    seen["progress: the next statement runs"] = code
    lib.sqlite3_progress_handler(db, 0, None, None)
    calls[0] = 0
    lib.sqlite3_exec(db, b"SELECT count(*) FROM p WHERE x % 3 = 0", None, None, None)
    seen["progress: removed"] = calls[0]
