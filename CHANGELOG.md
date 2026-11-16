# Changes

## 0.15

- Partial and expression indexes (the last of roadmap S1 but `ON CONFLICT` on a
  constraint): maintained, enforced when UNIQUE, persisted (index flag 4) and
  written into an exported `.sqlite` file that `PRAGMA integrity_check` accepts.
  The planner does not read them yet (D36). On the way: a UNIQUE column takes any
  number of NULLs, as SQL says; `CREATE UNIQUE INDEX` over rows that share a key
  is refused instead of silently dropping one from the index; `REPLACE` no
  longer reports a row it did not insert; `lower`, `upper`, `replace`, `instr`,
  `sign`, `sqrt` and `printf` give NULL for NULL; and an export writes constant
  DEFAULTs.

- SQLite's surface, roadmap S1 and S2 (grammar shapes measured by
  `scripts/sqlite_gaps.py`: 30 of 63 before, 47 now):
  - `CHECK` constraints (column and table, named or not, on every write path),
    `CONSTRAINT <name>`, a column's `REFERENCES`, `DEFERRABLE INITIALLY DEFERRED`
    foreign keys checked at COMMIT, `CURRENT_TIMESTAMP`/`_DATE`/`_TIME`, a
    `DEFAULT` that calls a function evaluated per row, and `ASC`/`DESC` on index
    and key columns. They live in a new optional section of the schema encoding
    (`docs/file-format.md`), travel into an exported `.sqlite` file and are read
    back from an imported one.
  - `IS`/`IS NOT` between values, `IS [NOT] DISTINCT FROM`, `& | ~ << >>`, `->`
    and `->>`, `LIMIT a, b`, `INSERT OR IGNORE/FAIL/ROLLBACK`, `REPLACE INTO`,
    `INTERSECT`, `EXCEPT`, `NULLS FIRST/LAST`, subqueries and `VALUES` in
    `FROM`, `VALUES` as a statement, and row values.
  - Left: partial and expression indexes, and `UPDATE OR <resolution>`.
