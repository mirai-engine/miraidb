package engine

import "core:crypto"
import "core:crypto/hmac"
import "core:crypto/pbkdf2"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:strconv"
import "core:sync"

// PostgreSQL wire protocol: the frontend startup (with the SSLRequest probe and
// SCRAM-SHA-256 authentication), simple queries, and the extended query protocol
// (Parse/Bind/Describe/Execute/Close/Sync), with text and binary parameters and
// results.
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

// PG_STARTUP_PARAMETERS are the ParameterStatus messages a server sends once a
// client is authenticated, with the values that describe this engine: text is
// UTF-8, timestamps are integers in ISO format and `\` in a string is a
// character, not an escape.
PG_STARTUP_PARAMETERS :: [][2]string {
	{"server_version", "14.0"},
	{"server_encoding", "UTF8"},
	{"client_encoding", "UTF8"},
	{"DateStyle", "ISO, MDY"},
	{"IntervalStyle", "postgres"},
	{"TimeZone", "UTC"},
	{"integer_datetimes", "on"},
	{"standard_conforming_strings", "on"},
	{"is_superuser", "off"},
	{"session_authorization", "miraidb"},
	{"application_name", ""},
}

pg_command_complete :: proc(tag: string) -> []u8 {
	body: [dynamic]u8
	pg_put_cstring(&body, tag)
	return pg_message('C', body[:])
}

pg_error_response :: proc(message: string, code := "XX000") -> []u8 {
	body: [dynamic]u8
	append(&body, 'S')
	pg_put_cstring(&body, "ERROR")
	// V is the severity that is never translated; C is the SQLSTATE a driver
	// turns into an exception class (psycopg's UniqueViolation, JDBC's state).
	append(&body, 'V')
	pg_put_cstring(&body, "ERROR")
	append(&body, 'C')
	pg_put_cstring(&body, code)
	append(&body, 'M')
	pg_put_cstring(&body, message)
	append(&body, 0)
	return pg_message('E', body[:])
}

// pg_error_from is an engine error as an ErrorResponse with its SQLSTATE.
pg_error_from :: proc(err: Error) -> []u8 {
	return pg_error_response(err.message, pg_sqlstate(err.kind))
}

// pg_sqlstate is the PostgreSQL error code closest to an engine error kind.
pg_sqlstate :: proc(kind: Error_Kind) -> string {
	#partial switch kind {
	case .Table_Not_Found:
		return "42P01" // undefined_table
	case .Column_Not_Found:
		return "42703" // undefined_column
	case .Table_Exists:
		return "42P07" // duplicate_table
	case .Index_Exists:
		return "42P07"
	case .Index_Not_Found:
		return "42704" // undefined_object
	case .Duplicate_Primary_Key, .Duplicate_Unique:
		return "23505" // unique_violation
	case .Not_Null_Violation:
		return "23502" // not_null_violation
	case .Check_Violation:
		return "23514" // check_violation
	case .Invalid_Type:
		return "42804" // datatype_mismatch
	case .Invalid_Argument:
		return "22023" // invalid_parameter_value
	case .Sql_Syntax:
		return "42601" // syntax_error
	case .Sql_Unsupported, .Sql_Not_A_Query:
		return "0A000" // feature_not_supported
	case .Transaction_Read_Only:
		return "25006" // read_only_sql_transaction
	case .Transaction_Closed:
		return "25P01" // no_active_sql_transaction
	case .Permission_Denied:
		return "42501" // insufficient_privilege
	case .Cancelled:
		return "57014" // query_canceled
	case .Quota_Exceeded:
		return "54000" // program_limit_exceeded
	case .Locked:
		return "55P03" // lock_not_available
	case .Out_Of_Memory:
		return "53200" // out_of_memory
	case .Io:
		return "58030" // io_error
	case .Corrupt_Log:
		return "XX001" // data_corrupted
	}
	return "XX000" // internal_error
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

// pg_text_value is a value in PostgreSQL's text format. It differs from the
// engine's own formatting for a boolean, which PostgreSQL spells `t` and `f`
// (psycopg reads anything else as false).
pg_text_value :: proc(value: Value, alloc: mem.Allocator) -> string {
	if value.kind == .Bool do return value.b ? "t" : "f"
	return value_format(value, alloc)
}

