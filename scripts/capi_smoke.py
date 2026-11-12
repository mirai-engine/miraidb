#!/usr/bin/env python3
"""Smoke test for the C ABI, using ctypes as a generic C consumer.

Run it with a Python that can load the platform's shared library. On Windows:

    python scripts/capi_smoke.py

It opens a database, creates a table, binds parameters through the C functions,
reads rows back, and checks NULL handling and the error path.
"""

from __future__ import annotations

import ctypes
import os
import sys

OK, ERROR, ROW, DONE = 0, 1, 100, 101


def load(path: str):
    if os.name == "nt":
        lib = ctypes.WinDLL(path)
    else:
        lib = ctypes.CDLL(path)
    lib.miraidb_open.argtypes = [ctypes.c_char_p]
    lib.miraidb_open.restype = ctypes.c_void_p
    lib.miraidb_close.argtypes = [ctypes.c_void_p]
    lib.miraidb_errmsg.argtypes = [ctypes.c_void_p]
    lib.miraidb_errmsg.restype = ctypes.c_char_p
    lib.miraidb_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.miraidb_exec.restype = ctypes.c_int
    lib.miraidb_backup.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.miraidb_backup.restype = ctypes.c_int
    lib.miraidb_prepare.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.miraidb_prepare.restype = ctypes.c_void_p
    lib.miraidb_bind_int.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_longlong]
    lib.miraidb_bind_text.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    lib.miraidb_bind_null.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.miraidb_step.argtypes = [ctypes.c_void_p]
    lib.miraidb_step.restype = ctypes.c_int
    lib.miraidb_reset.argtypes = [ctypes.c_void_p]
    lib.miraidb_finalize.argtypes = [ctypes.c_void_p]
    lib.miraidb_column_count.argtypes = [ctypes.c_void_p]
    lib.miraidb_column_count.restype = ctypes.c_int
    lib.miraidb_column_name.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.miraidb_column_name.restype = ctypes.c_char_p
    lib.miraidb_column_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.miraidb_column_text.restype = ctypes.c_char_p
    lib.miraidb_column_int.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.miraidb_column_int.restype = ctypes.c_longlong
    lib.miraidb_column_is_null.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.miraidb_column_is_null.restype = ctypes.c_int
    lib.miraidb_version.restype = ctypes.c_char_p
    return lib


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("bin", "miraidb.dll")
    if not os.path.exists(path):
        print(f"library not found: {path}", file=sys.stderr)
        return 2
    lib = load(path)
    print("version:", lib.miraidb_version().decode())

    database = os.path.join("bin", "capi_smoke.db")
    for suffix in ("", "-log"):
        candidate = database + suffix
        if os.path.isdir(candidate):
            import shutil
            shutil.rmtree(candidate)
        elif os.path.exists(candidate):
            os.remove(candidate)

    db = lib.miraidb_open(database.encode())
    if not db:
        print("open failed", file=sys.stderr)
        return 1
    assert lib.miraidb_exec(db, b"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, note TEXT)") == OK
    stmt = lib.miraidb_prepare(db, b"INSERT INTO t (id, name, note) VALUES (?, ?, ?)")
    for i, name in ((1, b"Ada"), (2, b"Grace")):
        assert lib.miraidb_bind_int(stmt, 0, i) == OK
        assert lib.miraidb_bind_text(stmt, 1, name) == OK
        assert lib.miraidb_bind_null(stmt, 2) == OK
        assert lib.miraidb_step(stmt) == DONE
        lib.miraidb_reset(stmt)
    lib.miraidb_finalize(stmt)

    query = lib.miraidb_prepare(db, b"SELECT id, name, note FROM t ORDER BY id")
    assert lib.miraidb_column_count(query) >= 0
    rows = []
    while True:
        state = lib.miraidb_step(query)
        if state == DONE:
            break
        assert state == ROW, lib.miraidb_errmsg(db)
        rows.append((
            lib.miraidb_column_int(query, 0),
            lib.miraidb_column_text(query, 1).decode(),
            lib.miraidb_column_is_null(query, 2),
        ))
    lib.miraidb_finalize(query)
    assert rows == [(1, "Ada", 1), (2, "Grace", 1)], rows

    # A backup is a compacted copy that opens as a database of its own.
    import shutil
    backup = os.path.join("bin", "capi_smoke_backup")
    shutil.rmtree(backup, ignore_errors=True)
    assert lib.miraidb_backup(db, backup.encode()) == OK, lib.miraidb_errmsg(db)
    copy_db = lib.miraidb_open(backup.encode())
    assert copy_db, lib.miraidb_errmsg(db)
    count = lib.miraidb_prepare(copy_db, b"SELECT count(*) FROM t")
    assert lib.miraidb_step(count) == ROW
    assert lib.miraidb_column_int(count, 0) == 2
    lib.miraidb_finalize(count)
    lib.miraidb_close(copy_db)
    shutil.rmtree(backup, ignore_errors=True)

    # The error path reports a message instead of crashing.
    assert lib.miraidb_exec(db, b"SELECT * FROM missing") == ERROR
    message = lib.miraidb_errmsg(db).decode()
    assert "missing" in message, message
    lib.miraidb_close(db)
    print("rows:", rows)
    print("error path:", message)
    print("capi smoke: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
