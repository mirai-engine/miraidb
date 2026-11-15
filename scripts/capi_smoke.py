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

OK, ERROR, MISUSE, DENIED, ROW, DONE = 0, 1, 2, 3, 100, 101


def load(path: str):
    if os.name == "nt":
        lib = ctypes.WinDLL(path)
    else:
        lib = ctypes.CDLL(path)
    lib.miraidb_open.argtypes = [ctypes.c_char_p]
    lib.miraidb_open.restype = ctypes.c_void_p
    lib.miraidb_open_ex.argtypes = [ctypes.c_char_p, ctypes.c_int]
    lib.miraidb_open_ex.restype = ctypes.c_void_p
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
    for name in ("miraidb_set_row_quota", "miraidb_set_work_budget"):
        function = getattr(lib, name)
        function.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
        function.restype = ctypes.c_int
    lib.miraidb_work_used.argtypes = [ctypes.c_void_p]
    lib.miraidb_work_used.restype = ctypes.c_ulonglong
    lib.miraidb_interrupt.argtypes = [ctypes.c_void_p]
    lib.miraidb_interrupt.restype = ctypes.c_int
    lib.miraidb_set_identity.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.miraidb_set_identity.restype = ctypes.c_int
    lib.miraidb_identity.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.miraidb_identity.restype = ctypes.c_int
    lib.miraidb_issue_token.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_longlong, ctypes.c_char_p, ctypes.c_ulonglong,
    ]
    lib.miraidb_issue_token.restype = ctypes.c_int
    lib.miraidb_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.miraidb_authenticate.restype = ctypes.c_int
    return lib


