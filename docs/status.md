# Status

What the engine does today, what is partial, and what it does not attempt. The
feature matrix is closed. [roadmap.md](roadmap.md) is the plan for what comes
next and [backlog.md](backlog.md) is the detail of every item. This file is the
honest measurement.

## Done

### Storage and recovery

- Typed rows in `map[Row_Id]Row`, one table per relation.
- Ordered indexes (red-black trees) with equality, prefix and range scans.
- Primary keys (single or composite), named multi-column `UNIQUE`, `NOT NULL`,
  `DEFAULT` and `AUTOINCREMENT` with start/increment/range, independent of the
  row id.
- Segmented append-only commit log (256 KiB per segment), one record per
  transaction, CRC32C per record.
- In-memory log (`in_memory_log`): the same append path writes to a buffer, for
  simulation and tests without a disk.
- Offset index (`log.index`): a derived seq -> offset sidecar so replay starts
  at the snapshot boundary; validated lookups and rebuild on demand.
- Recovery coverage: a torn tail and a flipped payload bit both stop the replay
  at the previous record and repair the file.
- Full-text search: `CREATE VIRTUAL TABLE … USING fts5` keeps the postings, the
  document lengths and the corpus totals in shadow tables created in the same
  transaction. `MATCH` walks the term index, narrows the scan to the matching
  documents, ranks with BM25 (`rank`, best first) and marks matches with
  `snippet()`/`highlight()`.
- Fault injection: `Fault_Vfs` fails the nth call of open/read/write/seek/
  truncate/sync/remove, or makes a write land part of its bytes. The test arms the
  fault at every write of a workload — log header, `CREATE TABLE` record, each
  commit — reopens without it, and finds exactly the commits that reported
  success. A short write is an error, never a silent success.
- A benchmark baseline (`benchmarks/baseline.json`) records bytes per row, insert
  rate, read cost and compaction; `scripts/bench.py --check` runs as a CI gate.
- Durability modes: `Full` (fsync per commit), `Batched` (every 64 commits and
  on close) and `None`; the CLI exposes `--durability=full|batched|none`.
- Replay on open, torn-tail detection and truncation.
- Log compaction (`store_compact`, `miraidb compact`) with continuous commit
  sequences; compaction also writes a snapshot.
- Snapshot files (`store_snapshot`, `miraidb snapshot`) and startup from
  snapshot plus the records after it.
- Per-table and per-database memory accounting (`store_table_memory`,
  `store_memory`, and the totals `miraidb inspect` prints).

### Transactions

- One writer, many readers, staged writes, read-your-writes.
- Deterministic operation order in the log.
- Validation before logging: a rejected statement never reaches the log.
- Rewind of the log if applying a validated transaction ever fails.

### SQL

- `CREATE TABLE`, `DROP TABLE`, `CREATE [UNIQUE] INDEX`, `DROP INDEX`.
- `INSERT` (multi-row), `UPDATE`, `DELETE`, positional `?` parameters.
- `SELECT` with aliases, `INNER`/`LEFT`/`CROSS` joins, `WHERE`, `DISTINCT`,
  `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`/`OFFSET`, `LIKE`/`ILIKE` with
  `ESCAPE`.
- Aggregates `count/sum/avg/min/max/total`; scalar `lower`, `upper`, `length`,
  `abs`, `coalesce`/`ifnull`, `now`.
- Index-assisted filtering on the base table, and for `UPDATE`/`DELETE` targets.
- Every result reports the commit sequence that produced it.
- `TRUNCATE` (one table-level op) and a broad scalar function set.
- `SET`/`SHOW` for process-local variables, `SHOW tables`, `DESCRIBE` for the
  catalog and `EXPLAIN` for the access plan.
- `CREATE VIEW` / `DROP VIEW`: the body is stored in `_view` and materialized as
  a temporary table when queried.
- Row-level security: `CREATE POLICY ... USING/CHECK` stored in `_policy`,
  enforced on reads and writes; `current_identity()` and `SET identity`.

### Programmable layer

- Reducers: statically linked Odin procedures, one transaction per call.
- Idempotent calls: `host_call_once` records the request id in the same
  transaction as the changes.
- Subscriptions: a `SELECT` (including joins) plus row-level insert/delete
  deltas published after each commit.
