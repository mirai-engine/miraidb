package engine

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:strconv"
import "core:sync"

// PostgreSQL wire protocol, simple-query subset. It covers the frontend
// startup (with the SSLRequest probe), simple queries and termination; the
// extended query protocol (Parse/Bind/Execute) is not implemented yet.
//
// The server side of this file is transport independent: pg_handle_message
// takes the bytes of one frontend message and returns the bytes to send back.

PG_PROTOCOL_3 :: u32(196608) // 3.0
PG_SSL_REQUEST :: u32(80877103)

@(private)
pg_put_i16 :: proc(b: ^[dynamic]u8, value: i16) {
	v := u16(value)
	append(b, u8(v >> 8), u8(v))
}

@(private)
pg_put_i32 :: proc(b: ^[dynamic]u8, value: i32) {
	v := u32(value)
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private)
pg_put_cstring :: proc(b: ^[dynamic]u8, text: string) {
	append(b, ..transmute([]u8)text)
	append(b, 0)
}

// pg_message wraps a body with its type byte and big-endian length.
@(private)
pg_message :: proc(kind: u8, body: []u8) -> []u8 {
	out := make([dynamic]u8, 0, len(body) + 5)
	append(&out, kind)
	pg_put_i32(&out, i32(len(body) + 4))
	append(&out, ..body)
	return out[:]
}

@(private)
pg_get_i32 :: proc(data: []u8, offset: int) -> i32 {
	if offset + 4 > len(data) do return 0
	return i32(
		u32(data[offset]) << 24 |
		u32(data[offset + 1]) << 16 |
		u32(data[offset + 2]) << 8 |
		u32(data[offset + 3]),
	)
}

Pg_Startup :: struct {
	protocol:    u32,
	ssl_request: bool,
	user:        string,
}

// pg_parse_startup parses the untyped startup packet. It also reports the
// SSLRequest probe, whose protocol field carries a magic number.
pg_parse_startup :: proc(data: []u8) -> (startup: Pg_Startup, ok: bool) {
	if len(data) < 8 do return {}, false
	length := int(pg_get_i32(data, 0))
	if length < 8 || length > len(data) do return {}, false
	code := u32(pg_get_i32(data, 4))
	if code == PG_SSL_REQUEST {
		startup.ssl_request = true
		return startup, true
	}
	if code != PG_PROTOCOL_3 do return {}, false
	startup.protocol = code
	position := 8
	for position < length {
		key, consumed := pg_read_cstring(data[position:length])
		if consumed == 0 do break
		position += consumed
		if len(key) == 0 do break
		value, value_consumed := pg_read_cstring(data[position:length])
		position += value_consumed
		if key == "user" do startup.user = strings.clone(value)
	}
	return startup, true
}

@(private)
pg_get_i16 :: proc(data: []u8, offset: int) -> i16 {
	if offset + 2 > len(data) do return 0
	return i16(u16(data[offset]) << 8 | u16(data[offset + 1]))
}

@(private)
pg_read_cstring :: proc(data: []u8) -> (text: string, consumed: int) {
	for i in 0 ..< len(data) {
		if data[i] == 0 do return string(data[:i]), i + 1
	}
	return "", 0
}

// --- Backend messages ------------------------------------------------------

pg_authentication_ok :: proc() -> []u8 {
	body: [dynamic]u8
	pg_put_i32(&body, 0)
	return pg_message('R', body[:])
}

pg_parameter_status :: proc(name, value: string) -> []u8 {
	body: [dynamic]u8
	pg_put_cstring(&body, name)
	pg_put_cstring(&body, value)
	return pg_message('S', body[:])
}

pg_ready_for_query :: proc(status: u8) -> []u8 {
	body: [dynamic]u8
	append(&body, status)
	return pg_message('Z', body[:])
}

pg_command_complete :: proc(tag: string) -> []u8 {
	body: [dynamic]u8
	pg_put_cstring(&body, tag)
	return pg_message('C', body[:])
}

pg_error_response :: proc(message: string) -> []u8 {
	body: [dynamic]u8
	append(&body, 'S')
	pg_put_cstring(&body, "ERROR")
	append(&body, 'M')
	pg_put_cstring(&body, message)
	append(&body, 0)
	return pg_message('E', body[:])
}