def scalar(lib, db, sql: bytes) -> int:
    """The first integer of a one-row, one-column query, through the C ABI."""
    stmt = lib.miraidb_prepare(db, sql)
    assert stmt, lib.miraidb_errmsg(db)
    assert lib.miraidb_step(stmt) == ROW, lib.miraidb_errmsg(db)
    value = lib.miraidb_column_int(stmt, 0)
    lib.miraidb_finalize(stmt)
    return value


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

    # An in-memory database through the C ABI, in the spellings SQLite accepts
    # (D28): the connection answers and writes without a directory.
    for spelling in (b":memory:", b"", b"file::memory:?cache=shared"):
        memory = lib.miraidb_open(spelling)
        assert memory, f"open {spelling!r}"
        assert lib.miraidb_exec(memory, b"CREATE TABLE m (id INTEGER)") == OK
        assert lib.miraidb_exec(memory, b"INSERT INTO m (id) VALUES (5)") == OK
        probe = lib.miraidb_prepare(memory, b"SELECT id FROM m")
        assert lib.miraidb_step(probe) == ROW, "an in-memory row is readable"
        assert lib.miraidb_column_int(probe, 0) == 5
        lib.miraidb_finalize(probe)
        lib.miraidb_close(memory)
    assert not os.path.exists(":memory:"), "the :memory: spelling made a directory"

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

    # Open flags (D25): a reader refuses every write and says why, an in-memory
    # database leaves nothing behind, and miraidb_open is this call with no flags.
    import shutil
    flags_path = os.path.join("bin", "capi_smoke_flags")
    shutil.rmtree(flags_path, ignore_errors=True)
    writer = ctypes.c_void_p(lib.miraidb_open(flags_path.encode()))
    assert writer
    assert lib.miraidb_exec(writer, b"CREATE TABLE f (id INTEGER PRIMARY KEY)") == OK
    assert lib.miraidb_exec(writer, b"INSERT INTO f VALUES (1)") == OK
    lib.miraidb_close(writer)
    assert os.path.exists(os.path.join(flags_path, "lock")), "a writer leaves a database behind"
    reader = ctypes.c_void_p(lib.miraidb_open_ex(flags_path.encode(), 1))
    assert reader, lib.miraidb_errmsg(None)
    assert lib.miraidb_exec(reader, b"SELECT count(*) FROM f") == OK
    assert lib.miraidb_exec(reader, b"INSERT INTO f VALUES (2)") == ERROR
    assert "read transaction" in lib.miraidb_errmsg(reader).decode()
    lib.miraidb_close(reader)
    memory = ctypes.c_void_p(lib.miraidb_open_ex(b"", 2))
    assert memory
    assert lib.miraidb_exec(memory, b"CREATE TABLE m (id INTEGER PRIMARY KEY)") == OK
    assert lib.miraidb_exec(memory, b"INSERT INTO m VALUES (1)") == OK
    lib.miraidb_close(memory)
    shutil.rmtree(flags_path, ignore_errors=True)

    # A handle is not permission to read freed memory (D29). Every call through a
    # finalized statement answers MIRAIDB_MISUSE, a double finalize does nothing,
    # a bind outside the statement's parameters is refused, and closing a
    # connection with a statement open turns that statement into misuse. None of
    # this may end the process, which is what the last of these used to do.
    lib.miraidb_bind_int.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_longlong]
    lib.miraidb_bind_int.restype = ctypes.c_int
    lib.miraidb_reset.restype = None
    lib.miraidb_finalize.restype = None
    lib.miraidb_column_int.restype = ctypes.c_longlong

    doomed = lib.miraidb_prepare(db, b"INSERT INTO t (id, name) VALUES (?, ?)")
    assert doomed
    assert lib.miraidb_bind_int(doomed, 0, 9) == OK
    assert lib.miraidb_bind_text(doomed, 1, b"n") == OK
    assert lib.miraidb_bind_int(doomed, 5, 1) == ERROR, "an index past the parameters is refused"
    lib.miraidb_finalize(doomed)
    assert lib.miraidb_step(doomed) == MISUSE
    assert lib.miraidb_bind_text(doomed, 0, b"x") == MISUSE
    lib.miraidb_reset(doomed)
    assert lib.miraidb_column_int(doomed, 0) == 0
    lib.miraidb_finalize(doomed)  # a second finalize must not crash
    assert "closed" in lib.miraidb_errmsg(None).decode()

    orphan_db = lib.miraidb_open(b":memory:")
    assert orphan_db
    orphan = lib.miraidb_prepare(orphan_db, b"SELECT 1")
    assert orphan
    lib.miraidb_close(orphan_db)
    assert lib.miraidb_step(orphan) == MISUSE, "a statement of a closed connection is misuse"
    lib.miraidb_finalize(orphan)

    # The two caps D23 built are reachable from C, and the message names which one
    # was hit. A cap is a session property: setting it back to zero restores the
    # statement, and work_used reports what this connection has spent.
    assert lib.miraidb_set_row_quota(db, 1) == OK
    assert lib.miraidb_exec(db, b"SELECT * FROM t") == ERROR
    assert "more than 1 rows" in lib.miraidb_errmsg(db).decode()
    assert lib.miraidb_set_row_quota(db, 0) == OK
    assert lib.miraidb_exec(db, b"SELECT * FROM t") == OK

    assert lib.miraidb_set_work_budget(db, 1) == OK
    assert lib.miraidb_exec(db, b"SELECT * FROM t") == ERROR
    assert "budget is 1" in lib.miraidb_errmsg(db).decode()
    assert lib.miraidb_work_used(db) > 0
    assert lib.miraidb_set_work_budget(db, 0) == OK

    # Interrupt asks a running statement to stop. The flag belongs to that
    # statement: the next one starts clean, so the connection stays usable, and a
    # dead handle answers MIRAIDB_MISUSE instead of touching freed memory.
    assert lib.miraidb_interrupt(db) == OK
    assert lib.miraidb_exec(db, b"SELECT count(*) FROM t") == OK

    # Identity and credentials (D25). A policy filters by the identity the
    # connection carries; a token names that identity to a connection that has not
    # set one yet; and an expired token is refused without changing who the caller
    # was. The identity is 32 bytes, not text: two different callers must not see
    # each other's rows.
    import shutil
    ana = bytes(range(32))
    luis = bytes(range(32, 64))
    identity_db = os.path.join("bin", "capi_identity")
    shutil.rmtree(identity_db, ignore_errors=True)
    auth = ctypes.c_void_p(lib.miraidb_open(identity_db.encode()))
    assert auth
    assert lib.miraidb_exec(auth, b"CREATE TABLE doc (id INTEGER PRIMARY KEY, owner IDENTITY NOT NULL, body TEXT)") == OK
    assert lib.miraidb_exec(auth, b"CREATE POLICY own ON doc USING (owner = current_identity())") == OK
    for who, value in ((ana, b"a"), (luis, b"b")):
        assert lib.miraidb_set_identity(auth, who) == OK
        stmt = lib.miraidb_prepare(auth, b"INSERT INTO doc (id, owner, body) VALUES (?, current_identity(), ?)")
        assert stmt, lib.miraidb_errmsg(auth)
        assert lib.miraidb_bind_int(stmt, 0, 1 if who == ana else 2) == OK
        assert lib.miraidb_bind_text(stmt, 1, value) == OK
        assert lib.miraidb_step(stmt) == DONE, lib.miraidb_errmsg(auth)
        lib.miraidb_finalize(stmt)
    seen = ctypes.create_string_buffer(32)
    assert lib.miraidb_identity(auth, seen) == 32
    assert seen.raw == luis, "identity reads back the bytes that were set"
    assert scalar(lib, auth, b"SELECT count(*) FROM doc") == 1
    assert lib.miraidb_set_identity(auth, ana) == OK
    assert scalar(lib, auth, b"SELECT count(*) FROM doc") == 1
    body = lib.miraidb_prepare(auth, b"SELECT body FROM doc")
    assert lib.miraidb_step(body) == ROW
    assert lib.miraidb_column_text(body, 0) == b"a", "a caller sees its own row"
    lib.miraidb_finalize(body)

    token = ctypes.create_string_buffer(128)
    issued = lib.miraidb_issue_token(auth, ana, 0, token, len(token))
    assert issued == 67, issued
    assert token.value.startswith(b"mt_")
    assert lib.miraidb_issue_token(auth, ana, 0, token, 10) == -1, "a short buffer is refused"
    ana_token = token.value
    expired = ctypes.create_string_buffer(128)
    assert lib.miraidb_issue_token(auth, luis, -1, expired, len(expired)) == 67
    lib.miraidb_close(auth)

    # A connection that has not authenticated carries the all-zero identity, so a
    # policy that compares against current_identity() matches nothing: the embedded
    # path is the server's path, not a privileged one.
    again = ctypes.c_void_p(lib.miraidb_open(identity_db.encode()))
    assert again, lib.miraidb_errmsg(None)
    assert scalar(lib, again, b"SELECT count(*) FROM doc") == 0, "no identity, no rows"
    assert lib.miraidb_authenticate(again, expired.value) == DENIED
    assert "expired" in lib.miraidb_errmsg(again).decode()
    assert scalar(lib, again, b"SELECT count(*) FROM doc") == 0, "a refused token changes nobody"
    assert lib.miraidb_authenticate(again, ana_token) == OK, lib.miraidb_errmsg(again)
    seen = ctypes.create_string_buffer(32)
    assert lib.miraidb_identity(again, seen) == 32
    assert seen.raw == ana, "the token names the identity it was issued for"
    assert scalar(lib, again, b"SELECT count(*) FROM doc") == 1
    assert lib.miraidb_authenticate(again, b"mt_00") == DENIED
    lib.miraidb_close(again)
    shutil.rmtree(identity_db, ignore_errors=True)

    # The error path reports a message instead of crashing.
    assert lib.miraidb_exec(db, b"SELECT * FROM missing") == ERROR
    message = lib.miraidb_errmsg(db).decode()
    assert "missing" in message, message
    lib.miraidb_close(db)
    assert lib.miraidb_set_row_quota(db, 5) == MISUSE, "a dead handle is misuse"
    assert lib.miraidb_interrupt(db) == MISUSE
    print("rows:", rows)
    print("error path:", message)
    print("capi smoke: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
