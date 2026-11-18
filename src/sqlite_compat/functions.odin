package sqlite_compat

// Application-defined functions through the classic API: sqlite3_create_function
// registers a C callback, the engine calls it with sqlite3_value arguments, and
// the callback answers through sqlite3_result_* on a sqlite3_context. An
// aggregate gets a step per row and a final per group, and keeps its
// accumulator in sqlite3_aggregate_context memory.
//
// The registration overrides a builtin of the same name, as SQLite's does,
// except an aggregate builtin (count, sum, ...), which keeps its name here.

import "base:runtime"
import "core:c"
import "core:strconv"
import "core:strings"

import engine "../engine"

SQLITE_UTF8 :: c.int(1)
SQLITE_TOOBIG_TEXT :: "string or blob too big"

Function_Callback :: #type proc "c" (ctx: rawptr, argc: c.int, argv: [^]rawptr)
Final_Callback :: #type proc "c" (ctx: rawptr)
Destroy_Callback :: #type proc "c" (data: rawptr)

// Function is one registration: a name and an arity on one connection.
Function :: struct {
	db:      ^Database,
	name:    string,
	arity:   int,
	user:    rawptr,
	func:    Function_Callback,
	step:    Function_Callback,
	final:   Final_Callback,
	destroy: Destroy_Callback,
}

// Context is what sqlite3_context points at for one call: the function, the
// answer the callback gave so far, and for an aggregate the group's memory.
Context :: struct {
	function:      ^Function,
	result:        engine.Value,
	has_error:     bool,
	error_message: string,
	error_code:    c.int,
	group:         ^engine.Aggregate_Group,
	auxdata:       [dynamic]Aux_Data,
}

Aux_Data :: struct {
	index:   c.int,
	data:    rawptr,
	destroy: Destroy_Callback,
}

// Value_Box is what sqlite3_value points at: one value, and the C string its
// text form was asked as, which lives as long as the box.
Value_Box :: struct {
	value: engine.Value,
	text:  cstring,
	// owned is set for a box sqlite3_value_dup made: it owns a deep copy.
	owned: bool,
	// text16 is the UTF-16 form last asked for, in the byte order text16_big
	// says (text16.odin).
	text16:     []u16,
	text16_big: bool,
}

// Aggregate_Memory is the zeroed block sqlite3_aggregate_context hands out,
// one per group.
Aggregate_Memory :: struct {
	block: rawptr,
	size:  int,
}

@(private)
context_of :: proc(handle: rawptr) -> ^Context {
	return (^Context)(handle)
}

@(private)
box_of :: proc(handle: rawptr) -> ^Value_Box {
	return (^Value_Box)(handle)
}

// --- SQLite's conversions --------------------------------------------------

// numeric_prefix is the longest prefix of `text` SQLite reads as a number,
// after leading spaces: a sign, digits, a fraction and an exponent. It reports
// whether the prefix is written as an integer.
@(private)
numeric_prefix :: proc(text: string) -> (prefix: string, integer: bool) {
	i := 0
	for i < len(text) && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r') do i += 1
	start := i
	if i < len(text) && (text[i] == '+' || text[i] == '-') do i += 1
	digits := 0
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		i += 1
		digits += 1
	}
	integer = true
	if i < len(text) && text[i] == '.' {
		j := i + 1
		fraction := 0
		for j < len(text) && text[j] >= '0' && text[j] <= '9' {
			j += 1
			fraction += 1
		}
		if digits + fraction > 0 {
			i = j
			digits += fraction
			integer = false
		}
	}
	if digits > 0 && i < len(text) && (text[i] == 'e' || text[i] == 'E') {
		j := i + 1
		if j < len(text) && (text[j] == '+' || text[j] == '-') do j += 1
		if j < len(text) && text[j] >= '0' && text[j] <= '9' {
			for j < len(text) && text[j] >= '0' && text[j] <= '9' do j += 1
			i = j
			integer = false
		}
	}
	if digits == 0 do return "", false
	return text[start:i], integer
}

