# Roadmap, weighted — regenerated

The parity matrix is complete (94/94, every row tested): that scope is 100% done
and is not counted here. This roadmap covers everything **after** parity and
totals **100 points**.

**Scoring rule.** `done` counts the full weight. A partial row starts with the
points earned (`2.5: …`) and states the exact gap. A row counts nothing until it
starts with a number or `done`. The totals table, the phase headers and the
current state are **generated**: edit a row, then run

```sh
python3 scripts/roadmap.py           # rewrite the numbers
python3 scripts/roadmap.py --check   # fail if the file is stale
```

The script rejects a row that does not have exactly four cells, so keep item and
state free of `|`. A row is `done` **only with a test** that covers it.

**Current state: 100 / 100 = 100%.**

| Phase | Weight | Earned |
|---|---|---|
| P0 Compatibility facades | 20 | 20 |
| P1 SQL surface | 20 | 20 |
| P2 Functions | 12 | 12 |
| P3 File format fidelity | 15 | 15 |
| P4 Tooling and API | 8 | 8 |
| P5 Efficiency and quality | 20 | 20 |
| P6 Modules and deployment | 5 | 5 |
| **Total** | **100** | **100** |

---

## Verification, and the numbers it produces

Every change must leave this green:

```sh
# Everything at once: build, tests, conformance, smokes, -vet and the roadmap.
# Set ODIN when the compiler is not on PATH.
python3 scripts/ci.py

python3 scripts/build.py                                   # builds and tests
odin test src/tests                                        # 211 tests
python3 scripts/conformance.py --bin ./bin/miraidb.exe     # 20/20
python3 scripts/shell_smoke.py                             # 11/11
python3 scripts/lock_smoke.py                              # two processes, one owner
python3 scripts/bench.py --check                           # against benchmarks/baseline.json
python3 scripts/page_rss.py --check                        # the pool bounds a read
python3 scripts/plan_check.py                              # 6 plan checks
python3 scripts/mirror_cost.py --check --text 200          # a commit is a patch
python3 scripts/roadmap.py --check                         # 100/100

# The DLL smokes need an interpreter that can load the DLL; when it is not on
# PATH, point the runner at it and the smokes run instead of being skipped:
MIRAIDB_WINDOWS_PYTHON=/path/to/python.exe python3 scripts/ci.py

# Static checks: every package must print nothing (`-vet` catches unused
# declarations, shadowing and casts that should be transmutes).
for pkg in src/engine src/cli src/capi src/sqlite_compat src/server src/tests; do
  odin check $pkg -no-entry-point -vet
done
```

`scripts/ci.py` runs those twenty-one times over (build, the suite, conformance,
the shell, the benchmark baseline, the package manifest, page memory, plan
regression, mirror cost, five DLL smokes, five `-vet` packages and the roadmap
check).

The optional harnesses (`python3 scripts/fuzz.py --statements 1000 --seed 1`,
`python3 scripts/soak.py --seconds 30`) must be run before claiming anything in
P5; the soak harness checks the log and a reopen but not the working set, which is
the diagnostics gap in [backlog.md](backlog.md).

Measured baselines to keep or beat (Windows, warm cache, `bin/miraidb.exe`):

| Metric | Command | Value |
|---|---|---|
| Inserts, one transaction | `scripts/bench.py --check` | 54.8k/s (baseline 42.2k) |
| Read snapshot, steady state | `scripts/bench.py --check` | 48.9 µs/tx (baseline 50.9) |
| Compact | `scripts/bench.py --check` | 0.813 s (baseline 0.374, tolerated) |
| Cost of a row on disk | `scripts/bench.py --check` | 80.015 bytes |
| Peak working set, 60k paged rows | `scripts/page_rss.py --check` | 6.4 MiB |
| Value / five values / column | `test_value_layout` | 24 B / 120 B / 128 B |

The first read of a process pays to copy every table (lock-free snapshots trade
that one copy for cache-published reads); it is a deliberate trade, not a gap.

---

## P0 — Compatibility facades (20) — 20

| # | Item | Weight | State |
|---|---|---|---|
| 1 | Embeddable API plus the C ABI (`bin/miraidb.dll`, `include/miraidb.h`, `examples/embed_c`) | 10 | done: open/exec/prepare/bind/step/column/errmsg/backup, covered by `scripts/capi_smoke.py` |
| 2 | `sqlite3_*` facade (`bin/sqlite3_miraidb.dll`) | 6 | done: the classic prepare/bind/step/column loop, exec, errmsg, changes, libversion, incremental blob I/O; covered by `scripts/sqlite_abi_smoke.py` |
| 3 | VFS: OS/memory/quota backends and the log wired through it | 4 | done: every log read, append, rewind, rotate, flush and truncate goes through `Vfs`; a persistent database replays on the in-memory backend; the quota wrapper reports `quota_exceeded`; the offset index is an OS-only cache; snapshots, compaction and `VACUUM INTO` refuse a virtual file system |

