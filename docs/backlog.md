# Backlog: the detail of what is open

[roadmap.md](roadmap.md) orders the open work; this file holds the detail of each
item: what the engine does today, what it costs, what "done" means and how big
the work is. Items that are closed leave this file. Their evidence is recorded
in [closing-plan.md](closing-plan.md), and their full write-ups are in the git
history of this file.

Item names say which goal an item serves:

- **R** — the reference model: be as fast as it is, or faster, on its own
  benchmark suite ([RESULTS.md](../benchmarks/parity/RESULTS.md)).
- **S** — SQLite's surface: the functions, pragmas and grammar measured by
  `scripts/sqlite_gaps.py` ([sqlite-roadmap.md](sqlite-roadmap.md)).
- **D** — depth and hardening: the places where the engine answers correctly at
  a cost or a risk a mature engine would not accept. D-numbers are the historic
  ones, so a gap in the sequence is an item that was closed.

Rules for this file:

1. An entry moves onto the roadmap only when its **Done when** block is a set of
   tests, not a paragraph.
2. Nothing here may be claimed in `README.md`, `docs/status.md` or a commit
   message until its tests exist.
3. Effort is in engine lines, not calendar time: **S** < 500, **M** 500–1.500,
   **L** 1.500–4.000, **XL** > 4.000.

## Summary

| Item | Today | Gap | Effort |
|---|---|---|---|
| R1 | closed: rows live in one slice in id order, a scan walks it | — | — |
| R2 | a memory index files the rows of a key under one entry; keys are encoded strings | the write path's keys: one encoding per check, fixed-size keys where the column allows | M |
| R3 | closed: a prune visits the rows that hold a version or are a tombstone | — | — |
| R4 | closed: a stored row is one allocation; a full hand-over measured and not worth it | — | — |
| R6 | closed: a statement's fixed cost, a rowid read and a scan's per-row lists | — | — |
| R7 | closed: a reader shares the rows by block, the index trees and the table's arena; a commit with a reader open is 0.19 ms over 50 000 rows, gated at 1 ms by `scripts/bench.py` | — | — |
| D2 | overlap on an `rtree` table is a scan | node pages and a descent | M |
| D3 | closed: a retention per store (`PRAGMA history_retention`), applied after each commit; `AS OF` on every table of a join | — | — |
| D4 | an index of up to 16 pages is built again per commit; a larger one, or an automatic one, re-encodes the `.sqlite` mirror | insert and remove index entries in place | L |
| D5 | paged tables: no leaf merge, one version per row | the rest of the page store (with D17) | L |
| D8 | closed: every write path is walked by a fault (`src/tests/fault_walk_test.odin`), and the reopen holds exactly the commits that reported success | — | — |
| D10 | decimals are floats, timestamps have no zone | decimal scale, `TIMESTAMPTZ`, streaming blobs | M |
| D11 | closed: triggers and policies follow their transaction; RAISE; a dropped table takes its triggers and policies | — | — |
| D12 | a module is a process with a work budget | a deterministic sandbox | L |
| D14 | one process owns one log | log shipping to followers | XL |
| D15 | HTTP/1.1 and WebSocket with caps | TLS, HTTP/2, backpressure, timeouts, a load test | M |
| D16 | a hand-written Python binding | bindings generated from the catalog, more languages | M |
| D18 | a read-only open replays | a reader that trusts the pages of a quiescent writer | M |
| D23 | closed: a refused allocation fails its statement with `.Out_Of_Memory` (`SQLITE_NOMEM`); `test_allocation_failure_walk` | — | — |
| D24 | closed: `scripts/mirror_fuzz.py` passes 20 seeds of 400 statements against SQLite, a CI gate | — | — |
| D34 | the threaded suite is green on Linux and Windows; the sanitizer covers the Windows CLI, not the suite | run the suite sanitized on every platform, in CI | S |
| D36 | a query never reads a partial or expression index | match a query's predicate to the index | M |
| D37 | a connection catching up with another process's commit reads and hashes the whole file; `multiwrite01` is 1.5–1.7× SQLite | read only the pages that changed, time `multiwrite01` in CI | M |
| S8 | the `sqlite3_*` facade exports 233 of the 309 functions SQLite declares | the other 76: statements, URIs, pre-update hooks, memory, WAL and snapshots, mutexes | M |
| D39 | PostgreSQL's surface is not measured in CI; its catalog is `pg_tables` only | a probe gate, the catalog drivers and ORMs read, PostgreSQL's `GRANT` and `CREATE POLICY` | L |
| D40 | a transaction holds the store's write lock until it commits | two writers that stage at once and conflict only at commit | L |
| D35 | diagnostics: closed | — | — |

---

## R — the reference model

