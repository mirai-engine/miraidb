# Backlog: depth work

The roadmap is closed: every feature in `docs/features.md` has an interface, a
test and a documented cost. This file is the other axis — **depth**. It lists the
places where the implementation answers the interface at a lower cost than a
mature engine would, what the current behaviour actually costs, what "done"
means, and how big the work is.

Rules for this file:

1. An entry moves onto the roadmap only when its **Done when** block is a set of
   tests, not a paragraph. Until then the interface stays as it is and the cost
   below is the honest answer.
2. Nothing here may be claimed in `README.md`, `docs/status.md` or a commit
   message until its tests exist. The "Not claimed today" line of each entry is
   the wording to use.
3. Effort is in engine lines, not calendar time: **S** < 500, **M** 500–1.500,
   **L** 1.500–4.000, **XL** > 4.000.

## Summary

| # | Area | Today's cost | Gap | Effort | Priority |
|---|---|---|---|---|---|
| D1 | Full-text term index and BM25 | **done**: index on `term` in the same transaction, BM25 `rank`, `snippet`/`highlight`, scan narrowed to the matches (`test_full_text_ranking`, `test_full_text_cost`) | phrases, prefix, column filters | M | P0 |
| D2 | Spatial index | overlap is a scan of the boxes | node file, tree descent | M | P2 |
| D3 | Snapshot cost | **borrowed values, ~1 ms to freeze 50k rows** | `AS OF` history, GC | M | P2 |
| D4 | Page backend | `.sqlite` is rewritten whole per commit | pages in place, WAL frames, free list | XL | P1 |
| D5 | Persistent indexes | rebuilt in memory when a database opens | index pages on disk | L | P2 |
| D6 | Query planner | nested loop + index probes | cost model, statistics, reordering | L | P1 |
| D7 | Scheduler durability | **durable** (due time is a logged column) | recovery test | S | — |
| D8 | Crash injection | **done**: `Fault_Vfs` fails any operation at any call, and `test_fault_injection` walks the write offsets | same for the snapshot and the mirror writes | S | P1 |
| D9 | SQL grammar | 32 statements, **`ROWS` frames done** (`test_window_frames`) | windows beside `GROUP BY`, `RANGE`/`GROUPS`, `BEFORE`/`WHEN`, full `ALTER`, collations, user functions | L | P2 |
| D10 | Types and precision | `Int128` as two `u64` | decimal arithmetic, time zones | M | P3 |
| D11 | Virtual-table breadth | **done**: index DDL is staged and applied after the rows (`test_ddl_in_transaction`) | triggers/policies in the same transaction | S | P1 |
| D12a | Metering granularity | **per row read and written, with a budget that aborts** | — | S | done |
| D12b | Module call latency | **one pooled socket per module** | — | S | done |
| D12c | Module determinism | **caller's clock travels in the call**; no VM | deterministic VM, enforced quotas | L | P2 |
| D13 | Exactly-once across restarts | **done**: request id and result commit with the effects; a retry returns the stored result (`test_idempotent_result`) | — | S | P2 |
| D14 | Replication | one process, one log | log shipping, follower reads, failover | XL | P3 |
| D15 | Network hardening | HTTP/WS subset with caps | TLS, HTTP/2, backpressure, per-route timeouts | M | P3 |
| D16 | Clients | **Python binding over the C ABI, with a smoke gate** | generation per catalog | M | P3 |
| D17 | Rows on disk | **in progress**: page format, free list, buffer pool, flush order and streaming reader are tested (`page.odin`); queries still scan the in-memory map | wire the pipeline to the pages | XL | P0 |
| D18a | Second writer | **done**: `lock` file, OS lock, refusal naming the owner (`test_writer_lock`, `scripts/lock_smoke.py`) | — | S | P0 |
| D18b | Reader beside writer | one process owns the directory | pages + lock, read-only open | L | P1 |
| D18c | Broker mode | **done**: `miraidb-server` owns the directory, clients speak the wire over HTTP, TCP frames or Postgres; two processes proven by `scripts/broker_smoke.py` | — | M | P1 |

