"""Application-defined functions, driven the same way through the facade and SQLite.

The callbacks are Python functions behind ctypes, and each one calls back into
the library it was registered with (sqlite3_value_*, sqlite3_result_*,
sqlite3_aggregate_context), so the same script exercises both sides of the
contract. Used by scripts/sqlite_abi_reference.py, which compares the answers.
"""

from __future__ import annotations

import ctypes

c_void_p, c_int, c_char_p, c_longlong, c_double = (
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_longlong, ctypes.c_double,
)

FUNC = ctypes.CFUNCTYPE(None, c_void_p, c_int, ctypes.POINTER(c_void_p))
FINAL = ctypes.CFUNCTYPE(None, c_void_p)
DESTROY = ctypes.CFUNCTYPE(None, c_void_p)

SIGNATURES = {
    "sqlite3_create_function_v2": (
        [c_void_p, c_char_p, c_int, c_int, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p], c_int),
    "sqlite3_value_type": ([c_void_p], c_int),
    "sqlite3_value_int64": ([c_void_p], c_longlong),
    "sqlite3_value_double": ([c_void_p], c_double),
    "sqlite3_value_text": ([c_void_p], c_char_p),
    "sqlite3_value_bytes": ([c_void_p], c_int),
    "sqlite3_value_blob": ([c_void_p], c_void_p),
    "sqlite3_value_numeric_type": ([c_void_p], c_int),
    "sqlite3_value_dup": ([c_void_p], c_void_p),
    "sqlite3_value_free": ([c_void_p], None),
    "sqlite3_result_int64": ([c_void_p, c_longlong], None),
    "sqlite3_result_double": ([c_void_p, c_double], None),
    "sqlite3_result_null": ([c_void_p], None),
    "sqlite3_result_text": ([c_void_p, c_char_p, c_int, c_void_p], None),
    "sqlite3_result_blob": ([c_void_p, c_char_p, c_int, c_void_p], None),
    "sqlite3_result_zeroblob": ([c_void_p, c_int], None),
    "sqlite3_result_value": ([c_void_p, c_void_p], None),
    "sqlite3_result_error": ([c_void_p, c_char_p, c_int], None),
    "sqlite3_result_error_code": ([c_void_p, c_int], None),
    "sqlite3_user_data": ([c_void_p], c_void_p),
    "sqlite3_context_db_handle": ([c_void_p], c_void_p),
    "sqlite3_aggregate_context": ([c_void_p, c_int], c_void_p),
    "sqlite3_get_auxdata": ([c_void_p, c_int], c_void_p),
    "sqlite3_set_auxdata": ([c_void_p, c_int, c_void_p, c_void_p], None),
    "sqlite3_errcode": ([c_void_p], c_int),
    "sqlite3_extended_errcode": ([c_void_p], c_int),
}

TRANSIENT = c_void_p(-1)
USER = 1234


def bind(lib) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result