pg_data_row :: proc(row: []Value, alloc: mem.Allocator) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(row)))
	for value in row {
		if value.kind == .Null {
			pg_put_i32(&body, -1)
			continue
		}
		text := pg_text_value(value, alloc)
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
		append(&out, ..pg_error_from(exec_err))
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
	// ran is set when a Describe of this portal ran the statement: `answer` holds
	// what Execute will send (the rows and the CommandComplete, or the error), so
	// the column types Describe announced are the ones the rows are encoded in,
	// and the statement runs once.
	ran:     bool,
	answer:  []u8,
}

// Pg_Statement is a parsed statement: its SQL and the parameter type OIDs the
// client declared (0 means unspecified).
Pg_Statement :: struct {
	sql:         string,
	param_types: []u32,
}

// Pg_Session keeps the prepared statements and portals of one connection, and
// the transaction a `BEGIN` opened. While `tx` is set the connection holds the
// store's write lock, so the transport must not let another statement in until
// it is closed (see pg_session_in_transaction).
Pg_Session :: struct {
	statements: map[string]Pg_Statement,
	portals:    map[string]Pg_Portal,
	tx:         ^Tx,
	// failed is PostgreSQL's aborted transaction: a statement failed after BEGIN,
	// and everything but ROLLBACK (or COMMIT, which rolls back) is refused.
	failed:     bool,
	// skip is the extended protocol's error rule: after an ErrorResponse every
	// message is discarded until the next Sync, which answers ReadyForQuery.
	skip:       bool,
}

// pg_session_in_transaction reports whether a BEGIN is open on this connection.
pg_session_in_transaction :: proc(session: ^Pg_Session) -> bool {
	return session != nil && session.tx != nil
}

// pg_session_status is the ReadyForQuery status byte: idle, in a transaction, or
// in a failed one.
@(private)
pg_session_status :: proc(session: ^Pg_Session) -> u8 {
	if session == nil || session.tx == nil do return 'I'
	return session.failed ? 'E' : 'T'
}

pg_session_init :: proc() -> ^Pg_Session {
	session := new(Pg_Session)
	session.statements = make(map[string]Pg_Statement)
	session.portals = make(map[string]Pg_Portal)
	return session
}

pg_session_destroy :: proc(session: ^Pg_Session) {
	if session == nil do return
	// A connection that goes away inside a transaction loses it, as in PostgreSQL.
	if session.tx != nil {
		tx_rollback(session.tx)
		session.tx = nil
	}
	for key, statement in session.statements {
		delete(statement.sql)
		delete(statement.param_types)
		delete(key)
	}
	delete(session.statements)
	for name, portal in session.portals {
		for value in portal.params do value_deep_free(value, context.allocator)
		delete(portal.params)
		delete(portal.formats)
		delete(portal.answer)
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
		text := pg_text_value(value, context.temp_allocator)
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
	if data[0] == 'Q' {
		length := int(pg_get_i32(data, 1))
		if length < 4 || 1 + length > len(data) {
			return pg_error_response("bad Query length"), true
		}
		sql, _ := pg_read_cstring(data[5:1 + length])
		return pg_session_simple_query(host, session, sql), false
	}
	if data[0] != 'P' && data[0] != 'B' && data[0] != 'D' && data[0] != 'E' && data[0] != 'S' && data[0] != 'H' && data[0] != 'C' {
		return pg_handle_message(host, data)
	}
	length := int(pg_get_i32(data, 1))
	if length < 4 || 1 + length > len(data) {
		return pg_error_response("bad message length"), true
	}
	body := data[5:1 + length]
	if session.skip && data[0] != 'S' do return nil, false
	out := make([dynamic]u8, 0, 128)
	defer if pg_has_error(out[:]) do session.skip = true
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
			// Free the key the map owns. `name` points into the network buffer:
			// freeing it crashed the server on the second unnamed Parse, which is
			// what every driver sends.
			stored_key, _ := delete_key(&session.statements, name)
			delete(stored_key)
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
			delete(portal.answer)
			delete(portal.sql)
			stored_key, _ := delete_key(&session.portals, portal_name)
			delete(stored_key)
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
			statement, known := session.statements[name]
			if !known {
				append(&out, ..pg_error_response(fmt.tprintf("unknown statement %s", name)))
				return out[:], false
			}
			append(&out, ..pg_parameter_description(pg_statement_param_types(statement)))
			append(&out, ..pg_describe_select(host, statement.sql))
		} else if portal, known := session.portals[name]; known {
			// A portal has its values, so it can answer exactly: run it now and
			// keep what Execute will send.
			if !portal.ran {
				description, answer := pg_portal_run(host, session, portal)
				portal.ran = true
				portal.answer = answer
				session.portals[name] = portal
				append(&out, ..description)
				delete(description)
				if pg_has_error(answer) {
					// The error belongs to this Describe; Execute has nothing left.
					append(&out, ..answer)
					delete(portal.answer)
					portal.answer = nil
					session.portals[name] = portal
				}
			} else {
				append(&out, ..pg_no_data())
			}
		} else {
			append(&out, ..pg_error_response(fmt.tprintf("unknown portal %s", name)))
		}
	case 'E':
		portal_name, consumed := pg_read_cstring(body)
		if consumed == 0 do return pg_error_response("bad Execute"), true
		portal, found := session.portals[portal_name]
		if !found {
			append(&out, ..pg_error_response(fmt.aprintf("unknown portal %s", portal_name)))
			return out[:], false
		}
		// No ReadyForQuery here: Sync owns it, and a client that pipelines
		// Execute messages reads one per Sync.
		if portal.ran {
			append(&out, ..portal.answer)
			delete(portal.answer)
			portal.answer = nil
			// Executing a portal again runs it again, as PostgreSQL does for a
			// portal that has run to completion.
			portal.ran = false
			session.portals[portal_name] = portal
		} else {
			description, answer := pg_portal_run(host, session, portal)
			delete(description)
			append(&out, ..answer)
			delete(answer)
		}
	case 'S':
		session.skip = false
		append(&out, ..pg_ready_for_query(pg_session_status(session)))
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
				stored_key, _ := delete_key(&session.statements, name)
				delete(stored_key)
			}
		} else if body[0] == 'P' {
			if portal, found := session.portals[name]; found {
				for value in portal.params do value_deep_free(value, context.allocator)
				delete(portal.params)
				delete(portal.formats)
				delete(portal.answer)
				delete(portal.sql)
				stored_key, _ := delete_key(&session.portals, name)
				delete(stored_key)
			}
		}
		append(&out, ..pg_close_complete())
	}
	return out[:], false
}

