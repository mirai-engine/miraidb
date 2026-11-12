# Changes

## 0.15

- The first packaged release: the engine, the CLI, the server, the shared
  library with its header, and the Python binding over the C ABI.
- Append-only commit log with CRC32C per record, snapshots, compaction and a
  segmented log; ACID transactions with one writer and many readers.
- SQL with joins, aggregates, window frames, policies, triggers, `AS OF`,
  full-text search with BM25 ranking, spatial tables and attached `.sqlite`
  reads.
- One owner per database directory (OS lock), and a broker that serves other
  processes over HTTP, WebSocket frames and Postgres.
- Tables on disk: a page file per table with a buffer pool, a free list, a
  fault-tested flush order, and a query pipeline that streams a single-table
  scan without holding the table in memory. Off by default; `--paged` turns it
  on.
