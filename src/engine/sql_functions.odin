package engine

import "core:slice"
import "core:mem"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

import "base:intrinsics"

eval_call :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	// A call its resolution linked goes straight to what it reaches (A1.8d).
	if link, linked := call_bound(ctx, call.id); linked do return eval_call_linked(ctx, call, link)
	resolve_counted.function_names += 1
	// A row value is taken apart by the comparison that holds it; reaching it
	// here means it stands alone, which SQLite refuses with the same words.
	if call.name == ROW_VALUE_CALL do return {}, errf(.Sql_Syntax, "row value misused")
	if call.name == RAISE_CALL do return eval_raise(ctx, call)
	if (call.filter != nil || len(call.order_by) > 0) && (scalar_minmax(call) || !is_aggregate_name(call.name)) {
		return {}, errf(.Sql_Syntax, "%s may not be used with non-aggregate %s()", call.filter != nil ? "FILTER" : "ORDER BY", call.name)
	}
	if scalar_minmax(call) {
		return eval_scalar_minmax(ctx, call)
	}
	if strings.equal_fold(call.name, "grouping") || strings.equal_fold(call.name, "grouping_id") {
		return eval_grouping(ctx, call)
	}
	if is_aggregate_name(call.name) {
		// A builtin aggregate's answer lives in its statement, as a scalar
		// function's does: the caller copies what it keeps, and the text of a
		// group_concat or a json_group_array no longer stays in the heap. A
		// program's aggregate keeps the caller's allocator, as its functions do.
		if ctx.tx == nil || !builtin_aggregate_name(strings.to_lower(call.name, context.temp_allocator)) {
			return eval_aggregate(ctx, call)
		}
		outer := context.allocator
		value: Value
		err: Error
		{
			context.allocator = ctx.tx.alloc
			value, err = eval_aggregate(ctx, call)
		}
		if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
		return value, err
	}
	args := make([dynamic]Value, 0, len(call.args))
	defer delete(args)
	for arg in call.args {
		value, arg_err := eval_expr(ctx, arg)
		if arg_err.kind != .None do return {}, arg_err
		append(&args, value)
	}
	if ctx.tx == nil do return eval_call_body(ctx, call, args[:], context.allocator)
	// What a function answers lives in the statement's memory, as SQLite's
	// result lives in its statement: the caller copies what it keeps, and the
	// text a function made for one row no longer stays behind in the heap
	// (`upper('abc')` leaked its answer once per call). The arguments are
	// evaluated outside, so a subquery among them keeps its own allocator; an
	// error's message is copied back out, since its reader frees it.
	outer := context.allocator
	value: Value
	err: Error
	{
		context.allocator = ctx.tx.alloc
		value, err = eval_call_body(ctx, call, args[:], outer)
	}
	if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
	return value, err
}

// eval_call_linked runs a call through its link: the arguments, then what
// the link says it reaches, without looking the name up. A virtual table's
// overload depends on the first argument's table and is checked as before.
@(private)
eval_call_linked :: proc(ctx: ^Eval_Ctx, call: Call_Expr, link: ^Call_Link) -> (Value, Error) {
	if link.kind == .Aggregate do return eval_aggregate_linked(ctx, call, link)
	CALL_ARGS_INLINE :: 8
	inline: [CALL_ARGS_INLINE]Value
	args: []Value
	heap: []Value
	if len(call.args) <= CALL_ARGS_INLINE {
		args = inline[:len(call.args)]
	} else {
		heap = make([]Value, len(call.args))
		args = heap
	}
	defer if heap != nil do delete(heap)
	for arg, i in call.args {
		value, arg_err := eval_expr(ctx, arg)
		if arg_err.kind != .None do return {}, arg_err
		args[i] = value
	}
	if ctx.tx == nil do return eval_call_link_body(ctx, call, link, args, context.allocator)
	// What the function answers lives in the statement's memory (eval_call).
	outer := context.allocator
	value: Value
	err: Error
	{
		context.allocator = ctx.tx.alloc
		value, err = eval_call_link_body(ctx, call, link, args, outer)
	}
	if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
	return value, err
}

// eval_aggregate_linked runs one of the engine's aggregates by the name its
// link lowered, its answer in the statement's memory as eval_call keeps it.
@(private)
eval_aggregate_linked :: proc(ctx: ^Eval_Ctx, call: Call_Expr, link: ^Call_Link) -> (Value, Error) {
	if ctx.tx == nil do return eval_aggregate_named(ctx, call, link.lowered, true)
	outer := context.allocator
	value: Value
	err: Error
	{
		context.allocator = ctx.tx.alloc
		value, err = eval_aggregate_named(ctx, call, link.lowered, true)
	}
	if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
	return value, err
}

@(private)
eval_call_link_body :: proc(ctx: ^Eval_Ctx, call: Call_Expr, link: ^Call_Link, args: []Value, outer: mem.Allocator) -> (Value, Error) {
	if ctx.tx != nil && ctx.tx.store != nil && len(ctx.tx.store.vtab_modules) > 0 && len(call.args) > 0 {
		context.allocator = outer
		if fn, user, overloaded := vtab_overload(ctx, call); overloaded do return program_call(ctx, fn, args, user, outer)
		context.allocator = ctx.tx != nil ? ctx.tx.alloc : outer
	}
	switch link.kind {
	case .Host:
		return program_call(ctx, link.host.handler, args, link.host.user, outer)
	case .Json:
		return eval_call_json(call, args)
	case .Time:
		return eval_call_time(ctx, call, args)
	case .Builtin:
		return eval_call_builtin(ctx, call, link.lowered, link.dispatch, args, outer)
	case .None, .Aggregate:
		// An aggregate's link is run before its arguments (eval_aggregate_linked).
	}
	return {}, errf(.Internal, "call %s has no link", call.name)
}

// program_call runs a program's function with `outer`, the caller's allocator,
// and moves the message of an error it answers into the statement's arena:
// eval_call copies every message out of the arena, and a message the program
// made in the heap was kept there.
@(private)
program_call :: proc(
	ctx: ^Eval_Ctx,
	fn: proc(args: []Value, user: rawptr) -> (Value, Error),
	args: []Value,
	user: rawptr,
	outer: mem.Allocator,
) -> (Value, Error) {
	value: Value
	err: Error
	{
		context.allocator = outer
		value, err = fn(args, user)
	}
	if len(err.message) > 0 && ctx.tx != nil {
		kept := strings.clone(err.message, ctx.tx.alloc)
		delete(err.message, outer)
		err.message = kept
	}
	return value, err
}

// eval_call_body answers a scalar function once its arguments are known. A
// program's function runs with `outer`, the caller's allocator: it may do
// anything (open a transaction, keep state), and what it makes is its own.
@(private)
eval_call_body :: proc(ctx: ^Eval_Ctx, call: Call_Expr, args: []Value, outer: mem.Allocator) -> (Value, Error) {
	// A virtual table's module may overload a function for a call whose first
	// argument is one of its columns (xFindFunction).
	if ctx.tx != nil && ctx.tx.store != nil && len(ctx.tx.store.vtab_modules) > 0 && len(call.args) > 0 {
		// Finding the overload may open the module's table: the store keeps it.
		context.allocator = outer
		if fn, user, overloaded := vtab_overload(ctx, call); overloaded do return program_call(ctx, fn, args[:], user, outer)
		context.allocator = ctx.tx != nil ? ctx.tx.alloc : outer
	}
	// A host function registered to override a builtin answers before it, which
	// is how SQLite treats an application-defined function with a builtin's name.
	if store := eval_function_store(ctx); store != nil && len(store.functions) > 0 {
		if def, found, _ := store_function(store, call.name, len(args)); found && def.overrides {
			return program_call(ctx, def.handler, args[:], def.user, outer)
		}
	}

	if json_call_name(call.name) do return eval_call_json(call, args)
	if db_time_has_functions(call.name) do return eval_call_time(ctx, call, args)
	lowered := strings.to_lower(call.name)
	defer delete(lowered)
	return eval_call_builtin(ctx, call, lowered, builtin_dispatch_name(lowered), args, outer)
}