- Wrong answers found and fixed on the way: a statement that failed inside a
  transaction kept the rows it staged before the failing one (a per-statement
  undo log now takes it back whole, SQLite's ABORT); a `UNION` anywhere in a
  compound deduplicated the whole result; a CTE's name stayed bound for the rest
  of a transaction, hiding a table of that name; an `ORDER BY` expression that
  failed (a misspelt column, a window function) sorted as NULL instead of failing
  the statement; and JSON object keys were matched without case.
- A commit read its own freed transaction: `tx_commit` cleared
  `apply_validated` in a `defer` through `tx.store`, after `tx_discard` had freed
  `tx`. When the heap reused the block, the process died with no message, about
  once in ten commits (the differential gate's setup hit it intermittently).
  Introduced by the write-path round above, found with AddressSanitizer once
  `windows_hook_rtl_allocators=true` let it see Odin's heap on Windows, and
  guarded by a new gate, `scripts/asan_smoke.py`, which builds the CLI sanitized
  and replays the differential corpus (27 gates).
- The planning documents are one list again. `docs/roadmap.md` holds every open
  item, split by goal: speed against the reference model (R1–R4, measured by its
  own benchmark suite), SQLite's surface (S1–S7) and hardening (the D items).
  `docs/backlog.md` keeps only open items; what closed, with its evidence, is in
  `docs/closing-plan.md` (formerly `pending.md`, which held nothing pending).
  `docs/sqlite-roadmap.md` was rewritten from a measurement: it listed CTEs,
  savepoints, windows and JSON as missing long after they landed.
- `scripts/sqlite_gaps.py` runs every SQLite function and pragma and 63 grammar
  shapes through the CLI: 73 of 121 functions, 54 of 63 pragmas and 30 of 63
  shapes run today. A CI gate fails when `docs/sqlite-roadmap.md` states other
  counts, so the document cannot drift again (27 gates).
- `docs/security.md` no longer says a deep expression takes the server down: the
  depth bound closed that; an allocation failure still can (D23).

- PostgreSQL clients work for real. The server framed its input by TCP read, so a
  driver's pipelined Parse/Bind/Describe/Execute/Sync lost everything after Parse
  and hung; reusing a statement name freed a slice of the network buffer and
  killed the process; no `client_encoding` was sent, which crashed psycopg's C
  build; and `Execute` repeated a RowDescription whose types disagreed with
  `Describe`. All four are fixed, and a connection now keeps a transaction across
  messages (with PostgreSQL's aborted state), runs several statements per Query,
  sends command tags and SQLSTATE codes, and answers `DEALLOCATE`/`DISCARD`.
- The PostgreSQL dialect an ORM sends first: `x::type`, `SERIAL`, identity
  columns, `$n` parameters, PostgreSQL's type names (`VARCHAR(n)`, `DOUBLE
  PRECISION`, `TIMESTAMP WITH TIME ZONE`, `JSONB`, `NUMERIC(p, s)`, …),
  `information_schema.tables`/`columns`, `pg_catalog.pg_tables`, `public.t`, and
  `version()`, `current_database()`, `current_user`, `current_schema`.
- Full-text search takes phrases (`"a b"`), prefixes (`foo*`) and column filters
  (`body:foo`), with no change to the index format.
- A transaction reuses an emptied arena instead of mapping a new one: an empty
  write transaction fell from 14.4 to 0.7 us. Rows collected in row-id order are
  sorted by a typed introsort instead of `slice.sort_by`, which copied both
  80-byte rows into every comparison: iterating 256 rows fell from 70 to 15 us.
- The write path does less: a commit sorts its row ids with the typed sort,
  clones nothing for a commit hook nobody registered, encodes no payload for a
  store without a log, and does not probe an insert's unique keys a second time
  when its own commit applies it; a table name joins the read set once, and a
  unique key is encoded into the transaction arena and checked by walking the
  index in place. 256 inserts fell from 1 645 to 762 us and 256 updates from
  2 339 to 1 142 us (in memory, `benchmarks/parity`).
- A transaction remembers whether `_grant` and `_trigger` exist and which table
  its last insert resolved, and resets both on any catalog change or savepoint
  rollback; the unique keys a check encodes are the ones it registers; index keys
  are encoded into a per-table buffer. 256 inserts: 762 to 681 us.
- A table keeps an ordered list of its row ids beside its map, maintained by
  the writers only, so a scan walks it and returns rows sorted without visiting
  empty map slots or sorting: 256 rows fell from 15 to 4.6 us. `row_ids_sort`
  no longer borrows the temp allocator on every commit.
- `benchmarks/parity` runs the reference database's own benchmark suite
  (schemas, generator, sizes) against this engine.
- The differential and compatibility gates read SQLite through Python's module
  and decode the CLI's output as UTF-8, so they no longer report the `sqlite3`
  shell's number formatting, or the Windows code page, as differences.

- The first packaged release: the engine, the CLI, the server, the shared
  library with its header, and the Python binding over the C ABI.
- Append-only commit log with CRC32C per record, snapshots, compaction and a
  segmented log; ACID transactions with one writer and many readers.
- SQL with joins, aggregates, window frames, policies, triggers, `AS OF`,
  full-text search with BM25 ranking, spatial tables and attached `.sqlite`
  reads. `IN` and `NOT IN` keep SQL's three-valued logic when the list holds a
  `NULL`: a non-match is unknown, so `NOT IN` does not return rows it cannot
  decide. `DISTINCT` inside an aggregate is honoured instead of parsed and
  dropped, so `count(DISTINCT x)` counts each value once. `ORDER BY` breaks ties
  by row id, so a query with equal keys answers the same sequence every run;
  `min`/`max` with two or more arguments compare their arguments, and
  `trim`/`ltrim`/`rtrim` take a set of characters.
- `scripts/differential.py` runs one schema, one set of rows and 55 queries
  through this engine and the system `sqlite3` and fails when the answers
  differ; the statements this engine refuses, and the four semantic decisions
  that differ on purpose, are listed in the script. `miraidb sql --json` exists
  so the comparison reads values instead of scraping a table.
- `CASE`, in both forms, wherever an expression is allowed; `GROUP BY` does not
  resolve a projection alias yet, and the differential runner records that
  refusal so it fails the gate the day it works.
- One owner per database directory (OS lock), and a broker that serves other
  processes over HTTP, WebSocket frames and Postgres.
- A join subscription indexes the key of its equi-join, so a commit probes the
  matches instead of walking the joined tables: over 200 authors and 900 books an
  insert visits one candidate and a base-row change six, where it used to read
  200 and 900. A join that cannot be indexed (an expression key, two types, a
  `FLOAT` key, a paged table) falls back to the full evaluation.
- A join subscription walks the tables it reads instead of copying every row of
  them into the transaction arena, which was 80 bytes a row per commit.
- `BEFORE` triggers work: the body runs while the row is still only proposed, so a
  statement in it that fails stops the write and takes its own effects with it, and
  `WHEN` still decides whether it fires. The log a `BEFORE`/`AFTER` pair writes is
  the one `sqlite3` writes, in the same order.
- `RANGE` and `GROUPS` window frames work, with offsets measured either in peer
  groups or in the `ORDER BY` value (`OVER (ORDER BY n RANGE BETWEEN 10 PRECEDING
  AND 10 FOLLOWING)`). A `RANGE` offset needs one numeric ordering term; a text one
  is refused rather than given an interpretation. Answers are checked against
  `sqlite3`, including a descending frame and a partitioned one.
- `JOIN b USING (c, …)` is accepted: it is the equality the planner already knows,
  and `SELECT *` prints the merged column once, from the left relation, while `b.*`
  still lists every column. Four queries joined the differential runner and one of
  its documented refusals is gone.
- `SELECT *` lists the columns of a join in the order the query wrote them. It used
  to expand them from the relation the plan started at, so a reordered join printed
  the other table's columns — found through the `USING` work, where the fixture names
  a column and a table the same.
- The join order is searched by cost instead of grown greedily: the planner prices a
  step that probes an index as a probe (a row a join step produces costs eleven
  times a fetched row: 5.1 µs measured) and refuses to run a relation before the
  `ON` that filters it can be answered, which is what made `FROM a JOIN b JOIN c`
  bind the two unjoined relations first and multiply them.
- `GROUP BY` resolves a projection alias, so `SELECT dept AS d ... GROUP BY d`
  groups by what the projection names; a name that is a column of a source still
  means the column.
- A join subscription indexes its walk with the order the planner chooses for the
  same query and keeps it, so `big JOIN small` written big-first walks the small
  relation and probes the big one. `SELECT *` still expands its columns in the
  written order.
- A range written as two comparisons is priced and answered as one: `v >= a AND
  v < b` now costs what `v BETWEEN a AND b` costs, one range scan over the band,
  instead of two independent filters that lost to a scan.
- The planner's cost constants are measured instead of assumed: over a 200 000-row
  table a scan row costs 100.8 ns, a row fetched through an index 456.3 ns and one
  descent through the tree 600 ns, so `PLAN_SCAN_ROW` is 1, `PLAN_INDEX_ROW` 4.5 and
  `PLAN_PROBE` 6, with the measurement written beside them.
- `ORDER BY` on a column set that is exactly an index key walks that index instead
  of sorting: 137 ms against 342 ms over 50 000 rows, and `ORDER BY id LIMIT 5`
  reads five rows in 4.6 ms where the sort took 115 ms. A filter keeps the full
  pass, because it is applied after the walk and could leave the answer short.
- A nested loop probes the index of the inner table when the ON clause binds a
  column that leads it, so a join reads the rows one outer row matches instead of
  the whole relation per outer row: 200 authors and 1 000 books read about 1 200
  rows where the scan read 200 200. `EXPLAIN` prints the index it probes.
- A view in `FROM` is priced from the relation its own query reads, and `EXPLAIN`
  says where that number came from rather than pricing the view at zero rows.
- A prepared statement is priced with the parameters it was given, so `n < ?`
  bound to 50 keeps the estimate and the access decision `n < 50` gets instead of
  falling back to a third of the table.
- `EXPLAIN` ends with the age of the numbers it priced the plan with:
  `note: statistics measured at commit N, data at commit M`, or a note that nothing
  was ever measured, so an estimate never passes for a measurement.
- A result row now always owns its text. `EXPLAIN`, `DESCRIBE` and `SHOW` handed a
  read-only literal to a caller that frees what it gets, which the debug allocator
  reported as a bad free (and which could abort a release build on Windows).
- A read transaction copies nothing: it takes one reference per table, and a
  commit that has to change a table a reader holds copies that table first, so
  the cost is per written table and only while a reader is open. Opening a read
  after a commit fell from 24 ms to 38 µs on the gate (21 µs over 50 000 rows);
  the commit that pays for a live reader is 16.9 ms over 20 000 rows. The store's
  read cache is gone with it, and so is the copy of every index tree it took.
  `bench-read` reports the read and the commit that pays for a live reader
  separately, and the gate watches both.
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
- A database opened from a `.sqlite` file is still kept a valid SQLite database,
  but a commit now patches the pages it touched instead of re-encoding the whole
  file: the leaf of every changed row, the separator its parent stores and the
  header — three pages, 12 KiB, at 10k, 100k and 250k rows, where the old export
  wrote 172 KiB, 1.8 MB and 4.8 MB. Splits, empty-leaf unlink, free-list reuse, a
  new root when one fills, and a rollback journal in SQLite's own format (so an
  interrupted commit is undone by this engine or by SQLite) are covered by tests;
  `scripts/mirror_cost.py --check` is the gate and verifies the file with real
  `sqlite3`. `PRAGMA stats` reports `mirror_pages` and `mirror_rewrites`, and
  `miraidb sql --mirror-report` prints them.
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
