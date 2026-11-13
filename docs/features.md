# Feature matrix

The record of the feature set this engine targets. Each row is one capability,
with its status in this tree and the evidence that closed it. IDs are stable.
The matrix is closed: 94 rows, all `done`, each with a test. [pending.md](pending.md)
records how each row was closed, [backlog.md](backlog.md) holds the depth work
that is deliberately not part of parity, and [roadmap.md](roadmap.md) orders
what is left.

- **done** — implemented and covered by tests.
- **partial** — implemented for a subset; the gap is described.
- **todo** — not started.

Effort: **S** small, **M** medium, **L** large.

## Progress

| Area | Done | Partial | Todo | Total |
|---|---:|---:|---:|---:|
| A. Data model and types | 10 | 0 | 0 | 10 |
| B. Schema and catalog | 16 | 0 | 0 | 16 |
| C. Datastore and transactions | 11 | 0 | 0 | 11 |
| D. Commit log and durability | 9 | 0 | 0 | 9 |
| E. Queries and SQL | 14 | 0 | 0 | 14 |
| F. Server and protocol | 14 | 0 | 0 | 14 |
| G. Modules and ABI | 10 | 0 | 0 | 10 |
| H. Tooling, SDK and operations | 10 | 0 | 0 | 10 |
| **Total (94)** | **94** | **0** | **0** | **94** |

**94 done (100 %)**: 0 partial, 0 todo, and every row is covered by a test.
Parity is interface-level by definition; where the implementation is shallower
than a mature engine, the gap is named with its cost in [backlog.md](backlog.md)
rather than hidden in this table.

## A. Data model and types

| ID | Feature | Status | Gap |
|---|---|---|---|
| A1 | 8/16/32-bit integers with range checks | done | `TINYINT`/`SMALLINT`/`INT4`, unsigned variants, range enforced on store |
| A2 | 128-bit integers | done | `INT128`/`UINT128`, arithmetic, aggregates, index keys |
| A3 | `F32` distinct from `F64` | done | `FLOAT4` rounds to single precision on store |
| A4 | `Unit`, `Option`, `Result` as types | done | `UNIT`, `OPTION(T)` and `RESULT(T, E)` parse, coerce (one Result side), reflect and replay |
| A5 | Arrays and products as column values | done | `ARRAY(T)` and `PRODUCT(T1, ..., Tn)` are column types: parser, element-wise coercion, codec, reflection |
| A6 | Named types and references | done | `CREATE TYPE name AS base`, resolved from `_type` when a table is created; `SHOW types` |
| A7 | Domains: identity, connection, timestamp, duration, uuid | done | `DURATION`, `IDENTITY`, `CONNECTION` added; timestamps and uuid already existed |
| A8 | Stable serialization with resolved references | done | a column keeps its catalog name next to the resolved type; both are encoded, replayed and exposed as `_columns.named` |
| A9 | Hash, order and equality for every type | done | `value_compare`, `value_equal` and `value_hash` tested for all 19 kinds, including numeric cross-kind equality |
| A10 | Type reflection for clients | done | `host_schema_text` and `GET /schema` render tables, columns and indexes |

## B. Schema and catalog

| ID | Feature | Status | Gap |
|---|---|---|---|
| B1 | Composite primary key | done | inline or `PRIMARY KEY (a, b)`; one unique index over the tuple |
| B2 | Named, multi-column unique constraints | done | `[CONSTRAINT name] UNIQUE (a, b)` creates a named index |
| B3 | Index algorithms: btree, hash, direct | done | btree by default; `USING HASH` for equality on any columns and `USING DIRECT` for a unique key that names one row |
| B4 | Independent sequences | done | per-column start/increment/min/max, independent of the row id |
| B5 | Views with parameters | done | positional `?` parameters bound by `FROM v(...)`, plus `OR REPLACE` and materialization |
| B6 | Persisted reducer catalog | done | `_reducer` stores name, kind and parameter types |
| B7 | Procedures with their own transaction phase | done | commit between phases, open the next one, sleep |
| B8 | Event tables and outbox | done | `CREATE EVENT TABLE` is append-only; `events_read` reads from a cursor and `SHOW events` lists them |
| B9 | Full schedule (instant and interval) | done | one-shot, immediate and interval rows; cancellation by deleting the row |
| B10 | Row-level security | done | `USING`/`CHECK` policies in `_policy`, combined with AND |
| B11 | Session and module variables | done | `SET`/`SHOW` for the session, `_var` and `host_set_module_variable` for the module |
| B12 | Client and credential tables | done | `_client` catalogs identities (name, creation time); credentials live in `_token` |
| B13 | Module metadata and schema versioning | done | `_meta` with a `schema_version` row |
| B14 | Automatic schema migration | done | `host_migrate` applies ordered steps, each atomic with its version bump |
| B15 | Table, column and index accessors | done | `SHOW tables` and `DESCRIBE` cover tables, columns and indexes |
| B16 | Full schema validation rules | done | table/index names, duplicate columns, NOT NULL with a NULL default, primary key and index column reuse |

