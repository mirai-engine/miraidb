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
| sqlite_master and schema SQL | done | tables and their CREATE statements, views, triggers, `sqlite_sequence` and the header's `user_version` and `application_id`, read and written; indexes: an imported index is recreated, so a plan walks it and `DROP INDEX` finds it (an index this engine cannot express is retried without its `WHERE`) |
| Table b-trees, leaf and interior | done | rowid tables, multi-level trees |
| WITHOUT ROWID (index b-trees) | done | read from a file, and created with `CREATE TABLE … WITHOUT ROWID`: the primary key is required and is the row's identity, `rowid` names nothing, and the option survives a reopen. An export writes it as SQLite stores it: an index b-tree keyed by the primary key (its columns first, then the others), with its own text and no `sqlite_master` row for the key; a secondary index ends in the key's columns instead of a rowid; a scan walks the table in key order. Reading one from a file puts each column back in its declared place, and reads the entries an index b-tree keeps in its interior pages |
| Varints and serial types | done | all widths, 0/1 shortcuts, floats, text, blob |
| Overflow chains | done | read and write |
| Write a valid database | done | `export-sqlite`, integrity-check clean, freelist trunk |
| Freelist reuse | partial | a live mirror frees and reuses pages; an export always packs fresh |
| WAL and journal replay | done | a file with a `-wal` or a hot `-journal` is read through it; the mirror writes a journal in SQLite's format |
| Page-level checksums (reserved bytes) | todo | reserved byte is written as 0 |

## Statements