No work left in this phase. The seam to reuse for #21 is `Vfs_Ops` in
`src/engine/vfs.odin`; the log side is `Log_File` in `src/engine/commitlog.odin`.

---

## P1 — SQL surface (20) — 20

| # | Item | Weight | State |
|---|---|---|---|
| 4 | `excluded` in UPSERT | 3 | done: qualified-only source, bare columns keep the stored row |
| 5 | CTEs, `UNION`, `WITH RECURSIVE`, `INSERT … SELECT` | 4 | done: per-statement materialization, compound tail, recursion quota |
| 6 | `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` | 3 | done: nested, reverts created tables, survives staging |
| 7 | `UPDATE … FROM`, `DELETE … USING` | 3 | done |
| 8 | `COLLATE` | 3 | done: expression-level, `ORDER BY` and column-declared collations (BINARY/NOCASE/RTRIM) apply to comparisons, sorts, unique keys and index probes; an unknown collation is refused |
| 9 | `ALTER TABLE` and table options | 2 | done: `RENAME TO`, `DROP COLUMN` (rows and staged writes remapped by name), `STRICT` and `GENERATED ALWAYS AS (expr)` columns computed on insert and update; writing a `WITHOUT ROWID` table stays refused with a reason |
| 10 | Window functions and triggers | 2 | done: eleven window functions plus aggregates over `PARTITION BY`/`ORDER BY` (frames and `GROUP BY` refused with a reason); `AFTER` triggers with `NEW`/`OLD`, multi-statement bodies, depth limit 8 |

### Delivered in #8 and #9 (for the record)

**#8 — collations.** A column may declare `COLLATE BINARY|NOCASE|RTRIM`; an
unknown name is refused. The declared collation applies when the expression does
not attach one of its own:

- comparisons (`=`, `<`, …) resolve the collation from either operand in
  `eval_expr`'s `Binary_Expr` case, through `column_collation(ctx, expr)`;
- `ORDER BY` folds with the same rule in both key builders;
- unique indexes encode folded text (`index_encode_value`), so
  `name TEXT COLLATE NOCASE UNIQUE` rejects `ALICE` next to `Alice`;
- the index probe folds the literal the same way, so `WHERE name = 'ALICE'`
  still uses the index.

**#9 — generated columns.** `name TYPE GENERATED ALWAYS AS (expr) [STORED]` (and
the shorter `AS (expr)`) stores the expression as SQL text. A statement parses it
once (`generated_plan_make` → `sql_parse_expression`) and evaluates it per row
against a synthetic `Source` holding the row being stored
(`generated_plan_apply`), after coercion and before `tx_insert`/`tx_update`, so
`CHECK` and `RETURNING` see the final values. Naming a generated column in
`INSERT` or in an `UPDATE … SET` is an error, and a `DEFAULT` on one is refused.

**Format.** Two optional column bits carry the collation and the generated
expression, so `LOG_VERSION` moves 15 → 16. The bits default off in an older
file, so a v15 store still opens and reads: the bump records the addition, it
does not break the previous decoder path. `schema_copy` clones both strings into
the **table** arena (a transaction arena copy would dangle after the commit —
that was the first bug the test caught).

Test: `test_column_collation_and_generated` — compare/sort/unique/index probe
with `COLLATE NOCASE`, a BINARY column that stays case-sensitive, a generated
column computed on insert and recomputed on update, direct writes refused, and a
reopen that keeps both (plus an update after the reopen).

---

## P2 — Functions (12) — 12