// builtin_dispatch_name is the name the builtin dispatch switches on for a
// lowered call name: SQLite's other spellings of functions the engine has are
// the engine's.
builtin_dispatch_name :: proc(lowered: string) -> string {
	switch lowered {
	case "if":
		return "iif"
	case "ceiling":
		return "ceil"
	case "power":
		return "pow"
	}
	return lowered
}

// eval_call_json answers a JSON function: they parse the document in
// json.odin.
@(private)
eval_call_json :: proc(call: Call_Expr, args: []Value) -> (Value, Error) {
	value, handled, json_err := json_call(call.name, args[:])
	if !handled do return {}, errf(.Internal, "unhandled JSON function %s", call.name)
	// What a function that builds or edits JSON answers is JSON, as SQLite
	// marks it with its subtype (json_extract marks its own containers).
	for builder in ([]string{"json", "json_array", "json_object", "json_set", "json_insert", "json_replace", "json_remove", "json_patch", "json_quote", "json_array_insert"}) {
		if strings.equal_fold(call.name, builder) do return value_json(value), json_err
	}
	return value, json_err
}

// eval_call_time answers a date and time function: they share the argument
// parsing in datetime.odin.
@(private)
eval_call_time :: proc(ctx: ^Eval_Ctx, call: Call_Expr, args: []Value) -> (Value, Error) {
	if strings.equal_fold(call.name, "strftime") {
		if len(args) < 2 {
			return {}, errf(.Invalid_Argument, "strftime() takes a format and a time")
		}
		if args[0].kind != .String {
			return {}, errf(.Invalid_Type, "strftime() expects a text format")
		}
		moment, ok := db_time_parse(args[1:], ctx.now_us)
		if !ok do return value_null(), ERROR_NONE
		text, known := db_time_strftime(args[0].s, moment)
		if !known do return value_null(), ERROR_NONE
		return value_string(text), ERROR_NONE
	}
	value, _ := db_time_call(call.name, args[:], ctx.now_us)
	return value, ERROR_NONE
}