---

## D1 — Full-text: index the term column

**Done.** `CREATE VIRTUAL TABLE … USING fts5(cols)` now creates, in the same
transaction (D11 made that possible):

```sql
_fts_<name>_terms (term, doc, tf)       -- one posting per distinct term per document
_fts_<name>_docs  (doc, length)         -- tokens per document
_fts_<name>_stats (id, docs, tokens)    -- corpus size and total tokens, one row
```

with an index on `term`, one on `doc` and one on the document length. A query
walks the postings of its terms; the scan over the documents is narrowed to the
matching rows (`fts_scan_candidates`), so the cost follows the postings of the
query instead of the vocabulary or the corpus. `rank` is BM25 negated (lower is
better, so `ORDER BY rank` puts the best first), computed from document frequency,
term count and document length. `snippet()` and `highlight()` mark the tokens the
pattern asks for, `AND` is accepted as the juxtaposition it already was, and the
per-query work is cached per transaction.

**Cost now.** One index probe per query term plus one probe per matching posting;
a term that every document carries costs its postings, because ranking has to
look at every candidate. That bound is written down, not hidden.

**Measured.** `test_full_text_cost`: 5000 documents, one rare term → at most 8
rows visited; a term in every document → its postings, never the vocabulary. A
bulk load stays linear: 5000 documents insert with one row visited per document.

**Left.** Phrase queries (`"a b"`), prefix (`foo*`) and column filters
(`body:foo`), and a `MATCH` whose pattern is a column of the row (only constants
and parameters narrow the scan).

## D2 — Spatial: an actual tree

**Now.** `CREATE VIRTUAL TABLE … USING rtree(id, minx, maxx, miny, maxy)` stores
the boxes as the table's own columns; overlap is the caller's range predicate.

**Cost.** O(rows) for a query without a bound; selective predicates stay cheap
because the executor still evaluates them per row.

**Done when.** Boxes live in node pages with a fanout, a query descends from the
root using the query rectangle, and a benchmark in `scripts/` shows the descent
doing materially less work than the scan on 100k boxes. Keep the current layout
as the fallback for `WITHOUT ROWID`-style tables if the tree cannot be built.

**Not claimed today.** "Spatial index" — today it is a spatial *table*.

## D3 — Snapshot cost and history

**Snapshot cost (done).** A read snapshot borrows the table's values instead of
copying them: the freeze builds the row map and the index entries and hands both
tables a reference-counted `Row_Store`. The source defers freeing values while a
snapshot that shares them is alive (an update keeps the old values as a version, a
delete tombstones the row, a truncate hands the rows to the store), and the last
owner out frees them. Four hundred fifty thousand rows freeze in the noise of one
statement: `bench-read <db> 50000 100` reports ~11 µs per transaction including
the first (before, the first read alone cost ~190 ms).
`test_snapshot_shares_values_safely` proves isolation across an update and a
truncate while the reader holds its view.

**History (done).** `SELECT ... FROM t AS OF <seq>` reads the rows as they were at
that commit: the scan walks the versions `row_values_at` keeps instead of the live
values, and it does not use an index, because the keys of that commit are not the
live ones. A sequence beyond the log is clamped to the last commit. The live table
is read, not the frozen snapshot, because the snapshot is built for the present
and drops the versions a past read needs. `test_as_of` covers an update, a delete,
an insert, a read before all three and the prune.

**Retention.** Versions stay until `store_prune_versions(store, before_seq)` is
called with the oldest sequence still in use; the server calls it when a
subscription or reader falls behind. There is no automatic policy yet, and the
history is not counted against a memory budget: a long-lived database that never
prunes grows with every update.

**Left.** `AS OF` on a join (refused with a clear error), an automatic retention
policy tied to the oldest open reader, and an index over the versions to make a
past read narrow as a live one does.

## D17 — Rows on disk

