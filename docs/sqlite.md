# SQLite compatibility

The engine speaks its own on-disk format (`.miraidb`/`.mdb`, a commit log plus
snapshots) and also reads and writes SQLite databases (`.sqlite`/`.db`). Opening
a SQLite file imports it; `export-sqlite` writes one back. On top of that, the
SQL surface, functions and pragmas follow SQLite where it matters.

The inventory is generated from the reference source (SQLite 3.54.1) so it never
drifts: `python3 scripts/sqlite_inventory.py --sqlite ../sqlite` writes
`docs/sqlite-inventory.md` with every keyword, built-in function and pragma.

This matrix records what is done, partial or missing; how much of the surface
runs, and the plan for the rest, is [sqlite-roadmap.md](sqlite-roadmap.md). A row is `done` only when
a test covers it, and `scripts/differential.py` checks the statements and
functions listed here against the system `sqlite3`: the answers must match, or
the statement must be one of the refusals or the intentional differences the
script lists.

## File format

| Feature | Status | Notes |
|---|---|---|
| Header, page size, encoding | done | 512..65536 pages, reserved bytes, UTF-8 |
| sqlite_master and schema SQL | done | tables and their CREATE statements, and their indexes: an imported index is recreated, so a plan walks it and `DROP INDEX` finds it (an index this engine cannot express is retried without its `WHERE`) |
| Table b-trees, leaf and interior | done | rowid tables, multi-level trees |
| WITHOUT ROWID (index b-trees) | done | read path |
| Varints and serial types | done | all widths, 0/1 shortcuts, floats, text, blob |
| Overflow chains | done | read and write |
| Write a valid database | done | `export-sqlite`, integrity-check clean, freelist trunk |
| Freelist reuse | partial | a live mirror frees and reuses pages; an export always packs fresh |
| WAL and journal replay | done | a file with a `-wal` or a hot `-journal` is read through it; the mirror writes a journal in SQLite's format |
| Page-level checksums (reserved bytes) | todo | reserved byte is written as 0 |

## Statements

| Feature | Status | Notes |
|---|---|---|
| SELECT with joins, subqueries, aggregates | done | engine syntax; `INNER`/`LEFT`/`CROSS`, no `NATURAL`/`RIGHT`/`FULL` (refused with a reason) |
| INSERT / UPDATE / DELETE | done | `RETURNING` with `*` or a column list; `INSERT OR REPLACE` deletes on any unique conflict, `OR ABORT` (the default), `OR ROLLBACK`/`FAIL`/`IGNORE` refused with a reason |
| CREATE/DROP TABLE, ALTER | done | `ALTER` adds, drops and renames columns and renames the table; type changes are refused |
| CREATE/DROP INDEX, UNIQUE | done | btree, hash, direct |
| CREATE/DROP VIEW | done | `OR REPLACE`, parameters, materialization |
| CREATE TYPE | done | engine extension |
| CREATE EVENT TABLE | done | engine extension |
| TRUNCATE | done | engine extension |
| BEGIN/COMMIT/ROLLBACK | done | session API and CLI REPL |
| SAVEPOINT/RELEASE/ROLLBACK TO | done | nested, inside one transaction |
| UPSERT (ON CONFLICT DO UPDATE) | done | `DO NOTHING`, `DO UPDATE`, `excluded.*`, with `RETURNING` |
| WITH (common table expressions) | done | recursive included |
| ATTACH/DETACH | done | attaches engine directories, and reads a `.sqlite` file |
| VACUUM / ANALYZE / REINDEX | partial | `compact` is the engine's VACUUM, `VACUUM INTO` writes a copy, `ANALYZE` measures statistics; `REINDEX` does not exist |
| PRAGMA | partial | four classes below: 25 answer, 18 are accepted as no-ops, 11 are refused |
| EXPLAIN / EXPLAIN QUERY PLAN | partial | `EXPLAIN` prints the chosen access path, the estimate and the join order; there is no `EXPLAIN QUERY PLAN` row format |
| Opening in memory | done | `:memory:`, the empty path, `file::memory:` (with or without `?cache=shared`) and `file:<name>?mode=memory` open a private database in the process: the tables live in memory, no directory is made, and every open is a fresh one (`test_open_in_memory_the_way_sqlite_does`; `scripts/capi_smoke.py` and `scripts/sqlite_abi_smoke.py` open each spelling through the DLL) |
| CREATE TRIGGER | done | `BEFORE` and `AFTER` triggers with `WHEN`, `NEW` and `OLD`; a `BEFORE` body that fails stops the write. Column-specific (`OF`) triggers are refused |
| CREATE VIRTUAL TABLE (FTS5, R-Tree) | done | FTS5 with BM25, `snippet` and `highlight`; spatial tables store their boxes as columns |
| GENERATED / STRICT / WITHOUT ROWID DDL | partial | `GENERATED … STORED` and `STRICT` work; `WITHOUT ROWID` is refused for writing and supported for reading |
| `ANY` columns (dynamic typing) | done | storage classes kept per value, `typeof()` reports them |
| CASE | done | simple (`CASE x WHEN …`) and searched (`CASE WHEN …`) forms, anywhere an expression is allowed, including policies and triggers |

