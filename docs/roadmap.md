# Roadmap: what is left, in priority order

This is the one list of open work. [backlog.md](backlog.md) carries the detail of
each item (today, cost, done when), [status.md](status.md) the measurements, and
[closing-plan.md](closing-plan.md) the record of everything already closed.

The project has two goals, and the open work is split by them, plus the
hardening a release needs:

- **A. The reference model, equalled or beaten.** The feature matrix is closed
  ([features.md](features.md), 97/97), so what is left on this axis is speed and
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
| 1 | **R1 — rows stored in id order** | Rows in a map keyed by id make a 256-row scan 2.8–3.1× the reference and put a map insert in every staged row. Store them contiguously in id order. | L | — |
| 2 | **R2 — fixed-size index keys** | Index entries are encoded strings: an index filter is 3–4× the reference and the entry is the largest share of applying a row. Key integer columns by value. | M | — |
| 3 | **R3 — prune what a commit touched** | Pruning walks every row of every table after each statement. | S | — |
| 4 | **R4 — hand the staged row to the table** | About 4% of an insert is a copy from the arena to the table. | M | 1 |
| 5 | **Parity gate** | `scripts/bench.py` gates the parity workloads, measured twice per run, so a regression against the reference fails CI. | S | — |
| 6 | **D12 — module sandbox** | A module is a process with a work budget; the reference runs modules deterministically with enforced limits. | L | — |
| 7 | **D16 — generated clients** | Generate the Python binding from the catalog, then a second language. | M | — |

## B. SQLite's features

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 8 | **S1 — the schema real files declare** — *done but one* | Done: `CHECK`, `CONSTRAINT` names, column `REFERENCES`, deferred foreign keys, `ASC`/`DESC` columns, `CURRENT_TIMESTAMP` and per-row defaults, partial and expression indexes, many NULLs in a UNIQUE column. Left: `ON CONFLICT` on a constraint. | S | — |
| 9 | **S2 — statement and expression forms** — *done but one* | Done: `IS` values, `IS DISTINCT FROM`, bitwise operators, `->`/`->>`, `LIMIT a, b`, `INSERT OR IGNORE/FAIL/ROLLBACK`, `REPLACE INTO`, `INTERSECT`/`EXCEPT`, `NULLS FIRST/LAST`, derived tables and `VALUES`, row values; a failed statement is undone whole inside a transaction. Left: `UPDATE OR <resolution>`. | S | — |
| 10 | **S3 — joins** | `NATURAL` (the shared columns are known only when the tables are resolved). | S | — |
| 11 | **S4 — aggregates and windows** | `FILTER`, the `WINDOW` clause, `ORDER BY` inside an aggregate, `median` and the percentiles, `json_group_array`/`_object`. | M | — |
| 12 | **S5 — functions** | 39 missing: hyperbolic math, `timediff`, `soundex`, `unistr`, planner hints, introspection, the rest of JSON and the `jsonb_*` family. | M | — |
| 13 | **S6 — statements and pragmas** | `EXPLAIN QUERY PLAN`, `REINDEX`, `INSTEAD OF` triggers, `INDEXED BY`, `generate_series`, `VACUUM`/`ATTACH` in memory, 9 pragmas. | M | — |
| 14 | **S7 — affinity and `WITHOUT ROWID`** | `ANY` columns exist; left: an untyped column, SQLite's affinity rules, comparison across storage classes (refused today), `WITHOUT ROWID` as a write target. | L | — |
| 15 | **D4 — secondary indexes in the mirror** | A table with a secondary index re-encodes the `.sqlite` file per commit. | L | — |
| 16 | **D36 — partial and expression indexes in plans** | The planner skips them; match a predicate to a partial index's WHERE and an expression to its index. | M | 8 |
| 17 | **D24 — the mirror's last gaps** | A counted skip for an index the engine cannot express, and a mirror fuzz pass. | S | 8 |

## C. Hardening and release