// pg_portal_run runs one bound portal and returns its two halves: the
// description (RowDescription, or NoData) and the answer Execute sends (the
// DataRows and CommandComplete, or an ErrorResponse). Both are built from the
// same result, so the type a column is announced with is the type its values are
// encoded in.
pg_portal_run :: proc(host: ^Host, session: ^Pg_Session, portal: Pg_Portal) -> (description: []u8, answer: []u8) {
	describe := make([dynamic]u8, 0, 64)
	out := make([dynamic]u8, 0, 128)
	if handled := pg_transaction_control(host, session, portal.sql, &out); handled {
		append(&describe, ..pg_no_data())
		return describe[:], out[:]
	}
	if session != nil && session.failed {
		append(&describe, ..pg_no_data())
		append(&out, ..pg_error_response(PG_ABORTED, "25P02"))
		return describe[:], out[:]
	}
	result, exec_err := pg_run(host, session, portal.sql, portal.params)
	if exec_err.kind != .None {
		if session != nil && session.tx != nil do session.failed = true
		append(&describe, ..pg_no_data())
		append(&out, ..pg_error_from(exec_err))
		return describe[:], out[:]
	}
	defer sql_result_destroy(&result)
	if len(result.columns) > 0 {
		oids := pg_column_oids(result.columns, result.rows)
		defer delete(oids)
		append(&describe, ..pg_row_description_formats(result.columns, oids, portal.formats))
		for row in result.rows {
			append(&out, ..pg_data_row_binary(row, oids, portal.formats))
		}
	} else {
		append(&describe, ..pg_no_data())
	}
	append(&out, ..pg_command_complete(pg_command_tag(portal.sql, &result)))
	return describe[:], out[:]
}

// pg_has_error reports whether a response holds an ErrorResponse message.
@(private)
pg_has_error :: proc(bytes: []u8) -> bool {
	i := 0
	for i + 5 <= len(bytes) {
		if bytes[i] == 'E' do return true
		length := int(u32(bytes[i + 1]) << 24 | u32(bytes[i + 2]) << 16 | u32(bytes[i + 3]) << 8 | u32(bytes[i + 4]))
		if length < 4 do return false
		i += 1 + length
	}
	return false
}