- Scheduler: persisted reducer calls (`_schedule`) with one-shot, immediate and
  interval schedules, driven by
  `host_tick`.

### Tooling

- `python3 scripts/ci.py` runs every gate in one command and reports each one;
  it is what "green" means.
- `miraidb create | sql | repl | inspect | check | compact | bench | bench-read`.
- `scripts/build.py` builds both binaries and runs the suite.
- 169 integration tests covering CRUD, recovery, constraints, transactions,
  aggregates, indexes, joins, window functions, triggers, bind parameters,
  snapshots, compaction, migrations, reducers, subscriptions, the scheduler,
  the SQLite reader and writer, the C ABI facade and idempotency.
- A sanitizer build (`odin build src/cli -debug -sanitize:address`) turns a
  silent abort into a source line; it found the read-after-free in the SELECT
  projection loop.
- `odin check <package> -no-entry-point -vet` prints nothing for every package;
  this gate catches unused declarations, shadowed names and casts that should
  be transmutes.
- HTTP and WebSocket caps (body, header, frame) are enforced before allocation
  and answer `413`/refuse instead of crashing; a reply is written with
  `host_set_request_limits`/`host_set_frame_limit`.
- `Store_Options.compact_after_bytes` starts an opt-in background compactor that
  rewrites the log past a threshold and waits for it to double before repeating.
- `scripts/fuzz.py` feeds seeded random SQL (valid and broken) to one REPL
  process per chunk and requires the engine to survive and stay consistent;
  `scripts/soak.py` keeps writing, reading, compacting and reopening for a
  while.

## Partial

### Rows on disk

`src/engine/page.odin` implements the page file: 4 KiB slotted pages with a
checksum, a free list, a buffer pool with eviction and a streaming reader, with
the flush order tested under injected faults. Queries do not read through it yet:
a table is still a `map[Row_Id]Row` in memory, and that is the next step of D17.


- **Index use.** Only the base table of a query is narrowed by an index; joined
  tables are scanned by the nested loop. No cost-based planner.
- **Ordering.** `ORDER BY` sorts after projection. It does not read an index
  order, and `LIMIT` does not stop a scan early.
- **Types.** One 64-bit integer width, one float width, no decimal, no
  interval, no nested row types in columns.
- **Memory.** Deleted rows are freed, but index key bytes stay in the table
  arena until the table is dropped or the process exits. There is no arena
  reset.
- **Cancellation.** A long query holds the read lock until it finishes. There
  is no statement timeout or cancel handle.

## Not implemented: a second process, and replication

- **One process owns one log.** A second process that opens the same directory is
  refused with `locked` and the owner's pid: an OS lock on `<directory>/lock`
  (Windows `LockFileEx`, POSIX `fcntl`) is taken on open and released on close or
  death. Connections (not processes) share one host: each client has its own
  subscriptions and its own byte budget. What is still missing is *sharing*, in
  `docs/backlog.md` (D18): a read-only open beside a writer once pages exist
  (D17), and a broker mode that serves other processes over the wire.

This is the one capability the engine does **not** have at all, as opposed to
having a shallow version of it. There is no code for it in the tree.

- **Nothing streams commits between processes**; a second process can read the
  same database only after the first one closes (the second opener is refused, it
  does not wait).
- **No follower.** There is no way to run a read-only copy that catches up, and
  no way to promote one.
- **No failover, no leader election, no consistency story for a partition.**
  Those are deliberately out of scope until log shipping exists.

What is already in place to build on: a segmented commit log with a CRC32C per
record, a replay path that applies records in order, a snapshot plus an offset
index to start replay from, and a wire/HTTP layer that can carry bytes. The plan
is in `docs/backlog.md` (D14): serve `GET /log?since=<seq>`, run
`miraidb replica <db> <url>` as a read-only follower applying records through the
same replay path, and test a lagging follower and a dead leader. Failover stays
unclaimed.

Everything else that is missing is **depth**, scoped in `docs/backlog.md` (D1,
D2, D4–D12, D16); the roadmap's matrix is closed and every row has a test.

## Invariants to keep when extending

1. A commit is durable before it is visible.
2. Nothing that fails validation is written to the log.
3. Replay of the same log always produces the same state.
4. SQL and reducers share one insert/update path.
5. The engine depends only on Odin's `core`.
6. No embedded scripting runtime: SQL plus linked Odin code.
