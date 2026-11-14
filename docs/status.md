# Status

What the engine does today, what is partial, and what it does not attempt. The
feature matrix is closed (94/94); [roadmap.md](roadmap.md) orders what is left
and [backlog.md](backlog.md) carries the detail of every item. This file is the
honest measurement: every number here was produced by a command in this tree, and
the gaps are named rather than left to be discovered.

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
- **A `.sqlite` file stays current, page by page.** Opening a database from a
  `.sqlite` file reads that file's layout once and keeps it a valid SQLite
  database: after a commit only the leaf of each changed row, the separator its
  parent stores and page 1 are rewritten — three pages, 12 KiB, at 10k, 100k and
  250k rows, where re-encoding the state would write 172 KiB, 1.8 MB and 4.8 MB.
  A full page splits into as many pages as it needs, a leaf that loses its last
  row is unlinked and its page goes back on the free list, and a commit that the
  patcher cannot express (a table without a single INTEGER primary key, a
  secondary index, a schema change, a write-ahead log) re-encodes the file
  instead. `scripts/mirror_cost.py --check` is the gate and it verifies the
  result with real `sqlite3`; `PRAGMA stats` reports `mirror_pages` and
  `mirror_rewrites`, and `miraidb sql --mirror-report` prints them.
- An interrupted mirror commit is rolled back, not guessed at: the pages are
  journalled in SQLite's own rollback-journal format (magic, nonce, per-page
  checksum, sector-padded records), page 1 is written last, and whoever owns the
  file applies the journal and deletes it. A plain reader applies it in memory
  and leaves it on disk.
- Replay on open, torn-tail detection and truncation.
- Log compaction (`store_compact`, `miraidb compact`) with continuous commit
  sequences; compaction also writes a snapshot.
- Snapshot files (`store_snapshot`, `miraidb snapshot`) and startup from
  snapshot plus the records after it.
- Per-table and per-database memory accounting (`store_table_memory`,
  `store_memory`, and the totals `miraidb inspect` prints).

### History

- `SELECT ... FROM t AS OF <seq>` reads the rows as they were at that commit,
  using the versions the table keeps; an index is not used for a past read.
- `store_prune_versions(store, before_seq)` drops versions and tombstones no
  reader can ask for; nothing prunes automatically yet.

### Transactions

- One writer, many readers, staged writes, read-your-writes.
- A read transaction copies nothing: it takes one reference per table, and a
  commit that has to change a table a reader holds copies **that** table first.
  Opening a read after a commit costs 38 µs on the gate (21 µs over 50 000 rows,
  where it cost 24 ms); the commit that pays for a live reader costs 16.9 ms over
  20 000 rows (46 ms over 50 000), once per read generation, because after the
  copy the store owns the table again. A table a reader holds outlives the store
  and a `DROP`.
- Deterministic operation order in the log.
- Validation before logging: a rejected statement never reaches the log.
- Rewind of the log if applying a validated transaction ever fails.

### SQL

- `CREATE TABLE`, `DROP TABLE`, `CREATE [UNIQUE] INDEX`, `DROP INDEX`.
- `INSERT` (multi-row), `UPDATE`, `DELETE`, positional `?` parameters.
- `ORDER BY` breaks ties by row id, so a query with equal keys answers the same
  sequence on every run; `min`/`max` with two or more arguments are scalar
  comparisons, and `trim`/`ltrim`/`rtrim` take a set of characters.
- `CASE`, in both the simple and the searched form, wherever an expression is
  allowed (a projection, a predicate, a grouping expression, a policy or a
  trigger).
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
  it is what "green" means. Twenty-three gates: the suite, the corpus, the
  smokes, the measurements and the document check.
- `miraidb` has 17 commands: `create`, `sql`, `sqlite`, `import-sqlite`,
  `export-sqlite`, `repl`, `inspect`, `describe`, `bench`, `bench-read`,
  `codegen`, `export`, `call`, `subscribe`, `check`, `compact`, `snapshot`.