// eval_call_builtin answers one of the engine's scalar functions by its
// dispatch name (builtin_dispatch_name), and a name it does not have from the
// program's functions; `lowered` is the name as written, lowered.
@(private)
eval_call_builtin :: proc(ctx: ^Eval_Ctx, call: Call_Expr, lowered: string, dispatch: string, args: []Value, outer: mem.Allocator) -> (Value, Error) {
	switch dispatch {
	case "ln":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "ln() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "ln() expects a number")
		// SQLite answers NULL outside the domain.
		if number <= 0 do return value_null(), ERROR_NONE
		return value_float(math.ln(number)), ERROR_NONE
	case "likely", "unlikely", "likelihood":
		// Planner hints in SQLite: the value passes through unchanged.
		if len(args) < 1 do return {}, errf(.Invalid_Argument, "%s() needs an argument", call.name)
		return args[0], ERROR_NONE
	case "array_make":
		// ARRAY[...] in PostgreSQL: the elements keep their own kinds, and a
		// column of ARRAY(T) coerces them when the value is stored.
		items := make([]Value, len(args))
		for arg, i in args do items[i] = value_clone(arg, context.allocator)
		return Value{kind = .Array, list = items}, ERROR_NONE
	case "array_get":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "[] takes an array and an index")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array do return {}, errf(.Invalid_Type, "[] needs an array, got %s", value_kind_name(args[0].kind))
		index, index_ok := value_to_i64(args[1])
		if !index_ok do return {}, errf(.Invalid_Type, "[] needs an integer index")
		// One-based, as in PostgreSQL; an index outside the array is NULL rather
		// than an error, which is what a query with a computed index expects.
		if index < 1 || index > i64(len(args[0].list)) do return value_null(), ERROR_NONE
		return value_clone(args[0].list[int(index) - 1], context.allocator), ERROR_NONE
	case "array_length":
		if len(args) < 1 || len(args) > 2 {
			return {}, errf(.Invalid_Argument, "array_length takes an array and an optional dimension")
		}
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array {
			return {}, errf(.Invalid_Type, "array_length needs an array, got %s", value_kind_name(args[0].kind))
		}
		if len(args) == 2 {
			// Only one dimension exists here, so asking for another is NULL, as
			// PostgreSQL answers for a dimension the array does not have.
			if args[1].kind == .Null do return value_null(), ERROR_NONE
			dimension, dimension_ok := value_to_i64(args[1])
			if !dimension_ok do return {}, errf(.Invalid_Type, "array_length needs an integer dimension")
			if dimension != 1 do return value_null(), ERROR_NONE
		}
		return value_int(i64(len(args[0].list))), ERROR_NONE
	case "cardinality":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "cardinality takes one array")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array {
			return {}, errf(.Invalid_Type, "cardinality needs an array, got %s", value_kind_name(args[0].kind))
		}
		return value_int(i64(len(args[0].list))), ERROR_NONE
	case "array_contains", "array_contained", "array_overlap":
		return eval_array_relation(call.name, args[:])
	case "array_append", "array_prepend":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "%s takes an array and a value", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array {
			return {}, errf(.Invalid_Type, "%s needs an array", call.name)
		}
		items := make([]Value, len(args[0].list) + 1)
		offset := 0
		if call.name == "array_prepend" {
			items[0] = value_clone(args[1], context.allocator)
			offset = 1
		}
		for item, i in args[0].list do items[i + offset] = value_clone(item, context.allocator)
		if call.name == "array_append" {
			items[len(args[0].list)] = value_clone(args[1], context.allocator)
		}
		return Value{kind = .Array, list = items}, ERROR_NONE
	case "snippet", "highlight":
		if len(args) != 2 {
			return {}, errf(.Invalid_Argument, "%s() takes text and a pattern", call.name)
		}
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "%s() expects text for both arguments", call.name)
		}
		window := strings.equal_fold(call.name, "snippet")
		return value_string(fts_mark(args[0].s, args[1].s, window)), ERROR_NONE
	case "lower":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "lower() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if sqlite_rules_on() do return value_string(ascii_case(sqlite_value_text(args[0], context.temp_allocator), false)), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "lower() expects text")
		return value_string(strings.to_lower(args[0].s)), ERROR_NONE
	case "upper":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "upper() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if sqlite_rules_on() do return value_string(ascii_case(sqlite_value_text(args[0], context.temp_allocator), true)), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "upper() expects text")
		return value_string(strings.to_upper(args[0].s)), ERROR_NONE
	case "length", "char_length":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "length() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .String do return value_int(i64(text_char_count(args[0].s))), ERROR_NONE
		if args[0].kind == .Bytes do return value_int(i64(len(args[0].bytes))), ERROR_NONE
		return {}, errf(.Invalid_Type, "length() expects text or bytes")
	case "abs":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "abs() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .Float {
			return value_float(abs_f64(args[0].f)), ERROR_NONE
		}
		number, ok := value_to_i64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "abs() expects a number")
		// abs(min(i64)) has no answer in 64 bits; SQLite answers "integer
		// overflow" and so does this engine rather than return a negative.
		if number == min(i64) do return {}, integer_overflow_error()
		return value_int(number < 0 ? -number : number), ERROR_NONE
	case "substr", "substring":
		if len(args) < 2 || len(args) > 3 {
			return {}, errf(.Invalid_Argument, "substr() takes two or three arguments")
		}
		// NULL is not text and is not an error: SQLite answers NULL.
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if len(args) == 3 && args[2].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "substr() expects text")
		text := args[0].s
		start_value, ok := value_to_i64(args[1])
		if !ok do return {}, errf(.Invalid_Type, "substr() expects an integer start")
		chars := text_char_count(text)
		begin := int(start_value)
		if len(args) == 2 {
			// No length asks for the rest of the text. A start at or before the
			// first character (including zero) takes the whole string.
			if begin > 0 {
				begin -= 1
			} else if begin < 0 {
				begin += chars
			}
			if begin < 0 do begin = 0
			if begin > chars do begin = chars
			return value_string(text[text_byte_at(text, begin):]), ERROR_NONE
		}
		count_value, count_ok := value_to_i64(args[2])
		if !count_ok do return {}, errf(.Invalid_Type, "substr() expects an integer length")
		count := int(count_value)
		from_end := false
		if count < 0 {
			// A negative length is the number of characters before the start.
			count = -count
			from_end = true
		}
		if begin < 0 {
			begin += chars
			if begin < 0 {
				count += begin
				if count < 0 do count = 0
				begin = 0
			}
		} else if begin > 0 {
			begin -= 1
		} else if count > 0 {
			// A start of zero names the character before the first one, so a
			// positive length loses one character.
			count -= 1
		}
		if from_end {
			begin -= count
			if begin < 0 {
				count += begin
				begin = 0
			}
		}
		if begin > chars do begin = chars
		if count > chars do count = chars
		if begin + count > chars do count = chars - begin
		if count < 0 do count = 0
		return value_string(text[text_byte_at(text, begin):text_byte_at(text, begin + count)]), ERROR_NONE
	case "trim", "ltrim", "rtrim":
		if len(args) < 1 || len(args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes one or two arguments", call.name)
		}
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "%s() expects text", call.name)
		// The second argument is the set of characters to remove; the default is
		// the space, as in SQLite (not every whitespace).
		set := " "
		if len(args) == 2 {
			if args[1].kind == .Null do return value_null(), ERROR_NONE
			if args[1].kind != .String do return {}, errf(.Invalid_Type, "%s() expects a text set", call.name)
			set = args[1].s
		}
		text := args[0].s
		begin := 0
		end := len(text)
		lower := strings.to_lower(call.name)
		defer delete(lower)
		if lower != "rtrim" {
			for begin < end && strings.index_byte(set, text[begin]) >= 0 do begin += 1
		}
		if lower != "ltrim" {
			for end > begin && strings.index_byte(set, text[end - 1]) >= 0 do end -= 1
		}
		return value_string(strings.clone(text[begin:end])), ERROR_NONE
	case "replace":
		if len(args) != 3 do return {}, errf(.Invalid_Argument, "replace() takes three arguments")
		for arg in args do if arg.kind == .Null do return value_null(), ERROR_NONE
		for arg in args {
			if arg.kind != .String do return {}, errf(.Invalid_Type, "replace() expects text")
		}
		replaced, _ := strings.replace_all(args[0].s, args[1].s, args[2].s)
		return value_string(replaced), ERROR_NONE
	case "concat":
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		for arg in args {
			if arg.kind == .Null do continue
			strings.write_string(&builder, value_format(arg, context.temp_allocator))
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "sign":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sign() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if number, ok := value_to_f64(args[0]); ok {
			if number > 0 do return value_int(1), ERROR_NONE
			if number < 0 do return value_int(-1), ERROR_NONE
			return value_int(0), ERROR_NONE
		}
		return {}, errf(.Invalid_Type, "sign() expects a number")
	case "round":
		if len(args) < 1 || len(args) > 2 do return {}, errf(.Invalid_Argument, "round() takes one or two arguments")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "round() expects a number")
		digits := i64(0)
		if len(args) == 2 {
			parsed, digits_ok := value_to_i64(args[1])
			if !digits_ok do return {}, errf(.Invalid_Type, "round() expects an integer digit count")
			digits = parsed
		}
		scale := math.pow(10, f64(digits))
		return value_float(math.round(number * scale) / scale), ERROR_NONE
	case "floor", "ceil":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		if strings.equal_fold(call.name, "floor") do return value_float(math.floor(number)), ERROR_NONE
		return value_float(math.ceil(number)), ERROR_NONE
	case "sqrt":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqrt() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "sqrt() expects a number")
		if number < 0 do return {}, errf(.Invalid_Argument, "sqrt() needs a non-negative number")
		return value_float(math.sqrt(number)), ERROR_NONE
	case "sinh", "cosh", "tanh", "asinh", "acosh", "atanh":
		// The hyperbolic family, one argument. Outside its domain acosh and atanh
		// answer NULL, as SQLite does for a number with no answer.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		switch dispatch {
		case "sinh":
			return value_float(math.sinh(number)), ERROR_NONE
		case "cosh":
			return value_float(math.cosh(number)), ERROR_NONE
		case "tanh":
			return value_float(math.tanh(number)), ERROR_NONE
		case "asinh":
			return value_float(math.asinh(number)), ERROR_NONE
		case "acosh":
			if number < 1 do return value_null(), ERROR_NONE
			return value_float(math.acosh(number)), ERROR_NONE
		case "atanh":
			if number <= -1 || number >= 1 do return value_null(), ERROR_NONE
			return value_float(math.atanh(number)), ERROR_NONE
		}
		return value_null(), ERROR_NONE
	case "affinity":
		// SQLite's affinity() names the storage class the value has.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "affinity() takes one argument")
		#partial switch args[0].kind {
		case .Int:
			return value_string(strings.clone("INTEGER", context.allocator)), ERROR_NONE
		case .Float:
			return value_string(strings.clone("REAL", context.allocator)), ERROR_NONE
		case .String:
			return value_string(strings.clone("TEXT", context.allocator)), ERROR_NONE
		case .Bytes:
			return value_string(strings.clone("BLOB", context.allocator)), ERROR_NONE
		}
		return value_string(strings.clone("BLOB", context.allocator)), ERROR_NONE
	case "unistr":
		// `\XXXX` is a UTF-16 code unit, `\+XXXXXX` and `\UXXXXXXXX` a code point,
		// and a doubled backslash is one backslash: what unistr_quote writes, unistr
		// reads.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unistr() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		return value_string(unistr_decode(value_to_text(args[0]))), ERROR_NONE
	case "unistr_quote":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unistr_quote() takes one argument")
		if args[0].kind == .Null do return value_string(strings.clone("NULL", context.allocator)), ERROR_NONE
		return value_string(unistr_quote(value_to_text(args[0]))), ERROR_NONE
	case "timediff":
		// The difference as a signed calendar span, which is the form SQLite
		// answers: +YYYY-MM-DD HH:MM:SS.SSS.
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "timediff() takes two times")
		first, first_ok := db_time_parse(args[0:1], ctx.now_us)
		second, second_ok := db_time_parse(args[1:2], ctx.now_us)
		if !first_ok || !second_ok do return value_null(), ERROR_NONE
		return value_string(timediff_text(first, second)), ERROR_NONE
	case "soundex":
		// SQLite's soundex: the first letter, then one digit per consonant group,
		// three of them, zero-padded. Vowels and h, w, y separate groups without
		// earning a digit of their own.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "soundex() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := value_to_text(args[0])
		return value_string(soundex_encode(text)), ERROR_NONE
	case "sqlite_source_id":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "sqlite_source_id() takes no arguments")
		return value_string(strings.clone("miraidb", context.allocator)), ERROR_NONE
	case "sqlite_compileoption_used":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqlite_compileoption_used() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		option := value_to_text(args[0])
		used := strings.equal_fold(option, "MIRAIDB") || strings.equal_fold(option, "SQLITE_ENABLE_JSON1") ? 1 : 0
		return value_int(i64(used)), ERROR_NONE
	case "sqlite_compileoption_get":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqlite_compileoption_get() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		index, index_ok := value_to_i64(args[0])
		if !index_ok do return {}, errf(.Invalid_Type, "sqlite_compileoption_get() expects a number")
		// The one option there is, then nothing: a list ends the way a list ends.
		if index == 0 do return value_string(strings.clone("MIRAIDB", context.allocator)), ERROR_NONE
		return value_null(), ERROR_NONE
	case "pow":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "pow() takes two arguments")
		base, base_ok := value_to_f64(args[0])
		exponent, exponent_ok := value_to_f64(args[1])
		if !base_ok || !exponent_ok do return {}, errf(.Invalid_Type, "pow() expects numbers")
		return value_float(math.pow(base, exponent)), ERROR_NONE
	case "mod":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "mod() takes two arguments")
		left, left_ok := value_to_i64(args[0])
		right, right_ok := value_to_i64(args[1])
		if !left_ok || !right_ok do return {}, errf(.Invalid_Type, "mod() expects integers")
		if right == 0 do return {}, errf(.Invalid_Argument, "mod() by zero")
		return value_int(left % right), ERROR_NONE
	case "nullif":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "nullif() takes two arguments")
		if value_equal(args[0], args[1]) do return value_null(), ERROR_NONE
		return args[0], ERROR_NONE
	case "coalesce", "ifnull":
		for value in args {
			if value.kind != .Null do return value, ERROR_NONE
		}
		return value_null(), ERROR_NONE
	// The session functions a PostgreSQL client asks for on connect. The answers
	// name this engine, so a driver that logs them says what it talks to.
	case "version":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "version() takes no arguments")
		return value_string(ENGINE_VERSION_TEXT), ERROR_NONE
	case "current_database", "current_catalog":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "%s() takes no arguments", lowered)
		return value_string("miraidb"), ERROR_NONE
	case "current_schema":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "current_schema() takes no arguments")
		return value_string("public"), ERROR_NONE
	case "current_user", "session_user", "user":
		// The role name. An identity is not a role, so this is the one name a
		// session has; `current_identity()` is the caller the policies see.
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "%s takes no arguments", lowered)
		return value_string("miraidb"), ERROR_NONE
	case "pg_backend_pid":
		return value_int(0), ERROR_NONE
	case "now", "current_timestamp":
		if len(args) != 0 {
			return {}, errf(.Invalid_Argument, "now() takes no arguments")
		}
		return value_timestamp(Timestamp(ctx.now_us)), ERROR_NONE
	case "has_role":
		if len(args) != 1 {
			return {}, errf(.Invalid_Argument, "has_role() takes one argument")
		}
		if args[0].kind != .String {
			return {}, errf(.Invalid_Type, "has_role() expects a role name")
		}
		if ctx.tx == nil do return value_bool(false), ERROR_NONE
		// A nested statement reads the catalog: it runs in the caller's memory.
		context.allocator = outer
		holds, role_err := has_role(ctx.tx, args[0].s)
		if role_err.kind != .None do return {}, role_err
		return value_bool(holds), ERROR_NONE
	case "current_identity", "sender":
		if len(args) != 0 {
			return {}, errf(.Invalid_Argument, "current_identity() takes no arguments")
		}
		if ctx.tx == nil do return value_identity(Identity{}), ERROR_NONE
		return value_identity(ctx.tx.store.identity), ERROR_NONE
	case "uuid":
		return {}, errf(.Sql_Unsupported, "uuid() needs a randomness source the engine does not have")
	case "typeof":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "typeof() takes one argument")
		#partial switch args[0].kind {
		case .Null:
			return value_string("null"), ERROR_NONE
		case .Int, .Uint, .Bool, .Int128, .Uint128:
			return value_string("integer"), ERROR_NONE
		case .Float:
			return value_string("real"), ERROR_NONE
		case .Bytes:
			return value_string("blob"), ERROR_NONE
		}
		return value_string("text"), ERROR_NONE
	case "quote":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "quote() takes one argument")
		return value_string(sq_literal(args[0])), ERROR_NONE
	case "hex":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "hex() takes one argument")
		return value_string(sq_hex(args[0])), ERROR_NONE
	case "iif":
		if len(args) != 3 do return {}, errf(.Invalid_Argument, "iif() takes three arguments")
		truth, truth_err := sq_truthy(args[0])
		if truth_err.kind != .None do return {}, truth_err
		return args[1] if truth else args[2], ERROR_NONE
	case "sqlite_version":
		return value_string("3.54.1"), ERROR_NONE
	case "instr":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "instr() takes two arguments")
		// NULL first: the check after the type test could never be reached.
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "instr() expects text")
		}
		at := strings.index(args[0].s, args[1].s)
		if at < 0 do return value_int(0), ERROR_NONE
		// The answer is a character position, the offset found is a byte one.
		return value_int(i64(text_char_count(args[0].s[:at])) + 1), ERROR_NONE
	case "char":
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		for arg in args {
			// SQLite reads a NULL argument as code point 0.
			if arg.kind == .Null {
				strings.write_byte(&builder, 0)
				continue
			}
			if arg.kind != .Int do return {}, errf(.Invalid_Type, "char() expects integers")
			strings.write_rune(&builder, rune(arg.i))
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "changes":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "changes() takes no arguments")
		return value_int(ctx.tx.store.last_changes), ERROR_NONE
	case "last_insert_rowid":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "last_insert_rowid() takes no arguments")
		return value_int(ctx.tx.store.last_row_id), ERROR_NONE
	case "total_changes":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "total_changes() takes no arguments")
		return value_int(ctx.tx.store.total_changes), ERROR_NONE
	case "log", "log10", "log2", "exp", "sin", "cos", "tan", "asin", "acos", "atan", "degrees", "radians", "trunc":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		inner_lower := strings.to_lower(call.name)
		defer delete(inner_lower)
		switch inner_lower {
		case "log", "log10":
			if number <= 0 do return value_null(), ERROR_NONE
			return value_float(math.log10(number)), ERROR_NONE
		case "log2":
			if number <= 0 do return value_null(), ERROR_NONE
			return value_float(math.log2(number)), ERROR_NONE
		case "exp":
			return value_float(math.exp(number)), ERROR_NONE
		case "sin":
			return value_float(math.sin(number)), ERROR_NONE
		case "cos":
			return value_float(math.cos(number)), ERROR_NONE
		case "tan":
			return value_float(math.tan(number)), ERROR_NONE
		case "asin":
			return value_float(math.asin(number)), ERROR_NONE
		case "acos":
			return value_float(math.acos(number)), ERROR_NONE
		case "atan":
			return value_float(math.atan(number)), ERROR_NONE
		case "degrees":
			return value_float(number * 180 / math.PI), ERROR_NONE
		case "radians":
			return value_float(number * math.PI / 180), ERROR_NONE
		case "trunc":
			return value_float(math.trunc(number)), ERROR_NONE
		case:
		}
		return {}, errf(.Internal, "unknown math function %s", call.name)
	case "atan2":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "atan2() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		y, y_ok := value_to_f64(args[0])
		x, x_ok := value_to_f64(args[1])
		if !y_ok || !x_ok do return {}, errf(.Invalid_Type, "atan2() expects numbers")
		return value_float(math.atan2(y, x)), ERROR_NONE
	case "pi":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "pi() takes no arguments")
		return value_float(math.PI), ERROR_NONE
	case "octet_length":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "octet_length() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .String do return value_int(i64(len(args[0].s))), ERROR_NONE
		if args[0].kind == .Bytes do return value_int(i64(len(args[0].bytes))), ERROR_NONE
		text := value_format(args[0], context.allocator)
		defer delete(text)
		return value_int(i64(len(text))), ERROR_NONE
	case "unicode":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unicode() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := args[0].kind == .String ? strings.clone(args[0].s) : value_format(args[0], context.allocator)
		defer delete(text)
		if len(text) == 0 do return value_null(), ERROR_NONE
		char, _ := utf8.decode_rune_in_string(text)
		return value_int(i64(char)), ERROR_NONE
	case "unhex":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unhex() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := args[0].kind == .String ? args[0].s : value_format(args[0], context.allocator)
		cloned := args[0].kind != .String
		defer if cloned do delete(text)
		if len(text) % 2 != 0 do return value_null(), ERROR_NONE
		out := make([]u8, len(text) / 2, context.allocator)
		for i in 0 ..< len(out) {
			high, high_ok := sql_hex_digit(text[i * 2])
			low, low_ok := sql_hex_digit(text[i * 2 + 1])
			if !high_ok || !low_ok do return value_null(), ERROR_NONE
			out[i] = u8(high << 4 | low)
		}
		return value_bytes(out), ERROR_NONE
	case "zeroblob", "randomblob":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		size, ok := value_to_i64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects an integer", call.name)
		if size < 0 do return value_null(), ERROR_NONE
		if size > 1 << 20 do size = 1 << 20
		buffer := make([]u8, int(size), context.allocator)
		if strings.equal_fold(call.name, "randomblob") {
			for i in 0 ..< len(buffer) do buffer[i] = u8(rng_next())
		}
		return value_bytes(buffer), ERROR_NONE
	case "random":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "random() takes no arguments")
		return value_int(i64(rng_next())), ERROR_NONE
	case "concat_ws":
		if len(args) < 2 do return {}, errf(.Invalid_Argument, "concat_ws() takes a separator and values")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		separator := value_format(args[0], context.allocator)
		defer delete(separator)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		first := true
		for arg in args[1:] {
			if arg.kind == .Null do continue
			if !first do strings.write_string(&builder, separator)
			piece := value_format(arg, context.allocator)
			strings.write_string(&builder, piece)
			delete(piece)
			first = false
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "like":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "like() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "like() expects text")
		}
		return value_bool(like_match(args[1].s, args[0].s, true, 0)), ERROR_NONE
	case "glob":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "glob() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "glob() expects text")
		}
		return value_bool(glob_match(args[1].s, args[0].s)), ERROR_NONE
	case "format", "printf":
		if len(args) == 0 do return {}, errf(.Invalid_Argument, "format() needs a pattern")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		// The pattern is the first argument's text, whatever its type, and
		// the format is SQLite's own (sqlite_printf.odin).
		pattern := args[0].kind == .String ? args[0].s : sqlite_value_text(args[0], context.temp_allocator)
		text, too_big := sqlite_printf_values(pattern, args[1:])
		if too_big do return {}, errf(.Invalid_Argument, "string or blob too big")
		return value_string(text), ERROR_NONE
	}
	// A host function answers last, so the builtins keep their names. The count
	// picks the function, as in SQLite: a name registered with other counts is
	// the caller's mistake, in SQLite's words.
	if store := eval_function_store(ctx); store != nil {
		def, found, named := store_function(store, call.name, len(args))
		if found do return program_call(ctx, def.handler, args[:], def.user, outer)
		if named do return {}, errf(.Invalid_Argument, "wrong number of arguments to function %s()", call.name)
	}
	return {}, errf(.Sql_Unsupported, "unknown function %s", call.name)
}

