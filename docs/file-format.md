# File format

A persistent miraidb database is a directory:

```text
<database>/
├── log          the first log segment, append-only
├── log.1, ...   later segments, same layout
├── log.index    seq -> offset sidecar for its segment (derived)
└── snapshot     optional full-state copy (written by compact/snapshot)
```

The log is the database. There is no separate data file: opening a database
replays every valid record in order and rebuilds the tables. A future milestone
adds snapshots (`M2`), which will be an optimization for startup time, not a
second source of truth.

All integers are little-endian. CRC32C is the Castagnoli polynomial
(`0x82f63b78`, reflected).

## Header

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `MIRADB01` |
| 8 | 4 | format version (currently `15`) |
| 12 | 4 | reserved, zero |
| 16 | 8 | `base_seq`: last sequence folded into a snapshot |

`base_seq` is zero for a log that was never compacted. Replay expects its first
record to have sequence `base_seq + 1`, so a compaction keeps the commit numbers
of the transactions that survive it.

A file with a different magic is not a miraidb log. A file with a higher version
than the build understands is rejected instead of being guessed at.

## Records

Every record is:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | payload length in bytes |
| 4 | 4 | CRC32C of the payload |
| 8 | 8 | commit sequence, starting at 1, strictly increasing |
| 16 | N | payload |

A record is accepted only when the payload fits in the file, its checksum
matches and its sequence is exactly one more than the previous accepted record.
Replay stops at the first record that fails any of those checks. The valid
length is then the end of the last accepted record; the file is truncated there
so the next append starts on a clean boundary.

Recording the sequence in the log makes reordering and accidental duplication
detectable at replay time.

## Payload

The payload is one committed transaction:

```text
u32  operation count
op*  operations, in apply order
```

Each operation starts with a `u8` kind and a length-prefixed table name
(`u32` length, bytes):

| Kind | Name | Fields |
|---|---|---|
| 1 | `Create_Table` | serialized schema |
| 2 | `Insert` | `u64` row id, `u32` value count, values |
| 3 | `Update` | `u64` row id, `u32` value count, values |
| 4 | `Delete` | `u64` row id |
| 5 | `Truncate` | — |
| 6 | `Drop_Table` | — |
| 7 | `Create_Index` | serialized index definition |
| 8 | `Drop_Index` | `string` index name |
| 9 | `Alter_Table` | serialized schema (the full new schema) |

### Schema encoding

```text
string  table name
u8      table flags (bit 0 ephemeral, bit 1 event)
u32     column count
column*:
    string  name
    u8      type kind (0 Bool, 1 Int, 2 Uint, 3 Float, 4 String,
                       5 Bytes, 6 Timestamp, 7 Uuid)
    u8      width (1/2/4/8/16 for Int and Uint, 4/8 for Float, 0 otherwise)
    u8      flags (2 unique, 4 not null, 8 autoincrement, 16 has default;
                   bit 1 is reserved)
    value*  default value, only when the flag is set
    i64*    sequence start/increment/min/max, only for autoincrement
u32     primary key column count
u32*    primary key column positions, in key order
u32     index count
index*:
    string  index name
    u8      flags (1 unique, 2 implicit)
    u32     column count
    u32*    column positions
```

`implicit` marks the indexes generated from the primary key and from `UNIQUE`
columns; they cannot be dropped with `DROP INDEX`. The same index encoding is
the payload of a `Create_Index` record.

Indexes carry the implicit ones generated for the primary key and `UNIQUE`
columns, so replay does not have to regenerate names.

### Value encoding

Every value starts with its kind byte and then a fixed or length-prefixed body:

| Kind | Body |
|---|---|
| 0 Null | — |
| 1 Default | — (never stored) |
| 2 Bool | `u8` |
| 3 Int | `i64` |
| 4 Uint | `u64` |
| 5 Float | `f64` bits |
| 6 String | `u32` length + bytes |
| 7 Bytes | `u32` length + bytes |
| 8 Timestamp | `i64` microseconds |
| 9 Uuid | 16 bytes |
| 10 Array | `u32` count + values |
| 11 Product | `u32` count + values |
| 12 Int128 | two `u64`, low then high |
| 13 Uint128 | two `u64`, low then high |
| 14 Duration | `i64` microseconds |
| 15 Identity | 32 bytes |
| 16 Connection | `u64` |