// integer_prefix reads the leading integer of `text` as SQLite does when it
// turns text into an integer: spaces, a sign and digits, and nothing after them
// ('12.9' is 12, '1e3' is 1), clamped at the ends of the range.
@(private)
integer_prefix :: proc(text: string) -> i64 {
	i := 0
	for i < len(text) && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r') do i += 1
	negative := false
	if i < len(text) && (text[i] == '+' || text[i] == '-') {
		negative = text[i] == '-'
		i += 1
	}
	magnitude: u64 = 0
	overflow := false
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		digit := u64(text[i] - '0')
		if magnitude > (max(u64) - digit) / 10 {
			overflow = true
		} else {
			magnitude = magnitude * 10 + digit
		}
		i += 1
	}
	if negative {
		if overflow || magnitude > u64(max(i64)) + 1 do return min(i64)
		return -i64(magnitude - 1) - 1 if magnitude > 0 else 0
	}
	if overflow || magnitude > u64(max(i64)) do return max(i64)
	return i64(magnitude)
}

// sqlite_to_i64 is what sqlite3_value_int64 and sqlite3_column_int64 answer:
// a real is truncated, text and blobs are read for their leading integer, and
// anything else is 0.
sqlite_to_i64 :: proc(value: engine.Value) -> i64 {
	#partial switch value.kind {
	case .Int:
		return value.i
	case .Uint:
		return i64(value.u)
	case .Bool:
		return value.b ? 1 : 0
	case .Float:
		return float_to_i64(value.f)
	case .String, .Bytes:
		return integer_prefix(value.kind == .String ? value.s : string(value.bytes))
	}
	return 0
}

// float_to_i64 truncates toward zero and clamps at the ends of the range, as
// SQLite's conversion does.
@(private)
float_to_i64 :: proc(f: f64) -> i64 {
	if f != f do return 0
	if f <= -9223372036854775808.0 do return min(i64)
	if f >= 9223372036854775807.0 do return max(i64)
	return i64(f)
}

// sqlite_to_f64 is what sqlite3_value_double and sqlite3_column_double answer.
sqlite_to_f64 :: proc(value: engine.Value) -> f64 {
	#partial switch value.kind {
	case .Float:
		return value.f
	case .Int:
		return f64(value.i)
	case .Uint:
		return f64(value.u)
	case .Bool:
		return value.b ? 1 : 0
	case .String, .Bytes:
		text := value.kind == .String ? value.s : string(value.bytes)
		prefix, _ := numeric_prefix(text)
		if len(prefix) == 0 do return 0
		number, _ := strconv.parse_f64(prefix)
		return number
	}
	return 0
}

// sqlite_type_of is the storage class SQLite reports for a value.
sqlite_type_of :: proc(value: engine.Value) -> c.int {
	#partial switch value.kind {
	case .Null, .Default:
		return SQLITE_NULL
	case .Int, .Uint, .Int128, .Uint128, .Bool:
		return SQLITE_INTEGER
	case .Float:
		return SQLITE_FLOAT
	case .Bytes:
		return SQLITE_BLOB
	}
	return SQLITE_TEXT
}

// --- Registration ----------------------------------------------------------

@(private)
function_destroy :: proc(fn: ^Function) {
	if fn == nil do return
	if fn.destroy != nil do fn.destroy(fn.user)
	delete(fn.name)
	free(fn)
}

// function_drop forgets this connection's registration of `name` with `arity`
// and runs its destructor.
@(private)
function_drop :: proc(db: ^Database, name: string, arity: int) {
	for fn, i in db.functions {
		if fn.arity == arity && strings.equal_fold(fn.name, name) {
			ordered_remove(&db.functions, i)
			function_destroy(fn)
			return
		}
	}
}

// functions_close runs every destructor when the connection closes.
functions_close :: proc(db: ^Database) {
	for fn in db.functions do function_destroy(fn)
	delete(db.functions)
}


// SQLITE_MAX_FUNCTION_ARG is the most arguments a function takes: SQLite's
// limit since 3.48, which raised it from 127.
SQLITE_MAX_FUNCTION_ARG :: 1000

@(export)
sqlite3_create_function :: proc "c" (
	handle: rawptr,
	name: cstring,
	arity: c.int,
	text_rep: c.int,
	user: rawptr,
	func: Function_Callback,
	step: Function_Callback,
	final: Final_Callback,
) -> c.int {
	context = runtime.default_context()
	return create_function(handle, name, arity, user, func, step, final, nil)
}

// sqlite3_create_function_v2 is sqlite3_create_function with a destructor for
// the user pointer, run when the function is replaced or dropped, when the
// connection closes, and when the registration fails.
@(export)
sqlite3_create_function_v2 :: proc "c" (
	handle: rawptr,
	name: cstring,
	arity: c.int,
	text_rep: c.int,
	user: rawptr,
	func: Function_Callback,
	step: Function_Callback,
	final: Final_Callback,
	destroy: Destroy_Callback,
) -> c.int {
	context = runtime.default_context()
	return create_function(handle, name, arity, user, func, step, final, destroy)
}

