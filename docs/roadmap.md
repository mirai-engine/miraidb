# Roadmap: what is left, in priority order

This is the one list of open work. [backlog.md](backlog.md) carries the detail of
each item (today, cost, done when), [status.md](status.md) the measurements, and
[closing-plan.md](closing-plan.md) the record of everything already closed.

The project has two goals, and the open work is split by them, plus the
hardening a release needs:

- **A. The reference model, equalled or beaten.** The feature matrix is closed
  ([features.md](features.md), 101/101), so what is left on this axis is speed and
  depth: the reference's own benchmark suite still puts this engine behind on
  every workload but the empty transaction.
- **B. SQLite's features.** Measured by `scripts/sqlite_gaps.py` over every
  built-in function, every pragma and 63 grammar shapes, and kept honest by a CI
  gate; [sqlite-roadmap.md](sqlite-roadmap.md) states the counts.
- **C. Hardening and release.** What has to be true before a public release.

**Priority rule.** An item that removes a risk of a wrong answer outranks one
that adds a capability; an item another depends on outranks the dependent; a
release gate waits until what it releases is worth shipping. Every SQLite gap is
refused with a message today, never answered differently, so track B adds
capability without fixing wrong answers, and the differential runner keeps it
that way.

## A. The reference model

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 2 | **R2 — fixed-size index keys** | The index filters are under the reference since a key files its rows under one entry; an insert is 1.2–1.3× it with an index per column and 2.6–2.7× with one unique index, and an update 2.6–2.8×. The cost is spread over staging, maps, key encoding, the tree, the copy and the commit; the next step is a sampling profile of the write path. | M | — |
| 5 | **R7 — share a table with its readers** | A commit with a reader open copies the table it writes: 13–17 ms over 50 000 rows, mostly new memory being touched. | L | — |
| 6 | **D12 — module sandbox** | A module is a process with a work budget; the reference runs modules deterministically with enforced limits. | L | — |
| 7 | **D16 — generated clients** | Deferred by months: generate the Python binding from the catalog, then a second language. Until then the C ABI, the `sqlite3_*` face and the Python wrapper stay gated, so a binding is a thin layer when it comes ([backlog](backlog.md#d16--clients-generated-from-the-catalog)). | M | — |

## B. SQLite's features

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 15 | **D4 — secondary indexes in the mirror** | A table with a secondary index re-encodes the `.sqlite` file per commit. | L | — |
| 16 | **D36 — partial and expression indexes in plans** | The planner skips them; match a predicate to a partial index's WHERE and an expression to its index. | M | 8 |
| 17 | **D24 — the mirror's last gaps** | The fuzz against SQLite (`scripts/mirror_fuzz.py`) still finds an unreadable file after `ALTER` on a WITHOUT ROWID table, a wrong `UPDATE` through a DESC index, missing defaults and a crash; then it becomes a gate. | M | — |
| 32 | **D37 — catching up with a shared file** | Five processes on one file run `multiwrite01` in a median 1.4× SQLite's time; reuse the parsed schema, explain the stalls, time it in CI. | S | — |
| 33 | **S8 — the rest of the C API** | 233 of SQLite's 309 functions are exported; 76 are left. | M | — |
| 34 | **D39 — PostgreSQL's surface** | A probe gate for the dialect, the catalog drivers and ORMs read, PostgreSQL's spelling of grants and policies. | L | — |
| 35 | **D40 — two writers** | A transaction holds the write lock until it commits; stage without it and conflict at commit. | L | — |

## C. Hardening and release

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 18 | **D23 — allocation failure** | A failed allocation is a crash, not `.Out_Of_Memory`; start with an allocator that fails the nth call. | M | — |
| 19 | **D34 — Linux suite and heap sanitizer** | The threaded suite is green on Linux and every script finds its binary; left is CI on Linux and macOS with `-sanitize:address` and the suite sanitized as a gate (the CLI already is, on Windows). | S | — |
| 20 | **D8 — fault injection beyond the log** | Snapshot, rotation, the mirror, a kill during a page flush. | S | — |
| 21 | **D3 — version retention** | Automatic retention tied to the oldest reader; `AS OF` on a join. | M | — |
| 22 | **D5 — the rest of the page store** | Leaf merge, versions on paged tables, a read without the shared lock for its whole life; with D18, a reader that trusts the pages. | L | — |
| 23 | **D11 — triggers and policies in a transaction** | Order them against the rows of the same transaction. | S | — |
| 24 | **D2 — spatial tree** | Node pages and a descent instead of a scan over box columns. | M | — |
| 25 | **D10 — precision and time** | Decimal scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 27 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 28 | **D14 — replication** | `GET /log?since=<seq>` and a follower applying through replay. | XL | 27 |
| 29 | **Auth review** | Rate limits, token lifetime, adversarial tests over subscriptions and budgets; tokens travel in clear until TLS; **grants are opt-in**, so a database with no grant rows accepts every statement from every client. | S | — |
| 30 | **Release and packaging** | `scripts/package.py` builds and checks one archive. Left: one archive per target, a version policy, a byte-for-byte reproducible build. | M | 19 |
| 31 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each release. | external | — |

After these, [versioning-plan.md](versioning-plan.md) proposes version control
with peer-to-peer sync; its networked phases build on items 27 and 28.

## Suggested order

1. **D24, D11, D23, D8, D3** and the grants review: the ways the engine can
   still lose an index silently, answer from the wrong rows, die instead of
   answering, or keep every old value of an embedded database.
2. **R2**: the largest gap left against the reference (inserts and updates),
   starting from a profile of the write path. The parity gate
   (`scripts/parity.py`) records its gain with `--record` so it cannot slip back.
3. **S8**, then **D37**, **D4** and **D36**.
4. **D39**, then **D40**.
5. **R7**, the disk workloads and the depth items of track C.
6. **D15, D14** and the release gates, in that order; **D34** when its image is
   ready.

## Efficiency contract and current baseline

The contract is that the engine stays **equal or better** than the reference
model in every measurable dimension. **It does not meet that today**: on the
reference's own suite ([RESULTS.md](../benchmarks/parity/RESULTS.md)) this engine
is at or under it on an empty transaction, the index filters and one of the two
256-row scans, at it on the other scan, and behind on the writes: inserts
1.2–2.7× in memory, updates 2.6–2.8×.
Track A is the plan to close it.

The rows below are this engine against its own recorded baseline, which is what
the CI gate checks; they are not a comparison with the reference.

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 46 838 /s on the 20k gate (baseline 42 219); 54 580 /s over 50k, run directly | not worse on the same hardware. CI fails on bytes per row (10%) only, and reports wall clock twice per run, because this machine alone moved a metric by 30x with no code change; `--strict-time` enforces 10% on a quiet machine |
| Read transaction, anyone reading | **1.5 µs** on the gate (20 000 rows, warm); opening one after a commit is **6.2 µs**: it copies nothing | costs one reference per table |
| Commit with a read open | **7.2 ms** over 20 000 rows on the gate (4.4–4.7 ms on Windows; 13–17 ms over 50 000): it copies the table it writes and leaves the old one to the reader (R7) | the copy is the rows of the table written, and only while a reader is open |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, one file left | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a written reason |
| Join, inner side | a nested loop reads the inner rows its ON clause names (1 200 rows where a scan read 200 200) | O(rows the outer row matches) |
| Ordered read | `ORDER BY <index key>` walks the index; `LIMIT 5` reads five rows | an ordered query costs the rows it returns |
| Subscription delta | O(rows touched), for a join too: an equi-join is indexed by its key | O(rows touched) for the table the commit changed |

Every row of this table is met today and gated by `scripts/bench.py`, the read
and commit numbers by `bench-read`, and the subscription row by
`test_join_subscription_probes_the_join_key`. The engineering gates are listed in
`docs/status.md` and run by `scripts/ci.py` (38 gates).
