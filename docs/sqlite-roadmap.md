# SQLite's surface: measured, missing, incompatible

The reference is SQLite 3.54.1, whose names are listed in
[sqlite-inventory.md](sqlite-inventory.md) (generated, do not edit).
[sqlite.md](sqlite.md) describes how each supported feature behaves; this file
says how much of the surface runs and what is left.

## Measured

`python scripts/sqlite_gaps.py` runs every built-in function and pragma of the
inventory, and 63 grammar shapes, through the CLI on an in-memory database.
Measured today: functions **119 / 119**, pragmas **63 / 63**, grammar **63 / 63**.

The function count leaves out ten names SQLite builds only for its own tests
(`expr_compare`, `fpdecode`, `oom`, …). A function or pragma counts as present
when the engine does not answer "unknown"; a grammar shape when every statement
of it runs. CI runs the script with `--check`, which fails when the counts above
are not the measured ones: a regression fails, and so does a feature that lands
without this file saying so.

Every gap is **refused with a message**, never answered differently.
`scripts/differential.py` (128 queries against SQLite) and the executed claims of
[sqlite.md](sqlite.md) keep that true.

## What is missing, by roadmap item

The detail of each item is in [backlog.md](backlog.md); the order is in
[roadmap.md](roadmap.md) (track B).

| Item | Missing today |
|---|---|
| **D4**, **D24** — the `.sqlite` mirror | secondary index b-trees patched in place; a reported skip for an index the engine cannot express |

## Incompatible on purpose, or substituted

| Area | Where it stands | Why |
|---|---|---|
| `sqlite3_*` C ABI | **done** as a facade: `bin/sqlite3_miraidb.dll`, 233 of SQLite's 309 functions with its result codes; the other 76 are S8 | — |
| `load_extension`, C functions | extensions run **out of process** (`LOAD EXTENSION … AT 'host:port'`); host functions and collations are registered from C | an in-process native plugin would share the engine's memory |
| VFS | `Vfs` with an OS, an in-memory and a fault-injecting implementation | — |
| WAL as the journal mode | a `-wal` or hot journal is **read** on import; the mirror writes a rollback journal in SQLite's format | durability is the commit log; WAL as the engine's own mode would be a second storage path |
| `ATTACH`/`DETACH` | engine directories and `.sqlite` files attach | — |
| FTS5, R*Tree | native: FTS5 with BM25, phrases and prefixes; R*Tree as a spatial table (a real tree is D2) | — |
| Byte-identical export | a written file is integrity-clean and deterministic, not byte-identical to SQLite's | packing choices differ; any reader accepts the file |
| `writable_schema`, shared cache, threading modes | refused or not offered | they would expose internals or features SQLite itself deprecates |
| Shell `.shell` / `.system` | not offered | no shell execution by design |