// pg_statement_param_types is the ParameterDescription of a statement: the types
// the client declared, and text for every parameter it left unspecified or did
// not declare at all, so a driver learns how many values to bind.
@(private)
pg_statement_param_types :: proc(statement: Pg_Statement) -> []u32 {
	count := len(statement.param_types)
	if query, parse_err := sql_parse(statement.sql); parse_err.kind == .None {
		count = max(count, query.param_count)
		query_destroy(&query)
	}
	types := make([]u32, count, context.temp_allocator)
	for i in 0 ..< count {
		types[i] = 25
		if i < len(statement.param_types) && statement.param_types[i] != 0 do types[i] = statement.param_types[i]
	}
	return types
}

// pg_row_description_formats is a typed RowDescription that also states the
// format each column will arrive in, which a binary-reading driver checks.
@(private)
pg_row_description_formats :: proc(columns: []string, oids: []u32, formats: []i16) -> []u8 {
	body: [dynamic]u8
	pg_put_i16(&body, i16(len(columns)))
	for column, i in columns {
		oid := i < len(oids) ? oids[i] : u32(25)
		binary := len(formats) == 1 ? formats[0] == 1 : i < len(formats) && formats[i] == 1
		// A column whose type has no binary encoder is sent as text; say so.
		if binary && !pg_binary_supported(oid) do binary = false
		pg_put_cstring(&body, column)
		pg_put_i32(&body, 0)
		pg_put_i16(&body, 0)
		pg_put_i32(&body, i32(oid))
		pg_put_i16(&body, i16(pg_oid_width(oid)))
		pg_put_i32(&body, -1)
		pg_put_i16(&body, binary ? 1 : 0)
	}
	return pg_message('T', body[:])
}

// pg_binary_supported names the types pg_data_row_binary can encode.
@(private)
pg_binary_supported :: proc(oid: u32) -> bool {
	switch oid {
	case 20, 701, 16, 2950, 17:
		return true
	}
	return false
}

PG_ABORTED :: "current transaction is aborted, commands ignored until end of transaction block"

// pg_run executes one statement in the session's open transaction, or in one of
// its own when there is none.
@(private)
pg_run :: proc(host: ^Host, session: ^Pg_Session, sql: string, params: []Value) -> (Sql_Result, Error) {
	if session != nil && session.tx != nil do return sql_execute_in_tx_params(session.tx, sql, params)
	return sql_execute_params(host.store, sql, params)
}

// pg_session_simple_query runs a Query message: one or more statements separated
// by `;`, each answered in turn, then one ReadyForQuery. As in PostgreSQL, the
// first error ends the message and the statements after it are not run.
pg_session_simple_query :: proc(host: ^Host, session: ^Pg_Session, sql: string) -> []u8 {
	out := make([dynamic]u8, 0, 256)
	statements := sql_split_statements(sql, context.temp_allocator)
	defer delete(statements)
	if len(statements) == 0 {
		// An empty query has its own answer.
		append(&out, ..pg_message('I', nil))
	}
	for statement in statements {
		if handled := pg_transaction_control(host, session, statement, &out); handled {
			continue
		}
		if session.failed {
			append(&out, ..pg_error_response(PG_ABORTED, "25P02"))
			break
		}
		result, exec_err := pg_run(host, session, statement, nil)
		if exec_err.kind != .None {
			if session.tx != nil do session.failed = true
			append(&out, ..pg_error_from(exec_err))
			break
		}
		if len(result.columns) > 0 {
			// Text values, typed columns: a driver parses `3` as an integer only
			// when the description says int8.
			oids := pg_column_oids(result.columns, result.rows)
			append(&out, ..pg_row_description_typed(result.columns, oids))
			delete(oids)
			for row in result.rows {
				append(&out, ..pg_data_row(row, context.temp_allocator))
			}
		}
		append(&out, ..pg_command_complete(pg_command_tag(statement, &result)))
		sql_result_destroy(&result)
	}
	append(&out, ..pg_ready_for_query(pg_session_status(session)))
	return out[:]
}