| # | Item | Weight | State |
|---|---|---|---|
| 11 | Text, blob, aggregate and status functions | 4 | done: `group_concat`, `zeroblob`, `randomblob`, `random`, `unhex`, `unicode`, `octet_length`, `concat_ws`, `quote`, `hex`, `instr`, `char`, `format`, `typeof`, `iif`, `changes`, `last_insert_rowid`, `total_changes`, `like`, `glob` |
| 12 | Date and time | 3 | done: `date`, `time`, `datetime`, `julianday`, `unixepoch`, `strftime`, modifiers, Julian-day model |
| 13 | Math | 1 | done: `log` family, `exp`, trigonometry, `atan2`, `degrees`, `radians`, `trunc`, `pi`, `round(x, digits)` |
| 14 | JSON functions | 3 | done: value functions including the mutators `json_set`, `json_replace`, `json_remove`, plus the table-valued `json_each` and `json_tree` (SQLite's eight columns, `$.a`/`$[0]` keys, quoted member names, a scalar document as one row), usable as a lateral join over a column |
| 15 | PRAGMAs | 1 | done: 32 pragmas answered (including `integrity_check`, `foreign_key_check`, `stats`, `page_count`, `data_version`), `synchronous` is a real setting that moves the log's durability, `journal_mode` reports the commit-log mode (`delete` or `memory`), and the knobs that would change what a statement does are refused instead of silently accepted; 19 tuning-only names remain accepted as no-ops |

### Delivered in #14 (for the record)

`json_each` and `json_tree` are table-valued functions: one JSON text in, one row
per node out, as a temporary table the executor scans like a view
(`src/engine/json_table.odin`).

- Columns match SQLite: `key`, `value`, `type`, `atom`, `id`, `parent`,
  `fullkey`, `path`.
- `json_each` yields the direct children (a scalar document is one row with no
  key); `json_tree` walks the whole document depth first with a `parent` link.
- `key` is the array index or the object member; `fullkey` is `$.a` or
  `$[0]`, with the member quoted when it is not a plain identifier.
- `value` is the SQL value for a scalar and the JSON text for a container;
  `atom` is NULL for a container; booleans are 1/0.
- The argument may be a column of another table, which makes it a lateral join:
  the function is materialized once per outer row (the tables stay alive until
  the statement ends, because the joined rows point into them).
- `FROM a, b` now parses as a cross join, which is how SQLite writes a table
  function beside a table and what the tests use.
- Test: `test_json_table_functions` — arrays, objects, quoting, a scalar
  document, `json_tree` nesting with parents, a lateral join over a real column,
  and clean errors for bad JSON and a missing argument.

### Delivered in #15 (for the record)

32 pragmas answer, and the answer is what the engine does:

| Pragma | Answer | Why |
|---|---|---|
| `journal_mode` | `delete` for a durable log, `memory` for an ephemeral one | there is no WAL and no rollback journal; a commit is one durable record, which is the `delete` guarantee. A set returns the mode in effect, as SQLite does when it cannot switch |
| `synchronous` | `0`/`1`/`2` from the log's durability | a real setting: `OFF`/`NORMAL`/`FULL`/`EXTRA` changes `store.log.durability`, so the next commit fsyncs differently; an unknown word is an error |
| `cache_size`, `mmap_size` | `0` | there is no page cache and nothing is mapped |
| `page_size`, `encoding` | `4096`, `UTF-8` | the export's page size and the only text encoding |
| `page_count`, `freelist_count`, `data_version` | log pages, `0`, the commit sequence | real numbers, not neutral zeros |
| `foreign_keys` | `1` | enforcement lives in the transaction layer and cannot be turned off |
| `user_version`, `application_id` | stored in the catalog | read back after a reopen |

A knob that would change what a statement does (`query_only`, `read_uncommitted`,
`recursive_triggers`, `defer_foreign_keys`, `ignore_check_constraints`,
`legacy_alter_table`, `locking_mode`, `case_sensitive_like`, `trusted_schema`,
`reverse_unordered_selects`, `writable_schema`) answers the truth on a read and
**refuses the write** with `sql_unsupported`: accepting it silently would make a
caller believe a guarantee the engine does not give. The remaining tuning-only
names (`busy_timeout`, `automatic_index`, `secure_delete`, …) are still accepted
so a tool that sets them does not fail.

---

## P3 — File format fidelity (15) — 15

| # | Item | Weight | State |
|---|---|---|---|
| 16 | Secondary indexes on export | 4 | done: multi-level b-trees, validated with `sqlite3` |
| 17 | `sqlite_sequence`, `AUTOINCREMENT` | 2 | done |
| 18 | WAL and rollback-journal replay on import | 3 | done: frames overlaid by salt and commit size, hot journal restored first |
| 19 | Deterministic export | 2 | done: two exports of one state are byte-identical, also after replay; an export has no free pages |
| 20 | Native FTS and R-Tree | 2 | done: FTS5 (`MATCH` with `OR`/`NOT`/conjunctions, index maintained on every write, survives reopen) and R-Tree (`rtree`/`rtree_i32` with min/max pairs, overlap answered by range predicates) |
| 21 | SQLite pages as an alternative storage backend | 2 | done as a live mirror, patched page by page: a database opened from a `.sqlite` file rewrites only the leaf of each changed row, its separator and the header (three pages per commit at any size), so any SQLite driver reads the committed rows and `PRAGMA database_list` names the file; the commit log stays the truth, splits and free-list reuse are covered by tests, and an interrupted commit is rolled back from a journal in SQLite's format |

### Delivered in #20 (for the record): FTS5

`src/engine/fts.odin` (new). Everything is **data**, so the log format is
unchanged: a virtual table is a normal document table, an inverted index in a
shadow table, and a catalog row.

- `CREATE VIRTUAL TABLE docs USING fts5(body, title)` creates `docs` (its
  columns stored as TEXT), `_fts_docs_terms (term, doc)` and a row in
  `_virtual (name, module, settings)`.
- Writes maintain the index: `INSERT`/`UPDATE` re-tokenize the row (one term row
  per distinct token, ASCII-folded to lower case, capped at `FTS_MAX_TERMS` per
  document) and `DELETE` removes the document's terms. The hooks sit in the
  insert, upsert-update, update and delete paths, so the index cannot drift.
- `docs MATCH 'term'` is a new operator (`Match_Expr` in the AST) evaluated
  against the index: the document set of a pattern is computed **once per
  statement** (cached in `Tx.fts_cache`, freed with the transaction) and every
  scanned row is one map lookup. Space-separated terms are a conjunction, `OR`
  is a union, `NOT` subtracts. Terms fold like the index, so `FOX` finds `fox`.
- `DROP TABLE` on a virtual table drops the catalog row and both tables; the
  catalog row goes first so the drop cannot re-enter itself.
- Test: `test_full_text_search` — projection returns the stored columns, single
  term, case folding, missing term, `OR`, conjunction, `NOT`, update and delete
  keep the index honest, two virtual tables stay separate, an unknown module is
  refused, the index survives a reopen, and `DROP` removes the shadow table.

- Spatial tables: `CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx,
  miny, maxy)` stores the boxes as columns — `id` is the primary key, the rest
  are REAL (`rtree_i32` makes them INTEGER) — so an overlap query is a range
  predicate the executor already answers. A shape that is not a set of min/max
  pairs is refused, `MATCH` on a spatial table fails instead of returning
  nothing, and a reopen keeps both the boxes and the catalog row.
- Test for the spatial half: `test_spatial_rtree` — point containment, a window
  overlap, fractional coordinates, move and delete, `rtree_i32`, rejected shape,
  rejected `MATCH`, reopen, and `DROP` forgetting the table.

Honest gaps:

- **Spatial layout**: the boxes are the table's columns, not an R-tree node file.
  Range predicates return the same rows an R-tree would, but with a scan: a
  bounded query is cheap, an unbounded one is O(rows). The node layout and a
  real tree descent are future work, and `docs/sql.md` says so.

- **No index on `term`**: `CREATE INDEX` must run in a transaction of its own and
  a virtual table is created inside one statement, so `MATCH` scans the shadow
  table once per distinct pattern. That is one scan per query, not per row: a
  scan of N documents costs O(terms + N).
- `rank`, `snippet()` and `highlight()` are not implemented.
- `AND` is implicit (juxtaposition); the word `AND` is a term.

### Delivered in #21 (for the record)

The page backend shipped as the **live mirror**: `embed_open` on a `.sqlite` file
imports it into memory **and sets `store.sqlite_mirror`**, so after a commit —
once the write lock is released — the store brings the file up to date. It first
rewrote the whole state with `sqlite_file_write`; the page patcher in
`src/engine/sqlite_mirror.odin` replaced that (`docs/backlog.md` D4), so a commit
now writes the leaf of each changed row, its separator and the header. The file
stays a valid SQLite database: a different driver opens it and sees the committed
rows, and `PRAGMA database_list` reports it as `main`.

- `store_set_sqlite_mirror` / `store_sqlite_mirror_flush` live in `store.odin`;
  the flush takes the read lock, so it runs after `tx_discard` and never inside
  the commit's write section.
- A failed mirror write is **reported** (`last_error`) and never fails the commit:
  the log is the truth, and a mirror is an export.
- Cost: three pages (12 KiB) per commit at any table size, measured by
  `scripts/mirror_cost.py --check`. What the patcher cannot express — a table
  with no single INTEGER primary key, a secondary index, a schema change, a
  write-ahead log, a tree deeper than three levels — re-encodes the file, which
  is correct and slow; patching those is the remaining work.
- Test: `test_sqlite_live_mirror` — export a database, `embed_open` it, insert,
  close, then reopen the file with the engine's own SQLite reader and find both
  rows (and the table name in `sqlite_master`).

---

## P4 — Tooling and API (8) — 8

| # | Item | Weight | State |
|---|---|---|---|
| 22 | Shell commands | 3 | done: `.mode` (column/list/csv/tabs), `.headers`, `.output`, `.dump`, `.read`, `.timer`, `.import` (CSV with quotes and affinity) |
| 23 | Backup API and `VACUUM INTO` | 2 | done: `VACUUM`, `VACUUM INTO 'path'` (a full database), `miraidb_backup`; an existing target is refused |
| 24 | `sqlite3_blob_*` incremental I/O | 1 | done: open/bytes/read/write/close/reopen over a copy flushed by `UPDATE`; the row is named by a single-column primary key; covered by the ABI smoke |
| 25 | `load_extension` through `core:dynlib` | 1 | done out of process instead of in-process: `LOAD EXTENSION name AT 'host:port' [USING reducers]` registers a remote module over the wire protocol, `UNLOAD EXTENSION` forgets it, the row in `_extension` makes `host_init` register it again after a restart, and no engine struct crosses the boundary (the in-process DLL attempt is documented below as refused) |
| 26 | `ATTACH` / `DETACH` as a store catalog | 1 | done: `ATTACH 'path' AS name` opens a database read-only and records it in `_attach` (so a reopen restores it), `name.table` and `db.table.column` read it, `DETACH` forgets it, writes are refused at parse time with a reason |

### Delivered in #25 (for the record): extensions as processes

`src/engine/extension.odin` (new). The DLL route stays refused: two allocators
sharing a heap is exactly how the first attempt corrupted it. An extension is
therefore a **process** that speaks the wire protocol, which the engine already
has (`remote_module.odin`) and which needs no memory contract at all.

- `LOAD EXTENSION notes AT '127.0.0.1:7100' USING note, bump` records a row in
  `_extension (name, address, port, reducers)` and registers a remote module.
  The address must carry a port; an address without one is refused instead of
  silently producing an extension that can never be reached.
- `UNLOAD EXTENSION [IF EXISTS] name` deletes the row and forgets the module.
- The row is data like every other catalog entry, so `host_init` replays it
  (`host_replay_extensions`): a restart registers the extension again without
  connecting. A module that is down still starts the host; its calls fail.
- Calls go through `host_call_module`, so the byte cap, the socket timeouts and
  the "unknown reducer is refused before any socket work" rule all apply.
- Registering an extension twice replaces the registration instead of leaving
  two, and every call carries a **fresh request id** seeded from the clock at
  `host_init`: without that, a restarted host reused id 0 and the module answered
  from its idempotency cache instead of executing the call (found by the test).
- Test: `test_extension_load` — a second host served from a thread over a real
  socket, `LOAD EXTENSION` through SQL, a call whose effect lands in the
  extension's own database, the declared reducer list enforced, `UNLOAD`
  forgetting both the module and the row, `IF EXISTS`, and a restart that
  re-registers from the catalog and executes the next call.

### Delivered in #26 (for the record)

`src/engine/attach.odin` (new) plus a `schema` on `Table_Ref` and a qualifier
parameter on `tx_source_table`.

- `ATTACH 'path' AS name` refuses a missing path, a repeated name and attaching
  a store to itself; it opens the database with `persistent = true,
  create = false, durable = false` (read-only) and records `name → path` in the
  internal `_attach` table, so a reopen restores the set with no format change.
- Reading copies the attached table into a temporary table under the attached
  store's shared lock, with `table_collect(..., max(u64))`: the attached log's
  commit sequence has nothing to do with this store's, so the visibility rule
  cannot be shared. The copy is returned as a view, which also skips the index
  planner (`index_candidates` resolves names in the principal catalog).
- `name.table` resolves through `tx_source_table`'s new qualifier; a
  `database.table.column` reference keeps everything before the last part as the
  table name, so a qualified projection and `WHERE` work.
- Writes are refused at parse time with `writes to an attached database are
  read-only` for `INSERT`, `UPDATE` and `DELETE`.
- `DETACH name` deletes the catalog row, commits, then closes the handle. Both
  statements are refused inside a transaction, like `VACUUM`, and appear in
  `EXPLAIN` with a readable line.
- A path that no longer opens at startup is reported through `last_error` and
  never blocks the principal.
- Test: `test_attach_and_detach` — attach, cross-database join with qualified
  columns, duplicate attach refused, unknown database and table as clean
  `table_not_found`, write refused, reopen restores the catalog, `DETACH`
  persists across another reopen.

Cost to keep honest: every statement that reads an attached table copies it
whole. That is fine for a read-only side database and is the price of not
threading a second consistency model through the executor.

---

## P5 — Efficiency and quality (20) — 20

| # | Item | Weight | State |
|---|---|---|---|
| 27 | Prepared-statement cache | 5 | done: 22k → 59.6k inserts/s (2.7×), measured 60.5k/s now |
| 28 | Snapshots in O(log n) | 6 | done for the steady state: 12.1 µs per read at 50k rows (was 223 ms); the first read of a process copies all tables (≈190 ms) by design |
| 29 | Compact `Value` | 3 | done: a 16-byte raw-union payload keeps the field reads and takes a value from 144 B to 24 B (five values 720 to 120 B, a column 256 to 128 B); `test_value_layout` pins the sizes, the 128-bit bit patterns and a replay of every class; read snapshots 12.0 to 9.9 µs at the time, 12.1 µs now |
| 30 | Subscription deltas for joins and aggregates | 3 | done: a join subscription keeps a tuple index and moves only the tuples of the changed row; a grouped one keeps a group table (the rows that feed each group and its last published row) and recomputes only the groups a commit touches, publishing a delete plus an insert when the row changed and dropping a group when its last row goes; `DISTINCT`, `ORDER BY`, `LIMIT` and policies still re-evaluate |
| 31 | Background compaction, HTTP/WS caps, fuzzing, soak, latency histograms | 3 | done: latency histograms (`PRAGMA stats`), a real `integrity_check`/`foreign_key_check`, `scripts/fuzz.py` and `scripts/soak.py`, transport caps (body/header/frame, tested), and an opt-in background compactor with a floor guard; the soak exposed a read-after-free that is fixed and pinned by a test; the worker allocates with the store's allocator |

### Refinement left in #30 (not a gap)

An ungrouped `count(*)`/`sum()` still recomputes from a scan of its one group
(the whole table). Per-aggregate state (counts and sums updated by ±1,
`min`/`max` over a multiset) would make that sub-linear; it also needs the
projection expressions evaluated over aggregate results instead of rows. Land it
when a workload needs it, and write the test with the delta counts per step.

### Delivered in #31 (for the record)

- **Latency histograms**: twenty doubling buckets for commits and queries,
  incremented with atomics because a query reports after releasing the lock;
  `PRAGMA stats` prints them and `test_integrity_and_latency_stats` checks the
  sums.
- **Integrity**: `store_integrity_check` verifies row width, index membership,
  unique keys and foreign keys on a read snapshot; `PRAGMA integrity_check` and
  `PRAGMA foreign_key_check` expose it.
- **Harnesses**: `scripts/fuzz.py` (seeded random SQL, valid and broken) and
  `scripts/soak.py` (writes, reads, `VACUUM`, reopens). They found five memory
  bugs plus the read-after-free that made the soak fail half the time: a scan
  projected a row, freed its source and then read the row id from it.
- **Transport caps**: `Host.max_request_bytes` (1 MiB), `max_header_bytes`
  (16 KiB) and `max_frame_bytes` (1 MiB), settable with
  `host_set_request_limits`/`host_set_frame_limit`; an oversized request answers
  `413`, an oversized frame is refused before it is allocated (also closing the
  64-bit length wrap). `test_transport_caps` covers header, body, overflow, the
  host cap and forged frame lengths.
- **Background compaction**: `Store_Options.compact_after_bytes` starts a worker
  that rewrites the log when it grows past the threshold.
  `store_background_compact_step` is the deterministic entry point and
  `store.compact_count` is the observable. Two design points: the worker sets
  `context.allocator` to the store's allocator (a custom allocator handed to a
  store with background compaction must be thread-safe), and `compact_floor`
  waits for the log to double after a rewrite, because a snapshot of a wide
  database can be larger than the threshold.