## Order-preserving key encoding

Index keys use a different encoding, designed so that byte-wise comparison of
two keys equals comparing the values:

| Kind | Body |
|---|---|
| Null/Default | `0x00` |
| Bool | `0x01`, `0x00`/`0x01` |
| Int | `0x02`, big-endian `u64(i) xor 2^63` |
| Uint | `0x03`, big-endian `u64` |
| Float | `0x04`, order-mapped IEEE bits, big-endian |
| Timestamp | `0x05`, same as Int |
| Uuid | `0x06`, 16 bytes |
| String | `0x07`, escaped bytes, `0x00 0x00` terminator |
| Bytes | `0x08`, escaped bytes, `0x00 0x00` terminator |
| Array | `0x09`, `u32` count, elements |
| Product | `0x0a`, `u32` count, elements |
| Int128 | `0x0b`, 16 bytes big-endian, sign bit flipped |
| Uint128 | `0x0c`, 16 bytes big-endian |
| Duration | `0x0d`, big-endian `u64(i) xor 2^63` |
| Identity | `0x0e`, 32 bytes |
| Connection | `0x0f`, big-endian `u64` |

Escaping replaces each `0x00` byte with `0x00 0xff`; the terminator is
`0x00 0x00`. That keeps variable-length parts unambiguous while preserving
lexicographic order.

Floats are mapped: if the sign bit is set, invert all bits; otherwise set the
sign bit. This maps the IEEE ordering (including negative numbers) into unsigned
byte order.

## Segments

The log is split into segments of at most 256 KiB:

- segment 0 is `<database>/log`, later segments are `<database>/log.<n>`;
- each segment carries the normal 24-byte header, whose `base_seq` is the commit
  before its first record, so recording numbering is continuous across files;
- rotation happens before appending the record that would exceed the limit, so a
  record never spans two files;
- replay concatenates segments in order and skips whole files whose base is
  already covered by the snapshot; the offset index applies per segment;
- tail repair truncates only the last segment; compaction removes every segment
  and its sidecar and rewrites segment 0.

Databases created before segments keep working: their single `log` file *is*
segment 0.

## Schema versions

`LOG_VERSION` is 16. Fifteen added nothing at the byte level for a column; sixteen
adds two optional column bits (a declared collation and a generated expression
with its text), which are appended only when set, so a v15 store still opens and
reads with the v16 decoder.

## Snapshot

A snapshot is a standalone copy of the state at one commit sequence. It is
optional: the log alone always rebuilds the database.

```
header  40 bytes: "MIRASNP1" + u32 version + u32 reserved + u64 base_seq
                  + u64 payload_len + u32 payload_crc32c + u32 reserved
payload         : the op list a compacted log record holds
```

- `base_seq` is the commit sequence the state reflects.
- The payload uses the commit log encoding and the same format version.
- Startup applies the snapshot, sets `commit_seq = base_seq`, then replays only
  the records with a higher sequence.
- The file is written to `snapshot.tmp`, synced and renamed, so a crash leaves
  either the old snapshot or the new one.
- Compaction publishes the snapshot before replacing the log: if the log swap
  fails, the old log still holds every record and replay ignores the extra
  snapshot.
- After a successful swap the standalone file is **removed**: the rewritten log
  starts with the same payload, so the database is one artifact again instead of
  two. `SNAPSHOT` (the CLI `snapshot` command) is what keeps a standalone copy
  next to a live log.

## Compaction

`store_compact` writes a new log with a fresh header whose `base_seq` is
`commit_seq - 1` and one record at `commit_seq` holding the whole state:
`Create_Table` followed by every row of every table. It syncs the new file,
renames it over `log`, and reopens it.