- `miraidb sql --json <db> <statement>` prints a result as one JSON array of
  rows, which is how `scripts/differential.py` compares answers against SQLite:
  one schema, one set of rows and 55 queries through both engines, with the
  refusals and the intentional differences listed in the script.
- `scripts/build.py` builds both binaries and runs the suite.
- 243 integration tests covering CRUD, recovery, constraints, transactions,
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

### Rows on disk (opt-in)

- `Store_Options.paged_tables` (CLI `--paged`, `--page-frames=N`) puts each table
  created from then on in a page file under `<db>/tables`; a table that already
  exists stays in memory. Internal tables (the catalogs, the full-text shadow
  tables) stay in memory because the engine reads them whole.
- Pages are 4 KiB, slotted, checksummed per page, with a free list that survives
  a crash and a buffer pool with a clock hand, pins and write-back. Frame 0 is
  reserved for the header: a flush writes the dirty data pages, then page 0 with
  `applied_seq`, then syncs. The fault test breaks each write of a flush.
- The page file is a **cache over the log**, and opening proves it before
  trusting it: the catalog (below) names the sequence the log index says is the
  last record, every table and index file carries that same sequence in its own
  header, and only then does the open read the pages instead of the log. Any
  disagreement — a crash, a stale file, a torn catalog — discards the page and
  index files and rebuilds them by replay, which is what every open did before.
  `store.replays_skipped` counts the opens that did not read the log at all and
  `store.replay_records` the ones that did.
- **The catalog is `<db>/catalog`**: the schema of every table plus the counters a
  page file does not carry (`next_row_id`, `next_sequence`, `next_int_key`), all
  at one sequence. It is written after the pages of a commit are durable and
  before the commit is reported, and it is only trusted when its checksum holds,
  its sequence is exactly the log's last, and every table in it is paged (a table
  without a page file keeps its rows nowhere else, so a catalog with one is
  refused). A failed write costs a replay, never the commit.
- A single-table `SELECT` streams: rows are filtered and projected as they leave
  the pages, aggregates accumulate (`count`, `sum`, `total`, `avg`, `min`, `max`,
  `group_concat`) and `LIMIT` stops the scan. `ORDER BY`, `GROUP BY`, `DISTINCT`,
  a window, `AS OF`, a join, staged writes or an index that answers the filter
  fall back to collecting the table.
- **The directory is on disk too.** Page 0 of the table file carries the root of
  a B+tree that maps `Row_Id → {page, slot}`, so opening a table reads its root
  instead of walking every page: `page_rows_open` sets
  `opened_from_directory` and the row map is gone. A file without that marker
  (written before this change) is walked once and the directory is written back,
  which is the migration.
- `scripts/page_rss.py --check` is a CI gate over an 8-frame pool: the table file
  is 36 times the pool at 15k rows and 145 times at 60k (it holds the rows and the
  directory), and the whole process peaks at **6.4 MiB with 60k rows**, down from
  33.9 MiB when every open rebuilt the pages from the log. The statement grows
  the process by ~410 KiB either way (the 2344 KiB of the previous round included
  the peak of the one-transaction load, which the trusted open no longer pays).
- **Indexes on disk.** Each index of a paged table is a B+tree of the same 4 KiB
  pages, one file under `<db>/indexes/<table>/<index>` with a 32-frame pool. A
  leaf holds `key | row id` in key order and points to the next leaf, so a range
  scan is one pass and a cursor needs no parent stack; a branch holds a separator
  and a child per cell. Point lookups, range scans, `UNIQUE`/primary-key checks,
  updates that move a key, deletes and `TRUNCATE` all go through those pages.
  `table_memory` reports the pool, not one entry per row, and `page_rss.py`
  checks the index file grows with the rows (688 KiB → 2756 KiB for 4× the rows)
  while the statement stays near 300 KiB.
