package engine

import "core:fmt"
import "core:strings"

// Host functions are functions a program registers on a database, so SQL written
// by a caller can call code the caller linked: scalar functions, which answer
// once per call, and aggregates, which see every row of a group and answer once
// for it. Nothing about the registry is persisted - it belongs to the process,
// not to the log - and opening the database again starts with no functions.
//
// A function is registered under its name and its number of arguments, as in
// SQLite: `f/1` and `f/2` are two functions, and an arity of -1 takes any count
// that has no function of its own. Registering a name and arity again replaces
// what was there, scalar or aggregate.
//
// The engine's own functions answer first, so a host cannot quietly replace
// `upper()`, unless the registration says it overrides them (`overrides`): the
// sqlite3_* facade registers that way because SQLite lets an application
// redefine a builtin. Only scalar builtins can be overridden; an aggregate
// builtin keeps its name.

// Scalar_Function is one host function: the evaluated arguments, the user pointer
// it was registered with, and the answer. Text the handler allocates must come
// from context.allocator, because the engine keeps the value until it is copied
// into a row or a result. An error kind travels to the caller as the statement's
// error, with the message the handler wrote.
Scalar_Function :: #type proc(args: []Value, user: rawptr) -> (Value, Error)

Scalar_Function_Def :: struct {
	handler:   Scalar_Function,
	// arity is the exact number of arguments the function takes, or -1 for any.
	arity:     int,
	user:      rawptr,
	// overrides makes the function answer before a builtin of the same name.
	overrides: bool,
	// nondeterministic is a function that may answer differently for the same
	// arguments (registered without SQLITE_DETERMINISTIC): an index cannot
	// hold it.
	nondeterministic: bool,
}

// store_mark_nondeterministic records that a registered function may answer
// differently for the same arguments.
store_mark_nondeterministic :: proc(store: ^Store, name: string, arity: int) {
	key := function_key(name, arity)
	defer delete(key)
	if def, found := store.functions[key]; found {
		def.nondeterministic = true
		store.functions[key] = def
	}
}

// expr_nondeterministic names a call in `expr` that may answer differently
// for the same arguments: a program's function registered so, or one of
// SQLite's own (random, randomblob, changes and the like).
expr_nondeterministic :: proc(store: ^Store, expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	State :: struct {
		store: ^Store,
		name:  string,
	}
	state := State{store = store}
	expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
		state := (^State)(user)
		call, is_call := node^.(Call_Expr)
		if !is_call do return true
		for builtin in ([]string{"random", "randomblob", "changes", "total_changes", "last_insert_rowid", "date", "time", "datetime", "julianday", "unixepoch", "strftime", "current_timestamp", "current_date", "current_time"}) {
			if strings.equal_fold(call.name, builtin) && (len(call.args) == 0 || builtin == "random" || builtin == "randomblob" || builtin == "changes" || builtin == "total_changes" || builtin == "last_insert_rowid") {
				state.name = call.name
				return false
			}
		}
		for arity in ([]int{len(call.args), -1}) {
			key := function_key(call.name, arity)
			def, found := state.store.functions[key]
			delete(key)
			if found && def.nondeterministic {
				state.name = call.name
				return false
			}
		}
		return true
	}, &state)
	return state.name, len(state.name) > 0
}

// Aggregate_Group is the state of one aggregate over one group: `state` is the
// host's to use (the facade keeps sqlite3_aggregate_context memory there), and
// it is the same pointer for every step of the group and for its final.
Aggregate_Group :: struct {
	state: rawptr,
	user:  rawptr,
}

// Aggregate_Step sees one row's arguments. Aggregate_Final answers for the group,
// and is called exactly once per group even when the group has no row or a step
// failed (its answer is then dropped), so the host can always free its state.
Aggregate_Step :: #type proc(group: ^Aggregate_Group, args: []Value) -> Error
Aggregate_Final :: #type proc(group: ^Aggregate_Group) -> (Value, Error)