## Expressions and clauses

| Feature | Status | Notes |
|---|---|---|
| WHERE, ORDER BY, LIMIT/OFFSET | done | stable sort, NULLs first |
| GROUP BY, HAVING | done | `HAVING` takes the expression, not a projection alias |
| DISTINCT | done | over the projected row, and inside an aggregate (`count(DISTINCT x)`) |
| IN, EXISTS, scalar subqueries | done | three-valued logic: a `NULL` in the list makes a non-match unknown |
| CASE, COALESCE, NULLIF | done | `CASE` in both forms; `COALESCE` and `NULLIF` as functions |
| LIKE, GLOB, ESCAPE | done | LIKE ignores ASCII case; GLOB is exact with `*`, `?`, `[...]` |
| `||` string concatenation | done | tested with text and numbers |
| COLLATE (BINARY, NOCASE, RTRIM) | done | on a column, in comparisons, in unique keys and index probes |
| Window functions, FILTER | partial | `OVER` with `PARTITION BY`/`ORDER BY` and `ROWS`/`RANGE`/`GROUPS` frames; aggregate `FILTER (WHERE …)` is not implemented, and windows beside `GROUP BY` are refused |
| Foreign keys | done | `ON DELETE`/`ON UPDATE` `RESTRICT`/`CASCADE`, enforced on every path |
| `AS OF <seq>` | done | engine extension: read a table as it was |

## Functions

**Implemented (73 of the 121 user-facing names, measured by
`scripts/sqlite_gaps.py`):** `abs` and the trigonometric/logarithmic set (`acos`, `asin`,
`atan`, `atan2`, `cos`, `sin`, `tan`, `degrees`, `radians`, `pi`, `exp`,
`log`, `log2`, `log10`), `ceil`/`floor`/`round`/`trunc`/`sign`/`sqrt`/`pow`/
`mod`, `char`, `unicode`, `hex`, `unhex`, `quote`, `format`/`printf`,
`coalesce`, `iif`, `ifnull`, `nullif`, `length`, `octet_length`, `lower`,
`upper`, `ltrim`, `rtrim`, `trim`, `replace`, `concat`, `concat_ws`, `instr`,
`substr`/`substring`, `glob`, `like`, `typeof`, `min(a, b, …)`/`max(a, b, …)`
as scalars, `trim`/`ltrim`/`rtrim` with a character set, `random`, `zeroblob`,
`uuid` (only when the host supplies a randomness source), `randomblob`,
`changes`, `total_changes`, `last_insert_rowid`, `sqlite_version`, `date`,
`time`, `datetime`, `strftime`, `now`, eleven `json_*` scalars and the
`json_each`/`json_tree` table functions,
`group_concat`/`string_agg`, `rank`, `snippet`, `highlight`, `current_identity`
and `has_role` (engine extensions), plus `count`, `sum`, `avg`, `min`, `max`,
`total`.

**Missing:** the list `scripts/sqlite_gaps.py --missing` prints, grouped by
roadmap item in [sqlite-roadmap.md](sqlite-roadmap.md) (S4 and S5).