pg_row_description :: proc(columns: []string) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(columns)))
	for column in columns {
		pg_put_cstring(&body, column)
		pg_put_i32(&body, 0) // table oid
		pg_put_i16(&body, 0) // column attribute
		pg_put_i32(&body, 25) // type oid: text
		pg_put_i16(&body, -1) // type length: variable
		pg_put_i32(&body, -1) // type modifier
		pg_put_i16(&body, 0) // text format
	}
	return pg_message('T', body[:])
}

pg_data_row :: proc(row: []Value, alloc: mem.Allocator) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(row)))
	for value in row {
		if value.kind == .Null {
			pg_put_i32(&body, -1)
			continue
		}
		text := value_format(value, alloc)
		pg_put_i32(&body, i32(len(text)))
		append(&body, ..transmute([]u8)text)
	}
	return pg_message('D', body[:])
}

// --- Dispatch --------------------------------------------------------------

// pg_handle_message processes one frontend message. `close` asks the transport
// to drop the connection after sending `response`.
pg_handle_message :: proc(host: ^Host, data: []u8) -> (response: []u8, close: bool) {
	if len(data) < 5 do return pg_error_response("short message"), true
	switch data[0] {
	case 'X':
		return nil, true
	case 'Q':
		length := int(pg_get_i32(data, 1))
		if length < 4 || 1 + length > len(data) {
			return pg_error_response("bad Query length"), true
		}
		sql, _ := pg_read_cstring(data[5:1 + length])
		return pg_simple_query(host, sql), false
	case:
		return pg_error_response(fmt.aprintf("unsupported message %c", data[0])), true
	}
}

// pg_simple_query runs one statement and returns the complete response: the
// result messages followed by ReadyForQuery.
pg_simple_query :: proc(host: ^Host, sql: string) -> []u8 {
	out := make([dynamic]u8, 0, 256)
	result, exec_err := sql_execute(host.store, sql)
	if exec_err.kind != .None {
		append(&out, ..pg_error_response(exec_err.message))
		append(&out, ..pg_ready_for_query('I'))
		return out[:]
	}
	defer sql_result_destroy(&result)
	if len(result.columns) > 0 {
		append(&out, ..pg_row_description(result.columns))
		for row in result.rows {
			append(&out, ..pg_data_row(row, context.temp_allocator))
		}
		append(&out, ..pg_command_complete(fmt.aprintf("SELECT %d", len(result.rows))))
	} else {
		append(&out, ..pg_command_complete("OK"))
	}
	append(&out, ..pg_ready_for_query('I'))
	return out[:]
}

// pg_is_startup recognizes the untyped startup packet (no type byte, protocol
// code in the second word), so a transport can route HTTP and PostgreSQL
// clients on the same port.
pg_is_startup :: proc(data: []u8) -> bool {
	if len(data) < 8 do return false
	code := u32(pg_get_i32(data, 4))
	return code == PG_PROTOCOL_3 || code == PG_SSL_REQUEST
}

// --- Extended query --------------------------------------------------------

// Pg_Portal is one bound statement waiting for Execute. Parameters are decoded
// from the text format the client sent.
Pg_Portal :: struct {
	sql:    string,
	params: []Value,
	// formats lists one result format code per column (0 text, 1 binary); an
	// empty list means text.
	formats: []i16,
}

// Pg_Statement is a parsed statement: its SQL and the parameter type OIDs the
// client declared (0 means unspecified).
Pg_Statement :: struct {
	sql:         string,
	param_types: []u32,
}

// Pg_Session keeps the prepared statements and portals of one connection.
Pg_Session :: struct {
	statements: map[string]Pg_Statement,
	portals:    map[string]Pg_Portal,
}

pg_session_init :: proc() -> ^Pg_Session {
	session := new(Pg_Session)
	session.statements = make(map[string]Pg_Statement)
	session.portals = make(map[string]Pg_Portal)
	return session
}

pg_session_destroy :: proc(session: ^Pg_Session) {
	if session == nil do return
	for _, statement in session.statements {
		delete(statement.sql)
		delete(statement.param_types)
	}
	delete(session.statements)
	for name, portal in session.portals {
		for value in portal.params do value_deep_free(value, context.allocator)
		delete(portal.params)
		delete(portal.formats)
		delete(portal.sql)
		delete(name)
	}
	delete(session.portals)
	free(session)
}