@(private)
abs_f64 :: proc(f: f64) -> f64 {
	return f < 0 ? -f : f
}

// eval_scalar_minmax is min(a, b, ...) as SQLite answers it: NULL if any
// argument is NULL, otherwise the smallest or largest of them.
// arrays_from_text turns a text operand into an array when the other side is
// one and the text is written as PostgreSQL's array input. Anything else is left
// alone, so a text column compared with text still compares as text.
@(private)
arrays_from_text :: proc(left, right: Value) -> (Value, Value) {
	if left.kind == .Array && right.kind == .String {
		if parsed, err := array_parse_text(right.s, array_element_type(left)); err.kind == .None {
			return left, parsed
		}
	}
	if right.kind == .Array && left.kind == .String {
		if parsed, err := array_parse_text(left.s, array_element_type(right)); err.kind == .None {
			return parsed, right
		}
	}
	return left, right
}

// array_element_type is the type of an array's elements, read from the elements
// themselves: the engine stores kinds, not a declared element type.
@(private)
array_element_type :: proc(array: Value) -> Column_Type {
	for item in array.list {
		#partial switch item.kind {
		case .Null:
			continue
		case .Int:
			return Column_Type{kind = .Int, width = 8}
		case .Uint:
			return Column_Type{kind = .Uint, width = 8}
		case .Float:
			return Column_Type{kind = .Float, width = 8}
		case .Bool:
			return Column_Type{kind = .Bool}
		case .Bytes:
			return Column_Type{kind = .Bytes}
		case:
			return Column_Type{kind = .String}
		}
	}
	return Column_Type{kind = .String}
}