- The next commit gets `commit_seq + 1`, so the sequence is continuous.
- Compaction writes a snapshot at the current sequence and then rewrites the log.
- Compaction is a rewrite of the state, not a new format: the payload uses the
  same operations as any other commit.
- If writing the snapshot fails, the old log is reopened untouched.

## Page file

The page file is the on-disk materialisation the page store uses: fixed 4 KiB
pages, a slotted layout for variable-length rows, a free list and a checksum per
page. It is a **cache over the log**, not a second source of truth: a page file
that does not match the log is discarded and rebuilt by replay.

```
page 0   header page (same slot layout, plus the file-wide fields)
page n   rows page: 32-byte header, cells from byte 32 upward,
         slots of {u16 offset, u16 length} from the end downward
```

Header fields (little-endian): `kind u8` (0 free, 1 rows), `slots u16`,
`slot_start u16`, `free_start u16`, `dead u16`, `row_count u16`,
`next_free u32`, `crc u32` at byte 16, reserved to byte 32. The checksum covers
the whole page with the checksum field zeroed, so a reader verifies a page
without trusting its header.

Page 0 adds, from byte 20: `magic` "MRPG", `version` 1, `page_size` 4096,
`page_count`, `free_head`, `free_pages` and `applied_seq`.

- A cell is `u64 row_id | u32 value_count | value...` using the same value
  encoding as the wire and the log.
- A slot whose length is zero is a deleted cell. Compaction closes the holes and
  **keeps the slot numbers**, because the row directory addresses rows by slot;
  an insert reuses a freed slot, so the slot array stays bounded by the rows a
  page ever held at once.
- The free list links free pages through their own `next_free`, and the head
  lives in page 0, so it survives a crash.
- **Flush order**: every dirty page is written and synced first, then page 0
  with the new `applied_seq`. A header that names a sequence is a promise that
  every page of that sequence is on disk; the fault-injection test breaks each
  write of a flush and checks the promise.
- Rows are read through a buffer pool: one frame per page, a clock hand, pins,
  and write-back on eviction. Frame 0 is reserved for the header page and is
  never used for rows; the pool is `page_frames` data frames plus that one.
  `page_rows_each` streams page by page, so a table larger than the pool is read
  without holding it.
- **The directory lives in the same file.** Page 0 also carries the root of a
  B+tree, `height` and `entries` at bytes 52, 56 and 60 and the "MRPI" magic at
  68, mapping `Row_Id` (8 bytes, big-endian) to `u64(page) << 16 | slot`. Opening
  a file that names a root reads that root and trusts it (`opened_from_directory`),
  so a table larger than memory opens in constant memory; a file without the
  marker is walked once and the directory written back. Every insert, move and
  delete updates the tree, and `page_rows_flush` syncs its root into page 0 before
  the flush writes the data pages and then page 0, so a header never names a page
  that is not on disk. The store still discards and rebuilds the file on open:
  trusting it is D18b.

**A table on disk.** A store opened with `paged_tables` creates
`<db>/tables/<table>` (non-alphanumeric bytes in the name are `%XX`). The commits
that touch it are applied to the pages, and a commit flushes them after the log
record is durable; a failed page flush is recorded, not reported as a failed
commit, because the log already holds it. On open the `tables` directory is
discarded and rebuilt by the replay, so the log is always the authority. The
`ALTER` and `AS OF` paths refuse a paged table: the first would need to rewrite
rows through a map that is not there, the second needs the versions the page
keeps only one of.

Tests: `test_page_store_roundtrip`, `test_page_store_streams_within_the_pool`,
`test_page_store_header_is_a_promise`, `test_paged_table_roundtrip` (a reopen
with a different pool size), `test_paged_table_churn` (compaction under churn).

## Index file

An index of a paged table is a B+tree of the same 4 KiB pages in
`<db>/indexes/<table>/<index>`. Keys are the order-preserving encoding the
in-memory tree used, so a comparison on the bytes is a comparison on the values.

```
page 0   header page: kind 2, plus magic "MRPI", version 1, root, height, entries
leaf     kind 3: cells {u16 key_len | key | u64 row id} in key order,
         next leaf in the page header's next_free  (0xFFFFFFFF = last)
branch   kind 4: cells {u16 key_len | key | u32 child} in key order,
         leftmost child in next_free
```