// pg_transaction_control answers BEGIN, COMMIT and ROLLBACK against the session.
// It returns false for any other statement, including `ROLLBACK TO <savepoint>`,
// which runs inside the open transaction like any statement.
@(private)
pg_transaction_control :: proc(host: ^Host, session: ^Pg_Session, sql: string, out: ^[dynamic]u8) -> bool {
	if session == nil do return false
	words := strings.fields(sql, context.temp_allocator)
	if len(words) == 0 do return false
	first := strings.to_upper(strings.trim_right(words[0], ";"), context.temp_allocator)
	second := ""
	if len(words) > 1 do second = strings.to_upper(strings.trim_right(words[1], ";"), context.temp_allocator)
	switch first {
	case "BEGIN", "START":
		if first == "START" && second != "TRANSACTION" do return false
		if session.tx == nil {
			session.tx = tx_begin_write(host.store)
			session.failed = false
		}
		// PostgreSQL warns about a nested BEGIN and keeps the open transaction.
		append(out, ..pg_command_complete("BEGIN"))
		return true
	case "COMMIT", "END":
		if session.tx == nil {
			append(out, ..pg_command_complete("COMMIT"))
			return true
		}
		tx := session.tx
		session.tx = nil
		if session.failed {
			// COMMIT of an aborted transaction rolls it back and says so.
			session.failed = false
			tx_rollback(tx)
			append(out, ..pg_command_complete("ROLLBACK"))
			return true
		}
		if err := tx_commit(tx); err.kind != .None {
			append(out, ..pg_error_from(err))
			return true
		}
		append(out, ..pg_command_complete("COMMIT"))
		return true
	case "DEALLOCATE", "DISCARD":
		// Prepared statements are session state, so these never reach the
		// engine. psycopg sends `DEALLOCATE ALL` after a rollback.
		target := second
		if target == "PREPARE" && len(words) > 2 {
			target = strings.to_upper(strings.trim_right(words[2], ";"), context.temp_allocator)
		}
		if first == "DISCARD" || target == "ALL" {
			for key, statement in session.statements {
				delete(statement.sql)
				delete(statement.param_types)
				delete(key)
			}
			clear(&session.statements)
			append(out, ..pg_command_complete(first == "DISCARD" ? "DISCARD ALL" : "DEALLOCATE ALL"))
			return true
		}
		name := strings.trim_right(words[len(words) - 1], ";")
		if existing, found := session.statements[name]; found {
			delete(existing.sql)
			delete(existing.param_types)
			stored_key, _ := delete_key(&session.statements, name)
			delete(stored_key)
		}
		append(out, ..pg_command_complete("DEALLOCATE"))
		return true
	case "ROLLBACK", "ABORT":
		if second == "TO" do return false
		if session.tx != nil {
			tx_rollback(session.tx)
			session.tx = nil
		}
		session.failed = false
		append(out, ..pg_command_complete("ROLLBACK"))
		return true
	}
	return false
}

// pg_command_tag is the CommandComplete text PostgreSQL sends for a statement:
// `SELECT 3`, `INSERT 0 2`, `UPDATE 1`, `CREATE TABLE`. Drivers read the count
// from it (psycopg's `rowcount`, JDBC's update count), so it has to be exact.
pg_command_tag :: proc(sql: string, result: ^Sql_Result) -> string {
	words := strings.fields(sql, context.temp_allocator)
	if len(words) == 0 do return "EMPTY"
	verb := strings.to_upper(strings.trim_right(words[0], ";("), context.temp_allocator)
	count := result.affected
	if len(result.columns) > 0 && (verb == "INSERT" || verb == "UPDATE" || verb == "DELETE") {
		count = max(count, len(result.rows))
	}
	switch verb {
	case "SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN", "DESCRIBE", "PRAGMA":
		return fmt.tprintf("SELECT %d", len(result.rows))
	case "INSERT", "REPLACE":
		return fmt.tprintf("INSERT 0 %d", count)
	case "UPDATE", "DELETE":
		return fmt.tprintf("%s %d", verb, count)
	case "CREATE", "DROP", "ALTER":
		// The object is the first word that is not a modifier.
		for word in words[1:] {
			object := strings.to_upper(strings.trim_right(word, ";("), context.temp_allocator)
			switch object {
			case "OR", "REPLACE", "UNIQUE", "TEMP", "TEMPORARY", "VIRTUAL", "IF", "NOT", "EXISTS":
				continue
			}
			return fmt.tprintf("%s %s", verb, object)
		}
		return verb
	case "TRUNCATE":
		return "TRUNCATE TABLE"
	}
	return verb
}