| Feature | Status | Notes |
|---|---|---|
| SELECT with joins, subqueries, aggregates | done | `INNER`, `LEFT`, `RIGHT`, `FULL`, `CROSS` and `NATURAL` (any of them); a subquery or `VALUES` in `FROM` (a derived table, named `(subquery-N)` when unaliased); `UNION [ALL]`, `INTERSECT` and `EXCEPT` applied left to right; `VALUES (…), (…)` as a statement, with columns `column1`, `column2`, … |
| INSERT / UPDATE / DELETE | done | `RETURNING` with `*`, expressions and aliases, named as SQLite names them. `INSERT` may name the rowid (`rowid`, `oid`, `_rowid_`) of a table without an `INTEGER PRIMARY KEY`; a taken one fails with `UNIQUE constraint failed: t.rowid`. Conflict resolution as SQLite's: `OR ABORT` (the default: a failed statement is undone whole, inside a transaction too), `OR IGNORE` (skips a row that breaks a key or `NOT NULL`), `OR FAIL` (keeps the rows before the failing one), `OR REPLACE` and `REPLACE INTO` (delete the colliding rows, fire no delete trigger). `OR ROLLBACK` is `ABORT` when the statement owns its transaction and ends the transaction a caller opened, as in SQLite. `REPLACE` and UPSERT find the rows the transaction staged as well as committed ones, and `REPLACE` gives an omitted `INTEGER PRIMARY KEY` the next value before the rows it replaces go. `UPDATE OR <resolution>` takes the same five |
| `sqlite_schema` / `sqlite_master` | done | readable in any query shape (joins, subqueries, `EXISTS`), with `type`, `name`, `tbl_name`, `rootpage` and `sql`; it lists what the current transaction created and not what it dropped. The rows are the ones an export writes to the file's own catalog (an automatic index is `sqlite_autoindex_*` with a NULL `sql`). `sql` is the statement as SQLite keeps it: `CREATE TABLE ` (or `INDEX`, `UNIQUE INDEX`, `VIEW`, `TRIGGER`) and the text from the name on, without `IF NOT EXISTS`, `main.` or the terminator, kept in the internal table `_sqlite_sql` with the statement's transaction; `ALTER TABLE` edits it as SQLite does (`ADD COLUMN` appends the definition, `RENAME COLUMN` renames its mentions outside a `REFERENCES`, `RENAME TO` quotes the new name in the table and in its indexes and triggers, `DROP COLUMN` removes the definition), and an engine-only type change drops it. An object imported from a SQLite file keeps the file's text, and one made before the text was kept is rendered from the engine's model. An export writes a table's text only when it describes the record the export stores (the same columns and rowid alias, no `WITHOUT ROWID` or generated column); otherwise the rendering. `pragma table_info` reads each column's declared type from the same text, as SQLite answers it (`varchar(10)`, `TEXT`, or empty). `sqlite_temp_schema` lists the temporary tables |
| `main.` qualifier | done | `main.t` names `t` in reads, writes, DDL and `PRAGMA main.name` |
| CREATE/DROP TABLE, ALTER | done | `CHECK` (column and table, named with `CONSTRAINT` or not), `DEFAULT` (one that calls a function, like `CURRENT_TIMESTAMP`, is evaluated per row), `NOT NULL`, `UNIQUE`, `PRIMARY KEY` with `ASC`/`DESC`. `ALTER` adds, drops and renames columns, changes a column's type and renames the table; they carry along what names the table or the column, as SQLite does: `RENAME TO` moves the table's triggers and renames it in the views and trigger bodies that read it; `RENAME COLUMN` rewrites the CHECK constraints, generated columns, trigger bodies, `UPDATE OF` lists and views that name it (the rewrite works on tokens: a body that reads two tables with a column of that name has only its qualified mentions renamed, where SQLite resolves every name); `DROP COLUMN` takes the column's own CHECK with it, keeps the other indexes, and refuses, in SQLite's words, a key column or one an index or a table CHECK reads. `ON CONFLICT <resolution>` on a `PRIMARY KEY`, `UNIQUE` or `NOT NULL` decides what a row that breaks it does when the statement names no `OR` (`REPLACE` on `NOT NULL` stores the default), and survives a reopen |
| CREATE/DROP INDEX, UNIQUE | done | btree, hash, direct; `ASC`/`DESC` columns accepted (they order SQLite's storage, not an answer). Partial indexes (`WHERE`) and indexes over expressions, enforced when UNIQUE and exported with their own entries; a query does not read them yet (backlog D36). A UNIQUE index takes any number of NULLs, and one the rows already break is refused |
| CREATE/DROP VIEW | done | `OR REPLACE`, parameters, materialization |
| CREATE TYPE | done | engine extension |
| CREATE EVENT TABLE | done | engine extension |
| TRUNCATE | done | engine extension |
| BEGIN/COMMIT/ROLLBACK | done | session API, CLI REPL, and the embedding layer: `sqlite3_exec(db, "BEGIN")` opens one transaction per connection that every later statement runs in, until `COMMIT`/`END` or `ROLLBACK`; `BEGIN DEFERRED/IMMEDIATE/EXCLUSIVE` all open the same single-writer transaction, the errors are SQLite's words, and closing a connection rolls back what is open (`test_embed_transactions`) |
| SAVEPOINT/RELEASE/ROLLBACK TO | done | nested, inside one transaction; through the embedding layer an outermost `SAVEPOINT` opens the transaction and releasing it commits, as in SQLite |
| UPSERT (ON CONFLICT DO UPDATE) | done | `DO NOTHING`, `DO UPDATE`, `excluded.*`, with `RETURNING` |
| WITH (common table expressions) | done | recursive included, run as SQLite runs it: a queue of rows, the step reading the one row taken, `UNION ALL` keeping duplicates, `ORDER BY` taking the smallest row first and `LIMIT`/`OFFSET` counting the rows taken; a recursion stops after 1 000 000 rows, where SQLite has no bound; in front of an `INSERT`, `UPDATE` or `DELETE` and inside an `INSERT`'s `SELECT` too |
| ATTACH/DETACH | done | attaches engine directories and `.sqlite` files, both writable; a statement that writes one database reads the others as SQLite resolves names (an unqualified name is main's first, then the written database's), and its writes commit or roll back with the connection's transaction |
| CREATE TABLE … AS SELECT | done | the columns are named after the result's (a repeated name gets `:1`, `:2`), each declared with its expression's affinity (`INT`, `TEXT`, `REAL`, `NUM` or none), and the table keeps the text SQLite writes for it (`CREATE TABLE v(a INT,b TEXT)`, one column per line past 50 characters) |
| VACUUM / ANALYZE / REINDEX | done | `compact` is the engine's VACUUM (on an in-memory database there is nothing to compact and it answers ok), `VACUUM INTO` writes a copy, `ANALYZE` measures statistics; `REINDEX` checks the name and answers ok, since every index is rebuilt from the log when the database opens |
| PRAGMA | partial | four classes below: 25 answer, 18 are accepted as no-ops, 11 are refused |
| EXPLAIN / EXPLAIN QUERY PLAN | partial | `EXPLAIN` prints the chosen access path, the estimate and the join order; there is no `EXPLAIN QUERY PLAN` row format |
| Opening in memory | done | `:memory:`, the empty path, `file::memory:` (with or without `?cache=shared`) and `file:<name>?mode=memory` open a private database in the process: the tables live in memory, no directory is made, and every open is a fresh one (`test_open_in_memory_the_way_sqlite_does`; `scripts/capi_smoke.py` and `scripts/sqlite_abi_smoke.py` open each spelling through the DLL) |
| Opening a path | done | through the `sqlite3_*` face, as SQLite opens one: a path that does not exist becomes an empty SQLite file when the flags allow creating it (`SQLITE_CANTOPEN` otherwise), an existing SQLite file is read and written as that file, and a directory opens only when it holds an engine database (`SQLITE_CANTOPEN_ISDIR`, "unable to open database file", otherwise). `file:` URIs are read with `SQLITE_OPEN_URI` (percent-decoding, an empty or `localhost` authority, `mode=ro`, `rw`, `rwc`, `memory`), and `SQLITE_OPEN_READONLY` refuses every write. A failed open hands back a connection that carries the error, as SQLite's does (`test_two_connections_share_a_sqlite_file`, `scripts/python_sqlite3.py`) |
| Several connections to one file | done | connections in one process to the same SQLite file each keep their own store, as SQLite's each keep their own cache, so functions, hooks, `changes()` and `PRAGMA foreign_keys` stay per connection. One writes at a time: another that wants to write waits for its `sqlite3_busy_timeout` and then fails with `SQLITE_BUSY`, "database is locked"; a reader is never blocked and reads the last commit; a connection reads the file again before its next statement outside a transaction once another committed. Another process, this engine's or SQLite's own, is coordinated with through SQLite's own file locks: SHARED to read the file, RESERVED from a transaction's first write to its end, PENDING and EXCLUSIVE while the commit writes it, at SQLite's offsets, and the file's change counter tells a connection that another process committed (`src/engine/sqlite_share.odin`, `scripts/sqlite_processes.py` runs the facade against itself and against SQLite in both directions). A commit waits up to 5 s for another process's readers and then writes; on POSIX the mirror's own write closes a descriptor, which drops the process's locks once the commit has written |
| CREATE TRIGGER | done | `BEFORE` and `AFTER` triggers with `WHEN`, `NEW` and `OLD`; a `BEFORE` body that fails stops the write. `INSTEAD OF` triggers make a view writable: an `INSERT`, `UPDATE` or `DELETE` on the view fires them per row with `NEW` and `OLD` over the view's columns, counts no change of its own, answers `RETURNING`, and is refused with SQLite's words when the view has none; a view's triggers go with `DROP VIEW`. `UPDATE OF col, …` fires only for an `UPDATE` whose `SET` names one of the columns (whether or not the value changes), for an UPSERT's `DO UPDATE`, and for a foreign key's `ON UPDATE CASCADE`, which writes the child's key columns |
| CREATE VIRTUAL TABLE (FTS5, R-Tree) | done | FTS5 and FTS4 with BM25, `snippet` and `highlight`; spatial tables store their boxes as columns. A full-text table has SQLite's shadow tables beside it, made with the text SQLite writes (`t_content`, `t_segments`, `t_segdir`, `t_docsize`, `t_stat` for fts4; `t_data`, `t_idx`, `t_content`, `t_docsize`, `t_config` for fts5), so a dump or `sqlite_master` shows SQLite's schema. The content table holds the documents with every write; the tables of SQLite's inverted index stay empty, because the index is the engine's: a SQLite that opens an exported file finds the documents and rebuilds its index with `INSERT INTO t(t) VALUES('rebuild')`. fts5's two `WITHOUT ROWID` shadow tables show the engine's text for them, as every `WITHOUT ROWID` table does (S7). An R-Tree has no shadow tables (`test_full_text_tables_have_sqlite_shadow_tables`) |
| GENERATED / STRICT / WITHOUT ROWID DDL | done | `GENERATED … STORED`; `STRICT` allows SQLite's five type names and refuses a value its column cannot convert, in SQLite's words (`cannot store TEXT value in INTEGER column t.i`); `WITHOUT ROWID` as above; both options can be combined and survive a reopen |
| `ANY` columns (dynamic typing) | done | storage classes kept per value, `typeof()` reports them |
| Affinity and untyped columns | done | a column without a type keeps any value; a type name no `CREATE TYPE` defined is read by SQLite's five rules (`UNSIGNED BIG INT` is INTEGER, `VARCHAR2(10)` TEXT, `FLOATING POINT` INTEGER); a text that reads as a number becomes one in a numeric column and a number becomes text in a text column. Through the `sqlite3_*` face every declared type is an affinity and a value that does not convert is stored as it is, as SQLite stores it; the engine's other faces refuse it. Values of different storage classes compare in SQLite's order (NULL, numbers, text, blobs) after a column's affinity converts the other side, in comparisons, `min`/`max` and `ORDER BY`. A real's text form is SQLite 3.54's `%!.17g` (`3.0`, `1.0e+20`, `0.1`, `0.30000000000000004`): up to 17 significant digits from SQLite's own decimal conversion, fewer when they already read back as the same double. Compared with SQLite in `scripts/sqlite_abi_affinity.py` |
| CASE | done | simple (`CASE x WHEN …`) and searched (`CASE WHEN …`) forms, anywhere an expression is allowed, including policies and triggers |

## Expressions and clauses

| Feature | Status | Notes |
|---|---|---|
| WHERE, ORDER BY, LIMIT/OFFSET | done | stable sort, NULL the smallest value; `NULLS FIRST`/`NULLS LAST`; `LIMIT <offset>, <count>`. An `ORDER BY` expression that fails is the statement's error (a window function there is refused) |
| Row values | done | `(a, b) = (1, 2)`, `<`, `<=`, `>`, `>=`, `IS`, `IN ((…), (…))` and `IN (SELECT a, b …)`; a row value anywhere else is "row value misused", as in SQLite |
| Operators | done | `IS`/`IS NOT` between values, `IS [NOT] DISTINCT FROM`, `& \| ~ << >>` at SQLite's precedence, `->` and `->>` |
| GROUP BY, HAVING | done | `HAVING` takes the expression, not a projection alias |
| DISTINCT | done | over the projected row, and inside an aggregate (`count(DISTINCT x)`) |
| IN, EXISTS, scalar subqueries | done | three-valued logic: a `NULL` in the list makes a non-match unknown |
| CASE, COALESCE, NULLIF | done | `CASE` in both forms; `COALESCE` and `NULLIF` as functions |
| LIKE, GLOB, ESCAPE | done | LIKE ignores ASCII case; GLOB is exact with `*`, `?`, `[...]` |
| `||` string concatenation | done | tested with text and numbers |
| COLLATE (BINARY, NOCASE, RTRIM) | done | on a column, in comparisons, in unique keys and index probes |
| Window functions, FILTER | done | `OVER` with `PARTITION BY`/`ORDER BY` and `ROWS`/`RANGE`/`GROUPS` frames, beside `GROUP BY` too; the `WINDOW` clause (`OVER name`, and `OVER (name …)` adding an `ORDER BY` or a frame, with SQLite's four refusals). `FILTER (WHERE …)` on an aggregate and on an aggregate window, and an aggregate's own `ORDER BY` (`group_concat(x, ',' ORDER BY y)`), which a scalar function refuses as SQLite does; `FILTER` on a window over grouped rows reads each group's values (`sum(sum(n)) FILTER (WHERE g > 1) OVER (…)`); an aggregate's `ORDER BY` sorts under a program's collation too |
| Foreign keys | done | `FOREIGN KEY (…) REFERENCES` and a column's `REFERENCES t [(col)]` (the parent's key when no column is named, the table itself allowed); `ON DELETE`/`ON UPDATE` `RESTRICT`/`CASCADE`; `DEFERRABLE INITIALLY DEFERRED` checked at COMMIT. Enforced on every path unless `PRAGMA foreign_keys = OFF` (a no-op inside a transaction, as in SQLite); the `sqlite3_*` face opens with them off, as SQLite does. A violation is `FOREIGN KEY constraint failed` (`SQLITE_CONSTRAINT_FOREIGNKEY`, SQLSTATE `23503`). A key that names no unique key of its parent is declared, and every write that has to enforce it fails with `foreign key mismatch - "child" referencing "parent"`, as in SQLite; a key whose parent table does not exist yet is still refused at `CREATE`. A SQLite file opens with SQLite's default (keys off until `PRAGMA foreign_keys = ON`), and its `REFERENCES` are imported, parents first (a key naming a table the file lacks, or closing a cycle, is left out); a written file carries the keys as `FOREIGN KEY … REFERENCES` |
| `AS OF <seq>` | done | engine extension: read a table as it was |

## Functions

**Implemented (the count is in [sqlite-roadmap.md](sqlite-roadmap.md),
measured by `scripts/sqlite_gaps.py`):** `abs` and the trigonometric, hyperbolic and logarithmic set (`acos`, `asin`,
`atan`, `atan2`, `cos`, `sin`, `tan`, `sinh`, `cosh`, `tanh`, `asinh`, `acosh`,
`atanh`, `degrees`, `radians`, `pi`, `exp`, `log`, `log2`, `log10`), `ceil`/`floor`/`round`/`trunc`/`sign`/`sqrt`/`pow`/
`mod`, `char`, `unicode`, `hex`, `unhex`, `quote`, `format`/`printf`,
`coalesce`, `iif`, `ifnull`, `nullif`, `length`, `octet_length`, `lower`,
`upper`, `ltrim`, `rtrim`, `trim`, `replace`, `concat`, `concat_ws`, `instr`,
`substr`/`substring`, `glob`, `like`, `typeof`, `min(a, b, …)`/`max(a, b, …)`
as scalars, `trim`/`ltrim`/`rtrim` with a character set, `random`, `zeroblob`,
`uuid` (only when the host supplies a randomness source), `randomblob`,
`changes`, `total_changes`, `last_insert_rowid`, `sqlite_version`, `affinity`,
`soundex`, `unistr`, `unistr_quote`, `timediff`, `sqlite_source_id`,
`sqlite_compileoption_used`, `sqlite_compileoption_get`, `date`,
`time`, `datetime`, `strftime`, `now`, seventeen `json_*` scalars
(`json_set`, `json_replace`, `json_insert`, `json_remove`, `json_patch`,
`json_array_insert`, `json_pretty`, `json_error_position` and the readers),
the ten `jsonb_*` scalars, the `json_group_array`/`json_group_object` and
`jsonb_group_array`/`jsonb_group_object` aggregates, the ordered aggregates
`median`, `percentile`, `percentile_cont` and `percentile_disc` and the
`json_each`/`json_tree` table functions,
`group_concat`/`string_agg`, `rank`, `snippet`, `highlight`, `current_identity`
and `has_role` (engine extensions), plus `count`, `sum`, `avg`, `min`, `max`,
`total`.

**JSONB.** SQLite's binary JSON: `jsonb()` of a JSON text is SQLite's bytes
(the smallest header for each size), every JSON function and `json_each`/
`json_tree` read a JSONB document, a JSONB value inside `json_array` or
`json_set` is the document it holds, and a BLOB that is not JSONB is
"malformed JSON". A JSON number keeps the text it was written with (`1.50`), and
a path's `[#]` and `[#-n]` read as SQLite reads them (`src/engine/jsonb.odin`,
`test_jsonb_and_array_insert`, the differential corpus). Not SQLite's: an edit
(`jsonb_set`, `jsonb_replace`, …) may pick another valid encoding of the same
document (SQLite stores text that came from a SQL value as TEXTRAW, and a string
written with an unneeded escape keeps it), which reads back the same. A JSON
function's text carries SQLite's JSON subtype (74), so the next JSON function
nests it as JSON (`json_array(json('[1]'))` is `[[1]]`), through `coalesce`
and a scalar subquery; a value written to a table, or read from a subquery in
`FROM`, has none, as in SQLite. `sqlite3_value_subtype` and
`sqlite3_result_subtype` read and set it.