@(private)
create_function :: proc(
	handle: rawptr,
	name: cstring,
	arity: c.int,
	user: rawptr,
	func: Function_Callback,
	step: Function_Callback,
	final: Final_Callback,
	destroy: Destroy_Callback,
) -> c.int {
	db := db_of(handle)
	misuse := db == nil || name == nil || arity < -1 || arity > SQLITE_MAX_FUNCTION_ARG || len(string(name)) > 255 ||
		(func != nil && (step != nil || final != nil)) ||
		(func == nil && (step == nil) != (final == nil))
	if misuse {
		if destroy != nil do destroy(user)
		return SQLITE_MISUSE
	}
	function_name := string(name)
	// No callback at all deletes the function, as in SQLite.
	if func == nil && step == nil {
		engine.store_unregister_function(db.conn.store, function_name, int(arity))
		function_drop(db, function_name, int(arity))
		if destroy != nil do destroy(user)
		return SQLITE_OK
	}
	fn := new(Function)
	fn^ = Function {
		db      = db,
		name    = strings.clone(function_name),
		arity   = int(arity),
		user    = user,
		func    = func,
		step    = step,
		final   = final,
		destroy = destroy,
	}
	err: engine.Error
	if func != nil {
		err = engine.store_register_function(db.conn.store, function_name, int(arity), facade_scalar, fn, true)
	} else {
		err = engine.store_register_aggregate(db.conn.store, function_name, int(arity), facade_step, facade_final, fn)
	}
	if err.kind != .None {
		code := fail(db, err)
		function_destroy(fn)
		return code
	}
	function_drop(db, function_name, int(arity))
	append(&db.functions, fn)
	return SQLITE_OK
}

// --- Calling the callbacks -------------------------------------------------

// call_callback runs one callback with the engine's arguments as sqlite3_value
// handles, then releases what the call made: the text forms the callback
// asked for, and the auxiliary data, which lives for one call here.
@(private)
call_callback :: proc(ctx: ^Context, callback: Function_Callback, args: []engine.Value) {
	boxes := make([]Value_Box, len(args))
	defer delete(boxes)
	pointers := make([]rawptr, len(args))
	defer delete(pointers)
	for value, i in args {
		boxes[i] = Value_Box{value = value}
		pointers[i] = rawptr(&boxes[i])
	}
	callback(rawptr(ctx), c.int(len(args)), raw_data(pointers))
	for box in boxes {
		delete(box.text)
		delete(box.text16)
	}
}

@(private)
context_release :: proc(ctx: ^Context) {
	for aux in ctx.auxdata {
		if aux.destroy != nil do aux.destroy(aux.data)
	}
	delete(ctx.auxdata)
	delete(ctx.error_message)
}

// context_answer turns what the callback said into the engine's answer. An
// error's code is kept on the connection, so the statement that fails answers
// it from sqlite3_step and sqlite3_errcode.
@(private)
context_answer :: proc(ctx: ^Context) -> (engine.Value, engine.Error) {
	if ctx.has_error {
		engine.value_deep_free(ctx.result, context.allocator)
		db := ctx.function.db
		db.function_code = ctx.error_code != 0 ? ctx.error_code : SQLITE_ERROR
		kind := engine.Error_Kind.Invalid_Argument
		if ctx.error_code == SQLITE_NOMEM do kind = .Out_Of_Memory
		if ctx.error_code == SQLITE_TOOBIG do kind = .Quota_Exceeded
		return {}, engine.errf(kind, "%s", ctx.error_message)
	}
	return ctx.result, engine.ERROR_NONE
}

@(private)
facade_scalar :: proc(args: []engine.Value, user: rawptr) -> (engine.Value, engine.Error) {
	ctx := Context{function = (^Function)(user)}
	defer context_release(&ctx)
	call_callback(&ctx, ctx.function.func, args)
	return context_answer(&ctx)
}

@(private)
facade_step :: proc(group: ^engine.Aggregate_Group, args: []engine.Value) -> engine.Error {
	ctx := Context{function = (^Function)(group.user), group = group}
	defer context_release(&ctx)
	call_callback(&ctx, ctx.function.step, args)
	engine.value_deep_free(ctx.result, context.allocator)
	if ctx.has_error {
		_, err := context_answer(&ctx)
		return err
	}
	return engine.ERROR_NONE
}