## Pragmas

The engine sorts the 63 names in the inventory into four classes:

- **25 answer with data**: `application_id`, `cache_size`, `compile_options`,
  `data_version`, `database_list`, `encoding`, `foreign_key_check`,
  `foreign_key_list`, `foreign_keys`, `freelist_count`, `function_list`,
  `index_info`, `index_list`, `integrity_check`, `journal_mode`,
  `max_page_count`, `mmap_size`, `page_count`, `page_size`, `pragma_list`,
  `quick_check`, `schema_version`, `sqlite_version`, `stats` (engine
  extension), `synchronous`, `table_info`, `table_list`, `table_xinfo`,
  `user_version`.
- **18 are accepted as no-ops** because the engine has no equivalent knob:
  `auto_vacuum`, `automatic_index`, `busy_timeout`, `cache_spill`,
  `cell_size_check`, `checkpoint_fullfsync`, `count_changes`,
  `default_cache_size`, `fullfsync`, `full_column_names`, `hard_heap_limit`,
  `journal_size_limit`, `optimize`, `secure_delete`, `short_column_names`,
  `soft_heap_limit`, `threads`, `wal_autocheckpoint`, `wal_checkpoint`.
- **11 are refused with a reason**, because accepting them would promise a
  guarantee the engine does not give: `case_sensitive_like`,
  `defer_foreign_keys`, `ignore_check_constraints`, `legacy_alter_table`,
  `locking_mode`, `query_only`, `read_uncommitted`, `recursive_triggers`,
  `reverse_unordered_selects`, `trusted_schema`, `writable_schema`.
- **The rest are unknown** and answer an error (`collation_list`,
  `module_list`, `incremental_vacuum`, `shrink_memory`, `legacy_file_format`,
  `soft_heap_limit64`, `data_store_directory`, `temp_store_directory`,
  `temp_store`).

## Semantics that differ from SQLite

These are decisions, not accidents, and a program that relies on SQLite's
behaviour here will see different results:

| Case | SQLite | This engine |
|---|---|---|
| `1/0` | `NULL` | error `invalid_argument: division by zero` |
| `CAST('abc' AS INTEGER)` | `0` | error `invalid_type` |
| `9223372036854775807 + 1` | a float | wraps to `-9223372036854775808` |
| `CAST(300 AS TINYINT)` | `300` (INTEGER affinity) | error: the value does not fit the declared width |
| `WHERE int_col = '1'` | compares through affinity | error `cannot compare int with string` |
| `HAVING c > 1` where `c` aliases `count(*)` | works | error `column c does not exist` |

## The claims in this file are executed

Every row below is run by `scripts/compat_check.py`, which is a gate: the
statement goes through this engine (its `--json` output) and through SQLite's
Python module, each on its own in-memory database. `matches` means both answer
the same thing, `ours` means this engine answers what is written while SQLite
answers something else — a difference the sections above state on purpose — and
`refused` means the statement has to fail with a message that contains the word.
A claim that stops being true fails the gate, which is the point: a compatibility
document that nobody runs is a document that drifts.

```compat
# claim | statement | answer, one list per row
matches | SELECT length('héllo')                          | [[5]]
matches | SELECT octet_length('héllo')                    | [[6]]
matches | SELECT instr('héllo', 'l')                      | [[3]]
matches | SELECT substr('héllo', -3, 2)                   | [["ll"]]
matches | SELECT hex('é')                                 | [["C3A9"]]
matches | SELECT printf('%05.2f', 3.14159)                | [["03.14"]]
matches | SELECT json_type('1.0')                         | [["real"]]
matches | SELECT typeof(1), typeof(1.0), typeof('1')      | [["integer", "real", "text"]]
matches | SELECT round(2.5), round(-2.5)                  | [[3.0, -3.0]]
matches | SELECT 'abc' LIKE 'A%'                          | [[1]]
matches | SELECT printf('%.0f', 2.5)                      | [["2"]]
ours    | SELECT upper(char(233))                         | [["É"]]
refused | SELECT 1 = '1'                                 | invalid_type
refused | SELECT CAST('12abc' AS INTEGER)                | invalid_type
refused | SELECT 1/0                                     | division by zero
refused | CREATE TABLE z (a INT) WITHOUT ROWID           | WITHOUT ROWID
```