**Not counted:** `json_parse` (built only with `SQLITE_DEBUG`) and
`sqlite_offset` (only with `SQLITE_ENABLE_OFFSET_SQL_FUNC`), which a default
SQLite build answers "no such function" for, as this engine does.

## Pragmas

The engine sorts the 63 names in the inventory into four classes:

- **29 answer with data**: `application_id`, `cache_size`, `collation_list`,
  `compile_options`, `legacy_file_format`, `module_list`,
  `data_version`, `database_list`, `encoding`, `foreign_key_check`,
  `foreign_key_list`, `foreign_keys`, `freelist_count`, `function_list`,
  `index_info`, `index_list`, `integrity_check`, `journal_mode`,
  `locking_mode` (`normal`; a set answers the mode in effect), `max_page_count`, `mmap_size`, `page_count`, `page_size`, `pragma_list`,
  `quick_check`, `schema_version`, `sqlite_version`, `stats` (engine
  extension), `synchronous`, `table_info`, `table_list`, `table_xinfo`,
  `user_version`.
- **18 are accepted as no-ops** because the engine has no equivalent knob:
  `auto_vacuum`, `automatic_index`, `busy_timeout`, `cache_spill`,
  `cell_size_check`, `checkpoint_fullfsync`, `count_changes`,
  `default_cache_size`, `fullfsync`, `full_column_names`, `hard_heap_limit`,
  `journal_size_limit`, `optimize`, `secure_delete`, `short_column_names`,
  `soft_heap_limit`, `threads`, `wal_autocheckpoint`, `wal_checkpoint`.