@(private)
facade_final :: proc(group: ^engine.Aggregate_Group) -> (engine.Value, engine.Error) {
	ctx := Context{function = (^Function)(group.user), group = group}
	defer context_release(&ctx)
	ctx.function.final(rawptr(&ctx))
	// The group's memory goes with its final, as SQLite frees it after xFinal.
	if group.state != nil {
		memory := (^Aggregate_Memory)(group.state)
		free(memory.block)
		free(memory)
		group.state = nil
	}
	return context_answer(&ctx)
}

// --- What a callback reads --------------------------------------------------

@(export)
sqlite3_user_data :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return nil
	return ctx.function.user
}

@(export)
sqlite3_context_db_handle :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return nil
	return rawptr(ctx.function.db)
}

// sqlite3_aggregate_context hands an aggregate the same zeroed block of `size`
// bytes for every step of a group and for its final. Asked with 0 before any
// step allocated it, it answers NULL, which is how a final tells an empty group.
@(export)
sqlite3_aggregate_context :: proc "c" (handle: rawptr, size: c.int) -> rawptr {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil || ctx.group == nil do return nil
	if ctx.group.state != nil do return (^Aggregate_Memory)(ctx.group.state).block
	if size <= 0 do return nil
	block, err := runtime.mem_alloc(int(size), 16)
	if err != nil do return nil
	memory := new(Aggregate_Memory)
	memory^ = Aggregate_Memory{block = raw_data(block), size = int(size)}
	ctx.group.state = memory
	return memory.block
}

// Auxiliary data lives for one call here: SQLite may drop it at any time, and a
// callback that reads NULL back computes it again, so this is SQLite's
// contract with the shortest lifetime it allows.
@(export)
sqlite3_get_auxdata :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return nil
	for aux in ctx.auxdata do if aux.index == index do return aux.data
	return nil
}

@(export)
sqlite3_set_auxdata :: proc "c" (handle: rawptr, index: c.int, data: rawptr, destroy: Destroy_Callback) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil {
		if destroy != nil do destroy(data)
		return
	}
	for &aux in ctx.auxdata {
		if aux.index != index do continue
		if aux.destroy != nil do aux.destroy(aux.data)
		aux = Aux_Data{index = index, data = data, destroy = destroy}
		return
	}
	append(&ctx.auxdata, Aux_Data{index = index, data = data, destroy = destroy})
}

@(export)
sqlite3_value_type :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return SQLITE_NULL
	return sqlite_type_of(box.value)
}

@(export)
sqlite3_value_int :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	return c.int(sqlite3_value_int64(handle))
}

@(export)
sqlite3_value_int64 :: proc "c" (handle: rawptr) -> c.longlong {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return 0
	return c.longlong(sqlite_to_i64(box.value))
}

@(export)
sqlite3_value_double :: proc "c" (handle: rawptr) -> c.double {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return 0
	return c.double(sqlite_to_f64(box.value))
}

// sqlite3_value_text is the text form of any value, NUL-terminated and living
// as long as the value; NULL for SQL NULL.
@(export)
sqlite3_value_text :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil || sqlite_type_of(box.value) == SQLITE_NULL do return nil
	if box.text == nil {
		rendered := engine.sqlite_value_text(box.value, context.allocator)
		defer delete(rendered)
		box.text = strings.clone_to_cstring(rendered)
	}
	return box.text
}

@(export)
sqlite3_value_blob :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return nil
	if box.value.kind == .Bytes {
		if len(box.value.bytes) == 0 do return nil
		return raw_data(box.value.bytes)
	}
	return rawptr(sqlite3_value_text(handle))
}

@(export)
sqlite3_value_bytes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return 0
	#partial switch box.value.kind {
	case .Null, .Default:
		return 0
	case .Bytes:
		return c.int(len(box.value.bytes))
	case .String:
		return c.int(len(box.value.s))
	}
	return c.int(len(string(sqlite3_value_text(handle))))
}

// sqlite3_value_numeric_type applies numeric affinity: a text that reads as a
// number becomes one, and the answer is the storage class after that.
@(export)
sqlite3_value_numeric_type :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return SQLITE_NULL
	if box.value.kind == .String {
		trimmed := strings.trim_space(box.value.s)
		prefix, integer := numeric_prefix(trimmed)
		if len(prefix) > 0 && len(prefix) == len(trimmed) {
			if integer {
				if number, ok := strconv.parse_i64(prefix, 10); ok {
					box.value = engine.value_int(number)
					return SQLITE_INTEGER
				}
			}
			number, _ := strconv.parse_f64(prefix)
			box.value = engine.value_float(number)
			return SQLITE_FLOAT
		}
	}
	return sqlite_type_of(box.value)
}