- Index files are opened, not rebuilt, on a trusted open: each one is checked
  against the sequence the catalog names and its tree is used as it stands.

**Not claimed.** An index leaf that loses its last entry is not merged back into
its neighbour, so an index that loses most of its keys keeps the leaves until it
is rebuilt (a delete never leaves a wrong answer: the cursor walks past empty
leaves, and the test deletes a third of 5000 keys); a paged table keeps one
version, so `AS OF` and `ALTER` refuse it; a read transaction of a store with
pages holds the shared lock (writers wait); a **read-only** open replays, because
a reader cannot know whether the writer beside it has pages still in flight, so
the trusted open belongs to the process that owns the directory; a key longer
than 1000 bytes cannot be indexed and the insert says so.


- **Planning.** `ANALYZE` measures each table once — row count, distinct non-null
  values and NULLs per column, the numeric range and a sixteen-bucket histogram
  over it — and the planner prices every way to read a relation with those
  numbers: a scan pays one row per row of the table, a probe pays a descent plus
  a row per id it hands over, and the cheaper one wins (`src/engine/plan.odin`).
  `EXPLAIN` prints the estimate and the cost (`est. N rows, cost C`), and the
  executor takes the same decision. Statistics are a cache in `<db>/stats`
  (checksummed, loaded on open, dropped with their table); a table nobody ran
  `ANALYZE` on keeps the old behaviour of using its index.
- **Join order and the inner probe.** A join is a nested loop, and its order is
  planned: the relation that keeps the fewest rows per outer row runs first, and
  each ON condition runs with the step that completes the relations it names, so
  a relation may run before the join it was written with. LEFT joins, `AS OF` and
  table functions keep the written order. The inner side is **probed** when the ON
  clause binds a column that leads one of its indexes: the loop reads the rows one
  outer row matches instead of the whole relation, so the same join over 200
  authors and 1 000 books reads about 1 200 rows where the scan read 200 200
  (`test_join_probes_the_inner_index`). `EXPLAIN` prints `join <name> using index
  <index> …`, `join order: …` when it changed (the order is searched by cost, so the
  step that can filter is preferred over the one that only looks small), and
  `scripts/plan_check.py` is a CI
  gate over the plans a measured fixture must produce.
- **An index can serve the order.** When the ORDER BY names the whole key of one
  in-memory index, in the index's own order and all in one direction, the executor
  walks the index instead of collecting and sorting: 342 ms to 137 ms over 50 000
  rows, and `ORDER BY id LIMIT 5` reads five rows in 4.6 ms instead of passing over
  the table in 115 ms. A LIMIT ends the walk only when nothing else can drop a row
  (a filter or a policy does, so those keep the full pass). Descending needs a
  unique index, because a reversed walk would order the ties the other way.
  `test_order_by_comes_from_the_index` checks the sequence against the sorted one,
  ties included, and counts the rows a LIMIT reads.
- **The plan reads the values it is given.** A statement is priced per execution,
  with the parameters that came with it, so `n < ?` bound to 50 keeps the estimate
  `n < 50` gets and the same access decision (`test_plan_reads_a_bound_value`); a
  statement that binds nothing keeps the old fallback of a third of the table.
- **A view is priced from its own FROM.** A view has no rows to measure until the
  statement runs, so the planner follows its query to the relation it reads (and
  follows a view over a view), and `EXPLAIN` says where the number came from
  instead of passing a guess off as a measurement
  (`test_plan_prices_a_view_from_its_own_from`).
- **The cost constants are measured.** A scan row costs 100.8 ns, a row fetched
  through an index 456.3 ns (4.5 of them) and one descent through the tree 600 ns
  (6 of them), measured over a 200 000-row table; the three constants in
  `plan.odin` are those numbers, written down with the measurement beside them, and
  an index therefore wins while it keeps under about a fifth of the table.