The reference's own suite, ported as `benchmarks/parity` and run on the same
machine, is the measure. In memory, with the baseline of
`benchmarks/parity/baseline.json`, this engine is at or under it on an empty
transaction (0.50 µs against 0.53), the index filters (2.4 against 3.25), both
256-row scans (1.4 against 1.99, 1.3 against 1.33), inserts with an index per
column (0.73–0.79×) and the u64 update (0.87×), and slower on the other writes:
inserts 1.38–1.44× with one unique index, the str update 1.24× (inserts
1.2–2.7× and updates 2.6–2.8× before the R2 work of 2026-11-25). On
disk (written, not synced, the reference's own contract) inserts were 3.0–4.8×
when last measured, on 2026-11-19.
SQLite, measured in the same run, also beats this engine on inserts and on
updates by a wide margin, so the target is not only the reference. Where the
time goes is measured in [RESULTS.md](../benchmarks/parity/RESULTS.md); the four
items below are its list, in order of payoff.

**Done when, for the whole track.** Every workload of `bin/parity.exe mem` and
`bin/parity.exe disk` is at or under the reference's figure on the same machine,
and `scripts/bench.py` gains a gate that fails on a regression of the parity
numbers, measured twice per run like the existing time metrics.

## R1 — Rows stored in id order

**Closed.** A memory table keeps its rows, tombstones included, in one slice in
id order (`Table.rows`). A lookup by id tries the slot the id would have with
no id missing, then a binary search; a scan walks the slice in place
(`table_scan`, or `table_collect` for a list); a prune compacts the slice in one
pass; a reader's copy is one pass over it with no hashing. The map cost a hash
and an 80-byte copy per row read. Measured against the build before, interleaved:
iterate 4.8–5.0 → 1.4–1.5 µs (the reference: 1.33 and 1.99), filter −33–36%,
inserts −6–16%, updates −6%. `test_scans_come_out_in_row_id_order` reads every
writer's result both ways, at the current sequence and at an older one.

The map insert of staging, which this item named the largest single cost of an
insert, is 8.8 µs of a 256-row insert's ~700 (1.3%): what an insert spends is the
unique-key check while staging (~0.9 µs a row with one UNIQUE index) and the
index entries at commit, which is R2.

## R2 — Fixed-size index keys

**Now.** A memory index keeps one entry per distinct key, holding its rows in id
order (`Index_Slot`): an equality lookup that meets 256 rows walks one node and
copies its ids, where it walked 256 nodes of the tree. The filter workloads went
from 8.3–8.8 to 2.7–2.8 µs (the reference: 3.25 and 3.28), and an insert into a
table with an index per column 13–20% down, interleaved against the build
before. A UNIQUE key without NULL belongs to one row, so it is still filed in one
descent. Keys are still encoded strings, compared byte by byte and copied into
the table arena once per distinct key. Measured for 256 rows, before that:
staging with one UNIQUE index costs 377 µs against 154 µs with none (the key is
encoded and probed for every row), and the commit of a table with one index per
column 575 µs against 306 µs with one. Two changes were measured and dropped,
neither moving an insert or a filter past the machine's noise: a key of up to
30 bytes kept inside its tree node (a descent reading one place per level, not
the node and then the key), and encoding a row's key once for the unique check
and the index entry.

**Done when.** An index over integer columns keys its tree by the integer (or a
fixed-width tuple) and an index over text keys by the text it already holds; the
filter workloads reach 4.05 µs and an insert with `btree_each_column` its
reference figure.

## R6 — The cost of a statement

**Closed.** A statement through `sql_execute` paid a fixed 11 µs for the arena
its parse reserved and released (now pooled), a full scan for `WHERE rowid = k`
(now a read of the row), and a heap list per scanned row plus a sort of rows
already in order (now one pooled arena per statement, and a sort only when it is
needed). `SELECT 1` went from 21.7 to 5.6 µs, a rowid read from 138 to 11.7, a
`count(*)` of 2 048 rows from 565 to 276 ([RESULTS.md](../benchmarks/parity/RESULTS.md#the-sql-path-2026-11-22)).
The parity gate holds four SQL workloads to their baseline, and
`test_a_rowid_equality_reads_the_row_directly` covers the rowid path, staged
writes included.

## R7 — The copy a commit makes for a reader

**Closed.** A commit that changes a table a reader holds shares with it what it
does not change: the rows by block (`Row_Blocks`), each index's tree by node
(`Index_Tree`, a B+tree copied on write along the path to a key, in
`src/engine/index_btree.odin`), the integer keys by page (`Int_Keys`) and the
table's arena, which holds the schema and the index keys and lives as long as the
last table that shares it (`Key_Store`). The copy of the table itself is a
header, built without `table_create`, which made two new arenas for it. Over
50 000 rows the commit went from 10-21 ms to 0.18-0.19 ms, and from 3.9-4.1 ms to
0.14-0.16 ms over 20 000; `scripts/bench.py --check` builds 50 000 rows three
times and fails when the median passes 1 ms. On the way, an INSERT that left an
INTEGER PRIMARY KEY out walked every row for the largest key, 1 ms of each such
commit over 50 000 rows: the key is read off the column's index now, walking
back from past the numbers (`table_largest_int_indexed`), and a commit with no
reader open over 50 000 rows is 47-116 us. Against the build before, the parity
inserts with an index per column are 0.94-0.95x, the unique ones 0.98 (text) and
1.04 (u64), the updates 1.00-1.01. `test_index_tree_answers_as_a_sorted_map`,
`test_an_index_shares_its_tree_with_a_reader` and
`test_the_next_integer_key_comes_from_the_index` cover them; the HASH and DIRECT
equality maps are still copied, being rare.

The history of the item:

**Now.** A commit that changes a table a reader holds copies it
(`table_cow_clone`), so the reader keeps a table nobody writes. Measured after
R1: 4.4–4.7 ms over 20 000 rows and 13–17 ms over 50 000 on this machine, which
ran 5.7–17 and 15–78 before this item. Of the 50 000-row copy, the index tree
was 10–16 ms and is 7.5 now: its nodes came from the heap one at a time and come
from a pool per index (`Node_Pool`: chunks of fixed-size slots and a free list,
released with the index), which also took 4–15% off the parity inserts and
updates that create index keys. Freeing the source's empty history lists cost
3.5 ms of it and costs 0.25. `test_an_index_takes_its_nodes_from_a_pool_of_its_own`
covers the reuse of freed nodes, a copy with a pool of its own, and an emptied
and dropped index.

What is left is the copy itself: 4 MB of rows and 5.6 MB of nodes at 50 000
rows, most of it first-touch page faults of new memory, and the walk.

The integer keys a UNIQUE index files beside its tree (R2) were an Odin map,
which seeds its hashes with the address of its cells: the copy filed every key
again, 10-48 ms of the commit, and took a 50 000-row commit with a reader open
to 22-60 ms. They are an open-addressed table of their own now (`Int_Keys`,
`src/engine/int_keys.odin`), where a key's slot depends on the key alone, so
the copy is one copy of the slots: the commit is 14 ms again (5.8-6.0 ms over
20 000 rows), and the parity inserts with a unique index are 5-8% faster.
`test_integer_keys_table_answers_as_a_map` runs the table against a map, and
`test_a_copied_key_map_answers_as_its_original` a copy against its original.

The rows are in blocks of 256 now (`Row_Blocks`, `src/engine/row_blocks.odin`):
the copy lists the reader's blocks with one more reference each and copies a
block only when it first writes one of its rows, with the history arrays of
those rows; the last table that lists a block frees it. The copy keeps the
history and the tombstones as they are and prunes them later, where it dropped
them and freed them in a pass over every row. A commit with a reader open is
4.1 ms over 20 000 rows (5.3-6.0 before) and 10.7-13.7 ms over 50 000
(13.5-16): what is left is the copy of the index trees, 8-10 ms of it, which a
tree that shares its nodes takes away next. A lookup by id is two loads when no
id is missing (`dense`), and the scan keeps the block it is in: the index
filters went 0.89-0.93x of the slice, and a scan as fast as it.
`test_row_blocks_answer_as_one_sorted_slice` puts rows in any order against a
sorted list, then changes a shared copy; `test_a_reader_keeps_its_rows_while_the_writer_changes_shared_blocks`
updates, deletes, puts rows between others and prunes while a reader reads.

**Done when.** A reader and the writer share what the commit did not change
(persistent index nodes and a row slice copied by chunk, or versions read in
place under a reader count), so a commit costs the rows it writes whatever the
table's size.

## R3 — Prune only what a commit touched

**Closed.** A table keeps the ids of its rows that hold a version or are a
tombstone (`Table.history`), once each, and a prune visits those; the slice is
compacted from the first tombstone that leaves, so a commit that deleted nothing
moves no row. A prune after a one-row commit beside a 100 000-row table went from
997 µs to 0.1, and the parity inserts and updates, which prune after each
commit, 2–7% down. `test_a_prune_visits_only_the_rows_a_commit_touched` counts
the rows each prune visits: a commit to one table visits none of another, and
what an older read can still ask for stays until a later prune.

## R4 — Hand the staged row to the table

**Closed, by a smaller change.** The copy a commit makes of each staged row was
measured at a tenth of a 256-row insert (54–58 µs of ~555), not the 4% this item
said: one allocation for the value array and one more per text, blob or list. A
stored row is now one allocation, the array followed by those bytes and items
(`row_values_pack`, freed whole by `row_values_free`), and only the table makes
and frees one. The copy went from 57 to 42 µs for the text rows and stayed at
~40 for the integer ones, which had one allocation already; the parity inserts
and updates of the text tables 4–7% down, interleaved, the integer ones within
the machine's noise. `test_a_stored_row_keeps_every_kind_of_value` writes every
kind (texts, an empty one, blobs, arrays, products, an empty array) and reads it
back through an update, an older pinned read, a delete and a prune.

Handing the staged row over was not done: the transaction arena is freed with
the transaction, so a row handed over would have to be allocated on the heap
while staging, which is the one allocation this copy now costs, and the
ownership would have to survive savepoints, `ALTER`, a staged row updated again
and rollback. What is left is that one allocation per row, ~150 ns here; a
table that allocated its rows in blocks would need a per-row free inside a
block (an update frees one row's old version), so it waits for a reason beyond
this suite.

Working through the delete path found a regression from R6: `tx_get` returned
a table's row as stored, tombstone or not, so a deleted row answered
`WHERE rowid = k` until the next prune (which the C ABI never runs), a read
pinned to an older sequence saw the current values, and a deleted row's id
could not be used again (SQLite allows it). It now answers the row the
transaction's sequence sees, and an insert that names a deleted row's id makes
the tombstone a version of the new row.

---

## D — depth and hardening

## D2 — Spatial: an actual tree

**Now.** `CREATE VIRTUAL TABLE … USING rtree(id, minx, maxx, miny, maxy)` stores
the boxes as the table's own columns; overlap is the caller's range predicate,
O(rows) for a query without a bound.

**Done when.** Boxes live in node pages with a fanout, a query descends from the
root, and a benchmark shows the descent doing materially less work than the scan
on 100k boxes.

**Not claimed today.** "Spatial index"; it is a spatial *table*.

## D3 — Version retention

**Now.** `SELECT … FROM t AS OF <seq>` reads the versions a table keeps
(`test_as_of`). Versions stay until `store_prune_versions(store, before_seq)` is
called with the oldest sequence in use; there is no automatic policy, history is
not counted against a memory budget, and `AS OF` on a join is refused. The CLI
prunes after each statement; the C ABI and the `sqlite3_*` facade do not, so an
embedded process that updates rows keeps every value it replaced. Since R3 a
prune costs the rows that changed, so pruning after each commit while no read is
pinned is cheap.

**Why the C ABI does not prune after each commit yet.** History has three
readers, and an automatic prune is only safe against two of them:

- *A read transaction* (`tx_begin_read`) shares the tables it reads and scans
  them without the store's lock. A prune skips a table anyone shares
  (`store_prune_table`), so its rows never move under a scan; before that skip a
  prune compacted a table a reader could be walking. Safe for the rows, but not
  for their values until 2026-11-25: a commit to a shared table writes a copy
  that borrows the reader's values, an update moves them into the copy's
  history, and the prune after the commit freed them while the reader still
  read them (a heap that overwrote freed memory had the reader read `"||"` for
  three texts). A table copied for a reader keeps the sequence of that commit
  (`shared_before`), and a prune hands the values stored before it to the
  shared store, freed when the last reader is gone
  (`test_a_prune_leaves_a_reader_its_values`, under an allocator that poisons
  what it frees).
- *A pinned read* (`tx_begin_read_at`) reads the live tables at an older
  sequence. A prune does nothing while one is announced or reading: it reads the
  pins under the lock and only tries that lock, which a live pin holds shared.
  Before, it read the pins before taking the lock, so a pin announced in between
  lost the history it pinned. Safe, for a pin announced before the prune.
- *`AS OF <seq>`* reads the live tables at any sequence the statement names, and
  nothing announces it beforehand. A prune after every commit leaves no history
  for it to read, so `AS OF` would miss every row changed since the sequence
  it names, through the C ABI and the `sqlite3_*` facade, where today it reads
  every past commit
  (as long as no reader forced a copy of the table, which drops its history).

So an automatic prune cannot be made safe by itself: it needs a retention
policy the embedder chooses — keep nothing (the CLI's choice today), keep the
last N commits or T seconds, or keep everything (today's default for the ABI).
That policy, with a test that a long-lived database with updates stays bounded
under it and that `AS OF` inside the kept window still answers, is this item.

**Closed.** A store has a retention (`src/engine/retention.odin`), applied after
each commit once its lock is free: `everything` keeps every version (a store the
engine's own API opens), `readers` keeps what an open or pinned read needs (the
C ABI and the `sqlite3_*` facade, where nothing names an older commit),
`commits=N` keeps what an `AS OF` up to N commits back reads, and `seconds=N` what
an `AS OF` at a commit of the last N seconds reads. `PRAGMA history_retention`
reads and sets it. A read transaction keeps the tables it shares and a pinned
read holds the lock the prune only tries, so neither loses a version.
`test_the_facade_keeps_no_history_nobody_reads` runs 100 000 updates through the
facade and finds no superseded value kept (it kept all 100 000);
`test_retention_keeps_its_window`, `test_retention_waits_for_an_open_read`.

`AS OF` names a commit for each table of a join; a historical table is scanned,
since its index holds the live keys (`test_as_of_on_a_join`).

Found on the way: a commit made while a reader held the table writes into a copy,
and the copy did not carry the commit's sequence, so the value that commit
replaced was stamped as replaced at 0: an `AS OF` before the row's next update
read the old value, and no prune dropped it
(`test_as_of_reads_a_table_copied_for_a_reader`).

## D4 — Secondary indexes in the `.sqlite` mirror

**Now.** A commit to a table with indexes builds each index again from the
table's rows into pages of its own, the old ones going to the free list, when
the index is up to 16 pages (`MIRROR_INDEX_REBUILD_PAGES`); a larger one, an
automatic `sqlite_autoindex_*` and one the engine keeps as the file had it
(D24) still re-encode the file. `scripts/mirror_cost.py` writes a 200-row
table with two indexes (one over two columns, one DESC) beside the 10 000-row
one and requires no re-encoded commit; `test_a_table_with_an_index_is_patched`
checks every index with `sqlite_mirror_validate`. The suspected bug of a
UNIQUE column's automatic index left stale was checked and is not one: such a
table re-encodes the file, which writes the index.

**Done when.** An index entry is inserted and removed in its b-tree in place
(leaf and interior pages, splits, keys with overflow chains), so a large index
costs a commit a few pages; automatic indexes are patched too; and
`mirror_cost.py` measures a commit to a table whose index is past the rebuild
bound.

## D5 — The rest of the page store (with D17)

**Now.** Paged tables (`--paged`) keep rows and index keys in 4 KiB pages with a
pool, chained leaves and a memory gate (`scripts/page_rss.py`).

**Left.** Merge an index leaf that loses its last entry; keep more than one
version per row so `AS OF` and `ALTER` work on a paged table; and let a read of a
paged store run without holding the shared lock for its whole life.

**Done when.** Each of the three has a test, and `page_rss.py` still passes.

## D8 — Fault injection beyond the log

**Closed.** `Fault_Vfs` fails any operation at any call (open, read, write,
seek, truncate, sync, remove and now rename), and `src/tests/fault_walk_test.odin`
breaks each one in turn and reopens the database to find exactly the commits
that reported success:

- `test_snapshot_and_compaction_faults`: a snapshot and a compaction, which now
  run through the virtual file system as the log does.
- `test_log_rotation_faults`: a workload that rotates its log twice.
- `test_page_flush_kill`: a paged database killed at any page write of a
  commit's evictions or of the flush at close (`page_fault_arm`, on the disk,
  where an open trusts the pages).
- `test_sqlite_mirror_faults`: a database opened from a `.sqlite` file, at any
  operation of its whole-file rewrites, its journal, its page patches and the
  journal's removal; the file validates after each reopen and takes a commit.

What the walks found, each fixed:

- A commit whose log write or sync failed left its record in the log; the next
  commit took the same sequence and replay kept the failed one. A failed append
  is now cut back (`log_append_undo`), and a log that cannot be cut back is closed
  and refuses the commits after it.
- A failed rotation left the log closed, and the next commit encoded no payload
  for a closed log: it wrote an empty record and lost its rows.
- Compaction deleted every segment before writing the new log; a failure there
  left a closed log whose commits reported success and were never written. The
  new log is now whole before any segment goes.
- A page that could not be loaded read as a shorter table, so a `DELETE` deleted
  nothing and reported success. The statement now fails with the page's error.
- A commit that stopped halfway through its apply left half of its rows in
  memory, and the statements after it built on them. The store now refuses every
  statement until it is reopened, and drops its catalog so that open rebuilds the
  pages from the log rather than trust pages the commit's evictions wrote.
- A page flush wrote the header that promises its pages without syncing them
  first.
- A database opened from a `.sqlite` file reported a commit the file did not take
  as a success, though the file is its only copy; it now fails, the journal goes
  back into the file while the commit still holds it, and the connection reads
  the file again. A rewrite of the whole file wrote it in place with no journal;
  it is now journaled like a page commit. A journal record whose checksum fails
  ends the journal, as in SQLite, and an owner that found a hot journal rolls it
  back into the file instead of deleting it after reading it.

## D10 — Precision and time

**Now.** `Int128` is two `u64`s; decimals are floats; timestamps are
microseconds since the epoch without a zone; blobs are copied whole.

**Done when.** Decimal arithmetic with a declared scale, `TIMESTAMPTZ`
normalising to UTC, streaming blob reads, and conformance cases for rounding.

## D11 — Triggers and policies inside a transaction

**Now.** Index DDL is staged, applied after the rows and rolled back with them
(`test_ddl_in_transaction`).

Triggers and policies are rows of internal tables read through the
transaction, so one created, dropped or rolled back in a transaction acts on
that transaction's rows as SQLite's does (`test_triggers_follow_their_transaction`,
`test_policies_follow_their_transaction`). Checking that against SQLite found:
`RAISE` was parsed as a call to a function nobody has, so no trigger could
refuse or skip a row (`test_a_trigger_raises_as_sqlite`,
`test_a_raised_rollback_ends_the_transaction`); a trigger body was parsed only
when it fired; and `DROP TABLE` left the table's triggers and policies, which
held the next table of that name (`test_a_dropped_table_takes_its_triggers`).
`scripts/differential.py` runs RAISE and the dropped table's trigger against
SQLite.

**Closed.**

## D12 — The module sandbox

**Now.** Metering (one unit per row, a budget that rolls a call back) and latency
(one pooled socket per module) are done, and a call carries the caller's clock.
A module is still a process: the host bounds the work per call, not the module's
memory, time or randomness.

**Done when.** Modules run in a deterministic sandbox with enforced memory and
time limits, so replaying a call reproduces it. The reference runs its modules
this way, which makes this a parity item as much as a hardening one.

## D14 — Replication

**Now.** One process owns one log; there is no replication code.

**Done when.** `GET /log?since=<seq>` streams records, a follower applies them
through the replay path and serves reads, and tests cover a lagging follower and
a dead leader. Failover stays unclaimed. [versioning-plan.md](versioning-plan.md)
builds its networked phases on this.

**Reusing the engine's networking.** The engine this database accompanies
(checked out as `mirai-engine`) has a networking library in Odin, so the
follower needs no new protocol: it can import `net` and carry commit records as
its messages.

| Piece there | What it gives a follower |
|---|---|
| `channel` | datagrams delivered whole and in order, or not at all; one reliable channel and one unreliable |
| `replication` / `protocol` | the message set for peers and the rules for what is sent once and in what order |
| `baseline` + `collection` | "start from this state, then apply changes": a snapshot plus the records after `seq` |
| `clock` | ticks numbered alike on both ends, which makes applying a record deterministic |
| `peer` / `host` / `connection` | connection lifecycle and queues; a full reliable queue refuses instead of dropping |
| `conditioner` | simulated latency, jitter and loss: the rig for a lagging or flapping follower |

This database brings the segmented log with CRC32C per record, the replay path
and the snapshot with an offset index; D14 is mostly wiring.

## D15 — Network hardening

**Now.** HTTP/1.1 and WebSocket with request, header and frame caps; the wire
protocol runs over both, and the PostgreSQL protocol on the same port.

**Done when.** TLS (or a documented handoff to a terminator), HTTP/2, per-route
timeouts, backpressure on a slow reader, and a load test in `scripts/`. Until
TLS exists a token travels in clear, which the auth review must state.

## D16 — Clients generated from the catalog

**Now.** `sdk/python/miraidb.py` wraps the C ABI by hand (`scripts/sdk_smoke.py`
is its gate), and `miraidb codegen` emits Odin structs.

**Done when.** The Python binding is generated from a schema and meets the
hand-written one's smoke test; the reference generates clients for several
languages, so a second language (TypeScript or C#) follows.

**Deferred.** Bindings for other languages (C#, Rust, TypeScript, a generated
Python) are months away and are not built now. What is kept is the base that
makes each of them a thin layer, and every change keeps it so:

- one C ABI, `include/miraidb.h`, every export declared and the header compiling
  on its own (`scripts/abi_header.py` gates both), with errors as codes and
  messages the caller owns, so any FFI can wrap it without the engine's types;
- the `sqlite3_*` face, `include/sqlite3_miraidb.h`, so a language whose SQLite
  driver loads a library by name (CPython's `sqlite3`, Microsoft.Data.Sqlite,
  rusqlite) can run on the engine with no binding of its own;
- `sdk/python/miraidb.py`, the hand-written wrapper a generated one has to match
  (`scripts/sdk_smoke.py`), and `miraidb codegen`, which already walks the
  catalog to emit Odin structs: a generator for another language is a second
  emitter over the same walk.

## D18 — A reader that trusts the pages

**Now.** A writer and read-only readers share a directory (two lock bytes), and
a paged database opens without replay when its sequences agree.

**Left.** A read-only open beside a live writer still replays, because a reader
cannot know whether the writer has pages in flight; and the broker serves with
one accepting thread, so a slow client is bounded by its outbox budget rather
than by concurrency.

## D23 — Resource limits: allocation failure

**Done.** Expression depth (100 levels, parser and evaluator), the row quota
while a projection or a join produces rows, the work budget, `LIMIT` pushed into
the scan, and both caps reachable from the CLI (`--row-quota=N`, `--budget=N`).

**Closed.** Every arena the engine allocates from is guarded
(`arena_allocator_guarded`, `src/engine/oom.odin`), and so is the heap the C
entry points, the CLI and the server run under (`oom_context`,
`oom_heap_allocator`). An allocation the system refuses releases a 4 MiB
ballast held for it and is tried again, so the step in flight finishes instead
of reading a nil. The statement then stops at its next checkpoint (each row of
an insert, update or delete, and the end of every statement, before its
commit) with `.Out_Of_Memory`, which the facade answers as `SQLITE_NOMEM`, and
is taken back; the next statement runs only once the ballast is held again, and
a rollback runs regardless. `oom_inject` fails a thread's nth guarded
allocation and every later one: `test_allocation_failure_walk` runs a script of
DDL, a trigger, a transaction, writes and a join once per allocation it makes,
and each run answers or fails cleanly, leaks nothing, and leaves the rows of
the statements that worked; `test_a_refused_allocation_is_sqlite_nomem` does the
same through `sqlite3_exec`.

**Outside it.** The temporary allocator, and the few registries that take the
heap directly (`runtime.heap_allocator()`: locks, handles, virtual-table
modules), are not guarded; a refusal there, or one larger than the ballast after
it is spent, is still the caller's nil.

## D24 — The mirror's last gaps

**Now.** DDL keeps the file valid, an imported file's indexes are recreated, and
`scripts/sqlite_abi_smoke.py` checks integrity after `DROP`, `ALTER` and index
DDL. An index the engine cannot build from the file (a collation or a function
only the program that wrote it had) is kept as the file has it: a rewrite writes
its entries back unchanged, `sqlite_master` lists it, `import-sqlite` reports
it, and its table refuses writes with the reason until the program registers
what it needs, when the index is built in the writing transaction
(`test_an_index_the_engine_cannot_build_is_kept`). It used to be built without
its WHERE (a partial UNIQUE index made whole refused rows SQLite accepts) or
left out, and the next rewrite dropped it from the user's file. `CREATE INDEX`
refuses a collation nobody registered, which it used to write in BINARY order
(`test_an_index_needs_what_it_can_evaluate`), and an index over a program's
function calls it, in the statement and in the commit: it answered NULL for
every row, so a partial UNIQUE index enforced nothing
(`test_an_index_calls_a_program_s_function`).

`scripts/mirror_fuzz.py` runs a seeded stream of DDL and DML through the facade
and through SQLite and, after each chunk, checks the facade's file with SQLite's
`integrity_check` and compares every table and the catalog. Its first seeds
found, each fixed with a test: a negative rowid written in nine bytes lost its
top seven bits (`test_a_negative_rowid_reaches_the_file`); an INTEGER PRIMARY
KEY kept a real or a text instead of failing with "datatype mismatch"
(`test_an_integer_primary_key_takes_only_integers`); an omitted key after a
negative one was 1, not one past it (`test_an_omitted_key_follows_a_negative_one`);
a PRIMARY KEY of a rowid table refused NULL, which SQLite stores
(`test_a_primary_key_takes_null_as_sqlite_s_does`); and two empty texts compared
unequal when one had a nil pointer, so an index put them out of rowid order
(`test_two_empty_texts_are_equal`). The next seeds found: `ADD COLUMN` wrote the
column after the table constraints, text SQLite cannot parse
(`test_an_added_column_goes_before_the_table_constraints`); ALTER brought a
deleted row back and left the rows its transaction had staged in the old shape,
without the DEFAULT, where an UPDATE of one took the process down
(`test_alter_keeps_deleted_rows_deleted_and_reshapes_staged_ones`); and an
integer and a real had keys of their own kinds, so a range through an index
lost rows and `c = 5.0` missed 5 (`test_numbers_share_one_key_space`; the index
page format is now version 2). Then: `INSERT OR REPLACE` and UPSERT looked for
the row they collide with before the column's affinity
(`test_a_replace_looks_up_the_value_as_stored`); ALTER of a table created in the
same transaction was refused
(`test_alter_runs_in_the_transaction_that_created_the_table`); a UNIQUE index
created in a transaction held nothing to the rest of it, and two equal keys
committed (`test_a_unique_index_holds_the_rest_of_its_transaction`); an integer
and a real compared as doubles, so 2^53 + 1 equalled 2^53 and an infinity every
number (`test_an_integer_and_a_real_compare_exactly`); a table dropped after an
index or an ALTER in its transaction failed the commit
(`test_a_dropped_table_takes_its_staged_indexes`); an index over a column the
table does not have was accepted (`test_an_index_expression_needs_its_columns`);
and a partial or expression index of a WITHOUT ROWID table repeated the key
columns it holds in each entry, which SQLite found missing every row
(`test_a_without_rowid_index_holds_each_key_column_once`). Last: a UNIQUE index
dropped in a transaction still refused the rest of it
(`test_a_dropped_unique_index_holds_nothing`); an error in a multi-row
`INSERT OR IGNORE` or `OR REPLACE` took back the rows before it, where SQLite
keeps them inside an explicit transaction when the statement has nothing that
makes it open a statement journal (no function call, trigger or foreign key;
`test_an_insert_without_a_statement_journal_keeps_its_rows`); and a
`sqlite_master` past page 1 kept on every page of its tree the 100 bytes only
the root needs, which integrity_check found in no cell and no freeblock
(`test_a_schema_past_page_one_accounts_for_every_byte`;
`sqlite_mirror_validate` now accounts for every byte of a page, as
integrity_check does).

**Closed.** Twenty seeds of 400 statements pass, and `scripts/ci.py` runs them
as the `mirror fuzz` gate. Not followed on purpose, and kept out of the stream:
SQLite's `UPDATE OR IGNORE` of a rowid to a real drops the row without an
error. A schema change still re-encodes the whole file, which is D4.

## D34 — The Linux suite and the heap sanitizer

**Now.** `odin test src/tests` is green on Linux under the default two-thread
runner (312 tests, about 14 s on x86_64) as on Windows. The crash was not the
threads: the in-process lock registry, which only exists on POSIX, was made
with the first test's tracking allocator, and the next test to insert after
that allocator was torn down corrupted the heap. The registry and the
live-handle set now grow on the process heap, the registry owns its keys and
holds its mutex across the whole acquire, and a reader of the same process
stops a log rewrite as a second process's reader does. Two test-side defects
showed up behind it: a reducer result written as a slice literal (a dead frame
by the time the host read it) and a listener thread joined while blocked in
`accept`, which a close does not wake on Linux. Every script finds its binary
through `scripts/binpath.py`, so none hardcodes `.exe`.

On Windows the heap half of the sanitizer works: Odin's allocator calls
`HeapAlloc`, which AddressSanitizer intercepts with
`ASAN_OPTIONS=windows_hook_rtl_allocators=true`. With it, the CLI runs under the
`heap sanitizer` gate (`scripts/asan_smoke.py`) and the suite runs clean except
`test_expression_depth_is_bounded`, whose 100 levels overflow the larger frames
a sanitized build uses.

**Left.** The suite under `-sanitize:address` on Linux and macOS: a musl
toolchain ships no sanitizer runtime, so it needs a glibc or macOS host, and the
project has no CI job yet to run it there. The Windows suite under the
sanitizer as a gate (it is the CLI only today).

**Done when.** A CI job runs the threaded suite on Linux and macOS with
`-sanitize:address`, and the Windows suite runs under the sanitizer as a gate.

## D36 — The planner and partial or expression indexes

**Now.** A partial or expression index is maintained and enforced, but the
planner skips it: `index_is_plain` keeps it out of every probe, range and
ordered walk, so a query answers from the rows and pays a scan where SQLite would
read the index.

**Done when.** A predicate that implies a partial index's WHERE (the same term,
or a stronger bound) may read it, and an expression a query compares is matched
to an index over the same expression text; `scripts/plan_check.py` gains both
plans and the differential corpus keeps passing with the indexes present.

## D37 — Catching up with a shared file

**Now.** `mptest`'s `multiwrite01` (five processes, one file) takes 3.8–4.5 s
on Windows against SQLite's 2.4–2.8 (1.5–1.7×; it was 4.6–5.3 s, 1.8–2.0×).
A trace of every lock each process took (2026-11-26) explained the stalls:

- *Waiting, not working.* Reading, parsing and hashing the file came to
  ~60 ms a process; waiting for the write lock and for SHARED to ~1.8 s, most
  of it mptest's busy handler sleeping 10 ms a try. An mptest built to count
  them called it 770–980 times a run through the facade, 250–290 through
  SQLite. Parsing the file once less, or reusing its schema, would save ~1%,
  and was left.
- *Every coordination step re-encoded the file.* mptest's own tables are
  written for each task: `task` has two indexes and `counters` no INTEGER
  PRIMARY KEY, and the mirror patched neither, so 26 commits a process wrote
  the whole file and the other processes read it all again. Both are patched
  now: an index of up to 16 pages is built again from the table's rows, and a
  table without an INTEGER PRIMARY KEY keeps the rowids the file gave its
  rows (the import, the catch-up and the writer used to number them again
  from 1). What is left re-encoded is the schema changes (6 a process).
- *The locks were held longer than SQLite holds them.* A writer took RESERVED
  before catching up, a reader kept SHARED through the whole catch-up, a
  commit took EXCLUSIVE before working out its pages, and a commit that
  changed nothing (mptest polls with BEGIN IMMEDIATE … COMMIT) wrote the file
  under EXCLUSIVE all the same. Each now does as SQLite's pager does: catch up
  under SHARED, let SHARED go once the file is read, take EXCLUSIVE only to
  write, and leave the file alone when nothing changed.

A lock is still held ~11 ms on average, against SQLite's ~3. The difference
left is how a connection catches up: SQLite compares 16 bytes of page 1 and
drops its page cache, then reads the pages a statement needs; this engine
reads the whole file and hashes every tree to find the tables that changed.

**Done when.** A catch-up reads the pages that changed rather than the file
(the journal or the change counter names them, or each tree's pages are
compared), and `scripts/sqlite_tools.py` times `multiwrite01` against SQLite
over five interleaved runs and fails past 1.25× SQLite's median.

## S8 — The rest of SQLite's C API

**Now.** `include/sqlite3_miraidb.h` declares 233 functions, each answered as
SQLite answers it (`scripts/sqlite_abi_reference.py`, zero differences).
SQLite's `sqlite.h.in` names 315; six of those are placeholders of its
documentation (`sqlite3_bind_`, `sqlite3_result_xxxxx`, …), so 76 are missing:
`bind_blob64`, `next_stmt`, `normalized_sql`, `get_table`, the `uri_*` and
`filename_*` family, the pre-update hook, `stmt_scanstatus`, the memory counters
and heap limits, the WAL checkpoint calls and snapshots, the mutex calls, and
the setup calls a default build of SQLite answers trivially.

**Done when.** The facade exports every function of `sqlite.h.in` but the
placeholders, the count is measured against that header instead of a written
number, and `scripts/sqlite_abi_reference.py` covers each new group with zero
differences; the WAL and snapshot calls answer as SQLite does on a database in
rollback-journal mode, and the hard heap limit waits for D23.

## D39 — PostgreSQL's surface

**Now.** The PostgreSQL front runs the wire protocol, SCRAM, `COPY`, cursors,
`LISTEN`/`NOTIFY`, arrays, `MERGE`, `LATERAL` and `GROUPING SETS`, each with its
test, but nothing measures how much of PostgreSQL's dialect runs: the probes
that did (87 statements, 35 running when last counted) live outside the
repository. The catalog has `pg_tables` only, so a driver's or an ORM's
reflection fails, and grants and policies have the engine's own spelling.

**Done when.** `scripts/pg_gaps.py --check` runs the probes in CI against a
counted figure written in the docs, as `scripts/sqlite_gaps.py` does; `pg_type`,
`pg_class`, `pg_attribute`, `pg_namespace`, `pg_index` and the
`information_schema` tables answer what psycopg and SQLAlchemy's reflection
read, with a gate that reflects a schema through them; `GRANT`, `REVOKE` and
`CREATE POLICY` parse as PostgreSQL writes them onto the grants and policies the
engine has; a cancel request stops the running statement.

## D40 — Two writers

**Now.** A write transaction takes the store's write lock when it starts and
holds it until it commits, so a second writer waits for the first even when the
two touch different rows: over the PostgreSQL front a client that leaves a
transaction open blocks every other writer.

**Done when.** A transaction stages without the lock and validates what it read
and wrote at commit: the first to commit wins and the other fails with
`40001 serialization_failure` over the PostgreSQL front (and `SQLITE_BUSY` on the
SQLite face, which keeps one writer); a test runs two connections that write
different rows at once without waiting and one conflict that fails, and
`scripts/soak.py` stays green.

## D35 — Diagnostics

**Now.** `tools/leakcheck` reports zero live allocations for every read shape and
a flat count for writes; `scripts/leaks.py` is a CI gate.

**Left, in order.**

1. ~~The leak lines the suite printed.~~ Closed: the suite runs with no leak and
   no bad free reported. Tracing each one to its allocation found engine leaks
   on error and teardown paths, and four readers that answered text from a
   result they had already freed (module variables, metadata, the token key,
   client names); a test-side leak is now a regression like any other.
2. ~~A map node freed through the wrong allocator.~~ Closed with D34's crash:
   it was the process-wide maps (the lock registry and the live-handle set)
   growing through whatever allocator their first caller had; they grow on the
   process heap now.
3. ~~Error ownership.~~ Closed: every `Error` an entry point returns is the
   caller's. The embedding layer used to hand back the message it also kept as
   the connection's last error, so a caller that freed it freed it twice and one
   that dropped a `bind` or `open` error leaked it; it now keeps a copy of its
   own. The C ABI and the `sqlite3_*` facade free every error they receive
   (`error_drop` for a yes or no), a store that notes a failure frees the one it
   replaces and its last on close (`store_note_error`), and `tools/leakcheck`
   fails on a leak or a double free of the error path.
4. ~~The log index opened per commit.~~ Closed: the log keeps the sidecar open
   from its first commit and closes it with the log, on rotation and before a
   rewind cuts it (`test_log_index_kept_open_matches_the_log` fails if a rewind
   leaves a hole of zeros).