One row is a real difference: `upper` folds the whole of Unicode, where SQLite
folds ASCII only, so `upper(char(233))` is `É` here and `é` there. The
`printf('%.0f', 2.5)` row used to be a second one (this engine rounds half to
even and older SQLite rounded half away from zero); SQLite 3.45 answers `2` as
well, so the row is now a match, and the gate is what noticed.

## Embedding and tooling

| Feature | Status | Notes |
|---|---|---|
| Odin embedding API | done | `src/engine/embed.odin` |
| C ABI and header | done | `src/capi`, `include/miraidb.h`, ctypes smoke test |
| CLI `.dbinfo`, `.tables`, `.schema` on SQLite files | done | `miraidb sqlite` |
| Import/export | done | `import-sqlite`, `export-sqlite`, auto-detect on open |
| Extension loading | done | `LOAD EXTENSION <name> AT 'host:port'` runs it out of process; the ABI is v1/v2 |
| VFS layer | done | OS, memory and quota backends; the commit log, the page files and the statistics file go through it |
| Backup API | done | `miraidb_backup` in the C ABI, `VACUUM INTO` in SQL |
| Extended result codes | done | `sqlite3_extended_result_codes(db, 1)` turns on the narrow constraint codes — `SQLITE_CONSTRAINT_PRIMARYKEY` (1555), `_UNIQUE` (2067), `_NOTNULL` (1299) — and `sqlite3_errcode` plus the return value of `exec`/`step` answer them while the mode is on; `sqlite3_extended_errcode` answers the narrow code in either mode, as SQLite's does. A failure that is not a constraint keeps its primary code, because a narrow code only exists to say which constraint failed |
| Identity from C | done | the `miraidb_*` face carries an identity and a token (`miraidb_set_identity`, `miraidb_identity`, `miraidb_issue_token`, `miraidb_authenticate`), so row policies are reachable from C; the `sqlite3_*` face has no such concept, because SQLite has none |
| Result codes | done | the `sqlite3_*` face answers SQLite's primary codes: `SQLITE_CONSTRAINT` (19) for a duplicate key or a null in a key column, `SQLITE_MISMATCH` (20) for a type the comparison cannot reconcile, `SQLITE_INTERRUPT` (9) when a cancellation landed, `SQLITE_RANGE` (25) for a bind past the parameters, and `SQLITE_ERROR` (1) for a syntax error or a missing table, which is what SQLite does too. `sqlite3_errcode` reports the same code the failing call returned |
| Open flags | done | `miraidb_open_ex(path, flags)` takes `MIRAIDB_OPEN_READ_ONLY`, `_IN_MEMORY`, `_NO_SYNC` and `_PAGED`; a reader refuses every write ("cannot insert in a read transaction"), an in-memory database creates nothing on disk, and `miraidb_open` is the same call with no flags. A path that is already a SQLite file is imported into memory and mirrored back after each commit, which the header states |
| Caps and interrupt | done | `miraidb_set_row_quota` and `miraidb_set_work_budget` cap one statement and `miraidb_work_used` reports the spend; `miraidb_interrupt` and `sqlite3_interrupt` ask a running statement to stop. A cap belongs to the connection's session and reaches nothing in the log, and the next statement starts with a clean cancel flag, so an interrupted connection stays usable |

## The course harness

`codecrafters-sqlite/run_stages.py` (outside the repository) drives the nine
stages of *Build your own SQLite* against a real SQLite database: page size,
table count, table names, row counts, single and multiple columns, WHERE,
full-table scan and an indexed lookup. All nine pass.

## A live `.sqlite` file

