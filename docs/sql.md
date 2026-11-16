# SQL subset

miraidb speaks its own SQL dialect. The grammar is fixed and hand written;
anything outside it is an error at parse time rather than something silently
misinterpreted, which is why this document is a list of what works and what is
refused. Identifiers are case-insensitive unless quoted with `"` or
backticks.

## Statements

```sql
SET name = expr
SHOW [name | tables]
ANALYZE [table]

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

`NATURAL`, `RIGHT` and `FULL` joins are refused by the parser, and so is
`JOIN … USING (col)`: write the condition in `ON` instead.
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
the join order, the post-processing steps and, when the predicate names a column,
the rows the plan expects to keep (`est. N rows`).

`ANALYZE` measures the tables once and stores what a plan needs: the row count of
each table and, per column, how many distinct non-null values and how many NULLs
it holds, plus the numeric range and a sixteen-bucket histogram over it.
`ANALYZE t` measures one table. The numbers live in `<db>/stats` and are loaded on
open; a plan without them assumes the table's full row count and keeps using the
index for a predicate that names one, which is what it did before statistics
existed.

The plan prices the two ways to read a table and takes the cheaper one: a scan
pays a row for every row of the table, a probe pays one descent plus a row for
every id the index hands over. An equality keeps about `rows / distinct` rows; a
range reads the histogram, so `amount < 50` over 400 rows with values 0..399 is
estimated at 50, not at the one-third rule's 133. `EXPLAIN` prints the estimate
and the cost it chose with (`est. N rows, cost C`).

Joins run as nested loops, and the order is planned rather than written: the
relation that keeps the fewest rows per outer row runs first, because it shrinks
everything after it. The conditions that connect relations travel with the step
that can answer them, so a relation may run before the join it was written with.
A LEFT join, an `AS OF` pin or a table function keeps the written order, because
there the order is part of the meaning. `EXPLAIN` prints `join order: a, c, b`
when the order changed.

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

## Schema changes

```sql
ALTER TABLE t RENAME TO t2;
ALTER TABLE t ADD COLUMN note TEXT NOT NULL DEFAULT '';
ALTER TABLE t DROP COLUMN note;
ALTER TABLE t RENAME COLUMN label TO name;
ALTER TABLE t RENAME label TO name;     -- COLUMN is optional
ALTER TABLE t ALTER COLUMN qty TYPE REAL;
ALTER TABLE t ALTER qty SET DATA TYPE REAL;  -- the standard's spelling
```

- A rename keeps the rows and the indexes: indexes refer to columns by
  position, so nothing has to be rebuilt. Adding or dropping a column matches
  the surviving columns by name; a rename matches by position, which is what
  keeps the data.
- A type change rewrites the table: every stored value is converted with the
  rules of `CAST` (`INTEGER` to `TEXT` gives the digits, `TEXT` to `INTEGER`
  parses the number), the declaration becomes the new type, and the indexes are
  rebuilt over the converted keys. A value the conversion refuses — `'thirty'` to
  `INTEGER` — refuses the whole statement and leaves every row as it was; a
  conversion that makes two unique keys equal is refused the same way. SQLite
  spells this as a table rebuild; here it is one statement, and the replay of its
  log record converts too, so a reopened database agrees with the one that ran it.
  A generated column is refused, because its value is computed rather than stored.
- Text that names a column — a generated expression, a trigger body, a policy
  condition, a view — is stored as written and is **not** rewritten by a rename.
- Inside an explicit transaction, a renamed table keeps answering to its old
  name until `COMMIT`, and the new name is not visible before then. Statements
  that follow a rename in the same transaction should use the old name.
- A virtual table (full-text or spatial) keeps the column names its index was
  built with, so renaming one is refused.

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

A program can also register a comparison of its own (`store_register_collation` in
the engine, `miraidb_create_collation` from C) and name it the same way:

```sql
SELECT count(*) FROM people WHERE name = 'Søren' COLLATE spanish;
```

The callback answers negative, zero or positive, and it is asked wherever a
comparison happens: `WHERE`, `ON`, `HAVING`, `CASE` and the comparison an `IS` or a
`BETWEEN` makes. A name nobody registered is an error (`no such collation: x`),
as it is in SQLite, instead of quietly comparing bytes.

A host comparison has no **folded form**: two texts can compare equal and still
differ byte for byte, and this engine orders, groups and indexes by a key it folds
from the text (`NOCASE` lowercases it, `RTRIM` trims it). So `ORDER BY`, `GROUP BY`,
`DISTINCT`, a window's `PARTITION BY`/`ORDER BY`, an index and a column declaration
all refuse a host collation with `collation x cannot order, group or key`, naming
the reason. Refusing beats answering in the wrong order: `ORDER BY name COLLATE
spanish` would sort by bytes while `WHERE … COLLATE spanish` compared differently.

The three built-in names are reserved and cannot be replaced. Registrations belong
to the process - one connection's C registrations are dropped when it closes - and
nothing about them is written to the database.

## Expressions

- Literals: numbers (`42`, `-1.5`, `1e9`), strings (`'text'`, `''` escapes a
  quote), blobs (`x'00ff'`), `TRUE`, `FALSE`, `NULL`.
- `CASE [x] WHEN … THEN … [ELSE …] END`, both the simple form (every `WHEN` is
  compared with `x`) and the searched form (every `WHEN` is a condition). The
  first match wins, a `NULL` condition or operand never matches, no `ELSE` gives
  `NULL`, and only the chosen branch is evaluated.
- Column references (`name`, `table.name`).
- Arithmetic `+ - * / %`, string concatenation `||`, unary `-`/`+`.
- `printf`/`format` with SQLite's own conversions: `%d %i %u %o %x %X %f %e %g
  %s %c %q %%`, the flags `- 0 + space`, a width and a `.precision`; an unknown
  conversion is written back as it came.
- Scalar functions: `lower`, `upper`, `length`, `substr`/`substring`, `trim`,
  `ltrim`, `rtrim` (the second argument is the set of characters to remove; the
  default is the space), `replace`, `concat`, `abs`, `sign`, `round`, `floor`,
  `ceil`, `sqrt`, `pow`, `mod`, `coalesce`, `nullif`, `now`, and `min`/`max`
  with two or more arguments, which compare their arguments instead of folding a
  column.
- Comparisons `= == != <> < <= > >=`, `IS [NOT] NULL`, `[NOT] BETWEEN`,
  `[NOT] IN (...)`, `[NOT] LIKE` / `ILIKE` with `%` and `_`, and
  `ESCAPE 'c'` to make the next wildcard literal.
- Boolean `AND`, `OR`, `NOT` with SQL three-valued logic: `NULL` propagates
  through comparisons, `WHERE` treats `NULL` as false.
- `[NOT] IN` follows the same rule: a `NULL` in the list (or in the subquery)
  makes a non-match unknown, so `x NOT IN (1, NULL)` returns no row unless
  `x = 1`, rather than every row whose value is not 1.
- `CAST(expr AS type)`.

## Functions

Aggregates: `count(*)`, `count(expr)`, `sum`, `avg`, `min`, `max`, `total`.

Scalar: `lower`, `upper`, `length`, `abs`, `coalesce`/`ifnull`, `now()`,
`min(a, b, …)`/`max(a, b, …)`, and `trim(s[, chars])` with its two variants.

## Behaviour worth knowing

- A join is a nested loop, and its order is planned from `ANALYZE` statistics:
  the relation that keeps the fewest rows per outer row runs first and every
  `ON` travels with the step that completes the relations it names, so a
  relation may run before the join it was written with. `LEFT` joins, `AS OF`
  and table functions keep the written order, and `EXPLAIN` prints
  `join order: …`. An `ON` clause is optional; without it the join is a cross
  product.
- `JOIN b USING (c, …)` is the equality `a.c = b.c` for every column named, where
  `a` is the relation written before the join, and it is planned like any other
  condition. It carries one extra rule: `SELECT *` prints a merged column once,
  from the left relation, and lists the right one without it — `a JOIN b USING
  (id)` yields `a.id, a.…, b.…`, while `b.*` still lists every column of `b`. A
  column that is not in the left relation is an error, not a cross join.
- `SELECT *` lists the columns of the relations **as written**, even when the plan
  runs them in another order.
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
  sort is stable and NULLs sort before values; rows that compare equal come back
  in row id order, so the same query always answers the same sequence.
- `GROUP BY` groups by equality of the encoded group expressions, and accepts a
  projection alias: `SELECT dept AS d … GROUP BY d` groups by `dept`. A name that
  is a column of a source still means the column, so aliasing `salary` to `dept`
  does not regroup anything. Without `GROUP BY`, an aggregate query produces
  exactly one row, even when the table is empty.
- `LIMIT`/`OFFSET` take constant non-negative integers (SQLite reads `LIMIT -1` as
  "no limit"; this engine refuses it).
- Text positions are characters, not bytes: `length('héllo')` is 5,
  `instr('héllo', 'llo')` is 3 and `substr('héllo', 2, 2)` is `él`.
  A text value is still a byte string, so `octet_length('héllo')` is 6 and
  `hex('é')` is `C3A9` — the bytes, as SQLite answers them. The two rules are
  different questions: a *position* is a character, a *byte* is a byte.
- `substr(s, start[, length])` follows SQLite: a negative `start` counts from the
  end (`substr('abcdef', -3)` is `def`), a start of zero names the character
  before the first one (`substr('abcdef', 0, 3)` is `ab`), a negative length
  returns the characters *before* the start (`substr('abcdef', 2, -2)` is `a`),
  and a `NULL` argument answers `NULL`.
- `WHERE` asks a value for its truth. A number is true when it is not zero, and a
  text is converted to a number first, as SQLite does: its numeric prefix counts,
  so `'12'` is true, `'12a'` is true, `'a'` is false, `''` is false and `'0'` is
  false. The same rule governs `CASE WHEN`, `HAVING` and a policy's `USING`.
  Comparison stays strict: `1 = '1'` is a type error, not a match.
- `INSERT OR REPLACE` deletes every row the new one collides with, on the primary
  key or on any unique index, and then inserts: two rows that collide under two
  different indexes both go and one arrives, `affected` counts the inserted row,
  and delete triggers do not fire (SQLite's behaviour with recursive triggers
  off). `INSERT OR ABORT` is what a plain `INSERT` already does; `OR ROLLBACK`,
  `OR FAIL` and `OR IGNORE` are refused with a message that says so.
- `DISTINCT` compares the whole projected row. Inside an aggregate it folds each
  value once: `count(DISTINCT x)`, `sum(DISTINCT x)` and `group_concat(DISTINCT
  x)` count, add or join the distinct values only, and `NULL` is not a value.
  An integral float and an integer that compare equal count as one.
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
database is one artifact. 50k rows compact in 0.48 s for the whole command.
`VACUUM INTO 'path'` writes that
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
inside a transaction. A database opened *without* host access refuses `ATTACH`
with `Permission_Denied` before it looks at the path: the path is the caller's,
not the operator's. `miraidb-server` opens without host access unless it was
started with `--allow-host` (`docs/security.md`). Reading an attached table copies it whole for the
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

Like `ATTACH`, a load is refused with `Permission_Denied` when the database was
opened without host access; `UNLOAD` stays allowed, because it only forgets.
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

## Tables on disk (opt-in)

A store opened with `paged_tables` (CLI `--paged`, `--page-frames=N`) keeps new
tables in a page file instead of memory. SQL does not change; the differences are
cost and two refusals:

- a single-table query streams the pages, so `WHERE`, projections, aggregates and
  `LIMIT` do not need the table in memory; `ORDER BY`, `GROUP BY`, `DISTINCT`,
  windows and joins collect it first;
- `AS OF` on a paged table is refused (`Sql_Unsupported`): a page keeps one
  version of a row;
- `ALTER TABLE` on a paged table is refused: the rewrite walks the row map that a
  paged table does not have;
- an index of a paged table lives in its own page file, so a filtered lookup or a
  range does not pay for the keys of the whole table in memory. A key longer than
  1000 bytes cannot be indexed: the insert fails with the limit in the message,
  and the same value held in a table without that index is fine.

## Reading the past

`FROM t AS OF <seq>` reads the rows as they were when commit `<seq>` landed:

```sql
SELECT * FROM t AS OF 4;                 -- the table at commit 4
SELECT v FROM t AS OF 4 WHERE id = 1;    -- the value it had then
```

The engine keeps the previous values of a row when it is updated, and keeps a
deleted row as a tombstone, so the past is available without a second copy. A
historical scan does not use an index: the keys of that commit are not the live
ones. `AS OF` reads only the first table of a query (a join answer is refused),
a sequence past the last commit is clamped to it, and `store_prune_versions` (the
server calls it when readers fall behind) discards history that no one can ask
for: after pruning, a read before that point sees only the rows whose versions
survived.

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
SELECT body FROM docs WHERE docs MATCH '"quick brown"'; -- a phrase
SELECT body FROM docs WHERE docs MATCH 'qu*';          -- a prefix
SELECT body FROM docs WHERE docs MATCH 'body:fox';     -- one column only
SELECT body, rank FROM docs WHERE docs MATCH 'fox OR dog' ORDER BY rank;
SELECT snippet(body, 'dog') FROM docs WHERE docs MATCH 'dog';
SELECT highlight(body, 'dog') FROM docs WHERE docs MATCH 'dog';
```