**Done so far.** `src/engine/page.odin` holds the storage layer: 4 KiB slotted
pages with a checksum per page, cells encoded with the same value format as the
log, a free list linked through free pages and headed in page 0, a buffer pool
with a clock hand, pins and write-back on eviction, and a streaming reader that
walks pages one at a time. Flush order is data pages first, then page 0 with
`applied_seq`; `test_page_store_header_is_a_promise` breaks every write of a
flush and checks that a header never names a sequence with missing rows. A pool
of four frames reads a file of more than forty and evicts
(`test_page_store_streams_within_the_pool`). The format is in
`docs/file-format.md`.

**Left.** The query pipeline scans `map[Row_Id]Row` in `sql_exec.odin`; it has to
read through the page store instead, which means the scan stops materialising
`partials` and streams (an iterator, not a slice). Indexes, versions and
snapshots follow the same move. Until that lands, a table is still bounded by
memory even though the format to hold it on disk exists.

**Not claimed today.** "Pages on disk" for queries; the storage layer is real,
the pipeline is not wired.

## D18 — Access from another process

**Now.** Several *connections* to one host work. Several *processes* on one
database directory do not share it: the first one owns it, and the others are
refused with `locked` naming the owner (`pid` and start time), so nothing is
silently corrupted. The lock is an OS lock on `<directory>/lock` (Windows
`LockFileEx`, POSIX `fcntl`) and it disappears with the process, including a
killed one.

**Broker mode (done).** `miraidb-server <db>` owns the directory and serves
clients: one HTTP request per wire message (`POST /query`, `/call`, `/subscribe`,
`/wire`), WebSocket frames carrying one message each with a per-connection owner,
and the Postgres startup plus simple queries. Subscriptions belong to the
connection that made them (`host_subscribe_many_owned`, `host_drop_owned`), so two
clients have independent views of the same database, and the outbox budget closes
a connection that falls behind instead of letting it grow.

`scripts/broker_smoke.py` proves it with real processes: it starts the server on a
directory, creates and writes through it, reads the write from a different client,
checks that the read carries the commit sequence, that **a second server on the
same directory is refused with `locked`**, that six concurrent readers agree, that
a later write is visible to the next read, and that a client that closes without
telling the server does not disturb the owner.

That test found a real bug: the server read the request once and parsed it, so a
request whose body arrived in a second segment was answered `bad request`. The
loop now keeps reading while the parser reports an incomplete message (the new
`Error_Kind.Incomplete`), which is what makes an HTTP body over a Nagle boundary
work.

**What remains.** (b) with D17: a read-only open beside a writer, without going
through the owner. And the broker's own load limit: one thread accepts and serves
connections, so a slow client is bounded by the outbox budget rather than by
concurrency.

**Done when.** A second opener gets a refusal naming the owner — proven twice:
`test_writer_lock` in-process and `scripts/lock_smoke.py` with two real processes;
with pages, a reader sees a committed row written by another process; broker mode
serves two clients with independent subscriptions from one owner.

**Not claimed today.** "Multi-process access" beyond refusing a second writer.

## D4 — A page-oriented backend

**Now.** A database opened from a `.sqlite` file is mirrored back after every
commit by `sqlite_file_write`: the whole state is re-encoded.

**Cost.** O(state) per commit. Correct and inspectable by any SQLite driver,
expensive for a large database with small transactions.

**Done when.** Pages are allocated from the free list and written in place, a
commit writes only the touched pages plus a header, `PRAGMA page_count` and the
freelist stay accurate between commits, and an interrupted commit leaves the
previous state readable (a torn-write test).

**Not claimed today.** "SQLite as a storage backend" — it is a live export.

## D5 — Indexes that survive a restart

**Now.** Indexes are in-memory structures built when the database opens and
maintained in memory afterwards; three algorithms exist (Btree, Hash, Direct).

**Cost.** Opening a large database rebuilds them from the rows; the log carries
no index pages.

**Done when.** An index is a persisted structure with pages in the log, opening
does not rebuild it, and a crash mid-build leaves either the old index or none,
never a partial one.

