# Backlog: depth work

The parity matrix is closed: every feature in `docs/features.md` has an
interface, a test and a documented cost, and `docs/roadmap.md` orders what is
left. This file is the other axis — **depth**. It lists the places where the
implementation answers the interface at a lower cost than a mature engine would,
what the current behaviour actually costs, what "done" means, and how big the
work is.

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
| D3 | Snapshot cost — *done* | a read copies nothing (one reference per table); a commit copies the table it writes when a reader holds it, once per read generation: read after a commit 38 µs on the gate, commit against a reader 16.9 ms (`test_a_commit_copies_the_table_a_reader_holds`) | automatic version retention | M | P2 |
| D4 | Page backend | `.sqlite` is rewritten whole per commit | pages in place, WAL frames, free list | XL | P1 |
| D5 | Persistent indexes | **done**: index keys live in B+trees of pages, with a pool, a cursor over chained leaves and a memory gate | merging empty leaves; a trusted open without replay (D18b) | L | P0 |
| D6 | Query planner — *done* | `ANALYZE` measures row counts, per-column distinct/NULL counts, the numeric range and a sixteen-bucket histogram into `<db>/stats`; the plan prices scan against probe from those numbers, picks between index candidates, prints `est. N rows, cost C`, prices a range written as two comparisons as one band, serves `ORDER BY` from an index, and searches the join order by cost — a step whose ON can be answered is preferred, because one that cannot multiplies the intermediate result by the whole relation (`test_plan_reorders_a_join`, `test_plan_does_not_cross_join_before_it_can_filter`, `scripts/plan_check.py`) | **nothing** | — | — |
| D7 | Scheduler durability | **durable** (due time is a logged column) | recovery test | S | — |
| D8 | Crash injection | **done**: `Fault_Vfs` fails any operation at any call, and `test_fault_injection` walks the write offsets | same for the snapshot and the mirror writes | S | P1 |
| D9 | SQL grammar | 33 statements, **`ROWS`/`RANGE`/`GROUPS` frames, trigger `WHEN` and `BEFORE`, `RENAME COLUMN`, `GROUP BY` on an alias and `JOIN … USING` done** (`test_window_frames`, `test_window_range_and_groups_frames`, `test_trigger_when`, `test_before_triggers`, `test_alter_rename_column`, `test_group_by_a_projection_alias`, `test_join_using`) | windows beside `GROUP BY`, `ALTER` type changes, user functions | L | P2 |
| D10 | Types and precision | `Int128` as two `u64` | decimal arithmetic, time zones | M | P3 |
| D11 | Virtual-table breadth | **done**: index DDL is staged and applied after the rows (`test_ddl_in_transaction`) | triggers/policies in the same transaction | S | P1 |
| D12a | Metering granularity | **per row read and written, with a budget that aborts** | — | S | done |
| D12b | Module call latency | **one pooled socket per module** | — | S | done |
| D12c | Module determinism | **caller's clock travels in the call**; no VM | deterministic VM, enforced quotas | L | P2 |
| D13 | Exactly-once across restarts | **done**: request id and result commit with the effects; a retry returns the stored result (`test_idempotent_result`) | — | S | P2 |
| D14 | Replication | one process, one log | log shipping, follower reads, failover | XL | P3 |
| D15 | Network hardening | HTTP/WS subset with caps | TLS, HTTP/2, backpressure, per-route timeouts | M | P3 |
| D16 | Clients | **Python binding over the C ABI, with a smoke gate** | generation per catalog | M | P3 |
| D17 | Rows on disk | **done**: paged tables, pool, free list, flush order, streaming scan with aggregates, memory gate | index pages (D5), a trusted open without replay (D18b) | XL | P0 |
| D18a | Second writer | **done**: `lock` file, OS lock, refusal naming the owner (`test_writer_lock`, `scripts/lock_smoke.py`) | — | S | P0 |
| D18b | Reader beside writer — *done* | **a reader opens beside the writer** (two lock bytes: writer exclusive, reader shared; `read_only` replays into memory, refuses every write and keeps compaction waiting) and **a paged database opens without replaying**: `<db>/catalog` names the schema and the log index names the last record, and the open trusts the page files only when both sequences agree (`test_read_only_opens_beside_a_writer`, `test_trusted_open_skips_the_replay`, `scripts/lock_smoke.py`) | a follower that tails commits; a read-only open of a quiescent database could trust the pages too, but a reader cannot know whether the writer beside it has pages in flight | L | P1 |
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

**Done: a read copies nothing.** A read transaction takes one reference per table
(`table_share`) instead of building a snapshot, so opening it after a commit costs
38 µs on the gate and 21 µs over 50 000 rows, where it cost 24 ms. The copy moved
to the write side, where it is also per table: `store_apply` calls
`store_table_writable`, which clones the table (`table_cow_clone`) only when a
reader holds it, and only for the table the commit writes. The clone copies the
row map (presized) and the index trees shape for shape, borrows the values through
the shared `Row_Store`, and leaves the old table to its readers; the old table
becomes read-only and the copy frees the history and tombstones its readers can no
longer see. After the copy the store owns the table again, so the commit after it
mutates in place: a long reader costs one copy per table, not one per commit. The
store's read cache, its reference-counted entries and the `READ_CACHE_LIMIT` guard
are gone with it.

`bench-read` reports the read and the commit that pays for a live reader
separately (`first_read_us`, `commit_with_reader_us`) and `scripts/bench.py` gates
both, so a copy that reappears on the read side, or a commit that copies when
nobody reads, fails CI. `test_a_commit_copies_the_table_a_reader_holds` proves the
reader keeps its values, that the table a commit does not write is the same object
before and after, and that a commit nobody reads copies nothing;
`test_snapshot_survives_dropping_the_source` proves a reader outlives a `DROP`.

What this file used to claim — "~11 µs per transaction including the first" — was
measured wrong: `bench-read` ran a `SELECT count(*)` before it started the clock,
and that statement published the read cache. Measured directly, `table_snapshot`
cost 117 ms on 50 000 rows because it rebuilt every index; the shape-for-shape
clone of the index trees (no comparisons, no rebalancing) brought a copy to 36 ms,
and moving the copy to the writer took it out of the read path entirely.

**Left.** The copy a commit pays is still O(rows of the written table) while a
reader is open — that is the price of a reader that never blocks a writer. Nothing
copies rows on the read side. Automatic version retention (below) is the only
remaining piece of D3.

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

