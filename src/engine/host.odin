package engine

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"

// A Host adds the programmable layer on top of a Store: registered reducers
// (transactional procedures written in Odin) and live subscriptions.
//
// Reducers run inside one transaction: either every change they make commits or
// none does. Subscriptions re-evaluate their query after each commit that
// touches their table and publish a row-level delta.

Reducer_Ctx :: struct {
	tx:     ^Tx,
	host:   ^Host,
	now_us: i64,
}

// Reducer_Def is a registered reducer: what it is called, the parameter types a
// call is coerced to, and the handler that runs inside the transaction.
Reducer_Def :: struct {
	name:    string,
	params:  []Column_Type,
	handler: proc(ctx: ^Reducer_Ctx, args: []Value) -> Error,
}

// Subscription_Update is one row-level delta. Inserts and deletes are owned by
// the host and only valid during the callback.
Subscription_Update :: struct {
	subscription_id: u64,
	// query indexes the SELECT inside a subscription set.
	query:           int,
	table:           string,
	inserts:         [][]Value,
	deletes:         [][]Value,
}

Subscription_Query :: struct {
	query:       Query,
	table:       string,
	join_tables: []string,
	rows:        map[string][]Value,
	// row_keys maps the stored row id of each cached row to its output key, so a
	// commit can turn a row operation into the matching delta.
	row_keys:    map[Row_Id]string,
	// join marks a query over more than one table. Its keys live in join_arena,
	// which owns them until the subscription is dropped, so moving a tuple never
	// frees anything on its own.
	join:           bool,
	join_ready:     bool,
	join_arena:     virtual.Arena,
	join_allocator: mem.Allocator,
	// join_tuples is the tuple index: one entry per combination of source rows
	// that contributes to the cached set, keyed by the concatenation of their
	// row ids. join_by_row finds the tuples that a stored row takes part in, and
	// join_counts tracks how many tuples project to the same output row.
	join_tuples:    map[string]Join_Tuple,
	join_by_row:    map[Source_Row][dynamic]string,
	join_counts:    map[string]int,
	// agg marks a grouped query over one table (or one aggregate over all of
	// it). Its state is one entry per group with the rows that feed it and the
	// row last published, so a commit recomputes only the groups it touches.
	agg:         bool,
	agg_ready:   bool,
	agg_whole:   bool,
	agg_groups:  map[string]Agg_Group,
	agg_by_row:  map[Row_Id]string,
}

// Agg_Group is one group of an aggregate subscription: the base rows that feed
// it and the row that was last published for it.
Agg_Group :: struct {
	rows:      map[Row_Id]struct{},
	published: []Value,
	found:     bool,
}

// Source_Row names a stored row inside one source of a join query. Row ids are
// only unique inside their table, so the source index is part of the key.
Source_Row :: struct {
	source: int,
	id:     Row_Id,
}

// Join_Tuple is one combination of source rows in a join subscription. `ids`
// holds one row id per source in query order and `output` is the key of the row
// it projects to.
Join_Tuple :: struct {
	ids:    []Row_Id,
	output: string,
}

HOST_MAX_CLIENTS :: 64

// Transport caps: what one connection may send. They are deliberately small and
// configurable; exceeding one is a clean rejection, never a crash.
HOST_MAX_REQUEST_BYTES :: 1 << 20
HOST_MAX_HEADER_BYTES :: 16 * 1024
HOST_MAX_FRAME_BYTES :: 1 << 20

// Client is one live connection in the host registry.
Client :: struct {
	owner:        u64,
	connected_us: i64,
	requests:     u64,
	bytes_out:    u64,
	// queue is the bytes waiting in the outbox, dropped counts the messages the
	// policy discarded, and drop asks the transport to close the connection.
	queue:   u64,
	dropped: u64,
	drop:    bool,
}

Subscription :: struct {
	id:      u64,
	owner:   u64,
	queries: []Subscription_Query,
}

Host :: struct {
	store:                ^Store,
	reducers:             map[string]Reducer_Def,
	modules:              map[string]Module,
	// remote_modules are the modules that run in another process, keyed by name.
	remote_modules:       map[string]Remote_Module,
	// remote_conns keeps one open socket per module: a call is a write and a
	// read, not a connect. A broken socket is dropped and the call redials once.
	remote_conns:         map[string]Remote_Conn,
	remote_mutex:         sync.Mutex,
	procedures:           map[string]Procedure_Def,
	subscriptions:        [dynamic]^Subscription,
	next_subscription_id: u64,
	// max_work_units is the per-call budget: a reducer that reads or writes more
	// rows than this is rolled back instead of committed. Zero means unlimited.
	max_work_units:       u64,
	// work_units_last is what the previous call spent, so a caller can size the
	// budget from evidence instead of guessing.
	work_units_last:      u64,
	// next_request_id numbers outgoing module calls, so each one executes once.
	next_request_id:      u64,
	// incremental_updates counts the deltas applied row by row instead of by
	// re-evaluating the query.
	incremental_updates:  u64,
	now_us:               i64,
	// token_counter keeps issued tokens distinct within one process.
	token_counter:        u64,
	// token_key is the HMAC key for credential hashing, loaded lazily.
	token_key:            []u8,
	// procedure_logs holds the messages of the last procedure call.
	procedure_logs:       []string,
	// Counters for the metrics endpoint.
	metric_requests:      u64,
	metric_errors:        u64,
	// Live connection registry (F9).
	clients:              map[u64]Client,
	max_clients:          int,
	// module_memory_limit and module_row_limit bound one module call.
	module_memory_limit:  int,
	module_row_limit:     u64,
	// client_queue_budget caps the outbound bytes waiting for one client. Zero
	// means unbounded. Overflow discards the message and closes the connection.
	client_queue_budget:  u64,
	// max_request_bytes, max_header_bytes and max_frame_bytes are the transport
	// caps enforced by the HTTP and WebSocket layers. Zero disables one.
	max_request_bytes:    int,
	max_header_bytes:     int,
	max_frame_bytes:      int,
	on_update:            proc(ctx: rawptr, update: ^Subscription_Update),
	on_update_ctx:        rawptr,
}

host_init :: proc(store: ^Store) -> ^Host {
	host := new(Host)
	host.store = store
	store.host = host
	host.reducers = make(map[string]Reducer_Def)
	host.subscriptions = make([dynamic]^Subscription)
	host.procedures = make(map[string]Procedure_Def)
	host.next_subscription_id = 1
	// Outgoing calls are numbered from the clock, so a restarted host cannot reuse
	// an id that the module still remembers as an acknowledged call.
	host.next_request_id = u64(time.time_to_unix_nano(time.now()))
	if host.next_request_id == 0 do host.next_request_id = 1
	store.on_commit = host_on_commit
	store.on_commit_ctx = host
	host.modules = make(map[string]Module)
	host.remote_modules = make(map[string]Remote_Module)
	host.remote_conns = make(map[string]Remote_Conn)
	host.clients = make(map[u64]Client)
	host.max_clients = HOST_MAX_CLIENTS
	host.max_request_bytes = HOST_MAX_REQUEST_BYTES
	host.max_header_bytes = HOST_MAX_HEADER_BYTES
	host.max_frame_bytes = HOST_MAX_FRAME_BYTES
	host.module_memory_limit = MODULE_DEFAULT_MEMORY
	if meta_err := host_ensure_meta(host); meta_err.kind != .None {
		// The host can still serve, but the catalog is missing; keep the reason.
		host.store.last_error = meta_err
	}
	// Extensions are processes: registering them opens nothing yet, so a database
	// with an extension that is down still starts.
	_ = host_replay_extensions(host)
	// Setup writes through the SQL path; those are not user changes, so the
	// counters changes()/total_changes() report start clean.
	store.last_changes = 0
	store.last_row_id = 0
	store.total_changes = 0
	return host
}

host_destroy :: proc(host: ^Host) {
	if host == nil do return
	if host.store != nil {
		host.store.host = nil
		host.store.on_commit = nil
		host.store.on_commit_ctx = nil
	}
	for _, reducer in host.reducers {
		delete(reducer.name)
		delete(reducer.params)
	}
	delete(host.reducers)
	for _, procedure in host.procedures {
		delete(procedure.name)
		delete(procedure.params)
	}
	delete(host.procedures)
	for subscription in host.subscriptions {
		free_subscription_queries(subscription.queries)
		delete(subscription.queries)
		free(subscription)
	}
	delete(host.subscriptions)
	host_remote_conns_close(host)
	host_remote_modules_destroy(host)
	free(host)
}

host_register :: proc(
	host: ^Host,
	name: string,
	params: []Column_Type,
	handler: proc(ctx: ^Reducer_Ctx, args: []Value) -> Error,
) -> Error {
	if len(name) == 0 {
		return errf(.Invalid_Argument, "a reducer needs a name")
	}
	if _, exists := host.reducers[name]; exists {
		return errf(.Invalid_Argument, "reducer %s is already registered", name)
	}
	host.reducers[name] = Reducer_Def {
		name    = strings.clone(name),
		params  = make([]Column_Type, len(params)),
		handler = handler,
	}
	copy(host.reducers[name].params, params)
	return host_catalog_record(host, name, "reducer", params)
}

