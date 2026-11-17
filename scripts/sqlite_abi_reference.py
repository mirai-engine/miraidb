"""Run the same calls against the facade and against SQLite itself, and compare.

A smoke that asserts what the facade answers only knows what its author thought
SQLite answers. This module drives both libraries through ctypes with one
script and compares what each call returned, so a difference is a difference
from SQLite, not from a guess. The reference is the sqlite3 library the running
Python ships (Windows: DLLs/sqlite3.dll) or the system one.

Used by scripts/sqlite_abi_smoke.py; `observe(lib)` is the script.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import sys

import sqlite_abi_functions
import sqlite_abi_authorizer
import sqlite_abi_hooks
import sqlite_abi_values

c_void_p, c_int, c_char_p, c_longlong = ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_longlong

SIGNATURES = {
    "sqlite3_open": ([c_char_p, ctypes.POINTER(c_void_p)], c_int),
    "sqlite3_close": ([c_void_p], c_int),
    "sqlite3_exec": ([c_void_p, c_char_p, c_void_p, c_void_p, ctypes.POINTER(c_void_p)], c_int),
    "sqlite3_errmsg": ([c_void_p], c_char_p),
    "sqlite3_errstr": ([c_int], c_char_p),
    "sqlite3_error_offset": ([c_void_p], c_int),
    "sqlite3_prepare_v2": ([c_void_p, c_char_p, c_int, ctypes.POINTER(c_void_p), ctypes.POINTER(c_char_p)], c_int),
    "sqlite3_prepare_v3": ([c_void_p, c_char_p, c_int, ctypes.c_uint, ctypes.POINTER(c_void_p), ctypes.POINTER(c_char_p)], c_int),
    "sqlite3_step": ([c_void_p], c_int),
    "sqlite3_reset": ([c_void_p], c_int),
    "sqlite3_finalize": ([c_void_p], c_int),
    "sqlite3_column_int64": ([c_void_p, c_int], c_longlong),
    "sqlite3_column_double": ([c_void_p, c_int], ctypes.c_double),
    "sqlite3_column_text": ([c_void_p, c_int], c_char_p),
    "sqlite3_bind_zeroblob": ([c_void_p, c_int, c_int], c_int),
    "sqlite3_last_insert_rowid": ([c_void_p], c_longlong),
    "sqlite3_set_last_insert_rowid": ([c_void_p, c_longlong], None),
    "sqlite3_changes": ([c_void_p], c_int),
    "sqlite3_changes64": ([c_void_p], c_longlong),
    "sqlite3_total_changes": ([c_void_p], c_int),
    "sqlite3_total_changes64": ([c_void_p], c_longlong),
    "sqlite3_get_autocommit": ([c_void_p], c_int),
    "sqlite3_db_handle": ([c_void_p], c_void_p),
    "sqlite3_sql": ([c_void_p], c_char_p),
    "sqlite3_stmt_readonly": ([c_void_p], c_int),
    "sqlite3_stmt_busy": ([c_void_p], c_int),
    "sqlite3_stmt_isexplain": ([c_void_p], c_int),
    "sqlite3_stmt_status": ([c_void_p, c_int, c_int], c_int),
    "sqlite3_data_count": ([c_void_p], c_int),
    "sqlite3_malloc": ([c_int], c_void_p),
    "sqlite3_realloc": ([c_void_p, c_int], c_void_p),
    "sqlite3_msize": ([c_void_p], ctypes.c_uint64),
    "sqlite3_free": ([c_void_p], None),
    "sqlite3_bind_parameter_count": ([c_void_p], c_int),
    "sqlite3_bind_parameter_name": ([c_void_p, c_int], c_char_p),
    "sqlite3_bind_parameter_index": ([c_void_p, c_char_p], c_int),
    "sqlite3_expanded_sql": ([c_void_p], c_void_p),
    "sqlite3_bind_int64": ([c_void_p, c_int, c_longlong], c_int),
    "sqlite3_bind_double": ([c_void_p, c_int, ctypes.c_double], c_int),
    "sqlite3_bind_text": ([c_void_p, c_int, c_char_p, c_int, c_void_p], c_int),
    "sqlite3_bind_blob": ([c_void_p, c_int, c_char_p, c_int, c_void_p], c_int),
    "sqlite3_column_count": ([c_void_p], c_int),
    "sqlite3_column_name": ([c_void_p, c_int], c_char_p),
    "sqlite3_column_decltype": ([c_void_p, c_int], c_char_p),
    "sqlite3_column_table_name": ([c_void_p, c_int], c_char_p),
    "sqlite3_column_origin_name": ([c_void_p, c_int], c_char_p),
    "sqlite3_column_database_name": ([c_void_p, c_int], c_char_p),
}

# SQLITE_TRANSIENT: SQLite copies the value before the call returns.
TRANSIENT = c_void_p(-1)

STMTSTATUS_RUN = 6
EXEC_CALLBACK = ctypes.CFUNCTYPE(c_int, c_void_p, c_int, ctypes.POINTER(c_char_p), ctypes.POINTER(c_char_p))


# Symbols a SQLite build may leave out: the column metadata calls exist only
# with SQLITE_ENABLE_COLUMN_METADATA, which Python's own Windows build does not
# set. What a reference lacks is not compared.
OPTIONAL = {"sqlite3_column_table_name", "sqlite3_column_origin_name", "sqlite3_column_database_name"}


def load(path: str):
    lib = ctypes.CDLL(path)
    lib.missing = set()
    for name, (args, result) in SIGNATURES.items():
        try:
            function = getattr(lib, name)
        except AttributeError:
            if name not in OPTIONAL:
                raise
            lib.missing.add(name)
            continue
        function.argtypes = args
        function.restype = result
    sqlite_abi_functions.bind(lib)
    sqlite_abi_hooks.bind(lib)
    # Python's own SQLite is built with SQLITE_OMIT_AUTOINIT: without this call
    # its first sqlite3_open writes through a NULL pointer.
    assert lib.sqlite3_initialize() == 0
    return lib


def reference_path() -> str | None:
    """The SQLite library this Python links, or the system one."""
    if os.name == "nt":
        candidate = os.path.join(sys.base_prefix, "DLLs", "sqlite3.dll")
        return candidate if os.path.exists(candidate) else None
    return ctypes.util.find_library("sqlite3")


def observe(lib) -> dict[str, object]:
    """One script, every answer recorded by name."""
    seen: dict[str, object] = {}
    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0

    def exec_(sql: bytes) -> int:
        return lib.sqlite3_exec(db, sql, None, None, None)

    def prepare(sql: bytes) -> c_void_p:
        stmt = c_void_p()
        assert lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None) == 0, (sql, lib.sqlite3_errmsg(db))
        return stmt

    seen["autocommit at open"] = lib.sqlite3_get_autocommit(db)
    seen["errmsg at open"] = lib.sqlite3_errmsg(db)
    exec_(b"CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
    exec_(b"INSERT INTO t (v) VALUES (10), (20), (30)")
    seen["last rowid after 3 inserts"] = lib.sqlite3_last_insert_rowid(db)
    seen["changes after 3 inserts"] = (lib.sqlite3_changes(db), lib.sqlite3_changes64(db))
    exec_(b"UPDATE t SET v = v + 1 WHERE id < 3")
    seen["changes after update"] = lib.sqlite3_changes64(db)
    seen["total changes"] = (lib.sqlite3_total_changes(db), lib.sqlite3_total_changes64(db))
    exec_(b"CREATE TABLE u (x INTEGER)")
    seen["total changes after DDL"] = lib.sqlite3_total_changes64(db)

    exec_(b"BEGIN")
    seen["autocommit in BEGIN"] = lib.sqlite3_get_autocommit(db)
    exec_(b"COMMIT")
    seen["autocommit after COMMIT"] = lib.sqlite3_get_autocommit(db)
    exec_(b"SAVEPOINT sp")
    seen["autocommit in SAVEPOINT"] = lib.sqlite3_get_autocommit(db)
    exec_(b"RELEASE sp")
    seen["autocommit after RELEASE"] = lib.sqlite3_get_autocommit(db)

    lib.sqlite3_set_last_insert_rowid(db, 42)
    seen["set last rowid"] = lib.sqlite3_last_insert_rowid(db)

    # A statement through its life: before the first step, on a row, at the end.
    tail = c_char_p()
    stmt = c_void_p()
    text = b"  SELECT id, v FROM t ORDER BY id; SELECT 2"
    assert lib.sqlite3_prepare_v3(db, text, -1, 0, ctypes.byref(stmt), ctypes.byref(tail)) == 0
    seen["sql"] = lib.sqlite3_sql(stmt)
    seen["tail"] = tail.value
    seen["db_handle is the connection"] = lib.sqlite3_db_handle(stmt) == db.value
    seen["select readonly"] = lib.sqlite3_stmt_readonly(stmt)
    seen["select isexplain"] = lib.sqlite3_stmt_isexplain(stmt)
    seen["before step"] = (lib.sqlite3_stmt_busy(stmt), lib.sqlite3_data_count(stmt))
    lib.sqlite3_step(stmt)
    seen["on a row"] = (lib.sqlite3_stmt_busy(stmt), lib.sqlite3_data_count(stmt))
    while lib.sqlite3_step(stmt) == 100:
        pass
    seen["at the end"] = (lib.sqlite3_stmt_busy(stmt), lib.sqlite3_data_count(stmt))
    seen["runs after one pass"] = lib.sqlite3_stmt_status(stmt, STMTSTATUS_RUN, 0)
    lib.sqlite3_reset(stmt)
    lib.sqlite3_step(stmt)
    seen["runs after two passes"] = lib.sqlite3_stmt_status(stmt, STMTSTATUS_RUN, 1)
    seen["runs after a reset of the counter"] = lib.sqlite3_stmt_status(stmt, STMTSTATUS_RUN, 0)
    lib.sqlite3_finalize(stmt)

    for label, sql in (
        ("insert", b"INSERT INTO t (v) VALUES (1)"),
        ("update", b"UPDATE t SET v = 0"),
        ("create", b"CREATE TABLE w (x INTEGER)"),
        ("begin", b"BEGIN"),
        ("commit", b"COMMIT"),
        ("pragma read", b"PRAGMA user_version"),
        ("pragma write", b"PRAGMA user_version = 3"),
        ("explain query plan", b"EXPLAIN QUERY PLAN SELECT * FROM t"),
    ):
        statement = prepare(sql)
        seen[f"{label}: readonly, isexplain"] = (
            lib.sqlite3_stmt_readonly(statement),
            lib.sqlite3_stmt_isexplain(statement),
        )
        lib.sqlite3_finalize(statement)
    exec_(b"COMMIT")

    # A zero blob holds n zero bytes.
    exec_(b"CREATE TABLE b (x BLOB)")
    insert = prepare(b"INSERT INTO b (x) VALUES (?)")
    seen["bind zeroblob"] = lib.sqlite3_bind_zeroblob(insert, 1, 4)
    seen["bind zeroblob out of range"] = lib.sqlite3_bind_zeroblob(insert, 2, 4)
    lib.sqlite3_step(insert)
    lib.sqlite3_finalize(insert)
    reader = prepare(b"SELECT length(x), hex(x) FROM b")
    lib.sqlite3_step(reader)
    seen["zeroblob stored"] = (lib.sqlite3_column_int64(reader, 0), lib.sqlite3_column_text(reader, 1))
    lib.sqlite3_finalize(reader)

    # exec hands its error message to the caller, who frees it.
    message = c_void_p()
    code = lib.sqlite3_exec(db, b"SELECT * FROM missing", None, None, ctypes.byref(message))
    seen["exec error code"] = code
    seen["exec error message set"] = bool(message.value)
    lib.sqlite3_free(message)
    seen["errmsg after success"] = (exec_(b"SELECT 1"), lib.sqlite3_errmsg(db))

    # A prepare that fails says where: at the token it stopped on, or -1 when
    # the text simply ended (SQLite's "incomplete input"). The two grammars stop
    # on the same token for these; a misspelled keyword after a valid prefix is
    # read differently and is left out.
    failed = c_void_p()
    for sql in (b"SELEC 1", b"SELECT 1 2", b"SELECT 1 +", b"  SELECT (1"):
        code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(failed), None)
        seen[f"prepare {sql!r}: code, offset"] = (code, lib.sqlite3_error_offset(db))
    lib.sqlite3_prepare_v2(db, b"SELECT 1", -1, ctypes.byref(failed), None)
    seen["after a prepare that works: offset, errmsg"] = (lib.sqlite3_error_offset(db), lib.sqlite3_errmsg(db))
    lib.sqlite3_finalize(failed)

    # The allocator a caller frees our answers with.
    block = lib.sqlite3_malloc(10)
    seen["malloc'd block holds what was asked"] = lib.sqlite3_msize(block) >= 10
    block = lib.sqlite3_realloc(block, 100)
    seen["realloc'd block grows"] = lib.sqlite3_msize(block) >= 100
    lib.sqlite3_free(block)
    lib.sqlite3_free(None)

    # Parameters by number and by name: the slots they take, their names, and
    # the text with their values in place.
    text = b"SELECT ?1, :a, @b, $c, ?, :a, ?7, '?' /* :a */"
    params = prepare(text)
    count = lib.sqlite3_bind_parameter_count(params)
    seen["parameter count"] = count
    seen["parameter names"] = [lib.sqlite3_bind_parameter_name(params, i) for i in range(0, count + 2)]
    seen["parameter indexes"] = [
        lib.sqlite3_bind_parameter_index(params, name) for name in (b":a", b"@b", b"$c", b"?7", b"?1", b"a", b":nope")
    ]
    seen["expanded before binding"] = ctypes.string_at(lib.sqlite3_expanded_sql(params))
    lib.sqlite3_bind_int64(params, 1, 42)
    lib.sqlite3_bind_text(params, 2, b"it's", -1, TRANSIENT)
    lib.sqlite3_bind_blob(params, 3, bytes([1, 255]), 2, TRANSIENT)
    lib.sqlite3_bind_double(params, 4, 2.5)
    lib.sqlite3_bind_int64(params, 7, -1)
    expanded = lib.sqlite3_expanded_sql(params)
    seen["expanded"] = ctypes.string_at(expanded)
    lib.sqlite3_free(expanded)
    assert lib.sqlite3_step(params) == 100, lib.sqlite3_errmsg(db)
    seen["values read back"] = [
        lib.sqlite3_column_text(params, i) for i in range(lib.sqlite3_column_count(params))
    ]
    lib.sqlite3_finalize(params)
    bad = c_void_p()
    seen["?0 is refused"] = lib.sqlite3_prepare_v2(db, b"SELECT ?0", -1, ctypes.byref(bad), None)

    # Where each result column comes from, right after prepare: a column that
    # names a table's column directly has a database, a table, a column and a
    # declared type, and an expression has none.
    exec_(b"CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL, photo BLOB)")
    exec_(b"CREATE TABLE orders (oid INTEGER PRIMARY KEY, pid INTEGER, total REAL)")
    for sql in (
        b"SELECT id, name, score, photo FROM people",
        b"SELECT name AS who, score * 2, t.id, upper(name), 1 FROM people t",
        b"SELECT p.id, o.total, pid, oid FROM people p JOIN orders o ON o.pid = p.id",
        b"SELECT * FROM orders",
        b"SELECT count(*), max(score) FROM people",
    ):
        described = prepare(sql)
        columns = lib.sqlite3_column_count(described)
        seen[f"decltypes of {sql!r}"] = [lib.sqlite3_column_decltype(described, i) for i in range(columns + 1)]
        if not lib.missing:
            seen[f"origins of {sql!r}"] = [
                (
                    lib.sqlite3_column_database_name(described, i),
                    lib.sqlite3_column_table_name(described, i),
                    lib.sqlite3_column_origin_name(described, i),
                )
                for i in range(columns + 1)
            ]
        lib.sqlite3_finalize(described)

    # A column read as a number follows SQLite's conversions: text is read for
    # its leading integer by column_int64 and its number by column_double.
    reader = prepare(b"SELECT '42', ' 12.9x', 4.7, '1e3', 'abc', NULL, x'3739'")
    lib.sqlite3_step(reader)
    seen["column_int64 and column_double of each kind"] = [
        (lib.sqlite3_column_int64(reader, i), lib.sqlite3_column_double(reader, i)) for i in range(7)
    ]
    lib.sqlite3_finalize(reader)

    # The names of the result columns: an alias, a column's own name, and for an
    # expression the text it was written with.
    for sql in (
        b"SELECT count(*), 1+2, id * 2, upper( name ) AS loud, p.score, max(score) FROM people p",
        b"SELECT *, pid FROM orders",
        b"SELECT 'a' || 'b', CAST(1 AS TEXT), (SELECT 1), -id FROM people",
    ):
        named = prepare(sql)
        seen[f"column names of {sql!r}"] = [
            lib.sqlite3_column_name(named, i) for i in range(lib.sqlite3_column_count(named))
        ]
        lib.sqlite3_finalize(named)

    # exec hands each row to its callback and stops when the callback says so.
    rows_seen = []

    @EXEC_CALLBACK
    def take_two(arg, count, values, names):
        rows_seen.append((values[0], names[0]))
        return 1 if len(rows_seen) == 2 else 0

    message = c_void_p()
    code = lib.sqlite3_exec(db, b"SELECT id AS n FROM people; SELECT 1", ctypes.cast(take_two, c_void_p), None, ctypes.byref(message))
    seen["exec stopped by its callback"] = (code, ctypes.string_at(message.value) if message.value else None, rows_seen, lib.sqlite3_errcode(db))
    lib.sqlite3_free(message)
    rows_seen.clear()
    code = lib.sqlite3_exec(db, b"  ; SELECT 7 AS x; -- end", ctypes.cast(take_two, c_void_p), None, None)
    seen["exec of a text with empty statements"] = (code, rows_seen)

    sqlite_abi_functions.observe(lib, db, seen)
    sqlite_abi_hooks.observe(lib, db, seen)
    sqlite_abi_hooks.observe_trace(lib, db, seen)
    sqlite_abi_authorizer.observe(lib, seen)
    # Last: it gives bind_text and bind_blob the argument types it needs.
    sqlite_abi_values.observe(lib, seen)

    seen["errstr"] = [lib.sqlite3_errstr(code) for code in (*range(0, 30), 100, 101, 516, 19 | 8 << 8, 9999)]
    assert lib.sqlite3_close(db) == 0
    return seen


# What SQLite answers for the column origins of the script's statements, for a
# reference built without SQLITE_ENABLE_COLUMN_METADATA: database, table (its
# real name, not the alias) and column, and NULL for an expression.
M, P, O = b"main", b"people", b"orders"
NONE3 = (None, None, None)
EXPECTED_ORIGINS = {
    b"SELECT id, name, score, photo FROM people":
        [(M, P, b"id"), (M, P, b"name"), (M, P, b"score"), (M, P, b"photo"), NONE3],
    b"SELECT name AS who, score * 2, t.id, upper(name), 1 FROM people t":
        [(M, P, b"name"), NONE3, (M, P, b"id"), NONE3, NONE3, NONE3],
    b"SELECT p.id, o.total, pid, oid FROM people p JOIN orders o ON o.pid = p.id":
        [(M, P, b"id"), (M, O, b"total"), (M, O, b"pid"), (M, O, b"oid"), NONE3],
    b"SELECT * FROM orders":
        [(M, O, b"oid"), (M, O, b"pid"), (M, O, b"total"), NONE3],
    b"SELECT count(*), max(score) FROM people": [NONE3, NONE3, NONE3],
}


def compare(facade_path: str) -> list[str]:
    """The differences between the facade and SQLite, one line each."""
    reference = reference_path()
    if reference is None:
        return ["no reference SQLite library to compare against"]
    ours = observe(load(facade_path))
    reference_lib = load(reference)
    theirs = observe(reference_lib)
    if reference_lib.missing:
        for sql, origins in EXPECTED_ORIGINS.items():
            theirs[f"origins of {sql!r}"] = origins
    return [
        f"{key}: facade {ours.get(key)!r}, SQLite {theirs[key]!r}"
        for key in theirs
        if ours.get(key) != theirs[key]
    ]


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("bin", "sqlite3_miraidb.dll")
    differences = compare(path)
    for line in differences:
        print(line)
    print(f"{len(differences)} difference(s) from SQLite")
    raise SystemExit(1 if differences else 0)