**Done.** `src/engine/page.odin` holds the storage: 4 KiB slotted pages with a
checksum per page, cells encoded like the log, a free list linked through free
pages and headed in page 0, a buffer pool with a clock hand, pins and write-back,
and a streaming reader. Flush order is data pages first, then page 0 with
`applied_seq`, proved by breaking each write of a flush. `page_frames` data
frames plus a reserved header frame; `test_page_store_streams_within_the_pool`
reads a file of more than forty pages with four.

`store_open(..., paged_tables = true, page_frames = N)` gives each user table a
file under `<db>/tables`, applied to by the commit path and flushed after the log
record is durable. The file is a cache: open discards it and replays. The
executor streams a paged table for a single-table query (`WHERE`, projections,
aggregates, `LIMIT`), and falls back to collecting for `ORDER BY`, `GROUP BY`,
`DISTINCT`, windows, `AS OF`, joins, staged writes and index-answered filters.
`test_paged_table_roundtrip` and `test_paged_table_churn` cover it;
`scripts/page_rss.py --check` bounds the statement's memory (316 KiB for 15k and
60k rows through an 8-frame pool).

**Bugs this stage found.** The header frame could be handed to a row page, and
the next flush wrote the header over it, so those rows never reached the disk
(119 of 100000 after a reopen). Compaction renumbered slots while the row
directory addresses rows by slot, so a churned page lost rows. The streaming
visitor allocated one `Source` slice per row in the transaction arena, making
the scan's memory grow with the table.

**Left.** Index keys in pages (D5), trusting the page files on open instead of
replaying the log (D18b), a paged table with versions so `AS OF` and `ALTER` can
work on it, and a read that does not take the shared lock.

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

The auth review found a second, worse bug: the identity was stored on the store,
so a client that authenticated lent its rows to every later client. Each client
now carries its own identity (`Client.identity`): a request runs with its
caller's identity, a token or `SET identity` inside a request is kept for that
connection, and a new connection starts from the default.
`test_connection_identity` covers two authenticated clients, an unauthenticated
one, a bad token and `SET identity`.

That test found a real bug: the server read the request once and parsed it, so a
request whose body arrived in a second segment was answered
`bad request`. The
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

## D4 — A page-oriented backend: **done**

**Now.** `src/engine/sqlite_mirror.odin`. A database opened from a `.sqlite` file
reads the file's layout once — for every table, the leaf pages its b-tree is made
of, the rowids each leaf holds, and the rowid the store's rows map to — and after
a commit it rewrites only what changed: the leaf page of each row the commit
inserted, updated or deleted, the separator that leaf's parent stores for it, the
parent page and its ancestors when a page has to split, and page 1, whose header
carries the change counter, the page count and the free list. A full page splits
into as many pages as its cells need; a leaf that loses its last row is unlinked
and put on the free list, and the next growth takes that page back instead of
making the file longer.

**Cost.** Three pages (12 KiB) per commit, whatever the table holds, because a
commit touches one leaf, its parent and the header: `scripts/mirror_cost.py
--check` builds a 1828 KiB table and asserts three commits write less than the
file, and prints the numbers — 12 KiB per commit at 10k, 100k and 250k rows,
where re-encoding would write 172 KiB, 1.8 MB and 4.8 MB.

**How it keeps the promise under a crash.** Before a page moves, its original
goes into a rollback journal in SQLite's own format (magic, nonce, per-page
checksum, sector-padded records); the data pages are written, then page 1, then
the journal is deleted. An engine or a SQLite that finds the journal restores the
pages and removes it, so an interrupted commit leaves the previous state readable
(`test_mirror_survives_a_torn_commit`). Recovery belongs to the file's owner: a
plain reader applies a hot journal in memory and leaves it on disk.

**What it re-encodes instead.** A table with no single INTEGER primary key (its
rowid would not be stable), a table with a secondary index (the index b-trees are
not patched yet, and a stale index is worse than a slow commit), any schema
change, a file with a write-ahead log, and a tree deeper than three levels. The
fallback is `sqlite_file_write` plus a fresh map, so a commit never fails over it.

**Bugs this cost.** (1) `direct` — the check for "the parent is the root" was
written as "the parent's first child is the first leaf", which is also true of the
left-most interior page of a three-level tree: deleting a row on a 250k-row table
then tried to pack 1183 children into one page and re-encoded the file. It is
`len(chain) == 1` now. (2) An empty leaf breaks SQLite's cursor: a delete that
emptied a page left it in the tree, our own reader accepted it, and SQLite said
`database disk image is malformed`. Emptying a leaf now unlinks and frees it.
(3) The journal was written after the header was patched, so a rollback restored
the new header; page 1's original is captured before anything is staged.

**Not claimed today.** "SQLite as a storage backend" — it is a mirror: the commit
log is the truth, a secondary index re-encodes its table, and writing the file
with another driver while the engine holds it open is not detected.

## D5 — Index keys in pages: **done** (a trusted open is D18b)

**Now.** An index of a paged table is a B+tree of 4 KiB pages in
`<db>/indexes/<table>/<index>`, with the same pool, checksum, free list and flush
order as the row files. Leaf cells hold `key | row id` in key order and each leaf
links to the next, so a cursor walks a range without a parent stack; a branch
holds a separator and a child per cell; page 0 holds the root, the height and the
entry count. The keys leave the table arena, so `table_memory` reports the pool
instead of one entry per row, and a point lookup on 3000 rows visits at most four
rows. `CREATE INDEX` on a paged table walks the row pages and fills the tree,
`DROP INDEX` closes and removes the file, `TRUNCATE` starts a fresh one, and a
reopen rebuilds them with the table pages (the replay is still the source of
truth).

**Cost / bugs found.** The first version of `table_add_index` built its visitor
context without the table pointer, so a `CREATE INDEX` after a reopen crashed
with a segmentation fault while the same statement in a fresh session sometimes
worked — the stack happened to hold the right pointer. `test_paged_index_pages`
now creates an index after a reopen. A leaf that loses its last entry is left in
place (no merge yet); the cursor walks past empty leaves, which is why a delete
is still correct, and the test deletes a third of 5000 keys to prove it.

**Left.** A merge between neighbours, and trusting the header when its
`applied_seq` matches the log (D18b) instead of replaying.

**Not claimed today.** "Persistent indexes" as in "opening does not touch them".

## D6 — A planner with numbers

