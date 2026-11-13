# Architecture

This document describes the engine as implemented in `src/engine`. It is the
normative description of the invariants; the code follows it.

## Modules

| File | Responsibility |
|---|---|
| `value.odin` | The dynamic `Value` type, comparisons, ordering, hashing, formatting |
| `schema.odin` | Column types, table schemas, schema validation and serialization |
| `table.odin` | Row storage, equality indexes, uniqueness checks |
| `encoding.odin` | Little-endian readers/writers, value codec, order-preserving key codec, CRC32C |
| `commitlog.odin` | Log file, records, append, read, truncate |
| `store.odin` | Table registry, operation encoding, apply and replay |
| `tx.odin` | Transactions: staging, read-your-writes, commit and rollback |
| `sql_lexer.odin`, `sql_ast.odin`, `sql_parser.odin` | SQL front end |
| `sql_exec.odin` | Statement execution: SELECT planning, DML, DDL |
| `host.odin` | Reducers and subscriptions |

## Data model

A table is a `Table_Schema` plus:

- `rows: map[Row_Id]Row`, where a `Row` is an ordered `[]Value` matching the
  schema columns.
- One `Index` per index in the schema, keyed by the order-preserving encoding. A
  unique index stores the key alone; a non-unique index appends the row id, so
  every entry is distinct and iteration is ordered. The keys live in a red-black
  tree, or — for a paged table — in a B+tree of 4 KiB pages (`index_page.odin`,
  one file per index with its own pool), where leaves are chained in key order
  and a range scan is a cursor over that chain.
- `next_row_id`, the id the next inserted row receives.

The primary key and every `UNIQUE` column get an implicit unique index during
schema normalization, so constraint checking has exactly one code path.

Rows and index buckets are heap allocated and freed when a row is deleted. The
schema and the *stored* index keys of an in-memory table live in a per-table arena
that is released when the table is dropped; a paged table keeps the keys in the
index files instead.

## Values and types

`Value` is a tagged struct with a `Value_Kind`:
`Null`, `Default`, `Bool`, `Int` (i64), `Uint` (u64), `Float` (f64), `String`,
`Bytes`, `Timestamp` (microseconds), `Uuid` (16 bytes), `Array`, `Product`.

The tag is followed by a 16-byte raw union payload, so a value is 24 bytes
whatever it holds (`docs/value-layout.md`). Every payload field shares those
bytes; the tag says which one is meaningful. Int128/Uint128 are stored as two
words and read with `value_big`; the 32-byte `Identity` is interned and read with
`value_identity_of`.

`Default` never reaches storage: it marks a column an `INSERT` did not supply, so
the engine can tell it apart from an explicit `NULL` (which violates `NOT NULL`).

Numeric values compare across kinds; `1` (int), `1` (uint) and `1.0` (float) are
equal. Strings compare byte-wise.

### Who frees a value

Odin has no destructors, so every buffer has exactly one owner and the rule is
written down where the memory is made:

- A **table** owns the values of its rows: `table_insert` clones them with the
  context allocator (`clone_values`), and `table_destroy` frees them. A **read
  snapshot** borrows them instead (`Table.borrowed`): it frees none, and the
  source defers freeing while a snapshot shares its `Row_Store`.
- A **transaction** owns everything made with `tx.alloc`: staged row values, the
  sources and column lists of a query, and what `tx_collect` returns. Freeing
  one of those with the context allocator is a bug the tracking allocator catches
  (`bad free`), and the arena frees it at `tx_end` anyway. A slice allocated with
  an explicit allocator is freed with that allocator:
  `delete(star, tx.alloc)`, `delete(column, tx.alloc)`. A `[dynamic]T` remembers
  its own allocator, so `delete(columns)` is enough.
- A **statement result** (`Sql_Result`) owns its rows, columns and message;
  `sql_result_destroy` frees them with the context allocator, so an engine path
  that builds a result must hand it context-allocated strings (that is what
  `pragma_text` does with its clone).
- **Interning** outlives every caller: the identity table and other process-wide
  maps grow on `runtime.heap_allocator()`, because a per-test or per-request
  allocator would free them underneath the process.

## Encoding

Two codecs:

- **Value codec** (`value_encode` / `value_decode`): self-describing, used for
  commit records. Every value starts with its kind byte.
- **Key codec** (`value_encode_key`): order preserving. Signed integers flip the
  sign bit, floats map their IEEE bits into an unsigned order, and strings and
  blobs escape `0x00` as `0x00 0xff` and terminate with `0x00 0x00`. Comparing
  the encoded bytes equals comparing the values.

Index keys are the concatenation of the key encoding of each indexed column.
Equality uses a lower-bound search plus a prefix walk; a range predicate scans
from the lower bound while the end bound holds, ignoring the row-id suffix of a
non-unique entry.