Opening a database with `embed_open` (or any path whose magic bytes are SQLite)
imports it into memory and remembers the file: **every later commit patches that
file**, so it stays a SQLite database another driver can read and
`PRAGMA database_list` names it. Only the pages a commit changed are rewritten —
the leaf of each changed row, the separator its parent stores, and page 1 — three
pages (12 KiB) at any table size; `docs/file-format.md` describes the layout, the
free list and the rollback journal that makes a torn commit harmless. The commit
log is still the truth. A table with a secondary index, a file with a
write-ahead log, a tree deeper than three levels **or any schema change**
re-encode the whole file instead (`scripts/mirror_cost.py --check` measures it).
That full rewrite is the path a `DROP TABLE` takes. It used to leave the file
malformed for `sqlite3` when the last table was dropped — the empty tree the
`sqlite_master` root is built from ignored the room the 100-byte file header
needs — and `scripts/sqlite_abi_smoke.py` now runs `DROP TABLE`, `ALTER TABLE`,
`DROP INDEX` and `CREATE INDEX` through the facade and verifies the result with
Python's `sqlite3`.

**The rewrite now keeps every object it was not asked to change.** Each catalog
entry is remembered as the file spelled it, and a rewrite re-emits that text for
a table whose schema the engine did not touch, and for every view and trigger —
so `ALTER TABLE parent …` leaves `child`'s `REFERENCES … ON DELETE CASCADE`,
`CHECK`, `DEFAULT` and `COLLATE` alone and keeps the views and triggers
(`scripts/sqlite_abi_smoke.py` compares `sqlite_master` before and after).

A table whose declaration spells a key is kept too, and that is where the
numbering matters: SQLite creates an automatic index for each key in the order
the constraints appear, so the rewrite writes `sqlite_autoindex_<table>_1`,
`_2` … in that same order, each with the b-tree of the engine index that carries
it. `CREATE TABLE m2 (a TEXT PRIMARY KEY, b TEXT UNIQUE)` keeps both, and so does
a table whose `UNIQUE` is declared after the primary key.

What is still rebuilt from the engine's model, and reported by `--mirror-report`
as `mirror-lost:`:

- the table the DDL itself changed, which loses `REFERENCES`, `CHECK`, `DEFAULT`,
  `COLLATE` and a generated column;
- a table with a `GENERATED` column (SQLite computes it and does not store it) or
  one declared `WITHOUT ROWID` (its rows have no rowid to patch).

Rows, indexes the engine knows, and file integrity survive in every case; a table
rebuilt this way loses its rules and says so. A failed mirror write is reported through `last_error` and
never fails the commit.

## Keys in a written file

The exported text declares the primary key the way SQLite declares it, including
a text one and a composite one, and the index the declaration implies is written
as SQLite writes it: a master row named `sqlite_autoindex_<table>_1` with no SQL,
holding the key's b-tree. A file without that row is one SQLite refuses to read
("wrong # of entries in index sqlite_autoindex_k_1"), which is what a text key
used to produce. A `UNIQUE` column is the other way round: it travels as a named
`CREATE UNIQUE INDEX` row and does not appear in the text, because a declaration
would ask for a second, automatic index. The integer key that is the rowid gets
neither, since the row's own key is the index.

An import reads all of it back out of the table text — a column `UNIQUE`, a
table-level `UNIQUE (a, b)`, a table-level `PRIMARY KEY (a, b)` — because the
automatic index rows carry no SQL to read. `src/tests/fixtures/keys.sqlite` is
that shape written by real `sqlite3`, and
`test_import_keeps_the_keys_sqlite_declared` proves the constraint is enforced
after the import and again after the export.

## Export determinism

An export is always a fresh build: pages are allocated in a fixed order from an
empty file, tables are laid out by name and rows by row id. So two exports of
the same state are byte-identical, including one taken after the log is
replayed, and an exported file never carries free pages. `PRAGMA freelist_count`
on our own export is therefore always 0.

## Incremental BLOB I/O

`sqlite3_blob_open` addresses a row by its single-column primary key, which is
what SQLite calls a rowid alias. The handle copies the column, `sqlite3_blob_read`
and `sqlite3_blob_write` work inside that copy (a write cannot grow it, as in
SQLite), and `sqlite3_blob_close` writes a dirty handle back with one `UPDATE`.
`sqlite3_blob_reopen` reloads the handle against another row of the same column.