@(private)
pg_parse_complete :: proc() -> []u8 {
	return pg_message('1', nil)
}

@(private)
pg_bind_complete :: proc() -> []u8 {
	return pg_message('2', nil)
}

@(private)
pg_close_complete :: proc() -> []u8 {
	return pg_message('3', nil)
}

@(private)
pg_no_data :: proc() -> []u8 {
	return pg_message('n', nil)
}

// pg_value_from_text turns one text-format parameter into a value, guessing the
// type the same way the SQL layer would coerce a literal.
pg_value_from_text :: proc(text: string) -> Value {
	if number, ok := strconv.parse_int(text); ok do return value_int(i64(number))
	if number, ok := strconv.parse_uint(text); ok do return value_uint(u64(number))
	if number, ok := strconv.parse_f64(text); ok do return value_float(number)
	if strings.equal_fold(text, "true") do return value_bool(true)
	if strings.equal_fold(text, "false") do return value_bool(false)
	if strings.equal_fold(text, "null") do return value_null()
	return value_string(strings.clone(text))
}

// pg_decode_param turns one Bind parameter into a value. Text parameters are
// guessed by shape; binary parameters need the OID the client declared.
pg_decode_param :: proc(data: []u8, binary: bool, oid: u32) -> (Value, bool) {
	if !binary do return pg_value_from_text(string(data)), true
	switch oid {
	case 21: // int2
		if len(data) != 2 do return {}, false
		return value_int(i64(i16(u16(data[0]) << 8 | u16(data[1])))), true
	case 23: // int4
		if len(data) != 4 do return {}, false
		return value_int(i64(i32(pg_get_i32(data, 0)))), true
	case 20: // int8
		if len(data) != 8 do return {}, false
		big := u64(0)
		for byte in data do big = big << 8 | u64(byte)
		return value_int(i64(big)), true
	case 700: // float4
		if len(data) != 4 do return {}, false
		bits := u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
		return value_float(f64(transmute(f32)bits)), true
	case 701: // float8
		if len(data) != 8 do return {}, false
		big := u64(0)
		for byte in data do big = big << 8 | u64(byte)
		return value_float(transmute(f64)big), true
	case 16: // bool
		if len(data) != 1 do return {}, false
		return value_bool(data[0] != 0), true
	case 25, 1043, 1042: // text, varchar, bpchar
		return value_string(strings.clone(string(data))), true
	case 17: // bytea
		raw := make([]u8, len(data))
		copy(raw, data)
		return value_bytes(raw), true
	case 2950: // uuid
		if len(data) != 16 do return {}, false
		uuid: Uuid
		copy(uuid[:], data)
		return value_uuid(uuid), true
	}
	return {}, false
}

// pg_type_oid is the PostgreSQL type OID advertised for a value kind.
pg_type_oid :: proc(v: Value) -> u32 {
	switch v.kind {
	case .Bool:
		return 16
	case .Int:
		return 20
	case .Uint:
		return 20
	case .Float:
		return 701
	case .String:
		return 25
	case .Bytes:
		return 17
	case .Uuid:
		return 2950
	case .Timestamp:
		return 1114
	case .Duration:
		return 1186
	case .Null, .Default, .Array, .Product, .Int128, .Uint128, .Identity, .Connection:
		return 25
	}
	return 25
}

pg_parameter_description :: proc(types: []u32) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(types)))
	for oid in types do pg_put_i32(&body, i32(oid))
	return pg_message('t', body[:])
}

// pg_describe_select answers Describe with a RowDescription. It plans the
// statement instead of running it: the columns come from the AST and the
// catalog, so Describe has no side effects and cannot fail on bad data.
pg_describe_select :: proc(host: ^Host, sql: string) -> []u8 {
	columns, plan_ok := pg_describe_plan(host, sql)
	if plan_ok {
		defer {
			for column in columns do delete(column)
			delete(columns)
		}
		if len(columns) == 0 do return pg_no_data()
		return pg_row_description(columns)
	}
	// Unknown shape: fall back to evaluating a SELECT with neutralized
	// placeholders, which still yields the column set.
	upper := strings.to_upper(strings.trim_space(sql))
	if !strings.has_prefix(upper, "SELECT") && !strings.has_prefix(upper, "WITH") {
		return pg_no_data()
	}
	describe_sql := pg_neutralize_params(sql)
	defer delete(describe_sql)
	result, exec_err := sql_execute(host.store, describe_sql)
	if exec_err.kind != .None do return pg_no_data()
	defer sql_result_destroy(&result)
	if len(result.columns) == 0 do return pg_no_data()
	oids := pg_column_oids(result.columns, result.rows)
	defer delete(oids)
	return pg_row_description_typed(result.columns, oids)
}