| # | Item | What is left | Effort | Depends on |
|---|---|---|---|---|
| 18 | **D23 — allocation failure** | A failed allocation is a crash, not `.Out_Of_Memory`; start with an allocator that fails the nth call. | M | — |
| 19 | **D34 — Linux suite and heap sanitizer** | The threaded suite crashes on Linux; then CI on Linux and macOS with `-sanitize:address`, the suite sanitized as a gate (the CLI already is, on Windows), and scripts that find a binary without `.exe`. | M | — |
| 20 | **D8 — fault injection beyond the log** | Snapshot, rotation, the mirror, a kill during a page flush. | S | — |
| 21 | **D3 — version retention** | Automatic retention tied to the oldest reader; `AS OF` on a join. | M | — |
| 22 | **D5 — the rest of the page store** | Leaf merge, versions on paged tables, a read without the shared lock for its whole life; with D18, a reader that trusts the pages. | L | — |
| 23 | **D11 — triggers and policies in a transaction** | Order them against the rows of the same transaction. | S | — |
| 24 | **D2 — spatial tree** | Node pages and a descent instead of a scan over box columns. | M | — |
| 25 | **D10 — precision and time** | Decimal scale, `TIMESTAMPTZ`, streaming blobs. | M | — |
| 26 | **D35 — diagnostics** | Map nodes freed through the wrong allocator, error ownership across the API, a file open per commit for the log index. | M | 19 |
| 27 | **D15 — network hardening** | TLS, HTTP/2, backpressure, per-route timeouts, a load test. | M | — |
| 28 | **D14 — replication** | `GET /log?since=<seq>` and a follower applying through replay. | XL | 27 |
| 29 | **Auth review** | Rate limits, token lifetime, adversarial tests over subscriptions and budgets; tokens travel in clear until TLS; **grants are opt-in**, so a database with no grant rows accepts every statement from every client. | S | — |
| 30 | **Release and packaging** | `scripts/package.py` builds and checks one archive. Left: one archive per target, a version policy, a byte-for-byte reproducible build. | M | 19 |
| 31 | **Licence and notice review** | MIT/Apache-2.0 with no vendored third-party source; confirm before each release. | external | — |

After these, [versioning-plan.md](versioning-plan.md) proposes version control
with peer-to-peer sync; its networked phases build on items 27 and 28.

## Suggested order

1. **The two leftovers of S1 and S2**, both small: `ON CONFLICT <resolution>` on
   a constraint, and `UPDATE OR <resolution>`.
2. **R1 and R2**: the two largest gaps against the reference, measured, with the
   parity gate (item 5) landing alongside so the gain cannot slip back.
3. **D36**: let the planner read partial and expression indexes, which are
   enforced today but never read.
4. **D23 and D34**: the two remaining ways the process can die instead of
   answering.
5. **S3 to S6**, then **R3/R4**: the rest of the visible surface and the smaller
   speed items.
6. **S7**, **D4/D24**, and the depth items of track C.
7. **D15, D14** and the release gates, in that order.

## Efficiency contract and current baseline

The contract is that the engine stays **equal or better** than the reference
model in every measurable dimension. **It does not meet that today**: on the
reference's own suite ([RESULTS.md](../benchmarks/parity/RESULTS.md)) this engine
is ahead on an empty transaction (0.50 µs against 0.62) and behind everywhere
else: writes 1.6–2.9× in memory, a 256-row scan about 3×, an index lookup 3–4×.
Track A is the plan to close it.

The rows below are this engine against its own recorded baseline, which is what
the CI gate checks; they are not a comparison with the reference.

| Dimension | Baseline today | Contract |
|---|---|---|
| Insert throughput | 46 838 /s on the 20k gate (baseline 42 219); 54 580 /s over 50k, run directly | not worse on the same hardware. CI fails on bytes per row (10%) only, and reports wall clock twice per run, because this machine alone moved a metric by 30x with no code change; `--strict-time` enforces 10% on a quiet machine |
| Read transaction, anyone reading | **10.7 µs** over 50k rows warm; opening one after a commit is **38 µs** on the gate (21 µs over 50 000 rows): it copies nothing | costs one reference per table |
| Commit with a read open | **16.9 ms** over 20 000 rows, **46 ms** over 50 000: it copies the table it writes and leaves the old one to the reader | the copy is the rows of the table written, and only while a reader is open |
| Commit record | one record, CRC32C, group commit | durability never traded for speed silently |
| Compaction | 0.48 s for 50k rows, one file left | same |
| Memory per row | `Row` 80 B, `Value` 24 B | no growth without a written reason |
| Join, inner side | a nested loop reads the inner rows its ON clause names (1 200 rows where a scan read 200 200) | O(rows the outer row matches) |
| Ordered read | `ORDER BY <index key>` walks the index; `LIMIT 5` reads five rows | an ordered query costs the rows it returns |
| Subscription delta | O(rows touched), for a join too: an equi-join is indexed by its key | O(rows touched) for the table the commit changed |

Every row of this table is met today and gated by `scripts/bench.py`, the read
and commit numbers by `bench-read`, and the subscription row by
`test_join_subscription_probes_the_join_key`. The engineering gates are listed in
`docs/status.md` and run by `scripts/ci.py` (29 gates).
