# SQLite compatibility

The engine speaks its own on-disk format (`.miraidb`/`.mdb`, a commit log plus
snapshots) and also reads and writes SQLite databases (`.sqlite`/`.db`). Opening
a SQLite file imports it; `export-sqlite` writes one back. On top of that, the
SQL surface, functions and pragmas follow SQLite where it matters.

The inventory is generated from the reference source (SQLite 3.54.1) so it never
drifts: `python3 scripts/sqlite_inventory.py --sqlite ../sqlite` writes
`docs/sqlite-inventory.md` with every keyword, built-in function and pragma.

This matrix records what is done, partial or missing. A row is `done` only when
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
| Opening in memory | refused | `:memory:`, the empty path and `file:…?mode=memory` are not a database here: an open needs a path. A program written against sqlite3 starts with one of those, so this is the first thing to add (backlog D28) |
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

**Implemented (66 of the 131 names the inventory lists, plus aliases and
families):** `abs` and the trigonometric/logarithmic set (`acos`, `asin`,
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

**Missing, verified by running each one:** `CASE` (a statement, not a function),
`current_timestamp` as a keyword, `ceiling`, `ln`, `power`, `timediff`,
`median`/`percentile`/`percentile_cont`/`percentile_disc`, `soundex`,
`json_patch`/`json_insert`/`json_pretty`/`json_array_insert`/`json_group_array`/
`json_group_object`/`json_error_position`, the whole `jsonb_*` family,
`unistr`/`unistr_quote`, `likelihood`/`likely`/`unlikely`/`unknown`,
`sqlite_compileoption_used`/`sqlite_compileoption_get`, `sqlite_source_id`,
`sqlite_offset`, `sqlite_filestat`, `sqlite_walstat`, and the names SQLite keeps
for its own internals (`expr_compare`, `fpdecode`, `datedebug`, `oom`,
`affinity`, `parseuri`, `implies_nonnull_row`).

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

**The rewrite re-emits the schema from the engine's model, and that model is
smaller than SQLite's.** A `REFERENCES … ON DELETE CASCADE`, a `UNIQUE`, a
`CHECK`, a `DEFAULT`, a `COLLATE`, a `GENERATED … AS` column, and every view and
trigger are dropped from the file by the first schema change (measured; backlog
D27). Rows, indexes the engine knows, and file integrity survive; the rules do
not. Until D27 lands, treat a schema change on someone else's `.sqlite` file as a
one-way simplification and keep the original. A failed mirror write is reported through `last_error` and
never fails the commit.

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