// pg_describe_plan expands the projections of a single SELECT against the
// catalog schemas. It returns false when the statement is not a SELECT or a
// referenced table is missing.
pg_describe_plan :: proc(host: ^Host, sql: string) -> (columns: []string, ok: bool) {
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return nil, false
	defer query_destroy(&query)
	stmt, is_select := query.statement.(Select_Stmt)
	if !is_select do return nil, false

	sync.shared_lock(&host.store.mutex)
	sources := make([dynamic]Source, 0, 1 + len(stmt.joins), context.temp_allocator)
	if len(stmt.from.name) > 0 {
		table, table_err := store_table(host.store, stmt.from.name)
		if table_err.kind != .None {
			sync.shared_unlock(&host.store.mutex)
			return nil, false
		}
		append(&sources, Source{table = table, alias = stmt.from.alias})
		for join in stmt.joins {
			join_table, join_err := store_table(host.store, join.table.name)
			if join_err.kind != .None {
				sync.shared_unlock(&host.store.mutex)
				return nil, false
			}
			append(&sources, Source{table = join_table, alias = join.table.alias})
		}
	}
	names := make([dynamic]string, 0, len(stmt.projections))
	_ = expand_projections(sources[:], stmt.joins, stmt.projections, &names, context.allocator)
	sync.shared_unlock(&host.store.mutex)
	return names[:], true
}

// pg_neutralize_params replaces every `?` outside quotes with NULL so a
// statement can be evaluated without bound parameters.
pg_neutralize_params :: proc(sql: string) -> string {
	builder := strings.builder_make()
	in_string := false
	for ch in sql {
		if ch == '\'' do in_string = !in_string
		if ch == '?' && !in_string {
			strings.write_string(&builder, "NULL")
			continue
		}
		strings.write_rune(&builder, ch)
	}
	return strings.to_string(builder)
}

// pg_column_oids picks one OID per column from the first non-null value; text is
// the fallback for unknown or empty columns.
pg_column_oids :: proc(columns: []string, rows: [][]Value) -> []u32 {
	oids := make([]u32, len(columns))
	for i in 0 ..< len(columns) do oids[i] = 25
	for row in rows {
		for value, i in row {
			if i >= len(oids) do break
			if value.kind == .Null || oids[i] != 25 do continue
			oids[i] = pg_type_oid(value)
		}
	}
	return oids
}

pg_row_description_typed :: proc(columns: []string, oids: []u32) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(columns)))
	for column, i in columns {
		oid := i < len(oids) ? oids[i] : u32(25)
		pg_put_cstring(&body, column)
		pg_put_i32(&body, 0)
		pg_put_i16(&body, 0)
		pg_put_i32(&body, i32(oid))
		pg_put_i16(&body, i16(pg_oid_width(oid)))
		pg_put_i32(&body, -1)
		pg_put_i16(&body, 0)
	}
	return pg_message('T', body[:])
}

@(private)
pg_oid_width :: proc(oid: u32) -> i32 {
	switch oid {
	case 16:
		return 1
	case 21:
		return 2
	case 23:
		return 4
	case 20, 701, 1114, 1186:
		return 8
	case 2950:
		return 16
	}
	return -1
}