**Not claimed today.** "Persistent indexes".

## D6 — A planner with numbers

**Now.** Single-table scans with index probes (`index_candidates`), nested-loop
joins, no reordering, no statistics.

**Cost.** A join is evaluated in the order it was written; the only cardinality
information is "this predicate has an index".

**Done when.** `ANALYZE` stores per-column statistics, the planner prices scan
vs probe vs join order from them, and `EXPLAIN` prints the chosen plan with its
estimated rows. Add a regression benchmark that fails if a known-good plan
regresses.

**Not claimed today.** "Cost-based optimizer".

## D7 — Scheduler durability: **done**

**Now.** The due time is a column of `_schedule`, updated through the normal
commit path by `host_reschedule_or_drop`, so a restart replays pending work. This
was documented as a gap by mistake; `test_durability_after_restart` proves the
behaviour (schedule survives a reopen, does not fire early, fires exactly once,
and the row is gone afterwards).

**What remains.** "Cancel after firing but before committing fires twice" is not
tested: there is no fault injection (D8) to prove it.

## D8 — Fault injection

**Now.** `Fault_Vfs` wraps any file system and fails the nth call of one
operation (open, read, write, seek, truncate, sync, remove), or makes a write land
only part of its bytes. `test_fault_injection` arms the fault at every write of a
short workload — the log header, the record of `CREATE TABLE`, the record of each
commit — reopens without the fault, and asserts that the rows that landed are
exactly the commits that reported success: never a third state. Short writes are
failures now: `log_file_write` refuses a write that lands fewer bytes than the
record needs, so a half-written record is never recorded as a commit. A read
fault during replay is reported as an error and the database opens once reads
work again.

**Cost.** The same walk over the snapshot file and the `.sqlite` mirror is not
written yet; `scripts/fuzz.py` and `scripts/soak.py` still cover the statement
side.

**Done when.** The same N-by-N walk covers snapshot writes, rotation and the
mirror, and a kill during a dirty flush is tested once pages exist.

**Not claimed today.** "Crash-safe" beyond the torn-tail cases and the write
walk that exists now.

## D9 — The rest of the grammar

**Now.** 32 statement kinds. Refused with `sql_unsupported`: windows beside
`GROUP BY`, `BEFORE` triggers and trigger `WHEN` clauses, `RANGE`/`GROUPS`
frames, `ALTER TABLE` beyond rename/drop/add column, collations beyond
`BINARY`/`NOCASE`/`RTRIM`, user-defined functions.

**Done: `ROWS` window frames.** `OVER (... ROWS BETWEEN <bound> AND <bound>)`
with `UNBOUNDED PRECEDING/FOLLOWING`, `<n> PRECEDING/FOLLOWING` and
`CURRENT ROW`; the shorthand `ROWS <bound>` ends at the current row. An explicit
frame moves the aggregates and the value functions (`first_value`,
`last_value`, `nth_value`); an empty frame is an empty group (`count` 0, `sum`
NULL). A frame on a ranking function is accepted and does not change it. `RANGE`
and `GROUPS` need value arithmetic between rows, so they are refused with a
message rather than approximated. `test_window_frames` covers the shapes,
partitioning, the shorthand, the empty frame and both refusals.

**Done when.** Each refusal becomes a test; the list above is the checklist and
must not shrink by approximation.

**Not claimed today.** "SQLite-compatible SQL".

## D10 — Precision and time

**Now.** `Int128` is two `u64`s; decimals are floats; timestamps are
microseconds since the epoch without a zone; blobs are copied whole.

**Done when.** Decimal arithmetic with a declared scale, `TIMESTAMPTZ`
normalising to UTC, streaming blob reads, and conformance cases for rounding.

**Not claimed today.** "Fixed-point arithmetic".

## D11 — Virtual tables inside a transaction

