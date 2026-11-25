# Serving a database to other machines

`miraidb-server` puts one database on a socket. This page states what it trusts,
what it refuses, and what it does not defend against, so a deployment does not
have to read the source to find out.

## The model

Inside one process, the caller *is* the host: an embedded `store_open` may
`ATTACH` any file, load an extension, or export a copy, because the code holding
the handle already runs with the process's authority. Nothing on this page
applies to that use.

A socket changes who the caller is. A client sends a statement and a token, and
the server decides. Three statements reach past the database into the machine
that owns it:

| Statement | What it reaches |
|---|---|
| `ATTACH '<path>' AS name` | any file path the process can read |
| `LOAD EXTENSION name AT 'host:port'` | host code (a module in another process) or a network peer |
| `VACUUM INTO '<path>'` | any file path the process can write |

A client chooses the path or the module name, so the server refuses all three
unless it was started with `--allow-host`. The refusal is
`Permission_Denied` with a message that says so, it changes nothing, and the
commit sequence does not move. An embedded caller, and any statement that names
the database rather than the machine (`SELECT`, `INSERT`, DDL), is unaffected.

```text
$ miraidb-server data/db --port=8080        # ATTACH / LOAD EXTENSION / VACUUM INTO refused
$ miraidb-server data/db --port=8080 --allow-host   # every client is trusted
$ miraidb-server data/db --port=8080 --statement-timeout-ms=2000 --budget=10000000
```

## Identity and grants

A request runs under the identity its bearer token authenticated, or under none,
never under the identity a previous request left behind. Policies are checked
against that identity when the database has any: `CREATE POLICY` and `GRANT`
decide who may read or write what.

**Credentials close the server.** It is closed when it has a PostgreSQL password
(`--password` or `MIRAIDB_PG_PASSWORD`), when its database has issued a token
that has not expired, or with `--closed`. A closed server answers a client that
does not prove who it is with nothing but `GET /health`:

| Front | Proof | Without it |
|---|---|---|
| HTTP | `Authorization: Bearer mt_...` on every request | `401` |
| WebSocket | the bearer token on the upgrade, or an `AUTH` message first | every other message answers an error |
| PostgreSQL | SCRAM-SHA-256 with the server's password | the startup is refused (`28000`); a closed server with no password refuses every PostgreSQL client |

A token that does not check out is refused on every server, open or closed: the
client asked to be someone and is not. A server without credentials accepts
every client and says so on stderr when it starts.

```text
$ miraidb-server data/db --issue-token=<64 hex digits>   # prints mt_..., then exits
$ miraidb-server data/db --port=8080                     # closed: the database has a token
```

A PostgreSQL session proves the password, not an identity, so it runs as no
identity: the grants and policies it meets are those of `'*'`.

**What a client never reaches.** Grants decide only if a client cannot rewrite
them, so a server's client, closed or open, is refused (`Permission_Denied`,
nothing changes) when it:

- reads `_token` or `_meta`: `_meta` holds the key that signs every token and
  JWT, and reading it was minting any identity;
- creates, writes, alters, renames or drops `_token`, `_meta`, `_role`,
  `_grant` or `_policy`, directly or through a trigger or a view;
- runs `GRANT`, `REVOKE`, `CREATE POLICY` or `DROP POLICY`;
- runs `SET identity`, which named any identity without a token.

The host sets these up: the CLI or an embedded `store_open` on the directory
while the server is stopped, or a server started with `--allow-host`, which
trusts every client with them as it does with files. An embedded caller is the
host and is not refused.

**Grants are opt-in.** A database with no grant rows allows everything to every
client that is let in: create, read, write and drop. A deployment that must keep
an authenticated client from writing creates its grants first, and then the
same statements are refused for a client without the right.

## What is not defended

- **Transport.** The socket is plain TCP: no TLS, no HTTP/2, no certificate
  pinning (backlog D15). Anything that must not be read in transit needs a
  tunnel in front of this server.
- **Work per statement.** `--statement-timeout-ms` cancels a statement that
  outlives it (the client gets `cancelled` and the server keeps serving) and
  `--budget` caps the work one statement may spend, refusing it *after* the work
  is done rather than during. One statement at a time runs per database, so a
  slow query delays the others. Neither flag is on by default, and the row quota
  (`max_rows_per_query`, `--row-quota` on the CLI) has no server flag yet.
- **Memory.** Expression depth is bounded (100 levels, refused by the parser and
  the evaluator), and an allocation the system refuses fails its statement with
  `out of memory` instead of ending the process (backlog D23): a 4 MiB ballast
  carries the statement to its next checkpoint. The temporary allocator and a
  few registries are outside that guard.
- **One writer.** The server holds the directory lock; a second server on the
  same directory is refused with the owner's pid. Readers may open beside it with
  `--read-only`.
- **The client registry.** `max_clients`, the outbox budget and the per-frame
  cap bound how much one client can make the server hold. Beyond those, a client
  that connects and says nothing holds one thread until it leaves.

## Connections

Each accepted socket is served on its own thread. A subscription stays open and
receives a delta frame per commit that touches its tables, while other clients
connect, read and write. Statements are serialised: the store carries the
caller's identity while a statement executes, so two statements at once could see
each other's. The delta of a commit is written to the subscriber's socket under
that socket's lock, never by two threads at once.

A frame may arrive in pieces and a read may carry several frames; the loop waits
for the rest of a frame and drains what it has, rather than closing the
connection.

## Misuse of a handle

A handle the embedding layer hands out is a pointer, and a host may keep one
after it stopped being valid. Every entry point checks it against the layer's set
of live handles before dereferencing, so a statement used after `finalize`, a
statement whose connection was closed, and a second `finalize` all answer a
misuse error (`MIRAIDB_MISUSE`, `SQLITE_MISUSE`) and do nothing. A bind index past
the statement's parameters is `SQLITE_RANGE`, not a silent growth of the list.

What this does not defend against: a pointer that was never handed out by this
layer, or a host that keeps a stale handle long enough for the allocator to hand
the same address to a new statement — the old handle then names the new one, as it
would in any C library. The guarantee is that a handle this layer forgot answers
an error instead of touching freed memory.
