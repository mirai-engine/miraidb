# SQLite semantics on the SQLite face

The engine has its own rules for a few operations where SQLite's answer hides a
mistake: a division by zero, an integer that overflows, a cast that cannot
hold its value. Those rules are deliberate and stay the engine's (see
[sqlite.md](sqlite.md#semantics-that-differ-from-sqlite)). A program written
against SQLite, though, depends on SQLite's answers: through the `sqlite3_*`
face it has to get them, or it is not a drop-in replacement.

This file records the differences that were found, what each face answers, and
how the claim is checked.

## Which rules apply where

| Connection | Rules |
|---|---|
| the `sqlite3_*` face (`sqlite3_open` and friends) | SQLite's |
| a SQLite file (`.sqlite`/`.db`) opened by the CLI, the server or the embedded API | SQLite's |
| an engine database (a directory) through the CLI, the server, the embedded API or the C ABI | the engine's |

Under SQLite's rules a table, view or index name matches whatever its case
(`INSERT INTO T` reaches `t`, `CREATE TABLE T` fails when `t` exists), as in
SQLite; the engine's own rules keep names exact
(`test_names_match_without_case_under_sqlite_rules`).

CPython's own tests of its `sqlite3` module run on the facade
(`scripts/python_sqlite3.py`, a gate of `scripts/ci.py`): every test that
passes with SQLite has to pass here, and every one does: the list of known
differences in the script is empty. SQLite's own shell does too, line for line
against SQLite 3.54.1 (`scripts/sqlite_shell.py`), with no known difference.
The last ones were the text of a `WITHOUT ROWID` table, an attached database
that could not be written and a full-text table without SQLite's shadow tables.

Under SQLite's rules the errors SQLite gives at prepare are given at prepare,
in its words, and `sqlite3_error_offset` points at the name they are about: a
column two relations of the query have (`ambiguous column name: a`; a `USING`
or `NATURAL` column is the join's, and a real column wins over `rowid`), a
function SQLite does not have (`no such function: f`) or a count of arguments
its function does not take (`wrong number of arguments to function abs()`,
read from SQLite 3.54.1's own functions by `scripts/function_table.py`), a
second trigger of one name, and `RENAME TO` a name another table, view or index
has. A bare column beside `min()` or `max()` reads the row they chose. Two
cases are left: `SELECT *` over one table named twice without an alias, which
SQLite refuses (`ambiguous column name: main.v.a`), and an alias equal to an
ambiguous column (`SELECT a AS a FROM v, w`), which the engine refuses only
when the row is read.

SQLite's own tools found the rest of what this section lists as SQLite's
(`scripts/sqlite_tools.py` runs sqldiff, dbhash and mptest on the facade):
`sum()` adds a boolean as its integer and a text as its number, `total()` is
always a real (0.0 over no rows); UNION, INTERSECT and EXCEPT answer in the
order of SQLite's temporary index (NULL, numbers, texts by the first COLLATE a
term writes, blobs); `strftime` knows every code of 3.54 and answers NULL for
one it does not; a time is read in whole milliseconds and never rounded into
the next second; `printf()`/`format()` are SQLite's printf, the one
`sqlite3_mprintf` answers with; `quote()` of a real is `%!0.17g`; a literal
past a double's range is infinity; a REAL column keeps `-0.0` as `0.0`; a
PRAGMA may follow a comment; `PRAGMA page_size = N` answers no row and takes
effect at the next `VACUUM`, or at once on a file with no table, and a file
keeps the page size it has (from 512 to 65536); a connection opened read-only
writes its TEMP tables, as SQLite's temp database is writable when main is
not, and a TEMP table's commit leaves the file alone. The gate has no known
difference left.

The switch is one flag on the store, `sqlite_rules`, set by `sqlite3_open` and
by opening a SQLite file. Foreign keys follow the same split: off until
`PRAGMA foreign_keys = ON` under SQLite's rules, on under the engine's.

## The differences

Each row was measured through the `sqlite3_*` face against SQLite itself before
the change (`scripts/sqlite_abi_semantics.py` runs the same statements through
both and fails on any answer that differs).

| Case | SQLite | Engine's rules | SQLite face, before |
|---|---|---|---|
| `1 / 0`, `5 % 0`, `1.0 / 0` | `NULL` | error "division by zero" | the engine's error |
| `9223372036854775807 + 1`, `- 1`, `* 2` | the result as a REAL | error "integer overflow" | the engine's error |
| `-9223372036854775808 / -1`, `-(-9223372036854775808)` | a REAL | error, or a 128-bit integer | the engine's answer |
| `sum()` over integers that overflows | error "integer overflow" | wrapped silently | wrapped silently |
| `10 % 3.5` | `1.0`: both operands are taken as integers | `3.0` (a real remainder) | `3.0` |
| `CAST('12abc' AS INTEGER)`, `' 7x'`, `'3.9'`, `'1e3'` | the longest integer prefix: `12`, `7`, `3`, `1` | error | the text, unconverted |
| `CAST('abc' AS INTEGER)`, `AS REAL` | `0`, `0.0` | error | the text, unconverted |
| `CAST('9999999999999999999' AS INTEGER)` | clamped to `9223372036854775807` | error | a wrapped number |
| `CAST('1.5x' AS REAL)`, `CAST('12abc' AS NUMERIC)` | the longest numeric prefix: `1.5`, `12` | error | the text, unconverted |
| `upper(char(233))`, `lower(char(201))`, `upper('straße')` | ASCII letters only: `é`, `É`, `STRAßE` | Unicode case mapping | Unicode case mapping |
| `'É' LIKE 'é'` | false: LIKE folds ASCII only | true | true |
| `1 + '2'`, `'3' * '4'`, `upper(5)` | `3`, `12`, `'5'`: a text operand is read as a number, any value as text | error: arithmetic needs numbers, `upper` needs text | the engine's error |
| `1.0 \|\| ''`, `1e-7 \|\| ''`, `x'41' \|\| 'b'` | `'1.0'`, `'1.0e-07'`, `'Ab'` | `'1'`, `'1e-07'`, `"x'41'b"` | the engine's text |
| `HAVING c > 1` where `c` names `count(*)` in the select list | works | error "column c does not exist" | the engine's error |
| `CAST(300 AS TINYINT)` | `300` (INTEGER affinity) | error: does not fit the width | `300` already |

The last row was already right on the SQLite face, which reads a declared type
by its affinity; it is listed because the engine's rule differs.

## What changed

- Arithmetic under SQLite's rules: a division or a remainder by zero is
  `NULL`; an integer `+`, `-`, `*`, `/` or negation that does not fit 64 bits
  is computed as a REAL; `%` takes both operands as integers and answers a
  REAL when either was one.
- `sum()` of integers that overflows 64 bits is an error, "integer overflow",
  under both rules: wrapping silently was a defect, not a rule.
- `CAST` under SQLite's rules reads the target by its affinity and converts
  as SQLite does: INTEGER takes the longest integer prefix (clamped), REAL the
  longest real prefix, NUMERIC the longest numeric prefix (an integer when it
  is one and fits), TEXT the value's text, BLOB its bytes; a text with no
  number is `0`.
- `upper`, `lower` and `LIKE` fold ASCII letters only under SQLite's rules,
  and `upper`/`lower` take any value as its text.
- Arithmetic reads a text or a blob operand as the number it starts with, and
  `||` writes a real and a blob as SQLite does (`1.0`, the blob's bytes).
- `HAVING` may name an alias of the select list, under both rules.

## Still different, on purpose

Under SQLite's rules nothing in the table above differs any more. Under the
engine's rules every row but the last two keeps the engine's answer, and
[sqlite.md](sqlite.md#semantics-that-differ-from-sqlite) lists those together
with the rest of the engine's own semantics (an `UPDATE` whose keys collide
only partway through, a failed deferred key at `COMMIT`).
