"""Virtual table modules, driven the same way through the facade and SQLite.

Two modules written here with ctypes are registered on both libraries:

- `series`, eponymous only (no xCreate): `FROM series(start, stop[, step])`
  passes its arguments as equality constraints on HIDDEN columns, which
  xBestIndex takes and xFilter receives.
- `kvmod`, a table made with CREATE VIRTUAL TABLE: its rows live in a Python
  dict, and INSERT, UPDATE and DELETE reach it through xUpdate.

What is compared: the rows of every query, `SELECT *` leaving the HIDDEN
columns out, WHERE terms offered to xBestIndex, the arguments xCreate receives
(not how often SQLite connects again), the arguments xUpdate receives,
changes(), an error a module reports, the destructor calls, and the errors for
a module nobody registered. Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes

c_void_p, c_int, c_char_p, c_longlong, c_ubyte, c_double, c_uint64 = (
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_longlong, ctypes.c_ubyte, ctypes.c_double, ctypes.c_uint64,
)


class Vtab(ctypes.Structure):
    _fields_ = [("pModule", c_void_p), ("nRef", c_int), ("zErrMsg", c_void_p)]


class Cursor(ctypes.Structure):
    _fields_ = [("pVtab", c_void_p)]


class Constraint(ctypes.Structure):
    _fields_ = [("iColumn", c_int), ("op", c_ubyte), ("usable", c_ubyte), ("iTermOffset", c_int)]


class OrderBy(ctypes.Structure):
    _fields_ = [("iColumn", c_int), ("desc", c_ubyte)]


class Usage(ctypes.Structure):
    _fields_ = [("argvIndex", c_int), ("omit", c_ubyte)]


class IndexInfo(ctypes.Structure):
    _fields_ = [
        ("nConstraint", c_int), ("aConstraint", ctypes.POINTER(Constraint)),
        ("nOrderBy", c_int), ("aOrderBy", c_void_p),
        ("aConstraintUsage", ctypes.POINTER(Usage)),
        ("idxNum", c_int), ("idxStr", c_char_p), ("needToFreeIdxStr", c_int), ("orderByConsumed", c_int),
        ("estimatedCost", c_double), ("estimatedRows", c_longlong), ("idxFlags", c_int), ("colUsed", c_uint64),
    ]


CONSTRUCT = ctypes.CFUNCTYPE(c_int, c_void_p, c_void_p, c_int, ctypes.POINTER(c_char_p), ctypes.POINTER(c_void_p), ctypes.POINTER(c_void_p))
BEST = ctypes.CFUNCTYPE(c_int, c_void_p, ctypes.POINTER(IndexInfo))
ONE = ctypes.CFUNCTYPE(c_int, c_void_p)
OPEN = ctypes.CFUNCTYPE(c_int, c_void_p, ctypes.POINTER(c_void_p))
FILTER = ctypes.CFUNCTYPE(c_int, c_void_p, c_int, c_char_p, c_int, ctypes.POINTER(c_void_p))
COLUMN = ctypes.CFUNCTYPE(c_int, c_void_p, c_void_p, c_int)
ROWID = ctypes.CFUNCTYPE(c_int, c_void_p, ctypes.POINTER(c_longlong))
UPDATE = ctypes.CFUNCTYPE(c_int, c_void_p, c_int, ctypes.POINTER(c_void_p), ctypes.POINTER(c_longlong))
LEVEL = ctypes.CFUNCTYPE(c_int, c_void_p, c_int)
RENAME = ctypes.CFUNCTYPE(c_int, c_void_p, c_char_p)
FIND = ctypes.CFUNCTYPE(c_int, c_void_p, c_int, c_char_p, ctypes.POINTER(c_void_p), ctypes.POINTER(c_void_p))
SCALAR = ctypes.CFUNCTYPE(None, c_void_p, c_int, ctypes.POINTER(c_void_p))
DESTROY = ctypes.CFUNCTYPE(None, c_void_p)

NAMES = ["xCreate", "xConnect", "xBestIndex", "xDisconnect", "xDestroy", "xOpen", "xClose", "xFilter", "xNext",
         "xEof", "xColumn", "xRowid", "xUpdate", "xBegin", "xSync", "xCommit", "xRollback", "xFindFunction",
         "xRename", "xSavepoint", "xRelease", "xRollbackTo", "xShadowName", "xIntegrity"]


class Module(ctypes.Structure):
    _fields_ = [("iVersion", c_int)] + [(name, c_void_p) for name in NAMES]


SIGNATURES = {
    "sqlite3_create_module": ([c_void_p, c_char_p, ctypes.POINTER(Module), c_void_p], c_int),
    "sqlite3_create_module_v2": ([c_void_p, c_char_p, ctypes.POINTER(Module), c_void_p, c_void_p], c_int),
    "sqlite3_declare_vtab": ([c_void_p, c_char_p], c_int),
    "sqlite3_drop_modules": ([c_void_p, ctypes.POINTER(c_char_p)], c_int),
    "sqlite3_vtab_config": ([c_void_p, c_int], c_int),
    "sqlite3_vtab_on_conflict": ([c_void_p], c_int),
    "sqlite3_value_int64": ([c_void_p], c_longlong),
    "sqlite3_value_type": ([c_void_p], c_int),
    "sqlite3_value_text": ([c_void_p], c_char_p),
    "sqlite3_result_int64": ([c_void_p, c_longlong], None),
    "sqlite3_result_text": ([c_void_p, c_char_p, c_int, c_void_p], None),
    "sqlite3_result_null": ([c_void_p], None),
    "sqlite3_malloc": ([c_int], c_void_p),
}

TRANSIENT = c_void_p(-1)


def observe(lib, seen: dict) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result
    keep: list = []

    def c_string(text: bytes):
        """A string SQLite will free with sqlite3_free."""
        block = lib.sqlite3_malloc(len(text) + 1)
        ctypes.memmove(block, text + b"\0", len(text) + 1)
        return block

    def value(handle):
        kind = lib.sqlite3_value_type(handle)
        if kind == 5:
            return None
        if kind == 1:
            return lib.sqlite3_value_int64(handle)
        return lib.sqlite3_value_text(handle)

    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0
    calls: list = []
    vtabs: dict = {}
    cursors: dict = {}

    def new_vtab(state):
        vtab = Vtab()
        keep.append(vtab)
        vtabs[ctypes.addressof(vtab)] = state
        return vtab

    # --- series: eponymous only --------------------------------------------
    def series_connect(handle, aux, argc, argv, out, err):
        calls.append(("series connect", [argv[i] for i in range(argc)]))
        assert lib.sqlite3_declare_vtab(handle, b"CREATE TABLE x(value, start HIDDEN, stop HIDDEN, step HIDDEN)") == 0
        vtab = new_vtab({})
        out[0] = ctypes.addressof(vtab)
        return 0

    def series_best(vtab, info):
        info = info.contents
        mask = 0
        slot = 1
        for i in range(info.nConstraint):
            constraint = info.aConstraint[i]
            if constraint.usable and constraint.op == 2 and 1 <= constraint.iColumn <= 3:
                info.aConstraintUsage[i].argvIndex = slot
                info.aConstraintUsage[i].omit = 1
                mask |= 1 << (constraint.iColumn - 1)
                slot += 1
        info.idxNum = mask
        # Without a stop the series is empty: a plan that cannot bind it is the
        # worst one, so SQLite picks the plan that binds it.
        info.estimatedCost = 10.0 if mask & 2 else 1e9
        return 0

    def series_open(vtab, out):
        cursor = Cursor()
        keep.append(cursor)
        cursors[ctypes.addressof(cursor)] = {"rows": [], "at": 0}
        out[0] = ctypes.addressof(cursor)
        return 0

    def series_filter(cursor, idx_num, idx_str, argc, argv):
        args = [lib.sqlite3_value_int64(argv[i]) for i in range(argc)]
        bounds = {}
        for bit in range(3):
            if idx_num & (1 << bit):
                bounds[bit] = args.pop(0)
        start, stop, step = bounds.get(0, 0), bounds.get(1, -1), bounds.get(2, 1) or 1
        state = cursors[cursor]
        state["rows"] = [(v, start, stop, step) for v in range(start, stop + 1, step)] if stop >= start else []
        state["at"] = 0
        return 0

    def series_next(cursor):
        cursors[cursor]["at"] += 1
        return 0

    def series_eof(cursor):
        state = cursors[cursor]
        return 1 if state["at"] >= len(state["rows"]) else 0

    def series_column(cursor, ctx, column):
        state = cursors[cursor]
        lib.sqlite3_result_int64(ctx, state["rows"][state["at"]][column])
        return 0

    def series_rowid(cursor, out):
        out[0] = cursors[cursor]["at"] + 1
        return 0

    def close(cursor):
        cursors.pop(cursor, None)
        return 0

    disconnected: list = []

    def disconnect(vtab):
        disconnected.append(vtabs.get(vtab, {}).get("name", "series"))
        return 0

    destroyed: list = []

    def destroy_vtab(vtab):
        destroyed.append(vtabs.get(vtab, {}).get("name"))
        return 0

    def module(**methods):
        m = Module()
        m.iVersion = 1
        for name, function in methods.items():
            keep.append(function)
            setattr(m, name, ctypes.cast(function, c_void_p))
        keep.append(m)
        return m

    series = module(
        xConnect=CONSTRUCT(series_connect), xBestIndex=BEST(series_best), xDisconnect=ONE(disconnect),
        xOpen=OPEN(series_open), xClose=ONE(close), xFilter=FILTER(series_filter), xNext=ONE(series_next),
        xEof=ONE(series_eof), xColumn=COLUMN(series_column), xRowid=ROWID(series_rowid),
    )
    seen["create_module series"] = lib.sqlite3_create_module(db, b"series", ctypes.byref(series), None)

    def rows(sql: bytes):
        stmt = c_void_p()
        code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
        if code:
            return code, lib.sqlite3_errmsg(db)
        out = [tuple(lib.sqlite3_column_name(stmt, i) for i in range(lib.sqlite3_column_count(stmt)))]
        while (step := lib.sqlite3_step(stmt)) == 100:
            out.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
        message = lib.sqlite3_errmsg(db) if step != 101 else None
        lib.sqlite3_finalize(stmt)
        return step, message, out, lib.sqlite3_changes(db)

    for sql in (
        b"SELECT value FROM series(1, 5)",
        b"SELECT * FROM series(2, 10, 3)",
        b"SELECT value, start, stop, step FROM series(1, 3)",
        b"SELECT sum(value) FROM series(1, 100) WHERE value % 2 = 0",
        b"SELECT a.value, b.value FROM series(1, 2) AS a, series(1, 2) AS b ORDER BY 1, 2",
        b"SELECT rowid, value FROM series(5, 7)",
        b"SELECT value FROM series WHERE start = 3 AND stop = 4",
        b"SELECT count(*) FROM series",
        b"SELECT value FROM series(1, 3) ORDER BY value DESC LIMIT 2",
        # Arguments and join terms that read an earlier table: one scan per row.
        b"WITH t(n) AS (VALUES (1), (2), (3)) SELECT t.n, s.value FROM t, series(1, t.n) AS s ORDER BY 1, 2",
        b"WITH t(n) AS (VALUES (2), (3)) SELECT t.n, s.value FROM t JOIN series AS s ON s.start = 1 AND s.stop = t.n ORDER BY 1, 2",
        b"WITH t(n) AS (VALUES (2), (4)) SELECT t.n, (SELECT count(*) FROM series(1, t.n)) FROM t ORDER BY 1",
        b"CREATE VIRTUAL TABLE s USING series",
        b"CREATE VIRTUAL TABLE z USING nomodule(a)",
        b"SELECT * FROM nomodule",
    ):
        seen[f"series: {sql!r}"] = rows(sql)
    seen["series: connects"] = sorted({tuple(args) for name, args in calls if name == "series connect"})

    # --- kvmod: CREATE VIRTUAL TABLE, written through xUpdate -----------------
    updates: list = []
    tables: dict = {}

    def kv_create(handle, aux, argc, argv, out, err):
        args = [argv[i] for i in range(argc)]
        calls.append(("kv create", args))
        if b"fail" in args[3:]:
            err[0] = c_string(b"kvmod refuses to fail")
            return 1
        assert lib.sqlite3_declare_vtab(handle, b"CREATE TABLE x(k TEXT, v INTEGER)") == 0
        # The rows belong to the table, not to one connection of it: SQLite
        # connects a table again after a schema change.
        name = args[2].decode()
        state = tables.setdefault(name, {"name": name, "rows": {}, "next": 1})
        vtab = new_vtab(state)
        out[0] = ctypes.addressof(vtab)
        return 0

    orders: list = []

    def kv_best(vtab, info):
        info = info.contents
        terms = ctypes.cast(info.aOrderBy, ctypes.POINTER(OrderBy))
        orders.append(tuple((terms[i].iColumn, terms[i].desc) for i in range(info.nOrderBy)))
        info.estimatedCost = 100.0
        return 0

    def kv_open(vtab, out):
        cursor = Cursor()
        keep.append(cursor)
        state = vtabs[vtab]
        cursors[ctypes.addressof(cursor)] = {"rows": sorted(state["rows"].items()), "at": 0}
        out[0] = ctypes.addressof(cursor)
        return 0

    def kv_filter(cursor, idx_num, idx_str, argc, argv):
        cursors[cursor]["at"] = 0
        return 0

    def kv_column(cursor, ctx, column):
        state = cursors[cursor]
        item = state["rows"][state["at"]][1][column]
        if item is None:
            lib.sqlite3_result_null(ctx)
        elif isinstance(item, int):
            lib.sqlite3_result_int64(ctx, item)
        else:
            lib.sqlite3_result_text(ctx, item, -1, TRANSIENT)
        return 0

    def kv_rowid(cursor, out):
        state = cursors[cursor]
        out[0] = state["rows"][state["at"]][0]
        return 0

    def kv_update(vtab, argc, argv, out):
        state = vtabs[vtab]
        args = [value(argv[i]) for i in range(argc)]
        updates.append(tuple(args))
        if argc == 1:
            state["rows"].pop(args[0], None)
            return 0
        if args[2] is None:
            vtab_struct = Vtab.from_address(vtab)
            vtab_struct.zErrMsg = c_string(b"kvmod: k is required")
            return 19
        new_rowid = args[1]
        if args[0] is None:
            if new_rowid is None:
                new_rowid = state["next"]
            state["next"] = max(state["next"], new_rowid + 1)
            out[0] = new_rowid
        else:
            state["rows"].pop(args[0], None)
        state["rows"][new_rowid] = [args[2], args[3]]
        return 0

    events: list = []

    def step(name):
        def call(vtab):
            events.append((name, vtabs.get(vtab, {}).get("name")))
            return 0
        return ONE(call)

    def level(name):
        def call(vtab, n):
            events.append((name, vtabs.get(vtab, {}).get("name"), n))
            return 0
        return LEVEL(call)

    def rename(vtab, new_name):
        state = vtabs[vtab]
        events.append(("rename", state["name"], new_name.decode()))
        tables[new_name.decode()] = tables.pop(state["name"])
        state["name"] = new_name.decode()
        return 0

    def shout(ctx, argc, argv):
        lib.sqlite3_result_text(ctx, b"overloaded", -1, TRANSIENT)
    shout_cb = SCALAR(shout)
    keep.append(shout_cb)

    def find(vtab, argc, name, func, arg):
        if name.lower() == b"upper" and argc == 1:
            func[0] = ctypes.cast(shout_cb, c_void_p)
            arg[0] = None
            return 1
        return 0

    kv = module(
        xCreate=CONSTRUCT(kv_create), xConnect=CONSTRUCT(kv_create), xBestIndex=BEST(kv_best),
        xDisconnect=ONE(disconnect), xDestroy=ONE(destroy_vtab), xOpen=OPEN(kv_open), xClose=ONE(close),
        xFilter=FILTER(kv_filter), xNext=ONE(series_next), xEof=ONE(series_eof), xColumn=COLUMN(kv_column),
        xRowid=ROWID(kv_rowid), xUpdate=UPDATE(kv_update),
        xBegin=step("begin"), xSync=step("sync"), xCommit=step("commit"), xRollback=step("rollback"),
        xSavepoint=level("savepoint"), xRelease=level("release"), xRollbackTo=level("rollback_to"),
        xRename=RENAME(rename), xFindFunction=FIND(find),
    )
    kv.iVersion = 2
    released: list = []
    release = DESTROY(lambda p: released.append(p))
    keep.append(release)
    seen["create_module_v2 kvmod"] = lib.sqlite3_create_module_v2(db, b"kvmod", ctypes.byref(kv), c_void_p(7), ctypes.cast(release, c_void_p))
    for sql in (
        b"CREATE VIRTUAL TABLE kv1 USING kvmod(alpha, 'b c', d = (1, 2))",
        b"CREATE VIRTUAL TABLE kv2 USING kvmod",
        b"CREATE VIRTUAL TABLE bad USING kvmod(fail)",
        b"INSERT INTO kv1 VALUES ('a', 1), ('b', 2)",
        b"INSERT INTO kv1 (rowid, k, v) VALUES (10, 'c', 3)",
        b"INSERT INTO kv1 (v) VALUES (4)",
        b"SELECT rowid, * FROM kv1 ORDER BY rowid",
        b"UPDATE kv1 SET v = v * 10 WHERE k = 'b'",
        b"UPDATE kv1 SET rowid = 20 WHERE k = 'c'",
        b"DELETE FROM kv1 WHERE v = 1",
        b"SELECT rowid, k, v FROM kv1 ORDER BY rowid",
        b"INSERT INTO kv2 SELECT k, v FROM kv1",
        b"SELECT k, v FROM kv2 ORDER BY k",
        b"SELECT k1.k, k2.v FROM kv1 AS k1 JOIN kv2 AS k2 ON k2.k = k1.k ORDER BY 1",
        b"SELECT nope FROM kv1",
        b"DROP TABLE kv2",
        b"SELECT * FROM kv2",
    ):
        seen[f"kvmod: {sql!r}"] = rows(sql)
    # Transactions reach the module: begin before the first write, sync then
    # commit, rollback, and the savepoints with their level.
    for script in (
        [b"INSERT INTO kv1 VALUES ('auto', 1)"],
        [b"BEGIN", b"INSERT INTO kv1 VALUES ('t1', 1)", b"SAVEPOINT a", b"INSERT INTO kv1 VALUES ('t2', 2)",
         b"ROLLBACK TO a", b"RELEASE a", b"COMMIT"],
        [b"BEGIN", b"INSERT INTO kv1 VALUES ('t3', 3)", b"ROLLBACK"],
        [b"BEGIN", b"SELECT count(*) FROM kv1", b"COMMIT"],
    ):
        events.clear()
        for sql in script:
            rows(sql)
        seen[f"kvmod transaction: {script!r}"] = list(events)
    # How often SQLite connects again (after a schema reload) is its own
    # business: the arguments each table is constructed with are compared.
    seen["kvmod: constructor arguments"] = sorted({tuple(args) for name, args in calls if name == "kv create"})
    events.clear()
    seen["kvmod: rename"] = rows(b"ALTER TABLE kv1 RENAME TO kv9")[:2]
    seen["kvmod: rename events"] = list(events)
    seen["kvmod: after rename"] = rows(b"SELECT count(*) FROM kv9")
    seen["kvmod: overloaded function"] = rows(b"SELECT upper(k), upper('plain') FROM kv9 ORDER BY rowid LIMIT 1")
    # The ORDER BY of a query that reads only the table is offered.
    orders.clear()
    seen["kvmod: ordered"] = rows(b"SELECT k, v FROM kv9 ORDER BY v DESC, k")
    seen["kvmod: ORDER BY offered"] = sorted(set(orders))
    seen["kvmod: updates"] = updates
    seen["kvmod: destroyed"] = destroyed
    seen["vtab_config"] = lib.sqlite3_vtab_config(db, 2)

    # drop_modules keeps the listed ones; close releases what is left.
    keep_list = (c_char_p * 2)(b"kvmod", None)
    seen["drop_modules"] = lib.sqlite3_drop_modules(db, keep_list)
    seen["series after drop_modules"] = rows(b"SELECT value FROM series(1, 2)")
    seen["kvmod after drop_modules"] = rows(b"SELECT count(*) FROM kv9")
    lib.sqlite3_close(db)
    seen["module destructor after close"] = len(released)