def observe(lib, db, seen: dict) -> None:
    keep = []  # ctypes callbacks must outlive the registration

    def register(name: bytes, arity: int, func=None, step=None, final=None, destroy=None, user=USER) -> int:
        holders = [FUNC(func) if func else None, FUNC(step) if step else None,
                   FINAL(final) if final else None, DESTROY(destroy) if destroy else None]
        keep.append(holders)
        args = [ctypes.cast(h, c_void_p) if h else None for h in holders]
        return lib.sqlite3_create_function_v2(db, name, arity, 1, c_void_p(user), *args)

    def first_failure(sql: bytes):
        """Prepare and step to the end; the code and message of the first failure."""
        stmt = c_void_p()
        code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
        rows = []
        if code == 0:
            while True:
                code = lib.sqlite3_step(stmt)
                if code != 100:
                    break
                rows.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
            if code == 101:
                code = 0
        answer = (code, lib.sqlite3_errmsg(db) if code else None, rows)
        lib.sqlite3_finalize(stmt)
        return answer

    def describe(ctx, argc, argv):
        value = argv[0]
        blob = lib.sqlite3_value_blob(value)
        size = lib.sqlite3_value_bytes(value)
        text = "%d|%d|%r|%s|%d|%s" % (
            lib.sqlite3_value_type(value),
            lib.sqlite3_value_int64(value),
            lib.sqlite3_value_double(value),
            lib.sqlite3_value_text(value),
            size,
            ctypes.string_at(blob, size).hex() if blob else None,
        )
        encoded = text.encode()
        lib.sqlite3_result_text(ctx, encoded, len(encoded), TRANSIENT)

    def numeric(ctx, argc, argv):
        lib.sqlite3_result_int64(ctx, lib.sqlite3_value_numeric_type(argv[0]))

    def failing(ctx, argc, argv):
        lib.sqlite3_result_error(ctx, b"custom failure", -1)
        lib.sqlite3_result_error_code(ctx, lib.sqlite3_value_int64(argv[0]))

    def failing_plain(ctx, argc, argv):
        lib.sqlite3_result_error(ctx, b"plain failure, cut here", 13)

    def blobby(ctx, argc, argv):
        lib.sqlite3_result_blob(ctx, b"\x00\x01\x02", 3, TRANSIENT)

    def zeros(ctx, argc, argv):
        lib.sqlite3_result_zeroblob(ctx, lib.sqlite3_value_int64(argv[0]))

    def echo(ctx, argc, argv):
        copy = lib.sqlite3_value_dup(argv[0])
        lib.sqlite3_result_value(ctx, copy)
        lib.sqlite3_value_free(copy)

    def whoami(ctx, argc, argv):
        same_db = lib.sqlite3_context_db_handle(ctx) == db.value
        lib.sqlite3_result_int64(ctx, (lib.sqlite3_user_data(ctx) or 0) + (1 if same_db else 0))

    def one(ctx, argc, argv):
        lib.sqlite3_result_int64(ctx, 1)

    def two(ctx, argc, argv):
        lib.sqlite3_result_int64(ctx, 2)

    def shout(ctx, argc, argv):
        lib.sqlite3_result_text(ctx, b"X", 1, TRANSIENT)

    def aux(ctx, argc, argv):
        before = lib.sqlite3_get_auxdata(ctx, 0)
        lib.sqlite3_set_auxdata(ctx, 0, c_void_p(77), None)
        lib.sqlite3_result_int64(ctx, (lib.sqlite3_get_auxdata(ctx, 0) or 0) + (1000 if before else 0))

    def sq_step(ctx, argc, argv):
        cell = lib.sqlite3_aggregate_context(ctx, 8)
        total = ctypes.cast(cell, ctypes.POINTER(c_longlong))
        x = lib.sqlite3_value_int64(argv[0])
        total[0] += x * x

    def sq_final(ctx):
        cell = lib.sqlite3_aggregate_context(ctx, 0)
        if not cell:
            lib.sqlite3_result_null(ctx)
            return
        lib.sqlite3_result_int64(ctx, ctypes.cast(cell, ctypes.POINTER(c_longlong))[0])

    destroyed = []

    def destroy(pointer):
        destroyed.append(pointer)

    for name, arity, func in (
        (b"describe", 1, describe), (b"numeric", 1, numeric), (b"failing", 1, failing),
        (b"failing_plain", 0, failing_plain), (b"blobby", 0, blobby), (b"zeros", 1, zeros),
        (b"echo", 1, echo), (b"whoami", 0, whoami), (b"pick", 1, one), (b"pick", 2, two),
        (b"aux", 0, aux),
    ):
        assert register(name, arity, func=func) == 0, name
    assert register(b"sumsq", 1, step=sq_step, final=sq_final) == 0

    for literal in (b"42", b"4.75", b"'12abc'", b"' 7'", b"'1e3'", b"'x'", b"NULL", b"x'3132'", b"9.9e30", b"-0.5",
                    b"'12.9'", b"'99999999999999999999'", b"'-99999999999999999999'", b"'-9223372036854775808'"):
        seen[f"describe({literal.decode()})"] = first_failure(b"SELECT describe(" + literal + b")")
    for literal in (b"'12'", b"' 3.5 '", b"'12abc'", b"7", b"x'31'"):
        seen[f"numeric_type({literal.decode()})"] = first_failure(b"SELECT numeric(" + literal + b")")
    seen["failing with SQLITE_CONSTRAINT"] = first_failure(b"SELECT failing(19)")
    seen["failing: errcode, extended"] = (lib.sqlite3_errcode(db), lib.sqlite3_extended_errcode(db))
    seen["failing with an extended code"] = first_failure(b"SELECT failing(2067)")
    seen["failing: extended errcode"] = lib.sqlite3_extended_errcode(db)
    seen["failing with a cut message"] = first_failure(b"SELECT failing_plain()")
    seen["results"] = first_failure(b"SELECT hex(blobby()), length(zeros(5)), hex(zeros(2)), echo('t'), echo(2.5), typeof(echo(NULL))")
    seen["user data and db handle"] = first_failure(b"SELECT whoami()")
    seen["arities"] = first_failure(b"SELECT pick(1), pick(1, 2)")
    seen["an arity nobody registered"] = first_failure(b"SELECT pick(1, 2, 3)")
    seen["auxdata within a call"] = first_failure(b"SELECT aux()")

    # A function with a builtin's name replaces it. (Deleting it again leaves
    # SQLite answering "wrong number of arguments" for upper() rather than the
    # builtin; this facade gives the builtin back, and that is not compared.)
    seen["override upper"] = register(b"upper", 1, func=shout)
    seen["upper overridden"] = first_failure(b"SELECT upper('a')")
    seen["delete upper"] = lib.sqlite3_create_function_v2(db, b"upper", 1, 1, None, None, None, None, None)

    lib.sqlite3_exec(db, b"CREATE TABLE sq (g TEXT, x INTEGER)", None, None, None)
    lib.sqlite3_exec(db, b"INSERT INTO sq VALUES ('a', 1), ('a', 2), ('b', 3)", None, None, None)
    seen["aggregate"] = first_failure(b"SELECT sumsq(x) FROM sq")
    seen["aggregate per group"] = first_failure(b"SELECT g, sumsq(x) FROM sq GROUP BY g ORDER BY g")
    seen["aggregate over no row"] = first_failure(b"SELECT sumsq(x) FROM sq WHERE x > 99")

    # Misuse is refused, and a destructor runs on replace and on delete.
    seen["arity 200 is misuse"] = lib.sqlite3_create_function_v2(db, b"bad", 200, 1, None, None, None, None, None)
    seen["func and step is misuse"] = register(b"bad", 1, func=one, step=sq_step, final=sq_final)
    register(b"temp", 0, func=one, destroy=destroy, user=5)
    register(b"temp", 0, func=two, destroy=destroy, user=6)
    seen["destroyed on replace"] = list(destroyed)
    lib.sqlite3_create_function_v2(db, b"temp", 0, 1, None, None, None, None, None)
    seen["destroyed on delete"] = list(destroyed)
    seen["temp after delete"] = first_failure(b"SELECT temp()")[0]
    lib._function_callbacks = keep
