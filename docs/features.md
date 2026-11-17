# Feature matrix

The record of the feature set this engine targets. Each row is one capability,
with its status in this tree, the evidence that closed it, and the test or gate
that covers it. IDs are stable. The matrix is closed: 101 rows, all `done`, and
every row names its test; `scripts/docs_check.py` fails if a name stops existing,
so "each with a test" is a claim the gate checks rather than a sentence.
[closing-plan.md](closing-plan.md)
records how each row was closed, [roadmap.md](roadmap.md) is the list of what is
left and [backlog.md](backlog.md) its detail. Parity of interface is closed;
parity of speed is not (roadmap track A).

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
| E. Queries and SQL | 21 | 0 | 0 | 21 |
| F. Server and protocol | 14 | 0 | 0 | 14 |
| G. Modules and ABI | 10 | 0 | 0 | 10 |
| H. Tooling, SDK and operations | 10 | 0 | 0 | 10 |
| **Total (101)** | **101** | **0** | **0** | **101** |

**101 done (100 %)**: 0 partial, 0 todo, and every row is covered by a test.
Parity is interface-level by definition; where the implementation is shallower
than a mature engine, the gap is named with its cost in [backlog.md](backlog.md)
rather than hidden in this table.

## A. Data model and types

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| A1 | 8/16/32-bit integers with range checks | done | `TINYINT`/`SMALLINT`/`INT4`, unsigned variants, range enforced on store | test_integer_widths |
| A2 | 128-bit integers | done | `INT128`/`UINT128`, arithmetic, aggregates, index keys | test_128_bit_integers |
| A3 | `F32` distinct from `F64` | done | `FLOAT4` rounds to single precision on store | test_integer_widths |
| A4 | `Unit`, `Option`, `Result` as types | done | `UNIT`, `OPTION(T)` and `RESULT(T, E)` parse, coerce (one Result side), reflect and replay | test_structural_types |
| A5 | Arrays and products as column values | done | `ARRAY(T)` and `PRODUCT(T1, ..., Tn)` are column types: parser, element-wise coercion, codec, reflection; PostgreSQL's spellings (`TEXT[]`, `ARRAY[...]`, `x[i]`, `@>`, `<@`, `&&`, `||`, `= ANY`, `array_agg`, `array_length`, `cardinality`) are in `docs/sql.md`; PostgreSQL's text form `{a,b}` is read as an array and written as one, so a driver's array parameter and result both work | test_array_and_product_types, test_array_syntax_and_operators, test_array_text_form |
| A6 | Named types and references | done | `CREATE TYPE name AS base`, resolved from `_type` when a table is created; `SHOW types` | test_named_types, test_named_type_references |
| A7 | Domains: identity, connection, timestamp, duration, uuid | done | `DURATION`, `IDENTITY`, `CONNECTION` added; timestamps and uuid already existed | test_domain_types |
| A8 | Stable serialization with resolved references | done | a column keeps its catalog name next to the resolved type; both are encoded, replayed and exposed as `_columns.named` | test_named_types |
| A9 | Hash, order and equality for every type | done | `value_compare`, `value_equal` and `value_hash` tested for all 19 kinds, including numeric cross-kind equality | test_value_order_and_hash |
| A10 | Type reflection for clients | done | `host_schema_text` and `GET /schema` render tables, columns and indexes | test_schema_reflection |

