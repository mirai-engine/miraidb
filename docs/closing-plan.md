# The closing plan, and what closed after it

This is the plan that closed the work *after* parity, and it is **closed**: the
parity matrix is complete (94/94, every row tested, 100%), and every row of this
plan is `done` with a test. It totals **100 points** and `scripts/roadmap.py`
regenerates the numbers.

[roadmap.md](roadmap.md) is the live list of what is left; this file is the
record of what the closing plan contained, how each row was closed, and (at the
end) the depth items closed after it.

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
python3 scripts/plan_check.py                              # 7 plan checks
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
| `user_version`, `application_id` | stored as 32-bit integers in `_sqlite_header` (they were session text until block 4) | read back after a reopen, undone by a rollback (`test_user_version_is_stored`) |

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
| 23 | Backup API and `VACUUM INTO` | 2 | done: `VACUUM`, `VACUUM INTO 'path'` (a full database), `miraidb_backup`; an existing target is refused. SQLite's `sqlite3_backup_*`, `sqlite3_serialize` and `sqlite3_deserialize` landed with ABI block 4 (`scripts/sqlite_abi_database.py`) |
| 24 | `sqlite3_blob_*` incremental I/O | 1 | done: open/bytes/read/write/close/reopen over a copy flushed by `UPDATE`; the row is named by its rowid, so a table without a primary key works too; covered by the ABI smoke |
| 25 | `load_extension` through `core:dynlib` | 1 | done out of process instead of in-process: `LOAD EXTENSION name AT 'host:port' [USING reducers]` registers a remote module over the wire protocol, `UNLOAD EXTENSION` forgets it, the row in `_extension` makes `host_init` register it again after a restart, and no engine struct crosses the boundary (the in-process DLL attempt is documented below as refused) |
| 26 | `ATTACH` / `DETACH` as a store catalog | 1 | done: `ATTACH 'path' AS name` opens a database and records it in `_attach` (so a reopen restores it), `name.table` and `db.table.column` read it, `DETACH` forgets it; writes to it run in its own transaction, which the statement's transaction ends (session 4: they used to be refused) |

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

## Defects found while closing the plan

The two still open (test results that are never destroyed, and `bad free`
noise from the runner) are part of backlog D35 now; their numbering here is the
plan's own, not the backlog's.

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

---

## Depth items closed after the plan

These were items of the roadmap after the plan closed; each entry names the code
and the test or gate that proves it, and the git history of `docs/backlog.md`
holds each one's full write-up. The engineering gates that watch them today are
listed in `docs/status.md` and run by `scripts/ci.py` (27 gates).

