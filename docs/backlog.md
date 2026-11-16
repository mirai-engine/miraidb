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
| R1 | rows live in a map keyed by id; a scan looks every id up | rows stored in id order | L |
| R2 | every index entry is an encoded string | fixed-size keys where the column allows | M |
| R3 | pruning walks every row of every table after each statement | prune what the commit touched | S |
| R4 | a committed row is copied from the transaction arena to the table | hand the staged row over | M |
| S1 | `ON CONFLICT` on a constraint is refused; the rest landed | the constraint resolutions | S |
| S2 | `UPDATE OR <resolution>` is refused; the rest landed | the UPDATE resolutions | S |
| S3 | `RIGHT`, `FULL` and `NATURAL` joins are refused | the three joins | M |
| S4 | `FILTER`, `WINDOW`, aggregate `ORDER BY`, ordered-set aggregates missing | the aggregate surface | M |
| S5 | 48 of 121 built-in functions missing | math, JSON/JSONB, text, introspection | M |
| S6 | eight statements and 9 pragmas missing | `EXPLAIN QUERY PLAN`, `REINDEX`, `INSTEAD OF`, `generate_series`, … | M |
| S7 | `ANY` columns exist; an untyped column, affinity and cross-class comparison do not; `WITHOUT ROWID` cannot be written | SQLite's typing rules | L |
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
| D34 | the Linux suite crashes under the threaded runner; the sanitizer covers the Windows CLI, not the suite | find the corruption, run the suite sanitized on every platform | M |
| D36 | a query never reads a partial or expression index | match a query's predicate to the index | M |
| D35 | diagnostics: test-side leak lines, map nodes freed through the wrong allocator, error ownership | one sweep | M |

---

## R — the reference model

The reference's own suite, ported as `benchmarks/parity` and run on the same
machine, is the measure. In memory this engine is faster on an empty
transaction (0.50 µs against 0.62) and slower on everything else: inserts
1.6–2.9×, updates 2.3×, a 256-row scan about 3×, an index filter 3–4×. On disk
(written, not synced, the reference's own contract) inserts are 3.0–4.8×.
SQLite, measured in the same run, also beats this engine on inserts and on
updates by a wide margin, so the target is not only the reference. Where the
time goes is measured in [RESULTS.md](../benchmarks/parity/RESULTS.md); the four
items below are its list, in order of payoff.

**Done when, for the whole track.** Every workload of `bin/parity.exe mem` and
`bin/parity.exe disk` is at or under the reference's figure on the same machine,
and `scripts/bench.py` gains a gate that fails on a regression of the parity
numbers, measured twice per run like the existing time metrics.

## R1 — Rows stored in id order

**Now.** A table keeps its rows in `map[Row_Id]Row` plus a sorted id list
(`Table.order`), so a scan walks the list and looks each id up in the map, and
staging a row pays a map insert, the largest single cost of an insert.

**Done when.** Rows live contiguously in id order (an array of rows with a
tombstone, or pages of rows), a scan is a walk over memory, the map insert is
gone from staging, and `test_scans_come_out_in_row_id_order` plus the
copy-on-write tests still pass. Measured: iterate within the reference's 1.65 µs,
and the insert workloads move by the map's share.

## R2 — Fixed-size index keys

**Now.** Every index entry is a key encoded into a string (`index_entry_key`),
compared byte by byte, and copied into the table arena on apply: the largest
share of applying a row, and the cost of an index filter.

**Done when.** An index over integer columns keys its tree by the integer (or a
fixed-width tuple) and an index over text keys by the text it already holds; the
filter workloads reach 4.05 µs and an insert with `btree_each_column` its
reference figure.

## R3 — Prune only what a commit touched

**Now.** Pruning row history walks every row of every table, and the CLI and the
C ABI prune after each statement.

**Done when.** A commit records the rows it versioned and the prune visits those
only; a test proves a commit to one table never visits another.

## R4 — Hand the staged row to the table

**Now.** A committed row is copied from the transaction arena to the table's heap
(about 4% of an insert, measured).

**Done when.** The table takes ownership of the staged values. The ownership has
to survive savepoints, `ALTER` and rollback, which is why this is last.

---

## S — SQLite's surface

Measured by `python scripts/sqlite_gaps.py`, which runs every built-in function
and pragma of SQLite 3.54.1 and 63 grammar shapes through the CLI. Every gap below
is **refused with a message**, never answered differently: that is the property
`scripts/differential.py` guards, and each item keeps it. An item is done when
its shapes run, `sqlite_gaps.py --check` is updated, and the differential corpus
gains a query per shape that compares the answer with SQLite's.

## S1 — The schema real files declare

**Done.** `CHECK` constraints, column and table level, named or not, enforced
on every write path (they run in `tx_insert`/`tx_update`, before a row is
staged) with SQLite's message and `SQLITE_CONSTRAINT_CHECK`; a column's own
CHECK goes with it on `DROP COLUMN`, and one that another part of the table
uses blocks the drop or a rename. `CONSTRAINT <name>` before any constraint. A
column-level `REFERENCES`, with the parent's primary key implied and a table
referencing itself. `DEFERRABLE INITIALLY DEFERRED` foreign keys, verified at
COMMIT. `CURRENT_TIMESTAMP`/`CURRENT_DATE`/`CURRENT_TIME`, and a DEFAULT that
calls a function evaluated per row. `ASC`/`DESC` on index and key columns. The
schema keeps them in a new optional section (`docs/file-format.md`), an export
writes the CHECKs and per-row defaults into the `.sqlite` file, and an import
reads them from the file's declaration (`test_check_constraints`,
`test_column_references_and_defaults`, `test_deferred_foreign_keys`,
`scripts/shell_smoke.py`).