// sql_split_statements cuts a script into statements at the `;` that end them.
// A `;` inside a quoted string, a quoted name, a comment or a trigger body
// (`CREATE TRIGGER … BEGIN …; …; END`) does not end anything. Empty statements
// are dropped; the slices point into `sql`.
sql_split_statements :: proc(sql: string, alloc := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 2, alloc)
	text := transmute([]u8)sql
	start := 0
	depth := 0 // BEGIN/CASE … END nesting inside a trigger body
	trigger := false
	word_start := -1
	i := 0
	flush_word :: proc(sql: string, word_start: int, end: int, start: int, trigger: ^bool, depth: ^int) {
		if word_start < 0 do return
		word := sql[word_start:end]
		if !trigger^ && strings.equal_fold(word, "trigger") {
			// Only a trigger that this statement creates has a body.
			head := strings.to_upper(strings.trim_space(sql[start:word_start]), context.temp_allocator)
			if strings.has_prefix(head, "CREATE") do trigger^ = true
			return
		}
		if !trigger^ do return
		if strings.equal_fold(word, "begin") || strings.equal_fold(word, "case") {
			depth^ += 1
		} else if strings.equal_fold(word, "end") && depth^ > 0 {
			depth^ -= 1
		}
	}
	for i < len(text) {
		c := text[i]
		is_word := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		if is_word {
			if word_start < 0 do word_start = i
			i += 1
			continue
		}
		flush_word(sql, word_start, i, start, &trigger, &depth)
		word_start = -1
		switch {
		case c == '\'' || c == '"' || c == '`':
			i += 1
			for i < len(text) {
				if text[i] == c {
					// A doubled quote is the quote character itself.
					if i + 1 < len(text) && text[i + 1] == c {
						i += 2
						continue
					}
					break
				}
				i += 1
			}
			i += 1
		case c == '-' && i + 1 < len(text) && text[i + 1] == '-':
			for i < len(text) && text[i] != '\n' do i += 1
		case c == '/' && i + 1 < len(text) && text[i + 1] == '*':
			i += 2
			for i + 1 < len(text) && !(text[i] == '*' && text[i + 1] == '/') do i += 1
			i += 2
		case c == ';' && depth == 0:
			piece := strings.trim_space(sql[start:i])
			if len(piece) > 0 do append(&out, piece)
			start = i + 1
			trigger = false
			i += 1
		case:
			i += 1
		}
	}
	flush_word(sql, word_start, min(i, len(text)), start, &trigger, &depth)
	if start < len(text) {
		piece := strings.trim_space(sql[start:])
		if len(piece) > 0 do append(&out, piece)
	}
	return out
}

// --- SCRAM-SHA-256 ---------------------------------------------------------
//
// PostgreSQL authenticates a password with SCRAM-SHA-256 (RFC 5802, RFC 7677):
// the client proves it knows the password without sending it, and the server
// proves it knows it too. Three messages carry it:
//
//	server  AuthenticationSASL          the mechanisms it accepts
//	client  SASLInitialResponse         "n,,n=user,r=<client nonce>"
//	server  AuthenticationSASLContinue  "r=<client+server nonce>,s=<salt>,i=4096"
//	client  SASLResponse                "c=biws,r=<nonce>,p=<client proof>"
//	server  AuthenticationSASLFinal     "v=<server signature>", then AuthenticationOk
//
// What travels is HMAC proofs over the transcript, so an observer on a
// connection without TLS learns nothing that lets it authenticate or replay:
// the proof is bound to the server's salt and nonces.

PG_SCRAM_MECHANISM :: "SCRAM-SHA-256"
PG_SCRAM_ITERATIONS :: u32(4096)
PG_SCRAM_NONCE_BYTES :: 18
PG_SCRAM_SALT_BYTES :: 16
PG_SCRAM_KEY_BYTES :: 32

// Pg_Scram is one authentication exchange. It holds the password, the salt it
// issued and the transcript the proof is checked against.
Pg_Scram :: struct {
	password:     string,
	salt:         []u8,
	nonce:        string,
	client_first: string, // client-first-message-bare, owned
	server_first: string, // owned, kept for the transcript
}