## C. Datastore and transactions

| ID | Feature | Status | Gap |
|---|---|---|---|
| C1 | MVCC with persistent structures | done | rows keep version chains visible at a read sequence; `tx_begin_read_at`, pruning, and replay rebuilds history |
| C2 | Read snapshots without blocking the writer | done | a read transaction copies its tables at begin and runs lock-free, so a commit never waits for a reader |
| C3 | Transaction offsets and read sets | done | `tx_read_seq` (start offset) and `tx_read_tables` (touched tables) |
| C4 | Transaction time fixed at commit | done | the commit stamps `last_commit_us` when it lands; `store_last_commit_us` reads it |
| C5 | Truncate with table-level tombstones | done | `TRUNCATE` stages one table-level op |
| C6 | Range scans through an index | done | the SQL planner and executor use them; there is no public Odin call for a range scan yet |
| C7 | Update in place | done | — |
| C8 | Ephemeral tables | done | `CREATE TEMPORARY TABLE`: applied in the session, never logged, gone on reopen |
| C9 | Per-table memory accounting | done | `store_table_memory`, shown by `inspect` |
| C10 | Snapshot files | done | `<database>/snapshot`, atomic replace |
| C11 | Replay from snapshot plus log | done | snapshot applied first, later records only |

## D. Commit log and durability

| ID | Feature | Status | Gap |
|---|---|---|---|
| D1 | Segments with a maximum size | done | 256 KiB segments, header per segment, rotation on append |
| D2 | Offset index per segment | done | `log.index` sidecar, validated lookup, rebuilt on demand |
| D3 | Negotiated format version | done | strict version check |
| D4 | Pluggable checksum algorithm | done | header records the algorithm: CRC32C (default) or none |
| D5 | Durability modes | done | Full, Batched (every 64) and None |
| D6 | Prepared, pipelined transactions | done | `tx_prepare` then `store_commit_prepared`: many records, one fsync |
| D7 | Streaming reader and writer | done | `log_reader_open/next/close` walks a file record by record and stops at a torn tail |
| D8 | Corruption, bit-flip and partial-record tests | done | torn tail plus a bit-flip that CRC rejects and replay repairs |
| D9 | In-memory log for simulation | done | `in_memory_log` buffer, same append path, no files |

## E. Queries and SQL

| ID | Feature | Status | Gap |
|---|---|---|---|
| E1 | Joins | done | inner, left, cross; nested loops |
| E2 | Semijoins | done | uncorrelated `IN`/`NOT IN`, `EXISTS`/`NOT EXISTS` and scalar subqueries; correlated references are not resolved |
| E3 | Index-driven update and delete | done | both narrow the scan through an index when possible |
| E4 | Complete scalar and aggregate function set | done | text, numeric and null functions plus six aggregates |
| E5 | `SET` and `SHOW` | done | session variables through the engine API; a server connection keeps its own identity and variables |
| E6 | `EXPLAIN` | done | scan/index choice, joins and post-processing steps |
| E7 | Row-level security in queries | done | policies filter reads and validate writes; subscriptions inherit them |
| E8 | Multi-query subscription sets | done | `host_subscribe_many`; one row set and one delta per query |
| E9 | Incremental subscription evaluation | done | a commit projects only the changed rows and diffs them against the cache; joins and aggregates have their own incremental paths, and ordering, `DISTINCT`, policies or DDL fall back to a full re-evaluation |
| E10 | Confirmed-read offsets in responses | done | every result carries `commit_seq`; F10 exposes it on the wire |
| E11 | `LIKE` escapes, casts between all types | done | `ESCAPE` supported; casts cover numbers, text, bool, timestamp, uuid, identity |
| E12 | Views as query sources | done | materialized per reference inside the transaction |
| E13 | System tables | done | `_tables`, `_columns` and `_indexes` synthesized from the catalog with full WHERE/ORDER BY support |
| E14 | Complete statement surface | done | `ALTER TABLE ADD COLUMN`, `CREATE OR REPLACE VIEW` and `FOREIGN KEY` with RESTRICT/CASCADE on delete and update, enforced on insert, update and delete |

## F. Server and protocol