- **A range written as two comparisons is one range.** `v >= a AND v < b` is priced
  and answered exactly like `v BETWEEN a AND b`: one band of the table, one range
  scan, each bound keeping its own inclusivity, and the bounds written the other way
  round (`b > v AND a <= v`) are the same band
  (`test_plan_reads_a_range_written_as_two_comparisons`). One range per estimate is
  combined; two ranges on two different columns still multiply.
- **A subscription walks the planned order.** A join subscription indexes its walk
  with the same order the planner chooses for the same query, and keeps that order
  for its life (the tuple index is keyed by source position): a subscription over
  `big JOIN small` written big-first walks the small relation and probes the big
  one, instead of walking the big one and probing the small one per row. `SELECT *`
  still expands its columns in the written order.
  `test_join_subscription_walks_the_planned_order` counts the candidates walked and
  checks that the two spellings answer the same set. Staleness is no longer silent: `EXPLAIN` reprices with the
  numbers it has and names their age.
- **A join the grammar does not implement is refused, not approximated.**
  `NATURAL`, `RIGHT` and `FULL` joins used to parse as an alias for the table
  before them, which turned the first into a cross join and the other two into
  inner joins: rows came back and the answer was wrong. They now fail at parse
  time with a reason (`test_unsupported_joins_are_refused`), and `JOIN … USING`
  was already refused. `LEFT [OUTER]`, `INNER`, `CROSS` and the comma form work.
- **The suite reports no bad free.** The debug allocator used to print 3058
  unfreed-or-mis-freed lines; the last causes were a pinned read that freed the
  read cache's snapshot a second time, a test that freed the metric strings its
  result still owned, and every `EXPLAIN`, `DESCRIBE` and `SHOW` result, which
  handed a read-only literal to a caller that frees what it gets
  (`result_own`). The remaining noise is `+++ leak`, ~320k lines
  per suite run (~9 blocks per statement, dominated by the string builder, the
  lexer and statement decoding); nobody has established yet whether those are
  real leaks or allocations released by a bulk free the tracker does not see, and
  `scripts/soak.py` does not measure the working set, so nothing would notice if
  they were real.
- **Schema changes.** `ALTER TABLE` renames the table, adds and drops columns,
  and renames a column (keeping the rows and the indexes); text that names a
  column is not rewritten.
- **Triggers.** `BEFORE` and `AFTER` for `INSERT`, `UPDATE` and `DELETE`, with
  `WHEN`, `NEW` and `OLD`; a `BEFORE` body that fails stops the write. A
  column-specific (`OF`) trigger is refused.
- **Window frames.** `ROWS`, `RANGE` and `GROUPS` work for aggregates and value
  functions, with offsets measured in the ordering value where the unit says so.
  A window beside `GROUP BY` is refused, and so is `FILTER (WHERE …)`.
- **Ordering.** `ORDER BY` sorts after projection, and reads an index order when
  the clause names a whole index key in one direction (`LIMIT` then stops the
  walk early); otherwise it sorts.
- **Types.** One 64-bit integer width, one float width, no decimal, no
  interval, no nested row types in columns.
- **Memory.** Deleted rows are freed, but index key bytes stay in the table
  arena until the table is dropped or the process exits. There is no arena
  reset.
- **Cancellation.** `store_cancel` ends a running statement with `.Cancelled` and
  is tested, but nothing outside the tests calls it: the CLI, the server and the C
  ABI have no cancel handle or statement timeout, and `store_set_work_budget` is
  in the same state. A long query holds the read lock until it finishes.
- **Limits.** An expression may nest 100 levels and no more
  (`MAX_EXPRESSION_DEPTH`, enforced by the parser and by the evaluator, which used
  to die by stack overflow at 155-178 levels of nesting with no message). A
  statement without `LIMIT`/`OFFSET` stops producing rows as soon as it passes
  `max_rows_per_query` instead of refusing after the result exists. What is left:
  a join still builds its intermediate before the projection sees it, `LIMIT` is
  not pushed into the scan, and an allocation that fails is still a crash rather
  than an error (`AUDIT-9` A5, backlog D23).