- Routing: child *i* holds the keys in `[separator i, separator i+1)`; the
  leftmost child holds everything below `separator 0`. So a descent is a binary
  search per level, and the height is the number of pages it reads.
- Leaves are chained in order, so a range scan or a prefix lookup is a single
  walk with a cursor that carries only `{page, slot, count}`; the key is copied
  out before the page is released, because the pool may evict it.
- A full page is split at the cell nearest half a page; the first key of the new
  right page is promoted to the parent, and a split at the root adds a level.
  A delete removes the cell and leaves an empty leaf in place: the cursor walks
  past it, which keeps lookups correct; merging is future work, so an index that
  loses most of its keys keeps its leaves until it is rebuilt.
- Index page 0 carries `root`, `height` and `entries` at bytes 52, 56 and 60 and
  the "MRPI" magic at 68; the row-file fields (`page_count`, `free_head`,
  `free_pages`, `applied_seq`) are shared.
- A key is limited to 1000 bytes so a cell always fits a page; a longer key is
  refused at insert with the limit in the message, instead of writing a cell the
  page cannot hold.
- The file is flushed after the log record, page 0 last, exactly like a table
  file, and it is discarded and rebuilt on open for the same reason.

Tests: `test_ordered_index_pages` (5000 keys over a 4-frame pool, a third of them
deleted, then closed, reopened and cleared),
`test_ordered_index_rejects_a_key_that_cannot_fit`, and
`test_paged_index_pages` (a paged table with two indexes: lookups, ranges,
constraints, an update that moves a key, `TRUNCATE`, a reopen and a `CREATE
INDEX` after it).

## Durability

`store_open(..., durable = true)` opens the log and calls `fsync` after writing
each record, before the in-memory state is updated. The replay walks the records
one at a time through a buffer that only grows to the largest commit, so opening a
database costs one record, not its history; it stops at the first record whose
CRC or sequence does not verify and truncates the torn tail before the next
append. With `durable = false` the
data reaches the OS but not necessarily the disk.

On a crash, the worst case is a torn record at the tail; replay ignores it and
truncates it away. A checksum failure in the middle of the log also ends replay
there, because the sequence check would reject everything after a gap anyway.

## Compatibility policy

- Unknown record kinds or column types are rejected, not skipped.
- Version 15 adds the foreign keys of a table to the schema encoding: name, both
  actions, referenced table and the two column lists.
- Version 14 stores a `PRODUCT` column as a component list: a count byte then
  one (kind, width) pair per component. A version 13 file with a product column
  is rejected by the strict check; earlier versions cannot contain one.
- Version 13 adds the catalog name of a named column type: flag bit 5 in the
  column flags byte marks it and the name follows the flags.
- Version 12 adds the index algorithm byte (`0` btree, `1` hash, `2` direct) to
  the index encoding, in schemas and in `Create_Index` records.
- Version 11 extends the encoded column type with the components of structural
  types: `OPTION(T)` writes its payload kind and width after the base pair, and
  `RESULT(T, E)` also writes the error kind and width; `ARRAY(T)` writes the
  payload and `PRODUCT(T1, T2)` writes both components. Other kinds are encoded
  exactly as before.
- Version 10 adds a table-flags byte to the schema encoding for ephemeral and
  event tables (a version 9 file has no such byte, hence the strict check).
- Version 9 gives the formerly reserved header field a meaning: the checksum
  id. `1` means records carry no digest, `2` means CRC32C (the default). A
  version 8 file has zeros there and is rejected by the strict version check.
- Version 8 adds the `Alter_Table` operation; a version 7 file still opens and
  a version 8 file with no alter is readable by a 7 build only if it never
  wrote that op, so the strict check stays.
- The format version is bumped whenever the meaning of an existing field
  changes. Adding a new record kind behind a version bump is preferred over
  reusing a field.
- A database written by a newer version is refused with `Format_Too_New`.