| ID | Feature | Status | Gap |
|---|---|---|---|
| F1 | HTTP server | done | `miraidb-server` accept loop, HTTP routing, `/health`; verified end to end |
| F2 | WebSocket protocol with JSON and binary formats | done | RFC 6455 handshake and binary frames carrying wire messages |
| F3 | Reducer call over the wire with a request id | done | `WIRE_CALL_REDUCER` + request id over HTTP/WebSocket |
| F4 | One-off query | done | `WIRE_QUERY` over the same endpoints |
| F5 | Subscribe, subscribe-single, subscribe-multi, unsubscribe | done | `WIRE_SUBSCRIBE`/`WIRE_UNSUBSCRIBE`, sets and owner cleanup |
| F6 | Procedure call | done | `WIRE_CALL_PROCEDURE` through the same server endpoints |
| F7 | Identity, tokens and JWT validation | done | CSPRNG tokens hashed with HMAC-SHA256; HS256 JWTs with `sub`/`exp` validation and tamper rejection |
| F8 | Energy metering and quotas | done | per-statement work (rows + payload) with a per-call budget, a cumulative total and the row quota |
| F9 | Client lifecycle and cancellation | done | registry, connection limit, cancellation, owned subscriptions, byte accounting, and a bounded outbox that drops a message and closes the connection on overflow |
| F10 | Confirmed reads | done | every result carries `commit_seq`, so the client confirms its read |
| F11 | Compression and row-size hints | done | deflate encoder (fixed Huffman + LZ77) in `deflate.odin`, HTTP zlib negotiation, `row_bytes` hints |
| F12 | Connection limits and backpressure | done | connection cap with 503, 4 MiB request limit, per-client byte accounting |
| F13 | Metrics endpoint | done | `GET /metrics` with requests, errors, commit sequence and subscriptions |
| F14 | PostgreSQL wire protocol | done | startup, SSLRequest, simple and extended query, text and binary parameters/results, plan-only `Describe`, Sync/Close/Flush |

## G. Modules and ABI

| ID | Feature | Status | Gap |
|---|---|---|---|
| G1 | Sandboxed module host with ABI v1/v2 | done | ABI v1 and v2; a v2 module runs with a bounded arena and a row quota (cooperative, in-process boundary; no dynamic loading or OS isolation) |
| G2 | Table and index scans with iterators | done | `module_scan_begin`/`_next`/`_end` over a read transaction |
| G3 | Insert, update, delete, delete-by-range from a module | done | `module_insert`/`_update`/`_delete`/`_delete_range` each commit one transaction |
| G4 | Immediate scheduled call | done | `host_schedule_now` queues at the current host time |
| G5 | Console log and timers | done | `procedure_log` messages returned with the call and `procedure_now_us` |
| G6 | Identity and JWT inside a module | done | `module_identity` and `module_authenticate` |
| G7 | HTTP requests from procedures | done | `http_get`/`http_get_via` with a pluggable transport and a TCP transport |
| G8 | Procedure transaction control and sleep | done | `procedure_commit` and `procedure_sleep` |
| G9 | Bytes sources and sinks | done | `bytes_source_*` / `bytes_sink_*` cursors for framed module I/O |
| G10 | Native Odin module registration | done | `host_register_module` with ABI validation and name dispatch |

## H. Tooling, SDK and operations

| ID | Feature | Status | Gap |
|---|---|---|---|
| H1 | Full CLI | done | `call` and `subscribe` join the tooling commands; subscribe prints a snapshot and then the inserts/deletes it polls from the server |
| H2 | Code generation | done | `miraidb codegen` and `codegen_odin`: one Odin struct per table, typed from `DESCRIBE` |
| H3 | Client SDKs | done | Odin SDK in `src/client`: query, call, auth and subscribe over an injected transport |
| H4 | SQL conformance runner | done | `scripts/conformance.py` runs a 20-case corpus through the CLI |
| H5 | Deterministic simulation testing | done | `Simulation` drives an explicit clock and `host_tick`; a script produces identical state on every run |
| H6 | Typed metrics | done | `/metrics` emits `# TYPE` counters and gauges |
| H7 | Per-database memory reporting | done | `store_memory` and the `inspect` footer sum every table |
| H8 | Module hot swap | done | `host_swap_module` runs the old shutdown, the new init and then swaps handlers |
| H9 | Test fixtures and harness | done | `fresh_host`/`destroy_host` and `run_params` fixtures |
| H10 | Benchmarks | done | `miraidb bench <db> [rows]` times inserts in one transaction |

## Order the work followed

This section used to list the dependency order for the rows still open. All 94
are closed, so the order is history: the last engine rows landed in this order
(E9, F7/F9, G1–G3, G5–G7/G9/G10, H2/H6, then the L rows). What is left is not
parity: it is depth, and `docs/roadmap.md` orders it.

## Parity notes

- The target's SQL layer uses a general-purpose parser; this engine has its own.
  Parity means behaviour, not the same dependency.
- The target invokes reducers through a module ABI; this engine calls them in
  process. Parity means the same semantics: one transaction per call,
  idempotency by request id, persisted schedules.
- The target persists its catalog in system tables. This engine keeps the schema
  in the log; exposing `st_*`-style system tables is a feature (B11–B15, E13),
  not a storage requirement.
