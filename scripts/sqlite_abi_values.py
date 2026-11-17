"""Pointer values and bind destructors, driven the same way through the
facade and SQLite.

Pointers: a pointer bound with sqlite3_bind_pointer or returned with
sqlite3_result_pointer reaches a function that asks for it by the same type
name, and is NULL to SQL, to a function that names another type, to a table
that stores it and to a copy made with sqlite3_value_dup. Its destructor runs
when SQLite lets it go; what is compared is the count once the statement is
finalized, which is the only moment both promise.

Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes

c_void_p, c_int, c_char_p, c_longlong, c_uint64, c_ubyte = (
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_longlong, ctypes.c_uint64, ctypes.c_ubyte,
)

FUNC = ctypes.CFUNCTYPE(None, c_void_p, c_int, ctypes.POINTER(c_void_p))
DESTROY = ctypes.CFUNCTYPE(None, c_void_p)
TRANSIENT = c_void_p(-1)
UTF8 = 1

SIGNATURES = {
    "sqlite3_bind_pointer": ([c_void_p, c_int, c_void_p, c_char_p, c_void_p], c_int),
    "sqlite3_result_pointer": ([c_void_p, c_void_p, c_char_p, c_void_p], None),
    "sqlite3_value_pointer": ([c_void_p, c_char_p], c_void_p),
    "sqlite3_result_int64": ([c_void_p, c_longlong], None),
    "sqlite3_result_null": ([c_void_p], None),
    "sqlite3_value_dup": ([c_void_p], c_void_p),
    "sqlite3_value_free": ([c_void_p], None),
    "sqlite3_create_function_v2": (
        [c_void_p, c_char_p, c_int, c_int, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p], c_int),
    "sqlite3_bind_text": ([c_void_p, c_int, c_void_p, c_int, c_void_p], c_int),
    "sqlite3_bind_blob": ([c_void_p, c_int, c_void_p, c_int, c_void_p], c_int),
    "sqlite3_bind_int64": ([c_void_p, c_int, c_longlong], c_int),
    "sqlite3_clear_bindings": ([c_void_p], c_int),
}

KIND = b"miraidb-test"
OTHER = b"other"


def observe(lib, seen: dict) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result
    keep: list = []
    observe_pointers(lib, seen, keep)
    observe_bind_destructors(lib, seen, keep)


def open_memory(lib):
    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0
    return db


def run(lib, db, sql: bytes, binder=None):
    """Prepare, bind, step to the end; the rows as text, and the finalize code."""
    stmt = c_void_p()
    code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
    if code:
        return code, lib.sqlite3_errmsg(db)
    if binder:
        binder(stmt)
    rows = []
    while (code := lib.sqlite3_step(stmt)) == 100:
        rows.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
    message = lib.sqlite3_errmsg(db) if code != 101 else None
    lib.sqlite3_finalize(stmt)
    return code, message, rows


def observe_pointers(lib, seen: dict, keep: list) -> None:
    db = open_memory(lib)
    released: list = []
    destroy = DESTROY(lambda p: released.append(p))
    keep.append(destroy)
    destroy_p = ctypes.cast(destroy, c_void_p)

    def getter(type_name):
        def call(ctx, argc, argv):
            pointer = lib.sqlite3_value_pointer(argv[0], type_name)
            if pointer:
                lib.sqlite3_result_int64(ctx, pointer)
            else:
                lib.sqlite3_result_null(ctx)
        return FUNC(call)

    def make(ctx, argc, argv):
        lib.sqlite3_result_pointer(ctx, c_void_p(0x2468), KIND, destroy_p)

    def dup(ctx, argc, argv):
        copy = lib.sqlite3_value_dup(argv[0])
        pointer = lib.sqlite3_value_pointer(copy, KIND)
        lib.sqlite3_value_free(copy)
        lib.sqlite3_result_int64(ctx, pointer or -1)

    for name, arity, callback in (
        (b"ptr_get", 1, getter(KIND)), (b"ptr_other", 1, getter(OTHER)),
        (b"ptr_make", 0, FUNC(make)), (b"ptr_dup", 1, FUNC(dup)),
    ):
        keep.append(callback)
        assert lib.sqlite3_create_function_v2(db, name, arity, UTF8, None, ctypes.cast(callback, c_void_p), None, None, None) == 0

    def bind_pointer(stmt):
        assert lib.sqlite3_bind_pointer(stmt, 1, c_void_p(0x1357), KIND, destroy_p) == 0

    seen["pointer bound"] = run(lib, db, b"SELECT ptr_get(?1), ptr_other(?1), typeof(?1), ?1 IS NULL, ptr_dup(?1)", bind_pointer)
    seen["pointer bound: released at finalize"] = len(released)
    seen["pointer returned"] = run(lib, db, b"SELECT ptr_get(ptr_make()), typeof(ptr_make()), ptr_other(ptr_make())")
    seen["pointer returned: released"] = len(released)
    assert lib.sqlite3_exec(db, b"CREATE TABLE pt (v ANY)", None, None, None) == 0
    seen["pointer stored"] = run(lib, db, b"INSERT INTO pt VALUES (?1)", bind_pointer)
    seen["pointer stored: read back"] = run(lib, db, b"SELECT typeof(v), ptr_get(v) FROM pt")

    # A rebind, clear_bindings and finalize each let the bound pointer go.
    stmt = c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"SELECT ptr_get(?1)", -1, ctypes.byref(stmt), None) == 0
    before = len(released)
    counts = []
    bind_pointer(stmt)
    lib.sqlite3_bind_int64(stmt, 1, 5)
    counts.append(len(released) - before)
    bind_pointer(stmt)
    lib.sqlite3_clear_bindings(stmt)
    counts.append(len(released) - before)
    bind_pointer(stmt)
    lib.sqlite3_finalize(stmt)
    counts.append(len(released) - before)
    seen["pointer bound: rebind, clear, finalize"] = counts
    seen["pointer with no type"] = run(lib, db, b"SELECT ptr_get(?1), typeof(?1)",
                                       lambda s: lib.sqlite3_bind_pointer(s, 1, c_void_p(1), None, None))
    lib.sqlite3_close(db)


def observe_bind_destructors(lib, seen: dict, keep: list) -> None:
    db = open_memory(lib)
    freed: list = []
    destroy = DESTROY(lambda p: freed.append(p))
    keep.append(destroy)
    destroy_p = ctypes.cast(destroy, c_void_p)
    text = ctypes.create_string_buffer(b"kept")
    blob = ctypes.create_string_buffer(b"\x01\x02")
    stmt = c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"SELECT ?1, ?2, typeof(?3), length(?3), typeof(?4)", -1, ctypes.byref(stmt), None) == 0
    codes = [
        lib.sqlite3_bind_text(stmt, 1, text, -1, destroy_p),
        lib.sqlite3_bind_blob(stmt, 2, blob, 2, destroy_p),
        lib.sqlite3_bind_blob(stmt, 3, blob, 0, TRANSIENT),
        lib.sqlite3_bind_text(stmt, 4, None, -1, TRANSIENT),
    ]
    assert lib.sqlite3_step(stmt) == 100
    row = (lib.sqlite3_column_text(stmt, 0), lib.sqlite3_column_bytes(stmt, 1),
           lib.sqlite3_column_text(stmt, 2), lib.sqlite3_column_int64(stmt, 3), lib.sqlite3_column_text(stmt, 4))
    lib.sqlite3_finalize(stmt)
    seen["bind destructors"] = (codes, row, len(freed))
    lib.sqlite3_close(db)