- **The server serves many clients, one statement at a time.** Each accepted
  socket gets its own thread, so a subscriber no longer blocks anyone: a
  subscription stays open while another client writes and the write's delta is
  written to the subscriber's socket under that socket's lock
  (`scripts/broker_smoke.py` runs both at once and reads the delta).
  `host_on_commit` was never wired to the transport before this, so a live
  subscription delivered its snapshot and then nothing. Statements still run one
  at a time — the store carries the caller's identity while it executes — so a
  slow query queues the others instead of running beside them.
  **What it refuses:** `ATTACH`, `LOAD EXTENSION` and `VACUUM INTO` to a client,
  because each names a path or a module the client chose; `--allow-host` turns
  them back on for a deployment that trusts every client. Reading, writing and
  DDL stay available, and grants still decide who may do them (a database with no
  grants allows everyone, which is the default). `docs/security.md` states the
  model. `--statement-timeout-ms` cancels a statement that outlives it — the
  watchdog sets the store's atomic cancel flag, the executor answers `cancelled`,
  and the next statement runs — while `--budget` refuses a statement that
  overspends (after the work, not during). **What is still open:** the transport
  is plain TCP (D15), the row quota is unreachable from the server, and an
  expression nested deeply enough still overflows the stack (D23).
- **A mirrored `.sqlite` file survives DDL.** `DROP TABLE`, `ALTER TABLE`, `DROP
  INDEX` and `CREATE INDEX` all leave a file `sqlite3` reads: the schema change
  takes the full rewrite, and that rewrite used to leave a file whose
  `sqlite_master` had no b-tree when the last table was dropped (an empty
  database, and a dropped table that held rows). An imported file's indexes are
  read and recreated now, so a plan walks one and `DROP INDEX` finds it
  (`scripts/sqlite_abi_smoke.py` checks all of it against Python's `sqlite3`).

## Not implemented: a second writer, and replication

- **One process writes one log.** A second process that opens the same directory
  for writing is refused with `locked` and the owner's pid: an OS lock on
  `<directory>/lock` (Windows `LockFileEx`, POSIX `fcntl`) is taken on open and
  released on close or death. A second process can still **use** the database,
  through the owner:
  `miraidb-server` serves HTTP wire messages, WebSocket frames and Postgres, and
  each connection has its own subscriptions and byte budget
  (`scripts/broker_smoke.py` proves it with two processes). The identity a
  connection authenticated as is kept **per connection** (`test_connection_identity`):
  two clients never share the identity policies see, and `SET identity` inside a
  request persists for that client only.
- **Two soak tests shared a directory.** `test_soak_workload` and
  `test_soak_update_delete_prune` both opened `_test_soak`, so when the second found
  the first's handle still alive it refused with "already open by pid N". The prune
  soak has its own directory now, and the refusal it produced was a name collision
  rather than a lock that outlives its owner.
- **A reader can open beside the writer (D18b).** The lock file has two bytes: the
  writer byte is taken exclusively, the reader byte shared by readers and writers
  alike. `store_open(..., read_only = true)` (CLI `--read-only`) therefore opens
  while another process is writing. A reader replays the log into memory, so it
  never touches the writer's page files; it cannot write (`Transaction_Read_Only`
  from every mutation path, including DDL and `compact`); and it is a snapshot of
  the state at open, not a follower. While a reader is open the writer keeps
  committing but a **compaction is refused** with `locked`, because compaction
  replaces the log file the reader may be replaying. Two writers are still
  refused, and `scripts/lock_smoke.py` proves all of it with two processes
  (`test_read_only_opens_beside_a_writer` covers the in-process cases).

What is still missing is opening the directory *directly* with the page files
trusted instead of replayed, and streaming commits to a follower.

- **Nothing streams commits between processes**; a reader sees the state at open
  and has to reopen to see later commits. The second *writer* is refused, not
  queued.
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
