#!/usr/bin/env python3
"""Broker check: one process owns the database, others speak the wire to it.

The server is a real process holding the directory lock; the clients below are
this script, talking HTTP with the wire messages the engine documents. It proves
the two claims broker mode makes:

* several clients read and write the same database without opening it
  themselves, and each request carries the commit sequence it saw;
* the owner is the only writer: a second server on the same directory is refused
  with `locked` and the owner's pid.

    python scripts/broker_smoke.py

The database lives in `_broker_tmp/` inside the repository so the path handed to
the Windows binary is the same one it can open.
"""

from __future__ import annotations

import concurrent.futures
import http.client
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, "bin", "miraidb-server.exe")

WIRE_QUERY = 2
WIRE_RESULT = 10
WIRE_ERROR = 13

# Value kinds, in the order of the engine's enum.
NULL, DEFAULT, BOOL, INT, UINT, FLOAT, TEXT = range(7)


def encode_string(text: str) -> bytes:
    raw = text.encode()
    return struct.pack("<I", len(raw)) + raw


def query_message(sql: str) -> bytes:
    return struct.pack("<I", WIRE_QUERY) + encode_string(sql) + struct.pack("<I", 0)


def read_value(data: bytes, at: int):
    kind = data[at]
    at += 1
    if kind in (NULL, DEFAULT):
        return None, at
    if kind == BOOL:
        return data[at] != 0, at + 1
    if kind in (INT,):
        return struct.unpack_from("<q", data, at)[0], at + 8
    if kind == UINT:
        return struct.unpack_from("<Q", data, at)[0], at + 8
    if kind == FLOAT:
        return struct.unpack_from("<d", data, at)[0], at + 8
    if kind == TEXT:
        size = struct.unpack_from("<I", data, at)[0]
        at += 4
        return data[at : at + size].decode(), at + size
    raise AssertionError(f"unhandled value kind {kind}")


def decode(data: bytes):
    kind = struct.unpack_from("<I", data, 0)[0]
    if kind == WIRE_ERROR:
        size = struct.unpack_from("<I", data, 4)[0]
        raise RuntimeError(data[8 : 8 + size].decode())
    assert kind == WIRE_RESULT, f"unexpected message kind {kind}"
    at = 4
    commit_seq = struct.unpack_from("<Q", data, at)[0]
    at += 8
    at += 8  # row_bytes
    affected = struct.unpack_from("<I", data, at)[0]
    at += 4
    at += 4  # result kind
    columns = struct.unpack_from("<I", data, at)[0]
    at += 4
    names = []
    for _ in range(columns):
        size = struct.unpack_from("<I", data, at)[0]
        at += 4
        names.append(data[at : at + size].decode())
        at += size
    count = struct.unpack_from("<I", data, at)[0]
    at += 4
    rows = []
    for _ in range(count):
        values = struct.unpack_from("<I", data, at)[0]
        at += 4
        row = []
        for _ in range(values):
            value, at = read_value(data, at)
            row.append(value)
        rows.append(row)
    return {"commit_seq": commit_seq, "affected": affected, "columns": names, "rows": rows}


def post(port: int, sql: str):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request("POST", "/query", body=query_message(sql))
        return decode(connection.getresponse().read())
    finally:
        connection.close()


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_healthy(port: int, process: subprocess.Popen) -> bool:
    deadline = time.time() + 20
    while time.time() < deadline:
        if process.poll() is not None:
            return False
        try:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            connection.request("GET", "/health")
            if connection.getresponse().status == 200:
                return True
        except OSError:
            pass
        finally:
            try:
                connection.close()
            except Exception:
                pass
        time.sleep(0.05)
    return False


def main() -> int:
    failures = 0

    def check(name: str, condition: bool, detail: str = "") -> None:
        nonlocal failures
        if condition:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name} {detail}")

    if not os.path.exists(SERVER):
        print(f"missing server binary: {SERVER}; run scripts/build.py first")
        return 2

    work = os.path.join(ROOT, "_broker_tmp")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    port = free_port()
    server = subprocess.Popen(
        [SERVER, "_broker_tmp/db", f"--port={port}"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        check("the server owns the database", wait_healthy(port, server))

        # Client A creates and writes; client B reads the same state.
        check("create through the broker", post(port, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")["affected"] >= 0)
        first = post(port, "INSERT INTO notes (id, body) VALUES (1, 'one'), (2, 'two')")
        check("write through the broker", first["commit_seq"] > 1, str(first))

        read = post(port, "SELECT count(*) AS n FROM notes")
        check("another client reads the write", read["rows"] == [[2]], str(read["rows"]))
        check("the read carries the commit", read["commit_seq"] == first["commit_seq"], str(read))

        # A second writer on the same directory is refused, with the owner named.
        second = subprocess.run(
            [SERVER, "_broker_tmp/db", f"--port={free_port()}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=20,
        )
        check("a second owner is refused", second.returncode != 0, second.stdout + second.stderr)
        check("the refusal names the lock", "locked" in (second.stderr + second.stdout).lower(), second.stderr)

        # Several clients at once: the server is one owner, the readers do not
        # wait on each other.
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            answers = list(pool.map(lambda _: post(port, "SELECT count(*) AS n FROM notes")["rows"], range(6)))
        check("six concurrent readers agree", all(answer == [[2]] for answer in answers), str(answers))

        # A write from one client is visible to the next read from another.
        post(port, "INSERT INTO notes (id, body) VALUES (3, 'three')")
        after = post(port, "SELECT count(*) AS n FROM notes")
        check("a later read sees the later write", after["rows"] == [[3]], str(after["rows"]))
        check("the commit sequence moved", after["commit_seq"] > first["commit_seq"], str(after["commit_seq"]))

        # A client may close without telling the server; the next one still works.
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        connection.request("POST", "/query", body=query_message("SELECT 1 AS one"))
        connection.close()
        still = post(port, "SELECT count(*) AS n FROM notes")
        check("a dropped client does not disturb the owner", still["rows"] == [[3]], str(still["rows"]))
    finally:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
        shutil.rmtree(work, ignore_errors=True)

    print("broker smoke: ok" if failures == 0 else f"broker smoke: {failures} failure(s)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
