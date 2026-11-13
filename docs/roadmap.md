# Roadmap: every pending item, in priority order

The feature matrix is closed (`docs/features.md`, 94 rows, 100/100). This file is
the authoritative order for the work that is left; [backlog.md](backlog.md) holds
the detail and the cost of each item, and [status.md](status.md) the honest
measurement of today.

**Scope note.** End-user documentation (guide, SQL reference, tutorials) is out of
scope here: it is maintained outside this repository. This file plans engine work
only — features, acceptance criteria and order.

**Priority rule.** Order is set by what blocks real use and what protects
everything else, not by what is most interesting. An item that removes a way to
lose data outranks an item that adds a capability; an item another item depends on
outranks the dependent.

## Priority order (authoritative)

| # | Item | Why at this position | Effort | Depends on |
|---|---|---|---|---|
| 1 | **D18a — writer lock** — *done* | Two processes on one directory corrupted each other silently; now the second open is refused with `locked` and the owner's pid, proven in-process and with two real processes. | S | — |
| 2 | **ASAN pass** over CLI, soak and conformance — *partly done* | The whole suite ran under `-sanitize:address` and found no bounds or stack errors. Odin's heap allocator is not intercepted on this toolchain (a deliberate use-after-free is not reported), so heap safety rests on the fault walk, the leak tracker and the tests until the Linux CI (#13) runs the same pass with a working heap sanitizer. | 1 round | — |
| 3 | **D8 — fault injection** — *done* | `Fault_Vfs` fails any operation at any call; `test_fault_injection` walks every write of a workload and proves the reopened state is exactly the commits that reported success. The page store will reuse the harness. | S | — |
| 4 | **Benchmark gate** — *done* | `scripts/bench.py` records bytes per row, insert rate, read cost and compaction in `benchmarks/baseline.json` and fails the build beyond the recorded limits; the efficiency contract is now enforced, not remembered. | S | — |
| 5 | **D11 — DDL inside a transaction** — *done* | Index DDL is staged like row changes and applied after them, so a table, its rows and its index commit together and roll back together. Unblocks the FTS index. | S | — |
| 6 | **D1 — FTS term index + BM25** — *done* | The term index is created with the table, `rank` is BM25 over the postings, `snippet`/`highlight` mark the match, and the scan visits only the matching documents (5000 documents: at most 8 rows visited for a rare term). | M | D11 |
| 7 | **D13 — return the stored result on a retry** — *done* | The result commits with the request id, and `host_call_once_result` answers a retry with it instead of "already ran". | S | — |
| 8 | **D17 — rows on disk (page store)** — *done* | A store opened with `paged_tables` keeps each user table in a 4 KiB-page file under `<db>/tables`. The page file is a cache over the log: opening discards it and the replay rebuilds it, a commit flushes it after the log record is durable, and frame 0 is reserved for the header. A single-table query streams the pages (`ORDER BY`/`GROUP BY`/`DISTINCT`/windows/`AS OF`/joins/staged writes fall back to collecting), aggregates accumulate as rows pass, and `LIMIT` stops the scan. `scripts/page_rss.py` is a CI gate: a table 63 times the pool adds 316 KiB to the statement, and four times the rows adds the same. `AS OF` and `ALTER` refuse a paged table, and a read transaction holds the shared lock, because one version lives in the pages. | XL | D8, bench |
| 9 | **D5 — index keys in pages** — *done* | Each index of a paged table is a B+tree of 4 KiB pages under `<db>/indexes/<table>/<index>`, with its own 32-frame pool, leaves chained in key order and a cursor that walks them without a parent stack. Point lookups, ranges, `UNIQUE`, updates, deletes, `TRUNCATE` and `CREATE INDEX` after a reopen go through the pages; `table_memory` reports the pool, and `scripts/page_rss.py` now also checks the index file grows with the rows (688 KiB → 2756 KiB for 4× the rows) while the statement stays near 300 KiB. An empty leaf is not merged yet, so an index that loses most of its keys keeps its leaves until it is rebuilt. Opening still rebuilds the trees with the rows: trusting the header is D18b. | L | D17 |
| 10 | **D18b — a reader in another process** | With pages and a lock, a read-only open can coexist with a writer: "varios procesos" becomes true, not just safe. | L | D17, D18a |
| 11 | **D6 — planner with statistics** | `ANALYZE`, a cost model, join reordering; the largest query-level win and a prerequisite for calling the engine fast on real schemas. | L | D5 (statistics live in pages) |
| 12 | **D4 — `.sqlite` pages in place** | The mirror re-encodes the whole state per commit; with pages it writes only what changed. Until then it stays a documented O(state) export. | XL | D17 |
| 13 | **CI on Linux and macOS** | The suite runs on Windows only; file locking (D18a) and the VFS are per-OS, so the lock must be proven on all three. | M | D18a |
| 14 | **D3 — `AS OF` and version GC** — *done* | `FROM t AS OF <seq>` reads the versions the table keeps, and `store_prune_versions` discards what no reader can ask for (`test_as_of`). What is left is an automatic retention policy and `AS OF` on a join. | M | — |
| 15 | **D9 — the rest of the grammar** — *started* | `ROWS` window frames, trigger `WHEN` and `ALTER TABLE RENAME COLUMN` landed with their own tests. Left: windows beside `GROUP BY`, `RANGE`/`GROUPS`, `BEFORE` triggers, `ALTER` type changes, more collations, user functions. | L | — |
| 16 | **D2 — spatial tree** | Boxes as columns today; node pages and a descent replace the scan. | M | D17, D5 |
| 17 | **D10 — precision and time** | Decimal arithmetic with scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 18 | **D18c — broker mode** — *done* | `miraidb-server` owns the directory and serves HTTP wire messages, TCP frames with a per-connection owner, and Postgres; `scripts/broker_smoke.py` runs two real processes, reads a write from a second client, and checks a second server is refused with `locked`. It found and fixed a server that parsed a request from one `recv`. | M | D18a |
| 19 | **D14 — replication** | `GET /log?since=<seq>`, a follower applying through the replay path, tested against a lagging follower and a dead leader; reuses the engine's `net` package. Failover stays unclaimed. | XL | D18c |
| 20 | **D12c — module VM** | Deterministic execution with enforced memory and time; today modules are processes with a work budget and the caller's clock. | L | — |
| 21 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 22 | **D16 — client generation from the catalog** | Emit the Python binding from the schema; the hand-written one is the contract it has to meet. | M | — |
| 23 | **Release packaging** — *done* | `scripts/package.py` builds `dist/miraidb-<version>-<target>.zip` from the version the library reports: two programs, the shared library, the header, the Python binding, the licences, the notices, a `pkg-config` file and the changelog. `--check` runs as a CI gate and verifies the manifest. | M | #13 |
| 24 | **Auth review** — *started* | It found that one client's identity was left on the store and inherited by the next; the wire now runs each request with its caller's identity (`test_connection_identity`). Left: rate limits, token lifetime policy, and the fact that without TLS (D15) a token travels in clear. | S | — |
| 25 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each public release. | external | #23 |

