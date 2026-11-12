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
| D1 | Full-text term index and BM25 | one scan of the term table per pattern; no `rank` | index on `term`, BM25 `rank`, `snippet` | M | P0 |
| D2 | Spatial index | overlap is a scan of the boxes | node file, tree descent | M | P2 |
| D3 | Snapshot cost | **borrowed values, ~1 ms to freeze 50k rows** | `AS OF` history, GC | M | P2 |
| D4 | Page backend | `.sqlite` is rewritten whole per commit | pages in place, WAL frames, free list | XL | P1 |
| D5 | Persistent indexes | rebuilt in memory when a database opens | index pages on disk | L | P2 |
| D6 | Query planner | nested loop + index probes | cost model, statistics, reordering | L | P1 |
| D7 | Scheduler durability | **durable** (due time is a logged column) | recovery test | S | — |
| D8 | Crash injection | **done**: `Fault_Vfs` fails any operation at any call, and `test_fault_injection` walks the write offsets | same for the snapshot and the mirror writes | S | P1 |
| D9 | SQL grammar | 32 statements, no window frames | frames, recursive CTE, full `ALTER` | L | P2 |
| D10 | Types and precision | `Int128` as two `u64` | decimal arithmetic, time zones | M | P3 |
| D11 | Virtual-table breadth | **done**: index DDL is staged and applied after the rows (`test_ddl_in_transaction`) | triggers/policies in the same transaction | S | P1 |
| D12a | Metering granularity | **per row read and written, with a budget that aborts** | — | S | done |
| D12b | Module call latency | **one pooled socket per module** | — | S | done |
| D12c | Module determinism | **caller's clock travels in the call**; no VM | deterministic VM, enforced quotas | L | P2 |
| D13 | Exactly-once across restarts | **durable** (request id commits with the effects) | result replay, not only skip | S | P2 |
| D14 | Replication | one process, one log | log shipping, follower reads, failover | XL | P3 |
| D15 | Network hardening | HTTP/WS subset with caps | TLS, HTTP/2, backpressure, per-route timeouts | M | P3 |
| D16 | Clients | **Python binding over the C ABI, with a smoke gate** | generation per catalog | M | P3 |
| D17 | Rows on disk | every table is a `map[Row_Id]Row` in RAM | page store, buffer pool, free list, eviction | XL | P0 |
| D18a | Second writer | **done**: `lock` file, OS lock, refusal naming the owner (`test_writer_lock`, `scripts/lock_smoke.py`) | — | S | P0 |
| D18b | Reader beside writer | one process owns the directory | pages + lock, read-only open | L | P1 |
| D18c | Broker mode | clients must be in-process | one owner, others over the wire | M | P1 |

---

## D1 — Full-text: index the term column

**Now.** `CREATE VIRTUAL TABLE … USING fts5(cols)` keeps an inverted index in
`_fts_<name>_terms (term, doc)` and `MATCH` resolves a pattern **once per
statement**, caching the document set in `Tx.fts_cache`. Resolution reads every
row of the term table, because there is no index on `term`: a virtual table is
created inside one statement and `CREATE INDEX` refuses to run in a transaction
that also creates tables (`tx_create_index`).

**Cost.** O(terms) per distinct pattern per query, then one map lookup per
scanned row. Small tables are unaffected; a corpus with a million tokens pays a
full pass for every query.

**Ranking.** There is no `rank` at all. BM25 needs two numbers the shadow table
can keep: document frequency per term (a counter row per term) and document
length (tokens per document). With both, `rank` is a scan over the matching
documents only, ordered by the formula; without the term index it would need the
vocabulary scan as well. So BM25 lands with the index, not before it.

**Done when.** `_fts_<name>_terms` is created with an index on `term` in the same
transaction as the table (this needs D11); `rank` is BM25 over the matching
documents with a test per shape (a rare term outranks a common one, a short
document outranks a long one at equal frequency); `snippet()`/`highlight()`
return the surrounding text with the match marked; `AND` is an operator rather
than a term. Cost of a query becomes O(matches + rows).

**Not claimed today.** "Full-text search" — not "ranked search".

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

## D3 — Snapshot cost: **done**, history still open

**Now.** A read snapshot borrows the table's values instead of copying them: the
freeze builds the row map and the index entries and hands both tables a
reference-counted `Row_Store`. The source defers freeing values while a snapshot
that shares them is alive (an update keeps the old values as a version, a delete
tombstones the row, a truncate hands the rows to the store), and the last owner
out frees them. Adopting a foreign row store per table cost 23 lines of plumbing.

**Effect.** Four hundred fifty thousand rows freeze in the noise of one
statement: `bench-read <db> 50000 100` reports 11.2 µs per transaction including
the first one (before, the first read alone cost ~190 ms). Steady state is
unchanged at 11.6 µs. `test_snapshot_shares_values_safely` proves isolation across
an update and a truncate while the reader holds its view.

**What remains.** There is still no `AS OF`: reading an arbitrary past sequence
needs versions indexed by sequence and garbage collection for them, which is a
separate piece of work.

## D17 — Rows on disk (the page store)

**Now.** Every table is a `map[Row_Id]Row` in memory. That is why reads are
10.7 µs and why opening a large database rebuilds its indexes: the whole
database is the working set.

**Gap.** Fixed-size pages, a page file (or one file with an allocation map), a
buffer pool with a clock hand and a memory cap, dirty-page flushing ordered
after the commit record that describes it, a free list that survives a crash, and
rows read and written through pages instead of a Go-style map.

**Done when.** A table larger than the buffer pool reads correctly; RSS stays
under the configured cap while scanning a database ten times larger; a kill
during a flush still opens to a consistent state (D8 proves it); `bench` and
`bench-read` stay within 10% for data that fits in memory.

**Not claimed today.** "Pages on disk" — nothing is paged today.

## D18 — Access from another process

**Now.** Several *connections* to one host work. Several *processes* on one
database directory do not share it: the first one owns it, and the others are
refused with `locked` naming the owner (`pid` and start time), so nothing is
silently corrupted. The lock is an OS lock on `<directory>/lock` (Windows
`LockFileEx`, POSIX `fcntl`) and it disappears with the process, including a
killed one.

**Gap.** In order: (a) *done*: the exclusive lock on open; (b) with D17, a
read-only open beside a writer; (c) a broker mode where one process owns the
database and the others speak the wire protocol to it — the cheap answer, and the
one that reuses everything already tested.

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

**Now.** 32 statement kinds. Refused with `sql_unsupported`: window frames,
windows beside `GROUP BY`, `BEFORE` triggers and trigger `WHEN` clauses,
recursive CTEs (the keyword parses, the recursion does not run), `ALTER TABLE`
beyond rename/drop/add column, collations beyond `BINARY`/`NOCASE`/`RTRIM`,
user-defined functions.

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

## D13 — Exactly-once: **durable**, with one gap

**Now.** `host_call_once` inserts the request id into `_request` **inside the
reducer's transaction**, so the id and the effects commit together; a restart
replays it and a retry is a no-op. `test_durability_after_restart` proves it.

**What remains.** The stored response is an empty product, so a retry returns
"already ran" rather than the original result. Storing and returning it is a
small change; a caller that needs the value has to read the state instead.

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
