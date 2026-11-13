# miraidb

**An embeddable relational database runtime written in Odin.**

> Status: embedded engine working (`M1`). Server, snapshots and SQLite
> compatibility are design targets, not shipped features. The interfaces below
> are the ones the current code implements unless marked otherwise.

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
| Hosted (planned) | A server process owning the files, exposing reducers and subscriptions over RPC |
| Portable files (planned) | Import/export to ordinary SQLite databases and a versioned miraidb container |

The storage engine is ours from the start, so the file format, transaction order
and change stream are all under our control. Compatibility with SQLite is a
planned adapter, not the foundation: the engine never depends on SQLite to run.

## Design principles

1. **One writer, many readers.** A write transaction takes the store's write
   lock; readers take the read lock. There is no lock upgrade and no deadlock.
2. **Durable before visible.** A commit appends its record to the log and syncs
   it before the in-memory state changes. If applying a logged transaction ever
   failed, the log record is rewound so the file always matches the live state.
3. **Replay is the recovery model.** The commit log is the database. Startup
   replays it record by record; a torn tail is detected by CRC32C and cut.
4. **Everything is data.** Schemas, rows and index keys are encoded with one
   versioned format, so the log, the indexes and the future wire protocol agree.
5. **The core owns its invariants.** Only the engine decides what a valid row
   is; SQL, reducers and subscriptions all go through the same insert/update
   path.
6. **No hidden scripting.** SQL is parsed by a small hand-written parser with a
   fixed grammar; new behaviour is added in Odin, not by embedding an
   interpreter.

## Repository layout

```text
miraidb/
├── scripts/build.py       build and test helper (Python, not part of the engine)
├── src/
│   ├── engine/            the database: values, schema, tables, log, tx, SQL, host
│   ├── cli/               the `miraidb` command line
│   └── tests/             integration tests (`odin test src/tests`)
├── examples/
│   └── todo/              reducers + subscriptions in a small Odin program
├── sdk/
│   └── python/           a typed client over the C ABI (`scripts/sdk_smoke.py`)
├── docs/
│   ├── architecture.md    modules, invariants, transaction and subscription model
│   ├── file-format.md     commit log and snapshot layout, records, recovery
│   ├── sql.md             the supported SQL subset
│   ├── features.md        the parity matrix and its execution order
│   ├── roadmap.md         the plan: phases, what is asked for, what "done" means
│   ├── backlog.md         depth work: what is shallow today and what "done" means
│   └── status.md          what is done, partial and not started
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
engine and the CLI are pure Odin and use only `core` packages. The `scripts/`
directory holds the test harnesses, all Python: `build.py`, `ci.py`,
`conformance.py`, `shell_smoke.py`, `capi_smoke.py`, `sqlite_abi_smoke.py`,
`roadmap.py`, `fuzz.py` and `soak.py`.

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

A reducer is an Odin procedure that receives the open transaction:

```odin
import "core:fmt"
import "core:strings"

add_score :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
	name, _ := strings.replace_all(args[0].s, "'", "''")
	points, _ := db.value_to_f64(args[1])
	statement := fmt.aprintf("UPDATE player SET score = score + %v WHERE name = '%s'", points, name)
	defer delete(statement)
	_, err := db.sql_execute_in_tx(ctx.tx, statement)
	return err
}