// sqlite3_value_dup makes a copy that outlives the call; sqlite3_value_free
// releases it.
@(export)
sqlite3_value_dup :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return nil
	copy := new(Value_Box)
	copy^ = Value_Box{value = engine.value_clone(box.value, context.allocator), owned = true}
	// A pointer value's copy is a plain NULL, as in SQLite (pointer.odin).
	if copy.value.kind == .Null do copy.value = engine.value_null()
	return rawptr(copy)
}

@(export)
sqlite3_value_free :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil || !box.owned do return
	engine.value_deep_free(box.value, context.allocator)
	delete(box.text)
	delete(box.text16)
	free(box)
}

// sqlite3_value_subtype is the value's subtype: 74 ('J') for text a JSON
// function produced. A value here never comes from an UPDATE that left its
// column alone, and is not traced back to a bind.
@(export)
sqlite3_value_subtype :: proc "c" (handle: rawptr) -> c.uint {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil do return 0
	return c.uint(box.value.subtype)
}

@(export)
sqlite3_value_nochange :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	return 0
}

@(export)
sqlite3_value_frombind :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	return 0
}

// --- What a callback answers ------------------------------------------------

@(private)
context_set :: proc(ctx: ^Context, value: engine.Value) {
	engine.value_deep_free(ctx.result, context.allocator)
	ctx.result = value
}

// release_with runs a destructor SQLite would run once it is done with the
// bytes: the bytes were copied, so that is now. SQLITE_STATIC (0) and
// SQLITE_TRANSIENT (-1) are not functions.
@(private)
release_with :: proc(data: rawptr, destructor: rawptr) {
	if destructor == nil || uintptr(destructor) == max(uintptr) do return
	(Destroy_Callback)(destructor)(data)
}

@(private)
c_bytes :: proc(data: rawptr, n: int) -> []u8 {
	if data == nil || n <= 0 do return nil
	return ([^]u8)(data)[:n]
}

@(export)
sqlite3_result_null :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	if ctx := context_of(handle); ctx != nil do context_set(ctx, engine.value_null())
}

@(export)
sqlite3_result_int :: proc "c" (handle: rawptr, value: c.int) {
	context = runtime.default_context()
	if ctx := context_of(handle); ctx != nil do context_set(ctx, engine.value_int(i64(value)))
}

@(export)
sqlite3_result_int64 :: proc "c" (handle: rawptr, value: c.longlong) {
	context = runtime.default_context()
	if ctx := context_of(handle); ctx != nil do context_set(ctx, engine.value_int(i64(value)))
}

@(export)
sqlite3_result_double :: proc "c" (handle: rawptr, value: c.double) {
	context = runtime.default_context()
	if ctx := context_of(handle); ctx != nil do context_set(ctx, engine.value_float(f64(value)))
}

// sqlite3_result_text copies `n` bytes, or up to the NUL when `n` is negative.
@(export)
sqlite3_result_text :: proc "c" (handle: rawptr, text: cstring, n: c.int, destructor: rawptr) {
	context = runtime.default_context()
	result_text(handle, text, i64(n), destructor)
}

@(export)
sqlite3_result_text64 :: proc "c" (handle: rawptr, text: cstring, n: u64, destructor: rawptr, encoding: u8) {
	context = runtime.default_context()
	length := n > u64(max(i64)) ? -1 : i64(n)
	if is_utf16, big_endian := text_encoding_order(c.int(encoding)); is_utf16 {
		result_text16(handle, rawptr(text), length, destructor, big_endian)
		return
	}
	result_text(handle, text, length, destructor)
}

@(private)
result_text :: proc(handle: rawptr, text: cstring, n: i64, destructor: rawptr) {
	ctx := context_of(handle)
	defer release_with(rawptr(text), destructor)
	if ctx == nil do return
	if text == nil {
		context_set(ctx, engine.value_null())
		return
	}
	body := n < 0 ? string(text) : string(c_bytes(rawptr(text), int(n)))
	context_set(ctx, engine.value_string(strings.clone(body)))
}

@(export)
sqlite3_result_blob :: proc "c" (handle: rawptr, data: rawptr, n: c.int, destructor: rawptr) {
	context = runtime.default_context()
	result_blob(handle, data, int(max(n, 0)), destructor)
}