Aggregate_Function_Def :: struct {
	step:  Aggregate_Step,
	final: Aggregate_Final,
	arity: int,
	user:  rawptr,
}

// function_key is the registry key of a name and an arity: the name folded to
// lower case, then the arity. The caller frees it.
@(private)
function_key :: proc(name: string, arity: int, alloc := context.allocator) -> string {
	lowered := strings.to_lower(name, context.temp_allocator)
	return fmt.aprintf("%s/%d", lowered, arity, allocator = alloc)
}

@(private)
function_check :: proc(store: ^Store, name: string, arity: int) -> Error {
	if store == nil do return errf(.Invalid_Argument, "no database")
	if len(name) == 0 do return errf(.Invalid_Argument, "a function needs a name")
	if arity < -1 do return errf(.Invalid_Argument, "function %s has a negative arity", name)
	return ERROR_NONE
}

// function_forget drops whatever is registered under `key`, scalar or
// aggregate, and frees the key the map held.
@(private)
function_forget :: proc(store: ^Store, key: string) -> bool {
	found := false
	if stored, _, ok := map_entry_key(&store.functions, key); ok {
		map_erase(&store.functions, key)
		delete(stored)
		found = true
	}
	if stored, _, ok := map_entry_key(&store.aggregates, key); ok {
		map_erase(&store.aggregates, key)
		delete(stored)
		found = true
	}
	return found
}

// map_entry_key returns the key the map stores for `key`, so it can be freed.
@(private)
map_entry_key :: proc(m: ^map[string]$T, key: string) -> (string, T, bool) {
	for stored, value in m {
		if stored == key do return stored, value, true
	}
	return "", {}, false
}

// store_register_function adds or replaces one scalar function by name and
// arity, case-insensitively. `arity` of -1 accepts any number of arguments.
store_register_function :: proc(
	store: ^Store,
	name: string,
	arity: int,
	handler: Scalar_Function,
	user: rawptr = nil,
	overrides := false,
) -> Error {
	if err := function_check(store, name, arity); err.kind != .None do return err
	if handler == nil do return errf(.Invalid_Argument, "function %s has no handler", name)
	key := function_key(name, arity)
	function_forget(store, key)
	store.functions[key] = Scalar_Function_Def {
		handler   = handler,
		arity     = arity,
		user      = user,
		overrides = overrides,
	}
	return ERROR_NONE
}

// store_register_aggregate adds or replaces one aggregate by name and arity.
store_register_aggregate :: proc(
	store: ^Store,
	name: string,
	arity: int,
	step: Aggregate_Step,
	final: Aggregate_Final,
	user: rawptr = nil,
) -> Error {
	if err := function_check(store, name, arity); err.kind != .None do return err
	if step == nil || final == nil do return errf(.Invalid_Argument, "aggregate %s needs a step and a final", name)
	if builtin_aggregate_name(name) {
		return errf(.Invalid_Argument, "%s is a built-in aggregate and keeps its name", name)
	}
	key := function_key(name, arity)
	function_forget(store, key)
	store.aggregates[key] = Aggregate_Function_Def {
		step  = step,
		final = final,
		arity = arity,
		user  = user,
	}
	return ERROR_NONE
}

// store_unregister_function drops a function, scalar or aggregate: the one with
// `arity`, or every arity of the name when `arity` is FUNCTION_ANY_ARITY. It
// reports whether one was there.
FUNCTION_ANY_ARITY :: -2

store_unregister_function :: proc(store: ^Store, name: string, arity := FUNCTION_ANY_ARITY) -> bool {
	if store == nil do return false
	if arity != FUNCTION_ANY_ARITY {
		key := function_key(name, arity, context.temp_allocator)
		return function_forget(store, key)
	}
	prefix := fmt.tprintf("%s/", strings.to_lower(name, context.temp_allocator))
	keys := make([dynamic]string, 0, 4, context.temp_allocator)
	for stored, _ in store.functions do if strings.has_prefix(stored, prefix) do append(&keys, strings.clone(stored, context.temp_allocator))
	for stored, _ in store.aggregates do if strings.has_prefix(stored, prefix) do append(&keys, strings.clone(stored, context.temp_allocator))
	found := false
	for key in keys do if function_forget(store, key) do found = true
	return found
}