| Item | Evidence |
|---|---|
| **S5 — built-in functions** | SQLite's binary JSON: `jsonb()` of a JSON text gives SQLite's bytes, the ten `jsonb_*` scalars and `jsonb_group_array`/`jsonb_group_object` answer it, and every JSON function, `json_each` and `json_tree` read it; `json_array_insert` answers what SQLite's `json109.test` expects. On the way: a JSON number keeps the text it was written with (`1.50`, a literal past an i64), and a path's `[#]` and `[#-n]` read as SQLite reads them (`$[#]` used to answer the array's length). `json_parse` and `sqlite_offset` are left out of the count: a default SQLite build has neither. Not SQLite's: an edit may pick another valid encoding of the same document, and the engine's values carry no JSON subtype. Functions 119 / 119. `test_jsonb_and_array_insert`, `test_json_functions`, and fifteen statements in the differential corpus. |
| **S4 — aggregates and windows** | `FILTER (WHERE …)` on an aggregate and on an aggregate window keeps the rows it holds for, and an aggregate's own `ORDER BY` (`group_concat(x, ',' ORDER BY y)`, `json_group_array(x ORDER BY y)`) is the order it reads them in, for the built-in aggregates and a program's alike; a scalar function refuses both, and a ranking window refuses `FILTER`, in SQLite's words. The `WINDOW` clause: `OVER name` takes a definition whole, `OVER (name …)` adds an `ORDER BY` or a frame, a definition may build on an earlier one, and SQLite's four refusals hold. On the way: an operator chain (`1+1+…`) is held to the expression depth when it is parsed, as parentheses are, instead of being walked 2000 levels deep before evaluation refused it. Not supported: `FILTER` on a window over grouped rows, and a program's collation in an aggregate's `ORDER BY`. `test_aggregate_filter_and_order`, `test_window_clause`, `test_expression_depth_is_bounded`, and nine statements in the differential corpus. |
| **S6 — statements and pragmas** | `INSTEAD OF` triggers make a view writable: the statement on the view writes nothing and counts no change, each row it would touch fires the trigger with `NEW` and `OLD` over the view's columns, `RETURNING` answers the view's row, a view without one is refused in SQLite's words, and `DROP VIEW` takes its triggers. `generate_series` is a built-in eponymous table with SQLite's series semantics, `ATTACH ':memory:'` opens an in-memory database, `VACUUM` on one answers ok; `EXPLAIN QUERY PLAN`, `REINDEX`, `INDEXED BY`/`NOT INDEXED` and all 63 pragmas landed before. `test_instead_of_triggers`, `test_generate_series`, `test_memory_attach_and_vacuum`, four statements in the differential corpus, and `sqlite_gaps.py` lists no statement of S6. |
| **S3 — `NATURAL` joins** | `NATURAL [LEFT | RIGHT | FULL | INNER] JOIN` is the `USING` over the names the table before it and the joined one share, worked out when the statement runs from the name pass's view of tables, views, CTEs and derived tables; no shared name makes it a cross join. `test_natural_joins`, and five statements in the differential corpus. |
| **S1 — `ON CONFLICT` on a constraint** | `PRIMARY KEY`, `UNIQUE` (column or table) and `NOT NULL` take `ON CONFLICT ROLLBACK/ABORT/FAIL/IGNORE/REPLACE`; when a statement names no `OR`, a row that breaks the constraint follows it — `FAIL` keeps the rows before it, `IGNORE` skips it, `REPLACE` removes the colliding rows (or stores the `NOT NULL` column's default), `ROLLBACK` ends the transaction. The resolution is part of the schema record and survives a reopen. On the way: a `RETURNING` that returned no row answered as a write without rows. `test_constraint_on_conflict`, and seven statements in the differential corpus. |
| **S2 — `UPDATE OR <resolution>`** | `UPDATE OR ABORT`, `FAIL`, `IGNORE`, `REPLACE` and `ROLLBACK` act as their `INSERT` counterparts: a row is its own unit under `FAIL` and `IGNORE`, `REPLACE` removes the rows a new key collides with (no delete triggers) and writes the row again, and `ROLLBACK` cannot end a transaction the caller opened. `test_update_or_resolutions`, and five statements in the differential corpus (one rejected by both). |
| **S7 — affinity, untyped columns, STRICT and `WITHOUT ROWID`** | A column without a type keeps any value, and a type name no `CREATE TYPE` defined is read by SQLite's five rules; a text that reads as a number becomes one in a numeric column, a number becomes text in a text column, and through the `sqlite3_*` face every declared type is an affinity and what does not convert is stored as it is. Values of different storage classes compare in SQLite's order after a column's affinity converts the other side. `STRICT` refuses what its column cannot convert in SQLite's words, and `WITHOUT ROWID` tables are created with their key as their identity; both survive a reopen. A real's text form is SQLite's. On the way: the `.sqlite` import turned a NULL in the first column of a table without an INTEGER PRIMARY KEY into the rowid, a zero-byte file would not open, and SQLite's prepare-time DDL errors (an existing name, a DROP of the wrong kind, an index on a missing column) were runtime errors or no error at all. `test_affinity_and_untyped_columns`, `test_strict_table_option`, `scripts/sqlite_abi_affinity.py` (0 differences from SQLite), and cross-class queries in the differential corpus. |
| **D37 — names are resolved before a statement runs** | `src/engine/resolve.odin` reads a statement against the catalog before it runs, with the scopes the executor uses (joins, correlated subqueries, CTEs, derived tables and `VALUES`, views, projection aliases, `NEW`/`OLD`, `excluded`, the row id and a full-text table's hidden columns), and refuses a table or a column that is not there with SQLite's words through the facade (`no such table: x`, `no such column: x`, `table t has no column named x`). `embed_prepare` runs it, so `sqlite3_prepare_v2` fails where SQLite does, and so does every execution, so an empty table no longer hides a misspelling. It refuses only what it is sure of: a reference that a table function, an attached or system table, or a relation whose columns it cannot list could answer is left to the executor, and a compound's `ORDER BY` is not checked. `test_names_resolved_before_running` (16 refusals, 17 statements that must still prepare), ten statements both engines reject in the differential corpus, and seven prepares compared with SQLite in `scripts/sqlite_abi_reference.py`. |
| **D38 — common table expressions on a write** | `WITH … INSERT`, `WITH … UPDATE`, `WITH … DELETE` and `INSERT INTO t WITH … SELECT` parse, and recursive CTEs with them: the write carries its CTEs, materializes them for its own life, and its `SELECT`, `WHERE`, `FROM` and subqueries read them by name; the authorizer walks them as it walks a query's. `test_cte_on_a_write`, and five statements in the differential corpus that answer as SQLite does, `RETURNING` included. |
| **D1 — the rest of full-text search** | Phrases (`"a b"`, with a prefix last word), prefixes (`foo*`, one range over the term index) and column filters (`body:foo`), composing with `OR` and `NOT`; `AND` was already an operator, not a term. The index format did not change: a phrase or a column filter verifies its candidates against the stored text, so it costs the documents that hold every word. `test_full_text_phrase_prefix_and_column`. |
| **PostgreSQL clients, for real** | Driven with `psql` and psycopg 3, the server had four defects that kept every real driver out: it read one TCP packet as one message (a driver's pipelined Parse/Bind/Describe/Execute/Sync lost everything after Parse and waited forever), it freed a slice of the network buffer when a statement name was reused (the second unnamed Parse killed the process), it sent no `client_encoding` (psycopg's C build crashed), and `Execute` repeated the RowDescription with different types than `Describe` had announced. Fixed, with transactions that span messages, the aborted state, several statements per Query, command tags, SQLSTATE codes, and the dialect: `::`, `SERIAL`, identity columns, `$n`, PostgreSQL's type names, `information_schema`/`pg_catalog.pg_tables`, the session functions. `test_postgres_dialect`, `test_postgres_session_transactions`, `test_postgres_extended_query`. |
| **D9 — the rest of the grammar** | `GROUP BY` on a projection alias, `JOIN … USING` with the merged column printed once, `RANGE`/`GROUPS` frames with offsets in the order value, `BEFORE` triggers, `ALTER TABLE … ALTER [COLUMN] c [SET DATA] TYPE t` (every row rewritten through `CAST`, refused if a value does not convert), a window beside `GROUP BY` (its input rows are the groups, so `sum(count(*)) OVER ()` is the total of the per-group counts), a window inside a larger expression (filled into a hidden slot before the projection is evaluated), host functions from SQL and from C, and host collations: a program registers a comparison and SQL names it with `COLLATE`, asked wherever a comparison happens and refused - with the reason - where the engine would have to fold the text into a key. An unknown collation name is refused too, as SQLite refuses it. `test_group_by_a_projection_alias`, `test_join_using`, `test_window_range_and_groups_frames`, `test_before_triggers`, `test_alter_column_type`, `test_windows_beside_group_by`, `test_windows_inside_expressions`, `test_host_functions`, `test_host_collations`, `scripts/capi_smoke.py`. |
| **Diagnostics — a leak report a human can read** | The `+++ leak` lines were real: five live allocations per read, most of them error messages a caller had asked for and dropped ("table _view is not visible to this transaction", built once per statement). `tx_table_probe` now answers "is that a table?" without building anything, `error_free` gives a message back, and the rest were the lexer's quoted text, the read set, the plan's steps, the projection names, a `to_lower` copy per comparison, the `EXPLAIN` fragments, `PRAGMA`'s lowered name and its rows array, and the slices a `RETURNING` that never returns builds. A tombstone now frees the row values it dropped. `tools/leakcheck` reports zero for every read shape and a flat count for writes, printing the file and line of anything left behind; `scripts/leaks.py` applies the budgets and measures the CLI working set (gate 25). The suite's own line count fell from 289 878 to 116 741 and the remainder is test-side. |
| **D18a — writer lock** | `<directory>/lock` held with an OS lock (Windows `LockFileEx`, POSIX `fcntl`), released on close and on death; the refusal names the owner. `test_writer_lock` and `scripts/lock_smoke.py` with two processes. |
| **D18b — a reader beside the writer** | Two lock bytes: the writer's exclusive, the reader's shared. A read-only open replays, refuses every mutation and waits out a compaction; a paged database opens from `<db>/catalog` and trusts the page files only when every sequence agrees (the 60k-row peak fell from 33.9 MiB to 6.4 MiB). `test_read_only_opens_beside_a_writer`, `test_trusted_open_skips_the_replay`. |
| **D18c — broker mode** | `miraidb-server` owns the directory and serves HTTP wire messages, TCP frames with a per-connection owner, and Postgres; `scripts/broker_smoke.py` runs two processes, reads a write from a second client and refuses a second owner. |
| **D22 — the server, for real** | A thread per connection, so a subscriber no longer blocks anyone; `host.on_update` wired to the transport, so a subscription delivers a delta per commit (`scripts/broker_smoke.py` holds a subscription open, writes from another client and reads the delta); `ATTACH`, `LOAD EXTENSION` and `VACUUM INTO` refused to clients with `Permission_Denied` unless the server was started with `--allow-host` (`test_host_statements_need_host_access`); `--statement-timeout-ms` cancels a statement that outlives it and the server keeps serving (the gate proves the error, the survival and the untouched table). `docs/security.md` states what a token buys and what is not defended. Statements still run one at a time, which the store's single identity field requires. |
| **D24 — the `.sqlite` mirror** | A file stays readable through DDL: the full rewrite honours the room the 100-byte header needs, so an empty `sqlite_master` (a dropped last table) no longer writes a malformed file; an imported file's indexes are read and recreated, so a plan walks one and `DROP INDEX` finds it. `scripts/sqlite_abi_smoke.py` runs `DROP TABLE`, `ALTER TABLE`, `INSERT`, `DROP INDEX` and `CREATE INDEX` through the facade and verifies integrity, rows and `sqlite_master` with Python's `sqlite3`; `test_empty_export_is_a_readable_file` and `test_imported_indexes_are_planned_and_droppable` cover the two defects. |
| **D30 — the differential and the gate** | `differential.py` decides the row order from the statement's own top-level `ORDER BY` (a window's `OVER (… ORDER BY …)` no longer counts, so the three window queries that were reported as differences now agree), compares a cell by type as well as value, and carries 94 queries with 6 refusals and 7 intentional differences. It found the printf format bug on the way. `bench.py` fails on bytes per row (10%) and reports every time metric twice per run with its spread, because this machine moves one by 30x with no code change; `--strict-time` enforces 10% on a quiet box. |
| **D26 — docs whose claims are executed** | The compatibility matrix is a table CI runs: `docs/sqlite.md` carries a ```compat block of sixteen claims — `matches` (both engines agree), `ours` (this engine answers what is written and SQLite answers something else) and `refused` (the statement fails with the reason named) — and `scripts/compat_check.py` runs each through the CLI's `--json` and through SQLite's Python module on separate in-memory databases. Writing it corrected two sentences: `printf('%.0f', 2.5)` answers 2 here and 3 in SQLite (this engine rounds half to even, SQLite half away from zero), and the split is now a row rather than prose. Gate 24, so a claim that stops being true fails CI. |
| **D27 — the mirror keeps the schema it does not model** | A rewrite re-emits the file's own text for every object it did not change: `ALTER TABLE parent …` leaves `child`'s `REFERENCES … ON DELETE CASCADE`, `CHECK`, `DEFAULT` and `COLLATE` alone, keeps the views and triggers, and — with the automatic indexes D33 taught the writer to number — keeps a table whose declaration spells a `UNIQUE` column, a text or a composite `PRIMARY KEY` exactly as it was, `sql` and index numbers included. `--mirror-report` names whatever had to be rebuilt (`mirror-lost:`). What a rebuild still cannot hold is stated: the table the DDL itself changed, a `GENERATED` column (SQLite computes it and does not store it) and a `WITHOUT ROWID` table (its rows have no rowid to patch). `scripts/sqlite_abi_smoke.py` compares `sqlite_master` before and after an `ALTER` for the plain, keyed and declaration-backed shapes and proves a duplicate is still refused; `test_rewrite_keeps_a_keyed_table_as_it_was` does it through the engine's own mirror. |
| **D25 — the C ABI, completely** | 33 `miraidb_*` exports and 43 `sqlite3_*` exports reach every lever the engine has: `miraidb_open_ex` (read-only, in-memory, no-sync, paged), `miraidb_interrupt`/`sqlite3_interrupt` (the cancellation belongs to the statement, so the connection keeps serving), the two caps and `miraidb_work_used`, and an identity — `miraidb_set_identity`, `miraidb_identity`, `miraidb_issue_token`, `miraidb_authenticate`, which answers `MIRAIDB_DENIED` for an unknown or expired token and changes nobody. A token is a row of the database, so the lookups were moved from `Host` to `Store` (`store_token_key`, `store_authenticate`); the key cache moved with them, which stopped a leak, and `_meta` is created on first use because an embedded database has no host to create it. The `sqlite3_*` face answers SQLite's primary result codes and, when asked, the narrow constraint ones (`_PRIMARYKEY` 1555, `_UNIQUE` 2067, `_NOTNULL` 1299); `include/miraidb.h` states the threading contract. `scripts/capi_smoke.py` proves the round trip across a reopen, a policy hiding another caller's rows, an expired token and a connection that never authenticated; `scripts/sqlite_abi_smoke.py` proves each code in both modes. |
| **D33 — the export writes a schema it can back** | A primary key is declared in the exported table text and its index is written as the automatic index a declaration implies (`sqlite_autoindex_<table>_1`, no SQL), so a text key, a composite key and a `UNIQUE` column all leave a file `PRAGMA integrity_check` calls `ok` and that refuses a duplicate and a null key — where a text key used to produce "wrong # of entries in index sqlite_autoindex_k_1" and a `UNIQUE` column was silently dropped. An import reads a column `UNIQUE`, a table-level `UNIQUE (a, b)` and a table-level `PRIMARY KEY (a, b)` out of the table text and recreates them, so the constraint survives the trip and is enforced afterwards. `test_keys_cross_a_sqlite_file_both_ways`, `test_import_keeps_the_keys_sqlite_declared`, and the `src/tests/fixtures/keys.sqlite` fixture (five shapes whose automatic indexes carry no SQL). |
| **D32 — bytes and characters** | Three edges fixed: the CLI decodes its arguments from the wide command line (`src/cli/args_windows.odin`), so `SELECT 'é'` reaches the parser as `C3 A9` instead of one ANSI byte; `hex()` of text iterates the bytes rather than runes, so `hex('é')` is `C3A9` where it answered `E9`; and both JSON writers escape a byte that is not part of a UTF-8 sequence as `\u00XX`, so `--json` output always parses (`test_text_is_bytes_and_json_stays_valid`, and `scripts/shell_smoke.py` sends the statement through argv and checks the document). |
| **D28 — opening in memory** | `:memory:`, the empty path, `file::memory:`, `file::memory:?cache=shared` and `file:<name>?mode=memory` open a private in-memory database: `store_path_is_memory` recognises the spellings in `store_open`, the one door the CLI, the C ABI and the facade all go through, so none of them needed its own rule. `test_open_in_memory_the_way_sqlite_does` opens all five, writes, reads and proves a second open is empty and no directory was made; `scripts/capi_smoke.py` and `scripts/sqlite_abi_smoke.py` open each spelling through the DLL. |
| **D29 — handles, and the bind index** | The embedding layers keep a set of live handles (`src/engine/handles.odin`) and check a handle by value before dereferencing it, so a statement used after `finalize` or through a closed connection answers `MIRAIDB_MISUSE`/`SQLITE_MISUSE` instead of reading freed memory, and a second `finalize` does nothing. Closing a connection finalizes the statements it still owns, so they become misuse too. `embed_prepare` parses eagerly, which gives `Embed_Parameter_Count` and turns a bind past it into `SQLITE_RANGE` (25) instead of a silent growth; a syntax error now fails at prepare. `test_bind_range_and_live_handles` covers the range and the registry; `scripts/capi_smoke.py` and `scripts/sqlite_abi_smoke.py` run the hostile sequences through both DLLs. |
| **D31 — the wrong answers** | Text positions count characters, so `length('héllo')` is 5, `instr` answers a character position and `substr` follows SQLite for a negative start, a start of zero and a negative length (`test_text_positions_count_characters`, 21 cases); `WHERE` converts a text to a number first, so `WHERE 'a'` keeps no row (`test_text_truth_is_numeric`, 17 literals); `--json` and the engine JSON writer keep the `.0` on a real, with `json_type`/`json_extract` agreeing on the type (`test_json_keeps_real_type`, `scripts/shell_smoke.py`); `INSERT OR REPLACE` deletes on any unique conflict and inserts, without delete triggers (`test_insert_or_replace`). |
| **D6 — the join constants** | The join delta, the probe, the order searched by cost with measured constants, the range written as two comparisons, the subscription walking the planned order, and the star expanded from the statement. Each has its test (`test_join_subscription_walks_the_planned_order`, `test_plan_reads_a_range_written_as_two_comparisons`, `test_plan_does_not_cross_join_before_it_can_filter`, …) and gate 7 judges the plan by rows visited. |
| **D8 — fault injection** | `Fault_Vfs` fails any operation at any call, or writes short; `test_fault_injection` arms every write of a workload and proves the reopen sees exactly the commits that reported success. |
| **Benchmark gate** | `benchmarks/baseline.json` plus `scripts/bench.py --check`: bytes per row within 10% of the baseline, which is a property of the format and the one thing CI can fail on. Every time metric is measured **twice in the same run** and reported with its spread, because three runs of one workload on this machine gave 15.6, 22.6 and 46.3 µs for a read transaction and 5.3 and 73.6 ms for a commit with a reader open. `--strict-time` fails on 10% against the baseline and is for a quiet box (`--record` first). |
| **D11 — DDL inside a transaction** | Index operations are staged like row changes, applied after them, and rolled back with them; `DROP INDEX` finds an index created earlier in the same transaction and a duplicate create is refused before apply (`test_ddl_in_transaction`). |
| **D1 — full-text index and BM25** | The `term` index is created with the table, `rank` is BM25 over the postings, `snippet`/`highlight` mark the match, and a rare term visits at most 8 rows of 5 000 (`test_full_text_ranking`, `test_full_text_cost`). |
| **D13 — the stored result on a retry** | The response commits with the request id and `host_call_once_result` answers a retry with it (`test_idempotent_result`). |
| **D17 — rows on disk** | A store opened with `paged_tables` keeps each table in a 4 KiB-page file under `<db>/tables`: a cache over the log, flushed after the log record is durable, frame 0 reserved for the header. A single-table query streams the pages; `ORDER BY`/`GROUP BY`/`DISTINCT`/windows/`AS OF`/joins/staged writes fall back to collecting. `scripts/page_rss.py` is a gate: a table 63× the pool adds 316 KiB to the statement and four times the rows adds the same. |
| **D19 — `CASE` expressions** | Both forms, anywhere an expression is allowed, including policies and triggers; `NULL` conditions match nothing, no `ELSE` gives `NULL`, only the chosen branch is evaluated. `test_case_expressions`, and seven `CASE` queries in the differential corpus. `GROUP BY` on a projection alias is still D9. |
| **D20 — differential runner** | `scripts/differential.py` is a gate: 94 queries answer identically through this engine and the system `sqlite3`, 6 statements are refused with a reason and 7 differ on purpose. It found the ORDER BY tie order (fixed with a row-id tiebreak) and the missing scalar `min`/`max` and `trim(s, chars)` (fixed); a refusal that stops refusing fails the gate. Its two blind spots (a window's `ORDER BY` read as the result's order, and `1` compared as `1.0`) were fixed in **D30**, and the corpus grew from 55 to 94 then. |
| **D5 — index keys in pages** | Each index of a paged table is a B+tree of 4 KiB pages under `<db>/indexes/…` with its own pool, chained leaves and a cursor without a parent stack; point lookups, ranges, `UNIQUE`, updates, deletes and `TRUNCATE` go through the pages. An empty leaf is not merged yet (a delete never answers wrongly). |
| **D6 — the planner** (the first half) | `ANALYZE` measures rows, distinct values, NULLs, the numeric range and a sixteen-bucket histogram into `<db>/stats`; the planner prices scan against probe and prints `est. N rows, cost C`; joins run in the planned order with each `ON` attached to the step that completes the relations it names. `scripts/plan_check.py` guards the plans (`test_analyze_and_plan_estimates`, `test_plan_reorders_a_join`). The join delta is item 2, and the order is searched by cost: a produced row is measured at 5.1 µs and a step whose `ON` cannot be answered yet multiplies by its whole relation, so it runs last (`test_plan_does_not_cross_join_before_it_can_filter`). |
| **D4 — `.sqlite` pages in place** | The mirror patches the leaf of every changed row, the separator its parent stores and page 1: three pages (12 KiB) per commit at 10k, 100k and 250k rows, where re-encoding wrote 172 KiB, 1.8 MB and 4.8 MB. Splits, empty-leaf unlink, free-list reuse and torn-commit recovery through a rollback journal in SQLite's format; `scripts/mirror_cost.py` checks the file with real `sqlite3`. |
| **D3 — `AS OF` and version pruning** | `FROM t AS OF <seq>` reads the versions the table keeps and `store_prune_versions` discards what no reader can ask for (`test_as_of`); automatic retention and `AS OF` on a join remain in D3's backlog entry. |
| **D3 — a read that copies nothing** | A read transaction shares the tables: one reference per table, no rows copied, and the store's read cache is gone with it. A commit that has to change a table a reader holds copies **that** table (`table_cow_clone`), so the copy is per written table and only while a reader is open. The first read after a commit fell from 24 ms to 38 µs on the gate (21 µs over 50 000 rows); the commit that pays for a live reader is 16.9 ms (46 ms over 50 000). `test_a_commit_copies_the_table_a_reader_holds` proves the reader keeps its values, that the table a commit does not write is not copied, and that a commit nobody reads copies nothing; `bench-read` reports both numbers and `scripts/bench.py` gates both. |
| **D7 — scheduler durability** | `_schedule.at_us` is a column and commits; a restart resumes pending work (`test_durability_after_restart`). |
| **D12a / D12b — work budget and module latency** | One unit per row touched, a per-statement and a per-call budget that rolls the call back (`test_work_budget`); one pooled socket per module, one frame each way. |
| **Page memory gate** | `scripts/page_rss.py --check` reads a table far larger than the pool and bounds what the statement adds; `scripts/plan_check.py` guards the plans a measured fixture must produce. |
| **Sanitizer pass (bounds and stack)** | The suite runs under `-sanitize:address` with no bounds or stack report; the heap half is backlog D34, because Odin's allocator on Windows bypasses the sanitizer's interception (verified with a deliberate use-after-free). |
| **Documentation consistency gate** | `scripts/docs_check.py`: version, test count, gate count, CLI commands, relative links, roadmap/backlog cross-references, orphan documents and the names the project does not use. Backlog D21. |
| **Audit corrections** | Two items once written down as gaps (D7, D13) were already durable, two wrong answers in `IN`/`NOT IN` and `DISTINCT` aggregates were found and fixed with tests, and the capabilities that three documents understated (the README, the CLI usage and the SQLite matrix) were rewritten. |

The three asks of the original plan — access from several processes, a per-term
full-text index, and pages on disk — are all closed above. What remains is
depth, not absence.
