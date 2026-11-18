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
differences in the script is empty. The last two were an attached database that
could not be written and a full-text table without SQLite's shadow tables.

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