// array_concat implements `||` when either side is an array: two arrays join
// their elements, and a single value is appended or prepended.
@(private)
array_concat :: proc(left, right: Value) -> (Value, Error) {
	if left.kind == .Null || right.kind == .Null do return value_null(), ERROR_NONE
	if left.kind != .Array && right.kind != .Array {
		return {}, errf(.Invalid_Type, "|| needs text or an array")
	}
	left_items := left.kind == .Array ? left.list : ([]Value{left})
	right_items := right.kind == .Array ? right.list : ([]Value{right})
	items := make([]Value, len(left_items) + len(right_items))
	for item, i in left_items do items[i] = value_clone(item, context.allocator)
	for item, i in right_items do items[i + len(left_items)] = value_clone(item, context.allocator)
	return Value{kind = .Array, list = items}, ERROR_NONE
}

// array_relation answers PostgreSQL's set operators: `@>` contains, `<@` is
// contained by, `&&` overlaps. One function for all three, because the only
// difference is which side is searched.
@(private)
eval_array_relation :: proc(name: string, args: []Value) -> (Value, Error) {
	if len(args) != 2 do return {}, errf(.Invalid_Argument, "%s takes two arrays", name)
	if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
	// A driver that did not know the parameter's type sends `{b}` as text; the
	// array on the other side says what its elements are.
	first, second := args[0], args[1]
	if first.kind == .Array && second.kind == .String {
		if parsed, err := array_parse_text(second.s, array_element_type(first)); err.kind == .None {
			second = parsed
		}
	}
	if second.kind == .Array && first.kind == .String {
		if parsed, err := array_parse_text(first.s, array_element_type(second)); err.kind == .None {
			first = parsed
		}
	}
	container := first
	needle := second
	if name == "array_contained" {
		container = args[1]
		needle = args[0]
	}
	if container.kind != .Array || (needle.kind != .Array && needle.kind == .Null) {
		if container.kind != .Array {
			return {}, errf(.Invalid_Type, "%s needs an array on both sides", name)
		}
	}
	if name == "array_overlap" {
		if first.kind != .Array || second.kind != .Array {
			return {}, errf(.Invalid_Type, "&& needs an array on both sides")
		}
		for one in first.list {
			for other in second.list {
				if value_equal(one, other) do return value_bool(true), ERROR_NONE
			}
		}
		return value_bool(false), ERROR_NONE
	}
	// `a @> b` is b a subset of a, and `a @> scalar` is a holding that value.
	candidates := needle.kind == .Array ? needle.list : ([]Value{needle})
	for candidate in candidates {
		found := false
		for element in container.list {
			if value_equal(element, candidate) {
				found = true
				break
			}
		}
		if !found do return value_bool(false), ERROR_NONE
	}
	return value_bool(true), ERROR_NONE
}

