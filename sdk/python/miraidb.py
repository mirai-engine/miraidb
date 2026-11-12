"""A typed client for the C ABI, so a Python program can use the engine.

The engine ships a small C surface (`include/miraidb.h`); this module wraps it in
`Connection`, `Statement` and `Row` objects. It is the reference for what a
generated binding must look like: no engine types cross, only handles and the
functions the header declares.

    >>> with miraidb.connect("app.db") as db:
    ...     db.execute("INSERT INTO notes (body) VALUES (?)", "hello")
    ...     for row in db.query("SELECT body FROM notes"):
    ...         print(row["body"])
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
from typing import Any, Iterable, Iterator, Sequence

__all__ = ["Error", "connect", "Connection", "Row", "Statement", "version"]

# Result codes from the header: miraidb_step returns SQLITE_ROW/0 or DONE/1.
_ROW = 100
_DONE = 101

# Column kinds from the header: NULL, BOOL, INT, FLOAT, TEXT, BLOB, OTHER.
_COLUMN_TYPES = {1: bool, 2: int, 3: float, 4: str, 5: bytes}


class Error(Exception):
    """An engine error, with the message the engine reported."""


def _library() -> ctypes.CDLL:
    override = os.environ.get("MIRAIDB_LIBRARY")
    candidates = [override] if override else []
    candidates += [
        "miraidb.dll",
        "libmiraidb.so",
        "libmiraidb.dylib",
        os.path.join(os.path.dirname(__file__), "..", "..", "bin", "miraidb.dll"),
        os.path.join(os.path.dirname(__file__), "..", "..", "bin", "libmiraidb.so"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        if os.path.exists(candidate) or not os.path.sep in candidate:
            try:
                return ctypes.CDLL(candidate)
            except OSError:
                continue
    raise Error("cannot find the miraidb library; set MIRAIDB_LIBRARY")


_lib = _library()

_lib.miraidb_open.restype = ctypes.c_void_p
_lib.miraidb_open.argtypes = [ctypes.c_char_p]
_lib.miraidb_close.argtypes = [ctypes.c_void_p]
_lib.miraidb_errmsg.restype = ctypes.c_char_p
_lib.miraidb_errmsg.argtypes = [ctypes.c_void_p]
_lib.miraidb_exec.restype = ctypes.c_int
_lib.miraidb_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.miraidb_prepare.restype = ctypes.c_void_p
_lib.miraidb_prepare.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.miraidb_step.restype = ctypes.c_int
_lib.miraidb_step.argtypes = [ctypes.c_void_p]
_lib.miraidb_finalize.argtypes = [ctypes.c_void_p]
_lib.miraidb_reset.argtypes = [ctypes.c_void_p]
_lib.miraidb_bind_int.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_longlong]
_lib.miraidb_bind_double.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_double]
_lib.miraidb_bind_text.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
_lib.miraidb_bind_null.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.miraidb_column_count.argtypes = [ctypes.c_void_p]
_lib.miraidb_column_name.restype = ctypes.c_char_p
_lib.miraidb_column_name.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.miraidb_column_type.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.miraidb_column_int.restype = ctypes.c_longlong
_lib.miraidb_column_int.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.miraidb_column_double.restype = ctypes.c_double
_lib.miraidb_column_double.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.miraidb_column_text.restype = ctypes.c_char_p
_lib.miraidb_column_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.miraidb_version.restype = ctypes.c_char_p


def version() -> str:
    """The engine version string."""
    raw = _lib.miraidb_version()
    return raw.decode() if raw else "unknown"


class Row(dict):
    """One result row: a dict by column name, plus positional access."""

    def __init__(self, names: Sequence[str], values: Sequence[Any]):
        super().__init__(zip(names, values))
        self._values = tuple(values)

    def __getitem__(self, key: Any) -> Any:
        if isinstance(key, int):
            return self._values[key]
        return super().__getitem__(key)


class Statement:
    """A prepared statement; use it directly or through the connection helpers."""

    def __init__(self, connection: "Connection", sql: str):
        self._connection = connection
        self._handle = _lib.miraidb_prepare(connection._handle, sql.encode())
        if not self._handle:
            raise connection._error()

    def bind(self, *args: Any) -> "Statement":
        for index, value in enumerate(args):
            # The ABI numbers parameters from zero; SQL's `?` placeholders are
            # bound in the order they appear.
            position = index
            if value is None:
                _lib.miraidb_bind_null(self._handle, position)
            elif isinstance(value, bool):
                _lib.miraidb_bind_int(self._handle, position, int(value))
            elif isinstance(value, int):
                _lib.miraidb_bind_int(self._handle, position, value)
            elif isinstance(value, float):
                _lib.miraidb_bind_double(self._handle, position, value)
            elif isinstance(value, str):
                _lib.miraidb_bind_text(self._handle, position, value.encode())
            else:
                raise TypeError(f"cannot bind {type(value).__name__}")
        return self

    def _row(self) -> Row:
        count = _lib.miraidb_column_count(self._handle)
        names = [
            (_lib.miraidb_column_name(self._handle, index) or b"").decode()
            for index in range(count)
        ]
        values = []
        for index in range(count):
            kind = _lib.miraidb_column_type(self._handle, index)
            if kind == 1:
                values.append(bool(_lib.miraidb_column_int(self._handle, index)))
            elif kind == 2:
                values.append(_lib.miraidb_column_int(self._handle, index))
            elif kind == 3:
                values.append(_lib.miraidb_column_double(self._handle, index))
            elif kind == 4:
                values.append((_lib.miraidb_column_text(self._handle, index) or b"").decode())
            else:
                values.append(None)
        return Row(names, values)

    def __iter__(self) -> Iterator[Row]:
        while True:
            code = _lib.miraidb_step(self._handle)
            if code == _ROW:
                yield self._row()
                continue
            if code == _DONE:
                return
            raise self._connection._error()

    def close(self) -> None:
        if self._handle:
            _lib.miraidb_finalize(self._handle)
            self._handle = None

    def __enter__(self) -> "Statement":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()


class Connection:
    """One open database."""

    def __init__(self, path: str, create: bool = True):
        if not create and not os.path.exists(path):
            raise Error(f"{path} does not exist")
        self._handle = _lib.miraidb_open(path.encode())
        if not self._handle:
            raw = _lib.miraidb_errmsg(None)
            raise Error(raw.decode() if raw else "cannot open the database")

    def _error(self) -> Error:
        message = _lib.miraidb_errmsg(self._handle) if self._handle else None
        return Error(message.decode() if message else "engine error")

    def execute(self, sql: str, *args: Any) -> int:
        """Run a statement and return the number of affected rows."""
        if args:
            with self.prepare(sql) as statement:
                statement.bind(*args)
                for _ in statement:
                    pass
                return 1
        if _lib.miraidb_exec(self._handle, sql.encode()) != 0:
            raise self._error()
        return 1

    def prepare(self, sql: str) -> Statement:
        return Statement(self, sql)

    def query(self, sql: str, *args: Any) -> Iterable[Row]:
        with self.prepare(sql) as statement:
            if args:
                statement.bind(*args)
            yield from statement

    def close(self) -> None:
        if self._handle:
            _lib.miraidb_close(self._handle)
            self._handle = None

    def __enter__(self) -> "Connection":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()


def connect(path: str, create: bool = True) -> Connection:
    """Open `path`, creating it when `create` is true."""
    return Connection(path, create)