## Transactions

`Tx` has two modes:

- `tx_begin_write` takes the store's write lock and stages writes.
- `tx_begin_read` takes the read lock and rejects writes.

Staged writes live in `Tx_State`:

```text
writes[table] = {
    inserts:     Row_Id -> Row
    updates:     Row_Id -> []Value
    deletes:     Row_Id -> bool
    truncated:   bool
    unique_keys: encoded key -> Row_Id
    next_row_id: u64
}
created[table] = ^Table      // schema created in this transaction
dropped[table] = bool
```

Reads inside the transaction (`tx_get`, `tx_collect`) merge the committed table
with the staged writes, so a reducer sees its own changes. `tx_collect` produces
rows ordered by `Row_Id`, which keeps unsorted output deterministic.

### Commit protocol

1. Compute the new commit sequence (`commit_seq + 1`).
2. Build the operation list in a deterministic order: create tables, then per
   table (truncate, deletes sorted by id, updates sorted by id, inserts sorted by
   id), then drops.
3. Encode the operations into one payload.
4. Append one log record and, if durable, `fsync`.
5. Apply the operations to the committed state, in order.
6. Set `commit_seq`.
7. Release the lock and run the commit hook (subscriptions).

If step 5 fails, the log is rewound to the size it had before step 4, so a
transaction is never half-present in the log. Staged values live in a
transaction arena that is destroyed after the apply, which makes ownership
simple: the log and the tables always receive copies.

### Rollback

`tx_rollback` destroys created tables, frees staged maps, destroys the arena and
releases the lock. Nothing reached the committed state.

### Index DDL

`CREATE INDEX` and `DROP INDEX` are staged as their own operations
(`Create_Index`, `Drop_Index`). They run in a transaction that touches no rows:
mixing them with row writes would make the staged uniqueness check disagree with
what the apply step builds. `table_add_index` populates the tree from the
existing rows; `table_drop_index` refuses implicit indexes (the primary key and
`UNIQUE` columns).

## Snapshots

`store_snapshot` writes `<database>/snapshot`, a full-state copy at the current
commit sequence. Opening a database applies the snapshot first and replays only
the records after it, so startup is O(state + recent commits) instead of
O(history). The snapshot is optional and atomically replaced; the log remains
the source of truth.

`store_table_memory` (and `miraidb inspect`) reports per-table rows, row bytes,
index entries and index bytes for diagnostics.

### Read snapshots

A read transaction does not hold the store lock while it runs. At begin it builds
one snapshot of the tables (`table_snapshot`): the row map is copied (presized),
the values are borrowed through a reference-counted `Row_Store`, and every index
tree is copied **shape for shape** — node and key, no comparisons and no
rebalancing — so a snapshot costs one copy per entry instead of a lookup, an
encoding and an insert. The snapshot is published as the store's read cache keyed
by commit sequence, so the next read at that sequence borrows it in O(1). Each
transaction holds a reference; a cache that a new commit replaced is freed as
soon as no transaction holds it, so the cache keeps publishing instead of going
dark after a fixed number of commits. A writer never waits for a reader: it keeps
mutating its own tables, and the snapshot's rows, tree nodes and keys are its
own — the test drops the source table under an open snapshot.

## Compaction

`store_compact` first writes the snapshot, then rewrites the log as one record
holding `Create_Table` plus every row, with `base_seq = commit_seq - 1` in the
header. Startup loads the snapshot, skips that record (its sequence is already
covered) and the next commit is `commit_seq + 1`. If the log is ever replaced
without the snapshot, the record alone still rebuilds the state.

## Views

A view definition is a row in the internal `_view (name TEXT PRIMARY KEY, sql
TEXT NOT NULL)` table, so creating one is an ordinary transaction and the commit
log, snapshots and replay need no new record type. `CREATE VIEW` parses the body
once to validate it and stores the SQL text.

Reading a view materializes it: `tx_source_table` falls back to `_view` when a
`FROM`/`JOIN` name is not a table, runs the stored SELECT in the same
transaction, infers one static column type per output column from the result
rows and fills a temporary table owned by the transaction. That table then goes
through the normal source, filter, join and aggregation paths. The transaction
keeps a small stack of view names to reject recursion and caps nesting at eight
levels.

## Row-level security

Policies are rows in `_policy (name, table_name, using_sql, check_sql)`, so they
are committed, replayed and snapshotted like any other data. Enforcement parses
each predicate once per statement as `SELECT 1 FROM <table> WHERE (<predicate>)`
and evaluates the resulting expression against the bound row with the normal
evaluator. That makes `current_identity()` and every scalar function available
inside a policy.

- Reads: after the joins, before `WHERE` and before projection/aggregation, a
  partial is dropped unless every policy of every referenced table allows it.
