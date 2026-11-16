# miraidb

**An embeddable relational database runtime written in Odin.**

> Status: the engine, the server, snapshots, compaction, the SQLite reader and
> writer, the C ABI and the Python SDK are implemented and covered by tests
> (`docs/status.md` is the honest measurement; `docs/features.md` is the closed
> 94-row parity matrix). What is deliberately not claimed is listed at the end of
> that document. The interfaces below are the ones the code implements.

miraidb is a small database engine meant to be linked into a program. It gives you:

- **Typed relational tables** with primary keys, unique constraints and equality
  indexes, queried with a compact SQL dialect.
- **Transactions** with one writer and many readers, staged writes, and an
  append-only commit log that rebuilds the database on startup.
- **Reducers**: procedures written in Odin, called by name, each of which runs as
  one atomic transaction.
- **Live subscriptions**: a registered `SELECT` that receives row-level inserts
  and deletes after every commit.

There is no embedded scripting language: the only interface to the database is
SQL plus Odin code linked into the host. That keeps the surface small and the
failure modes local.

## Why another database

The engine exists to make three deployment styles share one implementation:

| Style | What the host gets |
|---|---|
| Embedded | Link the `engine` package, open a directory, run SQL and reducers in-process |
| Hosted | `miraidb-server` owns the files and serves reducers, queries and subscriptions over HTTP, WebSocket frames and Postgres |
| Portable files | Read and write an ordinary `.sqlite` file, and keep one current by patching the pages each commit touched |

The storage engine is ours from the start, so the file format, transaction order
and change stream are all under our control. Compatibility with SQLite is an
adapter, not the foundation: the engine reads and writes the file format and the
SQL surface, but never links SQLite and never needs it to run.

## Design principles

1. **One writer, many readers.** A write transaction takes the store's write
   lock; readers take the read lock. There is no lock upgrade and no deadlock.
2. **Durable before visible.** A commit appends its record to the log and syncs
   it before the in-memory state changes. If applying a logged transaction ever
   failed, the log record is rewound so the file always matches the live state.
3. **Replay is the recovery model.** The commit log is the database. Startup
   replays it record by record; a torn tail is detected by CRC32C and cut.
4. **Everything is data.** Schemas, rows and index keys are encoded with one
   versioned format, so the log, the indexes and the wire protocol agree.
5. **The core owns its invariants.** Only the engine decides what a valid row
   is; SQL, reducers and subscriptions all go through the same insert/update
   path.
6. **No hidden scripting.** SQL is parsed by a small hand-written parser with a
   fixed grammar; new behaviour is added in Odin, not by embedding an
   interpreter.

## Repository layout

```text
miraidb/
├── src/
│   ├── engine/            the database: values, schema, tables, log, tx, SQL, host
│   ├── cli/               the `miraidb` command line
│   ├── server/            `miraidb-server`: HTTP, WebSocket frames and PostgreSQL
│   ├── capi/              the C ABI, built as `miraidb.dll` / `libmiraidb`
│   ├── sqlite_compat/     the `sqlite3_*` facade, built as `sqlite3_miraidb.dll`
│   ├── client/            the Odin client SDK
│   └── tests/             integration tests (`odin test src/tests`)
├── include/miraidb.h      the C header for the ABI
├── include/sqlite3_miraidb.h  the C header for the sqlite3_* facade
├── examples/
│   ├── todo/              reducers + subscriptions in a small Odin program
│   └── embed_c/           the database embedded in a C program
├── sdk/
│   └── python/            a typed client over the C ABI (`scripts/sdk_smoke.py`)
├── benchmarks/            the recorded baseline and the reference-suite port
├── tools/leakcheck/       the allocation report `scripts/leaks.py` gates
├── scripts/               build, CI and every test harness (Python, not part of the engine)
├── docs/
│   ├── architecture.md    modules, invariants, transaction and subscription model
│   ├── file-format.md     commit log and snapshot layout, records, recovery
│   ├── sql.md             the supported SQL subset
│   ├── features.md        the parity matrix (closed, 94/94)
│   ├── roadmap.md         the one list of open work, in priority order
│   ├── backlog.md         the detail of each open item: today, cost, done when
│   ├── closing-plan.md    the record of what was closed, with its evidence
│   ├── sqlite.md          SQLite compatibility, with claims CI executes
│   ├── sqlite-roadmap.md  SQLite's surface: measured, missing, incompatible
│   ├── security.md        what the server trusts, refuses and does not defend
│   ├── status.md          what is done, partial and not started
│   └── versioning-plan.md the proposal: branches, merge and peer-to-peer sync
├── CONTRIBUTING.md
├── LICENSE-APACHE
├── LICENSE-MIT
└── README.md
```

