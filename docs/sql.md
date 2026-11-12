# SQL subset

miraidb speaks its own small SQL dialect. The grammar is fixed and hand written;
anything outside it is a syntax error rather than something silently
misinterpreted. Identifiers are case-insensitive unless quoted with `"` or
backticks.

## Statements

```sql
SET name = expr
SHOW [name | tables]
EXPLAIN statement

TRUNCATE [TABLE] name

CREATE VIEW [IF NOT EXISTS] name AS SELECT ...
DROP VIEW [IF EXISTS] name
CREATE POLICY name ON table [USING (predicate)] [CHECK (predicate)]
DROP POLICY [IF EXISTS] name
DESCRIBE table

CREATE TABLE [IF NOT EXISTS] name (
    column type [constraints] [, ...]
    [, [CONSTRAINT name] PRIMARY KEY (column [, ...])]
    [, [CONSTRAINT name] UNIQUE (column [, ...])]
)
DROP TABLE [IF EXISTS] name

CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON table (column [, ...])
DROP INDEX [IF EXISTS] name [ON table]

INSERT INTO name [(column, ...)] VALUES (expr, ...) [, (...)]
UPDATE name SET column = expr [, ...] [WHERE expr]
DELETE FROM name [WHERE expr]

SELECT [DISTINCT] projection [, ...]
FROM table [[AS] alias]
    [[INNER | LEFT [OUTER] | CROSS] JOIN table [[AS] alias] [ON expr]]...
[WHERE expr]
[GROUP BY expr [, ...]]
[HAVING expr]
[ORDER BY expr [ASC|DESC] [, ...]]
[LIMIT expr] [OFFSET expr]
```

Placeholders are `?`, numbered left to right. Pass the values to
`sql_execute_params` / `sql_execute_in_tx_params`; the plain entry points reject
a statement that has placeholders.

Views store their SELECT body and are materialized per reference: `SELECT` over a
view runs the body in the same transaction and then treats the result as a
table, so filters, joins and aggregates apply on top. Views are read-only, take
no parameters, cannot be recursive, and the body must include a `FROM` (the
engine does not support `SELECT` without a table).

Policies filter rows on every read (`USING`) and validate every write
(`CHECK`). Policies on the same table combine with `AND`; a table without
policies is unconstrained. `SET identity = '<64 hex digits>'` sets the caller
the policies see, `SHOW identity` reads it back and `current_identity()` (alias
`sender()`) exposes it inside predicates.

`DESCRIBE table` (alias `DESC`) lists the columns and indexes as rows:
`kind` (`column` or `index`), `name`, `type` (or the index columns), `not_null`,
`unique` and `default`.
`SHOW tables` lists the user tables (internal `_` tables are hidden).
`SET`/`SHOW` read and write process-local variables (not persisted, not part of
the log; a server would scope them per connection). `EXPLAIN` prints the access
plan of a statement without running it: the scan or index chosen for each table,
the join order and the post-processing steps.

`BEGIN`/`COMMIT`/`ROLLBACK` are session statements. The CLI keeps one open
transaction across statements; `sql_execute` handles them per call and rejects
transaction control with `Sql_Not_A_Query`.

## Foreign keys

```sql
CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE books (
  id INTEGER PRIMARY KEY,
  author INTEGER,
  FOREIGN KEY (author) REFERENCES authors (id) ON DELETE CASCADE
);
```

The referenced columns must form the primary key or a unique index. Inserts and
updates of a child need an existing parent (NULL keys are exempt); deleting or
changing a referenced key follows `ON DELETE`/`ON UPDATE` (RESTRICT by default).

## Indexes

```sql
CREATE INDEX by_label ON t USING HASH (label);       -- equality on any columns
CREATE UNIQUE INDEX by_code ON t USING DIRECT (code); -- unique, one row per key
CREATE INDEX by_id ON t (id);                        -- btree, the default
```

## Types

Columns may be `UNIT` (no payload; only `NULL`), `OPTION(T)` (a typed nullable),
`RESULT(T, E)` (a pair where exactly one side is set), `ARRAY(T)` (a list of T)
or `PRODUCT(T1, ..., Tn)` (a fixed tuple of two or more scalar components). A `CREATE TYPE` may
name a structural base too:

```sql
CREATE TYPE maybe_count AS OPTION(INT);
CREATE TABLE t (id INTEGER PRIMARY KEY, n maybe_count, r RESULT(INT, TEXT));
```


| SQL name | Type |
|---|---|
| `BOOLEAN`, `BOOL` | Bool |
| `TINYINT`, `INT1` | signed 8-bit |
| `SMALLINT`, `INT2`, `INT4` | signed 16/32-bit |
| `INTEGER`, `INT`, `BIGINT`, `INT8` | signed 64-bit |
| `INT128`, `I128` | signed 128-bit |
| `UTINYINT`, `UINT1`, `USMALLINT`, `UINT2`, `UINT4` | unsigned 8/16/32-bit |
| `UINTEGER`, `UINT`, `UBIGINT`, `UINT8` | unsigned 64-bit |
| `UINT128`, `U128` | unsigned 128-bit |
| `FLOAT4`, `REAL32` | IEEE single precision |
| `REAL`, `DOUBLE`, `FLOAT`, `FLOAT8` | IEEE double |
| `TEXT`, `STRING`, `VARCHAR` | UTF-8 text |
| `BLOB`, `BYTES` | byte string |
| `TIMESTAMP`, `DATETIME` | microseconds since the Unix epoch |
| `UUID` | 128-bit identifier |
| `DURATION`, `INTERVAL` | signed microseconds |
| `IDENTITY` | 32-byte identifier (hex text or a 32-byte blob) |
| `CONNECTION`, `CONNECTION_ID` | unsigned 64-bit connection id |

A length or precision in parentheses is accepted and ignored: text is unbounded.
Values must fit the declared width; a `FLOAT4` column rounds to single precision
on store.

## Column constraints

- `PRIMARY KEY` — inline (one column) or as a table constraint with one or more
  columns. It implies `NOT NULL` and a unique index.
- `AUTOINCREMENT` / `AUTO_INCREMENT` — only when the primary key is exactly that
  one integer column. It carries a sequence: `START n`, `INCREMENT n`,
  `MINVALUE n`, `MAXVALUE n` (defaults `1`, `1`, the type minimum, the type
  maximum). Inserting `NULL` or omitting the column assigns the next value; an
  explicit value moves the counter past it. The row id is internal and separate
  from the sequence.
- `UNIQUE` — inline or `[CONSTRAINT name] UNIQUE (a, b)`; creates a named
  unique index. Duplicate tuples fail.
- `NOT NULL` — an explicit `NULL` fails; omitting the column uses the default.
- `DEFAULT expr` — a constant expression evaluated when the table is created.

## Generated columns and collations

A column may be generated: `total INTEGER GENERATED ALWAYS AS (qty * price)
STORED` keeps the expression as text, evaluates it against the row being written
and stores the result, so `SELECT`, indexes, `CHECK` and `RETURNING` see it. A
generated column cannot be written directly (an `INSERT` that names it or an
`UPDATE … SET` on it is an error), and it cannot carry a `DEFAULT`.

`COLLATE BINARY|NOCASE|RTRIM` on a column applies when an expression does not
attach a collation of its own: comparisons, `ORDER BY`, unique keys and index
probes all fold the text the same way, so `name TEXT COLLATE NOCASE UNIQUE`
rejects `ALICE` beside `Alice` and `WHERE name = 'ALICE'` still uses the index.

## Expressions

- Literals: numbers (`42`, `-1.5`, `1e9`), strings (`'text'`, `''` escapes a
  quote), blobs (`x'00ff'`), `TRUE`, `FALSE`, `NULL`.
- Column references (`name`, `table.name`).
- Arithmetic `+ - * / %`, string concatenation `||`, unary `-`/`+`.
- Scalar functions: `lower`, `upper`, `length`, `substr`/`substring`, `trim`,
  `ltrim`, `rtrim`, `replace`, `concat`, `abs`, `sign`, `round`, `floor`, `ceil`,
  `sqrt`, `pow`, `mod`, `coalesce`, `nullif`, `now`.
- Comparisons `= == != <> < <= > >=`, `IS [NOT] NULL`, `[NOT] BETWEEN`,
  `[NOT] IN (...)`, `[NOT] LIKE` / `ILIKE` with `%` and `_`, and
  `ESCAPE 'c'` to make the next wildcard literal.
- Boolean `AND`, `OR`, `NOT` with SQL three-valued logic: `NULL` propagates
  through comparisons, `WHERE` treats `NULL` as false.