@(export)
sqlite3_result_blob64 :: proc "c" (handle: rawptr, data: rawptr, n: u64, destructor: rawptr) {
	context = runtime.default_context()
	if n > 1 << 30 {
		release_with(data, destructor)
		sqlite3_result_error_toobig(handle)
		return
	}
	result_blob(handle, data, int(n), destructor)
}

@(private)
result_blob :: proc(handle: rawptr, data: rawptr, n: int, destructor: rawptr) {
	ctx := context_of(handle)
	defer release_with(data, destructor)
	if ctx == nil do return
	bytes := make([]u8, n)
	copy(bytes, c_bytes(data, n))
	context_set(ctx, engine.value_bytes(bytes))
}

@(export)
sqlite3_result_zeroblob :: proc "c" (handle: rawptr, n: c.int) {
	context = runtime.default_context()
	_ = sqlite3_result_zeroblob64(handle, u64(max(n, 0)))
}

@(export)
sqlite3_result_zeroblob64 :: proc "c" (handle: rawptr, n: u64) -> c.int {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return SQLITE_MISUSE
	if n > 1 << 30 {
		sqlite3_result_error_toobig(handle)
		return SQLITE_TOOBIG
	}
	context_set(ctx, engine.value_bytes(make([]u8, int(n))))
	return SQLITE_OK
}

@(export)
sqlite3_result_value :: proc "c" (handle: rawptr, value: rawptr) {
	context = runtime.default_context()
	ctx := context_of(handle)
	box := box_of(value)
	if ctx == nil do return
	if box == nil {
		context_set(ctx, engine.value_null())
		return
	}
	context_set(ctx, engine.value_clone(box.value, context.allocator))
}

// sqlite3_result_error makes the call fail with `message` (`n` bytes, or up
// to the NUL when negative); the code is SQLITE_ERROR unless
// sqlite3_result_error_code says otherwise.
@(export)
sqlite3_result_error :: proc "c" (handle: rawptr, message: cstring, n: c.int) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return
	text := ""
	if message != nil do text = n < 0 ? string(message) : string(c_bytes(rawptr(message), int(n)))
	delete(ctx.error_message)
	ctx.error_message = strings.clone(text)
	ctx.has_error = true
	if ctx.error_code == 0 do ctx.error_code = SQLITE_ERROR
}

@(export)
sqlite3_result_error_code :: proc "c" (handle: rawptr, code: c.int) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return
	ctx.error_code = code == SQLITE_OK ? SQLITE_ERROR : code
	if !ctx.has_error {
		ctx.has_error = true
		delete(ctx.error_message)
		ctx.error_message = strings.clone(string(sqlite3_errstr(ctx.error_code)))
	}
}

@(export)
sqlite3_result_error_nomem :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return
	sqlite3_result_error(handle, "out of memory", -1)
	ctx.error_code = SQLITE_NOMEM
}

@(export)
sqlite3_result_error_toobig :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return
	sqlite3_result_error(handle, SQLITE_TOOBIG_TEXT, -1)
	ctx.error_code = SQLITE_TOOBIG
}

@(export)
sqlite3_result_subtype :: proc "c" (handle: rawptr, subtype: c.uint) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return
	// SQLite keeps the low byte; a later sqlite3_result_* call resets it.
	ctx.result.subtype = u8(subtype & 0xff)
}

// sqlite3_overload_function makes sure a call to `name` with `arity`
// arguments prepares even when nothing is registered for it yet (a virtual
// table that overloads it is the use): when this connection has no function of
// that name and arity, it registers one that fails with SQLite's message. Like
// SQLite's, the placeholder hides a builtin of the same name.
@(export)
sqlite3_overload_function :: proc "c" (handle: rawptr, name: cstring, arity: c.int) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil || name == nil || arity < -1 do return SQLITE_MISUSE
	for fn in db.functions {
		if fn.arity == int(arity) && strings.equal_fold(fn.name, string(name)) do return SQLITE_OK
	}
	fn := new(Function)
	fn^ = Function{db = db, name = strings.clone(string(name)), arity = int(arity)}
	if err := engine.store_register_function(db.conn.store, fn.name, fn.arity, overloaded_placeholder, fn, true); err.kind != .None {
		code := fail(db, err)
		function_destroy(fn)
		return code
	}
	append(&db.functions, fn)
	return SQLITE_OK
}

@(private)
overloaded_placeholder :: proc(args: []engine.Value, user: rawptr) -> (engine.Value, engine.Error) {
	fn := (^Function)(user)
	return {}, engine.errf(.Invalid_Argument, "unable to use function %s in the requested context", fn.name)
}
