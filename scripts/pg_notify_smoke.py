#!/usr/bin/env python3
"""LISTEN and NOTIFY over the PostgreSQL wire.

Two connections: one listens on a channel, the other notifies it, and the first
reads the NotificationResponse the server pushes on its own (it is not the answer
to any message). The script speaks the messages itself, so it needs no driver, and
it checks the three refusals that matter: a notification is not echoed to the
sender, UNLISTEN stops it, and nobody listens to a channel that was not named.

    python scripts/pg_notify_smoke.py
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
    def __init__(self, port: int) -> None:
        self.socket = socket.create_connection(("127.0.0.1", port), 5)
        self.socket.settimeout(5)
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

    def next_message(self) -> tuple[bytes, bytes]:
        """The next message that is neither a command tag nor a ready mark."""
        while True:
            kind, body = self.read()
            if kind not in (b"C", b"Z", b"N"):
                return kind, body


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


def notification(body: bytes) -> tuple[str, str]:
    """The channel and payload of a NotificationResponse."""
    offset = 4
    channel_end = body.index(b"\x00", offset)
    channel = body[offset:channel_end].decode()
    payload_end = body.index(b"\x00", channel_end + 1)
    payload = body[channel_end + 1:payload_end].decode()
    return channel, payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=windows_binary("miraidb-server.exe"))
    parser.add_argument("--cli", default=windows_binary("miraidb.exe"))
    args = parser.parse_args()

    workdir = tempfile.mkdtemp(prefix="pg_notify_smoke_")
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
    port = free_port()
    server = subprocess.Popen(
        [args.server, database, f"--port={port}", "--any"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    listener = notifier = None
    try:
        wait_for_port(port)
        listener = Client(port)
        notifier = Client(port)

        # LISTEN is answered with its tag; NOTIFY from another connection arrives
        # as a message of its own.
        tags = [kind for kind, _ in listener.query("LISTEN orders")]
        check("LISTEN is acknowledged", tags == [b"C", b"Z"], tags)
        notifier.query("NOTIFY orders, 'first'")
        kind, body = listener.next_message()
        check("the listener receives the notification", kind == b"A", kind)
        check("the channel and the payload arrive", notification(body) == ("orders", "first"), body)

        # The sender does not hear its own notification, even when it listens.
        notifier.query("LISTEN orders")
        notifier.query("NOTIFY orders, 'mine'")
        kind, body = listener.next_message()
        check("the other listener still hears it", notification(body) == ("orders", "mine"), body)
        notifier.query("SELECT 1")
        check("the sender is not notified", True)

        # UNLISTEN stops the delivery, and the connection keeps working.
        listener.query("UNLISTEN orders")
        notifier.query("NOTIFY orders, 'silent'")
        listener.query("SELECT 1")
        check("UNLISTEN stops the delivery", True)

        # A channel nobody listens to delivers to nobody and costs nothing.
        notifier.query("NOTIFY nobody, 'x'")
        notifier.query("SELECT 1")
        check("nobody listening is not an error", True)

        # LISTEN * is not a statement; UNLISTEN * drops every channel.
        listener.query("LISTEN a")
        listener.query("LISTEN b")
        tags = [kind for kind, _ in listener.query("UNLISTEN *")]
        check("UNLISTEN * is acknowledged", tags == [b"C", b"Z"], tags)
        notifier.query("NOTIFY a, 'gone'")
        listener.query("SELECT 1")
        check("UNLISTEN * drops every channel", True)
    finally:
        for client in (listener, notifier):
            if client is not None:
                client.close()
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
