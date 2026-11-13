# SQLite features: done, pending, incompatible

Inventory of the reference (3.54.1, `docs/sqlite-inventory.md`): **62 keywords,
131 built-in functions, 63 pragmas**, plus the file format, the C API and the
shell. This file splits that surface into what is already in the engine, what
can be added, and what is deliberately incompatible.

**Status: the sections marked done are delivered and tested.** What remains is
depth, not surface: the rest of the grammar (D9), an index on the full-text term
column shape (D1 is done; a `MATCH` that a plan can narrow further is not), the
sensitivity of the cost model to bound values (D6), and secondary indexes inside
the page-patched `.sqlite` mirror (D4 re-encodes those tables) — see
[backlog.md](backlog.md).

## 1. Done

**File format** — header/page size/encoding, `sqlite_master`, table b-trees
(leaf and interior), `WITHOUT ROWID` indexing (read), varints and serial types,
overflow chains, writer producing integrity-clean files, import/export and
auto-detection by magic bytes.

**Embedding** — Odin API (`embed_open`, prepare/bind/step/column), C ABI
(`src/capi`, `include/miraidb.h`) and a ctypes smoke test.

**SQL** — `RETURNING` (`*` and column lists) on INSERT/UPDATE/DELETE; UPSERT
`DO NOTHING` and `DO UPDATE SET`; `GLOB`/`NOT GLOB`; case-insensitive `LIKE`;
`||`; automatic `INTEGER PRIMARY KEY`; joins, subqueries, aggregates, views,
RLS, event tables, indexes (btree/hash/direct), foreign keys with
`RESTRICT`/`CASCADE`.

**Functions** (≈36) — `abs`, `ceil`, `char`, `coalesce`, `concat`, `format`/
`printf`, `floor`, `hex`, `iif`, `ifnull`, `instr`, `length`, `lower`, `ltrim`,
`mod`, `now`, `nullif`, `pow`, `quote`, `replace`, `round`, `rtrim`, `sign`,
`sqrt`, `sqlite_version`, `substr`, `trim`, `typeof`, `upper`, and the
aggregates `count`, `sum`, `avg`, `min`, `max`, `total`.

**Pragmas** (32 of 63 answered) — `table_info`, `table_xinfo`, `table_list`,
`index_list`, `index_info`, `foreign_key_list`, `foreign_key_check`,
`database_list`, `user_version`, `application_id`, `schema_version`,
`page_size`, `encoding`, `journal_mode`, `synchronous`, `cache_size`,
`mmap_size`, `page_count`, `freelist_count`, `data_version`,
`max_page_count`, `foreign_keys`, `integrity_check`, `quick_check`,
`sqlite_version`, `compile_options`, `stats`, `pragma_list`,
`function_list`, `temp_store`, `stats` and the accepted tuning names. Eleven
semantic knobs (`query_only`, `read_uncommitted`, `recursive_triggers`,
`defer_foreign_keys`, `ignore_check_constraints`, `legacy_alter_table`,
`locking_mode`, `case_sensitive_like`, `trusted_schema`,
`reverse_unordered_selects`, `writable_schema`) answer on a read and are
refused on a write.

## 2. Pending, compatible

### Statements and DDL
1. `WITH` / `WITH RECURSIVE` (a step quota bounds the recursion).
2. `SAVEPOINT`, `RELEASE`, `ROLLBACK TO` (markers in the staged op list).
3. `ALTER TABLE` `RENAME COLUMN`, `DROP COLUMN`, `RENAME TO`.
4. `INSERT ... SELECT` and `UPDATE ... FROM` / `DELETE ... USING`.
5. `excluded` in UPSERT (a qualified-only source).
6. `GENERATED ALWAYS AS` columns and `STRICT` tables.
7. `CREATE TRIGGER` (declarative SQL triggers; reducers cover the rest).
8. `VACUUM INTO`, `ANALYZE`, `REINDEX` (the engine has `compact`).

### Expressions
9. `COLLATE BINARY|NOCASE|RTRIM` and the collation list.
10. Window functions (`OVER`, `PARTITION BY`, `ROWS`/`RANGE`, `FILTER`) and
    ordered-set aggregates.
11. Bitwise `&`, `|`, `~`, `<<`, `>>`.

### Functions
12. Date and time: `date`, `time`, `datetime`, `strftime`, `julianday`,
    `unixepoch`, `timediff`, `current_date`, `current_time`.
13. `group_concat`/`string_agg`, `changes`, `total_changes`,
    `last_insert_rowid`, `random`, `randomblob`, `zeroblob`, `unhex`,
    `unicode`, `octet_length`, `concat_ws`, `like`, `glob`, `printf` flags.
14. Math: `acos`…`atan2`, `sin`/`cos`/`tan`, `degrees`, `radians`, `log`,
    `log2`, `log10`, `exp`, `ln`, `trunc`.
15. JSON: `json`, `json_extract`, `json_array`, `json_object`, `json_set`,
    `json_type`, `json_valid`, `json_each`/`json_tree` (table functions).
16. `soundex`, `likely`/`unlikely` (planner hints or no-ops).

### Pragmas (what remains)

17. Introspection still missing: `collation_list`, `module_list`,
    `incremental_vacuum`, `temp_store_directory`, `data_store_directory`,
    `soft_heap_limit64`, `shrink_memory`.
