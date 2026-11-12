#!/usr/bin/env python3
"""Smoke test for the sqlite3_* facade, driven through ctypes.

Run with a Python that can load the platform library:
    python scripts/sqlite_abi_smoke.py
"""
from __future__ import annotations
import ctypes, os, shutil, sys

OK, ERROR, ROW, DONE = 0, 1, 100, 101


def load(path):
    lib = ctypes.WinDLL(path) if os.name == "nt" else ctypes.CDLL(path)
    lib.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.sqlite3_open.restype = ctypes.c_int
    lib.sqlite3_close.argtypes = [ctypes.c_void_p]
    lib.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    lib.sqlite3_exec.restype = ctypes.c_int
    lib.sqlite3_prepare_v2.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
    lib.sqlite3_prepare_v2.restype = ctypes.c_int
    lib.sqlite3_step.argtypes = [ctypes.c_void_p]
    lib.sqlite3_step.restype = ctypes.c_int
    lib.sqlite3_finalize.argtypes = [ctypes.c_void_p]
    lib.sqlite3_column_count.argtypes = [ctypes.c_void_p]
    lib.sqlite3_column_count.restype = ctypes.c_int
    lib.sqlite3_column_name.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_name.restype = ctypes.c_char_p
    lib.sqlite3_column_int64.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_int64.restype = ctypes.c_longlong
    lib.sqlite3_column_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_text.restype = ctypes.c_char_p
    lib.sqlite3_bind_int64.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_longlong]
    lib.sqlite3_bind_text.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
    lib.sqlite3_errmsg.argtypes = [ctypes.c_void_p]
    lib.sqlite3_errmsg.restype = ctypes.c_char_p
    lib.sqlite3_changes.argtypes = [ctypes.c_void_p]
    lib.sqlite3_changes.restype = ctypes.c_int
    lib.sqlite3_libversion.restype = ctypes.c_char_p
    return lib


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("bin", "sqlite3_miraidb.dll")
    if not os.path.exists(path):
        print(f"library not found: {path}", file=sys.stderr)
        return 2
    lib = load(path)
    print("libversion:", lib.sqlite3_libversion().decode())

    db_path = os.path.join("bin", "sqlite_abi_smoke.db")
    if os.path.isdir(db_path):
        shutil.rmtree(db_path)
    elif os.path.exists(db_path):
        os.remove(db_path)

    db = ctypes.c_void_p()
    assert lib.sqlite3_open(db_path.encode(), ctypes.byref(db)) == OK, "open"
    assert lib.sqlite3_exec(db, b"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", None, None, None) == OK
    assert lib.sqlite3_changes(db) >= 0
    assert lib.sqlite3_exec(db, b"INSERT INTO t (name) VALUES ('Ada'), ('Grace')", None, None, None) == OK

    stmt = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"SELECT id, name FROM t ORDER BY id", -1, ctypes.byref(stmt), None) == OK
    assert lib.sqlite3_column_count(stmt) == 2, lib.sqlite3_column_count(stmt)
    assert lib.sqlite3_column_name(stmt, 1) == b"name"
    rows = []
    while True:
        state = lib.sqlite3_step(stmt)
        if state == DONE:
            break
        assert state == ROW, lib.sqlite3_errmsg(db)
        rows.append((lib.sqlite3_column_int64(stmt, 0), lib.sqlite3_column_text(stmt, 1).decode()))
    lib.sqlite3_finalize(stmt)
    assert rows == [(1, "Ada"), (2, "Grace")], rows

    insert = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"INSERT INTO t (name) VALUES (?)", -1, ctypes.byref(insert), None) == OK
    assert lib.sqlite3_bind_text(insert, 1, b"Lin", -1, None) == OK
    assert lib.sqlite3_step(insert) == DONE
    assert lib.sqlite3_finalize(insert) == OK
    assert lib.sqlite3_changes(db) == 1, lib.sqlite3_changes(db)

    # Incremental blob I/O: an open handle reads and patches one column.
    assert lib.sqlite3_exec(db, b"CREATE TABLE blobs (id INTEGER PRIMARY KEY, payload BLOB)", None, None, None) == OK
    assert lib.sqlite3_exec(db, b"INSERT INTO blobs (id, payload) VALUES (7, x'01020304')", None, None, None) == OK
    blob = ctypes.c_void_p()
    assert lib.sqlite3_blob_open(db, b"main", b"blobs", b"payload", 7, 0, ctypes.byref(blob)) == OK, lib.sqlite3_errmsg(db)
    assert lib.sqlite3_blob_bytes(blob) == 4
    buffer = ctypes.create_string_buffer(4)
    assert lib.sqlite3_blob_read(blob, buffer, 4, 0) == OK
    assert buffer.raw[:4] == b"\x01\x02\x03\x04", buffer.raw
    assert lib.sqlite3_blob_write(blob, b"\xff", 1, 2) == OK
    assert lib.sqlite3_blob_write(blob, b"\x00", 1, 4) == ERROR  # past the end
    assert lib.sqlite3_blob_close(blob) == OK
    check = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"SELECT hex(payload) FROM blobs WHERE id = 7", -1, ctypes.byref(check), None) == OK
    assert lib.sqlite3_step(check) == ROW, lib.sqlite3_errmsg(db)
    assert lib.sqlite3_column_text(check, 0) == b"0102FF04", lib.sqlite3_column_text(check, 0)
    lib.sqlite3_finalize(check)
    blobs_ok = True

    assert lib.sqlite3_exec(db, b"SELECT * FROM missing", None, None, None) == ERROR
    message = lib.sqlite3_errmsg(db).decode()
    assert "missing" in message, message
    assert lib.sqlite3_close(db) == OK
    print("rows:", rows)
    print("error path:", message)
    print("blob io:", blobs_ok)
    print("sqlite3_* smoke: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
