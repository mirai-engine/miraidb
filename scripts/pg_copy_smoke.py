#!/usr/bin/env python3
"""COPY over the PostgreSQL wire, driven by a socket client.

A driver sends `COPY t FROM STDIN`, waits for CopyInResponse, streams CopyData
and closes with CopyDone; `COPY t TO STDOUT` comes back as CopyOutResponse,
CopyData and CopyDone. No driver is needed to test that: this script speaks the
messages itself, so it also runs where psycopg is not installed.

It starts one server of its own on a free port, checks the text and CSV forms,
the NULL markers, a column list, a failure that must write nothing and a client
that gives up (CopyFail), and stops the server. The rows are read back with the
CLI, so the check does not depend on the server's own answers.

    python scripts/pg_copy_smoke.py [--server bin/miraidb-server.exe]
"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def windows_binary(name: str) -> str:
    return os.path.join(ROOT, "bin", name)


class Client:
    """The PostgreSQL messages this test needs, and nothing else."""

    def __init__(self, port: int) -> None:
        self.socket = socket.create_connection(("127.0.0.1", port), 5)
        body = struct.pack("!I", 196608) + b"user\x00any\x00database\x00miraidb\x00\x00"
        self.socket.sendall(struct.pack("!I", len(body) + 4) + body)
        self.until_ready()

    def close(self) -> None:
        try:
            self.send(b"X")
        finally:
            self.socket.close()

    def send(self, kind: bytes, body: bytes = b"") -> None:
        self.socket.sendall(kind + struct.pack("!I", len(body) + 4) + body)

    def _read_exactly(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise EOFError(f"the server closed after {len(data)} of {count} bytes")
            data += chunk
        return data

    def read(self) -> tuple[bytes, bytes]:
        head = self._read_exactly(5)
        length = struct.unpack("!I", head[1:5])[0]
        return head[0:1], self._read_exactly(length - 4)

    def messages_until(self, stop: bytes) -> list[tuple[bytes, bytes]]:
        seen = []
        while True:
            kind, body = self.read()
            seen.append((kind, body))
            if kind == stop:
                return seen

    def until_ready(self) -> list[tuple[bytes, bytes]]:
        return self.messages_until(b"Z")

    def query(self, sql: str) -> list[tuple[bytes, bytes]]:
        self.send(b"Q", sql.encode() + b"\x00")
        return self.until_ready()

    def copy_from_stdin(self, sql: str, rows: list[bytes]) -> list[tuple[bytes, bytes]]:
        """Runs a COPY ... FROM STDIN statement and answers every message."""
        self.send(b"Q", sql.encode() + b"\x00")
        kind, body = self.read()
        if kind != b"G":
            return [(kind, body)]
        for row in rows:
            self.send(b"d", row)
        self.send(b"c")
        return self.until_ready()

    def data_rows(self, messages: list[tuple[bytes, bytes]]) -> list[list[bytes | None]]:
        rows = []
        for kind, body in messages:
            if kind != b"D":
                continue
            count = struct.unpack("!h", body[:2])[0]
            offset = 2
            values = []
            for _ in range(count):
                length = struct.unpack("!i", body[offset : offset + 4])[0]
                offset += 4
                if length < 0:
                    values.append(None)
                else:
                    values.append(body[offset : offset + length])
                    offset += length
            rows.append(values)
        return rows


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_port(port: int, timeout: float = 15.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), 0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"the server did not listen on port {port}")


def select(client: "Client", sql: str) -> list[list[bytes | None]]:
    """Reads a query through the wire: text values, None for NULL."""
    return client.data_rows(client.query(sql))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=windows_binary("miraidb-server.exe"))
    parser.add_argument("--cli", default=windows_binary("miraidb.exe"))
    args = parser.parse_args()

    workdir = tempfile.mkdtemp(prefix="pg_copy_smoke_")
    database = os.path.join(workdir, "db")
    failures = 0

    def check(name: str, condition: bool, detail: object = "") -> None:
        nonlocal failures
        if condition:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name} {detail}")

    created = subprocess.run([args.cli, "create", database], capture_output=True, text=True)
    if created.returncode != 0:
        print(f"cannot create the database: {created.stderr.strip()}")
        return 1
    subprocess.run(
        [args.cli, "sql", database, "CREATE TABLE c (id INTEGER PRIMARY KEY, name TEXT)"],
        check=True,
        capture_output=True,
    )

    port = free_port()
    server = subprocess.Popen(
        [args.server, database, f"--port={port}", "--any"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for_port(port)
        client = Client(port)

        # The text format: tab separated, `\N` for NULL.
        messages = client.copy_from_stdin("COPY c FROM STDIN", [b"1\tfirst\n", b"2\t\\N\n"])
        check(
            "COPY FROM STDIN answers a CopyInResponse",
            messages and messages[0][0] == b"C" and messages[0][1].startswith(b"COPY 2"),
            messages,
        )
        rows = select(client, "SELECT id, name FROM c ORDER BY id")
        check("the rows of a text COPY arrive", rows == [[b"1", b"first"], [b"2", None]], rows)

        # The same rows back out: CopyOutResponse, CopyData, CopyDone, tag.
        messages = client.query("COPY c TO STDOUT")
        kinds = [kind for kind, _ in messages]
        check(
            "COPY TO STDOUT answers CopyOutResponse, CopyData, CopyDone",
            kinds[:3] == [b"H", b"d", b"c"],
            kinds,
        )
        check(
            "the CopyOutResponse names the columns",
            kinds and struct.unpack("!h", messages[0][1][2:4])[0] == 2,
            messages[0][1] if messages else None,
        )
        check(
            "the data is the text form of the table",
            kinds and messages[1][1] == b"1\tfirst\n2\t\\N\n",
            messages[1][1] if len(messages) > 1 else None,
        )
        check(
            "the copy ends with its count",
            kinds and messages[3][1].startswith(b"COPY 2"),
            messages[3] if len(messages) > 3 else None,
        )

        # CSV with a header, a quoted separator and a quote inside a field.
        messages = client.copy_from_stdin(
            "COPY c FROM STDIN (FORMAT csv, HEADER)",
            [b'id,name\n3,"three, ""quoted"""\n'],
        )
        check(
            "a CSV COPY with a header counts its rows",
            messages and messages[0][1].startswith(b"COPY 1"),
            messages,
        )
        rows = select(client, "SELECT name FROM c WHERE id = 3")
        check("the quoted CSV field arrives whole", rows == [[b'three, "quoted"']], rows)

        # A column list: one column in, the rest default.
        client.query("CREATE TABLE d (id INTEGER PRIMARY KEY, label TEXT DEFAULT 'none')")
        messages = client.copy_from_stdin("COPY d (id) FROM STDIN", [b"7\n8\n"])
        check(
            "COPY with a column list runs",
            messages and messages[0][1].startswith(b"COPY 2"),
            messages,
        )
        rows = select(client, "SELECT id, label FROM d ORDER BY id")
        check(
            "the omitted column takes its default",
            rows == [[b"7", b"none"], [b"8", b"none"]],
            rows,
        )

        # A duplicate key in the stream: an error, and none of the rows written.
        before = select(client, "SELECT count(*) FROM c")
        messages = client.copy_from_stdin("COPY c FROM STDIN", [b"10\tten\n", b"1\tdup\n"])
        kinds = [kind for kind, _ in messages]
        check("a failing COPY answers an ErrorResponse", b"E" in kinds, kinds)
        after = select(client, "SELECT count(*) FROM c")
        check("a failing COPY writes none of its rows", after == before, (before, after))

        # The client gives up mid-stream: CopyFail, and nothing is written.
        client.send(b"Q", b"COPY c FROM STDIN\x00")
        kind, _ = client.read()
        check("a copy that is about to fail starts", kind == b"G", kind)
        client.send(b"d", b"50\tfifty\n")
        client.send(b"f", b"client changed its mind\x00")
        messages = client.until_ready()
        kinds = [kind for kind, _ in messages]
        check("CopyFail answers an error", b"E" in kinds, kinds)
        rows = select(client, "SELECT count(*) FROM c WHERE id = 50")
        check("CopyFail writes nothing", rows == [[b"0"]], rows)

        # A plain query still works after all that, and the connection is usable.
        messages = client.query("SELECT count(*) FROM c")
        check("the session survives the copy exchanges", client.data_rows(messages), messages)
        client.close()
    finally:
        server.terminate()
        try:
            out, err = server.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            out, err = server.communicate()
        if failures and err:
            print("--- server stderr ---")
            print(err.strip())
        shutil.rmtree(workdir, ignore_errors=True)

    print(f"{'ok' if not failures else 'FAILED'}: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
