#!/usr/bin/env python3
"""Who a server's client is, on each front: HTTP, WebSocket and PostgreSQL.

A server with credentials is closed. It has them when it was given a PostgreSQL
password, when its database issued a token, or with --closed, and then a client
that does not prove who it is gets refused. A server without them accepts every
client and warns when it starts. Whatever the server, a client cannot reach what
decides identities: it cannot read the key that signs tokens, write grants, or
name its own identity.

The script runs the real server three times on one database:

* open: the startup warning, anonymous statements answered, and the
  credentials refused on HTTP and on PostgreSQL;
* closed by an issued token: 401 without a token or with a wrong one, the
  request running as its token's identity, a WebSocket answered only after
  AUTH (or a token on its upgrade), and PostgreSQL refused, since it has no
  password to prove;
* closed by a password: SCRAM opens the PostgreSQL session, and the session
  runs as nobody, not as the identity an HTTP request left behind.

    python scripts/auth_smoke.py
"""

from __future__ import annotations

import http.client
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

from binpath import binary_path
from broker_smoke import (
    WIRE_ERROR,
    WIRE_RESULT,
    decode,
    encode_string,
    free_port,
    query_message,
    read_pg_message,
    scram_login,
    send_pg_message,
    wait_healthy,
    ws_read_frames,
    ws_send,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = binary_path("miraidb-server")
WIRE_AUTH = 5
ANA = "a1" * 32


def auth_message(token: str) -> bytes:
    return struct.pack("<I", WIRE_AUTH) + encode_string(token)


def http_query(port: int, sql: str, token: str | None = None):
    """POST /query and answer (status, decoded result or error text)."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        headers = {"Authorization": f"Bearer {token}"} if token is not None else {}
        connection.request("POST", "/query", body=query_message(sql), headers=headers)
        response = connection.getresponse()
        body = response.read()
        if response.status != 200:
            return response.status, body.decode(errors="replace")
        try:
            return 200, decode(body)
        except RuntimeError as exc:
            return 200, str(exc)
    finally:
        connection.close()


def ws_connect(port: int, token: str | None = None):
    """Opens a WebSocket, with a bearer token on the upgrade when given."""
    connection = socket.create_connection(("127.0.0.1", port), timeout=10)
    authorization = f"Authorization: Bearer {token}\r\n" if token else ""
    request = (
        "GET /wire HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        f"{authorization}"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    connection.sendall(request.encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = connection.recv(4096)
        if not chunk:
            break
        head += chunk
    status = head.split(b"\r\n", 1)[0]
    return connection, status, head.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in head else b""


def ws_ask(connection, pending: bytes, payload: bytes):
    """Sends one wire message and answers (kind, payload, pending)."""
    ws_send(connection, payload)
    frames, pending = ws_read_frames(connection, pending, 1)
    data = frames[0][1]
    return struct.unpack_from("<I", data, 0)[0], data, pending


def pg_startup(port: int):
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    startup = b"user\x00root\x00database\x00x\x00\x00"
    sock.sendall(struct.pack("!ii", 4 + len(startup), 196608) + startup)
    return sock


def pg_until_ready(sock) -> list[bytes]:
    messages = []
    while True:
        message = read_pg_message(sock)
        messages.append(message)
        if message[0:1] in (b"Z",):
            return messages
        if message[0:1] == b"E" and not messages[:-1]:
            return messages


def pg_query(sock, sql: str) -> tuple[list[str], str]:
    """Runs one simple query: the first column of each row, and the error text."""
    send_pg_message(sock, b"Q", sql.encode() + b"\x00")
    rows: list[str] = []
    error = ""
    while True:
        message = read_pg_message(sock)
        kind = message[0:1]
        if kind == b"D":
            length = struct.unpack_from("!i", message, 7)[0]
            rows.append("" if length < 0 else message[11 : 11 + length].decode())
        elif kind == b"E":
            error = message[5:].decode(errors="replace")
        elif kind == b"Z":
            return rows, error


def start(work_db: str, port: int, *extra: str) -> subprocess.Popen:
    return subprocess.Popen(
        [SERVER, work_db, f"--port={port}", *extra],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def stop(server: subprocess.Popen) -> tuple[str, str]:
    if server.poll() is None:
        server.terminate()
    try:
        return server.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        return server.communicate()


def main() -> int:
    failures = 0

    def check(name: str, condition: bool, detail: object = "") -> None:
        nonlocal failures
        if condition:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name} {detail}")

    if not os.path.exists(SERVER):
        print(f"missing server binary: {SERVER}; run scripts/build.py first")
        return 2
    work = os.path.join(ROOT, "_auth_tmp")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    database = "_auth_tmp/db"

    # --- Open: no password, no token. ---------------------------------------
    port = free_port()
    server = start(database, port)
    try:
        check("the open server starts", wait_healthy(port, server))
        status, result = http_query(port, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        check("an open server answers an anonymous statement", status == 200 and isinstance(result, dict), result)
        status, result = http_query(port, "SELECT value FROM _meta")
        check("HTTP: the token key is not a client's to read",
              status == 200 and isinstance(result, str) and "credentials" in result, result)
        status, result = http_query(port, "CREATE TABLE _role (role TEXT, identity TEXT)")
        check("HTTP: a client does not write itself a role",
              isinstance(result, str) and "host's" in result, result)
        status, result = http_query(port, f"SET identity = '{ANA}'")
        check("HTTP: a client does not name its identity", isinstance(result, str) and "host's" in result, result)
        sock = pg_startup(port)
        pg_until_ready(sock)
        rows, error = pg_query(sock, "SELECT value FROM _meta")
        check("PostgreSQL: the token key is not a client's to read", not rows and "credentials" in error, (rows, error))
        rows, error = pg_query(sock, "GRANT admin TO '*'")
        check("PostgreSQL: a client does not GRANT", "host's" in error, error)
        sock.close()
    finally:
        out, err = stop(server)
    check("an open server warns when it starts", "warning: no password and no tokens" in err, err)
    check("an open server says it is open", "open)" in out, out)

    # --- A token closes it. -------------------------------------------------
    issued = subprocess.run(
        [SERVER, database, f"--issue-token={ANA}"], cwd=ROOT, capture_output=True, text=True, timeout=30
    )
    token = issued.stdout.strip()
    check("--issue-token prints a token", issued.returncode == 0 and token.startswith("mt_"), (issued.returncode, issued.stderr))
    refused = subprocess.run(
        [SERVER, database, "--issue-token=nothex"], cwd=ROOT, capture_output=True, text=True, timeout=30
    )
    check("--issue-token refuses an identity that is not hex", refused.returncode == 2, refused.stderr)

    port = free_port()
    server = start(database, port)
    try:
        check("the closed server starts", wait_healthy(port, server))
        status, _ = http_query(port, "SELECT 1")
        check("HTTP: no token is 401", status == 401, status)
        status, _ = http_query(port, "SELECT 1", "mt_" + "0" * 64)
        check("HTTP: a wrong token is 401", status == 401, status)
        status, result = http_query(port, "SELECT CAST(current_identity() AS TEXT) AS who", token)
        check("HTTP: a request runs as its token's identity",
              status == 200 and isinstance(result, dict) and result["rows"] == [[ANA]], result)
        status, _ = http_query(port, "SELECT 1")
        check("HTTP: the next anonymous request is still 401", status == 401, status)

        connection, status_line, pending = ws_connect(port)
        check("WebSocket: the upgrade completes", b"101" in status_line, status_line)
        kind, _, pending = ws_ask(connection, pending, query_message("SELECT 1"))
        check("WebSocket: a query before AUTH is refused", kind == WIRE_ERROR, kind)
        kind, _, pending = ws_ask(connection, pending, auth_message("mt_" + "0" * 64))
        check("WebSocket: a wrong token is refused", kind == WIRE_ERROR, kind)
        kind, _, pending = ws_ask(connection, pending, auth_message(token))
        check("WebSocket: AUTH with the token is accepted", kind == WIRE_RESULT, kind)
        kind, data, pending = ws_ask(connection, pending, query_message("SELECT CAST(current_identity() AS TEXT)"))
        check("WebSocket: after AUTH it runs as the token's identity",
              kind == WIRE_RESULT and decode(data)["rows"] == [[ANA]], kind)
        connection.close()
        connection, status_line, pending = ws_connect(port, token)
        kind, _, pending = ws_ask(connection, pending, query_message("SELECT 1"))
        check("WebSocket: a token on the upgrade proves it", b"101" in status_line and kind == WIRE_RESULT, (status_line, kind))
        connection.close()
        _, status_line, _ = ws_connect(port, "mt_" + "0" * 64)
        check("WebSocket: a wrong token on the upgrade is 401", b"401" in status_line, status_line)

        sock = pg_startup(port)
        greeting = read_pg_message(sock)
        sock.close()
        check("PostgreSQL: a closed server with no password refuses the startup",
              greeting[0:1] == b"E" and b"28000" in greeting, greeting[:60])
    finally:
        out, err = stop(server)
    check("a closed server does not warn", "warning" not in err, err)
    check("a closed server says it is closed", "closed)" in out, out)

    # --- A password: PostgreSQL proves it, and runs as nobody. ---------------
    port = free_port()
    server = start(database, port, "--password=s3cret")
    try:
        check("the password server starts", wait_healthy(port, server))
        status, _ = http_query(port, "SELECT CAST(current_identity() AS TEXT)", token)
        check("HTTP: the token still works beside the password", status == 200, status)
        final, sock = scram_login(port, "s3cret", keep=True)
        pg_until_ready(sock)
        rows, error = pg_query(sock, "SELECT CAST(current_identity() AS TEXT)")
        check("PostgreSQL: the session runs as nobody, not as the last HTTP identity",
              not error and len(rows) == 1 and ANA not in rows[0], (rows, error))
        rows, error = pg_query(sock, f"SET identity = '{ANA}'")
        check("PostgreSQL: SET identity is refused", "host's" in error, error)
        sock.close()
    finally:
        stop(server)

    # --- --closed with no credentials at all. --------------------------------
    shutil.rmtree(os.path.join(work, "empty"), ignore_errors=True)
    port = free_port()
    server = start("_auth_tmp/empty", port, "--closed")
    try:
        check("the --closed server starts", wait_healthy(port, server))
        status, _ = http_query(port, "SELECT 1")
        check("HTTP: --closed refuses an anonymous client", status == 401, status)
    finally:
        out, err = stop(server)
    check("--closed does not warn", "warning" not in err, err)

    shutil.rmtree(work, ignore_errors=True)
    print(f"{'FAIL' if failures else 'ok'}: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
