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
| 1 | **D18a — writer lock** | Today two processes on one directory corrupt each other silently. Nothing else matters until that is refused with a clear error. | S | — |
| 2 | **ASAN pass** over CLI, soak and conformance | The two real bugs in this project were memory bugs; the pass protects every later phase, and is cheapest before the page store exists. | 1 round | — |
| 3 | **D8 — fault injection** | A VFS wrapper that fails the Nth write proves the log never leaves a third state; the page store will need exactly this harness. | S | — |
| 4 | **Benchmark gate** (`scripts/bench.py`, 10% threshold) | Turns the efficiency contract below into a build failure instead of a good intention; must exist before performance work starts. | S | — |
| 5 | **D11 — DDL inside a transaction** | `CREATE INDEX` cannot share a transaction with `CREATE TABLE`; that single restriction is why full-text needs a scan. Unblocks #6. | S | — |
| 6 | **D1 — FTS term index + BM25** | A per-term index and real ranking: the first of the three asks, and the visible one. | M | D11 |
| 7 | **D13 — return the stored result on a retry** | Exactly-once currently skips a repeat call; a caller retrying after a lost response should get the same answer. | S | — |
| 8 | **D17 — rows on disk (page store)** | All tables are in RAM today. Buffer pool, page size, free list, eviction under a cap, flushes ordered after their commit record. The third ask, and the biggest piece. | XL | D8, bench |
| 9 | **D5 — persistent index pages** | Indexes are rebuilt on open; they become pages once tables are pages. | L | D17 |
| 10 | **D18b — a reader in another process** | With pages and a lock, a read-only open can coexist with a writer: "varios procesos" becomes true, not just safe. | L | D17, D18a |
| 11 | **D6 — planner with statistics** | `ANALYZE`, a cost model, join reordering; the largest query-level win and a prerequisite for calling the engine fast on real schemas. | L | D5 (statistics live in pages) |
| 12 | **D4 — `.sqlite` pages in place** | The mirror re-encodes the whole state per commit; with pages it writes only what changed. Until then it stays a documented O(state) export. | XL | D17 |
| 13 | **CI on Linux and macOS** | The suite runs on Windows only; file locking (D18a) and the VFS are per-OS, so the lock must be proven on all three. | M | D18a |
| 14 | **D3 — `AS OF` and version GC** | Reading a past sequence and collecting versions no open reader can see; the snapshot cost is already solved. | M | — |
| 15 | **D9 — the rest of the grammar** | Window frames, windows beside `GROUP BY`, real `WITH RECURSIVE`, full `ALTER`, `BEFORE` triggers and `WHEN`, more collations. Each current refusal becomes a test. | L | — |
| 16 | **D2 — spatial tree** | Boxes as columns today; node pages and a descent replace the scan. | M | D17, D5 |
| 17 | **D10 — precision and time** | Decimal arithmetic with scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 18 | **D18c — broker mode** | One process owns the database, the others speak the wire protocol to it; the cheap answer for multi-process and the one to prefer until #10 lands. | M | D18a |
| 19 | **D14 — replication** | `GET /log?since=<seq>`, a follower applying through the replay path, tested against a lagging follower and a dead leader; reuses the engine's `net` package. Failover stays unclaimed. | XL | D18c |
| 20 | **D12c — module VM** | Deterministic execution with enforced memory and time; today modules are processes with a work budget and the caller's clock. | L | — |
| 21 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 22 | **D16 — client generation from the catalog** | Emit the Python binding from the schema; the hand-written one is the contract it has to meet. | M | — |
| 23 | **Release packaging** | Versioned `libmiraidb` + header + `pkg-config`, binaries per platform, changelog. | M | #13 |
| 24 | **Auth review** | Tokens, connection-scoped subscriptions and the byte and work budgets, attacked deliberately. | S | — |
| 25 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each public release. | external | #23 |

Rounds map onto the list: **1–7** are one round of small, mutually unblocking
work; **8–12** are the storage round; **13–17** the surface round; **18–22** the
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
- **D5** (9): index pages, so opening a database stops rebuilding indexes.
- **D6** (11): `ANALYZE` statistics stored in pages, then a cost model and join
  reordering.
- **D4** (12): the `.sqlite` mirror writes touched pages instead of the whole
  state.
- **D18b** (10): the reader-in-another-process case that pages make possible.

**Acceptance.** A table ten times the buffer pool reads correctly with RSS under
the configured cap; a kill during a dirty flush reopens to the last committed
state; `bench` and `bench-read` stay within 10% for data that fits in memory;
`EXPLAIN` shows index pages being probed rather than a scan.

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
| **Address sanitizer** over CLI, soak and conformance | Memory bugs have been the real risk | 1 round per phase | #2 |
| **Fault injection** (D8) | Proves no third state after a failed write | S, then extended | #3 |
| **Benchmark with thresholds** | A 10% regression fails the build | 1 day | #4 |
| **CI on Linux and macOS** | Locking and the VFS are per-OS | 2–3 days | #13 |
| **Release packaging** | Versioned library, header, `pkg-config`, binaries, changelog | 2–3 days | #23 |
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