- **10 are refused with a reason**, because accepting them would promise a
  guarantee the engine does not give: `case_sensitive_like`,
  `defer_foreign_keys`, `ignore_check_constraints`, `legacy_alter_table`,
  `query_only`, `read_uncommitted`, `recursive_triggers`,
  `reverse_unordered_selects`, `trusted_schema`, `writable_schema`.
- **The rest are acknowledged** and answer the neutral value SQLite answers when
  there is nothing to give back: `incremental_vacuum`, `shrink_memory`,
  `soft_heap_limit64`, `temp_store`, `temp_store_directory`,
  `data_store_directory`. There is no unknown pragma left in the inventory.

`user_version` and `application_id` are 32-bit integers stored with the data
(the internal table `_sqlite_header`), as SQLite keeps them in the file header:
every connection sees them, a reopen reads them back, the transaction they are
written in commits or undoes them, and a value that is not a 32-bit integer is
stored as 0. `PRAGMA main.name` is `PRAGMA name`.

A pragma that answers rows and changes nothing is also a table function, as in
SQLite: `SELECT name FROM pragma_table_info('t')`, and once per row of a join
(`sqlite_master m JOIN pragma_table_info(m.name)`). The pragma's argument is the
function's first argument, or what a `WHERE` or `ON` term asks of the hidden
column `arg` (`pragma_table_info WHERE arg = 't'`, `p.arg = m.name`), and the
hidden columns `arg` and `schema` answer them, as in SQLite. `table_info` reports `notnull = 0` for the rowid alias, as SQLite does. Its `type` is the declared type (see `sqlite_schema` above).