db.host_register(host, "add_score", []db.Column_Type{db.type_string, db.type_float}, add_score)
db.host_call(host, "add_score", []db.Value{db.value_string("ana"), db.value_float(1)})
```

The dialect has no bind parameters yet, so a reducer that takes values builds
the statement with escaped text (M2 adds prepared statements).

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

- `CREATE TABLE` with `PRIMARY KEY [AUTOINCREMENT]`, `UNIQUE`, `NOT NULL` and
  `DEFAULT`; `DROP TABLE [IF EXISTS]`; `CREATE [UNIQUE] INDEX` and `DROP INDEX`.
- `INSERT ... VALUES` (multiple rows), `UPDATE ... SET ... WHERE`,
  `DELETE FROM ... WHERE`; positional `?` bind parameters.
- `SELECT` over one or more tables: projections, aliases, `INNER`/`LEFT`/
  `CROSS` joins, `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`,
  `LIMIT`/`OFFSET`, `count/sum/avg/min/max`, and the scalar functions `lower`,
  `upper`, `length`, `abs`, `coalesce`, `now`.
- `CREATE VIEW` / `DROP VIEW`, `CREATE POLICY` row-level security,
  `SET`/`SHOW` session variables, `DESCRIBE` for the catalog and `EXPLAIN` for
  the access plan.
- Ordered indexes on any column tuple, created implicitly for the primary key
  and for `UNIQUE` columns. Equality and range predicates narrow the scan
  through the index.
- Segmented durable commit log with CRC32C per record, replay on open, tail repair,
  snapshots (`miraidb snapshot`), compaction (`miraidb compact`), an offset
  index for fast replay, three durability modes
  (`--durability=full|batched|none`) and an in-memory log for simulation.
- A persisted scheduler: `host_schedule`, `host_schedule_now` and
  `host_schedule_every` queue reducer calls and `host_tick` runs the due ones,
  each in its own transaction.
- Idempotent calls: `host_call_once` records the request id in the same
  transaction as the reducer's changes.
- Cooperative cancellation (`store_cancel` / `store_clear_cancel`) between rows
  and subscriptions owned by a connection (dropped when it closes).
- Session tokens (`host_issue_token` / `host_authenticate`), `WIRE_AUTH` and
  `Authorization: Bearer`, feeding the identity row-level policies check.
- Wire messages for reducer calls, queries and subscriptions, served over HTTP
  by `miraidb-server` (`POST /call`, `/query`, `/subscribe`, `/unsubscribe`,
  `GET /health`) and over WebSocket (RFC 6455, binary frames).
- HMAC-hashed session tokens, `_meta` metadata, `_var` module variables and
  `/metrics` counters;
  `miraidb describe <db> <table>` and `miraidb bench <db> [rows]`.
- A persisted reducer/procedure catalog (`_reducer`) that clients and codegen
  can read with SQL.
- Procedures with their own transaction phases (`procedure_commit`,
  `procedure_sleep`), callable over the wire.
- Reducers, row-level subscriptions (single or multi-query sets, with one delta
  per query) and row-level security policies.

## Roadmap

| Milestone | Deliverable |
|---|---|
| M1 | Embedded engine: tables, transactions, commit log, SQL, reducers, subscriptions **(done)** |
| M2 | Ordered and range-scan indexes, `CREATE INDEX`, bind parameters, `HAVING`, log compaction **(done)** |
| M3 | Snapshots for fast startup, join planning (index nested loops), more functions |
| M4 | Portable files: SQLite import/export, then a SQLite-compatible VFS adapter |
| M5 | Hosted mode: `miraidbd`, authentication, connection-scoped authorization |
| M6 | Retries with backoff, request timeouts, connection limits |
| M7 | Module ABI: trusted native Odin extensions, then sandboxed WASM modules |
| M8 | Hardening: statement fuzzing and a soak harness (`scripts/fuzz.py`, `scripts/soak.py`), fault injection at every write of a workload (`Fault_Vfs`), latency histograms, `PRAGMA integrity_check` and `foreign_key_check`, transport caps, opt-in background compaction, a benchmark gate against a recorded baseline; process-level load tests remain |

Snapshots and compaction came before the network layer on purpose: without
them, recovery time grows with the log and range queries scan the table.

## Not implemented: a second opener, and replication

One process owns one log. A second process on the same directory is refused with
`locked` and the owner's pid: an OS lock on `<directory>/lock` is taken on open and
released on close or death, so nothing is silently corrupted.

A second process can still **use** the database through the owner:
`miraidb-server` serves the wire protocol over HTTP, WebSocket frames and
Postgres, with per-connection subscriptions and byte budgets
(`scripts/broker_smoke.py` proves it with two processes). What is missing is
opening the directory *directly* beside a writer, which needs the page files to be
trusted without a replay (D18b). Tables can already live in page files: open a
store with `--paged` (or `Store_Options.paged_tables`) and a scan streams them
through a bounded buffer pool, with each index a B+tree of pages beside them.

A second process can **read** the same database while the first one writes:
`--read-only` (or `Store_Options.read_only`) takes the shared side of the lock,
answers from a replay of the log at open, refuses writes, and makes a compaction
wait. There is no follower, no log shipping and no failover. The replay path, the
segmented log and the wire layer are the pieces a follower would reuse, and
`docs/backlog.md` (D14) carries the plan. Everything else the engine
does not do is depth, not absence: see `docs/status.md`.

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