// REDUCER_TABLE is the persisted catalog: name, kind (reducer or procedure) and
// the comma-separated parameter types. Handlers stay linked in code; the catalog
// lets restarts, clients and code generation see what the module exposes.
REDUCER_TABLE :: "_reducer"
REDUCER_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _reducer (
		name TEXT PRIMARY KEY,
		kind TEXT NOT NULL,
		params TEXT NOT NULL
	)`

@(private)
host_catalog_record :: proc(
	host: ^Host,
	name, kind: string,
	params: []Column_Type,
) -> Error {
	result, create_err := sql_execute(host.store, REDUCER_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for param, i in params {
		if i > 0 do strings.write_string(&builder, ",")
		strings.write_string(&builder, column_type_name(param))
	}
	encoded := strings.to_string(builder)
	existing, select_err := sql_execute_params(
		host.store,
		"SELECT 1 FROM _reducer WHERE name = ?",
		[]Value{value_string(name)},
	)
	if select_err.kind != .None do return select_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	values := []Value{value_string(kind), value_string(encoded), value_string(name)}
	if found {
		_, update_err := sql_execute_params(
			host.store,
			"UPDATE _reducer SET kind = ?, params = ? WHERE name = ?",
			values,
		)
		return update_err
	}
	insert := []Value{value_string(name), value_string(kind), value_string(encoded)}
	_, insert_err := sql_execute_params(
		host.store,
		"INSERT INTO _reducer (name, kind, params) VALUES (?, ?, ?)",
		insert,
	)
	return insert_err
}

// host_call runs a reducer in a new transaction and commits it. The commit also
// publishes subscription deltas.
host_call :: proc(host: ^Host, name: string, args: []Value) -> Error {
	reducer, found := host.reducers[name]
	if !found {
		return errf(.Invalid_Argument, "no reducer named %s", name)
	}
	if len(args) != len(reducer.params) {
		return errf(
			.Invalid_Argument,
			"reducer %s takes %d arguments but %d were given",
			name,
			len(reducer.params),
			len(args),
		)
	}
	coerced := make([]Value, len(args))
	defer delete(coerced)
	for param, i in reducer.params {
		value, coerce_err := value_coerce(args[i], param)
		if coerce_err.kind != .None do return coerce_err
		coerced[i] = value
	}
	tx := tx_begin_write(host.store)
	ctx := Reducer_Ctx {
		tx     = tx,
		host   = host,
		now_us = host_now(host),
	}
	if call_err := reducer.handler(&ctx, coerced); call_err.kind != .None {
		tx_rollback(tx)
		return call_err
	}
	return tx_commit(tx)
}

// host_now returns the clock the host uses for reducers. Tests can replace it.
host_now :: proc(host: ^Host) -> i64 {
	if host.now_us != 0 do return host.now_us
	return time.now()._nsec / 1000
}

// --- Subscriptions ---------------------------------------------------------

// host_subscribe registers one SELECT and returns its first snapshot. The query
// must read exactly one table (plus optional joins).
host_subscribe :: proc(host: ^Host, sql: string) -> (id: u64, snapshot: [][]Value, err: Error) {
	snapshots: [][][]Value
	id, snapshots, err = host_subscribe_many(host, []string{sql})
	if err.kind != .None do return 0, nil, err
	snapshot = snapshots[0]
	delete(snapshots)
	return id, snapshot, ERROR_NONE
}

// host_subscribe_many registers several SELECTs under one id. Each query keeps
// its own row set and publishes its own delta, tagged with its index.
host_subscribe_many :: proc(
	host: ^Host,
	sqls: []string,
) -> (id: u64, snapshot: [][][]Value, err: Error) {
	return host_subscribe_many_owned(host, sqls, 0)
}

// host_subscribe_many_owned ties the subscription set to a connection. Owner 0
// means unowned: the caller must unsubscribe explicitly.
host_subscribe_many_owned :: proc(
	host: ^Host,
	sqls: []string,
	owner: u64,
) -> (id: u64, snapshot: [][][]Value, err: Error) {
	if len(sqls) == 0 {
		return 0, nil, errf(.Invalid_Argument, "a subscription needs at least one query")
	}
	subscription := new(Subscription)
	subscription.id = host.next_subscription_id
	subscription.owner = owner
	subscription.queries = make([]Subscription_Query, len(sqls))
	for sql, i in sqls {
		query, parse_err := sql_parse(sql)
		if parse_err.kind != .None {
			free_subscription_queries(subscription.queries[:i])
			delete(subscription.queries)
			free(subscription)
			return 0, nil, parse_err
		}
		select_stmt, is_select := query.statement.(Select_Stmt)
		if !is_select {
			query_destroy(&query)
			free_subscription_queries(subscription.queries[:i])
			delete(subscription.queries)
			free(subscription)
			return 0, nil, errf(.Sql_Not_A_Query, "a subscription needs a SELECT")
		}
		subscription.queries[i].query = query
		subscription.queries[i].table = strings.clone(select_stmt.from.name)
		if len(select_stmt.joins) > 0 {
			subscription.queries[i].join_tables = make([]string, len(select_stmt.joins))
			for join, j in select_stmt.joins {
				subscription.queries[i].join_tables[j] = strings.clone(join.table.name)
			}
		}
		entry := &subscription.queries[i]
		entry.rows = make(map[string][]Value)
		entry.row_keys = make(map[Row_Id]string)
		entry.agg = host_agg_shaped(entry)
		if len(entry.join_tables) > 0 {
			entry.join = true
			if arena_err := virtual.arena_init_growing(&entry.join_arena); arena_err != .None {
				free_subscription_queries(subscription.queries[:i + 1])
				delete(subscription.queries)
				free(subscription)
				return 0, nil, errf(.Out_Of_Memory, "cannot set up a join subscription")
			}
			entry.join_allocator = virtual.arena_allocator(&entry.join_arena)
			entry.join_tuples = make(map[string]Join_Tuple)
			entry.join_by_row = make(map[Source_Row][dynamic]string)
			entry.join_counts = make(map[string]int)
		}
	}
	host.next_subscription_id += 1
	append(&host.subscriptions, subscription)

	snapshot = make([][][]Value, len(subscription.queries))
	for _, i in subscription.queries {
		rows, ids, eval_err := host_evaluate(host, subscription, i)
		if eval_err.kind != .None {
			host_unsubscribe(host, subscription.id)
			return 0, nil, eval_err
		}
		rows_out := make([][]Value, len(rows))
		for row, r in rows {
			rows_out[r] = value_row_clone(row)
			entry := &subscription.queries[i]
			key := encode_output_key_alloc(row, entry_key_alloc(entry))
			entry.rows[key] = row
			if r < len(ids) && ids[r] != NO_ROW_ID {
				entry.row_keys[ids[r]] = strings.clone(key)
			}
		}
		delete(ids)
		snapshot[i] = rows_out
		if subscription.queries[i].join {
			if !host_join_prepare(host, &subscription.queries[i]) {
				host_unsubscribe(host, subscription.id)
				return 0, nil, errf(.Internal, "cannot index a join subscription")
			}
		} else if subscription.queries[i].agg {
			if !host_agg_prepare(host, &subscription.queries[i]) {
				host_unsubscribe(host, subscription.id)
				return 0, nil, errf(.Internal, "cannot index an aggregate subscription")
			}
		}
	}
	return subscription.id, snapshot, ERROR_NONE
}

// host_drop_owned removes every subscription created by one connection and
// reports how many it dropped. Owner 0 (unowned) is never touched.
host_drop_owned :: proc(host: ^Host, owner: u64) -> int {
	if owner == 0 do return 0
	dropped := 0
	for i := len(host.subscriptions) - 1; i >= 0; i -= 1 {
		subscription := host.subscriptions[i]
		if subscription.owner != owner do continue
		free_subscription_queries(subscription.queries)
		delete(subscription.queries)
		free(subscription)
		ordered_remove_slice(&host.subscriptions, i)
		dropped += 1
	}
	return dropped
}

host_unsubscribe :: proc(host: ^Host, id: u64) -> bool {
	for subscription, i in host.subscriptions {
		if subscription.id != id do continue
		free_subscription_queries(subscription.queries)
		delete(subscription.queries)
		free(subscription)
		ordered_remove_slice(&host.subscriptions, i)
		return true
	}
	return false
}

@(private)
free_subscription_queries :: proc(queries: []Subscription_Query) {
	for &entry in queries {
		for _, row in entry.rows do free_values(row)
		delete(entry.rows)
		if entry.join {
			// The row keys and the tuple index are arena allocations: they go away
			// together, and freeing them one by one would be a double free.
			virtual.arena_destroy(&entry.join_arena)
			delete(entry.join_tuples)
			delete(entry.join_by_row)
			delete(entry.join_counts)
		}
		if entry.agg {
			for _, group in entry.agg_groups {
				free_values(group.published)
				delete(group.rows)
			}
			delete(entry.agg_groups)
			for _, key in entry.agg_by_row do delete(key)
			delete(entry.agg_by_row)
		}
		for _, key in entry.row_keys do delete(key)
		delete(entry.row_keys)
		query_destroy(&entry.query)
		delete(entry.table)
		for name in entry.join_tables do delete(name)
		delete(entry.join_tables)
	}
}

// entry_key_alloc is the allocator that owns the keys of a query's row cache.
@(private)
entry_key_alloc :: proc(entry: ^Subscription_Query) -> mem.Allocator {
	if entry.join do return entry.join_allocator
	return context.allocator
}

// --- Incremental joins ------------------------------------------------------

// host_join_key concatenates the row ids of a tuple into one map key.
@(private)
host_join_key :: proc(ids: []Row_Id, alloc: mem.Allocator) -> string {
	bytes := make([]u8, len(ids) * 8, alloc)
	for id, index in ids {
		value := u64(id)
		for shift in 0 ..< 8 {
			bytes[index * 8 + shift] = u8(value >> u64(56 - shift * 8))
		}
	}
	return string(bytes)
}

// host_join_index_row records that a row takes part in a tuple.
@(private)
host_join_index_row :: proc(
	entry: ^Subscription_Query,
	source: int,
	id: Row_Id,
	key: string,
) {
	// The per-row list grows inside the arena, so it is released with the
	// subscription instead of element by element.
	previous := context.allocator
	context.allocator = entry.join_allocator
	row := Source_Row{source = source, id = id}
	list := entry.join_by_row[row]
	append(&list, key)
	entry.join_by_row[row] = list
	context.allocator = previous
}

// host_join_remove_row drops every tuple a stored row takes part in. It is the
// whole delete path: the cached row goes away only when the last tuple that
// projected to it is gone, so two combinations with the same output keep one
// row in the cache.
@(private)
host_join_remove_row :: proc(
	entry: ^Subscription_Query,
	source: int,
	id: Row_Id,
	deletes: ^[dynamic][]Value,
) {
	row := Source_Row{source = source, id = id}
	keys, had := entry.join_by_row[row]
	if !had do return
	for key in keys {
		tuple, exists := entry.join_tuples[key]
		if !exists do continue
		count := entry.join_counts[tuple.output]
		if count <= 1 {
			delete_key(&entry.join_counts, tuple.output)
			if cached, present := entry.rows[tuple.output]; present {
				if deletes != nil do append(deletes, value_row_clone(cached))
				free_values(cached)
				delete_key(&entry.rows, tuple.output)
			}
		} else {
			entry.join_counts[tuple.output] = count - 1
		}
		delete_key(&entry.join_tuples, key)
	}
	delete_key(&entry.join_by_row, row)
}

// host_join_add records one tuple and, when it is the first to project to its
// output row, publishes the insert.
@(private)
host_join_add :: proc(
	entry: ^Subscription_Query,
	sources: []Source,
	projected: []Value,
	inserts: ^[dynamic][]Value,
) {
	ids := make([]Row_Id, len(sources), entry.join_allocator)
	for source, i in sources do ids[i] = source.row.id
	key := host_join_key(ids, entry.join_allocator)
	if _, seen := entry.join_tuples[key]; seen {
		// The same tuple cannot be recorded twice; drop the fresh copy.
		free_values(projected)
		return
	}
	output := encode_output_key_alloc(projected, entry.join_allocator)
	entry.join_tuples[key] = Join_Tuple{ids = ids, output = output}
	for id, source in ids do host_join_index_row(entry, source, id, key)
	count := entry.join_counts[output]
	entry.join_counts[output] = count + 1
	if count > 0 {
		free_values(projected)
		return
	}
	entry.rows[output] = projected
	if inserts != nil do append(inserts, value_row_clone(projected))
}

// host_project_sources evaluates the WHERE and the projection of a query over an
// already bound combination of sources. The result is owned by the caller.
@(private)
host_project_sources :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	expanded: []^Expr,
	sources: []Source,
) -> (values: []Value, matched: bool, err: Error) {
	ctx := Eval_Ctx {
		tx     = tx,
		now_us = now_microseconds(),
	}
	ctx.sources = sources
	if stmt.where_clause != nil {
		value, eval_err := eval_expr(&ctx, stmt.where_clause)
		if eval_err.kind != .None do return nil, false, eval_err
		if !value_is_truthy(value) do return nil, false, ERROR_NONE
	}
	out := make([]Value, len(expanded))
	for expr, i in expanded {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None {
			free_values(out[:i])
			return nil, false, eval_err
		}
		out[i] = value_clone(value, context.allocator)
	}
	return out, true, ERROR_NONE
}

// Join_Walk carries the state of one enumeration of joined rows.
@(private)
Join_Walk :: struct {
	entry:    ^Subscription_Query,
	tx:       ^Tx,
	stmt:     Select_Stmt,
	expanded: []^Expr,
	tables:   []^Table,
	aliases:  []string,
	rows:     [][]Row,
	sources:  []Source,
	// fixed is the source that holds the row the commit changed, or -1 when the
	// enumeration walks every table (the rebuild).
	fixed:    int,
	fixed_id: Row_Id,
	inserts:  ^[dynamic][]Value,
}

// host_join_walk enumerates one combination of source rows at a time, fixing the
// changed row when the commit asked for it.
@(private)
host_join_walk :: proc(walk: ^Join_Walk, level: int) -> bool {
	if level == len(walk.tables) {
		return host_join_emit(walk)
	}
	if level == walk.fixed {
		table := walk.tables[level]
		row, exists := table.rows[walk.fixed_id]
		if !exists do return true
		walk.sources[level] = Source{table = table, row = row, alias = walk.aliases[level]}
		return host_join_walk(walk, level + 1)
	}
	for row in walk.rows[level] {
		if walk.tx.store.cancelled do return false
		walk.sources[level] = Source{
			table = walk.tables[level],
			row   = row,
			alias = walk.aliases[level],
		}
		if !host_join_walk(walk, level + 1) do return false
	}
	return true
}

// host_join_emit tests the join conditions over a bound combination and records
// it when it matches the WHERE and the projection.
@(private)
host_join_emit :: proc(walk: ^Join_Walk) -> bool {
	ctx := Eval_Ctx {
		tx     = walk.tx,
		now_us = now_microseconds(),
	}
	ctx.sources = walk.sources
	for join in walk.stmt.joins {
		if join.on == nil do continue
		value, eval_err := eval_expr(&ctx, join.on)
		if eval_err.kind != .None do return false
		if !value_is_truthy(value) do return true
	}
	projected, matched, eval_err := host_project_sources(
		walk.tx,
		walk.stmt,
		walk.expanded,
		walk.sources,
	)
	if eval_err.kind != .None do return false
	if !matched do return true
	host_join_add(walk.entry, walk.sources, projected, walk.inserts)
	return true
}

// --- Incremental aggregates -------------------------------------------------

// host_agg_shaped reports whether a query has the aggregate shape the group
// table handles: one table, optional grouping, no HAVING, ordering or limits.
@(private)
host_agg_shaped :: proc(entry: ^Subscription_Query) -> bool {
	stmt, ok := entry.query.statement.(Select_Stmt)
	if !ok || len(entry.join_tables) > 0 || len(stmt.joins) > 0 do return false
	if stmt.having != nil || stmt.is_distinct do return false
	if len(stmt.order_by) > 0 || stmt.limit != nil || stmt.offset != nil do return false
	if len(stmt.compound) > 0 do return false
	for item in stmt.projections {
		if item.expr == nil do continue
		if _, is_window := item.expr^.(Window_Expr); is_window do return false
	}
	if len(stmt.group_by) == 0 {
		// Without GROUP BY it is only an aggregate if some projection is one.
		for item in stmt.projections {
			if item.expr != nil && expr_is_aggregate(item.expr) do return true
		}
		return false
	}
	return true
}

// host_agg_key evaluates the GROUP BY expressions over one bound row. An empty
// grouping (the whole table) has the empty key.
@(private)
host_agg_key :: proc(tx: ^Tx, stmt: Select_Stmt, source: Source) -> (key: string, ok: bool) {
	if len(stmt.group_by) == 0 do return "", true
	ctx := Eval_Ctx {
		tx     = tx,
		now_us = now_microseconds(),
	}
	ctx.sources = []Source{source}
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for expr in stmt.group_by {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None do return "", false
		value_encode_key(&w, value)
	}
	return strings.clone(string(bw_bytes(&w))), true
}

// host_agg_matches applies the WHERE of the query to one bound row.
@(private)
host_agg_matches :: proc(tx: ^Tx, stmt: Select_Stmt, source: Source) -> bool {
	if stmt.where_clause == nil do return true
	ctx := Eval_Ctx {
		tx     = tx,
		now_us = now_microseconds(),
	}
	ctx.sources = []Source{source}
	value, eval_err := eval_expr(&ctx, stmt.where_clause)
	if eval_err.kind != .None do return false
	return value_is_truthy(value)
}

// host_agg_values evaluates the projection of a group. `group` holds one source
// slice per row, exactly like the executor builds it.
@(private)
host_agg_values :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	expanded: []^Expr,
	group: [][]Source,
) -> (values: []Value, ok: bool) {
	ctx := Eval_Ctx {
		tx     = tx,
		now_us = now_microseconds(),
	}
	ctx.group = group
	ctx.grouped = true
	if len(group) > 0 do ctx.sources = group[0]
	out := make([]Value, len(expanded))
	for expr, i in expanded {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None {
			free_values(out[:i])
			for item in group do delete(item)
			return nil, false
		}
		out[i] = value_clone(value, context.allocator)
	}
	for item in group do delete(item)
	return out, true
}

// host_agg_group_sources binds the rows a group names, skipping the ones the
// read transaction cannot see (a row a commit just deleted).
@(private)
host_agg_group_sources :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	base: ^Table,
	ids: []Row_Id,
) -> [][]Source {
	group := make([dynamic][]Source, 0, len(ids))
	for id in ids {
		row, exists := base.rows[id]
		if !exists do continue
		if _, visible := row_values_at(row, tx.read_seq); !visible do continue
		one := make([]Source, 1)
		one[0] = Source{table = base, row = row, alias = stmt.from.alias}
		append(&group, one)
	}
	return group[:]
}

// host_agg_publish compares a fresh group row with the one the subscriber has
// and publishes the difference.
@(private)
host_agg_publish :: proc(
	entry: ^Subscription_Query,
	group: ^Agg_Group,
	values: []Value,
	found: bool,
	inserts: ^[dynamic][]Value,
	deletes: ^[dynamic][]Value,
) {
	present := found && values != nil
	unchanged := group.found == present
	if unchanged && present {
		unchanged = len(group.published) == len(values)
		if unchanged {
			for value, i in values {
				if !value_equal(group.published[i], value) {
					unchanged = false
					break
				}
			}
		}
	}
	if unchanged {
		if values != nil do free_values(values)
		return
	}
	if group.found {
		if deletes != nil do append(deletes, value_row_clone(group.published))
		// The row cache a fallback diffs against has to follow the deltas.
		cached_key := encode_output_key(group.published)
		if cached, exists := entry.rows[cached_key]; exists {
			free_values(cached)
			delete_key(&entry.rows, cached_key)
		}
		delete(cached_key)
		free_values(group.published)
		group.published = nil
		group.found = false
	}
	if present {
		group.published = value_row_clone(values)
		group.found = true
		entry.rows[encode_output_key(values)] = value_row_clone(values)
		if inserts != nil do append(inserts, value_row_clone(values))
	}
	if values != nil do free_values(values)
}

// host_agg_recompute evaluates one group from the rows it names.
@(private)
host_agg_recompute :: proc(
	entry: ^Subscription_Query,
	tx: ^Tx,
	stmt: Select_Stmt,
	expanded: []^Expr,
	base: ^Table,
	group: ^Agg_Group,
	inserts, deletes: ^[dynamic][]Value,
) {
	ids := make([dynamic]Row_Id, 0, len(group.rows), tx.alloc)
	defer delete(ids)
	for id, _ in group.rows do append(&ids, id)
	sources := host_agg_group_sources(tx, stmt, base, ids[:])
	if len(sources) == 0 {
		delete(sources)
		host_agg_publish(entry, group, nil, false, inserts, deletes)
		return
	}
	values, ok := host_agg_values(tx, stmt, expanded, sources)
	delete(sources)
	host_agg_publish(entry, group, values, ok, inserts, deletes)
}

// host_agg_prepare builds the group table from the current state. Like the join
// index it never runs in the middle of a commit, so it cannot swallow a delta.
@(private)
host_agg_prepare :: proc(host: ^Host, entry: ^Subscription_Query) -> bool {
	stmt, is_select := entry.query.statement.(Select_Stmt)
	if !is_select do return false
	for _, group in entry.agg_groups do free_values(group.published)
	delete(entry.agg_groups)
	entry.agg_groups = make(map[string]Agg_Group)
	delete(entry.agg_by_row)
	entry.agg_by_row = make(map[Row_Id]string)

	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	base, table_err := tx_table(tx, stmt.from.name)
	if table_err.kind != .None do return false
	star := make([]Source, 1, tx.alloc)
	defer delete(star)
	star[0] = Source{table = base, alias = stmt.from.alias}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(star, stmt.projections, &columns, tx.alloc)
	defer {
		for column in columns do delete(column)
		delete(columns)
	}
	live := make([dynamic]Row)
	if collect_err := tx_collect(tx, stmt.from.name, &live); collect_err.kind != .None {
		delete(live)
		return false
	}
	defer delete(live)

	for row in live {
		source := Source{table = base, row = row, alias = stmt.from.alias}
		if !host_agg_matches(tx, stmt, source) do continue
		key, key_ok := host_agg_key(tx, stmt, source)
		if !key_ok do return false
		group, exists := entry.agg_groups[key]
		if exists {
			delete(key)
		} else {
			group.rows = make(map[Row_Id]struct{})
		}
		group.rows[row.id] = {}
		entry.agg_groups[key] = group
		entry.agg_by_row[row.id] = strings.clone(key)
	}
	for _, &group in entry.agg_groups {
		host_agg_recompute(entry, tx, stmt, expanded, base, &group, nil, nil)
	}
	entry.agg_ready = true
	return true
}

// host_agg_drop_group publishes the disappearance of a group and removes it.
@(private)
host_agg_drop_group :: proc(
	entry: ^Subscription_Query,
	key: string,
	deletes: ^[dynamic][]Value,
) {
	group, exists := entry.agg_groups[key]
	if !exists do return
	if group.found && deletes != nil do append(deletes, value_row_clone(group.published))
	free_values(group.published)
	delete_key(&entry.agg_groups, key)
	for id, _ in group.rows do delete_key(&entry.agg_by_row, id)
	delete(group.rows)

}

// host_agg_recompute_whole evaluates the single group of a query without GROUP
// BY: every live row that passes the WHERE.
@(private)
host_agg_recompute_whole :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	expanded: []^Expr,
	base: ^Table,
	entry: ^Subscription_Query,
	inserts, deletes: ^[dynamic][]Value,
) {
	live := make([dynamic]Row)
	if collect_err := tx_collect(tx, stmt.from.name, &live); collect_err.kind != .None {
		delete(live)
		return
	}
	defer delete(live)
	group, exists := entry.agg_groups[""]
	if !exists do group.rows = make(map[Row_Id]struct{})
	sources := make([dynamic][]Source, 0, len(live))
	for row in live {
		source := Source{table = base, row = row, alias = stmt.from.alias}
		if !host_agg_matches(tx, stmt, source) do continue
		one := make([]Source, 1)
		one[0] = source
		append(&sources, one)
	}
	values, ok := host_agg_values(tx, stmt, expanded, sources[:])
	delete(sources)
	if !ok do return
	host_agg_publish(entry, &group, values, true, inserts, deletes)
	entry.agg_groups[""] = group
}

// host_apply_incremental_aggregate publishes aggregate deltas from the groups a
// commit touches, recomputing each group once from the rows it names.
@(private)
host_apply_incremental_aggregate :: proc(
	host: ^Host,
	subscription: ^Subscription,
	entry: ^Subscription_Query,
	index: int,
	ops: []Store_Op,
) -> bool {
	stmt, is_select := entry.query.statement.(Select_Stmt)
	if !is_select || !entry.agg || !host_agg_shaped(entry) do return false
	if !entry.agg_ready do return false
	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	base, table_err := tx_table(tx, stmt.from.name)
	if table_err.kind != .None do return false
	policies, policy_err := policy_load(tx, stmt.from.name)
	if policy_err.kind != .None do return false
	active := len(policies.using_exprs) > 0
	policy_set_destroy(&policies)
	if active do return false
	star := make([]Source, 1, tx.alloc)
	defer delete(star)
	star[0] = Source{table = base, alias = stmt.from.alias}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(star, stmt.projections, &columns, tx.alloc)
	defer {
		for column in columns do delete(column)
		delete(columns)
	}

	inserts := make([dynamic][]Value)
	deletes := make([dynamic][]Value)
	defer {
		for row in inserts do free_values(row)
		for row in deletes do free_values(row)
		delete(inserts)
		delete(deletes)
	}
	touched := make([dynamic]string)
	defer {
		for key in touched do delete(key)
		delete(touched)
	}
	touch :: proc(touched: ^[dynamic]string, key: string) {
		for existing in touched^ {
			if strings.compare(existing, key) == 0 do return
		}
		append(touched, strings.clone(key))
	}
	any_op := false
	for op in ops {
		if !strings.equal_fold(op.name, stmt.from.name) do continue
		switch op.kind {
		case .Insert, .Update, .Delete:
			any_op = true
			old_key, had_old := entry.agg_by_row[op.row_id]
			matched := false
			new_key := ""
			if op.kind != .Delete {
				if row, exists := base.rows[op.row_id]; exists {
					source := Source{table = base, row = row, alias = stmt.from.alias}
					if host_agg_matches(tx, stmt, source) {
						if key, key_ok := host_agg_key(tx, stmt, source); key_ok {
							matched = true
							new_key = key
						} else {
							return false
						}
					}
				}
			}
			if had_old {
				touch(&touched, old_key)
				if group, exists := entry.agg_groups[old_key]; exists {
					delete_key(&group.rows, op.row_id)
					entry.agg_groups[old_key] = group
				}
				delete_key(&entry.agg_by_row, op.row_id)
			}
			if matched {
				touch(&touched, new_key)
				group, exists := entry.agg_groups[new_key]
				if exists {
					delete(new_key)
				} else {
					group.rows = make(map[Row_Id]struct{})
				}
				group.rows[op.row_id] = {}
				entry.agg_groups[new_key] = group
				entry.agg_by_row[op.row_id] = strings.clone(new_key)
			} else {
				delete(new_key)
			}
		case .Create_Table, .Truncate, .Drop_Table, .Create_Index, .Drop_Index, .Alter_Table:
			return false
		}
	}
	if !any_op do return true
	for key in touched {
		if entry.agg_whole {
			host_agg_recompute_whole(tx, stmt, expanded, base, entry, &inserts, &deletes)
			continue
		}
		group, exists := entry.agg_groups[key]
		if !exists do continue
		if len(group.rows) == 0 {
			host_agg_drop_group(entry, key, &deletes)
			continue
		}
		host_agg_recompute(entry, tx, stmt, expanded, base, &group, &inserts, &deletes)
		entry.agg_groups[key] = group
	}
	if len(inserts) == 0 && len(deletes) == 0 do return true
	host.incremental_updates += 1
	if host.on_update != nil {
		update := Subscription_Update {
			subscription_id = subscription.id,
			query           = index,
			table           = entry.table,
			inserts         = inserts[:],
			deletes         = deletes[:],
		}
		host.on_update(host.on_update_ctx, &update)
	}
	return true
}
// host_join_prepare indexes a join query from the current state. It runs when
// the subscription is created and after a fallback re-evaluation, never in the
// middle of a row operation: a rebuild already contains the rows a commit just
// wrote, so doing it there would swallow that commit's deltas.
@(private)
host_join_prepare :: proc(host: ^Host, entry: ^Subscription_Query) -> bool {
	stmt, is_select := entry.query.statement.(Select_Stmt)
	if !is_select do return false
	source_count := 1 + len(stmt.joins)
	tables := make([]^Table, source_count)
	rows := make([][]Row, source_count)
	aliases := make([]string, source_count)
	defer {
		for list in rows do delete(list)
		delete(rows)
		delete(tables)
		delete(aliases)
	}
	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	if !host_join_tables(tx, stmt, tables, rows, aliases) do return false
	star := make([]Source, source_count, tx.alloc)
	defer delete(star)
	for table, i in tables do star[i] = Source{table = table, alias = aliases[i]}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(star[:], stmt.projections, &columns, tx.alloc)
	defer {
		for column in columns do delete(column)
		delete(columns)
	}
	return host_join_rebuild(host, tx, entry, stmt, tables, aliases, rows, expanded)
}

// host_join_rebuild derives the tuple index and the row cache from scratch. It
// runs on the first commit that touches a join subscription and again after any
// fallback re-evaluation.
@(private)
host_join_rebuild :: proc(
	host: ^Host,
	tx: ^Tx,
	entry: ^Subscription_Query,
	stmt: Select_Stmt,
	tables: []^Table,
	aliases: []string,
	rows: [][]Row,
	expanded: []^Expr,
) -> bool {
	for _, row in entry.rows do free_values(row)
	delete(entry.rows)
	entry.rows = make(map[string][]Value)
	delete(entry.join_tuples)
	entry.join_tuples = make(map[string]Join_Tuple)
	delete(entry.join_by_row)
	entry.join_by_row = make(map[Source_Row][dynamic]string)
	delete(entry.join_counts)
	entry.join_counts = make(map[string]int)
	virtual.arena_free_all(&entry.join_arena)

	sources := make([]Source, len(tables), tx.alloc)
	defer delete(sources)
	walk := Join_Walk {
		entry    = entry,
		tx       = tx,
		stmt     = stmt,
		expanded = expanded,
		tables   = tables,
		aliases  = aliases,
		rows     = rows,
		sources  = sources,
		fixed    = -1,
		inserts  = nil,
	}
	if !host_join_walk(&walk, 0) do return false
	entry.join_ready = true
	return true
}

// host_query_is_incremental_join reports whether a join query can be moved from
// the tuple index: plain projection and WHERE, no grouping, ordering or limit.
@(private)
host_query_is_incremental_join :: proc(entry: ^Subscription_Query) -> bool {
	stmt, ok := entry.query.statement.(Select_Stmt)
	if !ok || len(stmt.joins) == 0 do return false
	if len(stmt.group_by) > 0 || stmt.having != nil || stmt.is_distinct do return false
	if len(stmt.order_by) > 0 || stmt.limit != nil || stmt.offset != nil do return false
	if len(stmt.compound) > 0 do return false
	for item in stmt.projections {
		if item.star do continue
		if item.expr != nil && expr_is_aggregate(item.expr) do return false
	}
	return true
}

// host_join_tables resolves the sources of a join query and collects their live
// rows once per commit. It reports false when a source is not a plain table.
@(private)
host_join_tables :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	tables: []^Table,
	rows: [][]Row,
	aliases: []string,
) -> bool {
	for join in stmt.joins {
		if len(join.table.args) > 0 do return false
	}
	for index in 0 ..< len(tables) {
		name := index == 0 ? stmt.from.name : stmt.joins[index - 1].table.name
		alias := index == 0 ? stmt.from.alias : stmt.joins[index - 1].table.alias
		table, table_err := tx_table(tx, name)
		if table_err.kind != .None do return false
		tables[index] = table
		alias_text := alias
		if len(alias_text) == 0 do alias_text = name
		aliases[index] = alias_text
		list: [dynamic]Row
		if collect_err := tx_collect(tx, name, &list); collect_err.kind != .None {
			delete(list)
			return false
		}
		rows[index] = list[:]
	}
	return true
}

// host_apply_incremental_join publishes deltas for a join subscription from the
// rows a commit touched, without re-running the query.
@(private)
host_apply_incremental_join :: proc(
	host: ^Host,
	subscription: ^Subscription,
	entry: ^Subscription_Query,
	index: int,
	ops: []Store_Op,
) -> bool {
	stmt, is_select := entry.query.statement.(Select_Stmt)
	if !is_select || !entry.join || !host_query_is_incremental_join(entry) do return false
	source_count := 1 + len(stmt.joins)
	tables := make([]^Table, source_count)
	rows := make([][]Row, source_count)
	aliases := make([]string, source_count)
	defer {
		for list in rows do delete(list)
		delete(rows)
		delete(tables)
		delete(aliases)
	}
	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	if !host_join_tables(tx, stmt, tables, rows, aliases) do return false
	// Row policies and views need the full evaluation.
	for name_index in 0 ..< source_count {
		name := name_index == 0 ? stmt.from.name : stmt.joins[name_index - 1].table.name
		policies, policy_err := policy_load(tx, name)
		if policy_err.kind != .None do return false
		active := len(policies.using_exprs) > 0
		policy_set_destroy(&policies)
		if active do return false
	}

	star := make([]Source, source_count, tx.alloc)
	defer delete(star)
	for table, i in tables do star[i] = Source{table = table, alias = aliases[i]}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(star[:], stmt.projections, &columns, tx.alloc)
	defer {
		for column in columns do delete(column)
		delete(columns)
	}
	if len(expanded) == 0 do return false

	if !entry.join_ready do return false

	inserts := make([dynamic][]Value)
	deletes := make([dynamic][]Value)
	defer {
		for row in inserts do free_values(row)
		for row in deletes do free_values(row)
		delete(inserts)
		delete(deletes)
	}
	sources := make([]Source, source_count, tx.alloc)
	defer delete(sources)
	for op in ops {
		changed := -1
		for index_name, i in aliases {
			if strings.equal_fold(index_name, op.name) {
				changed = i
				break
			}
		}
		if changed < 0 do continue
		switch op.kind {
		case .Insert, .Update:
			host_join_remove_row(entry, changed, op.row_id, &deletes)
			walk := Join_Walk {
				entry    = entry,
				tx       = tx,
				stmt     = stmt,
				expanded = expanded,
				tables   = tables,
				aliases  = aliases,
				rows     = rows,
				sources  = sources,
				fixed    = changed,
				fixed_id = op.row_id,
				inserts  = &inserts,
			}
			if !host_join_walk(&walk, 0) do return false
		case .Delete:
			host_join_remove_row(entry, changed, op.row_id, &deletes)
		case .Create_Table, .Truncate, .Drop_Table, .Create_Index, .Drop_Index, .Alter_Table:
			return false
		}
	}
	if len(inserts) == 0 && len(deletes) == 0 do return true
	host.incremental_updates += 1
	if host.on_update != nil {
		update := Subscription_Update {
			subscription_id = subscription.id,
			query           = index,
			table           = entry.table,
			inserts         = inserts[:],
			deletes         = deletes[:],
		}
		host.on_update(host.on_update_ctx, &update)
	}
	return true
}

@(private)
ordered_remove_slice :: proc(items: ^[dynamic]^Subscription, index: int) {
	for i in index ..< len(items) - 1 {
		items[i] = items[i + 1]
	}
	pop(items)
}

// host_evaluate runs one query of a subscription set and returns its fresh rows.
@(private)
host_evaluate :: proc(
	host: ^Host,
	subscription: ^Subscription,
	index: int,
) -> (rows: [][]Value, ids: []Row_Id, err: Error) {
	select_stmt, is_select := subscription.queries[index].query.statement.(Select_Stmt)
	if !is_select {
		return nil, nil, errf(.Internal, "a subscription lost its statement")
	}
	tx := tx_begin_read(host.store)
	result, eval_err := sql_exec_select(tx, select_stmt, nil)
	tx_end(tx)
	if eval_err.kind != .None do return nil, nil, eval_err
	rows = result.rows
	ids = result.row_ids
	result.rows = nil
	result.row_ids = nil
	sql_result_destroy(&result)
	return rows, ids, ERROR_NONE
}

// host_query_is_incremental reports whether a query can be updated from row
// operations alone: one table, plain projection, optional WHERE.
@(private)
host_query_is_incremental :: proc(entry: ^Subscription_Query) -> bool {
	stmt, ok := entry.query.statement.(Select_Stmt)
	if !ok do return false
	if len(entry.join_tables) > 0 do return false
	if len(stmt.joins) > 0 || len(stmt.group_by) > 0 || stmt.having != nil do return false
	if stmt.is_distinct || len(stmt.order_by) > 0 || stmt.limit != nil || stmt.offset != nil do return false
	for item in stmt.projections {
		if item.expr != nil && expr_is_aggregate(item.expr) do return false
	}
	return true
}

// host_project_row runs one stored row through the filter and projection of a
// single-table query. It returns false when the row does not match.
@(private)
host_project_row :: proc(
	host: ^Host,
	tx: ^Tx,
	stmt: Select_Stmt,
	row: Row,
) -> (values: []Value, matched: bool, err: Error) {
	table, table_err := tx_table(tx, stmt.from.name)
	if table_err.kind != .None do return nil, false, table_err
	ctx := Eval_Ctx {
		tx     = tx,
		now_us = now_microseconds(),
	}
	source := Source{table = table, row = row, alias = stmt.from.alias}
	ctx.sources = []Source{source}
	if stmt.where_clause != nil {
		value, eval_err := eval_expr(&ctx, stmt.where_clause)
		if eval_err.kind != .None do return nil, false, eval_err
		if !value_is_truthy(value) do return nil, false, ERROR_NONE
	}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections([]Source{source}, stmt.projections, &columns, tx.alloc)
	for column in columns do delete(column)
	delete(columns)
	out := make([]Value, len(expanded))
	for expr, i in expanded {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None {
			free_values(out[:i])
			return nil, false, eval_err
		}
		out[i] = value_clone(value, context.allocator)
	}
	return out, true, ERROR_NONE
}

// host_apply_incremental turns the operations of one commit into deltas for a
// query that only projects one table. It returns false when the query needs a
// full re-evaluation, in which case it has not touched the cached rows.
@(private)
host_apply_incremental :: proc(
	host: ^Host,
	subscription: ^Subscription,
	entry: ^Subscription_Query,
	index: int,
	ops: []Store_Op,
) -> bool {
	stmt, is_select := entry.query.statement.(Select_Stmt)
	if !is_select || !host_query_is_incremental(entry) do return false
	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	policies, policy_err := policy_load(tx, entry.table)
	if policy_err.kind != .None do return false
	defer policy_set_destroy(&policies)
	if len(policies.using_exprs) > 0 do return false

	deletes := make([dynamic][]Value)
	inserts := make([dynamic][]Value)
	defer {
		for row in inserts do free_values(row)
		for row in deletes do free_values(row)
		delete(deletes)
		delete(inserts)
	}

	touched := false
	for op in ops {
		if !strings.equal_fold(op.name, entry.table) do continue
		touched = true
		switch op.kind {
		case .Insert, .Update:
			projected, matched, eval_err := host_project_row(
				host,
				tx,
				stmt,
				Row{id = op.row_id, values = op.values},
			)
			if eval_err.kind != .None {
				free_values(projected)
				return false
			}
			// The previous projection of this row, if any, becomes a delete.
			if old_key, had := entry.row_keys[op.row_id]; had {
				if cached, exists := entry.rows[old_key]; exists {
					append(&deletes, value_row_clone(cached))
					free_values(cached)
					delete_key(&entry.rows, old_key)
				}
				delete_key(&entry.row_keys, op.row_id)
				delete(old_key)
			}
			if matched {
				key := encode_output_key(projected)
				if cached, exists := entry.rows[key]; exists do free_values(cached)
				entry.rows[key] = projected
				entry.row_keys[op.row_id] = strings.clone(key)
				append(&inserts, value_row_clone(projected))
			} else {
				free_values(projected)
			}
		case .Delete:
			if old_key, had := entry.row_keys[op.row_id]; had {
				if cached, exists := entry.rows[old_key]; exists {
					append(&deletes, value_row_clone(cached))
					free_values(cached)
					delete_key(&entry.rows, old_key)
				}
				delete_key(&entry.row_keys, op.row_id)
				delete(old_key)
			}
		case .Create_Table, .Truncate, .Drop_Table, .Create_Index, .Drop_Index, .Alter_Table:
			// Table or index DDL: the query needs a full re-evaluation.
			return false
		}
	}
	if !touched do return true
	if len(deletes) == 0 && len(inserts) == 0 do return true
	host.incremental_updates += 1
	if host.on_update != nil {
		update := Subscription_Update {
			subscription_id = subscription.id,
			query           = index,
			table           = entry.table,
			inserts         = inserts[:],
			deletes         = deletes[:],
		}
		host.on_update(host.on_update_ctx, &update)
	}
	return true
}

// host_on_commit refreshes every query whose tables changed and publishes one
// delta per query.
host_on_commit :: proc(ctx: rawptr, store: ^Store, ops: []Store_Op) {
	host := (^Host)(ctx)
	if host == nil do return
	changed_tables := make([dynamic]string)
	defer delete(changed_tables)
	for op in ops {
		known := false
		for name in changed_tables {
			if strings.equal_fold(name, op.name) {
				known = true
				break
			}
		}
		if !known do append(&changed_tables, op.name)
	}
	for subscription in host.subscriptions {
		for &entry, i in subscription.queries {
			changed := false
			for name in changed_tables {
				if strings.equal_fold(name, entry.table) {
					changed = true
					break
				}
				for joined in entry.join_tables {
					if strings.equal_fold(name, joined) {
						changed = true
						break
					}
				}
				if changed do break
			}
			if !changed do continue
			if host_apply_incremental(host, subscription, &entry, i, ops) {
				continue
			}
			if host_apply_incremental_join(host, subscription, &entry, i, ops) {
				continue
			}
			if host_apply_incremental_aggregate(host, subscription, &entry, i, ops) {
				continue
			}
			rows, ids, eval_err := host_evaluate(host, subscription, i)
			if eval_err.kind != .None do continue

			// Diff the new row set against the previous one. Rows are identified
			// by the full projected row: a changed row shows up as a delete plus
			// an insert, which is what a client needs to update its cache.
			// The full evaluation is the fallback, so the tuple index of a join
			// is stale from here on: it is rebuilt from the fresh rows.
			entry.join_ready = false
			old := entry.rows
			next := make(map[string][]Value, len(rows))
			next_keys := make(map[Row_Id]string)
			for row, r in rows {
				key := encode_output_key_alloc(row, entry_key_alloc(&entry))
				next[key] = row
				if r < len(ids) && ids[r] != NO_ROW_ID do next_keys[ids[r]] = strings.clone(key)
			}
			delete(ids)
			inserts := make([dynamic][]Value)
			for key, row in next {
				if _, existed := old[key]; !existed {
					append(&inserts, value_row_clone(row))
				}
			}
			deletes := make([dynamic][]Value)
			for key, row in old {
				if _, kept := next[key]; kept {
					free_values(row)
				} else {
					append(&deletes, value_row_clone(row))
					free_values(row)
				}
				// A join query keeps its row keys in the arena.
				if !entry.join do delete(key)
			}
			delete(old)
			entry.rows = next
			for _, key in entry.row_keys do delete(key)
			delete(entry.row_keys)
			entry.row_keys = next_keys
			if entry.join && !host_join_prepare(host, &entry) {
				entry.join_ready = false
			}
			if entry.agg {
				entry.agg_ready = false
				if !host_agg_prepare(host, &entry) {
					entry.agg_ready = false
				}
			}

			if host.on_update != nil && (len(inserts) > 0 || len(deletes) > 0) {
				update := Subscription_Update {
					subscription_id = subscription.id,
					query           = i,
					table           = entry.table,
					inserts         = inserts[:],
					deletes         = deletes[:],
				}
				host.on_update(host.on_update_ctx, &update)
			}
			for row in inserts do free_values(row)
			for row in deletes do free_values(row)
			delete(inserts)
			delete(deletes)
		}
	}
}

// Value_Row_Clone clones one result row with its own allocator.
Value_Row_Clone :: proc(row: []Value, alloc: mem.Allocator) -> []Value {
	out := make([]Value, len(row), alloc)
	for value, i in row do out[i] = value_clone(value, alloc)
	return out
}

value_row_clone :: proc(row: []Value) -> []Value {
	return clone_values(row)
}

// --- Reducer helpers -------------------------------------------------------

// reducer_sql runs a statement inside the reducer's transaction.
reducer_sql :: proc(ctx: ^Reducer_Ctx, sql: string) -> Error {
	_, exec_err := sql_execute_in_tx(ctx.tx, sql)
	return exec_err
}

// reducer_sql_params runs a statement with positional bind parameters.
reducer_sql_params :: proc(ctx: ^Reducer_Ctx, sql: string, params: []Value) -> Error {
	_, exec_err := sql_execute_in_tx_params(ctx.tx, sql, params)
	return exec_err
}

// reducer_query runs a SELECT inside the reducer's transaction.
reducer_query :: proc(ctx: ^Reducer_Ctx, sql: string) -> (Sql_Result, Error) {
	return sql_execute_in_tx(ctx.tx, sql)
}

// --- Utilities -------------------------------------------------------------

host_reducer_names :: proc(host: ^Host, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(host.reducers), alloc)
	for name in host.reducers do append(&names, name)
	return names[:]
}

// --- Scheduler -------------------------------------------------------------

// SCHEDULE_TABLE holds reducers waiting for their time. The engine creates it
// lazily, so a database that never schedules anything pays nothing.
SCHEDULE_TABLE :: "_schedule"

host_ensure_schedule :: proc(host: ^Host) -> Error {
	exists := false
	has_interval := false
	tx := tx_begin_read(host.store)
	if table, table_err := tx_table(tx, SCHEDULE_TABLE); table_err.kind == .None {
		exists = true
		_, has_interval = schema_column_index(&table.schema, "interval_us")
	}
	tx_end(tx)
	if exists && !has_interval {
		// Internal table from before intervals existed: recreate it. Pending
		// schedules are lost, which is acceptable for a table the host owns.
		if _, drop_err := sql_execute(host.store, "DROP TABLE _schedule"); drop_err.kind != .None {
			return drop_err
		}
		exists = false
	}
	if exists do return ERROR_NONE
	_, create_err := sql_execute(host.store, `
		CREATE TABLE IF NOT EXISTS _schedule (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			reducer TEXT NOT NULL,
			at_us INTEGER NOT NULL,
			interval_us INTEGER NOT NULL DEFAULT 0,
			args BLOB NOT NULL
		)`)
	return create_err
}

// host_schedule runs `reducer` with `args` at the given host time
// (microseconds since the Unix epoch). It returns the schedule row id.
host_schedule :: proc(host: ^Host, reducer: string, at_us: i64, args: []Value) -> (Row_Id, Error) {
	return host_schedule_at(host, reducer, at_us, 0, args)
}

// host_schedule_in is host_schedule relative to now.
host_schedule_in :: proc(host: ^Host, reducer: string, delay_us: i64, args: []Value) -> (Row_Id, Error) {
	return host_schedule(host, reducer, host_now(host) + delay_us, args)
}

// host_schedule_now is an immediate schedule: the next host_tick runs it.
host_schedule_now :: proc(host: ^Host, reducer: string, args: []Value) -> (Row_Id, Error) {
	return host_schedule_at(host, reducer, host_now(host), 0, args)
}

// host_schedule_every runs `reducer` every `interval_us` microseconds, starting
// one interval from now. The row stays in `_schedule` and its time advances.
host_schedule_every :: proc(
	host: ^Host,
	reducer: string,
	interval_us: i64,
	args: []Value,
) -> (Row_Id, Error) {
	if interval_us <= 0 {
		return 0, errf(.Invalid_Argument, "a schedule interval must be positive")
	}
	return host_schedule_at(host, reducer, host_now(host) + interval_us, interval_us, args)
}

@(private)
host_schedule_at :: proc(
	host: ^Host,
	reducer: string,
	at_us: i64,
	interval_us: i64,
	args: []Value,
) -> (Row_Id, Error) {
	if _, registered := host.reducers[reducer]; !registered {
		return 0, errf(.Invalid_Argument, "no reducer named %s", reducer)
	}
	if ensure_err := host_ensure_schedule(host); ensure_err.kind != .None {
		return 0, ensure_err
	}
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	value_encode(&w, value_product(args))
	payload := make([]u8, len(w.data))
	copy(payload, w.data[:])
	defer delete(payload)

	insert := make([]Value, 4)
	insert[0] = value_string(reducer)
	insert[1] = value_int(at_us)
	insert[2] = value_int(interval_us)
	insert[3] = value_bytes(payload)
	_, exec_err := sql_execute_params(
		host.store,
		"INSERT INTO _schedule (reducer, at_us, interval_us, args) VALUES (?, ?, ?, ?)",
		insert,
	)
	if exec_err.kind != .None do return 0, exec_err
	result, select_err := sql_execute_params(
		host.store,
		"SELECT id FROM _schedule WHERE reducer = ? AND at_us = ? AND interval_us = ? ORDER BY id DESC LIMIT 1",
		[]Value{value_string(reducer), value_int(at_us), value_int(interval_us)},
	)
	if select_err.kind != .None do return 0, select_err
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return 0, ERROR_NONE
	return Row_Id(result.rows[0][0].i), ERROR_NONE
}

// host_tick runs every scheduled reducer whose time has come, earliest first.
// Each call runs in its own transaction. A one-shot row is removed after it
// runs; a repeating row moves to its next time. A broken reducer skips its
// occurrence (or loses its one-shot row) and is reported, so the loop always
// makes progress.
host_tick :: proc(host: ^Host, now_us: i64) -> (ran: int, first_error: Error) {
	if ensure_err := host_ensure_schedule(host); ensure_err.kind != .None {
		return 0, ensure_err
	}
	due, query_err := sql_execute_params(
		host.store,
		"SELECT id, reducer, args, at_us, interval_us FROM _schedule WHERE at_us <= ? ORDER BY at_us, id",
		[]Value{value_int(now_us)},
	)
	if query_err.kind != .None do return 0, query_err
	defer sql_result_destroy(&due)

	for row in due.rows {
		if host.store.cancelled {
			first_error = errf(.Cancelled, "scheduler cancelled")
			break
		}
		id := row[0].i
		reducer_name := row[1].s
		payload := row[2].bytes
		at_us := row[3].i
		interval_us := row[4].i

		r: Byte_Reader
		br_init(&r, payload)
		encoded := value_decode(&r, context.temp_allocator)
		if r.bad {
			first_error = errf(.Corrupt_Log, "scheduled call of %s has corrupt arguments", reducer_name)
			host_reschedule_or_drop(host, id, at_us, interval_us, now_us)
			continue
		}
		args := encoded.kind == .Product ? encoded.list : []Value{encoded}

		reducer, registered := host.reducers[reducer_name]
		if !registered {
			first_error = errf(.Invalid_Argument, "scheduled reducer %s is not registered", reducer_name)
			host_reschedule_or_drop(host, id, at_us, interval_us, now_us)
			ran += 1
			continue
		}

		tx := tx_begin_write(host.store)
		move_err: Error
		if interval_us > 0 {
			// Move the row before calling: the reducer must not see its own call
			// as due, and the next occurrence commits with its changes.
			move_err = reschedule_schedule_row(tx, id, next_schedule_time(at_us, interval_us, now_us))
		} else {
			move_err = delete_schedule_row(tx, id)
		}
		if move_err.kind != .None {
			tx_rollback(tx)
			first_error = move_err
			continue
		}
		ctx := Reducer_Ctx{tx = tx, host = host, now_us = now_us}
		call_err := reducer.handler(&ctx, args)
		if call_err.kind != .None {
			tx_rollback(tx)
			first_error = call_err
			// The row survived the rollback; skip this occurrence so a broken
			// reducer cannot wedge the scheduler.
			host_reschedule_or_drop(host, id, at_us, interval_us, now_us)
			ran += 1
			continue
		}
		if commit_err := tx_commit(tx); commit_err.kind != .None {
			tx_rollback(tx)
			first_error = commit_err
			continue
		}
		ran += 1
	}
	return ran, first_error
}

// next_schedule_time advances `at_us` by whole intervals until it is past now,
// so a delayed tick runs once instead of bursting every missed occurrence.
@(private)
next_schedule_time :: proc(at_us, interval_us, now_us: i64) -> i64 {
	if interval_us <= 0 do return at_us
	next := at_us
	if next <= now_us {
		missed := (now_us - next) / interval_us + 1
		next += missed * interval_us
	}
	return next
}

@(private)
delete_schedule_row :: proc(tx: ^Tx, id: i64) -> Error {
	_, err := sql_execute_in_tx_params(tx, "DELETE FROM _schedule WHERE id = ?", []Value{value_int(id)})
	return err
}

@(private)
reschedule_schedule_row :: proc(tx: ^Tx, id, at_us: i64) -> Error {
	_, err := sql_execute_in_tx_params(
		tx,
		"UPDATE _schedule SET at_us = ? WHERE id = ?",
		[]Value{value_int(at_us), value_int(id)},
	)
	return err
}

@(private)
host_drop_schedule_row :: proc(host: ^Host, id: i64) {
	tx := tx_begin_write(host.store)
	if err := delete_schedule_row(tx, id); err.kind != .None {
		tx_rollback(tx)
		return
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None {
		host.store.last_error = commit_err
	}
}

// host_reschedule_or_drop keeps a repeating row alive after a failure and drops
// a one-shot row, mirroring what host_tick does on its happy path.
@(private)
host_reschedule_or_drop :: proc(host: ^Host, id: i64, at_us, interval_us, now_us: i64) {
	if interval_us <= 0 {
		host_drop_schedule_row(host, id)
		return
	}
	tx := tx_begin_write(host.store)
	if err := reschedule_schedule_row(tx, id, next_schedule_time(at_us, interval_us, now_us)); err.kind != .None {
		tx_rollback(tx)
		return
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None {
		host.store.last_error = commit_err
	}
}

// host_set_work_budget puts a ceiling on the rows a single call may read or
// write. Zero removes it. The counter is charged per row read and per row
// written, which is the work that a runaway reducer actually does.
host_set_work_budget :: proc(host: ^Host, units: u64) {
	host.max_work_units = units
}

// host_work_units_last reports what the previous call spent.
host_work_units_last :: proc(host: ^Host) -> u64 {
	return host.work_units_last
}

// --- Idempotent calls ------------------------------------------------------

// REQUEST_TABLE remembers the request ids that already ran, so a client can
// retry after a lost response without applying the call twice.
REQUEST_TABLE :: "_request"

host_ensure_request_table :: proc(host: ^Host) -> Error {
	if _, exists := host.store.tables[REQUEST_TABLE]; exists do return ERROR_NONE
	_, create_err := sql_execute(host.store, `
		CREATE TABLE IF NOT EXISTS _request (
			id BLOB PRIMARY KEY,
			response BLOB NOT NULL
		)`)
	return create_err
}

// host_call_once runs a reducer at most once per request id. The id is recorded
// in the same transaction as the reducer's changes, so either both commit or
// neither does.
host_call_once :: proc(host: ^Host, request_id: []u8, name: string, args: []Value) -> Error {
	return host_call_once_at(host, request_id, name, args, host_now(host))
}

// host_call_once_at runs an idempotent call at a given time. A remote caller
// passes its own clock, so the same call replayed produces the same result.
host_call_once_at :: proc(
	host: ^Host,
	request_id: []u8,
	name: string,
	args: []Value,
	now_us: i64,
) -> Error {
	if len(request_id) == 0 {
		return errf(.Invalid_Argument, "an idempotent call needs a request id")
	}
	reducer, registered := host.reducers[name]
	if !registered {
		return errf(.Invalid_Argument, "no reducer named %s", name)
	}
	if len(args) != len(reducer.params) {
		return errf(
			.Invalid_Argument,
			"reducer %s takes %d arguments but %d were given",
			name,
			len(reducer.params),
			len(args),
		)
	}
	if ensure_err := host_ensure_request_table(host); ensure_err.kind != .None {
		return ensure_err
	}
	coerced := make([]Value, len(args))
	defer delete(coerced)
	for param, i in reducer.params {
		value, coerce_err := value_coerce(args[i], param)
		if coerce_err.kind != .None do return coerce_err
		coerced[i] = value
	}

	tx := tx_begin_write(host.store)
	seen, seen_err := sql_execute_in_tx_params(
		tx,
		"SELECT count(*) FROM _request WHERE id = ?",
		[]Value{value_bytes(request_id)},
	)
	if seen_err.kind != .None {
		tx_rollback(tx)
		return seen_err
	}
	already_ran := len(seen.rows) > 0 && seen.rows[0][0].i > 0
	sql_result_destroy(&seen)
	if already_ran {
		tx_rollback(tx)
		return ERROR_NONE
	}

	call_now := now_us
	if call_now == 0 do call_now = host_now(host)
	ctx := Reducer_Ctx{tx = tx, host = host, now_us = call_now}
	if call_err := reducer.handler(&ctx, coerced); call_err.kind != .None {
		tx_rollback(tx)
		return call_err
	}
	// The transaction priced every statement it ran: one unit of work per row
	// touched, which is what a runaway reducer is measured in.
	spent := tx.work_units
	host.work_units_last = spent
	if host.max_work_units > 0 && spent > host.max_work_units {
		tx_rollback(tx)
		return errf(
			.Quota_Exceeded,
			"reducer %s spent %d work units, over the %d budget",
			name,
			spent,
			host.max_work_units,
		)
	}

	response: Value = value_product(nil)
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	value_encode(&w, response)
	payload := make([]u8, len(w.data))
	copy(payload, w.data[:])
	defer delete(payload)
	insert := []Value{value_bytes(request_id), value_bytes(payload)}
	if _, insert_err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _request (id, response) VALUES (?, ?)",
		insert,
	); insert_err.kind != .None {
		tx_rollback(tx)
		return insert_err
	}
	return tx_commit(tx)
}

// host_client_connect registers a connection. It returns false when the
// registry is full, which the transport reports as a rejection.
host_client_connect :: proc(host: ^Host, owner: u64) -> bool {
	if _, exists := host.clients[owner]; exists do return true
	if host.max_clients > 0 && len(host.clients) >= host.max_clients do return false
	host.clients[owner] = Client{owner = owner, connected_us = host.now_us}
	return true
}

// host_client_disconnect forgets the connection and drops its subscriptions.
host_client_disconnect :: proc(host: ^Host, owner: u64) {
	delete_key(&host.clients, owner)
	host_drop_owned(host, owner)
}

// host_client_over_budget reports whether a connection has been sent more
// than `limit` bytes. The transport uses it to drop slow consumers instead of
// letting one of them hold the writer.
host_client_over_budget :: proc(host: ^Host, owner: u64, limit: u64) -> bool {
	client, exists := host.clients[owner]
	return exists && client.bytes_out > limit
}

host_client_bytes :: proc(host: ^Host, owner: u64) -> u64 {
	client, exists := host.clients[owner]
	if !exists do return 0
	return client.bytes_out
}

// host_set_request_limits configures the HTTP caps; zero disables one.
host_set_request_limits :: proc(host: ^Host, max_request: int, max_header: int) {
	if host == nil do return
	host.max_request_bytes = max_request
	host.max_header_bytes = max_header
}

// host_set_frame_limit caps one WebSocket frame; zero disables the cap.
host_set_frame_limit :: proc(host: ^Host, max_frame: int) {
	if host == nil do return
	host.max_frame_bytes = max_frame
}

// host_set_client_queue_budget caps the outbox of every client (zero is
// unbounded). A client that cannot drain it is dropped rather than buffered.
host_set_client_queue_budget :: proc(host: ^Host, bytes: u64) {
	host.client_queue_budget = bytes
}

host_client_queue_budget :: proc(host: ^Host) -> u64 {
	return host.client_queue_budget
}

// host_client_enqueue reserves `bytes` in the outbox. It returns false when the
// message does not fit: the policy counts the drop and asks for the connection
// to be closed on the next write.
host_client_enqueue :: proc(host: ^Host, owner: u64, bytes: u64) -> bool {
	client, exists := host.clients[owner]
	if !exists do return false
	if budget := host.client_queue_budget; budget > 0 && client.queue + bytes > budget {
		client.dropped += 1
		client.drop = true
		host.clients[owner] = client
		return false
	}
	client.queue += bytes
	client.bytes_out += bytes
	host.clients[owner] = client
	return true
}

// host_client_dequeue releases bytes once the transport wrote them.
host_client_dequeue :: proc(host: ^Host, owner: u64, bytes: u64) {
	client, exists := host.clients[owner]
	if !exists do return
	client.queue = client.queue >= bytes ? client.queue - bytes : 0
	host.clients[owner] = client
}

host_client_queue :: proc(host: ^Host, owner: u64) -> u64 {
	client, exists := host.clients[owner]
	if !exists do return 0
	return client.queue
}

host_client_dropped :: proc(host: ^Host, owner: u64) -> u64 {
	client, exists := host.clients[owner]
	if !exists do return 0
	return client.dropped
}

// host_client_should_drop tells the transport to close the connection.
host_client_should_drop :: proc(host: ^Host, owner: u64) -> bool {
	client, exists := host.clients[owner]
	return exists && client.drop
}

// host_incremental_updates reports how many deltas were applied row by row.
host_incremental_updates :: proc(host: ^Host) -> u64 {
	return host.incremental_updates
}

host_client_count :: proc(host: ^Host) -> int {
	return len(host.clients)
}

host_client_connected :: proc(host: ^Host, owner: u64) -> bool {
	_, exists := host.clients[owner]
	return exists
}