`MATCH` is case-insensitive over ASCII letters (`FOX` finds `fox`). A pattern is
a list of items separated by spaces:

| Item | Matches |
|---|---|
| `fox` | documents that contain the term |
| `fox*` | documents that contain a term starting with `fox` |
| `"quick brown fox"` | the words adjacent and in this order; `"quick bro*"` ends in a prefix |
| `body:fox` | the item in one column only; it also takes a phrase or a prefix (`body:"a b"`, `body:fo*`) |
| `a b`, `a AND b` | both items (`AND` is the default and changes nothing) |
| `a OR b` | either item; `OR` binds looser than juxtaposition, so `a b OR c` is `(a b) OR c` |
| `a NOT b` | the documents of `a` that do not match `b` |

A bare item that the tokenizer splits into several words, such as `don't`, is a
phrase of those words. Naming a column the table does not have is an error
(`column_not_found`). `UPDATE` and `DELETE` maintain the index, `DROP TABLE`
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
every candidate. A prefix reads one range of the term index. The index keeps no
positions and no column, so a phrase or a column filter takes the documents that
carry all of its words as candidates and then reads each candidate's text to
confirm the order or the column: the cost is the documents that hold every word,
never the corpus. For a phrase item, `rank` counts the phrase's occurrences, not
its words'. Grouping with parentheses and `NEAR` are not implemented, and a
pattern taken from a column of the row cannot narrow the scan (a constant or a
`?` parameter can).