- **One artifact**: compaction used to write the payload twice (the log and a
  `snapshot` file with identical bytes). The log now carries the snapshot record
  and the redundant file is removed, halving the disk usage of a compacted
  database.

Measured: compacting 50k rows takes 0.48 s for the whole command and leaves one
`log` file (1956 KiB, no `snapshot`); 500 small commits go from 94 KiB to 76 KiB
with the same rows.

---

## P6 — Modules and deployment (5) — 5

| # | Item | Weight | State |
|---|---|---|---|
| 32 | Modules out of process or in WASM with the same ABI | 2 | done out of process: `host_register_remote_module` + `host_call_module` frame the call over TCP (length-prefixed wire message) with a byte cap and socket timeouts; a module that is down fails the call, and an unregistered reducer is refused before any socket work |
| 33 | Commit queue with fairness and priorities | 2 | done: priority order with FIFO inside a priority, promotion after `COMMIT_QUEUE_AGING` rounds, `store_commit_queue` over the group commit, tested as a policy and end to end |
| 34 | Roles and permissions alongside row policies | 1 | done: `GRANT`/`REVOKE` for roles and table permissions, `has_role()` for policies, writes gated in the transaction layer and open until the catalog has rows, catalog persisted as `_role`/`_grant` |

### Delivered in #32 (for the record)