Priority 1 landed first; the numbers are position, not rank, so the work
continues at 2. Rounds map onto the list: **1–7** are one round of small,
mutually unblocking work; **8–12** are the storage round; **13–17** the surface round; **18–22** the
sharing round; **23–25** are release gates that can run in parallel from #13.

## The three asks, in detail

### 1. Access from several processes or connections (D18a, D18b, D18c)

Today: several *connections* to one host work — each client gets its own
subscriptions, its own byte budget and its own last-applied sequence. Several
*processes* on one database do not: there is no lock, so two writers would corrupt
each other.

- **D18a** (priority 1): an exclusive lock on open, so a second writer is refused
  with an error that names the owner. Scope: per-OS lock (Windows `LockFileEx`,
  POSIX `flock`), a lock file beside the log, released on close and on crash.
- **D18b** (10): once pages exist, a read-only open beside a writer sees only
  committed state; the writer appends pages and log records, the reader pins a
  sequence.
- **D18c** (18): broker mode — one process owns the database and the others speak
  the wire protocol, reusing the caps, timeouts and work budgets that already
  exist. This is the cheap path, and the one to prefer until D18b lands.

**Acceptance.** Opening the same directory twice answers `io`/`locked` naming the
owner; a read-only open beside a writer sees only committed rows; broker mode
serves two clients with independent subscriptions from one owner, and killing one
client does not disturb the other.