- `UPDATE`/`DELETE`: the `USING` predicate skips rows the caller cannot see;
  `UPDATE` also runs `CHECK` against the new row.
- `INSERT`: the row is staged first (so `CHECK` sees coerced values) and the
  statement fails with `permission_denied` if the predicate rejects it.
- Subscriptions evaluate their SQL with `sql_exec_select`, so they inherit the
  same filtering.

The caller lives on the store (`store_set_identity`); a server would set it per
connection. Policies on internal tables (names starting with `_`) are ignored.

## Uniqueness

At staging time `tx_check_unique` consults:

1. `unique_keys`, the keys staged by this transaction;
2. the committed table's index buckets, skipping rows deleted or updated in this
   transaction.

Rows updated in the transaction have their old keys removed from `unique_keys`
before the new keys are checked, so an update that keeps its key is allowed.

## Commit log

See [file-format.md](file-format.md).

## SQL

The parser is hand written and strict. See [sql.md](sql.md).

Execution always goes through a transaction:

- `sql_execute` opens a read transaction for `SELECT` and a write transaction
  for everything else, committing on success.
- `sql_execute_in_tx` runs inside the caller's transaction (reducers).

A query binds sources: `Source` pairs a table with one of its rows and an
optional alias. Single-table statements build a one-source context; a join
builds one source per table. Column resolution searches the bound sources
(qualified names match a table name or alias; unqualified names must be
unique).

Joins expand a list of partial bindings, one nested loop per joined table.
`LEFT JOIN` keeps a partial with a NULL row when nothing matches. `WHERE`
filters bindings, then the query either projects each binding or groups
bindings and evaluates aggregates over the group.

Equality and range predicates on the *base* table narrow its scan through an
index; predicates on joined tables are applied by the nested loop, and the whole
`WHERE` is always re-checked. `ORDER BY` sorts the projected rows using byte
keys built from the order expressions (with descending parts inverted), so the
sorter needs no access to the clause.

## Reducers

A reducer is `proc(ctx: ^Reducer_Ctx, args: []Value) -> Error`. `host_call`
coerces the arguments to the declared parameter types, opens a write
transaction, runs the handler, and commits (or rolls back on error).

Reducers are registered by name at startup; there is no dynamic loading and no
embedded interpreter. A future milestone adds a module ABI, but the default
remains statically linked Odin code.

## Scheduler

Schedules are rows in the `_schedule` table (created lazily):
`(id, reducer, at_us, interval_us, args)`, with the arguments encoded as one
product value. Three helpers write it:

- `host_schedule(host, reducer, at_us, args)`: one shot at a fixed time;
- `host_schedule_now(...)`: one shot at the current host time (next tick);
- `host_schedule_every(host, reducer, interval_us, args)`: repeats, first run
  one interval from now.

`host_tick(host, now)` selects the due rows, earliest first, and for each:

1. opens a write transaction and either deletes the row (one shot) or moves
   `at_us` to the next occurrence (interval);
2. decodes the arguments and calls the reducer handler;
3. commits, or rolls back and repeats step 1 in its own transaction.

`next_schedule_time` advances by whole intervals until the time is past `now`, so
a delayed tick runs once instead of bursting every missed occurrence. A failing
reducer loses its one-shot row but keeps its repeating row (it skips the
occurrence), so a broken call cannot wedge the queue. The table is ordinary
data: it is logged, replicated by the same replay path, and can be inspected
with SQL. A `_schedule` created by an older build (without `interval_us`) is
recreated on first use; pending rows from before the upgrade are discarded.

## Subscriptions

A subscription owns a parsed `SELECT` (its own query arena) and the last result
set, keyed by the encoded projection values. It remembers every table in the
query, so a commit to a joined table also refreshes it.

After each commit, the store calls the host's commit hook with the names of the
changed tables. Every subscription whose table changed is re-evaluated against a
fresh read transaction; rows that appeared become inserts, rows that disappeared
become deletes, and rows that changed appear as a delete plus an insert. The
update is delivered after the lock is released, so a subscriber may query the
database from the callback.

This is a correct-but-simple model: evaluation cost is proportional to the
subscription's result size, not to the delta.

Two shapes avoid the re-evaluation:

- **One table.** The commit hook projects the stored row through the WHERE and
  the projection and moves exactly that row in the cache.
- **Joins.** A join subscription keeps a tuple index: one entry per combination
  of source rows that contributes to the cached set, keyed by the source row ids
  (the source index is part of the key, because row ids are only unique inside
  their table), plus the tuples each row takes part in and how many tuples
  project to the same output row. A commit removes the tuples of the row that
  changed and re-walks only that row against the other sources, so the cost is
  proportional to the affected combinations. The keys live in an arena owned by
  the subscription; the index is rebuilt after any fallback (DDL, policies,
  grouping, ordering) and at subscribe time.