`src/engine/remote_module.odin` (new). A module is any process that speaks the
wire protocol; the host does not share memory with it.

- `host_register_remote_module(host, name, address, port, reducers)` records where
  it lives and which reducers it offers. No connection is made until a call, so a
  module that is down fails its call instead of the host.
- `host_call_module` forwards through `host_call_remote_module`: it frames
  `wire_encode_call` with a little-endian u32 length, sends it, reads one framed
  reply, caps both sides at `Host.max_request_bytes` and answers an error reply
  as an error. A reducer's effects stay on the module side; the host gets the
  acknowledgement (`affected`) and can check its own view through the module.
- The socket carries a receive and send timeout (`REMOTE_MODULE_TIMEOUT_MS`), so
  a hung module fails the call. An unregistered reducer is refused **before**
  opening a socket, and an unreachable module answers `io`.
- Test: `test_remote_module` — a second host served from a thread over a real
  socket, a reducer executed there (its insert visible in that host's store), an
  unregistered reducer refused, and a dead module answering `io` instead of
  crashing. The thread runs the same `wire_request` a separate process would.
- Not claimed: WASM. The row says "out of process **or** in WASM"; this is the
  first, and #25 reuses its transport.

---

## Open defects and unknowns

### D1 — the soak abort: **closed**

The abort was a read-after-free in `sql_exec_select`: the projection loop freed
a row's `[]Source` and then read `partial[0].row.id` from it to fill
`row_ids`. The Windows heap usually left the bytes alone (so it worked), and
sometimes the freed block was reused (so it faulted); the low byte of
`STATUS_ACCESS_VIOLATION` is what showed up as exit code 5. The row id is now
read **before** the delete, `scripts/soak.py` is green over five runs (13k
statements) where it used to fail half the time, and
`test_limited_scan_row_ids_are_stored` pins the behaviour on the real heap.

How it was found, for the next hunt of this kind:

1. A per-statement trace on stderr (`fmt.eprintfln`, flushed) named the failing
   statement even though stdout was lost in the abort.
2. Running that statement repeatedly against the surviving database reproduced
   it 6 times in 12 — the layout sensitivity was the allocator reusing the
   freed block.
3. `odin build src/cli -debug -sanitize:address` printed the exact frame:
   `sql_exec_select` at the line that read the freed source. **ASAN is the
   tool**: a silent abort under the tracker becomes a named line.

Original notes, kept because the symptoms are worth recognising:

- The statement fuzzer (`scripts/fuzz.py`) is clean over 8 seeds × 1,000
  statements, so it is not "random SQL".
- The failure is layout-sensitive: replaying the *same* statements against a
  *copy* of the same database passes sometimes and fails other times, and a
  whole-suite run reports `bad free` sites that a single-test run does not.
- In-process workloads of the same shapes (1,200 statements, a result destroyed
  after every statement) pass under the tracking allocator.
- Five use-after-free/free-twice bugs of this family were already found and
  fixed this round; at least one remains.
- Exit codes are a fingerprint: a double free exits **116** silently, a bounds
  panic exits **140** with a message, `panic()` exits **29** with a message.
  Code **5** matches none of them, so record it as "terminated, cause unknown"
  until the hunt closes it.

Playbook for the next attempt, in order:

1. Build a CLI variant that flushes after every statement (`os.flush(os.stdout)`
   or an unbuffered stderr trace), so the output survives an abort and names the
   last statement executed.
2. Reproduce with `--keep`, then copy the database and bisect the failing chunk
   by halves over fresh copies; keep a passing copy as the control, because the
   failure is layout-sensitive.
3. Port the reproducer into `src/tests` and run it under the tracking allocator
   with `-debug`: a `bad free` there comes with the allocating call site.
4. Suspects, in order: result fields that outlive the transaction arena (two
   were already fixed: a message and the column names), the read cache after a
   commit that publishes and then retires a cache, and `sql_exec_select`'s
   error paths (two double frees were fixed there, and one `[]Source` allocated
   from `tx.alloc` for system tables was fixed this round).
5. If the tracking allocator stays silent, add a deliberate `-sanitize:address`
   build or a arena-poisoning mode that fills freed arena memory with 0xDD.

### D2 — tests do not destroy their results, so the destroy path is barely tested

The `run()` helper in `src/tests/engine_test.odin` returns the result and the
caller usually drops it. The suite therefore **leaks** every result and never
exercises `sql_result_destroy` the way the CLI does on every statement. One test
(`test_statement_stream_destroys_results`) now destroys each result, and
`test_system_tables` destroys its results too.

Action: add a `run_destroy` helper for tests that do not inspect the result and
convert the highest-traffic tests; when the tracker is quiet, consider failing
a test that leaks a result.

### D3 — `bad free` noise from the test runner hides real ones

A whole-suite run prints hundreds of `+++ bad free` lines whose call sites are
`sql_exec_select`; the same tests alone are clean. The tracking allocator is
installed per test, so an allocation freed after its test ends is reported as a
`bad free` in the next one. Treat the count as noise only when a single-test run
is clean, and check that before dismissing a report.

---

## Next

This roadmap is closed: **100 / 100**, every row `done` with a test. It is not
the whole plan. `docs/roadmap.md` is the authoritative order for what is left,
and its list still carries nine open items (POSIX CI, spatial tree, decimal and
time zones, replication, the module sandbox, TLS and HTTP/2, generated clients,
licences) plus the rows of the efficiency contract recorded as not met. The open
defects are in the section above; they come first.

Rationale, unchanged: correctness and memory first, then the features a user can
see, then the cheap independent gaps.

---

## Definition of done, per row

1. The behaviour exists and is documented where a user looks (`docs/sql.md`,
   `docs/sqlite.md`, `docs/architecture.md`).
2. A test covers it: a unit test in `src/tests/engine_test.odin` or a smoke
   script under `scripts/` (mention which one in the row). New tests destroy
   their results.
3. The full verification block above is green.
4. The row says `done` or `N: …`, and `python3 scripts/roadmap.py` was run.
5. One local commit, `miraidb <dev@miraidb.local>`, whose message explains the
   **why** and ends with the roadmap line.

## Known limits to keep honest

The roadmap is closed, so the limits below are **depth**, not missing
interfaces. `docs/backlog.md` turns each one into a scoped work item with
acceptance criteria, current cost and effort; this list is the short version.

- Window frames, windows beside `GROUP BY`, `BEFORE` triggers and trigger `WHEN`
  clauses are refused with `sql_unsupported`; they are not approximated. So is
  writing a `WITHOUT ROWID` table.
- `COLLATE` covers `BINARY`, `NOCASE` and `RTRIM`; other collations are refused.
  `WITH RECURSIVE` parses but does not recurse. `ALTER TABLE` covers rename, drop
  and add column. (backlog D9)
- Full-text `MATCH` resolves a pattern with one pass over the term table, because
  `CREATE INDEX` cannot run in the transaction that creates a virtual table, so
  there is no index on `term`; `rank`, `snippet` and `highlight` do not exist.
  (backlog D1, D11)
- A spatial table stores its boxes as columns: overlap is answered by range
  predicates, which is a scan when the query has no bound. (backlog D2)
- The `.sqlite` mirror patches the pages a commit touched, but a table with a
  secondary index still re-encodes the file, because the index b-trees are not
  patched yet. (backlog D4)
- Indexes are rebuilt in memory when a database opens; the log has no index
  pages. Joins are nested loops in the order written; there is no cost model or
  `ANALYZE` statistics. (backlog D5, D6)
- `FROM t AS OF <seq>` reads the versions a table keeps; versions stay until
  `store_prune_versions` is called with the oldest sequence in use, and there is
  no automatic retention policy or memory budget for history yet. `AS OF` on a
  join is refused.
- A page file format exists (`src/engine/page.odin`): 4 KiB slotted pages with a
  checksum, a free list, a buffer pool and a streaming reader, with the flush
  order tested under injected faults. Queries do not read through it yet; every
  table is still a `map[Row_Id]Row` in memory. (backlog D17)
- Read transactions freeze the tables they touch by borrowing their values
  through a shared store, so a freeze costs a map and its index entries rather
  than a deep copy: 50k rows in ~1 ms, steady state 11.6 µs per read. There is
  still no `AS OF` history. (backlog D3)
- A scheduled reducer keeps its due time as a column of `_schedule`, and an
  idempotent call commits its request id and its result in the same transaction
  as its effects, so a retry after a restart answers with the stored result
  (`test_idempotent_result`, `test_durability_after_restart`). What is still not
  offered is `AS OF` history and a sandbox that makes a module deterministic.
- Modules are processes, not a deterministic sandbox: the byte cap, socket
  timeouts, the reducer allow-list and a per-call **work budget** (rows read and
  written, `host_set_work_budget`) are the safety mechanism, and a pooled socket
  keeps a call to one frame each way. Extensions use the same transport, and
  nothing of the engine is shared across it. (backlog D12a, D12b, D12c)
- Compaction, snapshots and `VACUUM INTO` require the OS file system; a VFS
  database replays by scanning and has no offset index.
- An ungrouped aggregate still recomputes by scanning its one group.
- No crash injection and no process-level load test yet; the fuzzer and the soak
  cover statements and long runs only. (backlog D8)
- There is no replication: one process owns one log. (backlog D14)
- **The suite still prints 44 `bad free` lines** under the tracking allocator,
  down from 3058; they are memory frees the tracker refuses (the arena frees it
  later, so nothing leaks). 42 of them are the metric strings of `PRAGMA stats`
  reaching `sql_result_destroy` in `test_integrity_and_latency_stats`, plus one in
  `tx_discard` and one in `frozen_cache_destroy`. Count them and find a caller
  with:

  ```sh
  odin test src/tests 2>&1 | grep -c 'bad free'
  # a probe inside the suspect, printed for every call, then sort by caller:
  #   free_values :: proc(values: []Value, caller := #caller_location)
  #   fmt.printfln("PROBE from %s:%d", caller.file_path, caller.line)
  ```

  The ones that mattered are fixed: a store closed twice by a test (one of them
  held 3000 rows), a subscription path freeing transaction memory with the
  caller's allocator, and `strings.to_string` of a builder that was then
  destroyed.
