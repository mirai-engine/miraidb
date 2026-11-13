# SQLite compatibility

The engine speaks its own on-disk format (`.miraidb`/`.mdb`, a commit log plus
snapshots) and also reads and writes SQLite databases (`.sqlite`/`.db`). Opening
a SQLite file imports it; `export-sqlite` writes one back. On top of that, the
SQL surface, functions and pragmas follow SQLite where it matters.

The inventory is generated from the reference source (SQLite 3.54.1) so it never
drifts: `python3 scripts/sqlite_inventory.py --sqlite ../sqlite` writes
`docs/sqlite-inventory.md` with every keyword, built-in function and pragma.

This matrix records what is done, partial or missing. A row is `done` only when
a test covers it.

## File format

| Feature | Status | Notes |
|---|---|---|
| Header, page size, encoding | done | 512..65536 pages, reserved bytes, UTF-8 |
| sqlite_master and schema SQL | done | tables and their CREATE statements |
| Table b-trees, leaf and interior | done | rowid tables, multi-level trees |
| WITHOUT ROWID (index b-trees) | done | read path |
| Varints and serial types | done | all widths, 0/1 shortcuts, floats, text, blob |
| Overflow chains | done | read and write |
| Write a valid database | done | `export-sqlite`, integrity-check clean, freelist trunk |
| Freelist reuse | todo | export always packs fresh |
| WAL and journal replay | todo | the engine has its own log |
| Page-level checksums (reserved bytes) | todo | reserved byte is written as 0 |

## Statements

| Feature | Status | Notes |
|---|---|---|
| SELECT with joins, subqueries, aggregates | done | engine syntax |
| INSERT / UPDATE / DELETE | done | `RETURNING` with `*` or a column list |
| CREATE/DROP TABLE, ALTER ADD COLUMN | done | `ALTER` is add-only |
| CREATE/DROP INDEX, UNIQUE | done | btree, hash, direct |
| CREATE/DROP VIEW | done | views with parameters |
| CREATE TYPE | done | engine extension |
| CREATE EVENT TABLE | done | engine extension |
| TRUNCATE | done | engine extension |
| BEGIN/COMMIT/ROLLBACK | done | session API and CLI REPL |
| SAVEPOINT/RELEASE/ROLLBACK TO | todo | |
| UPSERT (ON CONFLICT DO UPDATE) | partial | `DO NOTHING` and `DO UPDATE`; `excluded` pending |
| WITH (common table expressions) | todo | |
| ATTACH/DETACH | todo | single database |
| VACUUM / ANALYZE / REINDEX | partial | `compact` is the engine's VACUUM |
| PRAGMA | partial | see the list below |
| EXPLAIN / EXPLAIN QUERY PLAN | partial | engine plan output |
| CREATE TRIGGER | todo | reducers cover the use case |
| CREATE VIRTUAL TABLE (FTS5, R-Tree) | todo | extension modules |
| GENERATED / STRICT / WITHOUT ROWID DDL | partial | accepted where harmless |
| `ANY` columns (dynamic typing) | done | storage classes kept per value, `typeof()` reports them |

## Expressions and clauses

| Feature | Status | Notes |
|---|---|---|
| WHERE, ORDER BY, LIMIT/OFFSET | done | |
| GROUP BY, HAVING | done | |
| DISTINCT | done | |
| IN, EXISTS, scalar subqueries | done | |
| CASE, COALESCE, NULLIF | done | |
| LIKE, GLOB, ESCAPE | done | LIKE ignores ASCII case; GLOB is exact with `*`, `?`, `[...]` |
| `||` string concatenation | done | tested with text and numbers |
| COLLATE (BINARY, NOCASE, RTRIM) | todo | |
| Window functions, FILTER | todo | |
| UPSERT | partial | `excluded` pending |

## Functions

Implemented: `abs`, `ceil`, `char`, `coalesce`, `concat`, `format`/`printf`,
`floor`, `hex`, `iif`, `ifnull`, `instr`, `length`, `lower`, `ltrim`, `mod`,
`now`/`current_timestamp`, `nullif`, `pow`, `quote`, `random`-free `uuid`,
`replace`, `round`, `rtrim`, `sign`, `sqlite_version`, `sqrt`, `substr`,
`substring`, `trim`, `typeof`, `upper`, plus `count`, `sum`, `avg`, `min`,
`max`, `total`.

Missing, in rough order of value: `date`/`time`/`datetime`/`strftime`/
`julianday` (the engine has timestamps but no calendar arithmetic),
`json_*` / `jsonb_*`, `unhex`, `printf` width and precision flags, `random`,
`zeroblob`, `soundex`, `group_concat`, `changes`, `last_insert_rowid`,
the math library beyond the basic set, and the ordered-set aggregates.

## Pragmas

done: `table_info`, `index_list`, `index_info`, `foreign_key_list`,
`database_list`, `table_list`, `user_version` (get and set), `application_id`,
`schema_version`, `page_size`, `encoding`, `journal_mode`, `foreign_keys`,
`integrity_check`, `quick_check`, `sqlite_version`, `compile_options`.

todo: `cache_size`, `busy_timeout`, `mmap_size`, `synchronous`, `temp_store`,
`wal_checkpoint*`, `freelist_count`, `page_count`, `optimize`, `pragma_list`,
`function_list`, `module_list`, `collation_list`, `data_version`.

## Embedding and tooling

| Feature | Status | Notes |
|---|---|---|
| Odin embedding API | done | `src/engine/embed.odin` |
| C ABI and header | done | `src/capi`, `include/miraidb.h`, ctypes smoke test |
| CLI `.dbinfo`, `.tables`, `.schema` on SQLite files | done | `miraidb sqlite` |
| Import/export | done | `import-sqlite`, `export-sqlite`, auto-detect on open |
| Extension loading | todo | no `load_extension` |
| VFS layer | partial | interface and memory/quota backends; the log is not wired yet |
| Backup API | todo | snapshots cover the case |

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
log is still the truth. A table with a secondary index, a schema change, a file
with a write-ahead log and a tree deeper than three levels re-encode the whole
file instead (`scripts/mirror_cost.py --check` measures it). A failed mirror write
is reported through `last_error` and never fails the commit.

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