// store_function finds the scalar function a call with `argc` arguments
// reaches: the one registered for that count, else the one for any count. The
// second answer says whether the name is registered at all, with any arity, so
// a call with the wrong count can say so.
store_function :: proc(store: ^Store, name: string, argc: int) -> (def: Scalar_Function_Def, found: bool, named: bool) {
	if store == nil || len(store.functions) == 0 do return {}, false, false
	exact := function_key(name, argc, context.temp_allocator)
	if d, ok := store.functions[exact]; ok do return d, true, true
	any_count := function_key(name, -1, context.temp_allocator)
	if d, ok := store.functions[any_count]; ok do return d, true, true
	return {}, false, function_named(store, name)
}

// store_aggregate is store_function for aggregates.
store_aggregate :: proc(store: ^Store, name: string, argc: int) -> (Aggregate_Function_Def, bool) {
	if store == nil || len(store.aggregates) == 0 do return {}, false
	exact := function_key(name, argc, context.temp_allocator)
	if d, ok := store.aggregates[exact]; ok do return d, true
	any_count := function_key(name, -1, context.temp_allocator)
	if d, ok := store.aggregates[any_count]; ok do return d, true
	return {}, false
}

// function_named reports whether any function, scalar or aggregate, is
// registered under `name`.
@(private)
function_named :: proc(store: ^Store, name: string) -> bool {
	prefix := fmt.tprintf("%s/", strings.to_lower(name, context.temp_allocator))
	for stored, _ in store.functions do if strings.has_prefix(stored, prefix) do return true
	for stored, _ in store.aggregates do if strings.has_prefix(stored, prefix) do return true
	return false
}

// store_has_aggregate reports whether `name` is a host aggregate with any
// arity: what decides that a call is an aggregate before its arguments are
// counted.
store_has_aggregate :: proc(store: ^Store, name: string) -> bool {
	if store == nil || len(store.aggregates) == 0 do return false
	prefix := fmt.tprintf("%s/", strings.to_lower(name, context.temp_allocator))
	for stored, _ in store.aggregates do if strings.has_prefix(stored, prefix) do return true
	return false
}

// --- Which calls are aggregates --------------------------------------------
//
// Whether a call is an aggregate decides how a whole query runs, and the
// question is asked in many places that only see an expression. A host
// aggregate is a property of the store, so the executor publishes the running
// store's registry for the duration of a statement (aggregate_scope_enter) and
// is_aggregate_name reads it. With no host aggregate registered it costs
// nothing.

@(thread_local, private)
aggregate_scope: ^Store

// aggregate_scope_enter makes `store`'s host aggregates visible to the
// statement this thread runs, and returns what was visible before.
aggregate_scope_enter :: proc(store: ^Store) -> ^Store {
	previous := aggregate_scope
	aggregate_scope = store
	return previous
}

aggregate_scope_leave :: proc(previous: ^Store) {
	aggregate_scope = previous
}

// sqlite_rules_on reports a statement running under SQLite's rules
// (docs/sqlite-semantics.md).
sqlite_rules_on :: proc() -> bool {
	return aggregate_scope != nil && aggregate_scope.sqlite_rules
}

// statement_store is the store whose statement this thread is running, or nil.
statement_store :: proc() -> ^Store {
	return aggregate_scope
}

// host_aggregate_name reports a call name that is a host aggregate of the
// store the running statement belongs to.
host_aggregate_name :: proc(name: string) -> bool {
	return aggregate_scope != nil && store_has_aggregate(aggregate_scope, name)
}
