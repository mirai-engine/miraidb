# Changes

## 0.15

- The first packaged release: the engine, the CLI, the server, the shared
  library with its header, and the Python binding over the C ABI.
- Append-only commit log with CRC32C per record, snapshots, compaction and a
  segmented log; ACID transactions with one writer and many readers.
- SQL with joins, aggregates, window frames, policies, triggers, `AS OF`,
  full-text search with BM25 ranking, spatial tables and attached `.sqlite`
  reads.
- One owner per database directory (OS lock), and a broker that serves other
  processes over HTTP, WebSocket frames and Postgres.
- Tables on disk: a page file per table with a buffer pool, a free list, a
  fault-tested flush order, and a query pipeline that streams a single-table
  scan without holding the table in memory. Off by default; `--paged` turns it
  on.
- `ANALYZE [table]`: row counts, per-column distinct/NULL counts, the numeric
  range and a sixteen-bucket histogram are measured once and kept in `<db>/stats`.
  The planner prices a scan against an index probe and prints `est. N rows,
  cost C` in `EXPLAIN`; a range reads the histogram (50 of 400 rows for
  `amount < 50`, not the one-third rule's 133) and a predicate that keeps most of
  the table reads the rows instead of collecting that many ids.
- Planned join order: a nested-loop join runs the relation that keeps the fewest
  rows per outer row first, and every ON condition travels with the step that
  completes the relations it names, so a relation may run before the join it was
  written with. LEFT joins, `AS OF` and table functions keep the written order.
- `NATURAL`, `RIGHT` and `FULL` joins are refused at parse time. They used to be
  read as an alias for the preceding table, which silently turned the first into
  a cross join and the other two into inner joins — a wrong answer that returned
  rows. `JOIN … USING (col)` was already refused; `LEFT [OUTER]`, `INNER`,
  `CROSS` and the comma form keep working.
- `scripts/plan_check.py` is the twentieth CI gate: it fails when a known-good
  plan (point lookup, wide predicate, range estimate, join order, the row counter
  behind them) regresses.
- A paged database opens without replaying: `<db>/catalog` holds every schema and
  the counters, the log index names the last record, and the open trusts the page
  files only when all three sequences agree; a missing, stale or torn catalog
  falls back to the replay, which is what every open did before. Opening 60k
  rows now peaks at 6.4 MiB instead of 33.9 MiB.
- The log offset index was never usable for a database created by this build: its
  sidecar was created without the header every lookup validates, so replay always
  scanned. It is created with its header now, and the trusted open depends on it.
- A reader beside the writer: `--read-only` opens a database another process is
  writing, answers from the log it replays into memory, refuses every write and
  keeps compaction waiting. The lock has two roles now, so readers join and a
  second writer is still refused.
- Memory: a subscription path freed transaction-allocated slices with the
  caller's allocator, and several tests closed a store twice. The tracking
  allocator reported 3058 bogus frees; it reports 44 now, with the rule written
  down in `docs/architecture.md` ("Who frees a value").
- Indexes on disk: each index of a paged table is a B+tree of 4 KiB pages with
  its own pool, leaves chained in key order, and a cursor that walks a range
  without a parent stack. The keys stop living in RAM, and `page_rss.py` checks
  the index file grows with the rows while the statement cost does not.