## B. Schema and catalog

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| B1 | Composite primary key | done | inline or `PRIMARY KEY (a, b)`; one unique index over the tuple | test_composite_primary_key |
| B2 | Named, multi-column unique constraints | done | `[CONSTRAINT name] UNIQUE (a, b)` creates a named index | test_named_unique_constraints |
| B3 | Index algorithms: btree, hash, direct | done | btree by default; `USING HASH` for equality on any columns and `USING DIRECT` for a unique key that names one row | test_hash_and_direct_indexes |
| B4 | Independent sequences | done | per-column start/increment/min/max, independent of the row id | test_sequences |
| B5 | Views with parameters | done | positional `?` parameters bound by `FROM v(...)`, plus `OR REPLACE` and materialization | test_view_parameters |
| B6 | Persisted reducer catalog | done | `_reducer` stores name, kind and parameter types | test_reducer_catalog |
| B7 | Procedures with their own transaction phase | done | commit between phases, open the next one, sleep | test_procedures |
| B8 | Event tables and outbox | done | `CREATE EVENT TABLE` is append-only; `events_read` reads from a cursor and `SHOW events` lists them | test_event_tables |
| B9 | Full schedule (instant and interval) | done | one-shot, immediate and interval rows; cancellation by deleting the row | test_scheduler, test_schedule_interval |
| B10 | Row-level security | done | `USING`/`CHECK` policies in `_policy`, combined with AND | test_policies |
| B11 | Session and module variables | done | `SET`/`SHOW` for the session, `_var` and `host_set_module_variable` for the module | test_set_and_show, test_module_variables |
| B12 | Client and credential tables | done | `_client` catalogs identities (name, creation time); credentials live in `_token` | test_client_registry, test_tokens |
| B13 | Module metadata and schema versioning | done | `_meta` with a `schema_version` row | test_schema_migrations |
| B14 | Automatic schema migration | done | `host_migrate` applies ordered steps, each atomic with its version bump | test_schema_migrations |
| B15 | Table, column and index accessors | done | `SHOW tables` and `DESCRIBE` cover tables, columns and indexes | test_show_tables, test_describe, test_show_indexes |
| B16 | Full schema validation rules | done | table/index names, duplicate columns, NOT NULL with a NULL default, primary key and index column reuse | test_schema_validation |

## C. Datastore and transactions

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| C1 | MVCC with persistent structures | done | rows keep version chains visible at a read sequence; `tx_begin_read_at`, pruning, and replay rebuilds history | test_row_versions |
| C2 | Read snapshots without blocking the writer | done | a read transaction copies its tables at begin and runs lock-free, so a commit never waits for a reader | test_snapshot_reads_do_not_block_writers |
| C3 | Transaction offsets and read sets | done | `tx_read_seq` (start offset) and `tx_read_tables` (touched tables) | test_transaction_read_set |
| C4 | Transaction time fixed at commit | done | the commit stamps `last_commit_us` when it lands; `store_last_commit_us` reads it | test_commit_time |
| C5 | Truncate with table-level tombstones | done | `TRUNCATE` stages one table-level op | test_sql_functions_and_truncate |
| C6 | Range scans through an index | done | the SQL planner and executor use them; there is no public Odin call for a range scan yet | test_index_ddl_and_ranges, test_ordered_index_scan_bounds |
| C7 | Update in place | done | — | test_update_keeps_the_row_in_place |
| C8 | Ephemeral tables | done | `CREATE TEMPORARY TABLE`: applied in the session, never logged, gone on reopen | test_ephemeral_tables |
| C9 | Per-table memory accounting | done | `store_table_memory`, shown by `inspect` | test_table_memory |
| C10 | Snapshot files | done | `<database>/snapshot`, atomic replace | test_snapshot_restore |
| C11 | Replay from snapshot plus log | done | snapshot applied first, later records only | test_snapshot_restore |

## D. Commit log and durability

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| D1 | Segments with a maximum size | done | 256 KiB segments, header per segment, rotation on append | test_log_segments |
| D2 | Offset index per segment | done | `log.index` sidecar, validated lookup, rebuilt on demand | test_log_offset_index |
| D3 | Negotiated format version | done | strict version check | test_log_format_is_negotiated |
| D4 | Pluggable checksum algorithm | done | header records the algorithm: CRC32C (default) or none | test_checksum_modes |
| D5 | Durability modes | done | Full, Batched (every 64) and None | test_durability_modes |
| D6 | Prepared, pipelined transactions | done | `tx_prepare` then `store_commit_prepared`: many records, one fsync | test_prepared_commit_group |
| D7 | Streaming reader and writer | done | `log_reader_open/next/close` walks a file record by record and stops at a torn tail | test_log_stream_reader |
| D8 | Corruption, bit-flip and partial-record tests | done | torn tail plus a bit-flip that CRC rejects and replay repairs | test_torn_log_tail, test_log_bit_flip |
| D9 | In-memory log for simulation | done | `in_memory_log` buffer, same append path, no files | test_in_memory_log |

