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
| 2 | **R2 — fixed-size index keys** | The index filters are under the reference since a key files its rows under one entry; an insert is 0.73–0.79× it with an index per column and 1.38–1.44× with one unique index. The write path by stage is in RESULTS.md (2026-11-25); its five candidates took inserts from 1.2–2.7× and updates from 2.6–2.8×, and resolving the table once per transaction (2026-11-26) the updates to 0.87× (u64) and 1.24× (str). The eight workloads at or under the reference are held under 1.10x of it by `scripts/parity.py`. Next: the unique insert and the str update, which are the index itself now. | M | — |
| 6 | **D12 — module sandbox** | A module is a process with a work budget; the reference runs modules deterministically with enforced limits. | L | — |
| 7 | **D16 — generated clients** | Deferred by months: generate the Python binding from the catalog, then a second language. Until then the C ABI, the `sqlite3_*` face and the Python wrapper stay gated, so a binding is a thin layer when it comes ([backlog](backlog.md#d16--clients-generated-from-the-catalog)). | M | — |

## B. SQLite's features

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 15 | **D4 — secondary indexes in the mirror** | A table with a secondary index re-encodes the `.sqlite` file per commit. | L | — |
| 16 | **D36 — partial and expression indexes in plans** | The planner skips them; match a predicate to a partial index's WHERE and an expression to its index. | M | 8 |
| 32 | **D37 — catching up with a shared file** | Five processes on one file run `multiwrite01` in a median 1.4× SQLite's time; reuse the parsed schema, explain the stalls, time it in CI. | S | — |
| 33 | **S8 — the rest of the C API** | 233 of SQLite's 309 functions are exported; 76 are left. | M | — |
| 34 | **D39 — PostgreSQL's surface** | A probe gate for the dialect, the catalog drivers and ORMs read, PostgreSQL's spelling of grants and policies. | L | — |
| 35 | **D40 — two writers** | A transaction holds the write lock until it commits; stage without it and conflict at commit. | L | — |

## C. Hardening and release

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 19 | **D34 — Linux suite and heap sanitizer** | The threaded suite is green on Linux and every script finds its binary; left is CI on Linux and macOS with `-sanitize:address` and the suite sanitized as a gate (the CLI already is, on Windows). | S | — |
| 22 | **D5 — the rest of the page store** | Leaf merge, versions on paged tables, a read without the shared lock for its whole life; with D18, a reader that trusts the pages. | L | — |
| 24 | **D2 — spatial tree** | Node pages and a descent instead of a scan over box columns. | M | — |
| 25 | **D10 — precision and time** | Decimal scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 27 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 28 | **D14 — replication** | `GET /log?since=<seq>` and a follower applying through replay. | XL | 27 |
| 29 | **Auth review** | Rate limits, token lifetime, adversarial tests over subscriptions and budgets; tokens travel in clear until TLS. Done: a server with credentials refuses anonymous clients on every front, and no client reaches the token key, the grants or its own identity (`docs/security.md`). | S | — |
| 30 | **Release and packaging** | `scripts/package.py` builds and checks one archive. Left: one archive per target, a version policy, a byte-for-byte reproducible build. | M | 19 |
| 31 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each release. | external | — |

After these, [versioning-plan.md](versioning-plan.md) proposes version control
with peer-to-peer sync; its networked phases build on items 27 and 28.

## Suggested order

1. **R2**: the largest gap left against the reference (inserts and updates),
   starting from a profile of the write path. The parity gate
   (`scripts/parity.py`) records its gain with `--record` so it cannot slip back,
   and holds a workload that reached the reference under 1.10x of it.
2. **S8**, then **D37**, **D4** and **D36**.
3. **D39**, then **D40**.
4. The disk workloads and the depth items of track C.
5. **D15, D14** and the release gates, in that order; **D34** when its image is
   ready.

## Efficiency contract and current baseline

The contract is that the engine stays **equal or better** than the reference
model in every measurable dimension. **It does not meet that today**: on the
reference's own suite ([RESULTS.md](../benchmarks/parity/RESULTS.md)) this engine
is at or under it on an empty transaction, the index filters and one of the two
256-row scans, at it on the other scan, and behind on the writes: inserts
0.76–1.6× in memory, updates 1.05–1.3×.
Track A is the plan to close it.

The rows below are this engine against its own recorded baseline, which is what
the CI gate checks; they are not a comparison with the reference.

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 46 838 /s on the 20k gate (baseline 42 219); 54 580 /s over 50k, run directly | not worse on the same hardware. CI fails on bytes per row (10%) only, and reports wall clock twice per run, because this machine alone moved a metric by 30x with no code change; `--strict-time` enforces 10% on a quiet machine |
| Read transaction, anyone reading | **1.5 µs** on the gate (20 000 rows, warm); opening one after a commit is **6.2 µs**: it copies nothing | costs one reference per table |
| Commit with a read open | **0.19 ms** over 50 000 rows (0.15 over 20 000): it shares the rows by block, the index trees by node and the arena with the reader, and copies what it writes (R7) | under 1 ms over 50 000 rows, a gate of `scripts/bench.py --check` |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, one file left | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a written reason |
| Join, inner side | a nested loop reads the inner rows its ON clause names (1 200 rows where a scan read 200 200) | O(rows the outer row matches) |
| Ordered read | `ORDER BY <index key>` walks the index; `LIMIT 5` reads five rows | an ordered query costs the rows it returns |
| Subscription delta | O(rows touched), for a join too: an equi-join is indexed by its key | O(rows touched) for the table the commit changed |

Every row of this table is met today and gated by `scripts/bench.py`, the read
and commit numbers by `bench-read`, and the subscription row by
`test_join_subscription_probes_the_join_key`. The engineering gates are listed in
`docs/status.md` and run by `scripts/ci.py` (41 gates).