### 2. FTS with a per-term index and BM25 (D1)

Today: an inverted table `_fts_<name>_terms (term, doc)` exists, but `MATCH`
resolves each pattern with **one scan of the term table**, and there is no
`rank`.

- The index on `term` cannot be created inside the transaction that creates the
  table (D11), which is the only reason for the scan.
- **BM25** needs two numbers: document frequency per term (a counter per term) and
  document length (tokens per document). Both fit in the shadow tables, so `rank`
  is a pass over the **matching** documents only.
- `snippet()` / `highlight()` mark the match in the stored text.
- `AND` becomes an operator instead of being a term; `OR`/`NOT` already work.

**Acceptance.** A rare term outranks a common one; a short document outranks a
long one at equal frequency; `rank` is computed from the index, not from a
document scan; `snippet()` marks the match; `AND`/`OR`/`NOT` parse as operators;
cost follows matches, not vocabulary.

### 3. Pages on disk instead of everything in RAM (D17, D5, D4, D18b)

Today: every table is a `map[Row_Id]Row` in memory.

- **D17** (8): fixed-size pages, a page file (or one file with an allocation
  map), a buffer pool with a clock hand and a memory cap, dirty-page flushing
  ordered **after** the commit record that describes it, and a free list that
  survives a crash. Recovery stays "replay what the pages are missing".
- **D5** (9): index pages, so an index stops costing one RAM entry per row.
  **Done**; opening still rebuilds them until D18b trusts the headers.
- **D6** (11): `ANALYZE` statistics stored in pages, then a cost model and join
  reordering.
- **D4** (12): the `.sqlite` mirror writes touched pages instead of the whole
  state.
- **D18b** (10): the reader-in-another-process case that pages make possible.

**Acceptance.** A table ten times the buffer pool reads correctly with RSS under
the configured cap — `scripts/page_rss.py --check` reads 15k and 60k rows through
an 8-frame pool and measures what the statement added over the open (316 KiB for
both; the file is 63 times the pool). A kill during a dirty flush reopens to the
last committed state (the page file is rebuilt from the log, and the flush writes
pages before the header). `bench` and `bench-read` stay within 10% for data that
fits in memory; `EXPLAIN` shows index pages being probed rather than a scan is
still D5.

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

## Engineering gates (parallel, and some are priorities)

| Gate | Why | Effort | Priority |
|---|---|---|---|
| **Address sanitizer** over CLI, soak and conformance — *partly done* | Memory bugs have been the real risk; bounds and stack are covered here, the heap needs the Linux toolchain | 1 round per phase | #2 |
| **Fault injection** (D8) | Proves no third state after a failed write | S, then extended | #3 |
| **Benchmark with thresholds** — *done* | Bytes per row within 10%; timings under a 3x catastrophe guard, because a shared machine cannot promise 10% (the 10% time rule is measured by hand with `--record`) | 1 day | #4 |
| **Page memory** — *done* | `scripts/page_rss.py --check` reads a table far larger than the pool and bounds what the statement adds; 19 gates in total | 1 day | #8 |
| **CI on Linux and macOS** | Locking and the VFS are per-OS | 2–3 days | #13 |
| **Release packaging** — *done* | `scripts/package.py --check`, one archive per target with the version the library reports | 2–3 days | #23 |
| **Auth review** | Tokens, subscriptions, byte and work budgets under attack | 1 day | #24 |
| **Licence and notice review** | MIT/Apache-2.0, nothing vendored | external | #25 |

A round is done when `ci.py` is green **and** the baseline below did not regress.

## Efficiency contract and current baseline

The engine must stay **equal or better** than the reference model in every
measurable dimension. Measured on this tree:

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 50.264 /s (20k rows), 48.270 /s (50k) | not worse on the same hardware; 10% regression fails the gate |
| Read transaction | 10.7 µs over 50k rows, first read included | same |
| Freeze a 50k-row table | ~1 ms | same |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, one file left | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a written reason |
| Subscription delta | O(rows touched) | never a full re-evaluation |

