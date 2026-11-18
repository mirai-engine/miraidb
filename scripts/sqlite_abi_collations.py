"""Application-defined collations, driven the same way through the facade and
SQLite: sqlite3_create_collation(_v2, 16) and sqlite3_collation_needed(16).

What is compared: comparisons under a collation (WHERE, IN, BETWEEN, CASE),
ORDER BY under it over NULLs, numbers, text and blobs, ascending and
descending, with ties broken by the next term; a UTF-16 collation receiving
UTF-16 bytes; a collation registered on demand by collation_needed; the
destructor count after a replace, a delete and a close; and the prepare error
for a collation nobody knows. Used by scripts/sqlite_abi_reference.py.
"""

from __future__ import annotations

import ctypes

c_void_p, c_int, c_char_p = ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p

COMPARE = ctypes.CFUNCTYPE(c_int, c_void_p, c_int, c_void_p, c_int, c_void_p)
DESTROY = ctypes.CFUNCTYPE(None, c_void_p)
NEEDED = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_int, c_char_p)
NEEDED16 = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_int, c_void_p)
UTF8, UTF16LE = 1, 2

SIGNATURES = {
    "sqlite3_create_collation": ([c_void_p, c_char_p, c_int, c_void_p, c_void_p], c_int),
    "sqlite3_create_collation_v2": ([c_void_p, c_char_p, c_int, c_void_p, c_void_p, c_void_p], c_int),
    "sqlite3_create_collation16": ([c_void_p, c_void_p, c_int, c_void_p, c_void_p], c_int),
    "sqlite3_collation_needed": ([c_void_p, c_void_p, c_void_p], c_int),
    "sqlite3_collation_needed16": ([c_void_p, c_void_p, c_void_p], c_int),
}