Partial indexes (`WHERE`) and indexes over expressions, unique or not: a row
outside a partial index is not constrained by it, a key is the expression's value
(its `COLLATE` included), an expression that changes between evaluations
(`random()`, `'now'`, a subquery) is refused as SQLite refuses it, and the export
writes such an index's own entries so `PRAGMA integrity_check` passes and SQLite
enforces it (`test_partial_and_expression_indexes`). Three wrong answers found on
the way, fixed: `CREATE UNIQUE INDEX` over rows that already shared a key was
accepted and the index lost a row, so a lookup by that key answered fewer rows
than the table held; a UNIQUE column refused a second NULL, where SQL holds no
two NULLs equal (`test_unique_allows_many_nulls`); and `REPLACE` that found no
row to replace freed its error and reported a row it never inserted, which a
column left to its DEFAULT made happen. `lower`, `upper`, `replace`, `instr`,
`sign`, `sqrt` and `printf` give NULL for NULL instead of failing
(`test_functions_give_null_for_null`). The export now writes constant DEFAULTs
too.

**Now refused.** `ON CONFLICT <resolution>` on a constraint. An import does not
carry `REFERENCES` (a file may list a child before its parent). The planner does
not read a partial or expression index yet (D36).

**Why first.** A schema that uses any of them fails at `CREATE TABLE`, so
nothing written against it runs; and an imported file whose index is partial or
over an expression loses that index today (D24).

**Done when.** Each form is accepted and enforced: a `CHECK` that fails refuses
the row with SQLite's message and `SQLITE_CONSTRAINT_CHECK` through the facade; a
deferred foreign key is checked at `COMMIT`; a partial index holds only matching
rows and the planner uses it only when the query implies its `WHERE`.

## S2 — Statement and expression forms

**Done.** `IS` / `IS NOT` between any two values and `IS [NOT] DISTINCT FROM`;
the bitwise operators `& | ~ << >>` at SQLite's precedence; the JSON operators
`->` and `->>` (a path, a key or an array slot); `LIMIT <offset>, <count>`
(`test_is_compares_null_as_a_value`, `test_bitwise_operators`,
`test_json_arrow_operators`, `test_limit_with_a_comma`, and differential
queries). JSON object keys became case sensitive on the way, as SQLite's are.
`INSERT OR IGNORE`, `OR FAIL`, `OR ROLLBACK` (where the statement owns its
transaction) and `REPLACE INTO` (`test_insert_conflict_resolutions`). Making them
right needed statement atomicity: a statement that failed inside a transaction
used to leave the rows it staged before the failing one, and now a per-statement
undo log takes it back whole (`test_a_failed_statement_is_undone_in_a_transaction`).

`INTERSECT` and `EXCEPT`, with the chain applied left to right (a `UNION`
anywhere used to deduplicate the whole result); `NULLS FIRST` / `NULLS LAST`; a
subquery or `VALUES` in `FROM`, and `VALUES` as a statement; row values in
comparisons, `IN` lists and `IN (SELECT …)` (`test_compound_operators`,
`test_nulls_first_and_last`, `test_derived_tables_and_values`,
`test_row_values`). Two wrong answers were found and fixed on the way: a CTE's
name stayed bound for the rest of a transaction, hiding a real table of that
name from later statements, and an `ORDER BY` expression that failed (a misspelt
column, a window function) sorted as NULL instead of failing the statement.

**Now refused.** `UPDATE OR <resolution>`. A unique key an `UPDATE` changes is checked against the
statement's result, where SQLite checks it row by row; a statement whose rows
collide only partway through succeeds here (`docs/sqlite.md`).

**Done when.** Each runs and matches SQLite in the differential corpus, including
the `NULL` cases (`NULL IS NULL` is true, `1 & NULL` is `NULL`).

## S3 — Joins

**Now refused.** `RIGHT`, `FULL` and `NATURAL` joins, with a message that says to
write an inner or left join (`test_unsupported_joins_are_refused`).

**Done when.** `RIGHT` runs as a mirrored `LEFT`, `FULL` as a left join plus the
unmatched right rows, and `NATURAL` as `USING` over the shared column names; the
refusal test becomes an answer test.

## S4 — Aggregates and windows

