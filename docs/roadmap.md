# Roadmap: what is left, in the order it should happen

The feature matrix is closed (`docs/features.md`, 94 rows, 100/100). This file is
the plan for what comes next: the three capabilities a user needs before this is a
tool someone else can run, then the depth work from
[backlog.md](backlog.md), which holds the detail for every item named here.

Priority is set by what blocks real use, not by what is most interesting.

**Scope note.** End-user documentation (guide, SQL reference, tutorials) is
deliberately out of scope here: it is maintained outside this repository. This
file plans engine work only — features, their acceptance criteria and their
order.

## What is asked for, in one table

| Ask | Today | What "done" means | Effort | Depends on |
|---|---|---|---|---|
| **Access from several processes or connections** | Several *connections* to one host work (wire protocol, per-connection subscriptions). Several *processes* on one database do not: there is no lock, so two writers would corrupt it. | A second process cannot silently corrupt a database: either it is refused with a clear error (writer lock), or it talks to the owning process (broker). Reader/writer coexistence comes with the page store. | M → L | D18; the read-write split needs D17 |
| **FTS with a per-term index and BM25 ranking** | `MATCH` keeps an inverted table but resolves each pattern with one scan of the term table; there is no `rank`. | An index on the term column, `rank` computed from BM25 over document frequency and length, `snippet()`/`highlight()`, `AND` as an operator, and a query cost that follows matches instead of vocabulary. | M | D11 (index inside a transaction) |
| **Pages on disk instead of everything in RAM** | Every table is a `map[Row_Id]Row` in memory. The `.sqlite` mirror is a whole-state export per commit; native storage was never paged. | A buffer pool with a page size, pages allocated from a free list, eviction under a memory cap, a table's rows read through pages, and the log still able to recover what was not flushed. Indexes keep their own pages. | XL | D17, then D5 |

These three are **D18, D1 and D17**: the first and the third are the reason the
engine is a library for one process rather than a database a team can share, and
they are the largest pieces of work left.

## Phase 1 — make it safe to run beside something else (2–3 weeks)

Small items that protect everything built later.

| Item | Why now |
|---|---|
| **D8 fault injection** | Before pages and background flushes exist, prove that a failed write never leaves a third state. A VFS wrapper that fails the Nth write, over every N. |
| **D18a writer lock** | A second process that opens the same directory must be refused, not left to corrupt it. This is the honest minimum for "varios procesos" until the broker exists. |
| **D11 DDL inside a transaction** | `CREATE INDEX` cannot share a transaction with `CREATE TABLE`, which is the only reason D1 needs a scan. Remove the restriction, order the DDL, roll it back with the transaction. |
| **D1 FTS index + BM25** | With D11 in place, the term index is one line of DDL. BM25 needs document frequency and length, which the shadow table already has. |
| **D13 result replay** | An idempotent retry should return the stored result, not just "already ran". |
| **ASAN pass over CLI + soak + conformance** | The two real bugs in this project were memory bugs. Run the whole gate under the address sanitizer once and fix what it finds. |

Exit criteria: `ci.py` still 14/14, the lock test and the fault-injection matrix
pass, and `MATCH` on a million-token corpus no longer pays a vocabulary scan.

**Multiprocess acceptance.** Opening the same directory twice answers
`io`/`locked` naming the owning process; a read-only open beside a writer sees
only committed rows; broker mode serves two clients with independent
subscriptions from one owner, and killing a client does not disturb the other.

**FTS acceptance.** A rare term outranks a common one; a short document outranks
a long one at equal frequency; `rank` is computed from the index, not from a
document scan; `snippet()` marks the match; `AND`/`OR`/`NOT` parse as operators.

**Pages acceptance.** A table ten times the buffer pool reads correctly with RSS
under the configured cap; a kill during a dirty flush reopens to the last
committed state; `EXPLAIN` shows index pages being probed rather than a scan.

## Phase 2 — move rows out of RAM (6–10 weeks)

The largest single piece, and the one the ask "páginas en disco" really means.

1. **D17 native page store.** Fixed-size pages, a page file per table in the
   database directory (or one file with an allocation map), a buffer pool with a
   clock hand, dirty-page flushing, and a free list that survives a crash. The
   commit log stays the durability record: a page is written after the record
   that describes it, so recovery is "replay what the pages are missing".
   - Acceptance: a table larger than the buffer pool reads correctly; the RSS of
     a process reading a 1 GB table stays under the configured cap; killing the
     process mid-flush still opens to a consistent state (this is why D8 is
     Phase 1).
2. **D5 indexes on disk, then D6 planner with statistics.** Index pages only
   after table pages work; a cost model needs `ANALYZE` counts, which need a
   place to put them.
   **D4 (the `.sqlite` mirror) follows the same machinery**: once pages exist,
   the mirror writes only the pages a commit touched instead of re-encoding the
   whole state. Until then the mirror stays a documented O(state) export.
3. **D18b readers and writers in different processes.** With pages on disk and a
   lock, a reader can open the database read-only while a writer appends; this is
   where "varios procesos" becomes true rather than just safe.

Exit criteria: a database bigger than RAM works, `bench` and `bench-read` are
within 10% of today's numbers for data that fits in memory, and the fault
injection matrix passes with flushes enabled.

## Phase 3 — the rest of the surface (4–6 weeks)

| Item | What it adds |
|---|---|
| **D3 `AS OF` and GC** | Reading a past sequence, and collecting the versions no open reader can see. |
| **D9 grammar** | Window frames, windows beside `GROUP BY`, `WITH RECURSIVE` that recurses, full `ALTER`, `BEFORE` triggers and `WHEN`, more collations. |
| **D2 spatial tree** | Node pages and a descent, replacing the box scan. Needs D17. |
| **D10 precision and time** | Decimal arithmetic with scale, `TIMESTAMPTZ`, streaming blobs. |