- `CAST(expr AS type)`.

## Functions

Aggregates: `count(*)`, `count(expr)`, `sum`, `avg`, `min`, `max`, `total`.

Scalar: `lower`, `upper`, `length`, `abs`, `coalesce`/`ifnull`, `now()`.

## Behaviour worth knowing

- Joins run as nested loops over the right-hand table: correct, but not planned
  yet. An `ON` clause is optional; without it the join is a cross product.
- `LEFT JOIN` extends a partial row with NULLs when no right row matches.
- Unqualified column names must be unique across the joined tables; qualify
  with the table name or its alias otherwise.
- `CREATE INDEX` and `DROP INDEX` are staged like any other change: a table, the
  rows in it and an index over them commit together, a rollback takes the index
  with it, and `DROP INDEX` on an index this transaction created is a no-op. The
  index is built when the transaction is applied, after the rows it covers.
- An equality or range predicate on a single indexed column narrows the scan
  through the index; the full `WHERE` is still re-checked, so the result is
  always exact.
- `ORDER BY` accepts a column, an alias, or a 1-based projection ordinal. The
  sort is stable and NULLs sort before values.
- `GROUP BY` groups by equality of the encoded group expressions. Without
  `GROUP BY`, an aggregate query produces exactly one row, even when the table
  is empty.
- `LIMIT`/`OFFSET` take constant non-negative integers.
- `DISTINCT` compares the whole projected row.
- Updates and deletes narrow their target rows through an index when the `WHERE`
  clause allows it, then stage one write per row; `affected` reports how many
  rows matched.
- Every result carries `commit_seq`, the sequence of the transaction that
  produced it (for a read, the last committed one).
- `HAVING` filters groups after the projections and aggregates are computed.
- A subscription may join tables: a commit to any of them refreshes it.

## Errors

Every failure carries an `Error_Kind`:

`syntax`, `unsupported`, `not_a_query`, `table_not_found`, `table_exists`,
`column_not_found`, `duplicate_primary_key`, `duplicate_unique`,
`not_null_violation`, `invalid_type`, `invalid_argument`, and the storage kinds
`io`, `corrupt_log`, `format_too_new`.

The parser reports `line L, column C` in the message. Engine errors do not
include positions; they refer to the table and column by name.

## Maintenance statements

`VACUUM` rewrites the live log as one snapshot record: startup becomes O(state)
instead of O(history), and a history of many small commits collapses, so the
directory shrinks (500 small commits of a 120-byte row: 94 KiB to 76 KiB). A
database written in one transaction already is a single record, so it keeps its
size; either way the standalone `snapshot` copy is removed, so a compacted
database is one artifact. 50k rows compact in 0.48 s for the whole command. `VACUUM INTO 'path'` writes that
same compacted copy somewhere else and leaves the live database alone; the copy
is a complete database (it opens, reads and takes commits). It also gives an
in-memory database a way to reach disk. Both are refused inside a transaction,
and an existing target path is not overwritten.

## Table-valued functions

`json_each(<json>)` and `json_tree(<json>)` behave like tables: `SELECT key,
value, type, atom, id, parent, fullkey, path FROM json_each('[10, "two"]')`
returns one row per node, and `json_tree` walks the whole document depth first
with a `parent` link. A container reports its JSON text as `value` and NULL as
`atom`; a scalar document is a single row with no key. The argument may be a
column of another table, which turns the call into a lateral join:
`SELECT docs.id, json_each.value FROM docs, json_each(docs.body)`.

## Attached databases

`ATTACH 'path' AS name` opens a second database read-only; its tables are then
readable as `name.table`, including in joins and with three-part references
(`name.table.column`). The name and path are recorded in the internal `_attach`
table, so reopening the principal restores the set. `DETACH name` forgets it.
Writes against an attached database are refused with
`writes to an attached database are read-only`, and both statements are refused
inside a transaction. Reading an attached table copies it whole for the
statement, which is what keeps the read path free of a second consistency model.

## Extensions

An extension is a process, not a shared library. It speaks the same wire
protocol as any client, so nothing but bytes crosses the boundary and an
extension cannot corrupt the host.

```sql
LOAD EXTENSION notes AT '127.0.0.1:7100' USING note, bump;
-- calls now go through host_call_module("notes", "note", args)
UNLOAD EXTENSION notes;
UNLOAD EXTENSION IF EXISTS notes;
```

