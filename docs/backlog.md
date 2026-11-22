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
| R4 | a committed row is copied from the transaction arena to the table | hand the staged row over | M |
| R6 | closed: a statement's fixed cost, a rowid read and a scan's per-row lists | — | — |
| D2 | overlap on an `rtree` table is a scan | node pages and a descent | M |
| D3 | versions stay until `store_prune_versions` is called | automatic retention, `AS OF` on a join | M |
| D4 | a table with a secondary index re-encodes the `.sqlite` mirror | patch the index b-trees | L |
| D5 | paged tables: no leaf merge, one version per row | the rest of the page store (with D17) | L |
| D8 | the fault walk covers the log | snapshot, rotation and mirror | S |
| D10 | decimals are floats, timestamps have no zone | decimal scale, `TIMESTAMPTZ`, streaming blobs | M |
| D11 | index DDL is atomic | triggers and policies ordered against the rows of their transaction | S |
| D12 | a module is a process with a work budget | a deterministic sandbox | L |
| D14 | one process owns one log | log shipping to followers | XL |
| D15 | HTTP/1.1 and WebSocket with caps | TLS, HTTP/2, backpressure, timeouts, a load test | M |
| D16 | a hand-written Python binding | bindings generated from the catalog, more languages | M |
| D18 | a read-only open replays | a reader that trusts the pages of a quiescent writer | M |
| D23 | depth, row quota and budget are bounded | an allocation failure is a crash, not an error | M |
| D24 | an index the engine cannot express is dropped on import | a counted skip, and a mirror fuzz pass | S |
| D34 | the threaded suite is green on Linux and Windows; the sanitizer covers the Windows CLI, not the suite | run the suite sanitized on every platform, in CI | S |
| D36 | a query never reads a partial or expression index | match a query's predicate to the index | M |
| D35 | diagnostics: closed | — | — |

---

## R — the reference model

The reference's own suite, ported as `benchmarks/parity` and run on the same
machine, is the measure. In memory, with the baseline of
`benchmarks/parity/baseline.json`, this engine is at or under it on an empty
transaction (0.50 µs against 0.53), the index filters (2.7 against 3.25) and a
256-row scan of the u64 table (1.4 against 1.99), at it on the other scan (1.4
against 1.33), and slower on the writes: inserts 1.3–2.9×, updates 2.6–3.0×. On
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

**Now.** A committed row is copied from the transaction arena to the table's heap
(about 4% of an insert, measured).

**Done when.** The table takes ownership of the staged values. The ownership has
to survive savepoints, `ALTER` and rollback, which is why this is last.

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

**Done when.** Retention follows the oldest open reader automatically, a test
proves a long-lived database with updates stays bounded, and `AS OF` works on a
join.

## D4 — Secondary indexes in the `.sqlite` mirror

**Now.** The mirror patches the leaf of every changed row (three pages per
commit at 250k rows), but only table b-trees are patched: a table with a
secondary index re-encodes the whole file on every commit.

**Done when.** Index b-trees are patched too (a moved key can jump leaves), and
`scripts/mirror_cost.py` gains a table with a secondary index whose per-commit
bytes stay flat as the table grows.

## D5 — The rest of the page store (with D17)

**Now.** Paged tables (`--paged`) keep rows and index keys in 4 KiB pages with a
pool, chained leaves and a memory gate (`scripts/page_rss.py`).

**Left.** Merge an index leaf that loses its last entry; keep more than one
version per row so `AS OF` and `ALTER` work on a paged table; and let a read of a
paged store run without holding the shared lock for its whole life.

**Done when.** Each of the three has a test, and `page_rss.py` still passes.

## D8 — Fault injection beyond the log

**Now.** `Fault_Vfs` fails any operation at any call, and `test_fault_injection`
arms every write of a workload and proves the reopen sees exactly the commits
that reported success.

**Done when.** The same walk covers snapshot writes, log rotation and the
`.sqlite` mirror, and a kill during a dirty page flush.

## D10 — Precision and time

**Now.** `Int128` is two `u64`s; decimals are floats; timestamps are
microseconds since the epoch without a zone; blobs are copied whole.

**Done when.** Decimal arithmetic with a declared scale, `TIMESTAMPTZ`
normalising to UTC, streaming blob reads, and conformance cases for rounding.

## D11 — Triggers and policies inside a transaction

**Now.** Index DDL is staged, applied after the rows and rolled back with them
(`test_ddl_in_transaction`).

**Left.** A trigger or policy created in the same transaction as the rows it
affects is not ordered against those rows.

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

**Left.** An allocation that fails is still a crash rather than
`.Out_Of_Memory`. There is no reproduction yet; the first step is an allocator
that fails the nth allocation, the way `Fault_Vfs` fails the nth write.

## D24 — The mirror's last gaps

**Now.** DDL keeps the file valid, an imported file's indexes are recreated, and
`scripts/sqlite_abi_smoke.py` checks integrity after `DROP`, `ALTER` and index
DDL.

**Left.** A schema change re-encodes the whole file; an index the engine cannot
express (partial or over an expression, until S1) is left out of an import
silently, which should be a counted and reported skip; and the mirror has no fuzz
pass of its own (random DDL and DML, integrity after each chunk).

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