@(private)
eval_scalar_minmax :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	want_min := strings.equal_fold(call.name, "min")
	best: Value
	have := false
	for arg in call.args {
		value, eval_err := eval_expr(ctx, arg)
		if eval_err.kind != .None do return {}, eval_err
		if value.kind == .Null do return value_null(), ERROR_NONE
		if !have {
			best = value
			have = true
			continue
		}
		order, comparable := value_compare(value, best)
		if !comparable {
			return {}, errf(.Invalid_Type, "%s() mixes incompatible types", call.name)
		}
		if (want_min && order == .Less) || (!want_min && order == .Greater) do best = value
	}
	// The answer lives in the statement's memory, like any call's (eval_call).
	return value_clone(best, ctx.tx != nil ? ctx.tx.alloc : context.allocator), ERROR_NONE
}

eval_aggregate :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	if call.filter != nil || len(call.order_by) > 0 do return eval_aggregate_chosen(ctx, call)
	name := strings.to_lower(call.name)
	defer delete(name)
	return eval_aggregate_named(ctx, call, name, builtin_aggregate_name(name))
}

// eval_aggregate_named is eval_aggregate of a call without FILTER or ORDER BY
// whose name is `name`, lowered, and `builtin` when it is one of the engine's
// aggregates.
@(private)
eval_aggregate_named :: proc(ctx: ^Eval_Ctx, call: Call_Expr, name: string, builtin: bool) -> (Value, Error) {
	if ctx.stream != nil {
		acc := agg_stream_lookup(ctx.stream, call)
		if acc == nil {
			return {}, errf(.Internal, "aggregate %s was not accumulated by the scan", call.name)
		}
		return agg_stream_value(acc)
	}
	rows := ctx.group
	single_rows: [1][]Source
	if !ctx.grouped {
		single_rows[0] = ctx.sources
		rows = single_rows[:]
	}
	if !builtin do return eval_host_aggregate(ctx, call, rows)
	// jsonb_group_array and jsonb_group_object build what their json_ forms
	// build, as JSONB.
	if plain, is_jsonb := jsonb_aggregate_plain(call); is_jsonb {
		text, err := eval_aggregate(ctx, plain)
		if err.kind != .None do return {}, err
		return jsonb_from_text(text)
	}

	if name == "count" {
		if call.star || len(call.args) == 0 {
			return value_int(i64(len(rows))), ERROR_NONE
		}
		count := 0
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind == .Null do continue
			if call.is_distinct {
				key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
				_, repeated := keys[key]
				if repeated {
					delete(key)
				} else {
					keys[key] = true
				}
				if repeated do continue
			}
			count += 1
		}
		return value_int(i64(count)), ERROR_NONE
	}

	if name == "json_group_array" {
		if call.star || len(call.args) != 1 {
			return {}, errf(.Invalid_Argument, "json_group_array() takes one argument")
		}
		items := make([dynamic]Json_Value, 0, len(rows))
		defer delete(items)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, value_err := eval_expr(&sub, call.args[0])
			if value_err.kind != .None do return {}, value_err
			append(&items, json_from_value(value, context.temp_allocator))
		}
		text := json_write(Json_Value{kind = .Array, items = items[:]}, context.allocator)
		return value_json(value_string(text)), ERROR_NONE
	}
	if name == "median" || name == "percentile" || name == "percentile_cont" ||
	   name == "percentile_disc" {
		// The ordered aggregates SQLite 3.51 added: median(Y) is the 0.5
		// percentile, percentile_cont interpolates between two values and
		// percentile_disc takes one, and percentile() reads its argument as a
		// percentage where the other two read a fraction.
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes a value and a fraction", name)
		}
		fraction := 0.5
		if len(call.args) == 2 {
			value, value_err := eval_expr(ctx, call.args[1])
			if value_err.kind != .None do return {}, value_err
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects a number as its fraction", name)
			fraction = strings.equal_fold(name, "percentile") ? number / 100 : number
			if fraction < 0 || fraction > 1 {
				return {}, errf(
					.Invalid_Argument,
					"the fraction argument to %s() is not between 0.0 and 1.0",
					name,
				)
			}
		}
		numbers := make([dynamic]f64, 0, len(rows))
		defer delete(numbers)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, value_err := eval_expr(&sub, call.args[0])
			if value_err.kind != .None do return {}, value_err
			if value.kind == .Null do continue
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			append(&numbers, number)
		}
		if len(numbers) == 0 do return value_null(), ERROR_NONE
		slice.sort(numbers[:])
		if strings.equal_fold(name, "percentile_disc") {
			index := int(math.floor(fraction * f64(len(numbers) - 1)))
			return value_float(numbers[index]), ERROR_NONE
		}
		position := fraction * f64(len(numbers) - 1)
		low := int(math.floor(position))
		high := int(math.ceil(position))
		if low == high do return value_float(numbers[low]), ERROR_NONE
		weight := position - f64(low)
		return value_float(numbers[low] * (1 - weight) + numbers[high] * weight), ERROR_NONE
	}
	if name == "json_group_object" {
		if len(call.args) != 2 {
			return {}, errf(.Invalid_Argument, "json_group_object() takes a key and a value")
		}
		keys := make([dynamic]string, 0, len(rows))
		defer delete(keys)
		items := make([dynamic]Json_Value, 0, len(rows))
		defer delete(items)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			key, key_err := eval_expr(&sub, call.args[0])
			if key_err.kind != .None do return {}, key_err
			if key.kind == .Null do continue
			value, value_err := eval_expr(&sub, call.args[1])
			if value_err.kind != .None do return {}, value_err
			append(&keys, value_to_text(key))
			append(&items, json_from_value(value, context.temp_allocator))
		}
		text := json_write(Json_Value{kind = .Object, keys = keys[:], values = items[:]}, context.allocator)
		return value_json(value_string(text)), ERROR_NONE
	}
	if name == "median" || name == "percentile" || name == "percentile_cont" ||
	   name == "percentile_disc" {
		// The ordered aggregates SQLite 3.51 added: median(Y) is the 0.5
		// percentile, percentile_cont interpolates between two values and
		// percentile_disc takes one, and percentile() reads its argument as a
		// percentage where the other two read a fraction.
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes a value and a fraction", name)
		}
		fraction := 0.5
		if len(call.args) == 2 {
			value, value_err := eval_expr(ctx, call.args[1])
			if value_err.kind != .None do return {}, value_err
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects a number as its fraction", name)
			fraction = strings.equal_fold(name, "percentile") ? number / 100 : number
			if fraction < 0 || fraction > 1 {
				return {}, errf(
					.Invalid_Argument,
					"the fraction argument to %s() is not between 0.0 and 1.0",
					name,
				)
			}
		}
		numbers := make([dynamic]f64, 0, len(rows))
		defer delete(numbers)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, value_err := eval_expr(&sub, call.args[0])
			if value_err.kind != .None do return {}, value_err
			if value.kind == .Null do continue
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			append(&numbers, number)
		}
		if len(numbers) == 0 do return value_null(), ERROR_NONE
		slice.sort(numbers[:])
		if strings.equal_fold(name, "percentile_disc") {
			index := int(math.floor(fraction * f64(len(numbers) - 1)))
			return value_float(numbers[index]), ERROR_NONE
		}
		position := fraction * f64(len(numbers) - 1)
		low := int(math.floor(position))
		high := int(math.ceil(position))
		if low == high do return value_float(numbers[low]), ERROR_NONE
		weight := position - f64(low)
		return value_float(numbers[low] * (1 - weight) + numbers[high] * weight), ERROR_NONE
	}
	if name == "json_group_object" {
		// One document from the group: the first argument is the key, the second
		// the value, and a NULL key is skipped as SQLite skips it.
		if len(call.args) != 2 {
			return {}, errf(.Invalid_Argument, "json_group_object() takes a key and a value")
		}
		keys := make([dynamic]string, 0, len(rows))
		defer delete(keys)
		items := make([dynamic]Json_Value, 0, len(rows))
		defer delete(items)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			key, key_err := eval_expr(&sub, call.args[0])
			if key_err.kind != .None do return {}, key_err
			if key.kind == .Null do continue
			value, value_err := eval_expr(&sub, call.args[1])
			if value_err.kind != .None do return {}, value_err
			append(&keys, value_to_text(key))
			append(&items, json_from_value(value, context.temp_allocator))
		}
		text := json_write(Json_Value{kind = .Object, keys = keys[:], values = items[:]}, context.allocator)
		return value_json(value_string(text)), ERROR_NONE
	}

	if name == "group_concat" || name == "string_agg" {
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes one or two arguments", name)
		}
		separator := ","
		separator_text: string
		if len(call.args) == 2 {
			value, eval_err := eval_expr(ctx, call.args[1])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind != .Null {
				separator_text = value_format(value, context.allocator)
				separator = separator_text
			}
		}
		defer if len(separator_text) > 0 do delete(separator_text)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		seen_any := false
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind == .Null do continue
			if call.is_distinct {
				key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
				_, repeated := keys[key]
				if repeated {
					delete(key)
				} else {
					keys[key] = true
				}
				if repeated do continue
			}
			if seen_any do strings.write_string(&builder, separator)
			piece := value_format(value, context.allocator)
			strings.write_string(&builder, piece)
			delete(piece)
			seen_any = true
		}
		if !seen_any do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	}

	if name == "array_agg" {
		// The same aggregate over sources: every row's value, NULLs included,
		// and NULL for an empty set.
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		list := make([dynamic]Value, 0, len(rows))
		defer {
			for item in list do value_deep_free(item, context.allocator)
			delete(list)
		}
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			if len(call.args) != 1 {
				return {}, errf(.Invalid_Argument, "%s() takes exactly one argument", name)
			}
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if call.is_distinct {
				key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
				_, repeated := keys[key]
				if repeated {
					delete(key)
					continue
				}
				keys[key] = true
			}
			append(&list, value_clone(value, context.allocator))
		}
		if len(list) == 0 do return value_null(), ERROR_NONE
		items := make([]Value, len(list))
		for item, i in list do items[i] = item
		// The list's buffer is freed above; the values moved into `items`.
		clear(&list)
		return Value{kind = .Array, list = items}, ERROR_NONE
	}

	accumulator: Value = value_null()
	seen := 0
	sum_float := f64(0)
	sum_int := i64(0)
	sum_128 := i128(0)
	uses_float := name == "total"
	uses_128 := false
	keys: map[string]bool
	if call.is_distinct do keys = make(map[string]bool)
	defer agg_distinct_destroy(&keys)
	for sources in rows {
		sub := ctx^
		sub.sources = sources
		if len(call.args) != 1 {
			return {}, errf(.Invalid_Argument, "%s() takes exactly one argument", name)
		}
		value, eval_err := eval_expr(&sub, call.args[0])
		if eval_err.kind != .None do return {}, eval_err
		if value.kind == .Null do continue
		if call.is_distinct {
			key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
			_, repeated := keys[key]
			if repeated {
				delete(key)
			} else {
				keys[key] = true
			}
			if repeated do continue
		}
		seen += 1
		switch name {
		case "min":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "min() mixes incompatible types")
				if order == .Less do accumulator = value
			}
		case "max":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "max() mixes incompatible types")
				if order == .Greater do accumulator = value
			}
		case "sum", "total", "avg":
			// SQLite adds a boolean as its integer and a text by its number.
			operand := sqlite_rules_on() ? sqlite_sum_operand(value) : value
			if !value_is_numeric(operand) {
				return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			}
			if operand.kind == .Float && !uses_float {
				// The integers added before the first REAL are part of the sum: SQLite's
				// sum() of 1 and 2.5 is 3.5. It used to answer 2.5.
				uses_float = true
				sum_float = uses_128 ? f64(sum_128) : f64(sum_int)
			}
			if uses_float {
				number, _ := value_to_f64(operand)
				sum_float += number
			} else if operand.kind == .Int128 || operand.kind == .Uint128 {
				if !uses_128 {
					uses_128 = true
					sum_128 = i128(sum_int)
				}
				sum_128 += value_as_i128(operand)
			} else if uses_128 {
				number, _ := value_to_i64(operand)
				sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(operand)
				// A sum that leaves 64 bits is an error, as in SQLite: it used to wrap.
				total, overflow := intrinsics.overflow_add(sum_int, number)
				if overflow do return {}, integer_overflow_error()
				sum_int = total
			}
		}
	}
	switch name {
	case "min", "max":
		return value_clone(accumulator, context.allocator), ERROR_NONE
	case "total":
		return value_float(sum_float), ERROR_NONE
	case "sum":
		if seen == 0 do return value_null(), ERROR_NONE
		if uses_float do return value_float(sum_float), ERROR_NONE
		if uses_128 do return value_int128(sum_128), ERROR_NONE
		return value_int(sum_int), ERROR_NONE
	case "avg":
		if seen == 0 do return value_null(), ERROR_NONE
		total := uses_float ? sum_float : (uses_128 ? f64(sum_128) : f64(sum_int))
		return value_float(total / f64(seen)), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", name)
}

