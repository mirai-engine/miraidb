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

## Durability

`store_open(..., durable = true)` opens the log and calls `fsync` after writing
each record, before the in-memory state is updated. With `durable = false` the
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
