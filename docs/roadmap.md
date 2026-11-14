# Roadmap: what is left, in priority order

The parity matrix is closed (`docs/features.md`, 94 rows, 100/100) and the work
that closed it is recorded at the end of this file. This file is the
authoritative order for what is left; [backlog.md](backlog.md) carries the detail
and the cost of each item, and [status.md](status.md) the measurements.

**Scope note.** End-user documentation (guide, SQL reference, tutorials) is out
of scope here: it is maintained outside this repository. This file plans engine
work only — features, acceptance criteria and order.

**Priority rule.** Order is set by what blocks real use and what protects
everything else, not by what is most interesting. An item that removes a risk of
a wrong answer outranks an item that adds a capability; an item another item
depends on outranks the dependent; a release gate waits until the thing it
releases is worth shipping.

## Open items

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 1 | **D31 — the three wrong answers** | `substr('abcdef', -3)` returns the whole string where SQLite counts from the end; `WHERE 'a'` is true where SQLite casts the text to zero and answers nothing; `--json` prints an integral real as `1`, so a JSON consumer loses the type although `typeof` says `real`. None of the three has a test. What is left: the negative index, SQLite's numeric truth for a `WHERE` that is not a number, and the `.0` in the JSON rendering, each with a test; `INSERT OR REPLACE` is refused without being listed as refused. Second audit pass, `AUDIT-10` P-B1/P-B2/P-B3/P-B7. | S | D30 |
| 2 | **D30 — the differential cannot lie** | `differential.py` decides a statement is ordered with `"order by" in statement`, so every `OVER (… ORDER BY …)` is compared positionally against an unordered scan: three window queries were reported as differences while their multisets were identical. `same_cell` also treats `1` and `1.0` as equal, so a type bug is invisible. What is left: read the ordering from the statement's own top-level `ORDER BY`, compare types as well as values, adopt the 47 edge queries from `AUDIT-10` as the corpus, and stop calling the 3x guard a 10% contract (`AUDIT-10` P-B4/P-B5/P-A6). | S | D31 |
| 3 | **D27 — the mirror keeps the schema it does not model** | One `ALTER TABLE` through the engine rewrites the file's `CREATE TABLE` from the engine's own model: `REFERENCES … ON DELETE CASCADE`, `UNIQUE`, `CHECK`, `DEFAULT`, `COLLATE` and a `GENERATED` column all disappear, and views and triggers vanish entirely (measured: three objects before, one after). The file still opens, which is why D24 looked closed; what is lost is the database's rules. What is left: keep each object's original SQL and re-emit it when the model has not changed it, refuse a DDL that cannot be expressed instead of degrading it, and gate a round trip that compares `sqlite_master` before and after (`AUDIT-10` P-A1). | L | — |
| 4 | **D28 — open the way SQLite opens** | `:memory:` is not a database here: `miraidb sql :memory:` answers `io: cannot create :memory:: INVALID_NAME`, and `sqlite3_open(":memory:")` through the facade answers `SQLITE_ERROR`, as do `""` and `file::memory:?cache=shared`. A program written against the sqlite3 API cannot start. What is left: the three in-memory spellings in the engine, the C ABI and the facade, plus a gate that opens `:memory:` through the DLL (`AUDIT-10` P-A2). | S | D25 |
| 5 | **D29 — a C handle is never a dangling pointer** | `miraidb_step` after `miraidb_finalize` reads freed memory and answers `DONE`; `miraidb_bind_text` after it is an access violation that ends the host process, where sqlite3 answers `SQLITE_MISUSE` to both. `bind` also accepts any index — 99 succeeds and silently grows the parameter list, where SQLite answers `SQLITE_RANGE`. What is left: a live-handle table with misuse codes, a validated bind index, the same for a connection closed with statements open, and an ABI fuzz pass (`AUDIT-10` P-A3/P-B6). | M | D25 |
| 6 | **D23 — resource limits** — *partly done* | Done: the depth bound (an expression may nest 100 levels; the parser and the evaluator both refuse, where 155-178 levels used to kill the process), the quota applied while the projection produces rows, and the work budget reachable from the server. What is left: a join still builds its intermediate before the projection (so the quota cannot stop that spike), `LIMIT` is not pushed into the scan, an allocation that fails is a crash rather than `.Out_Of_Memory`, and neither the quota nor the budget is reachable from the C ABI (D25). An audit item (`AUDIT-9` A4/A5). | M | — |
| 7 | **D25 — the C ABI, completely** | 24 functions in the sqlite3 shape, and none of the engine's own levers: no open options (read-only, durability, in-memory), no row quota or work budget, no `miraidb_interrupt` although `store_cancel` exists, no identity or token so roles and policies are unreachable from C, and no statement on thread safety. `miraidb_open` also imports a `.sqlite` file into memory without saying so. An audit item (`AUDIT-9` B1). | M | D23 |
| 8 | **D26 — docs whose claims are executed** | The documentation gate checks shape (counts, links, forbidden names) and not content: `docs/sqlite.md` still says `BEFORE` triggers and `RANGE`/`GROUPS` frames are refused, and both work. What is left: the compatibility matrix becomes a table CI runs — the row that says *refused* must fail, the row that says *done* must answer, against `sqlite3`. An audit item (`AUDIT-9` B3). | S | — |
| 9 | **D9 — the rest of the grammar** | Windows beside `GROUP BY`, `ALTER` type changes, user functions (the three SQLite collations already exist: `BINARY`, `NOCASE`, `RTRIM`). Done: `GROUP BY` on a projection alias (`test_group_by_a_projection_alias`), `JOIN … USING` with the merged column printed once (`test_join_using`), `RANGE`/`GROUPS` frames with offsets in the order value (`test_window_range_and_groups_frames`), and `BEFORE` triggers (`test_before_triggers`). | L | — |
| 10 | **ASAN pass** over the CLI, soak and conformance — *partly done* | Bounds and stack are covered today. Odin's heap allocator is not intercepted on Windows (a deliberate use-after-free is not reported), so the heap half runs with the POSIX toolchain in #14. | 1 round | 12 |
| 11 | **D2 — spatial tree** | Node pages and a descent replace the scan over box columns. | M | — |
| 12 | **D10 — precision and time** | Decimal arithmetic with scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 13 | **D14 — replication** | `GET /log?since=<seq>`, a follower applying through the replay path, tested against a lagging follower and a dead leader. Failover stays unclaimed. The networking plan is below. | XL | — |
| 14 | **D12c — module sandbox** | Deterministic execution with enforced memory and time; today a module is a process with a work budget and the caller's clock. | L | — |
| 15 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 16 | **D16 — client generation from the catalog** | Emit the Python binding from the schema; the hand-written one is the contract it has to meet. | M | — |
| 17 | **D1 — the rest of full-text search** | Phrase queries (`"a b"`), prefix matching (`foo*`) and column filters (`body:foo`); `AND` is still parsed as a term rather than an operator, and a pattern taken from a column cannot narrow the scan. The index, the ranking and `snippet`/`highlight` are done. | M | — |
| 18 | **D4 — a secondary index in the mirror** | A table with a secondary index re-encodes the whole `.sqlite` file on every commit, because only table-b-tree leaves are patched. Patch the index b-trees too (a moved key can jump leaves), or state the fallback where a user will read it. | L | — |
| 19 | **D5 / D17 — the rest of the page store** | Merge an index leaf that loses its last entry; keep more than one version per row so `AS OF` and `ALTER` work on a paged table; let a read of a paged store run without holding the shared lock for its whole life; let a read-only open trust the pages when it can prove nothing is in flight. | L | — |
| 20 | **Diagnostics — a leak report a human can read** | The suite prints ~320k `+++ leak` lines (~9 per statement) and nobody has established whether they are real, and `soak.py` does not watch the working set. Make the tracker report a working set and settle the noise. The intermittent `_test_soak` refusal was two tests sharing one directory, not a lock bug, and is fixed. | M | — |
| 21 | **CI on Linux and macOS** | File locking and the VFS are per-OS, so the lock must be proven on all three; `-sanitize:address` covers the heap there (#3). Six scripts hardcode a `.exe` binary: `ci.py`, `page_rss.py`, `plan_check.py`, `bench.py`, `lock_smoke.py`, `broker_smoke.py`. | M | — |
| 22 | **Release and packaging** | `scripts/package.py` builds `dist/miraidb-<version>-<target>.zip` from the version the library reports and `--check` gates its manifest. Left: publish one archive per target, decide the version policy, and verify an archive builds twice byte for byte. | M | 16 |
| 23 | **Auth review** | The internal pass found one client's identity leaking into the next (fixed, `test_connection_identity`). Left: rate limits, a token lifetime policy, adversarial tests over subscriptions and budgets, the fact that without TLS (#8) a token travels in clear, and that **grants are opt-in**: a database with no grant rows allows every statement to every client, so a fresh deployment accepts anonymous writes until its grants exist. | S | — |
| 24 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each public release. | external | — |

## Efficiency contract and current baseline

The engine must stay **equal or better** than the reference model in every
measurable dimension. Measured on this tree:

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 46 838 /s on the 20k gate (baseline 42 219); 54 580 /s over 50k, run directly | not worse on the same hardware; 10% regression fails the gate |
| Read transaction, anyone reading | **10.7 µs** over 50k rows warm; opening one after a commit is **38 µs** on the gate (21 µs over 50 000 rows): it copies nothing | should cost the rows the transaction touches; it costs one reference per table |
| Commit with a read open | **16.9 ms** over 20 000 rows, **46 ms** over 50 000: it copies the table it writes and leaves the old one to the reader | the copy a commit pays is the rows of the table it writes, and only while a reader is open (D3) |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, one file left | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a written reason |
| Join, inner side | a nested loop reads the inner rows its ON clause names (`test_join_probes_the_inner_index`: 1 200 rows where a scan read 200 200) | O(rows the outer row matches) |
| Ordered read | `ORDER BY <index key>` walks the index: 137 ms against 342 ms sorted over 50 000 rows, and `LIMIT 5` reads five rows in 4.6 ms where the sort took 115 ms | an ordered query costs the rows it returns, not a sort |
| Subscription delta | O(rows touched), for a join too: an equi-join is indexed by its key, so a commit probes the matches (one candidate for an insert, six for a base-row change, in a fixture of 200 authors and 900 books, where it used to read 200 and 900) | O(rows touched) for the table the commit changed |

These are the numbers the gate compares against and the targets the engine is
held to, and every row is met today. The read row is met by moving the copy
rather than hiding it: a read copies nothing, and the commit pays for the table it
writes while a reader holds it, once per read generation. `bench-read` reports the
read and that commit separately, and `scripts/bench.py` gates both. The
subscription row is met by the join index, and
`test_join_subscription_probes_the_join_key` counts the candidates a commit
walks, so a regression to the scan fails the suite.

## Reusing the engine's networking for D14

The engine this tool accompanies (checked out as `mirai-engine`) already has a
networking library in the same language, Odin, so the follower does not need a new
protocol: it can import `net` and carry replicated commit records as its messages.
The package is about 12.000 lines across 48 files and exposes
`repl_peer_allocate` / `_connected` / `_disconnected` / `_release`, the authority
operations (`Authority_Request` / `_Grant` / `_Release`) as system messages, plus
`channel`, `clock`, `conditioner`, `baseline` and `pool`.

| Piece there | What it gives a follower |
|---|---|
| `channel` | datagrams delivered whole and in order, or not at all; one reliable channel and one unreliable, kept by the library |
| `replication` / `protocol` | the message set for peers and the rules for what is sent once and in what order |
| `baseline` + `collection` | "start from this state, then apply changes": our snapshot plus records after `seq` maps onto it directly |
| `clock` | ticks numbered alike on both ends, which is what makes applying a record deterministic |
| `peer` / `host` / `connection` | connection lifecycle and queues; a full reliable queue refuses messages instead of dropping the connection |
| `conditioner` | simulated latency, jitter and loss: the test rig for a lagging or flapping follower |

What miraidb brings: the segmented log with CRC32C per record, the replay path and
the snapshot with an offset index. What the engine brings: transport, ordering
guarantees and the harness. D14 is mostly wiring: name a baseline, stream records
after it, apply through `commitlog`, expose the last applied sequence.

## What this costs

| Work | New engine lines (order of magnitude) |
|---|---|
| The second-pass items (D31, D30, D27, D28, D29) | ~2.000 |
| The first audit's items (D22–D26: server, limits, the mirror, the C ABI, doc claims) | ~2.500 |
| The grammar and the depth work (D9, ASAN, D2, D10, D14, D12c, D15, D16, D1 and the residuals) | ~14.000 |
| The release gates (CI, packaging, auth, licences) | ~1.000 |

## Closed already (for the record)

The items below were in this table and are done; each entry names the code and
the test or gate that proves it. The engineering gates that watch them today are
listed in `docs/status.md` and run by `scripts/ci.py` (23 gates).

| Item | Evidence |
|---|---|
| **D18a — writer lock** | `<directory>/lock` held with an OS lock (Windows `LockFileEx`, POSIX `fcntl`), released on close and on death; the refusal names the owner. `test_writer_lock` and `scripts/lock_smoke.py` with two processes. |
| **D18b — a reader beside the writer** | Two lock bytes: the writer's exclusive, the reader's shared. A read-only open replays, refuses every mutation and waits out a compaction; a paged database opens from `<db>/catalog` and trusts the page files only when every sequence agrees (the 60k-row peak fell from 33.9 MiB to 6.4 MiB). `test_read_only_opens_beside_a_writer`, `test_trusted_open_skips_the_replay`. |
| **D18c — broker mode** | `miraidb-server` owns the directory and serves HTTP wire messages, TCP frames with a per-connection owner, and Postgres; `scripts/broker_smoke.py` runs two processes, reads a write from a second client and refuses a second owner. |
| **D22 — the server, for real** | A thread per connection, so a subscriber no longer blocks anyone; `host.on_update` wired to the transport, so a subscription delivers a delta per commit (`scripts/broker_smoke.py` holds a subscription open, writes from another client and reads the delta); `ATTACH`, `LOAD EXTENSION` and `VACUUM INTO` refused to clients with `Permission_Denied` unless the server was started with `--allow-host` (`test_host_statements_need_host_access`); `--statement-timeout-ms` cancels a statement that outlives it and the server keeps serving (the gate proves the error, the survival and the untouched table). `docs/security.md` states what a token buys and what is not defended. Statements still run one at a time, which the store's single identity field requires. |
| **D24 — the `.sqlite` mirror** | A file stays readable through DDL: the full rewrite honours the room the 100-byte header needs, so an empty `sqlite_master` (a dropped last table) no longer writes a malformed file; an imported file's indexes are read and recreated, so a plan walks one and `DROP INDEX` finds it. `scripts/sqlite_abi_smoke.py` runs `DROP TABLE`, `ALTER TABLE`, `INSERT`, `DROP INDEX` and `CREATE INDEX` through the facade and verifies integrity, rows and `sqlite_master` with Python's `sqlite3`; `test_empty_export_is_a_readable_file` and `test_imported_indexes_are_planned_and_droppable` cover the two defects. |
| **D6 — the join constants** | The join delta, the probe, the order searched by cost with measured constants, the range written as two comparisons, the subscription walking the planned order, and the star expanded from the statement. Each has its test (`test_join_subscription_walks_the_planned_order`, `test_plan_reads_a_range_written_as_two_comparisons`, `test_plan_does_not_cross_join_before_it_can_filter`, …) and gate 7 judges the plan by rows visited. |
| **D8 — fault injection** | `Fault_Vfs` fails any operation at any call, or writes short; `test_fault_injection` arms every write of a workload and proves the reopen sees exactly the commits that reported success. |
| **Benchmark gate** | `benchmarks/baseline.json` plus `scripts/bench.py --check`: bytes per row within 10%, insert rate, read cost and compaction under a 3x guard, with the machine recorded beside the numbers. |
| **D11 — DDL inside a transaction** | Index operations are staged like row changes, applied after them, and rolled back with them; `DROP INDEX` finds an index created earlier in the same transaction and a duplicate create is refused before apply (`test_ddl_in_transaction`). |
| **D1 — full-text index and BM25** | The `term` index is created with the table, `rank` is BM25 over the postings, `snippet`/`highlight` mark the match, and a rare term visits at most 8 rows of 5 000 (`test_full_text_ranking`, `test_full_text_cost`). |
| **D13 — the stored result on a retry** | The response commits with the request id and `host_call_once_result` answers a retry with it (`test_idempotent_result`). |
| **D17 — rows on disk** | A store opened with `paged_tables` keeps each table in a 4 KiB-page file under `<db>/tables`: a cache over the log, flushed after the log record is durable, frame 0 reserved for the header. A single-table query streams the pages; `ORDER BY`/`GROUP BY`/`DISTINCT`/windows/`AS OF`/joins/staged writes fall back to collecting. `scripts/page_rss.py` is a gate: a table 63× the pool adds 316 KiB to the statement and four times the rows adds the same. |
| **D19 — `CASE` expressions** | Both forms, anywhere an expression is allowed, including policies and triggers; `NULL` conditions match nothing, no `ELSE` gives `NULL`, only the chosen branch is evaluated. `test_case_expressions`, and seven `CASE` queries in the differential corpus. `GROUP BY` on a projection alias is still D9. |
| **D20 — differential runner** | `scripts/differential.py` is a gate: 55 queries answer identically through this engine and the system `sqlite3`, 7 statements are refused with a reason and 4 differ on purpose. It found the ORDER BY tie order (fixed with a row-id tiebreak) and the missing scalar `min`/`max` and `trim(s, chars)` (fixed); a refusal that stops refusing fails the gate. |
| **D5 — index keys in pages** | Each index of a paged table is a B+tree of 4 KiB pages under `<db>/indexes/…` with its own pool, chained leaves and a cursor without a parent stack; point lookups, ranges, `UNIQUE`, updates, deletes and `TRUNCATE` go through the pages. An empty leaf is not merged yet (a delete never answers wrongly). |
| **D6 — the planner** (the first half) | `ANALYZE` measures rows, distinct values, NULLs, the numeric range and a sixteen-bucket histogram into `<db>/stats`; the planner prices scan against probe and prints `est. N rows, cost C`; joins run in the planned order with each `ON` attached to the step that completes the relations it names. `scripts/plan_check.py` guards the plans (`test_analyze_and_plan_estimates`, `test_plan_reorders_a_join`). The join delta is item 2, and the order is searched by cost: a produced row is measured at 5.1 µs and a step whose `ON` cannot be answered yet multiplies by its whole relation, so it runs last (`test_plan_does_not_cross_join_before_it_can_filter`). |
| **D4 — `.sqlite` pages in place** | The mirror patches the leaf of every changed row, the separator its parent stores and page 1: three pages (12 KiB) per commit at 10k, 100k and 250k rows, where re-encoding wrote 172 KiB, 1.8 MB and 4.8 MB. Splits, empty-leaf unlink, free-list reuse and torn-commit recovery through a rollback journal in SQLite's format; `scripts/mirror_cost.py` checks the file with real `sqlite3`. |
| **D3 — `AS OF` and version pruning** | `FROM t AS OF <seq>` reads the versions the table keeps and `store_prune_versions` discards what no reader can ask for (`test_as_of`); automatic retention and `AS OF` on a join remain in D3's backlog entry. |
| **D3 — a read that copies nothing** | A read transaction shares the tables: one reference per table, no rows copied, and the store's read cache is gone with it. A commit that has to change a table a reader holds copies **that** table (`table_cow_clone`), so the copy is per written table and only while a reader is open. The first read after a commit fell from 24 ms to 38 µs on the gate (21 µs over 50 000 rows); the commit that pays for a live reader is 16.9 ms (46 ms over 50 000). `test_a_commit_copies_the_table_a_reader_holds` proves the reader keeps its values, that the table a commit does not write is not copied, and that a commit nobody reads copies nothing; `bench-read` reports both numbers and `scripts/bench.py` gates both. |
| **D7 — scheduler durability** | `_schedule.at_us` is a column and commits; a restart resumes pending work (`test_durability_after_restart`). |
| **D12a / D12b — work budget and module latency** | One unit per row touched, a per-statement and a per-call budget that rolls the call back (`test_work_budget`); one pooled socket per module, one frame each way. |
| **Page memory gate** | `scripts/page_rss.py --check` reads a table far larger than the pool and bounds what the statement adds; `scripts/plan_check.py` guards the plans a measured fixture must produce. |
| **Sanitizer pass (bounds and stack)** | The suite runs under `-sanitize:address` with no bounds or stack report; the heap half is item 6, because Odin's allocator on Windows bypasses the sanitizer's interception (verified with a deliberate use-after-free). |
| **Documentation consistency gate** | `scripts/docs_check.py`: version, test count, gate count, CLI commands, relative links, roadmap/backlog cross-references, orphan documents and the names the project does not use. Backlog D21. |
| **Audit corrections** | Two items once written down as gaps (D7, D13) were already durable, two wrong answers in `IN`/`NOT IN` and `DISTINCT` aggregates were found and fixed with tests, and the capabilities that three documents understated (the README, the CLI usage and the SQLite matrix) were rewritten. |

The three asks of the original plan — access from several processes, a per-term
full-text index, and pages on disk — are all closed above. What remains is
depth, not absence.