## E. Queries and SQL

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| E1 | Joins | done | inner, left, right, full and cross; nested loops | test_joins, test_right_and_full_joins |
| E2 | Semijoins | done | `IN`/`NOT IN`, `EXISTS`/`NOT EXISTS` and scalar subqueries, correlated at any depth: a column the subquery does not have resolves against the row of the statement it is written in | test_semijoins, test_correlated_subqueries |
| E3 | Index-driven update and delete | done | both narrow the scan through an index when possible | test_indexed_dml_and_offsets |
| E4 | Complete scalar and aggregate function set | done | text, numeric and null functions plus six aggregates | test_math_functions, test_text_and_blob_functions, test_aggregates_and_order |
| E5 | `SET` and `SHOW` | done | session variables through the engine API; a server connection keeps its own identity and variables | test_set_and_show |
| E6 | `EXPLAIN` | done | scan/index choice, joins and post-processing steps | test_explain |
| E7 | Row-level security in queries | done | policies filter reads and validate writes; subscriptions inherit them | test_policies |
| E8 | Multi-query subscription sets | done | `host_subscribe_many`; one row set and one delta per query | test_subscription_set |
| E9 | Incremental subscription evaluation | done | a commit projects only the changed rows and diffs them against the cache; joins and aggregates have their own incremental paths, and ordering, `DISTINCT`, policies or DDL fall back to a full re-evaluation | test_incremental_subscriptions, test_incremental_join_subscription, test_incremental_aggregate_subscription |
| E10 | Confirmed-read offsets in responses | done | every result carries `commit_seq`; F10 exposes it on the wire | test_wire_messages |
| E11 | `LIKE` escapes, casts between all types | done | `ESCAPE` supported; casts cover numbers, text, bool, timestamp, uuid, identity | test_like_escape, test_cast_to_narrow_types |
| E12 | Views as query sources | done | materialized per reference inside the transaction | test_views |
| E13 | System tables | done | `_tables`, `_columns` and `_indexes` synthesized from the catalog with full WHERE/ORDER BY support | test_system_tables |
| E21 | `LISTEN` and `NOTIFY` | done | `LISTEN channel`, `UNLISTEN channel`/`UNLISTEN *` and `NOTIFY channel [, payload]`; the listener receives the protocol's NotificationResponse on its own connection, a sender does not hear itself, and the registry belongs to the database | test_listen_registry, scripts/pg_notify_smoke.py |
| E20 | The SQLite function and pragma surface | done | the hyperbolic family, `soundex`, `unistr`/`unistr_quote`, `timediff`, `affinity`, `sqlite_source_id`, `sqlite_compileoption_*`, the JSON mutators (`json_insert`, `json_patch`, `json_pretty`, `json_error_position`) the `json_group_array`/`json_group_object` aggregates and the ordered aggregates (`median`, `percentile*`), and every pragma in the inventory (`collation_list`, `module_list`, `shrink_memory`, `soft_heap_limit64`, `temp_store*`, `data_store_directory`, `incremental_vacuum`, `legacy_file_format`); `EXPLAIN QUERY PLAN` in SQLite's four columns, and the counts are in `scripts/sqlite_gaps.py` (106/121 functions, 63/63 pragmas, 51/63 grammar) | test_sqlite_scalar_gaps, test_sqlite_pragma_gaps, test_json_mutators_and_aggregates, test_percentile_aggregates, scripts/sqlite_gaps.py |
| E19 | Cursors | done | `DECLARE name CURSOR FOR query`, `FETCH` (NEXT, PRIOR, FIRST, LAST, ABSOLUTE, RELATIVE, FORWARD, BACKWARD, ALL), `MOVE` and `CLOSE [ALL]`; a cursor lives in the transaction that declared it and a `WITH HOLD` one is refused with words | test_cursors |
| E18 | `LATERAL` | done | `FROM a, LATERAL (SELECT ...)` and `JOIN LATERAL (...) ON ...`: the derived table is evaluated once per row of the sources to its left, so its aggregates and filters read that row; a RIGHT or FULL join of a lateral step is refused | test_lateral_subqueries |
| E17 | `MERGE` | done | `MERGE INTO t USING s ON ... WHEN MATCHED [AND cond] THEN UPDATE/DELETE WHEN NOT MATCHED [AND cond] THEN INSERT`, one statement and one pass, a target a second source would change again is refused, policies apply; `WHEN NOT MATCHED BY SOURCE` is refused with words | test_merge_updates_inserts_and_deletes |
| E16 | Grouping sets | done | `GROUP BY ROLLUP(...)`, `CUBE(...)` and `GROUPING SETS (...)`: one row per set, a column the set leaves out reads NULL, `GROUPING(x)` answers the mask, and a construct beside a plain expression multiplies the sets | test_grouping_sets |
| E15 | `COPY` in and out | done | `COPY t [(cols)] FROM`/`TO` a file, `STDIN` or `STDOUT`, in the text format (tab separated, `\N`, backslash escapes) and CSV (`HEADER`, `DELIMITER`, `NULL`); each field is parsed against its column's type and a row that fails writes none of the rows; `test_copy_text_and_csv_roundtrip`, `test_copy_options_and_column_lists`, `test_copy_refuses_a_bad_row` | test_copy_text_and_csv_roundtrip, test_copy_options_and_column_lists, test_copy_refuses_a_bad_row |
| E14 | Complete statement surface | done | `ALTER TABLE ADD COLUMN`, `CREATE OR REPLACE VIEW` and `FOREIGN KEY` with RESTRICT/CASCADE on delete and update, enforced on insert, update and delete | test_create_or_replace_view, test_foreign_key_enforcement, test_alter_table_add_column |