`REINDEX` is accepted and answers `ok`: every index is rebuilt from the log when
the database opens, so there is never one that is out of date. `INDEXED BY name`
and `NOT INDEXED` are read as the hints they are -- the plan is priced by the
planner, and the answer is the same with or without them.

`EXPLAIN QUERY PLAN` answers SQLite's four columns (`id`, `parent`, `notused`,
`detail`) with the steps in SQLite's words: `SCAN <table>`,
`SEARCH <table> USING INDEX <index>`, `SCAN CONSTANT ROW`,
`USE TEMP B-TREE FOR ORDER BY`, and a note naming what the planner had to guess.

## Semantics that differ from SQLite

These are decisions, not accidents, and they are the engine's own rules: an
engine database (a directory) answers this way. Through the `sqlite3_*` face
and on a SQLite file a statement answers with SQLite's rules instead, as
[sqlite-semantics.md](sqlite-semantics.md) records case by case:

| Case | SQLite | This engine |
|---|---|---|
| `1/0` | `NULL` | error `invalid_argument: division by zero` |
| `CAST('abc' AS INTEGER)` | `0` | error `invalid_type` |
| `9223372036854775807 + 1` | a float | wraps to `-9223372036854775808` |
| `CAST(300 AS TINYINT)` | `300` (INTEGER affinity) | error: the value does not fit the declared width |
| `UPDATE t SET u = u + 990` whose rows collide only partway through | error: a unique key is checked row by row | succeeds when the final rows are distinct: a statement's keys are checked against its result |
| `COMMIT` a deferred foreign key fails | the transaction stays open until `ROLLBACK` | the transaction is rolled back |
| foreign keys, engine default | enforced only after `PRAGMA foreign_keys = ON` | enforced until `PRAGMA foreign_keys = OFF` (the `sqlite3_*` face starts with them off) |

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
ours@<3.50 | SELECT printf('%.0f', 2.5)                    | [["3"]]
matches@>=3.50 | SELECT printf('%.0f', 2.5)                | [["3"]]
ours    | SELECT upper(char(233))                         | [["É"]]
matches | SELECT 1 = '1', 1 < 'a', 'a' < x'00'           | [[0, 1, 1]]
refused | SELECT CAST('12abc' AS INTEGER)                | invalid_type
refused | SELECT 1/0                                     | division by zero
refused | SELECT 2 * 9223372036854775807                 | integer overflow
```

One row is a real difference: `upper` folds the whole of Unicode, where SQLite
folds ASCII only, so `upper(char(233))` is `É` here and `é` there. The
`printf('%.0f', 2.5)` row is version-scoped, and it is why the table carries the
versions it holds for. SQL's `printf` is SQLite 3.54's own printf (the one
`sqlite3_mprintf` answers with), which rounds a tie away from zero, so it
answers `3`, as SQLite does from 3.50 on; SQLite 3.45.1 answers `2`, rounding
to even. The claim is a match from 3.50 on and a declared difference below it,
and a row outside its window is reported as skipped with the version that
skipped it, never silently passed.

`rowid` names the stored row (`rowid`, `_rowid_` and `oid`), and a table whose
primary key is one INTEGER column answers that column, so a program that pages
with `ORDER BY rowid` or names a row to `sqlite3_blob_open` finds the same rows
here as in SQLite.

Integer arithmetic that does not fit is refused, as PostgreSQL refuses it, where
SQLite promotes the result to a real: `2 * 9223372036854775807` is a real in
SQLite and `integer overflow` here. The refusal is the same for `+`, `-`, `*`,
`/`, `%` and `abs()`.

## Embedding and tooling

| Feature | Status | Notes |
|---|---|---|
| Odin embedding API | done | `src/engine/embed.odin` |
| SQLite's command-line shell | done | SQLite 3.54.1's own `shell.c`, compiled against the facade, runs as it runs on SQLite: every output mode (list, csv, column, box, table, markdown, json, line, insert, quote, html, tabs, qbox), `.schema`, `.fullschema`, `.tables`, `.indexes`, `.dump` (AUTOINCREMENT, triggers, views, blobs and control characters included), `.databases`, `.changes`, `.width`, `.nullvalue`, `.separator`, transactions, and errors with SQLite's words and position (`near ";": syntax error`, `unrecognized token`). What it needed of the facade, all in Odin: SQLite's printf (`sqlite3_mprintf`, `_snprintf`, the `sqlite3_str` builder and their `va_list` forms, read with Odin's C variadic intrinsics: `%q`, `%Q`, `%w`, `%j`, `%r`, `%!`, and doubles through SQLite's own decimal conversion, identical to SQLite 3.54.1 over 20 000 random values), `sqlite3_incomplete`, the keyword list in SQLite's order, the VFS registry, status and control entry points, client data, `sqlite3_stmt_explain`, `sqlite3_table_column_metadata`; of the engine, SQLite's answers for `PRAGMA table_list`, `index_list` (`sqlite_autoindex_T_N`, newest first), `table_info` of a view and of the catalogs, `database_list` (full paths, temp once used), `rowid` on `sqlite_schema`, `temp.sqlite_schema`, a PRAGMA's columns before its first step, and `changes()` that leaves the catalogs out. `sqlite3_sourceid` starts with SQLite 3.54.1's id, which the shell compares with its header. `scripts/sqlite_shell.py` (a gate of `scripts/ci.py`) builds the shell twice, against SQLite 3.54.1 from its source and against the facade, feeds both the cases in `scripts/shell_cases/` and compares every line: 8 cases, 499 lines, no known difference (`WITHOUT ROWID`, attached databases, `CREATE TABLE … AS SELECT`, bare columns beside `min()`/`max()`, and errors at prepare and at run time with SQLite's words and position among them) |
| SQLite's tools | done | SQLite 3.54.1's `sqldiff`, `dbhash` and `mptest`, compiled against the facade, answer as they do on SQLite. `scripts/sqlite_tools.py` (a gate of `scripts/ci.py`) builds each twice, against SQLite and against the facade: sqldiff (every option, both ways, a database against itself) and dbhash over files SQLite wrote print the same bytes and exit the same way; the same statements through SQLite's shell and the facade's give files SQLite calls intact (`PRAGMA integrity_check`) with the same dbhash; and mptest's multi-process scripts (`multiwrite01`, `crash01`, `config01`, `config02`: five processes writing one file, a client that dies mid-transaction) pass every check SQLite passes (`multiwrite01` in a median 3.6 s against SQLite's 2.6: a connection catches up with another's commit by hashing again only the tables whose pages changed, D37). What they needed: a read-only connection that attaches, `aux.sqlite_schema`, `PRAGMA aux.x`, `index_xinfo`, `sqlite3_table_column_metadata` by schema, `sqlite3_busy_handler`, `sqlite3_trace`, `sqlite3_compileoption_get`/`_used`, a connection that reads another process's file under SHARED (open included) and fails with BUSY rather than read an older one, and a function that runs SQL mid-write on its own connection. They found the mirror losing page 1's header when a root split and leaking overflow pages, the file's catalog out of creation order, DESC and collated indexes written unsorted, a dropped table's key and index names kept to the end of the transaction, and an outer `alias.rowid` a subquery could not read. No known difference is left: `--vtab` needed a TEMP table on a read-only connection, and `config02` page sizes from 512 to 65536 set by `PRAGMA page_size` and `VACUUM` |
| C ABI and header | done | `src/capi`, `include/miraidb.h`; the `sqlite3_*` facade has its own `include/sqlite3_miraidb.h` with the 230 symbols it exports, and `scripts/abi_header.py` keeps each header equal to its exports; `scripts/sqlite_abi_reference.py` runs one script against the facade and against SQLite itself and fails on any answer that differs |
| CLI `.dbinfo`, `.tables`, `.schema` on SQLite files | done | `miraidb sqlite` |
| Import/export | done | `import-sqlite`, `export-sqlite`, auto-detect on open |
| Extension loading | done | `LOAD EXTENSION <name> AT 'host:port'` runs it out of process; the ABI is v1/v2 |
| VFS layer | done | OS, memory and quota backends; the commit log, the page files and the statistics file go through it |
| Backup API | done | `miraidb_backup` in the C ABI, `VACUUM INTO` in SQL, and SQLite's `sqlite3_backup_init/step/remaining/pagecount/finish`: the copy replaces what the destination held, in one transaction of the destination, from the source as it is at the last step (SQLite copies a few pages per step; here the steps only count pages, and the last one copies). A source that commits between two steps starts the copy over, as SQLite's does. The source may be `main`, `temp` (empty here) or an attached database; the destination is `main`. A copy into itself or into a destination that has read or written in an open transaction is refused with SQLite's words, and a step while either side holds a transaction answers `SQLITE_BUSY`. What travels is what a SQLite file says (`scripts/sqlite_abi_database.py`) |
| Serialize / deserialize | done | `sqlite3_serialize` answers the database as SQLite file bytes from `sqlite3_malloc` (an empty database is one page); `SQLITE_SERIALIZE_NOCOPY` answers NULL, as SQLite does for a database not kept as one block. `sqlite3_deserialize` replaces the database with an image (a copy is taken; one handed over with `FREEONCLOSE` is freed at once) and stops the connection writing the file it was opened on. Bytes that are not a database are taken, as SQLite takes them, and every statement after fails with `SQLITE_NOTADB` ("file is not a database") until another image replaces them; SQLite lets a statement that reads no table (`SELECT 1`) run in some versions. With `SQLITE_DESERIALIZE_READONLY` a write fails with `SQLITE_READONLY`, "attempt to write a readonly database". On a database opened from an engine directory the new content is written to its log, where SQLite would leave the file alone |
| Connection's databases | done | `sqlite3_db_filename` (the absolute path, `""` in memory), `sqlite3_db_name`, `sqlite3_db_readonly` (an attached database answers for itself), `sqlite3_txn_state` (none after `BEGIN`, read once a table is read, write once one is written), and `sqlite3_close_v2`, which leaves a connection with open statements to close at the last finalize |
| Authorizer | done | `sqlite3_set_authorizer` is asked while a statement is prepared (`src/engine/authorize.odin`): `SELECT`, `READ` of every column a query reads in any clause (an empty column for a table nothing is read from), `FUNCTION`, `INSERT`, `UPDATE` per assigned column, `DELETE`, the DDL actions, `TRANSACTION`, `SAVEPOINT` and `PRAGMA` with SQLite's arguments. `DENY` fails the prepare with SQLite's code and words, `IGNORE` reads a column as NULL, drops an assignment, or makes the statement do nothing. The bodies of the views and CTEs a statement reads and of the triggers it fires are asked about too, with the view, CTE or trigger as the sixth argument, as SQLite compiles them into the statement. An `IGNORE` reaches a column read through `*` (it becomes a NULL under the column's name), inside a view (the reference then reads the rewritten query), and inside a trigger's body: the answers are kept with the prepared statement and given again each time the trigger fires, without asking again. The set of questions for 35 statements and the effect of each answer, through `*`, views, CTEs and trigger bodies included, match SQLite (`test_authorizer`, `test_authorizer_star_view_trigger`, `scripts/sqlite_abi_authorizer.py`). Not SQLite's: the order of the questions and the questions about SQLite's own `sqlite_*` tables |
| Trace | done | `sqlite3_trace_v2` reports `STMT` when a statement starts running, `ROW` per row, `PROFILE` when it ends (at its last step, an error, or a reset of a running statement) and `CLOSE`, in SQLite's order, for statements a program steps and for those `sqlite3_exec` runs, which prepares and steps each statement of its text as SQLite does (and answers `SQLITE_ABORT` when its callback stops it). `sqlite3_overload_function` registers SQLite's placeholder (`scripts/sqlite_abi_hooks.py`) |
| Connection hooks | done | `sqlite3_update_hook`, `sqlite3_commit_hook` (a non-zero answer vetoes, reported as `SQLITE_CONSTRAINT_COMMITHOOK`) and `sqlite3_rollback_hook` report the same events in the same order as SQLite: rows a statement or a trigger changed with SQLite's rowid, a commit for every write transaction (one that changed no row included, an empty `BEGIN; COMMIT` not), a rollback for `ROLLBACK`, a vetoed commit and a failed autocommit statement, nothing for the rows a `REPLACE` removes or for the engine's catalog tables. `sqlite3_progress_handler` runs every n rows a statement visits (SQLite counts bytecode instructions, so how often differs) and a non-zero answer interrupts it with SQLite's code and text (`scripts/sqlite_abi_hooks.py`) |
| Application-defined functions | done | `sqlite3_create_function(_v2)` for scalars and aggregates, the `sqlite3_value_*` readers (with SQLite's conversions: `'12.9'` is 12 as an integer, `'1e3'` is 1, a real is truncated, past the range clamps), the `sqlite3_result_*` answers (an error with its own code is the statement's code, extended included), `sqlite3_aggregate_context`, `sqlite3_user_data`, `sqlite3_context_db_handle`, auxiliary data, and the destructor of `_v2` on replace, delete, close and failure. Every answer is compared with SQLite's (`scripts/sqlite_abi_functions.py`). A function registered without `SQLITE_DETERMINISTIC` cannot appear in an index's expressions or its `WHERE`, and a function or collation an active statement may be using is not replaced (`SQLITE_BUSY`), as in SQLite. `sqlite3_create_window_function` feeds a program's window function as SQLite does: `xStep` for each row that enters the frame, `xInverse` for each row that leaves it, `xValue` for each row's answer and `xFinal` once, whose error a window drops (`test_window_function_is_fed_incrementally`). Differences: an aggregate builtin cannot be replaced, auxiliary data lives for one call, and deleting a function that replaced a builtin gives the builtin back where SQLite leaves the name unusable |
| Column names | done | the `sqlite3_*` facade names an unaliased expression by the text it was written with (`count(*)`, `1+2`, `upper( name )`), as SQLite does, so a program that reads a row by column name finds it; the engine's other faces keep PostgreSQL's `?column?` (`store.sqlite_names`, `test_expression_column_names`, compared with SQLite in `scripts/sqlite_abi_reference.py`) |
| Column origins | done | `sqlite3_column_decltype`, `_database_name`, `_table_name` and `_origin_name` answer right after prepare for a column that names a table's column, and NULL for an expression, as SQLite does (`test_result_column_origins`, `scripts/sqlite_abi_reference.py`, checked against SQLite 3.53 built with column metadata). The declared type is the one the `CREATE` text wrote (`VARCHAR(10)`, or NULL for a column declared without one), as SQLite answers it. One difference: a column read through a derived table, a CTE or a view has no origin here where SQLite follows it through |
| Virtual table modules | done | `sqlite3_create_module(_v2)`, `sqlite3_declare_vtab`, `sqlite3_drop_modules` and the `sqlite3_vtab_*` calls: a program's module serves a table made with `CREATE VIRTUAL TABLE` (the arguments reach `xCreate` as written, and a later read connects it again) or, eponymous, under its own name. A table is materialized each time a statement names it, like a view: `xBestIndex` is offered the arguments after the name as equality constraints on the HIDDEN columns and the WHERE and ON terms `column op value`, `xFilter` receives the ones it numbered, the rows come from the cursor, and the WHERE applies afterwards; `SELECT *` leaves the HIDDEN columns out. After the first table of a join, or in a correlated subquery, it is read once per outer row with its arguments and terms bound to that row (`FROM t, series(1, t.n)`). `INSERT`, `UPDATE` (the row id too) and `DELETE` call `xUpdate` with SQLite's arguments, and a module's error message is the statement's. `xBegin`, `xSync`, `xCommit`, `xRollback` and the savepoint methods follow the transaction that wrote, in SQLite's order and levels; `ALTER TABLE … RENAME TO` calls `xRename`; `xFindFunction` overloads a function on one of the table's columns; `DROP TABLE` calls `xDestroy` (`src/engine/vtab.odin`, `src/sqlite_compat/vtab.odin`, `test_program_virtual_tables`, `scripts/sqlite_abi_vtab.py`). The `ORDER BY` of a query that reads only the table is offered too; the engine sorts the rows whatever the module answers. `sqlite3_vtab_collation` names the comparison each constraint asks for (its `COLLATE`, the column's, or `BINARY`). `sqlite3_vtab_in`, `_distinct` and `_nochange` answer 0, which their contract allows and a module has to accept from SQLite too: the engine offers no `IN` term (an `IN` reads the rows and filters after), gives no DISTINCT hint, and hands `xUpdate` every column |
| Collations | done | `sqlite3_create_collation`, `_v2`, `16` and `sqlite3_collation_needed(16)`: a C comparison answers in `WHERE`, `ON`, `CASE`, `IN` and `BETWEEN`; `ORDER BY` (a window's too) ranks the values under it (NULL, numbers, text by the collation, blobs, as SQLite orders them); `GROUP BY`, `DISTINCT`, a `DISTINCT` aggregate and `PARTITION BY` group by the classes it makes; a column may be declared with it. A UTF-16 registration is handed UTF-16 bytes; the destructor runs on replace, delete and close; an unknown name fails the prepare with SQLite's words, after `collation_needed` had its chance (`src/sqlite_compat/collation.odin`, `scripts/sqlite_abi_collations.py`). The built-in `NOCASE` and `RTRIM` group, deduplicate and partition under their rule too, and `ORDER BY 1` sorts under its column's collation. `BINARY`, `NOCASE` and `RTRIM` can be replaced on a connection; an index on a column under a replaced name is not read while the replacement stands. A key (`UNIQUE`, `PRIMARY KEY`) on a column with a host collation compares the rows with it, so two values it calls equal are the same key, as in SQLite; it reads every row of the table for each write, where SQLite walks an index ordered by the comparison, and an index on such a column is kept but not read. Not SQLite's: deleting a replacement gives the built-in rule back where SQLite is left comparing in BINARY |
| UTF-16 API | done | `sqlite3_open16`, `_errmsg16`, `_prepare16` (v2, v3; the tail is a place in the UTF-16 text), `_bind_text16`, `_bind_text64` in each encoding, `_column_text16`, `_bytes16`, `_name16`, `_decltype16` and the origin names, `_value_text16` (native, LE, BE) and `_bytes16`, `_result_text16` (native, LE, BE), `_result_text64` with an encoding, `_result_error16` and `_create_function16` convert at the boundary; the text is UTF-8 inside. Compared with SQLite in `scripts/sqlite_abi_values.py` |
| Pointer passing | done | `sqlite3_bind_pointer` and `sqlite3_result_pointer` hand a function a C pointer through SQL, read back with `sqlite3_value_pointer` under the same type name; to SQL it is NULL, a stored row or a `sqlite3_value_dup` copy holds a plain NULL, and the destructor runs on rebind, `clear_bindings` or finalize (bound) and when the step ends (returned) (`src/sqlite_compat/pointer.odin`, `scripts/sqlite_abi_values.py`). The bind destructors of `bind_text` and `bind_blob` run once the value is copied, a NULL text binds NULL and a zero-length blob is a blob, as in SQLite |
| Parameters | done | `?`, `?NNN`, `:name`, `@name` and `$name` take the slots SQLite gives them; `sqlite3_bind_parameter_count`, `_name` (prefix included, NULL for a bare `?`) and `_index`, and `sqlite3_expanded_sql` (the text with the bound values in SQLite's spelling) answer what SQLite answers on the same statement (`test_numbered_and_named_parameters`, `scripts/sqlite_abi_reference.py`) |
| Extended result codes | done | `sqlite3_extended_result_codes(db, 1)` turns on the narrow constraint codes — `SQLITE_CONSTRAINT_PRIMARYKEY` (1555), `_UNIQUE` (2067), `_NOTNULL` (1299) — and `sqlite3_errcode` plus the return value of `exec`/`step` answer them while the mode is on; `sqlite3_extended_errcode` answers the narrow code in either mode, as SQLite's does. A failure that is not a constraint keeps its primary code, because a narrow code only exists to say which constraint failed |
| Identity from C | done | the `miraidb_*` face carries an identity and a token (`miraidb_set_identity`, `miraidb_identity`, `miraidb_issue_token`, `miraidb_authenticate`), so row policies are reachable from C; the `sqlite3_*` face has no such concept, because SQLite has none |
| Result codes | done | the `sqlite3_*` face answers SQLite's primary codes: `SQLITE_CONSTRAINT` (19) for a duplicate key or a null in a key column, `SQLITE_MISMATCH` (20) for a type the comparison cannot reconcile, `SQLITE_INTERRUPT` (9) when a cancellation landed, `SQLITE_RANGE` (25) for a bind past the parameters, and `SQLITE_ERROR` (1) for a syntax error or a missing table, which is what SQLite does too. `sqlite3_errcode` reports the same code the failing call returned. A broken key or `NOT NULL` is reported in SQLite's words: `UNIQUE constraint failed: t.a, t.b` (the primary key included, and `index 'name'` for a key over an expression), `NOT NULL constraint failed: t.c` |
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

**Views, triggers, AUTOINCREMENT and the header travel both ways.** Opening a
file creates its views and its triggers as the engine's own, so a query reads a
view and an insert fires a trigger (before, they were text the engine kept for
the file but could not run); one the engine cannot read stays that text. An
`AUTOINCREMENT` key keeps the keyword, and the counter `sqlite_sequence` holds
is read, so a rowid the table gave out is not given again; `user_version` and
`application_id` are read from the header. Writing a file (an export or the
mirror's rewrite) does the reverse: the engine's views and triggers with the
file's own text when they came from it unchanged, `INTEGER PRIMARY KEY
AUTOINCREMENT` inline, the last rowid given out in `sqlite_sequence`, and the
two header integers. A view or trigger dropped through the engine leaves the
file. The page patcher keeps `sqlite_sequence` current too: an insert into an
`AUTOINCREMENT` table patches its counter's row (or adds it) with the pages it
already writes (`test_sqlite_file_round_trip`,
`test_mirror_patches_sqlite_sequence`).

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
- a table with a `GENERATED` column (SQLite computes it and does not store it).

A `WITHOUT ROWID` table has no rowid to patch: a commit that writes one rewrites
the file, which keeps its text.

Rows, indexes the engine knows, and file integrity survive in every case; a table
rebuilt this way loses its rules and says so. Opened from the file, the database
has no other copy: a commit the file did not take fails (`SQLITE_IOERR`), the
journal goes back into the file, and the connection reads it again (backlog D8).
A rewrite of the whole file is journaled like a page commit.

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

`sqlite3_blob_open` addresses a row by its rowid: a single-column integer primary
key when the table has one (SQLite's rowid alias), and the table's rowid
otherwise, so a table with no primary key works. It answers SQLite's errors
("no such table: main.t", `no such column: "c"`, "no such row", "cannot open
value of type integer"). A write goes to the row at once, so a query sees it,
and cannot grow the value, as in SQLite; a handle opened with flags 0 refuses it
with `SQLITE_READONLY`. A change the handle did not make to its row expires it:
a read or write after it answers `SQLITE_ABORT`. `sqlite3_blob_reopen` reads
another row of the same column (CPython's `BlobTests`, `scripts/python_sqlite3.py`).
