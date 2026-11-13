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
- A reader beside the writer: `--read-only` opens a database another process is
  writing, answers from the log it replays into memory, refuses every write and
  keeps compaction waiting. The lock has two roles now, so readers join and a
  second writer is still refused.
- Indexes on disk: each index of a paged table is a B+tree of 4 KiB pages with
  its own pool, leaves chained in key order, and a cursor that walks a range
  without a parent stack. The keys stop living in RAM, and `page_rss.py` checks
  the index file grows with the rows while the statement cost does not.