def observe(lib, seen: dict) -> None:
    for name, (args, result) in SIGNATURES.items():
        function = getattr(lib, name)
        function.argtypes = args
        function.restype = result
    keep: list = []
    db = c_void_p()
    assert lib.sqlite3_open(b":memory:", ctypes.byref(db)) == 0
    for sql in (b"CREATE TABLE w (id INTEGER PRIMARY KEY, v TEXT)",
                b"INSERT INTO w (v) VALUES ('b'), ('a'), ('B'), ('ab'), ('A')",
                b"CREATE TABLE t (id INTEGER PRIMARY KEY, v ANY)",
                b"INSERT INTO t (v) VALUES (NULL), (3), ('b'), ('a'), (x'00'), (1.5), ('B'), ('ab'), ('A')"):
        assert lib.sqlite3_exec(db, sql, None, None, None) == 0

    def compare_with(key):
        def call(arg, n1, s1, n2, s2):
            a = ctypes.string_at(s1, n1) if n1 else b""
            b = ctypes.string_at(s2, n2) if n2 else b""
            ka, kb = key(a), key(b)
            return (ka > kb) - (ka < kb)
        callback = COMPARE(call)
        keep.append(callback)
        return ctypes.cast(callback, c_void_p)

    destroyed: list = []
    destroy = DESTROY(lambda p: destroyed.append(p))
    keep.append(destroy)
    destroy_p = ctypes.cast(destroy, c_void_p)

    reverse = compare_with(lambda s: bytes(255 - x for x in s) + b"\xff")
    fold = compare_with(lambda s: s.lower())
    seen["create rev"] = lib.sqlite3_create_collation_v2(db, b"rev", UTF8, c_void_p(1), reverse, destroy_p)
    seen["create fold"] = lib.sqlite3_create_collation(db, b"Fold", UTF8, None, fold)

    def rows(sql: bytes):
        stmt = c_void_p()
        code = lib.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(stmt), None)
        if code:
            return code, lib.sqlite3_errmsg(db)
        out = []
        while (step := lib.sqlite3_step(stmt)) == 100:
            out.append(tuple(lib.sqlite3_column_text(stmt, i) for i in range(lib.sqlite3_column_count(stmt))))
        lib.sqlite3_finalize(stmt)
        return step, out

    for sql in (
        b"SELECT v FROM t ORDER BY v COLLATE rev",
        b"SELECT v FROM t ORDER BY v COLLATE rev DESC",
        b"SELECT v FROM t ORDER BY v COLLATE fold, id",
        b"SELECT v FROM t ORDER BY v COLLATE fold DESC, id DESC",
        # A text column: comparing across storage classes is backlog S7.
        b"SELECT id FROM w WHERE v = 'a' COLLATE fold ORDER BY id",
        b"SELECT id FROM w WHERE v COLLATE fold IN ('b', 'ab') ORDER BY id",
        b"SELECT id FROM w WHERE v COLLATE fold BETWEEN 'a' AND 'ab' ORDER BY id",
        b"SELECT id FROM w WHERE v COLLATE nocase IN ('b') ORDER BY id",
        b"SELECT id FROM w WHERE v COLLATE nocase BETWEEN 'a' AND 'a' ORDER BY id",
        b"SELECT CASE WHEN 'X' = 'x' COLLATE fold THEN 1 ELSE 0 END",
        b"SELECT v FROM t WHERE typeof(v) = 'text' ORDER BY v COLLATE rev LIMIT 2 OFFSET 1",
        b"SELECT 1 ORDER BY 1 COLLATE nope",
        # Grouping under a host collation: equality classes, as SQLite groups.
        b"SELECT count(*) FROM w GROUP BY v COLLATE fold ORDER BY 1",
        b"SELECT count(DISTINCT v COLLATE fold) FROM w",
        b"SELECT count(*) FROM (SELECT DISTINCT v COLLATE fold FROM w)",
        b"SELECT v, rank() OVER (PARTITION BY v COLLATE fold ORDER BY id) FROM w ORDER BY id",
        b"SELECT v, row_number() OVER (ORDER BY v COLLATE rev, id) FROM w ORDER BY id",
        b"SELECT v, rank() OVER (ORDER BY v COLLATE fold DESC) FROM w ORDER BY id",
        # An aggregate's own ORDER BY under a host collation.
        b"SELECT group_concat(v, ',' ORDER BY v COLLATE rev, id) FROM w",
        b"SELECT group_concat(v, ',' ORDER BY v COLLATE fold DESC, id) FROM w",
        b"SELECT json_group_array(v ORDER BY v COLLATE rev) FILTER (WHERE id > 1) FROM w",
        # A column declared with the collation compares, sorts and groups by it.
        b"CREATE TABLE hc (id INTEGER PRIMARY KEY, v TEXT COLLATE fold)",
        b"INSERT INTO hc (v) VALUES ('b'), ('A'), ('a'), ('B'), ('c')",
        b"SELECT id FROM hc WHERE v = 'a' ORDER BY id",
        b"SELECT v FROM hc ORDER BY v, id",
        b"SELECT count(*) FROM hc GROUP BY v ORDER BY 1",
        b"SELECT count(*) FROM (SELECT DISTINCT v FROM hc)",
        b"SELECT id FROM hc WHERE v IN ('B', 'C') ORDER BY id",
        b"CREATE TABLE hc2 (v TEXT COLLATE never_registered)",
        # A key under a host collation: the comparison decides what repeats.
        b"CREATE TABLE hk (id INTEGER PRIMARY KEY, v TEXT COLLATE fold UNIQUE)",
        b"INSERT INTO hk (v) VALUES ('a')",
        b"INSERT INTO hk (v) VALUES ('A')",
        b"INSERT INTO hk (v) VALUES ('b')",
        b"UPDATE hk SET v = 'B' WHERE v = 'b'",
        b"UPDATE hk SET v = 'a' WHERE v = 'B'",
        b"CREATE TABLE hp (v TEXT COLLATE fold PRIMARY KEY, n INTEGER)",
        b"INSERT INTO hp VALUES ('x', 1), ('X', 2)",
        b"CREATE INDEX hk_v ON hk (v)",
        b"SELECT id FROM hk WHERE v = 'A' ORDER BY id",
        b"SELECT group_concat(v, ',') FROM (SELECT v FROM hk ORDER BY v, id)",
    ):
        seen[f"collation: {sql!r}"] = rows(sql)

    # UTF-16: the comparison is handed UTF-16 bytes.
    sizes: list = []

    def by_size(arg, n1, s1, n2, s2):
        sizes.extend((n1, n2))
        return (n1 > n2) - (n1 < n2)
    size16 = COMPARE(by_size)
    keep.append(size16)
    name16 = ctypes.create_string_buffer("size".encode("utf-16-le") + b"\0\0")
    seen["create16"] = lib.sqlite3_create_collation16(db, name16, UTF16LE, None, ctypes.cast(size16, c_void_p))
    seen["collation16 order"] = rows("SELECT x FROM (SELECT 'é' AS x UNION ALL SELECT 'ab' UNION ALL SELECT 'abc') ORDER BY x COLLATE size".encode())
    seen["collation16 byte lengths"] = sorted(set(sizes))

    # collation_needed registers the collation the first time a statement names it.
    asked: list = []

    def needed(arg, handle, rep, name):
        asked.append((rep, name))
        lib.sqlite3_create_collation(handle, name, UTF8, None, reverse)
    needed_cb = NEEDED(needed)
    keep.append(needed_cb)
    seen["collation_needed"] = lib.sqlite3_collation_needed(db, None, ctypes.cast(needed_cb, c_void_p))
    seen["needed: order"] = rows(b"SELECT v FROM t WHERE typeof(v) = 'text' ORDER BY v COLLATE late")
    seen["needed: asked"] = asked[:1]

    # A built-in name may be replaced on the connection, a column declared
    # with it included, and deleting the replacement restores it here. (An index
    # built under the old rule is left out: SQLite documents that changing a
    # collation under an index corrupts what the index answers.)
    rows(b"CREATE TABLE nc (id INTEGER PRIMARY KEY, v TEXT COLLATE NOCASE)")
    rows(b"INSERT INTO nc (v) VALUES ('a'), ('A'), ('b'), ('B')")
    seen["replace NOCASE"] = lib.sqlite3_create_collation(db, b"NOCASE", UTF8, None, reverse)
    for sql in (b"SELECT 'a' = 'A' COLLATE NOCASE, 'b' < 'a' COLLATE NOCASE",
                b"SELECT v FROM nc ORDER BY v, id",
                b"SELECT id FROM nc WHERE v = 'a' ORDER BY id",
                b"SELECT count(*) FROM nc GROUP BY v ORDER BY 1"):
        seen[f"replaced NOCASE: {sql!r}"] = rows(sql)
    # Deleting the replacement gives the built-in rule back here; SQLite is
    # left comparing in BINARY, so that answer is not compared.
    lib.sqlite3_create_collation(db, b"NOCASE", UTF8, None, None)

    # Replace and delete run the destructor; close runs the rest.
    lib.sqlite3_create_collation_v2(db, b"rev", UTF8, c_void_p(2), reverse, destroy_p)
    seen["destroyed after replace"] = len(destroyed)
    lib.sqlite3_create_collation_v2(db, b"rev", UTF8, None, None, None)
    seen["destroyed after delete"] = len(destroyed)
    seen["deleted collation"] = rows(b"SELECT 1 ORDER BY 1 COLLATE rev")
    lib.sqlite3_create_collation_v2(db, b"rev", UTF8, c_void_p(3), reverse, destroy_p)
    lib.sqlite3_close(db)
    seen["destroyed after close"] = len(destroyed)
