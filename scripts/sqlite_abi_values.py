"""Pointer values, the UTF-16 API and bind destructors, driven the same way
through the facade and SQLite.

Pointers: a pointer bound with sqlite3_bind_pointer or returned with
sqlite3_result_pointer reaches a function that asks for it by the same type
name, and is NULL to SQL, to a function that names another type, to a table
that stores it and to a copy made with sqlite3_value_dup. Its destructor runs
when SQLite lets it go; what is compared is the count once the statement is
finalized, which is the only moment both promise.

UTF-16: open16, prepare16 (and its tail), bind_text16, bind_text64 in each
encoding, column_text16/bytes16/name16/decltype16, value_text16 in each byte
order, result_text16 in each byte order, result_text64 with an encoding,
result_error16, errmsg16 and create_function16.

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
UTF8, UTF16LE, UTF16BE, UTF16 = 1, 2, 3, 4

SIGNATURES = {
    "sqlite3_bind_pointer": ([c_void_p, c_int, c_void_p, c_char_p, c_void_p], c_int),
    "sqlite3_result_pointer": ([c_void_p, c_void_p, c_char_p, c_void_p], None),
    "sqlite3_value_pointer": ([c_void_p, c_char_p], c_void_p),
    "sqlite3_open16": ([c_void_p, ctypes.POINTER(c_void_p)], c_int),
    "sqlite3_errmsg16": ([c_void_p], c_void_p),
    "sqlite3_prepare16_v2": ([c_void_p, c_void_p, c_int, ctypes.POINTER(c_void_p), ctypes.POINTER(c_void_p)], c_int),
    "sqlite3_prepare16_v3": ([c_void_p, c_void_p, c_int, ctypes.c_uint, ctypes.POINTER(c_void_p), ctypes.POINTER(c_void_p)], c_int),
    "sqlite3_create_function16": ([c_void_p, c_void_p, c_int, c_int, c_void_p, c_void_p, c_void_p, c_void_p], c_int),
    "sqlite3_bind_text16": ([c_void_p, c_int, c_void_p, c_int, c_void_p], c_int),
    "sqlite3_bind_text64": ([c_void_p, c_int, c_void_p, c_uint64, c_void_p, c_ubyte], c_int),
    "sqlite3_column_text16": ([c_void_p, c_int], c_void_p),
    "sqlite3_column_bytes16": ([c_void_p, c_int], c_int),
    "sqlite3_column_name16": ([c_void_p, c_int], c_void_p),
    "sqlite3_column_decltype16": ([c_void_p, c_int], c_void_p),
    "sqlite3_value_text16": ([c_void_p], c_void_p),
    "sqlite3_value_text16le": ([c_void_p], c_void_p),
    "sqlite3_value_text16be": ([c_void_p], c_void_p),
    "sqlite3_value_bytes16": ([c_void_p], c_int),
    "sqlite3_result_text16": ([c_void_p, c_void_p, c_int, c_void_p], None),
    "sqlite3_result_text16le": ([c_void_p, c_void_p, c_int, c_void_p], None),
    "sqlite3_result_text16be": ([c_void_p, c_void_p, c_int, c_void_p], None),
    "sqlite3_result_text64": ([c_void_p, c_void_p, c_uint64, c_void_p, c_ubyte], None),
    "sqlite3_result_error16": ([c_void_p, c_void_p, c_int], None),
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


def wide(text: str, order: str = "utf-16-le") -> ctypes.Array:
    """A NUL-terminated UTF-16 buffer in the given byte order."""
    data = text.encode(order) + b"\0\0"
    return ctypes.create_string_buffer(data, len(data))


def read16(address, order: str = "utf-16-le") -> str | None:
    """The NUL-terminated UTF-16 text at `address`."""
    if not address:
        return None
    out = bytearray()
    at = address
    while True:
        unit = ctypes.string_at(at, 2)
        if unit == b"\0\0":
            break
        out += unit
        at += 2
    return out.decode(order, errors="replace")


def observe(lib, seen: dict) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result
    keep: list = []
    observe_pointers(lib, seen, keep)
    observe_utf16(lib, seen, keep)
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


def observe_utf16(lib, seen: dict, keep: list) -> None:
    db = c_void_p()
    seen["open16"] = lib.sqlite3_open16(wide(":memory:"), ctypes.byref(db))
    assert lib.sqlite3_exec(db, b"CREATE TABLE w (name TEXT, n INTEGER)", None, None, None) == 0

    # prepare16: the tail is a place in the UTF-16 text.
    script = "SELECT 'héllo', 'x\U0001F600y' AS émo, n FROM w; SELECT 2"
    buffer = wide(script)
    stmt, tail = c_void_p(), c_void_p()
    code = lib.sqlite3_prepare16_v2(db, buffer, -1, ctypes.byref(stmt), ctypes.byref(tail))
    seen["prepare16 tail"] = (code, (tail.value - ctypes.addressof(buffer)) // 2 if tail.value else None)
    seen["column_name16"] = [read16(lib.sqlite3_column_name16(stmt, i)) for i in range(3)]
    seen["column_decltype16"] = [read16(lib.sqlite3_column_decltype16(stmt, i)) for i in range(3)]
    lib.sqlite3_finalize(stmt)
    limited = wide("SELECT 1; SELECT 2")
    code = lib.sqlite3_prepare16_v3(db, limited, 16, 0, ctypes.byref(stmt), ctypes.byref(tail))
    seen["prepare16 with a length"] = (code, (tail.value - ctypes.addressof(limited)) // 2 if tail.value else None)
    lib.sqlite3_finalize(stmt)

    # bind_text16 and bind_text64 in each encoding; the column read back both ways.
    insert = c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"INSERT INTO w VALUES (?1, ?2)", -1, ctypes.byref(insert), None) == 0
    texts = [("añ\U0001F600", None), ("le", UTF16LE), ("big é", UTF16BE), ("native", UTF16), ("utf8 ü", UTF8)]
    for n, (text, encoding) in enumerate(texts):
        if encoding is None:
            code = lib.sqlite3_bind_text16(insert, 1, wide(text), -1, TRANSIENT)
        elif encoding == UTF8:
            data = text.encode()
            code = lib.sqlite3_bind_text64(insert, 1, data, len(data), TRANSIENT, encoding)
        else:
            order = "utf-16-be" if encoding == UTF16BE else "utf-16-le"
            data = text.encode(order)
            code = lib.sqlite3_bind_text64(insert, 1, data, len(data), TRANSIENT, encoding)
        assert code == 0, (text, code)
        lib.sqlite3_bind_int64(insert, 2, n)
        assert lib.sqlite3_step(insert) == 101
        lib.sqlite3_reset(insert)
    lib.sqlite3_finalize(insert)
    read = c_void_p()
    assert lib.sqlite3_prepare_v2(db, b"SELECT name, n, NULL FROM w ORDER BY n", -1, ctypes.byref(read), None) == 0
    rows = []
    while lib.sqlite3_step(read) == 100:
        rows.append((lib.sqlite3_column_text(read, 0), read16(lib.sqlite3_column_text16(read, 0)),
                     lib.sqlite3_column_bytes16(read, 0), lib.sqlite3_column_bytes(read, 0),
                     read16(lib.sqlite3_column_text16(read, 1)), lib.sqlite3_column_text16(read, 2),
                     lib.sqlite3_column_bytes16(read, 2)))
    lib.sqlite3_finalize(read)
    seen["bound UTF-16 read back"] = rows

    # Functions: value_text16 in each order, result_text16 in each order.
    def echo(order):
        def call(ctx, argc, argv):
            value = argv[0]
            le = read16(lib.sqlite3_value_text16le(value))
            be = read16(lib.sqlite3_value_text16be(value), "utf-16-be")
            native = read16(lib.sqlite3_value_text16(value))
            size = lib.sqlite3_value_bytes16(value)
            text = f"{le}|{be}|{native}|{size}" if le is not None else None
            if text is None:
                lib.sqlite3_result_null(ctx)
            elif order == "64":
                data = text.encode("utf-16-be")
                lib.sqlite3_result_text64(ctx, data, len(data), TRANSIENT, UTF16BE)
            else:
                function = {"le": lib.sqlite3_result_text16le, "be": lib.sqlite3_result_text16be,
                            "native": lib.sqlite3_result_text16}[order]
                encoding = "utf-16-be" if order == "be" else "utf-16-le"
                data = ctypes.create_string_buffer(text.encode(encoding) + b"\0\0")
                function(ctx, data, -1, TRANSIENT)
        return FUNC(call)

    def fail16(ctx, argc, argv):
        message = wide("bad é input")
        lib.sqlite3_result_error16(ctx, message, -1)

    for name, callback in ((b"echo_le", echo("le")), (b"echo_be", echo("be")), (b"echo_native", echo("native")),
                           (b"echo_64", echo("64"))):
        keep.append(callback)
        assert lib.sqlite3_create_function_v2(db, name, 1, UTF8, None, ctypes.cast(callback, c_void_p), None, None, None) == 0
    failing = FUNC(fail16)
    keep.append(failing)
    seen["create_function16"] = lib.sqlite3_create_function16(db, wide("fäil"), 0, UTF16, None,
                                                                ctypes.cast(failing, c_void_p), None, None)
    seen["value and result in UTF-16"] = run(
        lib, db, "SELECT echo_le('été'), echo_be(12), echo_native(NULL), echo_64('x\U0001F600')".encode())
    stmt = c_void_p()
    assert lib.sqlite3_prepare_v2(db, "SELECT fäil()".encode(), -1, ctypes.byref(stmt), None) == 0
    seen["result_error16"] = (lib.sqlite3_step(stmt), read16(lib.sqlite3_errmsg16(db)), lib.sqlite3_errmsg(db))
    lib.sqlite3_finalize(stmt)
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
