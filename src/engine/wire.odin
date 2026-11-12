package engine

import "core:mem"

// Wire messages are the transport-independent half of the server: one message
// is a u32 kind followed by its fields, encoded with the same primitives as the
// commit log. A future HTTP/WebSocket layer only has to frame these bytes.
//
// Requests           Response
//   CALL_REDUCER       RESULT (commit sequence and the query result)
//   QUERY              SNAPSHOT (subscription id and one row list per query)
//   SUBSCRIBE          DELTA (pushed per changed query)
//   UNSUBSCRIBE        ERROR
//
// Every result carries the store's commit sequence, so a client can confirm the
// read (F10).

WIRE_CALL_REDUCER :: u32(1)
WIRE_QUERY :: u32(2)
WIRE_SUBSCRIBE :: u32(3)
WIRE_UNSUBSCRIBE :: u32(4)
WIRE_AUTH :: u32(5)
WIRE_CALL_PROCEDURE :: u32(6)
WIRE_RESULT :: u32(10)
WIRE_SNAPSHOT :: u32(11)
WIRE_DELTA :: u32(12)
WIRE_ERROR :: u32(13)

// --- Encoding --------------------------------------------------------------

wire_write_values :: proc(w: ^Byte_Writer, values: []Value) {
	bw_write_u32(w, u32(len(values)))
	for value in values do value_encode(w, value)
}

wire_write_rows :: proc(w: ^Byte_Writer, rows: [][]Value) {
	bw_write_u32(w, u32(len(rows)))
	for row in rows do wire_write_values(w, row)
}

@(private)
wire_finish :: proc(w: ^Byte_Writer) -> []u8 {
	raw := bw_bytes(w)
	out := make([]u8, len(raw))
	copy(out, raw)
	bw_destroy(w)
	return out
}

// wire_encode_call frames a reducer call. `now_us` travels with it so the
// receiving side runs the reducer at the caller's clock instead of its own: a
// module becomes deterministic for a given call, which is what makes a replay
// reproducible.
wire_encode_call :: proc(request_id: u64, name: string, args: []Value, now_us: i64 = 0) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_CALL_REDUCER)
	bw_write_u64(&w, request_id)
	bw_write_u64(&w, u64(now_us))
	bw_write_string(&w, name)
	wire_write_values(&w, args)
	return wire_finish(&w)
}

wire_encode_query :: proc(sql: string, params: []Value) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_QUERY)
	bw_write_string(&w, sql)
	wire_write_values(&w, params)
	return wire_finish(&w)
}

wire_encode_subscribe :: proc(sqls: []string) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_SUBSCRIBE)
	bw_write_u32(&w, u32(len(sqls)))
	for sql in sqls do bw_write_string(&w, sql)
	return wire_finish(&w)
}

wire_encode_call_procedure :: proc(name: string, args: []Value) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_CALL_PROCEDURE)
	bw_write_string(&w, name)
	wire_write_values(&w, args)
	return wire_finish(&w)
}

wire_encode_auth :: proc(token: string) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_AUTH)
	bw_write_string(&w, token)
	return wire_finish(&w)
}

wire_encode_unsubscribe :: proc(id: u64) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_UNSUBSCRIBE)
	bw_write_u64(&w, id)
	return wire_finish(&w)
}

wire_encode_result :: proc(result: Sql_Result) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_RESULT)
	bw_write_u64(&w, result.commit_seq)
	bw_write_u64(&w, result.row_bytes)
	bw_write_u32(&w, u32(result.affected))
	bw_write_u32(&w, u32(result.kind))
	bw_write_u32(&w, u32(len(result.columns)))
	for column in result.columns do bw_write_string(&w, column)
	wire_write_rows(&w, result.rows)
	return wire_finish(&w)
}

wire_encode_snapshot :: proc(id: u64, commit_seq: u64, snapshot: [][][]Value) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_SNAPSHOT)
	bw_write_u64(&w, id)
	bw_write_u64(&w, commit_seq)
	bw_write_u32(&w, u32(len(snapshot)))
	for rows in snapshot do wire_write_rows(&w, rows)
	return wire_finish(&w)
}