## PostgreSQL spellings

The dialect accepts what a PostgreSQL client, an ORM or a migration tool sends
first, so a schema written for PostgreSQL runs here unchanged in the common
cases. Each spelling maps onto a construct the engine already has:

| PostgreSQL | Here |
|---|---|
| `x::type`, `x::numeric(10, 2)` | `CAST(x AS type)`; binds tighter than any operator |
| `SERIAL`, `BIGSERIAL`, `SMALLSERIAL` | an integer column with a sequence (`AUTOINCREMENT`) |
| `GENERATED ALWAYS AS IDENTITY`, `GENERATED BY DEFAULT AS IDENTITY` | the same; `ALWAYS` does not refuse an explicit value |
| `$1`, `$2`, … | numbered parameters: `$n` binds the n-th value and may repeat |
| `VARCHAR(n)`, `CHARACTER VARYING(n)`, `CHAR(n)`, `TEXT`, `CITEXT`, `NAME` | `TEXT`; the length is read and not enforced |
| `JSON`, `JSONB`, `XML`, `INET`, `CIDR`, `MACADDR` | `TEXT`; the `json_*` functions read JSON text |
| `DATE`, `TIME` | ISO-8601 `TEXT`, as SQLite stores them |
| `TIMESTAMP [WITH[OUT] TIME ZONE]`, `TIMESTAMPTZ` | `TIMESTAMP` (microseconds, no zone) |
| `NUMERIC(p, s)`, `DECIMAL`, `MONEY` | `DOUBLE`: binary floating point, the scale is not enforced (exact decimals are backlog D10) |
| `DOUBLE PRECISION`, `REAL`, `INT2`/`INT4`/`INT8`, `BYTEA`, `UUID`, `BOOLEAN` | the types of the same name |
| `version()`, `current_database()`, `current_schema`, `current_user`, `session_user` | session values that name this engine |
| `public.t` | `t` |
| `information_schema.tables`, `information_schema.columns`, `pg_catalog.pg_tables` | system tables built from the live schema, with PostgreSQL's column names |
| `ILIKE` | case-insensitive `LIKE` |