**Now.** `CREATE INDEX` and `DROP INDEX` behave like any other change: they are
staged in the transaction, applied after the rows of the same commit (so the index
is built once, from the final rows), and rolled back with it. `DROP INDEX`
without `ON` also resolves an index created earlier in the same transaction, and a
duplicate name is refused before apply. `test_ddl_in_transaction` covers a table
created with its rows and index, an index over rows written in the same commit,
and a rollback that leaves no index behind.

**Left.** Triggers and policies created in the same transaction as the rows they
affect are not ordered against those rows yet.

**Not claimed today.** "Atomic DDL" for triggers and policies; index DDL is
atomic and tested.

## D12 — Modules: metering and latency are done, the sandbox is not

**Metering (D12a, done).** `Tx.work_units` charges one unit per row read or
written; `host_set_work_budget` sets a ceiling and a call that exceeds it is
rolled back with `quota_exceeded`, so a runaway reducer cannot commit partial
work. `host_work_units_last` reports what the previous call spent, which is how a
caller sizes the budget. `test_work_budget` proves the abort and the rollback.

**Latency (D12b, done).** A call writes a frame and reads a frame on a **pooled
socket** per module instead of connecting again; a socket the peer closed while
idle is dropped and the call redials once. `test_remote_module` makes two calls
and asserts the listener accepted exactly one connection.

**Determinism (D12c, done for the clock).** A call carries the caller's
`now_us` in its frame, and the receiving side runs the reducer with that clock
(`host_call_once_at`) instead of its own, so replaying a call reproduces it.
`test_remote_module` fixes the caller's clock and asserts the module stored it.
What is still unclaimed is a VM that also controls randomness, memory and time
limits; the host can bound the work per call (D12a) but not the module's internals.

## D13 — Exactly-once across restarts

**Done.** `host_call_once` inserts the request id and the reducer's result into
`_request` **inside the reducer's transaction**, so the id, the response and the
effects commit together; a restart replays it and a retry is a no-op.
`host_call_once_result` (and its `_at` form with the caller's clock) returns the
stored response on a retry and the fresh one on the first run, so a caller that
lost the reply gets the same answer instead of reading the state again.
`test_idempotent_result` covers the first call, the retry (counter unchanged), a
different id, and a reducer that names no result. `test_durability_after_restart`
covers the restart.

## D14 — Replication

**Now.** One process owns one log. There is no replication code in the tree.

**Done when.** A follower catches up from the log, reads are served locally, a
leader change is safe against a torn log, and the tests cover a partition. This
is the largest single item on the list and nothing depends on it today.

**Not claimed today.** Nothing at all.

## D15 — Network hardening

**Now.** HTTP/1.1 and WebSocket with request, header and frame caps; the wire
protocol runs over both.

**Done when.** TLS termination (or `openssl`-style handoff), HTTP/2, per-route
timeouts, backpressure on a slow reader, and a load test in `scripts/`.

**Not claimed today.** "Production HTTP server".

## D16 — A client in another language: **done for Python**

**Now.** `sdk/python/miraidb.py` wraps the C ABI with `Connection`, `Statement`
and `Row`: `connect`, `execute`, `query`, `prepare`, binds of every scalar type,
iteration, error messages and reconnection. `scripts/sdk_smoke.py` runs the path a
user would (create, bind, read by name and by position, update, a prepared
statement, an error, a reopen) and is a gate in `scripts/ci.py`.

**What remains.** Only one language, and generation is per-catalog for Odin
(`codegen`). Generating this binding from a schema would be the next step; the
hand-written module is the contract a generated one has to meet.

---

## Ordering, if this becomes the roadmap again

1. **D8** first: it is small and it protects everything else.
2. **D11** then **D1**: the index restriction is the only thing making full-text
   slow, and both are small.
3. **D6** and **D4**: the two largest wins a user can feel, in that order —
   planning first, because a faster file with a bad plan is still slow.
4. **D3**, **D7**, **D13**: correctness under failure and history.
5. **D2**, **D5**, **D9**, **D10**, **D12**, **D15**, **D16**: independent.
6. **D14** last: nothing needs it yet, and it is the biggest.