The row is kept in `_extension`, so a restart registers the extension again
without connecting to it: a database whose extension is down still opens, and
the extension's calls fail until it is back. The optional `USING` list names the
reducers the extension offers; a call to any other name is refused before a
socket is opened. `host_call_module` applies the configured byte cap and the
socket timeouts, so a hung extension fails its call rather than the host.

Extensions are deliberately **not** DLLs: the engine allocates through the
calling component's allocator, and two allocators sharing one heap is how an
earlier in-process attempt corrupted memory. The process boundary is the
contract.

## Spatial indexes

`CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)` declares a
table of bounding boxes: `id` is the primary key and every other column is a
coordinate, given as min/max pairs (four for a 2D box, six for 3D). `rtree_i32`
stores the coordinates as integers instead of REAL.

```sql
CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy);
INSERT INTO places (id, minx, maxx, miny, maxy) VALUES (1, 0, 10, 0, 10);
SELECT id FROM places WHERE maxx >= 5 AND minx <= 5 AND maxy >= 5 AND miny <= 5;
```

An overlap or containment query is written as the min/max comparisons above,
which is what an R-tree accelerates in SQLite. Here the boxes are the table's
own columns and the comparisons are range predicates: the rows are the same, but
the cost of an unbounded query is a scan rather than a tree descent. A bounded
query — a point or a small window — stays cheap because the predicate is
selective. The tree layout is deliberately not claimed until it is measured.

## Full-text search

`CREATE VIRTUAL TABLE docs USING fts5(body, title)` makes a table of documents
whose text columns are indexed. The documents are stored as an ordinary table
and the index lives beside it in `_fts_docs_terms` (with `_fts_docs_docs` for the
document lengths and `_fts_docs_stats` for the corpus totals), so the index is
logged, replicated and repaired like any other data. The term index is created in
the same transaction as the table.

```sql
CREATE VIRTUAL TABLE docs USING fts5(body);
INSERT INTO docs (body) VALUES ('the quick brown fox'), ('a lazy dog sleeps');
SELECT body FROM docs WHERE docs MATCH 'fox';          -- one row
SELECT body FROM docs WHERE docs MATCH 'fox OR dog';   -- both
SELECT body FROM docs WHERE docs MATCH 'the fox';      -- both terms, one row
SELECT body FROM docs WHERE docs MATCH 'a NOT fox';    -- the second row
SELECT body, rank FROM docs WHERE docs MATCH 'fox OR dog' ORDER BY rank;
SELECT snippet(body, 'dog') FROM docs WHERE docs MATCH 'dog';
SELECT highlight(body, 'dog') FROM docs WHERE docs MATCH 'dog';
```

`MATCH` is case-insensitive over ASCII letters (`FOX` finds `fox`). Adjacent
terms are a conjunction, `OR` is a union, and `NOT` removes the documents that
carry the following term. `UPDATE` and `DELETE` maintain the index, `DROP TABLE`
removes the index with the table, and a reopen keeps searching.