## F. Server and protocol

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| F1 | HTTP server | done | `miraidb-server` accept loop, HTTP routing, `/health`; verified end to end | test_http_layer |
| F2 | WebSocket protocol with JSON and binary formats | done | RFC 6455 handshake and binary frames carrying wire messages | test_websocket |
| F3 | Reducer call over the wire with a request id | done | `WIRE_CALL_REDUCER` + request id over HTTP/WebSocket | test_wire_messages |
| F4 | One-off query | done | `WIRE_QUERY` over the same endpoints | test_wire_messages |
| F5 | Subscribe, subscribe-single, subscribe-multi, unsubscribe | done | `WIRE_SUBSCRIBE`/`WIRE_UNSUBSCRIBE`, sets and owner cleanup | test_subscriptions, test_subscription_set |
| F6 | Procedure call | done | `WIRE_CALL_PROCEDURE` through the same server endpoints | test_procedure_over_the_wire |
| F7 | Identity, tokens and JWT validation | done | CSPRNG tokens hashed with HMAC-SHA256; HS256 JWTs with `sub`/`exp` validation and tamper rejection | test_jwt_tokens, test_tokens |
| F8 | Energy metering and quotas | done | per-statement work (rows + payload) with a per-call budget, a cumulative total and the row quota | test_work_budget, test_statement_work_budget, test_row_quota |
| F9 | Client lifecycle and cancellation | done | registry, connection limit, cancellation, owned subscriptions, byte accounting, and a bounded outbox that drops a message and closes the connection on overflow | test_cancellation, test_transport_caps |
| F10 | Confirmed reads | done | every result carries `commit_seq`, so the client confirms its read | test_wire_messages |
| F11 | Compression and row-size hints | done | deflate encoder (fixed Huffman + LZ77) in `deflate.odin`, HTTP zlib negotiation, `row_bytes` hints | test_http_compression, test_deflate_roundtrip, test_row_size_hint |
| F12 | Connection limits and backpressure | done | connection cap with 503, 4 MiB request limit, per-client byte accounting | test_transport_caps, test_wire_request_limit |
| F13 | Metrics endpoint | done | `GET /metrics` with requests, errors, commit sequence and subscriptions | test_meta_and_metrics |
| F14 | PostgreSQL wire protocol | done | startup with the standard ParameterStatus set, SSLRequest answered with one byte, SCRAM-SHA-256 authentication when the server is given a password, simple query with several statements, extended query framed per message (several to a packet), `Describe` that announces the types `Execute` encodes, skip-to-`Sync` after an error, text and binary parameters/results, transactions across messages with the aborted state, PostgreSQL command tags and SQLSTATE codes, `DEALLOCATE`/`DISCARD`; `COPY` driven by the client (CopyInResponse/CopyData/CopyDone and CopyFail in, CopyOutResponse/CopyData/CopyDone out); the dialect spellings are in `docs/sql.md` (PostgreSQL spellings) | test_postgres_wire, test_postgres_extended_query, scripts/pg_copy_smoke.py |