// glob_match implements SQLite's GLOB: case sensitive, * matches any run, ?
// matches one character and [...] is a character class (^ negates it).
glob_match :: proc(text, pattern: string) -> bool {
	return glob_here(text, pattern)
}

@(private)
glob_here :: proc(text_in, pattern_in: string) -> bool {
	text := text_in
	pattern := pattern_in
	for len(pattern) > 0 {
		switch pattern[0] {
		case '*':
			for len(pattern) > 0 && pattern[0] == '*' {
				pattern = pattern[1:]
			}
			if len(pattern) == 0 do return true
			for i in 0 ..= len(text) {
				if glob_here(text[i:], pattern) do return true
			}
			return false
		case '?':
			if len(text) == 0 do return false
			text = text[1:]
			pattern = pattern[1:]
		case '[':
			if len(text) == 0 do return false
			closing := strings.index_byte(pattern, ']')
			if closing < 0 {
				if text[0] != '[' do return false
				text = text[1:]
				pattern = pattern[1:]
				continue
			}
			body := pattern[1:closing]
			negate := len(body) > 0 && body[0] == '^'
			if negate do body = body[1:]
			member := false
			i := 0
			for i < len(body) {
				if i + 2 < len(body) && body[i + 1] == '-' {
					if text[0] >= body[i] && text[0] <= body[i + 2] do member = true
					i += 3
				} else {
					if text[0] == body[i] do member = true
					i += 1
				}
			}
			if member == negate do return false
			text = text[1:]
			pattern = pattern[closing + 1:]
		case:
			if len(text) == 0 || text[0] != pattern[0] do return false
			text = text[1:]
			pattern = pattern[1:]
		}
	}
	return len(text) == 0
}