// pg_scram_start begins an exchange with a fresh salt and nonce.
pg_scram_start :: proc(password: string) -> Pg_Scram {
	scram := Pg_Scram{password = password}
	scram.salt = make([]u8, PG_SCRAM_SALT_BYTES)
	crypto.rand_bytes(scram.salt)
	raw_nonce := make([]u8, PG_SCRAM_NONCE_BYTES)
	defer delete(raw_nonce)
	crypto.rand_bytes(raw_nonce)
	scram.nonce, _ = base64.encode(raw_nonce, allocator = context.allocator, options = {.No_Padding})
	return scram
}

pg_scram_destroy :: proc(scram: ^Pg_Scram) {
	if scram == nil do return
	delete(scram.salt)
	delete(scram.nonce)
	delete(scram.client_first)
	delete(scram.server_first)
	scram^ = {}
}

// pg_scram_client_first parses "n,,n=user,r=<nonce>" and keeps the bare part,
// which is what both sides sign. A mandatory extension is refused: this server
// implements none, and accepting one silently would weaken the proof.
pg_scram_client_first :: proc(scram: ^Pg_Scram, message: string) -> Error {
	bare_start := -1
	commas := 0
	for i in 0 ..< len(message) {
		if message[i] == ',' {
			commas += 1
			if commas == 2 {
				bare_start = i + 1
				break
			}
		}
	}
	if bare_start < 0 do return errf(.Invalid_Argument, "malformed SCRAM client-first message")
	bare := message[bare_start:]
	client_nonce := ""
	for attribute in strings.split(bare, ",", context.temp_allocator) {
		if strings.has_prefix(attribute, "m=") {
			return errf(.Invalid_Argument, "SCRAM extensions are not supported")
		}
		if strings.has_prefix(attribute, "r=") do client_nonce = attribute[2:]
	}
	if len(client_nonce) == 0 {
		return errf(.Invalid_Argument, "the SCRAM client-first message carries no nonce")
	}
	scram.client_first = strings.clone(bare)
	combined, _ := strings.concatenate({client_nonce, scram.nonce}, context.allocator)
	delete(scram.nonce)
	scram.nonce = combined
	return ERROR_NONE
}

// pg_scram_server_first answers the challenge: the combined nonce, the salt and
// the iteration count. The answer is owned by the caller.
pg_scram_server_first :: proc(scram: ^Pg_Scram) -> string {
	salt, _ := base64.encode(scram.salt)
	defer delete(salt)
	scram.server_first = fmt.aprintf(
		"r=%s,s=%s,i=%d",
		scram.nonce,
		salt,
		PG_SCRAM_ITERATIONS,
	)
	return strings.clone(scram.server_first)
}

@(private)
scram_keys :: proc(scram: ^Pg_Scram, auth_message: string) -> (salted: []u8, err: Error) {
	salted = make([]u8, PG_SCRAM_KEY_BYTES)
	pbkdf2.derive(
		.SHA256,
		transmute([]u8)scram.password,
		scram.salt,
		PG_SCRAM_ITERATIONS,
		salted,
	)
	return salted, ERROR_NONE
}

@(private)
scram_hmac :: proc(key: []u8, message: string) -> []u8 {
	out := make([]u8, PG_SCRAM_KEY_BYTES)
	hmac.sum(.SHA256, out, transmute([]u8)message, key)
	return out
}

@(private)
scram_sha256 :: proc(data: []u8) -> []u8 {
	out := make([]u8, PG_SCRAM_KEY_BYTES)
	hash.hash_bytes_to_buffer(.SHA256, data, out)
	return out
}

