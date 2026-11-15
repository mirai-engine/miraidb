package engine

import "core:strings"

// Host functions are scalar functions a program registers on a database, so SQL
// written by a caller can call code the caller linked. The engine's own functions
// answer first: the registry is consulted only where a name would otherwise be
// "unknown function", so a host cannot quietly replace `upper()` with something
// else. Nothing about the registry is persisted - it belongs to the process, not
// to the log - and opening the database again starts with no functions.

// Scalar_Function is one host function: the evaluated arguments, the user pointer
// it was registered with, and the answer. Text the handler allocates must come
// from context.allocator, because the engine keeps the value until it is copied
// into a row or a result. An error kind travels to the caller as the statement's
// error, with the message the handler wrote.
Scalar_Function :: #type proc(args: []Value, user: rawptr) -> (Value, Error)

Scalar_Function_Def :: struct {
	handler: Scalar_Function,
	// arity is the exact number of arguments the function takes, or -1 for any.
	arity:   int,
	user:    rawptr,
}

// store_register_function adds or replaces one function by name, case-insensitively.
// `arity` of -1 accepts any number of arguments; the count is checked before the
// handler runs.
store_register_function :: proc(
	store: ^Store,
	name: string,
	arity: int,
	handler: Scalar_Function,
	user: rawptr = nil,
) -> Error {
	if store == nil do return errf(.Invalid_Argument, "no database")
	if len(name) == 0 do return errf(.Invalid_Argument, "a function needs a name")
	if handler == nil do return errf(.Invalid_Argument, "function %s has no handler", name)
	if arity < -1 do return errf(.Invalid_Argument, "function %s has a negative arity", name)
	// The map owns its keys, and `strings.to_lower` returns the argument itself when
	// it is already lower case: the copy is what the map keeps, and the temporary
	// (when there is one) is freed here. A lookup walks with equal_fold instead of
	// building a key per call, because a function map is a handful of entries.
	for stored, _ in store.functions {
		if strings.equal_fold(stored, name) {
			store.functions[stored] = Scalar_Function_Def{handler = handler, arity = arity, user = user}
			return ERROR_NONE
		}
	}
	lowercased := strings.to_lower(name)
	key := strings.clone(lowercased)
	if raw_data(lowercased) != raw_data(name) do delete(lowercased)
	store.functions[key] = Scalar_Function_Def {
		handler = handler,
		arity   = arity,
		user    = user,
	}
	return ERROR_NONE
}

// store_unregister_function drops one function. It reports whether one was there.
store_unregister_function :: proc(store: ^Store, name: string) -> bool {
	if store == nil do return false
	// Erase by the key the map holds, then free that key: `map_erase` removes the
	// entry without touching the memory, and the key was cloned when it was added.
	stored_key: string
	for stored, _ in store.functions {
		if strings.equal_fold(stored, name) {
			stored_key = stored
			break
		}
	}
	if len(stored_key) == 0 do return false
	map_erase(&store.functions, stored_key)
	delete(stored_key)
	return true
}

// store_function looks a function up. The name is folded, so `Twice` and `twice`
// are the same function, which is how the builtins read.
store_function :: proc(store: ^Store, name: string) -> (Scalar_Function_Def, bool) {
	if store == nil do return {}, false
	for stored, def in store.functions {
		if strings.equal_fold(stored, name) do return def, true
	}
	return {}, false
}