What is not mapped: other `pg_catalog` tables (so `psql`'s `\d` does not work),
`CREATE SCHEMA`, arrays written `int[]`, `RETURNING` with expressions over
several tables, and the PostgreSQL error-message texts (the SQLSTATE codes are
sent, see below). A cast to `int` truncates, where PostgreSQL rounds.

Over the wire (`miraidb-server`, any port: the server recognises the startup
packet) a connection keeps PostgreSQL's session rules:

- `BEGIN` opens a transaction that spans messages until `COMMIT` or `ROLLBACK`.
  A statement that fails inside it aborts it: every later statement answers
  `25P02` until `ROLLBACK`, and `COMMIT` then rolls back and says `ROLLBACK`.
  ReadyForQuery reports `I`, `T` or `E` accordingly. While a transaction is open
  the connection holds the writer, so other connections wait for it, as they
  would for any writer here; a client that leaves a transaction idle blocks the
  others until it ends or disconnects (which rolls it back).
- A Query message may carry several statements separated by `;`; the first
  error ends it.
- Every statement gets the tag drivers read their row count from (`INSERT 0 2`,
  `UPDATE 1`, `SELECT 3`, `CREATE TABLE`), and every error carries a SQLSTATE
  (`23505` for a duplicate key, `42P01` for an unknown table, `42703` for an
  unknown column, …), so psycopg raises `UniqueViolation` and JDBC reports the
  state.
- The extended protocol follows the specification: messages may arrive several
  to a packet, `Describe` of a portal announces the column types its rows are
  then encoded in, `Execute` sends rows without a description, ReadyForQuery
  belongs to `Sync`, and after an error everything up to `Sync` is discarded.
  To announce exact types, `Describe` of a bound portal runs its statement and
  keeps the answer for `Execute`: a client that describes a write and then
  closes the portal without executing it has still written. Drivers describe a
  portal only to execute it, so this costs nothing in practice.
  `DEALLOCATE` and `DISCARD ALL` are answered by the session.

`psql` and psycopg 3 (text and binary results, server-side parameters, prepared
statements, transactions, `executemany`) are exercised against the server.

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
- A frame decides which rows the aggregate sees. Bounds are
  `UNBOUNDED PRECEDING`, `<n> PRECEDING`, `CURRENT ROW`, `<n> FOLLOWING` and
  `UNBOUNDED FOLLOWING`; `<unit> <bound>` is the shorthand ending at the current
  row. An explicit frame also moves `first_value`, `last_value` and `nth_value`,
  and an empty frame is an empty group (`count` 0, `sum` NULL).
- The unit says what the bounds count:
  - `ROWS` counts rows: `OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1
    FOLLOWING)`.
  - `GROUPS` counts peer groups, so `GROUPS 1 PRECEDING` reaches back one distinct
    value of the ordering: `OVER (ORDER BY n GROUPS BETWEEN 1 PRECEDING AND 1
    FOLLOWING)`.
  - `RANGE` without an offset is the peers of the row; with an offset it runs
    from the order *value* that far below to the value that far above —
    `OVER (ORDER BY n RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING)` covers every
    row whose `n` is within ten of this row's. That needs exactly one numeric
    `ORDER BY` term, in either direction; a text ordering there is refused rather
    than given an interpretation SQL reserves for its type order.
- `DISTINCT` inside a window (`count(DISTINCT v) OVER (…)`) counts the distinct
  argument values of the frame, the same way the aggregate does.
- Beside `GROUP BY` the window's input rows are the **groups**, so the argument of
  an aggregate window may itself be an aggregate: `sum(count(*)) OVER ()` is the
  total of the per-group counts, which is the percentage-of-total shape:

  ```sql
  SELECT k, count(*) AS n, sum(count(*)) OVER () AS total FROM t GROUP BY k;
  ```

  The ranking windows read the keys the group captured (`rank() OVER (ORDER BY
  count(*) DESC)` numbers the groups), and `ORDER BY` may name either the window
  projection or the aggregate. A `RANGE` frame with an offset is refused beside
  `GROUP BY`: it re-reads its `ORDER BY` value per row, and that value may be an
  aggregate whose group is already gone.
- A projection that contains a window turns the `LIMIT` pushdown off, wherever the
  window sits: the frame is the whole table, so the scan may not stop early.
- A window can sit inside a larger expression: `sum(n) OVER () + 1`, `abs(sum(n)
  OVER () - 20)`, `CASE WHEN max(n) OVER () > 10 THEN … END`. The executor fills the
  window into a hidden slot of the row and then evaluates the projection over it, so
  the arithmetic runs per row over an answer that already covers the frame. Several
  windows in one expression work, and `ORDER BY` may name the alias.
- A window in `WHERE`, `GROUP BY` or `HAVING` is still refused: those run before the
  rows exist, and so is a window nested in a window.

## Host functions

A program that embeds the engine can register a scalar function, and SQL can then
call it like any other:

```c
static int twice(void *user, const miraidb_value *args, int argc, miraidb_value *result) {
    result->type = MIRAIDB_INT;
    result->i = args[0].i * 2;
    return MIRAIDB_OK;
}
miraidb_create_function(db, "twice", 1, twice, NULL);
```

```sql
SELECT twice(v) FROM t WHERE twice(v) > 10;
SELECT twice(count(*)) FROM t GROUP BY k;
```

- The registry is consulted **last**: a builtin keeps its name, so a registration
  cannot quietly replace `upper()`.
- `arity` is exact, or `-1` for any number; the count is checked before the handler
  runs, and a mismatch is the statement's error.
- The arguments are evaluated before the call, so a host function works per row, in
  `WHERE`, and as the argument of an aggregate (where it sees the group).
- A handler receives values as `miraidb_value`: a tag, an integer, a real and a
  borrowed buffer. Text it returns is copied when it returns, so a temporary buffer
  is allowed; text it receives is borrowed for the duration of the call.
- Registrations belong to the process, not to the database: they are not logged,
  they do not survive a reopen, and `miraidb_close` drops them.

## Triggers

```sql
CREATE TRIGGER audit_insert AFTER INSERT ON t FOR EACH ROW
BEGIN
    INSERT INTO audit (note) VALUES ('in:' || NEW.a);
END;

DROP TRIGGER audit_insert;
```

- `BEFORE` and `AFTER`, for `INSERT`, `UPDATE` and `DELETE`, one row at a time,
  with `NEW` bound to the row being written and `OLD` to the stored one (the
  missing side of an event reads NULL). An `AFTER` trigger runs once the row is
  staged; a `BEFORE` trigger runs while the row is still only proposed, so a body
  that fails stops the write and takes its own effects with it.
- The body may hold several statements separated by `;`; they run in the same
  transaction as the write, so a failing trigger rolls the row back.
- The definition is a row in the internal `_triggers` table, which means it is
  logged, replayed and dropped like any other data, and needs no new file
  version.
- `WHEN <condition>` decides whether the trigger fires for a row, with `NEW`
  and `OLD` in scope: a false or NULL condition skips it without failing the
  write. The condition is checked when `CREATE TRIGGER` parses it, so a typo is
  reported there rather than on the first write.
- Column-specific (`OF`) triggers are refused with `sql_unsupported` instead of
  being approximated. A trigger that fires itself stops at a depth of 8 and fails
  the statement.

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