**Now refused.** `FILTER (WHERE …)` on an aggregate or a window, a named `WINDOW`
clause, `ORDER BY` inside an aggregate's arguments (`group_concat(x ORDER BY x)`),
and the ordered-set aggregates `median`, `percentile`, `percentile_cont`,
`percentile_disc`; `json_group_array` and `json_group_object` are missing.

**Done when.** Each runs and matches SQLite.

## S5 — Built-in functions

**Missing (48 of 121).**

- Math: `acosh`, `asinh`, `atanh`, `cosh`, `sinh`, `tanh`, `ln`, and the aliases
  `ceiling`, `power`.
- Text and logic: `if` (an alias of `iif`), `soundex`, `unistr`, `unistr_quote`,
  `affinity`.
- Date: `timediff`, and `current_date` / `current_time` as functions (S1 covers
  the keywords).
- Planner hints: `likely`, `unlikely`, `likelihood` (identity functions).
- Introspection: `sqlite_source_id`, `sqlite_compileoption_get`,
  `sqlite_compileoption_used`, `sqlite_offset`.
- JSON: `json_insert`, `json_patch`, `json_pretty`, `json_parse`,
  `json_error_position`, `json_array_insert`, and the whole `jsonb_*` family
  (13 functions: SQLite's binary JSON; a first version can store it as text and
  answer the same values).

**Done when.** `sqlite_gaps.py` lists none of them, and each family has
differential queries.

## S6 — Statements and pragmas

**Missing statements.** `EXPLAIN QUERY PLAN` (`EXPLAIN` exists), `REINDEX`,
`INSTEAD OF` triggers on a view, `INDEXED BY` / `NOT INDEXED`, the
`generate_series` table function, `VACUUM` and `ATTACH ':memory:'` on an
in-memory database (SQLite accepts both; here the first is refused as "nothing to
compact" and the second as a missing file).

**Missing pragmas (9 of 63).** `collation_list`, `module_list`, `temp_store`,
`incremental_vacuum`, `shrink_memory`, `soft_heap_limit64`,
`temp_store_directory`, `data_store_directory`, `legacy_file_format`. The last
three are deprecated in SQLite; answering them is enough.

**Done when.** `sqlite_gaps.py` lists none of them.

## S7 — Affinity, untyped columns and `WITHOUT ROWID`

**Now.** A column declared `ANY` keeps each value's storage class (`typeof()`
reports it), but a column with **no** declared type (`CREATE TABLE t(x)`) is a
syntax error, a typed column coerces rather than applying SQLite's affinity
rules, and a comparison across classes is refused (`'1' = 1` answers "cannot
compare string with int", where SQLite answers 0 by its ordering of classes).
`WITHOUT ROWID` tables are read from a file but refused as a `CREATE TABLE`.

**Design.** An undeclared type becomes `ANY`; SQLite's affinity (the five rules
over the declared type name) becomes one function used on insert; comparison
across classes follows SQLite's order (NULL < numbers < text < blob) with its
numeric conversion for an affinity column. `WITHOUT ROWID` maps onto a table
whose primary key is its row identity.

**Done when.** An untyped column round-trips mixed values through the engine and
through a `.sqlite` export, and comparisons between classes match SQLite in the
differential corpus.

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
not counted against a memory budget, and `AS OF` on a join is refused.

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

**Now.** Every package passes `odin check` for linux_amd64, linux_arm64 and
darwin_arm64, and the CLI runs on Linux. `odin test src/tests` under the default
two-thread runner dies in `test_aggregates_and_order` with a map panic and a
segmentation fault, while the test alone passes: memory corruption, most likely
a map built in a transaction arena whose nodes are freed through another
allocator (`Tx_Snapshot`'s maps). On Windows the heap half works after all:
Odin's allocator calls `HeapAlloc`, which AddressSanitizer intercepts only with
`ASAN_OPTIONS=windows_hook_rtl_allocators=true`. With it, the CLI runs under the
`heap sanitizer` gate (`scripts/asan_smoke.py`) and the suite runs clean except
`test_expression_depth_is_bounded`, whose 100 levels overflow the larger frames
a sanitized build uses.

**Done when.** The threaded suite is green on Linux, a CI job runs it on Linux and
macOS with `-sanitize:address`, the Windows suite runs under the sanitizer as a
gate (it is the CLI only today), and the scripts that hardcode a
`.exe` (`ci.py`, `page_rss.py`, `plan_check.py`, `bench.py`, `lock_smoke.py`,
`broker_smoke.py`) find the binary on every platform.

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

1. The lines the suite still prints are test-side: a test that expects an error
   drops it. Quieting them is worth doing only if the noise starts hiding a real
   report.
2. A map node freed through the wrong allocator (see D34): harmless while the
   arena outlives the map, a crash the day it does not.
3. Error ownership: a host that receives an `Error` and drops it leaks the
   message. Every entry point that returns one should say the message is the
   caller's, in one sweep.
4. `log_index_append` opens the index sidecar, seeks and writes 16 bytes on every
   commit: the first place to look when commit latency matters.
