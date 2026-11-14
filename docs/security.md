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
```

## Identity and grants

A request runs under the identity its bearer token authenticated, or under none.
Policies are checked against that identity when the database has any:
`CREATE POLICY` and `GRANT` decide who may read or write what.

**Grants are opt-in.** A database with no grant rows allows everything to
everyone, which is the state of a fresh database: create, read, write and drop.
A deployment that must not accept anonymous writes creates its grants first, and
then the same statements are refused for a client without the right.

`WIRE_AUTH` inside a request, and `SET identity`, change the identity of that
connection only; two clients never see each other's.

## What is not defended

- **Transport.** The socket is plain TCP: no TLS, no HTTP/2, no certificate
  pinning (backlog D15). Anything that must not be read in transit needs a
  tunnel in front of this server.
- **Work per statement.** A statement runs until it finishes. There is no
  statement timeout and no cancel from the client, and one statement at a time
  is executed per database, so a slow query delays the others (backlog D23 and
  D22 step 2). The row quota and the work budget exist in the engine and the
  server does not set them.
- **One writer.** The server holds the directory lock; a second server on the
  same directory is refused with the owner's pid. Readers may open beside it with
  `--read-only`.
- **The client registry.** `max_clients`, the outbox budget and the per-frame
  cap bound how much one client can make the server hold. Beyond those, a client
  that connects and says nothing holds one thread until it leaves.
- **Memory of a bad statement.** An expression nested deeply enough overflows the
  stack and takes the process with it (backlog D23). Until that item lands, treat
  the server as one fault away from a restart.

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