// pg_scram_finish checks the client's proof and answers the server signature,
// which the client verifies. The answer is owned by the caller.
pg_scram_finish :: proc(scram: ^Pg_Scram, message: string) -> (server_final: string, err: Error) {
	proof_at := -1
	for i := 0; i + 2 < len(message); i += 1 {
		if message[i] == ',' && message[i + 1] == 'p' && message[i + 2] == '=' {
			proof_at = i + 1
			break
		}
	}
	if proof_at < 0 {
		return "", errf(.Invalid_Argument, "the SCRAM client-final message carries no proof")
	}
	without_proof := message[:proof_at - 1]
	proof_text := message[proof_at + 2:]
	// The channel binding is base64("n,,") because this server offers no TLS: a
	// client that asked for it was answered N, so it must say so there.
	if !strings.contains(without_proof, "c=biws") {
		return "", errf(.Permission_Denied, "SCRAM channel binding is not what this server offered")
	}
	// The nonce must be the one this exchange issued, or the transcript is not
	// the one the server signed.
	client_nonce := ""
	for attribute in strings.split(without_proof, ",", context.temp_allocator) {
		if strings.has_prefix(attribute, "r=") do client_nonce = attribute[2:]
	}
	if client_nonce != scram.nonce {
		return "", errf(.Permission_Denied, "SCRAM nonce does not match the exchange")
	}

	auth_message, _ := strings.concatenate(
		{scram.client_first, ",", scram.server_first, ",", without_proof},
		context.allocator,
	)
	defer delete(auth_message)
	salted, _ := scram_keys(scram, auth_message)
	defer delete(salted)
	client_key := scram_hmac(salted, "Client Key")
	defer delete(client_key)
	stored_key := scram_sha256(client_key)
	defer delete(stored_key)
	client_signature := scram_hmac(stored_key, auth_message)
	defer delete(client_signature)

	// The client sent ClientKey XOR ClientSignature. Undo the signature, hash
	// what comes out, and check that it signs the transcript: only the password
	// produces such a key.
	decoded, decode_err := base64.decode(proof_text)
	if decode_err != base64.Decode_Error.None || len(decoded) != PG_SCRAM_KEY_BYTES {
		delete(decoded)
		return "", errf(.Permission_Denied, "the SCRAM proof is not a base64 SHA-256 value")
	}
	defer delete(decoded)
	recovered := make([]u8, PG_SCRAM_KEY_BYTES)
	defer delete(recovered)
	for i in 0 ..< PG_SCRAM_KEY_BYTES do recovered[i] = decoded[i] ~ client_signature[i]
	recovered_stored := scram_sha256(recovered)
	defer delete(recovered_stored)
	check := scram_hmac(recovered_stored, auth_message)
	defer delete(check)
	difference := u8(0)
	for i in 0 ..< PG_SCRAM_KEY_BYTES do difference |= check[i] ~ client_signature[i]
	if difference != 0 {
		return "", errf(.Permission_Denied, "invalid username or password")
	}

	server_key := scram_hmac(salted, "Server Key")
	defer delete(server_key)
	signature := scram_hmac(server_key, auth_message)
	defer delete(signature)
	encoded, _ := base64.encode(signature)
	defer delete(encoded)
	return fmt.aprintf("v=%s", encoded), ERROR_NONE
}

// --- The wire messages the exchange uses -----------------------------------

// pg_authentication_sasl offers the mechanism list. An AuthenticationSASL body
// is the type (10), the mechanisms as C strings, and an empty one to end.
pg_authentication_sasl :: proc() -> []u8 {
	body := make([dynamic]u8, 0, 32)
	defer delete(body)
	pg_put_i32(&body, 10)
	pg_put_cstring(&body, PG_SCRAM_MECHANISM)
	append(&body, 0)
	return pg_message('R', body[:])
}

pg_authentication_sasl_continue :: proc(challenge: string) -> []u8 {
	body := make([dynamic]u8, 0, len(challenge) + 8)
	defer delete(body)
	pg_put_i32(&body, 11)
	append(&body, ..transmute([]u8)challenge)
	return pg_message('R', body[:])
}

pg_authentication_sasl_final :: proc(answer: string) -> []u8 {
	body := make([dynamic]u8, 0, len(answer) + 8)
	defer delete(body)
	pg_put_i32(&body, 12)
	append(&body, ..transmute([]u8)answer)
	return pg_message('R', body[:])
}

// pg_sasl_initial reads SASLInitialResponse: the mechanism name, then the
// initial client message with its length.
pg_sasl_initial :: proc(data: []u8) -> (mechanism: string, initial: string, ok: bool) {
	if len(data) < 5 || data[0] != 'p' do return "", "", false
	offset := 5
	name, consumed := pg_read_cstring(data[offset:])
	if consumed <= 0 do return "", "", false
	offset += consumed
	if offset + 4 > len(data) do return "", "", false
	size := int(pg_get_i32(data, offset))
	offset += 4
	if size < 0 || offset + size > len(data) do return "", "", false
	return name, string(data[offset:offset + size]), true
}

// pg_sasl_response reads the bare SASLResponse the client sends for the final
// step: the message body is just its text.
pg_sasl_response :: proc(data: []u8) -> (text: string, ok: bool) {
	if len(data) < 5 || data[0] != 'p' do return "", false
	return string(data[5:]), true
}