// pg_data_row_binary writes values in binary format; a column whose OID has no
// binary encoder falls back to text.
pg_data_row_binary :: proc(row: []Value, oids: []u32, formats: []i16) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(row)))
	for value, i in row {
		if value.kind == .Null {
			pg_put_i32(&body, -1)
			continue
		}
		binary := len(formats) == 1 ? formats[0] == 1 : i < len(formats) && formats[i] == 1
		oid := i < len(oids) ? oids[i] : u32(25)
		if binary && oid == 20 && value.kind == .Int {
			pg_put_i32(&body, 8)
			big := u64(value.i)
			for shift := 56; shift >= 0; shift -= 8 do append(&body, u8(big >> u64(shift)))
			continue
		}
		if binary && oid == 701 && value.kind == .Float {
			pg_put_i32(&body, 8)
			big := transmute(u64)value.f
			for shift := 56; shift >= 0; shift -= 8 do append(&body, u8(big >> u64(shift)))
			continue
		}
		if binary && oid == 16 && value.kind == .Bool {
			pg_put_i32(&body, 1)
			append(&body, value.b ? u8(1) : u8(0))
			continue
		}
		if binary && oid == 2950 && value.kind == .Uuid {
			pg_put_i32(&body, 16)
			uuid := value.uuid
			raw: []u8 = uuid[:]
			append(&body, ..raw)
			continue
		}
		if binary && oid == 17 && value.kind == .Bytes {
			pg_put_i32(&body, i32(len(value.bytes)))
			append(&body, ..value.bytes)
			continue
		}
		text := value_format(value, context.temp_allocator)
		pg_put_i32(&body, i32(len(text)))
		append(&body, ..transmute([]u8)text)
	}
	return pg_message('D', body[:])
}