wire_encode_delta :: proc(update: ^Subscription_Update) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_DELTA)
	bw_write_u64(&w, update.subscription_id)
	bw_write_u32(&w, u32(update.query))
	bw_write_string(&w, update.table)
	wire_write_rows(&w, update.inserts)
	wire_write_rows(&w, update.deletes)
	return wire_finish(&w)
}

wire_encode_error :: proc(err: Error) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, WIRE_ERROR)
	bw_write_u32(&w, u32(err.kind))
	bw_write_string(&w, err.message)
	return wire_finish(&w)
}

// wire_message_kind reads the kind prefix of one message.
wire_message_kind :: proc(data: []u8) -> u32 {
	if len(data) < 4 do return 0
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

// wire_decode_error parses an ERROR message. It reports false for other kinds.
wire_decode_error :: proc(data: []u8, alloc: mem.Allocator) -> (Error, bool) {
	if wire_message_kind(data) != WIRE_ERROR do return {}, false
	r: Byte_Reader
	br_init(&r, data[4:])
	kind := Error_Kind(br_read_u32(&r))
	message := br_read_string(&r, alloc)
	if r.bad do return {}, false
	return Error{kind = kind, message = message}, true
}

// --- Decoding --------------------------------------------------------------

wire_read_values :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> []Value {
	count := int(br_read_u32(r))
	values := make([]Value, count, alloc)
	for i in 0 ..< count do values[i] = value_decode(r, alloc)
	return values
}

wire_read_rows :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> [][]Value {
	count := int(br_read_u32(r))
	rows := make([][]Value, count)
	for i in 0 ..< count do rows[i] = wire_read_values(r, alloc)
	return rows
}

// wire_decode_result parses a RESULT message. The caller owns the rows.
wire_decode_result :: proc(data: []u8, alloc: mem.Allocator) -> (Sql_Result, Error) {
	if len(data) < 4 do return {}, errf(.Invalid_Argument, "truncated message")
	r: Byte_Reader
	br_init(&r, data[4:])
	result := Sql_Result {
		commit_seq = br_read_u64(&r),
		row_bytes  = br_read_u64(&r),
		affected   = int(br_read_u32(&r)),
		kind       = Sql_Result_Kind(br_read_u32(&r)),
	}
	column_count := int(br_read_u32(&r))
	result.columns = make([]string, column_count, alloc)
	for i in 0 ..< column_count do result.columns[i] = br_read_string(&r, alloc)
	result.rows = wire_read_rows(&r, alloc)
	if r.bad do return {}, errf(.Invalid_Argument, "truncated result")
	return result, ERROR_NONE
}

// wire_decode_snapshot parses a SNAPSHOT message.
wire_decode_snapshot :: proc(
	data: []u8,
	alloc: mem.Allocator,
) -> (
	id: u64,
	commit_seq: u64,
	snapshot: [][][]Value,
	err: Error,
) {
	if len(data) < 4 do return 0, 0, nil, errf(.Invalid_Argument, "truncated message")
	r: Byte_Reader
	br_init(&r, data[4:])
	id = br_read_u64(&r)
	commit_seq = br_read_u64(&r)
	count := int(br_read_u32(&r))
	snapshot = make([][][]Value, count)
	for i in 0 ..< count do snapshot[i] = wire_read_rows(&r, alloc)
	if r.bad do return 0, 0, nil, errf(.Invalid_Argument, "truncated snapshot")
	return id, commit_seq, snapshot, ERROR_NONE
}

// --- Dispatch --------------------------------------------------------------

// wire_request executes one request message and returns one response message.
// It is the whole server minus the socket.
wire_request :: proc(host: ^Host, data: []u8) -> []u8 {
	return wire_request_owned(host, data, 0)
}

// wire_request_owned is wire_request with a connection owner: subscriptions
// created by this message belong to `owner` and host_drop_owned removes them.
wire_request_owned :: proc(host: ^Host, data: []u8, owner: u64) -> []u8 {
	host.metric_requests += 1
	// The identity belongs to the connection, not to the store: before the
	// request the store carries the caller's identity, and a token or SET
	// identity inside the request is kept for the next one. An embedded caller
	// (owner 0) keeps using the store identity directly.
	if owner != 0 {
		if client, exists := host.clients[owner]; exists {
			store_set_identity(host.store, client.identity)
		}
	}
	response := wire_dispatch_owned(host, data, owner)
	if owner != 0 {
		if client, exists := host.clients[owner]; exists {
			client.identity = store_identity(host.store)
			host.clients[owner] = client
		}
	}
	if client, exists := host.clients[owner]; exists {
		client.bytes_out += u64(len(response))
		host.clients[owner] = client
	}
	if len(response) >= 4 {
		kind := u32(response[0]) | u32(response[1]) << 8 | u32(response[2]) << 16 | u32(response[3]) << 24
		if kind == WIRE_ERROR do host.metric_errors += 1
	}
	return response
}

// WIRE_MAX_REQUEST bounds a single client message; larger ones are rejected
// instead of being parsed.
WIRE_MAX_REQUEST :: 4 * 1024 * 1024

@(private)
wire_dispatch_owned :: proc(host: ^Host, data: []u8, owner: u64) -> []u8 {
	if len(data) > WIRE_MAX_REQUEST {
		return wire_encode_error(errf(.Invalid_Argument, "request exceeds %d bytes", WIRE_MAX_REQUEST))
	}
	if len(data) < 4 do return wire_encode_error(errf(.Invalid_Argument, "empty message"))
	kind := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	r: Byte_Reader
	br_init(&r, data[4:])
	switch kind {
	case WIRE_CALL_REDUCER:
		request_id := br_read_u64(&r)
		caller_now := i64(br_read_u64(&r))
		name := br_read_string(&r, context.temp_allocator)
		args := wire_read_values(&r, context.temp_allocator)
		request := make([]u8, 8)
		put_u64_le(request, request_id)
		call_err := host_call_once_at(host, request, name, args, caller_now)
		if call_err.kind != .None do return wire_encode_error(call_err)
		return wire_encode_result(
			Sql_Result{kind = .Ack, affected = 1, commit_seq = host.store.commit_seq},
		)
	case WIRE_QUERY:
		sql := br_read_string(&r, context.temp_allocator)
		params := wire_read_values(&r, context.temp_allocator)
		result, exec_err := sql_execute_params(host.store, sql, params)
		if exec_err.kind != .None do return wire_encode_error(exec_err)
		defer sql_result_destroy(&result)
		return wire_encode_result(result)
	case WIRE_SUBSCRIBE:
		count := int(br_read_u32(&r))
		sqls := make([]string, count, context.temp_allocator)
		for i in 0 ..< count do sqls[i] = br_read_string(&r, context.temp_allocator)
		id, snapshot, sub_err := host_subscribe_many_owned(host, sqls, owner)
		if sub_err.kind != .None do return wire_encode_error(sub_err)
		return wire_encode_snapshot(id, host.store.commit_seq, snapshot)
	case WIRE_CALL_PROCEDURE:
		name := br_read_string(&r, context.temp_allocator)
		args := wire_read_values(&r, context.temp_allocator)
		call_err := host_call_procedure(host, name, args)
		if call_err.kind != .None do return wire_encode_error(call_err)
		return wire_encode_result(
			Sql_Result{kind = .Ack, affected = 1, commit_seq = host.store.commit_seq},
		)
	case WIRE_AUTH:
		token := br_read_string(&r, context.temp_allocator)
		identity, valid := host_authenticate(host, token)
		if !valid {
			return wire_encode_error(errf(.Permission_Denied, "invalid or expired token"))
		}
		store_set_identity(host.store, identity)
		return wire_encode_result(
			Sql_Result{kind = .Ack, affected = 1, commit_seq = host.store.commit_seq},
		)
	case WIRE_UNSUBSCRIBE:
		id := br_read_u64(&r)
		removed := host_unsubscribe(host, id)
		return wire_encode_result(
			Sql_Result {
				kind = .Ack,
				affected = removed ? 1 : 0,
				commit_seq = host.store.commit_seq,
			},
		)
	}
	return wire_encode_error(errf(.Invalid_Argument, "unknown message kind"))
}