- **Grouped aggregates.** A grouped subscription keeps a group table: for each
  group, the base rows that feed it and the row it last published. A commit
  looks up the group of the row that changed (through a row-to-group map, so a
  delete needs no old values), moves the row, and recomputes only the groups it
  touched, publishing the row as a delete plus an insert when it differs and
  dropping the group when its last row goes. Without `GROUP BY` the single
  group is recomputed from a scan.

`DISTINCT`, `ORDER BY`, `LIMIT` and policies still take the full evaluation and
diff. Their deltas are correct; making them incremental is a refinement
(`docs/pending.md`, #30).

## Diagnostics

- `store_integrity_check` verifies the invariants a commit must keep (row width
  against the schema, every index answering with the row that feeds it, unique
  keys not repeating, foreign keys resolving) on a read snapshot, and
  `store_foreign_key_check` lists orphans. `PRAGMA integrity_check` and
  `PRAGMA foreign_key_check` expose them.
- The store keeps latency histograms for commits and queries: 20 doubling
  buckets from one microsecond up, incremented with atomics because a query
  releases the store lock before it reports. `PRAGMA stats` prints them.
- A silent abort (exit code 5, no output) is usually a use-after-free: build
  the CLI with `odin build src/cli -debug -sanitize:address` and run the failing
  statement. The sanitizer names the frame and the line; the tracking allocator
  cannot, because it leaves freed bytes intact. A double free exits 116, a
  bounds panic 140 with a message, and `panic()` 29.
- `scripts/fuzz.py` feeds seeded random SQL to the CLI: half of it valid, half
  deliberately broken. The engine may reject anything, but it must survive and
  `PRAGMA integrity_check` must stay `ok`; it found four memory bugs in the
  executor and one dangling result field. `scripts/soak.py` keeps writing,
  reading, compacting and reopening for a while and checks the same invariants.

## Transport caps and background compaction

- One connection may send at most `Host.max_request_bytes` (default 1 MiB), a
  header block of `max_header_bytes` (16 KiB) and a WebSocket frame of
  `max_frame_bytes` (1 MiB); `host_set_request_limits` and
  `host_set_frame_limit` change them. A body over the cap is a `413` before the
  payload is buffered, and a frame is refused before it is allocated, so a
  forged 64-bit length cannot ask for gigabytes or wrap negative.
- `Store_Options.compact_after_bytes` starts a worker thread that calls
  `store_background_compact_step`: it rewrites the log as one snapshot record
  when the log passes the threshold, taking the same write lock compaction always
  takes (writers pause, they do not fail). The worker sets `context.allocator` to
  the store's allocator, so a custom allocator handed to such a store must be
  safe to use from another thread. `compact_floor` waits for the log to double
  after a rewrite, because a snapshot of a wide database can be larger than the
  threshold; `store.compact_count` tells a test (or a monitor) that a rewrite
  happened. `store_close` stops and joins the worker before touching the log.

## Concurrency

- One writer at a time; readers run concurrently with each other and are blocked
  only while a writer commits.
- A read transaction holds the read lock for its lifetime. Long analytical
  queries therefore delay writers. Snapshot isolation without blocking writers
  arrives with the persistent data structures in M2.

## Determinism

The engine never reads the clock while encoding state or applying operations.
`now()` in SQL and `Reducer_Ctx.now_us` read the host clock, which tests can
override. Replaying the same log always produces the same state.

## Virtual file system

The commit log never touches `core:os` directly. Every read, append, rewind,
rotate, flush and truncate goes through `Vfs` (`src/engine/vfs.odin`), which has
three backends:

| Backend | Use |
|---|---|
| OS | the default: real files under `<database>/log` |
| Memory | a database that lives entirely in RAM, log and replay included |
| Quota | a wrapper that refuses a write past a byte budget |

`Store_Options.vfs` selects one. A virtual file system has no directories, so
the path names the log file directly, and the offset index (`.index`) is an
OS-only cache — a virtual log replays by scanning, which is what it does anyway.
Snapshots, compaction and `VACUUM INTO` need real files and refuse a virtual
one with `sql_unsupported`.

The same seam is what a page backend and an encrypted store plug into later.

## Commit queue

Prepared transactions can wait in a `Commit_Queue` before group commit
(`src/engine/commit_queue.odin`):

```odin
commit_queue_push(&queue, prepared, .High)
written, err := store_commit_queue(store, &queue, 64)
```

Higher priority is served first and arrival order breaks ties. An entry that
survives `COMMIT_QUEUE_AGING` (16) drains competes at the highest priority, so a
steady stream of urgent work cannot starve background writes: the wait of any
entry is bounded, and `commit_queue_stats` reports how many were promoted.
Draining a batch hands it to `store_commit_prepared`, which appends every record
and syncs the log once, so a batch costs one fsync instead of one per commit.
