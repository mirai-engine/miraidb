#!/usr/bin/env python3
"""Smoke test for the sqlite3_* facade, driven through ctypes.

Run with a Python that can load the platform library:
    python scripts/sqlite_abi_smoke.py
"""
from __future__ import annotations
import ctypes, os, shutil, sqlite3, sys

OK, ERROR, CONSTRAINT, MISUSE, ROW, DONE, RANGE = 0, 1, 19, 21, 100, 101, 25


def load(path):
    lib = ctypes.WinDLL(path) if os.name == "nt" else ctypes.CDLL(path)
    lib.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.sqlite3_open.restype = ctypes.c_int
    lib.sqlite3_close.argtypes = [ctypes.c_void_p]
    lib.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    lib.sqlite3_exec.restype = ctypes.c_int
    lib.sqlite3_prepare_v2.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_char_p)]
    lib.sqlite3_prepare_v2.restype = ctypes.c_int
    lib.sqlite3_step.argtypes = [ctypes.c_void_p]
    lib.sqlite3_step.restype = ctypes.c_int
    lib.sqlite3_exec.restype = ctypes.c_int
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
    lib.sqlite3_reset.argtypes = [ctypes.c_void_p]
    lib.sqlite3_reset.restype = ctypes.c_int
    lib.sqlite3_clear_bindings.argtypes = [ctypes.c_void_p]
    lib.sqlite3_clear_bindings.restype = ctypes.c_int
    lib.sqlite3_bind_int.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    lib.sqlite3_bind_int.restype = ctypes.c_int
    lib.sqlite3_column_bytes.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_bytes.restype = ctypes.c_int
    lib.sqlite3_column_double.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_double.restype = ctypes.c_double
    lib.sqlite3_column_type.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_type.restype = ctypes.c_int
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

    # A SQLite program starts with an in-memory database more often than not, and
    # every spelling has to open or the program cannot start (D28).
    for spelling in (b":memory:", b"", b"file::memory:", b"file::memory:?cache=shared",
                     b"file:memdb1?mode=memory&cache=shared"):
        memory = ctypes.c_void_p()
        assert lib.sqlite3_open(spelling, ctypes.byref(memory)) == OK, f"open {spelling!r}"
        assert lib.sqlite3_exec(memory, b"CREATE TABLE m (id INTEGER)", None, None, None) == OK
        assert lib.sqlite3_exec(memory, b"INSERT INTO m (id) VALUES (7)", None, None, None) == OK
        check = ctypes.c_void_p()
        assert lib.sqlite3_prepare_v2(memory, b"SELECT id FROM m", -1, ctypes.byref(check), None) == OK
        assert lib.sqlite3_step(check) == ROW
        assert lib.sqlite3_column_int64(check, 0) == 7
        lib.sqlite3_finalize(check)
        assert lib.sqlite3_close(memory) == OK
    assert not os.path.exists(":memory:"), "the :memory: spelling made a directory"

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

    # The mirror survives DDL. The facade opens a real SQLite file, imports it,
    # and every commit patches the file back; a schema change takes the full
    # rewrite, which is the path that used to leave the file malformed for
    # SQLite when the dropped table held rows. The file is created and verified
    # by Python's sqlite3, so the check is against a second implementation.
    mirror_path = os.path.join("bin", "sqlite_abi_mirror.sqlite")
    for stale in (mirror_path, mirror_path + "-journal"):
        if os.path.exists(stale):
            os.remove(stale)
    seed = sqlite3.connect(mirror_path)
    seed.executescript(
        "CREATE TABLE keep (id INTEGER PRIMARY KEY, v TEXT);"
        "CREATE INDEX keep_v ON keep (v);"
        "CREATE TABLE gone (id INTEGER PRIMARY KEY, w TEXT);"
        "INSERT INTO keep (id, v) VALUES (1, 'a'), (2, 'b');"
        "INSERT INTO gone (id, w) VALUES (1, 'x'), (2, 'y'), (3, 'z');"
    )
    seed.commit()
    seed.close()

    mirrored = ctypes.c_void_p()
    assert lib.sqlite3_open(mirror_path.encode(), ctypes.byref(mirrored)) == OK, "open mirror"
    ddl = [
        b"DROP TABLE gone",
        b"ALTER TABLE keep ADD COLUMN extra INTEGER",
        b"INSERT INTO keep (id, v, extra) VALUES (3, 'c', 7)",
        b"DROP INDEX keep_v",
        b"CREATE INDEX keep_extra ON keep (extra)",
    ]
    for statement in ddl:
        code = lib.sqlite3_exec(mirrored, statement, None, None, None)
        assert code == OK, (statement, lib.sqlite3_errmsg(mirrored))
    assert lib.sqlite3_close(mirrored) == OK

    check_file = sqlite3.connect(mirror_path)
    integrity = check_file.execute("PRAGMA integrity_check").fetchone()[0]
    assert integrity == "ok", integrity
    rows_after = check_file.execute("SELECT id, v, extra FROM keep ORDER BY id").fetchall()
    assert rows_after == [(1, "a", None), (2, "b", None), (3, "c", 7)], rows_after
    objects = dict(check_file.execute("SELECT name, type FROM sqlite_master WHERE type IN ('table','index')"))
    assert "gone" not in objects, objects
    assert objects.get("keep_extra") == "index", objects
    assert "keep_v" not in objects, objects
    check_file.close()

    # D27: a rewrite keeps what it was not asked to change. A DDL on one table
    # used to re-emit every table from the engine's model, so REFERENCES,
    # UNIQUE, CHECK, DEFAULT, COLLATE, views and triggers disappeared from the
    # user's file. Now only the table the DDL touched is rebuilt.
    keep_path = os.path.join("bin", "sqlite_abi_keep.sqlite")
    if os.path.exists(keep_path):
        os.remove(keep_path)
    seed = sqlite3.connect(keep_path)
    seed.executescript(
        "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT);"
        "CREATE TABLE child (id INTEGER PRIMARY KEY,"
        " pid INTEGER NOT NULL REFERENCES parent(id) ON DELETE CASCADE,"
        " note TEXT DEFAULT 'n' COLLATE NOCASE,"
        " flag INTEGER CHECK (flag IN (0, 1)));"
        "INSERT INTO parent (id, name) VALUES (1, 'a');"
        "INSERT INTO child (id, pid, flag) VALUES (1, 1, 1);"
        "CREATE TABLE keyed (code TEXT PRIMARY KEY, v INTEGER);"
        "CREATE TABLE tagged (id INTEGER PRIMARY KEY, tag TEXT UNIQUE, n INTEGER);"
        "CREATE TABLE paired (a TEXT, b TEXT, UNIQUE (a, b));"
        "INSERT INTO keyed (code, v) VALUES ('a', 1);"
        "INSERT INTO tagged (id, tag, n) VALUES (1, 'x', 2);"
        "INSERT INTO paired (a, b) VALUES ('p', 'q');"
        "CREATE VIEW child_view AS SELECT id FROM child;"
        "CREATE TRIGGER child_touch AFTER INSERT ON child BEGIN SELECT 1; END;"
    )
    seed.commit()
    child_sql = seed.execute("SELECT sql FROM sqlite_master WHERE name = 'child'").fetchone()[0]
    # The tables whose declaration SQLite backs with an automatic index: the text
    # must come back exactly as it was, with the indexes numbered as it numbers
    # them (D27).
    keyed_before = list(
        seed.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master"
            " WHERE tbl_name IN ('keyed', 'tagged', 'paired') ORDER BY name"
        )
    )
    seed.close()

    keeper = ctypes.c_void_p()
    assert lib.sqlite3_open(keep_path.encode(), ctypes.byref(keeper)) == OK, "open keeper"
    assert lib.sqlite3_exec(keeper, b"ALTER TABLE parent ADD COLUMN extra INTEGER", None, None, None) == OK
    assert lib.sqlite3_close(keeper) == OK

    kept = sqlite3.connect(keep_path)
    assert kept.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert kept.execute("SELECT sql FROM sqlite_master WHERE name = 'child'").fetchone()[0] == child_sql, (
        "the table the DDL did not touch kept its text"
    )
    rules = kept.execute("PRAGMA foreign_key_list(child)").fetchall()
    assert len(rules) == 1 and rules[0][2] == "parent", rules
    assert kept.execute("SELECT name FROM sqlite_master WHERE type = 'view'").fetchall() == [("child_view",)]
    assert kept.execute("SELECT name FROM sqlite_master WHERE type = 'trigger'").fetchall() == [("child_touch",)]
    columns = [row[1] for row in kept.execute("PRAGMA table_info(parent)").fetchall()]
    assert columns == ["id", "name", "extra"], columns
    keyed_after = list(
        kept.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master"
            " WHERE tbl_name IN ('keyed', 'tagged', 'paired') ORDER BY name"
        )
    )
    assert keyed_after == keyed_before, (keyed_before, keyed_after)
    for statement, message in (
        ("INSERT INTO keyed (code, v) VALUES ('a', 9)", "keyed.code"),
        ("INSERT INTO tagged (id, tag, n) VALUES (2, 'x', 0)", "tagged.tag"),
        ("INSERT INTO paired (a, b) VALUES ('p', 'q')", "paired"),
    ):
        try:
            kept.execute(statement)
        except sqlite3.IntegrityError:
            continue
        raise AssertionError("%s was accepted by SQLite after the DDL" % message)
    kept.close()

    # The same rewrite with nothing left: dropping the last table leaves a valid,
    # empty database rather than a file whose sqlite_master has no b-tree.
    empty_path = os.path.join("bin", "sqlite_abi_empty.sqlite")
    if os.path.exists(empty_path):
        os.remove(empty_path)
    seed = sqlite3.connect(empty_path)
    seed.executescript("CREATE TABLE only_one (id INTEGER PRIMARY KEY); INSERT INTO only_one VALUES (1), (2);")
    seed.commit()
    seed.close()
    emptied = ctypes.c_void_p()
    assert lib.sqlite3_open(empty_path.encode(), ctypes.byref(emptied)) == OK
    assert lib.sqlite3_exec(emptied, b"DROP TABLE only_one", None, None, None) == OK, lib.sqlite3_errmsg(emptied)
    assert lib.sqlite3_close(emptied) == OK
    empty_check = sqlite3.connect(empty_path)
    empty_integrity = empty_check.execute("PRAGMA integrity_check").fetchone()[0]
    remaining = empty_check.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]
    empty_check.close()
    assert empty_integrity == "ok", empty_integrity
    assert remaining == 0, remaining

    # A failure carries the result code SQLite uses for it (D25): a duplicate is
    # SQLITE_CONSTRAINT (19), a syntax error is SQLITE_ERROR (1), errcode agrees
    # with what step returned, and an interrupt ends the running statement
    # without poisoning the connection.
    coded = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(coded)) == OK
    lib.sqlite3_exec.restype = ctypes.c_int
    lib.sqlite3_errcode.restype = ctypes.c_int
    lib.sqlite3_errcode.argtypes = [ctypes.c_void_p]
    assert lib.sqlite3_exec(coded, b"CREATE TABLE c (id INTEGER PRIMARY KEY, s TEXT UNIQUE)", None, None, None) == OK
    assert lib.sqlite3_exec(coded, b"INSERT INTO c VALUES (1, 'a')", None, None, None) == OK
    assert lib.sqlite3_exec(coded, b"INSERT INTO c VALUES (2, 'a')", None, None, None) == CONSTRAINT, "a duplicate key is a constraint"
    assert lib.sqlite3_errcode(coded) == CONSTRAINT, "errcode names the same condition"
    assert lib.sqlite3_exec(coded, b"INSERT INTO c VALUES (3, 'b')", None, None, None) == OK
    assert lib.sqlite3_errcode(coded) == OK
    assert lib.sqlite3_exec(coded, b"SELECT (((", None, None, None) == ERROR, "a syntax error is a plain error"
    assert lib.sqlite3_errcode(coded) == ERROR
    lib.sqlite3_interrupt.argtypes = [ctypes.c_void_p]
    lib.sqlite3_interrupt(coded)
    assert lib.sqlite3_exec(coded, b"SELECT count(*) FROM c", None, None, None) == OK, "an interrupted connection still works"

    # Extended result codes (D25): with the mode on, the same failure answers the
    # narrow code, so a caller learns which constraint failed without parsing the
    # message, and extended_errcode answers it either way. SQLite's numbers:
    # unique 2067, primary key 1555, not null 1299.
    lib.sqlite3_extended_result_codes.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_extended_result_codes.restype = ctypes.c_int
    lib.sqlite3_extended_errcode.argtypes = [ctypes.c_void_p]
    lib.sqlite3_extended_errcode.restype = ctypes.c_int
    UNIQUE, PRIMARYKEY, NOTNULL = 2067, 1555, 1299
    assert lib.sqlite3_extended_result_codes(coded, 1) == OK
    assert lib.sqlite3_exec(coded, b"INSERT INTO c VALUES (2, 'a')", None, None, None) == UNIQUE
    assert lib.sqlite3_errcode(coded) == UNIQUE, "in extended mode errcode is narrow"
    assert lib.sqlite3_extended_errcode(coded) == UNIQUE
    assert lib.sqlite3_exec(coded, b"INSERT INTO c VALUES (1, 'z')", None, None, None) == PRIMARYKEY
    assert lib.sqlite3_exec(coded, b"CREATE TABLE n (id INTEGER PRIMARY KEY, v TEXT NOT NULL)", None, None, None) == OK
    assert lib.sqlite3_exec(coded, b"INSERT INTO n (id, v) VALUES (1, NULL)", None, None, None) == NOTNULL
    assert lib.sqlite3_exec(coded, b"SELECT (((", None, None, None) == ERROR, "a syntax error has no narrow code"
    assert lib.sqlite3_extended_result_codes(coded, 0) == OK
    assert lib.sqlite3_exec(coded, b"INSERT INTO c VALUES (2, 'a')", None, None, None) == CONSTRAINT
    assert lib.sqlite3_errcode(coded) == CONSTRAINT, "off again is the primary code"
    assert lib.sqlite3_extended_errcode(coded) == UNIQUE, "extended_errcode still answers which one"
    assert lib.sqlite3_close(coded) == OK

    # A dead handle is misuse, not memory (D29): the sqlite3 face answers
    # SQLITE_MISUSE to a statement used after finalize or through a closed
    # connection, a bind outside the parameters answers SQLITE_RANGE, and none of
    # it ends the process.
    lib.sqlite3_finalize.restype = ctypes.c_int
    lib.sqlite3_bind_text.restype = ctypes.c_int
    lib.sqlite3_step.restype = ctypes.c_int
    lib.sqlite3_exec.restype = ctypes.c_int

    ghost = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(ghost)) == OK
    assert lib.sqlite3_exec(ghost, b"CREATE TABLE g (id INTEGER, s TEXT)", None, None, None) == OK
    gone = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(ghost, b"INSERT INTO g (id, s) VALUES (?, ?)", -1, ctypes.byref(gone), None) == OK
    assert lib.sqlite3_bind_int64(gone, 1, 1) == OK
    assert lib.sqlite3_bind_text(gone, 2, b"a", -1, None) == OK
    assert lib.sqlite3_bind_text(gone, 5, b"a", -1, None) == RANGE, "an index past the parameters is refused"
    assert lib.sqlite3_finalize(gone) == OK
    assert lib.sqlite3_step(gone) == MISUSE
    assert lib.sqlite3_bind_text(gone, 1, b"b", -1, None) == MISUSE
    assert lib.sqlite3_finalize(gone) == MISUSE

    owner = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(owner)) == OK
    orphan = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(owner, b"SELECT 1", -1, ctypes.byref(orphan), None) == OK
    assert lib.sqlite3_close(owner) == OK
    assert lib.sqlite3_step(orphan) == MISUSE, "a statement of a closed connection is misuse"
    lib.sqlite3_finalize(orphan)
    lib.sqlite3_close(ghost)

    # F2: sqlite3_reset keeps the bound values; dropping them is what
    # sqlite3_clear_bindings is for, as SQLite documents. The loop this protects
    # is the one every driver uses: prepare once, bind, step, reset, step again
    # with the same values.
    reset_db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(reset_db)) == OK
    assert lib.sqlite3_exec(reset_db, b"CREATE TABLE rb (a INTEGER NOT NULL)", None, None, None) == OK
    reset_stmt = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(reset_db, b"INSERT INTO rb VALUES (?)", -1, ctypes.byref(reset_stmt), None) == OK
    assert lib.sqlite3_bind_int(reset_stmt, 1, 7) == OK
    assert lib.sqlite3_step(reset_stmt) == DONE, "first insert"
    assert lib.sqlite3_reset(reset_stmt) == OK
    assert lib.sqlite3_step(reset_stmt) == DONE, "the binding survived the reset"
    assert lib.sqlite3_reset(reset_stmt) == OK
    assert lib.sqlite3_clear_bindings(reset_stmt) == OK
    assert lib.sqlite3_step(reset_stmt) == CONSTRAINT, "a cleared binding is NULL, which NOT NULL refuses"
    lib.sqlite3_finalize(reset_stmt)
    reader = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(reset_db, b"SELECT a FROM rb ORDER BY a", -1, ctypes.byref(reader), None) == OK
    kept_rows = []
    while lib.sqlite3_step(reader) == ROW:
        kept_rows.append(lib.sqlite3_column_int64(reader, 0))
    lib.sqlite3_finalize(reader)
    assert kept_rows == [7, 7], kept_rows
    assert lib.sqlite3_close(reset_db) == OK

    # F3: changes() counts the rows of the last statement whichever way it ran.
    # A caller that uses sqlite3_exec -- the shell, a loader -- used to read 0
    # after a two-row UPDATE, which is a wrong answer, not a missing feature.
    changes_db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(changes_db)) == OK
    assert lib.sqlite3_exec(changes_db, b"CREATE TABLE ch (a INTEGER)", None, None, None) == OK
    assert lib.sqlite3_exec(changes_db, b"INSERT INTO ch VALUES (1)", None, None, None) == OK
    assert lib.sqlite3_exec(changes_db, b"INSERT INTO ch VALUES (2)", None, None, None) == OK
    assert lib.sqlite3_exec(changes_db, b"UPDATE ch SET a = a + 10", None, None, None) == OK
    assert lib.sqlite3_changes(changes_db) == 2, "exec leaves the row count"
    assert lib.sqlite3_total_changes(changes_db) == 2
    change_stmt = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(changes_db, b"DELETE FROM ch", -1, ctypes.byref(change_stmt), None) == OK
    assert lib.sqlite3_step(change_stmt) == DONE
    assert lib.sqlite3_changes(changes_db) == 2, "a stepped statement leaves the row count too"
    lib.sqlite3_finalize(change_stmt)
    assert lib.sqlite3_close(changes_db) == OK

    # F4: a non-negative length is the byte count. `string(value)` used to stop at
    # the first NUL, so a text with an embedded one arrived as zero bytes.
    text_db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(text_db)) == OK
    assert lib.sqlite3_exec(text_db, b"CREATE TABLE txt (a TEXT)", None, None, None) == OK
    text_stmt = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(text_db, b"INSERT INTO txt VALUES (?)", -1, ctypes.byref(text_stmt), None) == OK
    assert lib.sqlite3_bind_text(text_stmt, 1, b"a\x00b", 3, None) == OK
    assert lib.sqlite3_step(text_stmt) == DONE
    assert lib.sqlite3_reset(text_stmt) == OK
    assert lib.sqlite3_bind_text(text_stmt, 1, b"abc", -1, None) == OK
    assert lib.sqlite3_step(text_stmt) == DONE
    lib.sqlite3_finalize(text_stmt)
    lengths = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(text_db, b"SELECT length(a) FROM txt", -1, ctypes.byref(lengths), None) == OK
    seen = []
    while lib.sqlite3_step(lengths) == ROW:
        seen.append(lib.sqlite3_column_int64(lengths, 0))
    lib.sqlite3_finalize(lengths)
    assert seen == [3, 3], seen
    assert lib.sqlite3_close(text_db) == OK

    # F10: column_text renders every value, answers NULL for NULL, and its bytes
    # are NUL-terminated. Before this, an integer or a real answered "", and the
    # pointer came from an engine string that was not terminated at all.
    render_db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(render_db)) == OK
    render_stmt = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(render_db, b"SELECT 42, 2.5, 'text', NULL, x'00ff'", -1,
                                  ctypes.byref(render_stmt), None) == OK
    assert lib.sqlite3_step(render_stmt) == ROW
    assert lib.sqlite3_column_text(render_stmt, 0) == b"42", lib.sqlite3_column_text(render_stmt, 0)
    assert lib.sqlite3_column_text(render_stmt, 1) == b"2.5", lib.sqlite3_column_text(render_stmt, 1)
    assert lib.sqlite3_column_text(render_stmt, 2) == b"text"
    assert lib.sqlite3_column_text(render_stmt, 3) is None, "NULL is a NULL pointer"
    assert lib.sqlite3_column_bytes(render_stmt, 0) == 2, "the bytes of a rendered integer"
    assert lib.sqlite3_column_bytes(render_stmt, 2) == 4
    assert lib.sqlite3_column_bytes(render_stmt, 3) == 0
    assert lib.sqlite3_column_type(render_stmt, 0) == 1 and lib.sqlite3_column_type(render_stmt, 3) == 5
    lib.sqlite3_finalize(render_stmt)
    assert lib.sqlite3_close(render_db) == OK

    # F5: prepare_v2 reports where the first statement ends, honours nByte, and
    # answers "no statement" instead of an error for text that holds none. A
    # caller looping over a script used to lose everything after the first
    # semicolon because the tail was always NULL.
    tail_db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(tail_db)) == OK
    script = b"SELECT 1; SELECT 2"
    first = ctypes.c_void_p()
    tail = ctypes.c_char_p()
    assert lib.sqlite3_prepare_v2(tail_db, script, -1, ctypes.byref(first), ctypes.byref(tail)) == OK
    assert lib.sqlite3_step(first) == ROW and lib.sqlite3_column_int64(first, 0) == 1
    assert tail.value == b" SELECT 2", tail.value
    second = ctypes.c_void_p()
    assert lib.sqlite3_prepare_v2(tail_db, tail, -1, ctypes.byref(second), None) == OK
    assert lib.sqlite3_step(second) == ROW and lib.sqlite3_column_int64(second, 0) == 2
    lib.sqlite3_finalize(second)
    lib.sqlite3_finalize(first)

    # A semicolon inside a literal does not end the statement.
    quoted = ctypes.c_void_p()
    quoted_tail = ctypes.c_char_p()
    assert lib.sqlite3_prepare_v2(tail_db, b"SELECT ';' AS a; SELECT 3", -1,
                                  ctypes.byref(quoted), ctypes.byref(quoted_tail)) == OK
    assert lib.sqlite3_step(quoted) == ROW and lib.sqlite3_column_text(quoted, 0) == b";"
    assert quoted_tail.value == b" SELECT 3", quoted_tail.value
    lib.sqlite3_finalize(quoted)

    # nByte decides how much of the buffer is the statement.
    exact = ctypes.c_void_p()
    exact_tail = ctypes.c_char_p()
    assert lib.sqlite3_prepare_v2(tail_db, b"SELECT 4; SELECT 5", 8, ctypes.byref(exact),
                                  ctypes.byref(exact_tail)) == OK
    assert lib.sqlite3_step(exact) == ROW and lib.sqlite3_column_int64(exact, 0) == 4
    assert exact_tail.value == b"; SELECT 5", exact_tail.value
    lib.sqlite3_finalize(exact)

    # Nothing to prepare is not an error, and ppStmt stays NULL.
    empty = ctypes.c_void_p(1234)
    assert lib.sqlite3_prepare_v2(tail_db, b"  -- only a comment\n", -1, ctypes.byref(empty), None) == OK
    assert not empty.value, "a comment-only text prepares no statement"
    assert lib.sqlite3_close(tail_db) == OK

    # F1: exec runs the callback once per row, over every statement in the text,
    # with NULL as a NULL pointer, and a non-zero answer stops it. Before this the
    # callback was discarded, so a caller that read rows through exec -- the
    # shell, a loader -- was told OK and given nothing.
    CALLBACK = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                                ctypes.POINTER(ctypes.c_char_p),
                                ctypes.POINTER(ctypes.c_char_p))
    seen_rows = []

    @CALLBACK
    def collect(arg, count, values, names):
        seen_rows.append(tuple(values[i] for i in range(count)))
        return 0

    exec_db = ctypes.c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(exec_db)) == OK
    script = (b"CREATE TABLE ex (a INTEGER, b TEXT);"
              b"INSERT INTO ex VALUES (1, 'x');"
              b"INSERT INTO ex VALUES (2, 'y')")
    assert lib.sqlite3_exec(exec_db, script, ctypes.cast(collect, ctypes.c_void_p), None, None) == OK
    assert seen_rows == [], "the inserts produce no row"
    assert lib.sqlite3_exec(exec_db, b"SELECT a, b FROM ex ORDER BY a",
                            ctypes.cast(collect, ctypes.c_void_p), None, None) == OK
    assert seen_rows == [(b"1", b"x"), (b"2", b"y")], seen_rows

    seen_rows.clear()
    assert lib.sqlite3_exec(exec_db, b"SELECT NULL, 3, 'z'", ctypes.cast(collect, ctypes.c_void_p), None, None) == OK
    assert seen_rows == [(None, b"3", b"z")], seen_rows

    stopped = []

    @CALLBACK
    def stop(arg, count, values, names):
        stopped.append(values[0])
        return 1

    assert lib.sqlite3_exec(exec_db, b"SELECT a FROM ex", ctypes.cast(stop, ctypes.c_void_p), None, None) == OK
    assert stopped == [b"1"], stopped
    assert lib.sqlite3_close(exec_db) == OK

    print("rows:", rows)
    print("error path:", message)
    print("blob io:", blobs_ok)
    print("mirror after DDL:", integrity, rows_after)
    print("mirror emptied:", empty_integrity, remaining)
    print("sqlite3_* smoke: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