## Phase 4 — sharing and ecosystem (6–10 weeks)

| Item | What it adds |
|---|---|
| **D18c broker mode** | One process owns the database, others connect over the existing wire protocol, with the same lock and byte caps as any client. This is the cheap answer for "varios procesos" and the one to prefer until Phase 2 lands. |
| **D14 replication** | `GET /log?since=<seq>`, a follower applying records through the replay path, tested against a lagging follower and a dead leader. Failover stays unclaimed. |
| **D12c module VM** | Deterministic execution with enforced memory and time. Until then modules are processes with a work budget and the caller's clock. |
| **D15 network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. |
| **D16 generated clients** | Emit the Python binding from the catalog; the hand-written one is the contract. |

## Reusing the engine's networking for D14

The engine this tool accompanies (now checked out as `mirai-engine`) already has
a networking library in the same language, Odin, so a follower does not have to
invent a protocol: it can import `net` and carry replicated commit records as its
messages. The package is about 12.000 lines across 48 files, and the parts that
matter are all there by name: `repl_peer_allocate`/`_connected`/`_disconnected`/
`_release`, the authority ops (`Authority_Request`/`_Grant`/`_Release`) as system
messages, `channel`, `clock`, `conditioner`, `baseline` and `pool`.

| Piece there | What it gives a follower |
|---|---|
| `channel` | datagrams delivered whole and in order, or not at all; a reliable channel and an unreliable one kept by the library itself |
| `replication` / `protocol` | the message set for peers and the rules for what is sent once and in what order |
| `baseline` + `collection` | "start from this state, then apply changes": our snapshot plus records after `seq` maps onto it directly |
| `clock` | ticks numbered alike on both ends, which is what makes applying a record deterministic |
| `peer` / `host` / `connection` | connection lifecycle, queues, and a full reliable queue refusing messages instead of dropping the connection |
| `conditioner` | simulated latency, jitter and loss: the test rig for a lagging or flapping follower |

What miraidb brings to the pair: the segmented log with CRC32C per record, the
replay path, and the snapshot with an offset index. What the engine brings: the
transport, the ordering guarantees and the test harness. The work in D14 is
mostly wiring the two: name a baseline, stream records after it, apply through
`commitlog`, and expose the last applied sequence.

## Engineering gates (parallel to every phase)

| Gate | Why | Effort |
|---|---|---|
| **Address sanitizer over CLI, soak and conformance** | The two real bugs in this project were memory bugs; run the whole gate under ASAN once per phase | 1 round per phase |
| **Crash injection matrix** (D8) | Proves the page store and the log never leave a third state; grows with every new write path | S, then extended |
| **Benchmark with thresholds** (`scripts/bench.py`) | Fail the build when inserts, reads or compaction regress more than 10% against the recorded baseline | 1 day |
| **CI on Linux and macOS** | Today the suite runs on Windows only; the VFS and the file locking are per-OS | 2–3 days |
| **Release packaging** | Versioned `libmiraidb` + header + `pkg-config`, binaries per platform, changelog | 2–3 days |
| **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each public release | external |
| **Auth review** | Tokens, connection-scoped subscriptions and the byte/work budgets, attacked deliberately | 1 day |

The rule for all of them: a phase is done when `ci.py` is green **and** the
measured numbers in the next section did not regress.

## Efficiency contract and current baseline

The engine must stay **equal or better** than the reference model in every
measurable dimension. What that means concretely, measured on this tree:

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 50.264 /s (20k rows), 48.270 /s (50k) | no worse than the reference on the same hardware; a 10% regression fails the gate |
| Read transaction | 10.7 µs over 50k rows, first read included | same |
| Freeze a 50k-row table | ~1 ms | same |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, leaves one file | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a documented reason |
| Subscription delta | O(rows touched) | never a full re-evaluation |

If a phase cannot meet a row of that table, it does not land; the number is
recorded and the reason written down instead.

## What this costs

| Phase | New engine lines (order of magnitude) |
|---|---|
| 1 | ~2.000 |
| 2 | ~12.000 |
| 3 | ~7.000 |
| 4 | ~12.000 |
| **Total** | **~33.000**, roughly doubling the tree |

## Closed already (for the record)

- **D7 scheduler durability** — the due time is a column of `_schedule` and
  commits: a restart resumes pending work (`test_durability_after_restart`).
- **D12a work budget** — one unit per row touched, a per-statement budget and a
  per-call budget that rolls the call back (`test_work_budget`).
- **D12b module latency** — one pooled socket per module, one frame each way.
- **D13 exactly-once** — the request id commits with the effects; what is left is
  returning the stored result instead of only skipping.
- **D3 snapshot cost** — snapshots borrow values through a reference-counted
  store: freezing 50k rows costs ~1 ms (`test_snapshot_shares_values_safely`).

## Where each item lives

| This file | Detail |
|---|---|
| Ask table (D1, D17, D18) | `docs/backlog.md` D1, D17, D18a/b/c |
| Phase 1 small items | D8, D18a, D11, D1, D13 |
| Phase 2 storage | D17, D5, D6, D4, D18b |
| Phase 3 surface | D3, D9, D2, D10 |
| Phase 4 sharing | D18c, D14, D12c, D15, D16 |
| Closed | D7, D12a, D12b, D13 (partly), D3 (snapshot cost) |

## Rules that do not change

- A row moves onto this roadmap only when its acceptance block is tests.
- Nothing is described as more than it is: no "ranked search" before BM25, no
  "pages on disk" before the buffer pool, no "multi-process" before the lock and
  the reader/writer split, no "replication" before the follower.
- Every phase keeps `ci.py` green; a feature that cannot land green waits.