If an item cannot meet a row, it does not land: the number is recorded and the
reason written down instead.

## What this costs

| Round | New engine lines (order of magnitude) |
|---|---|
| Priorities 1–7 | ~2.000 |
| Priorities 8–12 | ~12.000 |
| Priorities 13–17 | ~7.000 |
| Priorities 18–22 | ~12.000 |
| **Total** | **~33.000**, roughly doubling the tree |

## Closed already (for the record)

- **Benchmark gate** — `benchmarks/baseline.json` plus `scripts/bench.py --check`
  as a CI gate: bytes per row within 10%, insert rate, read cost and compaction
  under a 3x guard, with the machine recorded beside the numbers.
- **D18c broker mode** — one owner process, clients over HTTP wire messages,
  TCP frames and Postgres, with per-connection subscriptions; two-process proof in
  `scripts/broker_smoke.py`, including the refusal of a second owner.
- **D3 `AS OF`** — historical reads over the versions the table keeps, with
  pruning as the bound (`test_as_of`); the snapshot cost was already solved.
- **Sanitizer pass** — 190 tests run under `-sanitize:address` on Windows with no
  bounds or stack report; the heap half waits for the Linux CI, because Odin's
  allocator on Windows bypasses the sanitizer's interception (verified with a
  deliberate use-after-free).
- **D13 stored result** — the response is recorded with the request id and
  returned on a retry (`host_call_once_result`, `test_idempotent_result`).
- **D1 full-text ranking** — index on `term` created with the table, BM25
  `rank` (negated, best first), `snippet()`/`highlight()`, `AND`, and a scan
  narrowed to the matches measured by `rows_scanned`
  (`test_full_text_ranking`, `test_full_text_cost`). The shadow tables keep the
  document lengths and the corpus totals, so ranking never reads the documents.
- **D11 DDL inside a transaction** — index operations are part of the
  transaction: `DROP INDEX` without `ON` also finds an index created earlier in
  the same transaction, and two creates of one name are refused before apply
  (`test_ddl_in_transaction`).
- **D8 fault injection** — `Fault_Vfs` (open/read/write/seek/truncate/sync/remove,
  or a short write) and `test_fault_injection`, which arms the fault at every write
  of a workload and checks that the reopen sees only successful commits. A short
  write is now an error in the log, not a silent success.
- **D18a writer lock** — `<directory>/lock` held with an OS lock (Windows
  `LockFileEx`, POSIX `fcntl`), released on close and on death; the refusal names
  the owner (`test_writer_lock`, and `scripts/lock_smoke.py`, which opens the
  database from one process, is refused in another, and reopens after the owner is
  killed). `miraidb_errmsg(NULL)` reports the reason a failed open failed.

- **D7 scheduler durability** — `_schedule.at_us` is a column and commits; a
  restart resumes pending work (`test_durability_after_restart`).
- **D12a work budget** — one unit per row touched, a per-statement and a per-call
  budget that rolls the call back (`test_work_budget`).
- **D12b module latency** — one pooled socket per module, one frame each way.
- **D13 (partly)** — the request id commits with the effects; what remains is
  priority 7, returning the stored result.
- **D3 snapshot cost** — snapshots borrow values through a reference-counted
  store: freezing 50k rows costs ~1 ms
  (`test_snapshot_shares_values_safely`).
- **Audit corrections** — two items that had been written down as gaps (D7, D13)
  were already durable; the claim was wrong and the tests now prove the truth.
- **Metering unified** — one counter (`result.work`, `store.work_used`,
  `max_work_per_call`) instead of two parallel accounts.

## Rules that do not change

- A row moves onto this list only when its acceptance block is tests.
- Nothing is described as more than it is: no "ranked search" before BM25, no
  "pages on disk" before the buffer pool, no "multi-process" before the lock and
  the reader/writer split, no "replication" before the follower.
- Every round keeps `ci.py` green; an item that cannot land green waits.