// like_match implements SQL LIKE with % and _, an optional escape character,
// and case folding. The pattern is tokenized first so an escaped wildcard is a
// literal even when the matcher backtracks.
like_match :: proc(text, pattern: string, case_insensitive: bool, escape: u8 = 0) -> bool {
	t := text
	p := pattern
	if case_insensitive {
		// SQLite's LIKE folds ASCII letters only.
		if sqlite_rules_on() {
			t = ascii_case(text, false, context.temp_allocator)
			p = ascii_case(pattern, false, context.temp_allocator)
		} else {
			t = strings.to_lower(text, context.temp_allocator)
			p = strings.to_lower(pattern, context.temp_allocator)
		}
	}
	Like_Token_Kind :: enum u8 {
		Literal,
		Any,
		Star,
	}
	Like_Token :: struct {
		kind: Like_Token_Kind,
		ch:   u8,
	}
	tokens := make([dynamic]Like_Token, 0, len(p))
	defer delete(tokens)
	for i := 0; i < len(p); i += 1 {
		ch := p[i]
		if escape != 0 && ch == escape && i + 1 < len(p) {
			i += 1
			append(&tokens, Like_Token{kind = .Literal, ch = p[i]})
			continue
		}
		switch ch {
		case '%':
			append(&tokens, Like_Token{kind = .Star})
		case '_':
			append(&tokens, Like_Token{kind = .Any})
		case:
			append(&tokens, Like_Token{kind = .Literal, ch = ch})
		}
	}
	ti := 0
	pi := 0
	star := -1
	match := 0
	for ti < len(t) {
		if pi < len(tokens) {
			token := tokens[pi]
			if token.kind == .Any || (token.kind == .Literal && token.ch == t[ti]) {
				ti += 1
				pi += 1
				continue
			}
			if token.kind == .Star {
				star = pi
				match = ti
				pi += 1
				continue
			}
		}
		if star != -1 {
			pi = star + 1
			match += 1
			ti = match
			continue
		}
		return false
	}
	for pi < len(tokens) && tokens[pi].kind == .Star do pi += 1
	return pi == len(tokens)
}

// --- Text positions --------------------------------------------------------

// text_char_count counts characters, not bytes: SQLite positions text by
// character, so length('héllo') is five. A malformed byte counts as one.
text_char_count :: proc(text: string) -> int {
	for c in text {
		if c >= 0x80 do return text_char_count_slow(text)
	}
	return len(text)
}

@(private)
text_char_count_slow :: proc(text: string) -> int {
	count, at := 0, 0
	for at < len(text) {
		_, size := utf8.decode_rune_in_string(text[at:])
		if size <= 0 do size = 1
		at += size
		count += 1
	}
	return count
}

// text_byte_at turns a character index into a byte offset. An index at or past
// the last character answers the length, so a slice end needs no special case.
text_byte_at :: proc(text: string, index: int) -> int {
	if index <= 0 do return 0
	ascii := true
	for c in text {
		if c >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii do return min(index, len(text))
	at, seen := 0, 0
	for at < len(text) {
		if seen == index do return at
		_, size := utf8.decode_rune_in_string(text[at:])
		if size <= 0 do size = 1
		at += size
		seen += 1
	}
	return at
}

// Chosen_Row is one row of a group an aggregate reads, with the key its own
// ORDER BY sorts it under.
@(private)
Chosen_Row :: struct {
	key:     []u8,
	sources: []Source,
}

// eval_aggregate_chosen runs an aggregate with a FILTER or an ORDER BY of its
// own: the group keeps the rows the filter holds for, sorted by the ORDER BY
// (stably, so equal keys keep the group's order), and the plain aggregate runs
// over that group.
@(private)
eval_aggregate_chosen :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	rows := ctx.group
	single_rows: [1][]Source
	if !ctx.grouped {
		single_rows[0] = ctx.sources
		rows = single_rows[:]
	}
	chosen := make([dynamic]Chosen_Row, 0, len(rows))
	defer {
		for row in chosen do delete(row.key)
		delete(chosen)
	}
	// A program's collation leaves a slot in the key for the value's rank,
	// filled once every row is known, as an ORDER BY does (collations.odin).
	host_slots: ^[dynamic]Host_Order_Slot
	for sources in rows {
		sub := ctx^
		sub.sources = sources
		sub.host_slots = host_slots
		if call.filter != nil {
			value, filter_err := eval_expr(&sub, call.filter)
			if filter_err.kind != .None do return {}, filter_err
			if !value_is_truthy(value) do continue
		}
		key: []u8
		if len(call.order_by) > 0 {
			w: Byte_Writer
			bw_init(&w)
			first_slot := host_slots != nil ? len(host_slots^) : 0
			for item, term in call.order_by {
				value, order_err := eval_expr(&sub, item.expr)
				if order_err.kind != .None {
					bw_destroy(&w)
					return {}, order_err
				}
				if host, is_host := host_order_collation(&sub, item.expr); is_host {
					host_slot_append(&sub, &w, item, term, value_clone(value, sub.tx.alloc), host)
					host_slots = sub.host_slots
					continue
				}
				collation, has := collate_name(item.expr)
				if !has do collation, has = column_collation(&sub, item.expr)
				if has && len(collation) > 0 do value = collate_ordered_value(value, collation)
				order_key_append(&w, value, item)
			}
			key = slice.clone(bw_bytes(&w))
			bw_destroy(&w)
			if host_slots != nil {
				for &slot in host_slots^[first_slot:] do slot.key = key
			}
		}
		append(&chosen, Chosen_Row{key = key, sources = sources})
	}
	if host_slots != nil do host_order_resolve(ctx.tx.store, host_slots^[:])
	if len(call.order_by) > 0 {
		slice.stable_sort_by(chosen[:], proc(a, b: Chosen_Row) -> bool {
			return text_compare(string(a.key), string(b.key)) < 0
		})
	}
	group := make([][]Source, len(chosen))
	defer delete(group)
	for row, i in chosen do group[i] = row.sources
	sub := ctx^
	sub.group = group
	sub.grouped = true
	sub.stream = nil
	plain := call
	plain.filter = nil
	plain.order_by = nil
	return eval_aggregate(&sub, plain)
}

// jsonb_aggregate_plain is the json_ aggregate a jsonb_group_* call stands for.
@(private)
jsonb_aggregate_plain :: proc(call: Call_Expr) -> (Call_Expr, bool) {
	if !strings.equal_fold(call.name, "jsonb_group_array") && !strings.equal_fold(call.name, "jsonb_group_object") {
		return call, false
	}
	plain := call
	plain.name = strings.equal_fold(call.name, "jsonb_group_array") ? "json_group_array" : "json_group_object"
	return plain, true
}