// pg_handle_session_message is pg_handle_message plus the extended-query
// protocol. Extended statements are executed in text format; a binary format
// request is refused with an error instead of returning corrupt bytes.
pg_handle_session_message :: proc(
	host: ^Host,
	session: ^Pg_Session,
	data: []u8,
) -> (response: []u8, close: bool) {
	if len(data) < 5 do return pg_error_response("short message"), true
	if data[0] != 'P' && data[0] != 'B' && data[0] != 'D' && data[0] != 'E' && data[0] != 'S' && data[0] != 'H' && data[0] != 'C' {
		// Simple messages work exactly as before.
		return pg_handle_message(host, data)
	}
	length := int(pg_get_i32(data, 1))
	if length < 4 || 1 + length > len(data) {
		return pg_error_response("bad message length"), true
	}
	body := data[5:1 + length]
	out := make([dynamic]u8, 0, 128)
	switch data[0] {
	case 'P':
		name, consumed := pg_read_cstring(body)
		if consumed == 0 do return pg_error_response("bad Parse"), true
		rest := body[consumed:]
		sql, sql_consumed := pg_read_cstring(rest)
		if sql_consumed == 0 do return pg_error_response("bad Parse"), true
		if existing, found := session.statements[name]; found {
			delete(existing.sql)
			delete(existing.param_types)
			delete_key(&session.statements, name)
			delete(name)
		}
		types_rest := rest[sql_consumed:]
		param_count := int(pg_get_i16(types_rest, 0))
		param_types := make([]u32, param_count)
		for i in 0 ..< param_count {
			param_types[i] = u32(pg_get_i32(types_rest, 2 + i * 4))
		}
		session.statements[strings.clone(name)] = Pg_Statement {
			sql         = strings.clone(sql),
			param_types = param_types,
		}
		append(&out, ..pg_parse_complete())
	case 'B':
		portal_name, consumed := pg_read_cstring(body)
		if consumed == 0 do return pg_error_response("bad Bind"), true
		rest := body[consumed:]
		statement_name, statement_consumed := pg_read_cstring(rest)
		if statement_consumed == 0 do return pg_error_response("bad Bind"), true
		statement, found := session.statements[statement_name]
		if !found {
			append(&out, ..pg_error_response(fmt.aprintf("unknown statement %s", statement_name)))
			append(&out, ..pg_ready_for_query('I'))
			return out[:], false
		}
		cursor := rest[statement_consumed:]
		format_count := int(pg_get_i16(cursor, 0))
		param_formats := cursor[2:2 + format_count * 2]
		cursor = cursor[2 + format_count * 2:]
		param_count := int(pg_get_i16(cursor, 0))
		cursor = cursor[2:]
		params := make([dynamic]Value, 0, param_count)
		for param_index in 0 ..< param_count {
			param_length := int(pg_get_i32(cursor, 0))
			cursor = cursor[4:]
			if param_length < 0 {
				append(&params, value_null())
				continue
			}
			if param_length > len(cursor) {
				delete(params)
				return pg_error_response("bad Bind parameter"), true
			}
			binary := format_count == 1 ? pg_get_i16(param_formats, 0) == 1 : param_index < format_count && pg_get_i16(param_formats, param_index * 2) == 1
			var_oid: u32 = 0
			if param_index < len(statement.param_types) do var_oid = statement.param_types[param_index]
			decoded, decode_ok := pg_decode_param(cursor[:param_length], binary, var_oid)
			if !decode_ok {
				delete(params)
				return pg_error_response(fmt.aprintf("cannot decode parameter %d (oid %d)", param_index + 1, var_oid)), true
			}
			append(&params, decoded)
			cursor = cursor[param_length:]
		}
		result_format_count := int(pg_get_i16(cursor, 0))
		cursor = cursor[2:]
		formats := make([]i16, result_format_count)
		for i in 0 ..< result_format_count do formats[i] = pg_get_i16(cursor, i * 2)
		if portal, existing := session.portals[portal_name]; existing {
			for value in portal.params do value_deep_free(value, context.allocator)
			delete(portal.params)
			delete(portal.formats)
			delete(portal.sql)
			delete_key(&session.portals, portal_name)
		}
		bound := make([]Value, len(params))
		copy(bound, params[:])
		session.portals[strings.clone(portal_name)] = Pg_Portal {
			sql     = strings.clone(statement.sql),
			params  = bound,
			formats = formats,
		}
		append(&out, ..pg_bind_complete())
	case 'D':
		if len(body) < 2 do return pg_error_response("bad Describe"), true
		target := body[0]
		name, name_consumed := pg_read_cstring(body[1:])
		if name_consumed == 0 do return pg_error_response("bad Describe"), true
		if target == 'S' {
			statement, _ := session.statements[name]
			append(&out, ..pg_parameter_description(statement.param_types))
			append(&out, ..pg_describe_select(host, statement.sql))
		} else if portal, known := session.portals[name]; known {
			append(&out, ..pg_describe_select(host, portal.sql))
		} else {
			append(&out, ..pg_no_data())
		}
	case 'E':
		portal_name, consumed := pg_read_cstring(body)
		if consumed == 0 do return pg_error_response("bad Execute"), true
		portal, found := session.portals[portal_name]
		if !found {
			append(&out, ..pg_error_response(fmt.aprintf("unknown portal %s", portal_name)))
			append(&out, ..pg_ready_for_query('I'))
			return out[:], false
		}
		append(&out, ..pg_extended_execute(host, portal))
		append(&out, ..pg_ready_for_query('I'))
	case 'S':
		append(&out, ..pg_ready_for_query('I'))
	case 'H':
		// Flush: the response is already buffered here.
	case 'C':
		if len(body) < 2 do return pg_error_response("bad Close"), true
		name, name_consumed := pg_read_cstring(body[1:])
		if name_consumed == 0 do return pg_error_response("bad Close"), true
		if body[0] == 'S' {
			if existing, found := session.statements[name]; found {
				delete(existing.sql)
				delete(existing.param_types)
				delete_key(&session.statements, name)
			}
		} else if body[0] == 'P' {
			if portal, found := session.portals[name]; found {
				for value in portal.params do value_deep_free(value, context.allocator)
				delete(portal.params)
				delete(portal.sql)
				delete_key(&session.portals, name)
			}
		}
		append(&out, ..pg_close_complete())
	}
	return out[:], false
}

// pg_extended_execute runs one bound portal. It returns the result messages
// without the trailing ReadyForQuery, which Sync owns.
pg_extended_execute :: proc(host: ^Host, portal: Pg_Portal) -> []u8 {
	out := make([dynamic]u8, 0, 128)
	result, exec_err := sql_execute_params(host.store, portal.sql, portal.params)
	if exec_err.kind != .None {
		append(&out, ..pg_error_response(exec_err.message))
		return out[:]
	}
	defer sql_result_destroy(&result)
	if len(result.columns) > 0 {
		oids := pg_column_oids(result.columns, result.rows)
		defer delete(oids)
		append(&out, ..pg_row_description_typed(result.columns, oids))
		for row in result.rows {
			append(&out, ..pg_data_row_binary(row, oids, portal.formats))
		}
		append(&out, ..pg_command_complete(fmt.aprintf("SELECT %d", len(result.rows))))
	} else {
		append(&out, ..pg_command_complete("OK"))
	}
	return out[:]
}
