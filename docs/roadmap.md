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
| 1 | **D19 — `CASE` expressions** | Simple and searched `CASE` wherever an expression is allowed, including policies and triggers; `NULL` conditions are not true, no `ELSE` yields `NULL`. It is the only statement `docs/sqlite.md` still marks missing. D19. | M | — |
| 2 | **D3 — the first read after a commit** | Three parts: clone a table's rows and indexes without re-inserting every row (measured 2.3 µs/row, 115–117 ms at 50 000), evict `store.retired` so the read cache keeps publishing past 16 snapshots, and make `bench-read` time a commit followed by a read. Two rows of the efficiency contract are marked not met until this lands. | L | — |
| 3 | **D6 — the delta of a join subscription** | Index the join key per table so a commit costs the rows it touched instead of collecting every row of the other tables; then the smaller planner gaps: probe the joined side, `ORDER BY` from an index, calibrated constants, statistics that announce staleness, a histogram for a bound value, an estimate for a view, and the subscription path using the planned order. | L | — |
| 4 | **D9 — the rest of the grammar** | `RANGE`/`GROUPS` frames, windows beside `GROUP BY`, `BEFORE` triggers, `ALTER` type changes, more collations, user functions. | L | — |
| 5 | **ASAN pass** over the CLI, soak and conformance — *partly done* | Bounds and stack are covered today. Odin's heap allocator is not intercepted on Windows (a deliberate use-after-free is not reported), so the heap half runs with the POSIX toolchain in #17. | 1 round | 13 |
| 6 | **D2 — spatial tree** | Node pages and a descent replace the scan over box columns. | M | — |
| 7 | **D10 — precision and time** | Decimal arithmetic with scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 8 | **D14 — replication** | `GET /log?since=<seq>`, a follower applying through the replay path, tested against a lagging follower and a dead leader. Failover stays unclaimed. The networking plan is below. | XL | — |
| 9 | **D12c — module sandbox** | Deterministic execution with enforced memory and time; today a module is a process with a work budget and the caller's clock. | L | — |
| 10 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 11 | **D16 — client generation from the catalog** | Emit the Python binding from the schema; the hand-written one is the contract it has to meet. | M | — |
| 12 | **D1 — the rest of full-text search** | Phrase queries (`"a b"`), prefix matching (`foo*`) and column filters (`body:foo`); `AND` is still parsed as a term rather than an operator, and a pattern taken from a column cannot narrow the scan. The index, the ranking and `snippet`/`highlight` are done. | M | — |
| 13 | **D4 — a secondary index in the mirror** | A table with a secondary index re-encodes the whole `.sqlite` file on every commit, because only table-b-tree leaves are patched. Patch the index b-trees too (a moved key can jump leaves), or state the fallback where a user will read it. | L | — |
| 14 | **D5 / D17 — the rest of the page store** | Merge an index leaf that loses its last entry; keep more than one version per row so `AS OF` and `ALTER` work on a paged table; let a read of a paged store run without holding the shared lock for its whole life; let a read-only open trust the pages when it can prove nothing is in flight. | L | — |
| 15 | **Diagnostics — a leak report a human can read** | The suite prints ~320k `+++ leak` lines (~9 per statement) and nobody has established whether they are real; `soak.py` does not watch the working set, and `test_soak_update_delete_prune` failed once opening its lock file. Make the tracker report a working set, settle the noise, and chase the flake. | M | — |
| 16 | **CI on Linux and macOS** | File locking and the VFS are per-OS, so the lock must be proven on all three; `-sanitize:address` covers the heap there (#6). Six scripts hardcode a `.exe` binary: `ci.py`, `page_rss.py`, `plan_check.py`, `bench.py`, `lock_smoke.py`, `broker_smoke.py`. | M | — |
| 17 | **Release and packaging** | `scripts/package.py` builds `dist/miraidb-<version>-<target>.zip` from the version the library reports and `--check` gates its manifest. Left: publish one archive per target, decide the version policy, and verify an archive builds twice byte for byte. | M | 17 |
| 18 | **Auth review** | The internal pass found one client's identity leaking into the next (fixed, `test_connection_identity`). Left: rate limits, a token lifetime policy, adversarial tests over subscriptions and budgets, and the fact that without TLS (#11) a token travels in clear. | S | — |
| 19 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each public release. | external | 18 |

The last four are the release gates, in the order they have to run: prove it on
every platform, package it, review who may call it, review what it carries. The
rest come before them because a release is only worth making once the engine
answers correctly, ships its own weight, and can be replicated.

Rounds map onto the list: **1–3** are the correctness-and-measurement round
(this one), **4–15** the depth round (grammar, sanitizer, spatial, precision,
replication, sandbox, network, clients, and the residuals of full-text, the
mirror, the page store and diagnostics), **16–19** the release round.

## Efficiency contract and current baseline

The engine must stay **equal or better** than the reference model in every
measurable dimension. Measured on this tree:

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 46 838 /s on the 20k gate (baseline 42 219); 54 580 /s over 50k, run directly | not worse on the same hardware; 10% regression fails the gate |
| Read transaction, cache warm | 11.4 µs over 50k rows | same |
| Read transaction, first after a commit | **116 ms**: it clones the table | should cost the rows the transaction touches; today it is O(rows) at ~2.3 µs per row (D3, not met) |
| Freeze a 50k-row table | **115–117 ms** (`table_snapshot` measured three times) | was recorded as ~1 ms; the real cost is 2.3 µs per row (D3, not met) |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, one file left | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a written reason |
| Subscription delta | O(rows touched) for one table; a join re-collects every row of the other tables on each commit | O(rows touched) for the table the commit changed (D6, not met for joins) |

These are the numbers the gate compares against and the targets the engine is
held to. Three rows are recorded as **not met** rather than quietly relaxed: the
first read after a commit pays a full table clone, so a database that writes
while it serves readers pays it per commit, and `bench-read` hides it because
its preparation statement publishes the read cache before it starts timing.
Items 2 and 3 carry the work.

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
| Items 1–3 (`CASE`, snapshot, join delta) | ~2.000 |
| Items 4–15 (grammar, sanitizer, spatial, precision, replication, sandbox, network, clients, and the residuals) | ~14.000 |
| Items 16–19 (release gates) | ~1.000 |

## Closed already (for the record)

The items below were in this table and are done; each entry names the code and
the test or gate that proves it. The engineering gates that watch them today are
listed in `docs/status.md` and run by `scripts/ci.py` (23 gates).

| Item | Evidence |
|---|---|
| **D18a — writer lock** | `<directory>/lock` held with an OS lock (Windows `LockFileEx`, POSIX `fcntl`), released on close and on death; the refusal names the owner. `test_writer_lock` and `scripts/lock_smoke.py` with two processes. |
| **D18b — a reader beside the writer** | Two lock bytes: the writer's exclusive, the reader's shared. A read-only open replays, refuses every mutation and waits out a compaction; a paged database opens from `<db>/catalog` and trusts the page files only when every sequence agrees (the 60k-row peak fell from 33.9 MiB to 6.4 MiB). `test_read_only_opens_beside_a_writer`, `test_trusted_open_skips_the_replay`. |
| **D18c — broker mode** | `miraidb-server` owns the directory and serves HTTP wire messages, TCP frames with a per-connection owner, and Postgres; `scripts/broker_smoke.py` runs two processes, reads a write from a second client and refuses a second owner. |
| **D8 — fault injection** | `Fault_Vfs` fails any operation at any call, or writes short; `test_fault_injection` arms every write of a workload and proves the reopen sees exactly the commits that reported success. |
| **Benchmark gate** | `benchmarks/baseline.json` plus `scripts/bench.py --check`: bytes per row within 10%, insert rate, read cost and compaction under a 3x guard, with the machine recorded beside the numbers. |
| **D11 — DDL inside a transaction** | Index operations are staged like row changes, applied after them, and rolled back with them; `DROP INDEX` finds an index created earlier in the same transaction and a duplicate create is refused before apply (`test_ddl_in_transaction`). |
| **D1 — full-text index and BM25** | The `term` index is created with the table, `rank` is BM25 over the postings, `snippet`/`highlight` mark the match, and a rare term visits at most 8 rows of 5 000 (`test_full_text_ranking`, `test_full_text_cost`). |
| **D13 — the stored result on a retry** | The response commits with the request id and `host_call_once_result` answers a retry with it (`test_idempotent_result`). |
| **D17 — rows on disk** | A store opened with `paged_tables` keeps each table in a 4 KiB-page file under `<db>/tables`: a cache over the log, flushed after the log record is durable, frame 0 reserved for the header. A single-table query streams the pages; `ORDER BY`/`GROUP BY`/`DISTINCT`/windows/`AS OF`/joins/staged writes fall back to collecting. `scripts/page_rss.py` is a gate: a table 63× the pool adds 316 KiB to the statement and four times the rows adds the same. |
| **D20 — differential runner** | `scripts/differential.py` is a gate: 55 queries answer identically through this engine and the system `sqlite3`, 7 statements are refused with a reason and 4 differ on purpose. It found the ORDER BY tie order (fixed with a row-id tiebreak) and the missing scalar `min`/`max` and `trim(s, chars)` (fixed); a refusal that stops refusing fails the gate. |
| **D5 — index keys in pages** | Each index of a paged table is a B+tree of 4 KiB pages under `<db>/indexes/…` with its own pool, chained leaves and a cursor without a parent stack; point lookups, ranges, `UNIQUE`, updates, deletes and `TRUNCATE` go through the pages. An empty leaf is not merged yet (a delete never answers wrongly). |
| **D6 — the planner** (the first half) | `ANALYZE` measures rows, distinct values, NULLs, the numeric range and a sixteen-bucket histogram into `<db>/stats`; the planner prices scan against probe and prints `est. N rows, cost C`; joins run in the planned order with each `ON` attached to the step that completes the relations it names. `scripts/plan_check.py` guards the plans (`test_analyze_and_plan_estimates`, `test_plan_reorders_a_join`). The join delta is item 3. |
| **D4 — `.sqlite` pages in place** | The mirror patches the leaf of every changed row, the separator its parent stores and page 1: three pages (12 KiB) per commit at 10k, 100k and 250k rows, where re-encoding wrote 172 KiB, 1.8 MB and 4.8 MB. Splits, empty-leaf unlink, free-list reuse and torn-commit recovery through a rollback journal in SQLite's format; `scripts/mirror_cost.py` checks the file with real `sqlite3`. |
| **D3 — `AS OF` and version pruning** | `FROM t AS OF <seq>` reads the versions the table keeps and `store_prune_versions` discards what no reader can ask for (`test_as_of`). The snapshot cost is item 3; automatic retention and `AS OF` on a join remain in D3's backlog entry. |
| **D7 — scheduler durability** | `_schedule.at_us` is a column and commits; a restart resumes pending work (`test_durability_after_restart`). |
| **D12a / D12b — work budget and module latency** | One unit per row touched, a per-statement and a per-call budget that rolls the call back (`test_work_budget`); one pooled socket per module, one frame each way. |
| **Page memory gate** | `scripts/page_rss.py --check` reads a table far larger than the pool and bounds what the statement adds; `scripts/plan_check.py` guards the plans a measured fixture must produce. |
| **Sanitizer pass (bounds and stack)** | The suite runs under `-sanitize:address` with no bounds or stack report; the heap half is item 6, because Odin's allocator on Windows bypasses the sanitizer's interception (verified with a deliberate use-after-free). |
| **Documentation consistency gate** | `scripts/docs_check.py`: version, test count, gate count, CLI commands, relative links, roadmap/backlog cross-references, orphan documents and the names the project does not use. Backlog D21. |
| **Audit corrections** | Two items once written down as gaps (D7, D13) were already durable, two wrong answers in `IN`/`NOT IN` and `DISTINCT` aggregates were found and fixed with tests, and the capabilities that three documents understated (the README, the CLI usage and the SQLite matrix) were rewritten. |

The three asks of the original plan — access from several processes, a per-term
full-text index, and pages on disk — are all closed above. What remains is
depth, not absence.