## Build

The engine is a plain Odin package; there is no build system to install.

```sh
python3 scripts/build.py          # builds the binaries and runs the suite
python3 scripts/ci.py             # every gate: build, tests, conformance, smokes, vet, roadmap
python3 scripts/package.py        # dist/miraidb-<version>-<target>.zip
```

or directly:

```sh
odin build src/cli -out:bin/miraidb
odin test src/tests
```

Odin `dev-2026-10` or newer (`ODIN=/path/to/odin` when it is not on `PATH`). The
engine and the CLI are pure Odin and use only `core` packages. The harnesses in
`scripts/` are Python; `python3 scripts/ci.py --list` names every gate they make
up. The DLL smokes need a Python that can load a Windows DLL: pass
`--windows-python C:/path/to/python.exe` (a Windows path) or set
`MIRAIDB_WINDOWS_PYTHON`, otherwise `ci.py` skips them and says so.

## Using the CLI

```console
$ miraidb create game.db
created game.db

$ miraidb sql game.db "CREATE TABLE player (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    score DOUBLE NOT NULL DEFAULT 0
  )"
ok

$ miraidb sql game.db "INSERT INTO player (name) VALUES ('ana'), ('luis')"
2 rows affected

$ miraidb sql game.db "SELECT id, name, score FROM player ORDER BY score DESC"
id  name  score
--  ----  -----
1   ana   0
2   luis  0
(2 rows)
```

`miraidb repl game.db` opens an interactive session with `.tables`, `.schema`,
`.help` and `.quit`. `BEGIN`, `COMMIT` and `ROLLBACK` keep one transaction open
across statements. `miraidb inspect game.db` prints the schema and row counts;
`miraidb check game.db` reports the commit sequence after a replay;
`miraidb snapshot game.db` writes a checkpoint and `miraidb compact game.db`
snapshots and rewrites the log.

Options: `--no-sync` commits without fsync (faster, loses the last commits on a
crash), `--memory` runs without a log.

## Using the engine

```odin
import db "miraidb/src/engine"

store, err := db.store_open("game.db", {persistent = true, create = true, durable = true})
if !db.error_ok(err) do return
defer db.store_close(store)

host := db.host_init(store)
defer db.host_destroy(host)

_, exec_err := db.sql_execute(store, `
    CREATE TABLE player (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        score DOUBLE NOT NULL
    )`)
```