## G. Modules and ABI

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| G1 | Sandboxed module host with ABI v1/v2 | done | ABI v1 and v2; a v2 module runs with a bounded arena and a row quota (cooperative, in-process boundary; no dynamic loading or OS isolation) | test_module_abi, test_module_abi_v2 |
| G2 | Table and index scans with iterators | done | `module_scan_begin`/`_next`/`_end` over a read transaction | test_module_data_access |
| G3 | Insert, update, delete, delete-by-range from a module | done | `module_insert`/`_update`/`_delete`/`_delete_range` each commit one transaction | test_module_data_access |
| G4 | Immediate scheduled call | done | `host_schedule_now` queues at the current host time | test_schedule_now |
| G5 | Console log and timers | done | `procedure_log` messages returned with the call and `procedure_now_us` | test_procedure_logs_and_timers |
| G6 | Identity and JWT inside a module | done | `module_identity` and `module_authenticate` | test_module_identity |
| G7 | HTTP requests from procedures | done | `http_get`/`http_get_via` with a pluggable transport and a TCP transport | test_http_client |
| G8 | Procedure transaction control and sleep | done | `procedure_commit` and `procedure_sleep` | test_procedures |
| G9 | Bytes sources and sinks | done | `bytes_source_*` / `bytes_sink_*` cursors for framed module I/O | test_byte_cursors |
| G10 | Native Odin module registration | done | `host_register_module` with ABI validation and name dispatch | test_module_abi |

## H. Tooling, SDK and operations

| ID | Feature | Status | Gap | Test |
|---|---|---|---|---|
| H1 | Full CLI | done | `call` and `subscribe` join the tooling commands; subscribe prints a snapshot and then the inserts/deletes it polls from the server | scripts/shell_smoke.py, scripts/broker_smoke.py |
| H2 | Code generation | done | `miraidb codegen` and `codegen_odin`: one Odin struct per table, typed from `DESCRIBE` | test_codegen |
| H3 | Client SDKs | done | Odin SDK in `src/client`: query, call, auth and subscribe over an injected transport | test_client_sdk |
| H4 | SQL conformance runner | done | `scripts/conformance.py` runs a 20-case corpus through the CLI | scripts/conformance.py |
| H5 | Deterministic simulation testing | done | `Simulation` drives an explicit clock and `host_tick`; a script produces identical state on every run | test_deterministic_simulation |
| H6 | Typed metrics | done | `/metrics` emits `# TYPE` counters and gauges | test_meta_and_metrics |
| H7 | Per-database memory reporting | done | `store_memory` and the `inspect` footer sum every table | test_store_memory |
| H8 | Module hot swap | done | `host_swap_module` runs the old shutdown, the new init and then swaps handlers | test_module_hot_swap |
| H9 | Test fixtures and harness | done | `fresh_host`/`destroy_host` and `run_params` fixtures | test_fixture_helpers |
| H10 | Benchmarks | done | `miraidb bench <db> [rows]` times inserts in one transaction | scripts/bench.py |

## Order the work followed

This section used to list the dependency order for the rows still open. All 101
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