18. Settings that only matter for a page-based file: `auto_vacuum`,
    `journal_size_limit`, `wal_autocheckpoint`, `wal_checkpoint` — accepted as
    neutrals today, and honest only once #21 gives the engine pages.

### File format and export
20. Write secondary indexes and `sqlite_sequence` (today the export writes the
    table b-trees and the declared indexes are lost in the file).
21. Replay `-wal` and rollback journals on import.
22. Reuse free pages on export (today it emits a freelist trunk).
23. `WITHOUT ROWID` and `STRICT` as write targets.

### Tooling
24. SQLite shell commands: `.mode`, `.headers`, `.output`, `.dump`, `.import`,
    `.read`, `.timer`.
25. `sqlite3_backup_*` equivalent (`store_snapshot` covers the use case) and
    `VACUUM INTO`.
26. `sqlite3_blob_*` incremental I/O.

## 3. Incompatible or out of scope

| Area | Why it cannot be 1:1 | Reasonable substitute |
|---|---|---|
| Drop-in `sqlite3_*` C ABI | Different engine, different API (ours is `miraidb_*`) | Thin shim mapping names; not a goal |
| Dynamic typing | The engine is statically typed; SQLite stores any storage class in any column | Affinity on import/export plus `BLOB`/`TEXT` casts |
| `load_extension`, C UDFs | Native plugins would break the single-binary, sandboxed design | SQL functions and module ABI |
| VFS, encryption (SEE), `sqlite3_config`, allocator backends | The engine owns its I/O and memory | None needed |
| WAL as our journal mode | Our durability is the commit log | Read and replay WAL, never use it |
| `ATTACH`/`DETACH` multi-database | One store per file | Read-only import; separate connections |
| FTS5 / R*Tree virtual tables | Extension modules with their own file shadow tables | Native full-text index (extension) |
| `PRAGMA writable_schema`, `legacy_file_format`, shared cache | Would expose internals or dead features | Rejected by design |
| `SHARED`/`THREADING` modes, `sqlite3_*_mutex` | One writer, many readers is the model | Documented in the architecture |
| Byte-identical file output | Packing choices (freelist, overflow splits) differ | Any reader accepts our files |
| Shell scripting surface (`.shell`, `.system`) | No shell execution by design | None |

## 4. Porting the "incompatible" list to Odin

"Incompatible" above means *not a like-for-like trait of the current engine*,
not impossible. Each item has a native Odin design; the cost and the invariant it
touches differ.

| Item | Odin design | Cost | Invariant touched |
|---|---|---|---|
| **Dynamic typing** | A column type `.Any`: `Value` already has exactly SQLite's five storage classes (null, int, real, text, blob), so `.Any` skips coercion and stores the class it received. Add SQLite's affinity rules as a function used on INSERT and on comparison. | M | Static typing becomes opt-in per column; typed columns keep their guarantees |
| **`sqlite3_*` C ABI** | A `src/sqlite_compat` package exporting `sqlite3_open`, `prepare_v2`, `bind_*`, `step`, `column_*`, `finalize`, `errmsg`, `changes`, `sqlite3_exec` over `embed_*`, with SQLite's return codes. | M | None: a second facade over the same engine |
| **VFS** | A `Vfs` struct of function pointers (open, read, write, truncate, sync, lock) with the default over `core:os`, an in-memory one and a quota one. | S–M | None, as long as the log uses it |
| **WAL as a mode** | Reuse the commit log as the WAL: a compatibility writer appends frames to `<db>-wal` and checkpoints into the SQLite file. Reading a foreign WAL is parser work only. | L | The durability story changes only in SQLite mode |
| **`ATTACH`/`DETACH`** | A catalog of stores: the session holds `main` plus attached paths; name resolution prefixes the store. | M | One store per file becomes one store per attachment |
| **FTS5 / R*Tree** | Native features instead of loadable modules: a tokenizer plus an inverted index table (FTS) and a bounding-box index (R-Tree) over the existing index layer. | L / M | None; they become SQL surface |
| **`load_extension`, C UDFs** | `core:dynlib` loading Odin-built shared libraries that implement the existing module ABI v2 (`init_v2`/`call_v2`). | M | Sandbox becomes opt-in; still in-process |
| **Byte-identical export** | Mirror SQLite's packing (cell order, freelist reuse, overflow split thresholds, sequence table) and diff against `sqlite3` output in CI. | M | None; only matters for byte-level tests |
| **`writable_schema`, `legacy_file_format`** | Accept and ignore, or expose the catalog as a writable table behind a flag. | S | Schema validation is bypassed while enabled |
| **Threading modes** | Accept `serialized`/`multi-thread` as configuration; the store already serialises writers. | S | None |
| **Full SQLite storage engine** | Pager + page cache + b-tree + WAL behind the same `Store` interface, so a database can be backed by SQLite pages instead of the log. The reader/writer already map the format. | XL | The commit log stops being the only storage backend |

Priority if this list is pursued: **`sqlite3_*` shim** (unlocks third-party
clients and the course testers), then **`.Any` + affinity** (makes imported files
faithful), then **FTS/R\*Tree**, then **VFS**, and only afterwards the storage
backend and WAL mode.