**Now.** `src/engine/stats.odin` measures each table once (rows, distinct non-null
values, NULLs, and for numeric columns the range plus sixteen equi-width buckets)
and keeps them in `<db>/stats`. `src/engine/plan.odin` prices a scan against an
index probe, picks the cheapest of the predicates that have an index, and orders
the relations of a join so the one that keeps the fewest rows per outer row runs
first, attaching every ON to the step that completes the relations it names. The
executor takes the same decisions the plan prints (`test_analyze_and_plan_estimates`,
`test_plan_reorders_a_join`), and `scripts/plan_check.py` is the regression gate
that fails when a known-good plan gets worse.

**Done: the join delta.** A join subscription indexes the key of an equi-join
instead of collecting the joined tables. `host_join_plan_probes` reads every `ON`
clause and, for each equality between two plain columns of the same type, records
a probe in both directions: the later source is found from the values of the
earlier ones, and the earlier source is found from the changed row when the commit
touched the later one. `host_join_index` files each source's rows under that key
(buckets live in the subscription's arena) and follows inserts, updates and deletes,
so a commit evaluates the matches and not the table. An expression that cannot be
indexed (an arithmetic key, two different types, a `FLOAT` key, a paged source)
takes the full re-evaluation instead, which is correct and slow rather than wrong.
`test_join_subscription_probes_the_join_key` counts the candidates: over 200
authors and 900 books an insert walks one and a base-row change walks six, where
the collect walked 200 and 900; the answers are checked against a fresh
subscription after every step.

**Done: the inner side of a join is probed.** `join_index_probe` reads the ON
clause of a nested-loop step and finds an equality that binds a column leading one
of the inner table's indexes; `join_probe_rows` evaluates the outer side per outer
row, coerces the value, folds it by the column's collation and prefix-scans the
index, so the loop reads the matches. A probe that cannot be answered — the value
side names the inner table, the value does not coerce, the table has staged
writes, it is a view or a table function — falls back to the scan for that step,
which is why a wrong probe cannot shorten a result. `EXPLAIN` names the index, and
`test_join_probes_the_inner_index` bounds the rows read (about 1 200 where the scan
read 200 200 over 200 authors and 1 000 books) and checks the answers, the
expression key that cannot be probed, a LEFT join and the plan line.

**Done: `ORDER BY` from an index.** `index_order_for` matches the ORDER BY against
an index whose key it names completely, in order, all ascending (or descending on a
unique index, where no two rows tie); `index_order_ids` walks the tree in order, or
backwards with `node_prev`, and stops as soon as a LIMIT has the rows it needs when
nothing else can drop one. The same statement over 50 000 rows takes 137 ms against
342 ms sorted, and `ORDER BY id LIMIT 5` reads five rows in 4.6 ms.
`test_order_by_comes_from_the_index` compares the sequence with the sorted one, ties
included, and counts the rows a LIMIT reads.

**Done: the constants are measured.** A scan row, a row fetched by id and one
descent through the tree were timed over a 200 000-row table (100.8 ns, 456.3 ns and
600 ns), and `plan.odin` holds those numbers with the measurement written beside
them: an index row costs 4.5 scan rows and a probe 6. The plan reads the values it is given: a prepared
`v < ?` bound to 50 keeps the estimate `v < 50` gets, so the histogram decides the
access as well as the estimate (`test_plan_reads_a_bound_value`). A view is priced from the relation its own
query reads, and `EXPLAIN` says so
(`test_plan_prices_a_view_from_its_own_from`). The statistics announce their age: `EXPLAIN` ends with
`note: statistics measured at commit N, data at commit M`, or with `note: no
statistics measured` when `ANALYZE` never ran, so an estimate never passes for a
measurement (`test_explain_announces_stale_statistics`). The incremental subscription path (`host_join_prepare`) lays out the
walk in the order the query was written, so a subscription and the same query can
do different work for the same delta.

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
`GROUP BY`, `BEFORE` triggers, `RANGE`/`GROUPS` frames, `ALTER TABLE` beyond
rename/drop/add column, collations beyond `BINARY`/`NOCASE`/`RTRIM`,
user-defined functions. `GROUP BY` does not resolve a projection alias
(`GROUP BY d` where `d` is `dept AS d`), although `ORDER BY` does.

**Done: `ALTER TABLE RENAME COLUMN`.** A rename keeps the rows and the indexes:
indexes refer to columns by position and a rename keeps the count, so the stored
values are mapped by position instead of by name (matching by name would find
nothing and turn every value into its default — the bug the test caught). Adding
or dropping a column still matches by name because the count changes. Text that
names a column (a generated expression, a trigger body, a policy, a view) is not
rewritten, and a virtual table is refused. `test_alter_rename_column` covers the
rename, the unique index still rejecting duplicates, the refusals and a reopen.

**Done: trigger WHEN.** `CREATE TRIGGER ... WHEN <condition>` keeps the
condition as text and parses it when the trigger fires, with NEW and OLD in
scope; a false or NULL condition means the trigger does not fire for that row,
which is not an error. The condition is parsed at `CREATE TRIGGER` too, so a
syntax error is reported there. A catalog written before the column existed gets
it on first use (`ALTER TABLE _triggers ADD COLUMN when_text`), so older
databases keep their triggers. `test_trigger_when` covers INSERT/UPDATE/DELETE
conditions, a NULL condition, the creation-time error and the migration.

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

## Correctness — nothing accepted may answer a different question

**Found while auditing this list, and fixed.** `NATURAL`, `RIGHT` and `FULL` were
not keywords the parser knew, so each was read as an alias for the table before
it: `FROM a NATURAL JOIN b` became a cross join and `FROM a RIGHT JOIN b ON …` an
inner join. Both returned rows; nothing in the suite complained, because the
suite asserts what the engine answers, not what it should have refused.
`test_unsupported_joins_are_refused` pins the three refusals now (`JOIN … USING`
was already refused).

**The gate that would have caught it.** `scripts/conformance.py` holds twenty
hand-written cases with substrings they must contain. That checks what someone
thought to write down. What the parser *accepts* needs a second oracle:
`sqlite3` answers the same statements, so a corpus can be run through both and the
answers compared — equal rows, or a parse-time refusal on our side with a reason.
Anything else is a silent difference in meaning, which is the one class of bug a
test suite written by the same hand cannot find. `sqlite3` 3.53.4 is on the WSL
image (`/usr/bin/sqlite3`), so the runner belongs with the POSIX CI work; the
corpus can be generated from the grammar (`docs/sql.md`) plus the shapes that bit
us: aliases, keyword lookalikes, `AS OF`, `TRUNCATE`, `RETURNING`.

## Diagnostics — the leak report is unreadable

The debug allocator prints `+++ leak` for every block it still knows at exit:
**~320k lines per suite run**, about nine per statement, dominated by
`builder.odin:173`, `sql_exec_insert`, `sql_exec_select`, `projection_name`,
`br_read_len_bytes`, `lexer_next` and `plan_join_order`. The count has been flat
across rounds (312k before D6), so it is not a regression, and nobody has
established whether they are real leaks or allocations a bulk free releases out of
the tracker's sight. Two things would settle it and both are cheap: run 20k
statements in one process and compare the working set from `--memory-report` with
20k more (a real leak grows ~400 B per statement), and make `scripts/soak.py`
assert the working set stays flat instead of only checking the log and the reopen.
Until then the leak report cannot be used to judge a change, and a real leak
would hide inside it.

## Ordering, if this becomes the roadmap again

Ordered by what protects the rest, not by what is most interesting. Fixed items
stay listed so the order can be read as a whole.

1. **D8** (done), **D11** (done), **D1** (done): the small items that protect
   everything else.
2. **Correctness gate** (above): a differential runner against `sqlite3`. It is
   the only protection against the class of bug that just bit — an accepted
   statement that means something else — and it is worth more than any feature
   because a wrong answer costs more than a slow one.
3. **D4**: the largest win a user can feel, and the engine now has the pieces.
4. **POSIX CI**: `-sanitize:address` for the whole suite, `lock_posix.odin` and
   `rss_linux.odin` exercised, and the scripts taught to find `bin/miraidb`
   without `.exe` (`ci.py`, `page_rss.py`, `plan_check.py`, `bench.py`,
   `lock_smoke.py` and `broker_smoke.py` all hardcode a Windows binary).
5. **D6 leftovers**: probe the inner side of a join, `ORDER BY` from an index,
   statistics that say they are stale, and the histogram
   for a bound parameter (a plan chosen at bind time, or a re-plan when a value
   lands).
6. **Leak report** (above): make the diagnostics usable again.
7. **D9**, **D2**, **D10**, **D16**: independent surface work.
8. **D12c**, **D15**, **D14**: the module sandbox, the network, replication.
9. **Licences** and the release review last, before each public release.

## D19 — CASE expressions: **done**

**Done.** Both forms parse and evaluate anywhere an expression is allowed:
projections, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `UPDATE … SET`, policies
and triggers. A `NULL` operand or condition matches nothing, no `ELSE` gives
`NULL`, and only the chosen branch is evaluated, so
`CASE WHEN d = 0 THEN NULL ELSE n / d END` is safe. `test_case_expressions`
covers the forms, the NULL rules, the grouping expression and a nested `CASE`,
and `scripts/differential.py` compares seven `CASE` queries against `sqlite3`.
What it did not fix: `GROUP BY` still does not resolve a projection alias
(`GROUP BY d` for `dept AS d`), which is in D9 and in the runner's refusal
list.

**Why it matters.** It is the most used conditional expression in SQLite queries
(conditional aggregation, bucketing, `ORDER BY` keys) and the only statement the
compatibility matrix still lists as missing. A query ported from SQLite either
fails or is rewritten as several `iif()` calls.

**Scope.** Simple (`CASE x WHEN a THEN …`) and searched (`CASE WHEN cond THEN …`)
forms, evaluated wherever an expression is allowed: projections, `WHERE`,
`GROUP BY`, `HAVING`, `ORDER BY`, `UPDATE … SET` and generated columns. Evaluate
it as an expression, not as syntax sugar, so policies and triggers see it too.
`ELSE` absent yields `NULL`; a `NULL` condition is not true; the result type is
the common type of the chosen branch, as `value_compare`/coercion already decide
for `iif`.

**Done when.** Both forms parse, the tests cover the branch chosen, the missing
`ELSE`, a `NULL` condition, a `NULL` branch and a nested `CASE`; `docs/sqlite.md`
turns the row `done`; and a `CASE` in a policy or trigger works.

**Cost.** M (one parser production, one evaluator case, tests).

## D20 — A differential runner against SQLite: **done**

**Done.** `scripts/differential.py` is the twenty-third gate: one schema, one set
of rows and 55 queries go through this engine and the system `sqlite3`, and the
answers must match (as sequences when the query says `ORDER BY`, as multisets
otherwise). Seven statements are refused here and answered there, each with the
reason in the script, and the runner fails when a refusal stops refusing; four
differ on purpose and fail when they converge. It found two things on its first
run: `ORDER BY` ties came back in map order instead of row id order (fixed, with
the tiebreak in the sort key), and the scalar forms `min(a, b)`/`max(a, b)` and
`trim(s, chars)` were missing (fixed). The corpus should keep growing; a
correlated subquery is in the refusal list, because `features.md` E2 says the
reference is not resolved.

**Why it exists.** `scripts/conformance.py` runs 20 statements through the CLI
and checks substrings of the output. It is a smoke: no joins, CTEs, windows, triggers, JSON,
`ALTER`, `UPSERT`, three-valued logic or `DISTINCT` aggregates. The audit of this
tree found two wrong answers (`IN`/`NOT IN` with `NULL`, `DISTINCT` inside an
aggregate) that the suite could not see, and neither could this corpus.

**Why it matters.** A hand-written suite tests what its author thought of. A
differential runner tests the engine against a reference implementation over a
corpus: same schema, same rows, same query, and the answers must match exactly
(or the engine must refuse the statement with a reason, and the refusal is listed
as intentional). That is the only cheap way to find the next `IN`/`NULL`.

**Scope.** Build the same database through both engines (avoiding features that
are intentionally absent), run a corpus of queries and compare the rows, the
column names and the order where the query says `ORDER BY`. Start with the
existing 20 cases plus: inner/left/cross joins, aggregates with `DISTINCT`,
`GROUP BY`/`HAVING`, window frames, `LIKE`/`GLOB`/`ESCAPE`, `CAST`, integer
overflow, `IN`/`NOT IN`/`BETWEEN` with `NULL`, subqueries, `UPSERT` with
`excluded`, `RETURNING`, CTEs, triggers, JSON functions and `ALTER`. A statement
the engine refuses is recorded in a list with the reason, so a new refusal fails
the gate until someone writes it down.

**Not in scope.** Cases where SQLite's behaviour is deliberately different
(`1/0`, `CAST('abc' AS INTEGER)`, integer overflow, comparing text with a
number). They are listed in `docs/sqlite.md` and in this file, so the runner
skips them with a comment.

**Done when.** The runner is a CI gate, the corpus covers the areas above, and a
deliberate wrong answer (e.g. `count(DISTINCT x)` returning the row count) makes
it fail.

**Cost.** M (a generator for the corpus, the two databases, the comparison and
the refusal list).

## D21 — Documentation that cannot drift

**Done.** `scripts/docs_check.py` is a CI gate: it reads the version the library
reports and compares it with `CHANGELOG.md`; counts the `@(test)` declarations
and compares them with `status.md`; asks `ci.py --list` how many gates exist and
compares every document that states the number; compares the CLI commands the
usage text lists with the list in `status.md`; resolves every relative link in
`README.md` and `docs/*.md`; checks that every `D<n>` named in the roadmap exists
in this file and that each roadmap row has the five cells the table needs;
refuses an orphan document (one no other document links to); and scans the tree
for the names the project does not use.

**Why.** Three of the findings in the audit were sentences that had stopped being
true — a test count, a gate count, and a matrix row that claimed a feature nobody
had written — and nothing failed when the engine moved on.

**Left.** It checks numbers and links, not prose: a paragraph that describes an
old design (the kind of thing the audit found in `sql.md` and `README.md`) still
needs a reader. The gate makes the cheap half impossible; the other half stays an
editorial duty, listed in `CONTRIBUTING.md`.

## D22 — The server, for real — **done**

**Done: a thread per connection, and the delta path.** Each accepted socket gets
its own thread (`src/server/main.odin`: `thread.create_and_start_with_data`), the
registry behind it is locked (`Host.clients_mutex`, so a connection's counters can
be bumped by a statement thread while another thread registers), writes to a
socket happen under that socket's lock, and `host.on_update` is finally wired to
the transport: a commit finds the connection that owns the subscription
(`host_subscription_owner`) and writes one delta frame into it.
`scripts/broker_smoke.py` runs a subscriber and a second client at the same time,
reads the delta the write produced, and checks that two frames in one read both
answer. The frame loop also waits for the rest of a frame that has not arrived
instead of closing the socket, which the old one did.

Statements still run **one at a time**, under `Server.statements`: the store
carries the caller's identity while a statement executes (`store_set_identity`),
so two statements at once would see each other's. A slow query therefore queues
the others rather than running beside them, which is what step 2 is for.

**Done: the host-touching statements.** `ATTACH`, `LOAD EXTENSION` and
`VACUUM INTO` name a path or a module the client chose, so the server refuses
them with `Permission_Denied` unless it was started with `--allow-host`
(`Store.host_access`, set from the server; an embedded open starts with it on).
`test_host_statements_need_host_access` proves the refusal, the unchanged commit
sequence, that reading/writing/DDL still work, and that turning it back on
restores the statement; `broker_smoke.py` proves it over the wire. `docs/security.md`
is the written model: what a token buys, that grants are opt-in, and what is not
defended. The gate also turned up a bug in the gate itself: `decode` in
`broker_smoke.py` read the error *kind* as the message length, so no error text
had ever been matched.

**Done: what bounds one statement.** `--statement-timeout-ms=N` arms a watchdog
thread. A statement announces itself to it (`statement_begin`, which also clears
a stale cancellation), and the watchdog polls every 2 ms against a monotonic
tick: when the statement has spent its time it sets `store.cancel` through
`sync.atomic_store`, which every row loop in the executor checks and answers
`cancelled`. A cancelled statement is an error, not a crash: the gate starts a
second server with a 300 ms limit, asks for a four-way cross join, reads
`cancelled`, then reads `SELECT 1` and the table it never wrote. `--budget=N`
sets the engine's per-statement work budget, which refuses *after* the work.
`store.cancel` and its read side are atomic now, so the flag is sound across the
two threads that touch it.

**Left for its own items.** Grants are opt-in (a database with no grant rows
allows every statement), which is a policy decision rather than a bug: it is
listed in the auth review. TLS, HTTP/2 and backpressure are D15; the row quota
and a depth bound are D23.

**Second half: who may ask.** A wire request runs under the connection's identity,
and identity is whatever the bearer token said — or nothing. Grants are opt-in:
`permission_allows` answers `true` when `_grant` has no rows, which is the state of
every database that never created one. So an unauthenticated client can create,
read, write and drop tables, and can also run `LOAD EXTENSION` (native code in the
host process) and `ATTACH` (a file path in the host). Verified against a running
server: `CREATE TABLE`, `INSERT`, `SELECT`, `DROP TABLE` all answered 200, and
`LOAD EXTENSION` / `ATTACH` reached their loaders.

**Next.**

1. ~~Serve connections concurrently and prove it.~~ Done; `broker_smoke.py` holds
   a subscription open while another client writes and reads the delta.
2. Wire a per-statement work budget and a cancel route (`store_set_work_budget`,
   `store_cancel`) so a stuck statement ends with `.Cancelled` instead of ending
   the process, and a client that leaves stops its work.
3. Refuse the host-touching statements (`ATTACH`, `LOAD EXTENSION`, `VACUUM INTO`,
   DDL) to a remote client unless the server was started with a flag that allows
   them; keep them allowed on the local embed path.
4. Write the threat model down in `docs/`: what a server without a token is
   trusted to do, and what `--any` changes.

**Acceptance.** Two clients at once, one of them subscribed (`broker_smoke.py`
grows a second concurrent client); a statement that spends more than the budget
returns `.Cancelled`; a remote client's `LOAD EXTENSION` is refused and the same
statement through the embed API still works; the document exists and says what is
refused.

**Cost.** L. It is the difference between a demo of the wire protocol and a server.

## D23 — Resource limits — *partly done*

**Done.** The depth bound. `MAX_EXPRESSION_DEPTH :: 100` counts the outermost
expression as level one, and both halves enforce it: `parse_expression` refuses a
tree that nests deeper (so 99 levels of parentheses parse and 100 do not) and
`eval_expr` refuses while it descends, which is the half a `+` chain of 2 000
terms needs, since it parses iteratively as a left-deep tree. Before this the
process died at 166 nested parentheses, 178 terms in one chain and 155 nested
`CASE`s, by stack overflow, with no message and no exit code. The boundary is
measured on a release build and stated in `test_expression_depth_is_bounded`,
which also proves the test process survives all three shapes.

The quota is read where rows appear: `sql_exec_select` stops as soon as the
projection passes `max_rows_per_query`, except when the statement carries
`LIMIT`/`OFFSET`, which bound their own rows (the post-check applies there).

**Now.** Three ways to lose the process, all measured on the shipped CLI:

| Input | Result |
|---|---|
| `SELECT ((((…1…))))` 170 deep | exit 253 (`0xC00000FD`, stack overflow), no message |
| `SELECT 1+1+…` 2 000 terms | exit 253 |
| `SELECT CASE WHEN 1 THEN …` 300 deep | exit 253 |
| a three-way join with a 2·10⁹-row intermediate | `sql_exec.odin: Index 1 is out of range 0..<0` |

The first three are a recursive descent and a recursive evaluator with no depth
bound; the fourth is `make` returning `nil` under memory pressure and the code
indexing it anyway. Separately, `max_rows_per_query` is compared with the row count
**after** the result is built, so the cap that exists to prevent the spike cannot
prevent it, and neither the quota nor the work budget is reachable from the CLI,
the server or the C ABI.

**Next.**

1. ~~A depth counter in the parser and the evaluator.~~ Done at 100 levels.
2. ~~Check the row quota while rows accumulate.~~ Done for the projection. Left:
   the join's *intermediate* is built before the projection sees a row, so a
   `LIMIT 1` over a huge join still builds the join; and `LIMIT` is not pushed
   into the scan. This is where the memory spike actually happens.
3. Treat a failed allocation as an error (`.Out_Of_Memory` or the existing
   `.Quota_Exceeded`) everywhere the executor allocates per row. Not started: the
   audit saw it as `Index 1 is out of range 0..<0` and that path still needs a
   reproduction before it can be fixed honestly.

**Acceptance.** A test that nests exactly the limit (answers) and the limit plus
one (refuses, process alive); a test with a small quota over a cross join that
fails fast instead of materializing; a test that the CLI exits with an error code
and a message for both.

**Cost.** M. The counting is small; finding every recursive path is the work.

## D24 — The `.sqlite` mirror, completely — *partly done*

**Done.** Both defects the audit found are fixed and gated.

*The empty `sqlite_master`.* `sqlite_build_tree` with no cells returned an empty
leaf whose content offset was `usable`, ignoring the `reserve` its caller passed.
The `sqlite_master` tree reserves the 100-byte file header so its root can move
to page 1, and with the offset at `usable` the move had no room and returned
early — leaving page 1 with no b-tree header at all. `sqlite3` reads that as
`database disk image is malformed`, which is what a `DROP TABLE` produced. The
empty branch honours `reserve` now, so an empty database and a dropped last table
both write a file that opens (`test_empty_export_is_a_readable_file`, and the
gate checks `PRAGMA integrity_check` from Python's `sqlite3`).

*Indexes on import.* `sqlite_master_visit` skipped every row of type `index`.
`Sqlite_File.indexes` collects them (name, table, the SQL SQLite stored), and
`sqlite_import` runs each `CREATE INDEX` as it stands inside the import
transaction; a partial index that this engine cannot express is retried without
its `WHERE`, and if that fails too it is left out rather than failing the import.
`test_imported_indexes_are_planned_and_droppable` proves the plan names the index
and `DROP INDEX` answers `index_not_found` only for an index that is really gone.

*The gate.* `scripts/sqlite_abi_smoke.py` now opens a real `.sqlite` file through
the facade, runs `DROP TABLE`, `ALTER TABLE`, `INSERT`, `DROP INDEX` and
`CREATE INDEX`, closes, and verifies with Python's `sqlite3`: integrity, rows,
and which objects remain in `sqlite_master`. A second fixture drops the last
table and expects a valid empty database. Before the fix, the mirrored file was
`malformed` after that drop (reproduced with the CLI and `sqlite3` 3.53).

**What is left.** A schema change still re-encodes the whole file (the mirror's
cost, measured by `mirror_cost.py`); a partial or expression index that fails
both attempts disappears silently, which should become a counted and reported
skip; and the mirror has no fuzz pass of its own.

**Now.** Two defects in the compatibility path, both reproduced against files that
`sqlite3` opened and closed cleanly:

- `DROP TABLE` on a table that **held rows** leaves the file malformed —
  `PRAGMA integrity_check` answers `database disk image is malformed` and
  `sqlite_master` cannot be read. Dropping an empty table, truncating, adding a
  column, creating an index and updating rows are all fine, so the defect is in
  the full rewrite that DDL falls back to (`sqlite_mirror.odin`: `needs_full`)
  when it has to release the pages of a non-empty table.
- An imported file's **indexes are ignored**: the plan is a full scan and
  `DROP INDEX` answers `index_not_found`, while `sqlite3` sees the index in
  `sqlite_master`. Correct answers, missing access path, and one statement SQLite
  accepts that this engine refuses.

The ABI gate (`sqlite_abi_smoke.py`) creates a table, inserts, prepares and reads
blobs — no `DROP`, no `ALTER`, no `DROP INDEX` — which is why neither defect fails
CI.

**Next.**

1. ~~Fix the full-rewrite path and prove it with `PRAGMA integrity_check`.~~ Done.
2. ~~Read the indexes of an imported file.~~ Done, including the retry without
   `WHERE`.
3. ~~Extend the ABI gate to DDL.~~ Done. Left: a fuzz pass (random DDL and DML,
   integrity after each chunk) and a counted skip for an index that cannot be
   expressed.

**Acceptance.** The four DDL statements survive a round trip through the engine and
are valid for `sqlite3`; an imported index shows in `EXPLAIN` and can be dropped;
the gate fails if either regresses.

**Cost.** M.

## D25 — The C ABI, completely

**Now.** 24 functions in the sqlite3 shape (`open`, `close`, `errmsg`, `exec`,
`backup`, `prepare`, `finalize`, `reset`, six `bind`s, `step`, `changes`, nine
column accessors, `version`) and none of the engine's levers: no open options, so
an embedder cannot ask for read-only, in-memory or a durability other than the
default; no `miraidb_interrupt` although `store_cancel` exists and is tested; no
row quota or work budget; no identity or token, so roles and policies are
unreachable from C; no statement about thread safety. `miraidb_open` also imports
a `.sqlite` file into memory without saying so, which for a 250 000-row file is
~15 s and the size of the file in RAM.

**Next.**

1. `miraidb_open_v2(path, flags)` with read-only, create, durability and
   in-memory bits; keep `miraidb_open` as a thin wrapper so the ABI stays additive.
2. `miraidb_interrupt`, `miraidb_set_row_quota`, `miraidb_set_work_budget`.
3. `miraidb_set_identity`, `miraidb_authenticate(token)` so the C surface can use
   what `roles.odin` already checks.
4. A paragraph in `include/miraidb.h` on thread safety and pointer lifetimes, and
   the same in `docs/`.

**Acceptance.** `capi_smoke.py` exercises each new call; a cancelled statement
returns `MIRAIDB_ERROR` with "cancelled" in `miraidb_errmsg`; a read-only open
refuses `INSERT`; the header documents the model.

**Cost.** M.

## D26 — Docs whose claims are executed

**Now.** `docs_check.py` verifies shape: counts, links, forbidden names, five-cell
roadmap rows. It does not verify a sentence. Two rows of `docs/sqlite.md` still said
`BEFORE` triggers and `RANGE`/`GROUPS` frames are refused, and both have worked
since `0a59dbb` and `763bb3b` — this audit found them by reading, not by running
anything.

**Next.** Turn the compatibility matrix into data the gate executes: a table of
`(statement, expectation)` where `expectation` is `works` or `refused`, run
against both this engine and `sqlite3`, with the matrix rows generated from it or
checked against it. Start with the rows that name a refusal, because those are the
ones that go stale when a feature lands, then the `done` rows that are cheap to
state as one statement.

**Acceptance.** A row that says `refused` while the engine answers fails CI, and
the reverse too; the SQLite matrix is generated or cross-checked from the same
file.

**Cost.** S.

## D31 — The three wrong answers

**Now.** Three sentences that answer and are wrong, found by the second audit pass
(`AUDIT-10`) by running 47 edge queries through both engines:

| Query | SQLite | this engine |
|---|---|---|
| `SELECT substr('abcdef', -3)` | `def` | `abcdef` |
| `SELECT 1 WHERE 'a'` | 0 rows | 1 row |
| `SELECT 1.0` (`--json`) | `1.0` | `1` |

The first is a missing feature that fails silently: a negative start counts from the
end in SQLite, and the engine takes the absolute value path and returns the whole
string. `substr` is tested, but only with a positive index
(`test_functions` uses `substr(s, 3, 5)`), so nothing noticed.

The second is a semantics choice with the wrong default. `WHERE` asks a value for its
truth, and the engine's rule is "a non-empty text is true". SQLite converts the text
to a number first, so `'a'` is `0` and the row is dropped; `'1'` is true. The
difference is invisible until a predicate is written against a text column by mistake
— which is exactly when it matters.

The third is rendering, not data: `typeof(1.0)` answers `real`, and the JSON writer
prints `1` for it because the format string drops a trailing `.0`. A JSON consumer
gets an integer where the schema promised a real, and the differential runner cannot
see it (it also treats `1` and `1.0` as equal; D30).

`INSERT OR REPLACE` belongs here too: the parser refuses it with "expected into" and
neither `REFUSED` in the differential nor `docs/sqlite.md` says so.

**Next.**

1. `substr`/`substring`: a negative start counts from the end, a negative length
   returns the characters before the start (SQLite's rule), and both are tested at
   the boundary (start equal to length, start below the string, length 0).
2. `WHERE`: cast to a number the way SQLite does (`'12'` → 12, `'12a'` → 12, `'a'` →
   0, `''` → 0, `x'…'` → 0), then test truth against that. Keep the current strictness
   for comparisons (`1 = '1'` stays an error, listed in `DIFFERENT`): this is about
   *truth*, not about comparison.
3. The JSON writer keeps the `.0` for a real, so a consumer can tell the types apart.
4. `INSERT OR REPLACE`: implement it as `INSERT` + delete-on-conflict, or list it as
   refused in `REFUSED` and in `docs/sqlite.md`. Refusing is acceptable; refusing
   quietly is not.

**Acceptance.** Each of the four has a test that fails today; the corpus in D30 holds
them; `docs/sql.md` states the negative-index rule and the truth rule.

**Cost.** S.

## D30 — The differential cannot lie

**Now.** Two ways `scripts/differential.py` can look at a difference and not see it:

- **Ordering by substring.** `compare()` decides the rows are ordered when
  `"order by" in statement.lower()`. An `OVER (… ORDER BY …)` or a subquery with its
  own `ORDER BY` therefore makes the *outer* result compared position by position,
  while the outer query promises no order at all. Three window queries were reported
  as differences whose multisets were identical in this pass; the same defect can hide
  a real difference behind a lucky order.
- **Types as values.** `same_cell` compares `1` and `1.0` as equal, so a query that
  returns the wrong type passes.

And the gate advertises more than it enforces: `docs/roadmap.md` says a 10% regression
fails, while `scripts/bench.py` accepts 3x for every time metric and compares against a
number recorded on another machine (it prints `machine` and never compares it). Two runs
on this machine in one session produced 31 603 and 57 403 inserts/s, so the honest
target is a *reference measured in the same run*, not a stored number.

**Next.**

1. Decide "ordered" from the statement's own top level: the outermost `ORDER BY` after
   the last closing parenthesis of the `FROM`/`WHERE`/`GROUP BY` region, or — simpler
   and safer — compare as a multiset *and* as a sequence, and accept a query when
   either matches, while a query that names a top-level `ORDER BY` must match the
   sequence.
2. Compare types: a cell carries its kind, so `int 1` and `real 1.0` differ.
3. Adopt the 47 queries of `AUDIT-10` as the corpus, with the three D31 bugs listed in
   `DIFFERENT` until they are fixed and moved to `QUERIES` after.
4. The performance gate: measure a reference (a fixed, simple workload) in the same run
   and compare against *that*, so a loaded machine and slower code are distinguishable;
   keep the stored baseline as history. Then the roadmap can say 10% and mean it.

**Acceptance.** A window query that returns the right multiset in any order passes; one
that drops a row fails; a query returning `1` where SQLite returns `1.0` fails; the
performance gate fails on a 15% regression of a same-run reference and passes on a
loaded machine.

**Cost.** S for the runner, M for the same-run reference.

## D27 — The mirror keeps the schema it does not model

**Now.** One `ALTER TABLE` through the engine rewrites the user's `.sqlite` file with
the engine's own idea of the schema (`AUDIT-10` P-A1). Measured on a file that SQLite
created:

```sql
-- before
CREATE TABLE child (id INTEGER PRIMARY KEY,
  pid INTEGER NOT NULL REFERENCES parent(id) ON DELETE CASCADE,
  code TEXT UNIQUE CHECK (length(code) > 2),
  note TEXT DEFAULT 'n' COLLATE NOCASE)

-- after `ALTER TABLE parent ADD COLUMN extra INTEGER`
CREATE TABLE "child" ("id" INTEGER NOT NULL, "pid" INTEGER NOT NULL,
  "code" TEXT, "note" TEXT, PRIMARY KEY ("id"))
```

`PRAGMA foreign_key_list(child)` is empty afterwards. In the same experiment the file's
view and trigger disappeared (three objects before, one after), and a
`GENERATED ALWAYS AS (a*2)` column is imported as `NULL` and written back as a plain
NULL column.

The mechanism is two halves that each looked reasonable: `sqlite_import` recreates a
table from `Sqlite_Column` (name, type, NOT NULL, PRIMARY KEY), and `sqlite_file_write`
emits `CREATE TABLE` from the engine's `Table_Schema`. Any DDL forces the full rewrite,
so everything the engine does not model is dropped — silently, on a file that is the
user's database.

D24 closed the *corruption* in that path (the empty `sqlite_master`) and the *indexes*
on import. It did not close this, and the roadmap said DDL was safe, which was true of
integrity and false of semantics.

**Next.**

1. Keep each imported object's original SQL: `Sqlite_Table.sql` already carries the
   `CREATE TABLE` text and is currently unused by the writer. Extend it to views and
   triggers (they are rows in `sqlite_master` with SQL), and keep them in the mirror as
   opaque objects the engine does not evaluate but must not delete.
2. On a rewrite, re-emit the original SQL for every object whose engine-side schema is
   unchanged. For a table the engine *did* change (a column added), apply the change to
   the original statement or fall back to the generated one — and in that second case,
   say so: a `mirror_reason` the CLI's `--mirror-report` prints and the file's owner can
   read.
3. Refuse rather than degrade: a `ALTER`/`CREATE`/`DROP` that the engine cannot express
   against a table whose SQL carries constraints it does not model answers
   `mirror_unrepresentable` (or the existing `.Unsupported`) instead of writing a
   weaker schema. Losing a user's foreign keys silently is worse than refusing the
   statement.
4. Import a `GENERATED` column as generated, or refuse the table with a reason. A NULL
   column with the right name is the one outcome nobody can recover from.
5. Gate it: a fixture with FK, UNIQUE, CHECK, DEFAULT, COLLATE, a view, a trigger and a
   generated column goes through `INSERT`, `ALTER… ADD COLUMN`, `CREATE INDEX`,
   `DROP INDEX` and `DROP TABLE`, and `sqlite_master` is compared (normalised) against
   the expectation, plus `PRAGMA integrity_check` and a foreign-key check from a real
   `sqlite3`.

**Acceptance.** The fixture above keeps its constraints, view, trigger and generated
column through every DDL the engine accepts; a DDL it cannot express is refused with a
reason; `docs/sqlite.md` states which of the two happened.

**Cost.** L. It is a design decision (preserve the text, or model the constraints and
emit them) before it is code, and this item exists so the decision is written down.

## D28 — Open the way SQLite opens

**Now.** `:memory:` is not a database here (`AUDIT-10` P-A2):

```
$ ./bin/miraidb.exe sql ":memory:" "SELECT 1"
miraidb: io: cannot create :memory:: INVALID_NAME

sqlite3_open(':memory:')                   -> 1  (SQLITE_ERROR)
sqlite3_open('')                           -> 1
sqlite3_open('file::memory:?cache=shared') -> 1
```

`src/sqlite_compat` exists so a program written against `sqlite3_*` can link against
this engine instead, and the first thing such a program does is open an in-memory
database. Nothing documents the gap; the error names a filesystem problem, which is
misleading.

**Next.**

1. An in-memory open in the engine: `:memory:` (and the empty path) mean
   `store_open("", {persistent = false})`, which already exists — the work is the
   spelling and the ABI flag.
2. `file:…?mode=memory` and `?cache=shared` in the facade: recognise the URI form and
   either honour the memory mode or refuse with a reason.
3. A `MIRAIDB_IN_MEMORY` bit on the C open options (which lands with D25) so an
   embedder does not have to spell a name.
4. `docs/sqlite.md` and the header state which forms open in memory.

**Acceptance.** `sqlite3_open(":memory:")` through the DLL answers `SQLITE_OK` and a
statement round-trips; the CLI opens `:memory:`; `docs` list the accepted spellings.

**Cost.** S. This is the cheapest item in the table and it unblocks every sqlite3 test
suite.

## D29 — A C handle is never a dangling pointer

**Now.** `capi_stmt` is a cast of the caller's pointer (`src/capi/capi.odin:132`), so
after `miraidb_finalize` the memory is free and the next call reads it
(`AUDIT-10` P-A3):

```
miraidb_step(stmt) after finalize   -> 101    (DONE, from freed memory)
miraidb_bind_text(stmt, 1, "x")     -> access violation reading 0xFFFFFFFFFFFFFFF9
```

The second call ends the host process. `sqlite3` answers `SQLITE_MISUSE` to both, which
is what a C API has to do: the caller's lifetime bug is theirs, not the library's
chance to take the process down. The same shape applies to a connection closed while a
statement is open.

`bind` also takes any index: `miraidb_bind_int(stmt, 99, 1)` returns `OK` because
`embed_bind` grows the parameter list to fit (`src/engine/embed.odin:177`), so a typo
silently becomes a NULL parameter instead of `SQLITE_RANGE`.

**Next.**

1. A live-handle registry per connection: `finalize` removes the statement, every entry
   point looks it up and answers `MIRAIDB_ERROR` with "statement is closed" instead of
   dereferencing. `close` finalizes what is left (or refuses with a clear count).
2. A bind index bound: an index past the statement's placeholder count is an error, not
   a growth.
3. Column accessors on a finished statement return NULL/0 rather than reading freed
   rows, and `errmsg` explains.
4. A fuzz pass over the ABI (`ctypes`): random calls, wrong order, double finalize,
   closed connection; the process must survive every sequence.

**Acceptance.** The thirty hostile calls of `AUDIT-10` all answer (no crash), each with
a message a C programmer can act on; the fuzz pass runs as a gate.

**Cost.** M. The registry is small; deciding how much of sqlite3's misuse contract to
copy is the judgement.