`rank` is BM25 negated, so `ORDER BY rank` puts the best match first (the same
convention as SQLite's FTS5). It is computed from the postings: a term that few
documents contain weighs more than one they all contain, and at equal frequency a
short document outranks a long one. `snippet(text, pattern)` marks the match with
`[]` and keeps a window around the first one; `highlight(text, pattern)` marks
every match in the whole text.

The query walks the postings of its terms and the scan visits the matching
documents only, so the cost follows the answer rather than the vocabulary. A term
that every document carries costs its postings, because ranking has to look at
every candidate. Three limits remain: phrase queries (`"a b"`), prefix matching
(`foo*`) and column filters (`body:foo`) are not implemented, and a pattern taken
from a column of the row cannot narrow the scan (a constant or a `?` parameter
can).

## PRAGMAs

`PRAGMA` reaches the engine before parsing, so `PRAGMA name`, `PRAGMA name =
value`, `PRAGMA name(arg)` and a statement with its terminator (`PRAGMA name;`)
all work. Introspection pragmas answer from the catalog: `table_info`,
`table_xinfo`, `table_list`, `index_list`, `index_info`, `foreign_key_list`,
`database_list`, `schema_version`, `user_version`, `encoding`, `page_size`
and `compile_options`; `pragma_list` and `function_list` describe the engine.

Three of them do real work:

- `PRAGMA integrity_check` (and `quick_check`) walks every table on a read
  snapshot: each row must match its schema, each index must answer with the row
  that feeds it, no unique key may repeat, and every foreign key must resolve.
  A healthy database answers `ok`; otherwise one row per problem says what and
  where.
- `PRAGMA foreign_key_check` returns one row per orphan child: `table`, `rowid`,
  `parent` and `fkid`.
- `PRAGMA stats` reports the latency histograms as `(metric, value)`:
  `commits`, `queries`, then `commit_us_lt_<bound>` and `query_us_lt_<bound>`
  for bounds 1, 2, 4, … microseconds (20 doubling buckets, the last one
  covering everything above about a quarter of a second).

Settings a client inspects answer what the engine actually does:
`journal_mode` reports `delete` (there is no WAL; one commit is one durable
record) or `memory` for an ephemeral log, `synchronous` reports — and changes —
the log's durability, `cache_size` and `mmap_size` are `0`, `page_size` is the
export's 4096, `page_count`/`freelist_count`/`data_version` are real numbers.
Knobs that would change what a statement does (`query_only`,
`read_uncommitted`, `recursive_triggers`, `defer_foreign_keys`,
`ignore_check_constraints`, `legacy_alter_table`, `locking_mode`,
`case_sensitive_like`, `trusted_schema`, `reverse_unordered_selects`,
`writable_schema`) answer on a read and are refused on a write. The remaining
tuning-only names are accepted and answered neutrally, because the engine has no
equivalent knob.

## Window functions

A call followed by `OVER (...)` is a window function. It cannot run row by row,
so the executor keeps every output row, fills the window columns, and only then
sorts and applies `LIMIT`:

```sql
SELECT id, row_number() OVER (ORDER BY id DESC) AS rn,
       sum(n)   OVER (PARTITION BY g)          AS total,
       avg(n)   OVER (PARTITION BY g ORDER BY id) AS running
FROM s;
```

- `row_number`, `rank`, `dense_rank`, `percent_rank`, `cume_dist`, `ntile`,
  `lag`, `lead`, `first_value`, `last_value`, `nth_value`.
- Every group aggregate (`count`, `sum`, `avg`, `min`, `max`, `total`,
  `group_concat`) also works as a window; the frame is the partition up to the
  last peer of the current row, or the whole partition without `ORDER BY`.
- `ORDER BY` may name a window projection by its alias.
- Frames (`ROWS`/`RANGE`/`GROUPS`) and window functions beside `GROUP BY` are
  refused with `sql_unsupported` rather than approximated.

## Triggers

```sql
CREATE TRIGGER audit_insert AFTER INSERT ON t FOR EACH ROW
BEGIN
    INSERT INTO audit (note) VALUES ('in:' || NEW.a);
END;

DROP TRIGGER audit_insert;
```

- `AFTER INSERT`, `AFTER UPDATE` and `AFTER DELETE`, one per row, with `NEW`
  bound to the row being written and `OLD` to the stored one (the missing side
  of an event reads NULL).
- The body may hold several statements separated by `;`; they run in the same
  transaction as the write, so a failing trigger rolls the row back.
- The definition is a row in the internal `_triggers` table, which means it is
  logged, replayed and dropped like any other data, and needs no new file
  version.
- `BEFORE`, `WHEN` and column-specific (`OF`) triggers are refused with
  `sql_unsupported` instead of being approximated. A trigger that fires itself
  stops at a depth of 8 and fails the statement.

## Roles and permissions

```sql
GRANT insert ON t TO writer;      -- what a role may do
GRANT writer TO '*';              -- who has it: every caller
GRANT admin TO '0011…';           -- or one 32-byte identity, in hex
REVOKE writer FROM '*';
SELECT id FROM t WHERE has_role('admin');
```

- Writes (`INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`) are checked against the
  grant catalog in the transaction layer. A database that never granted
  anything stays as open as before, and internal `_` tables are always exempt.
- `GRANT role TO identity` takes `'*'` for every caller or the hex form of the
  caller's 32-byte identity (`current_identity()`); `has_role(name)` exposes
  the same membership to row policies.
- The catalog is `_role` and `_grant`, so it is logged, replayed and dropped
  like any other data. Reads remain the job of row policies.