A reducer is an Odin procedure that receives the open transaction. Values reach
the statement as bind parameters (`?`, or PostgreSQL's `$1`), never as text
spliced into it:

```odin
add_score :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
	// args are (name, points); the statement takes them as (points, name).
	result, err := db.sql_execute_in_tx_params(
		ctx.tx,
		"UPDATE player SET score = score + ? WHERE name = ?",
		[]db.Value{args[1], args[0]},
	)
	db.sql_result_destroy(&result)
	return err
}

db.host_register(host, "add_score", []db.Column_Type{db.type_string, db.type_float}, add_score)
db.host_call(host, "add_score", []db.Value{db.value_string("ana"), db.value_float(1)})
```

If the handler returns an error, the whole call rolls back. Subscription
updates arrive after the commit:

```odin
id, snapshot, sub_err := db.host_subscribe(host, "SELECT id, name, score FROM player")
// snapshot holds the current rows; afterwards the host callback receives deltas
host.on_update = proc(ctx: rawptr, update: ^db.Subscription_Update) {
	// update.inserts and update.deletes are row slices, valid during the call
}
```

## Current capabilities

**Data.** Nineteen column types, including `INT128`, `FLOAT4`, `UUID`,
`DURATION`, `IDENTITY`, `ARRAY(T)`, `PRODUCT(T…)` and named types; composite
primary keys, named unique constraints, sequences, generated columns, collations
(`BINARY`, `NOCASE`, `RTRIM`) and foreign keys with `RESTRICT`/`CASCADE`.
Integer widths are enforced on store.

**SQL.** `CREATE`/`DROP`/`ALTER TABLE` (add, drop, rename), `INSERT`, `UPDATE`,
`DELETE`, `UPSERT … ON CONFLICT DO UPDATE` (with `excluded`) and `RETURNING`;
`SELECT` with `INNER`/`LEFT`/`CROSS` joins, `CASE`, common table expressions
(recursive included), `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`,
`LIMIT`/`OFFSET`, scalar and aggregate functions (`count(DISTINCT x)` included),
window functions with `ROWS`, `RANGE` and `GROUPS` frames, subqueries (`IN`,
`EXISTS`, scalar), positional `?` and numbered `$n` parameters; views (with
parameters and `OR REPLACE`), `BEFORE` and `AFTER` triggers with `WHEN`,
row-level security policies, `SET`/`SHOW`, `DESCRIBE`,
`EXPLAIN` with cost estimates and the planned join order, `SAVEPOINT`,
`ATTACH`/`DETACH`, `AS OF <seq>` for a past commit, and `TRUNCATE`. The
PostgreSQL spellings an ORM sends first are accepted too: `x::type`, `SERIAL`,
identity columns, PostgreSQL's type names, `information_schema` and the session
functions (`docs/sql.md`, PostgreSQL spellings).

**Search and documents.** FTS5 virtual tables with BM25 ranking (`rank`),
phrases, prefixes and column filters, `snippet` and `highlight`, backed by an
index in ordinary tables; spatial
tables of bounding boxes; JSON functions and the `json_each`/`json_tree` table
functions; dates and times.

**Storage.** A segmented commit log with CRC32C per record, an offset index,
three durability modes, replay with tail repair, snapshots, compaction, and
opt-in page files per table with a buffer pool, a free list and a fault-tested
flush order. One owner per directory (OS lock), and a reader that opens beside
the writer.

**Programmable layer.** Reducers, procedures with their own transaction phases,
a persisted scheduler (one-shot, immediate, interval), idempotent calls by
request id, cooperative cancellation, row-level subscriptions (single,
multi-query and incremental for plain queries, joins and aggregates) and a
module ABI v1/v2 for out-of-process extensions.

**Network.** `miraidb-server` over HTTP (`/call`, `/query`, `/subscribe`,
`/unsubscribe`, `/wire`, `/health`, `/metrics`), WebSocket binary frames and the
PostgreSQL wire protocol (`psql` and psycopg 3 work against it: transactions
across messages, pipelined extended queries, command tags, SQLSTATE codes);
HMAC-hashed session tokens, HS256 JWTs, per-connection
identity, connection limits, byte accounting, a bounded outbox, deflate
compression and per-call work budgets.

**Files and clients.** Import a `.sqlite` file, export one deterministically, or
keep one current: every commit patches only the pages it changed, with a
rollback journal in SQLite's format. A C ABI with a header (`include/miraidb.h`),
a `sqlite3_*` facade, an Odin client SDK, a Python binding, code generation for
Odin, and a CLI with seventeen commands (`create`, `sql`, `sqlite`,
`import-sqlite`, `export-sqlite`, `repl`, `inspect`, `describe`, `bench`,
`bench-read`, `codegen`, `export`, `call`, `subscribe`, `check`, `compact`,
`snapshot`).

Everything above is covered by the test suite; `docs/status.md` records the
measurements and what is deliberately not claimed, and `docs/sql.md` is the SQL
reference.

## Documentation

Design and reference:
[architecture](docs/architecture.md) (modules, transactions, the value layout
link below), [file-format](docs/file-format.md) (the log, snapshots, pages and
the `.sqlite` mirror), [value-layout](docs/value-layout.md) (what a `Value` and
a `Row` carry), [security.md](docs/security.md) (what the server trusts and
refuses), [sql.md](docs/sql.md) (the SQL reference) and the SQLite
compatibility documents: [sqlite.md](docs/sqlite.md) (what is done, partial or
missing), [sqlite-roadmap.md](docs/sqlite-roadmap.md) and
[sqlite-inventory.md](docs/sqlite-inventory.md) (generated from the reference).

Status and planning:
[status.md](docs/status.md) (measurements, what is deliberately not claimed),
[features.md](docs/features.md) (the parity matrix, 94 rows),
[roadmap.md](docs/roadmap.md) (the one list of open work, in priority order),
[backlog.md](docs/backlog.md) (the detail and cost of each open item) and
[closing-plan.md](docs/closing-plan.md) (what was closed, with its evidence).
[versioning-plan.md](docs/versioning-plan.md) is the proposal for what comes
after the roadmap: commits with an identity, branches, row-level merge, and
peer-to-peer sync between users, an office peer and a VPS.

## Roadmap

| Milestone | Deliverable |
|---|---|
| M1 | Embedded engine: tables, transactions, commit log, SQL, reducers, subscriptions **(done)** |
| M2 | Ordered and range-scan indexes, `CREATE INDEX`, bind parameters, `HAVING`, log compaction **(done)** |
| M3 | Snapshots for fast startup **(done)**, cost-based join planning and `ANALYZE` statistics **(done, D6)**, the language surface of `docs/sql.md` **(done; what is left is `docs/roadmap.md`)** |
| M4 | Portable files: SQLite import/export **(done)**, a `.sqlite` file kept current by patching its pages **(done, D4)**, the `sqlite3_*` facade **(done, `bin/sqlite3_miraidb.dll`)** |
| M5 | Hosted mode: `miraidb-server` over HTTP/WebSocket/Postgres, authentication, connection-scoped authorization **(done)** |
| M6 | Retries with backoff, request timeouts, connection limits **(transport caps done; retry policy and per-route timeouts remain, `docs/backlog.md` D15)** |
| M7 | Module ABI: trusted native Odin extensions **(done out of process: `LOAD EXTENSION … AT 'host:port'`)**, sandboxed modules with enforced memory and time **(remaining, D12c)** |
| M8 | Hardening: statement fuzzing and a soak harness (`scripts/fuzz.py`, `scripts/soak.py`), fault injection at every write of a workload (`Fault_Vfs`), latency histograms, `PRAGMA integrity_check` and `foreign_key_check`, transport caps, opt-in background compaction, a benchmark gate against a recorded baseline, a leak report that names the file and line (`tools/leakcheck`) **(done)**; process-level load tests remain |

Snapshots and compaction came before the network layer on purpose: without
them, recovery time grows with the log and range queries scan the table.

What comes next is in [docs/roadmap.md](docs/roadmap.md), split by the two goals:
**match or beat the reference model** on its own benchmark suite (the engine is
faster on an empty transaction and still 1.6–4× slower elsewhere,
[RESULTS.md](benchmarks/parity/RESULTS.md)), and **bring SQLite's features**
(measured by `scripts/sqlite_gaps.py`; the counts are in
[sqlite-roadmap.md](docs/sqlite-roadmap.md)), plus the hardening a release needs.

## Not implemented: a second writer, and replication

One process **owns** one log. A second writer on the same directory is refused with
`locked` and the owner's pid: an OS lock on `<directory>/lock` is taken on open and
released on close or death, so nothing is silently corrupted.

A second process can **read** while the first one writes. The lock file has two
bytes — the writer's, exclusive, and a reader's, shared by readers and the writer —
so `--read-only` (or `Store_Options.read_only`) opens beside a live writer, answers
from a replay of the log at open, refuses every mutation and makes a compaction
wait. The writer, in turn, opens its page files without replaying them: the
catalog names the sequence, every page file carries it, and a mismatch means a
replay, never a wrong answer (`docs/backlog.md` D18).

A second process can also **use** the database through the owner:
`miraidb-server` serves the wire protocol over HTTP, WebSocket frames and
Postgres, with per-connection subscriptions and byte budgets
(`scripts/broker_smoke.py` proves it with two processes).

What is missing is a **follower**: no log shipping, no failover, no multi-writer.
The replay path, the segmented log and the wire layer are the pieces a follower
would reuse, and `docs/backlog.md` (D14) carries the plan. Everything else the
engine does not do is depth, not absence: see `docs/status.md`.

## Data model and limits

- Column types: `BOOLEAN`, `TINYINT`/`SMALLINT`/`INT`/`BIGINT` (signed),
  `UTINYINT`/`USMALLINT`/`UINT`/`UBIGINT` (unsigned), `INT128`/`UINT128`,
  `FLOAT4`/`DOUBLE`, `TEXT`, `BLOB`, `TIMESTAMP` and `DURATION` (microseconds),
  `UUID`, `IDENTITY` and `CONNECTION`. Integer widths are enforced on store.
- One primary key per table, single or composite. `AUTOINCREMENT` needs the key
  to be exactly one integer column.
- Rows are addressed by a per-table `Row_Id`; autoincrement columns reuse it.
- Delete frees the row, but the key bytes stored in the table's index arena are
  reclaimed only when the table is dropped or the process restarts. Compaction
  rewrites the log, not the live arenas.

## License

Dual-licensed under MIT or Apache-2.0, at your option. Third-party material and
its notices are in `THIRD_PARTY_NOTICES.md`.
