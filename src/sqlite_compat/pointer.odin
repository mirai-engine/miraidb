package sqlite_compat

// Pointer passing: sqlite3_bind_pointer and sqlite3_result_pointer hand SQL a
// value that is NULL to every SQL operation and still carries a C pointer and
// a type name, which an application-defined function reads back with
// sqlite3_value_pointer when it names the same type. It is how a program hands
// an object to its own functions (carray, fts5) without SQL seeing it.
//
// The engine's NULL carries a token in its payload, which nothing in the
// engine reads, and the token names an entry here: the pointer, its type and
// the destructor SQLite promises to run. A bound pointer lives until the
// parameter is bound again, the bindings are cleared or the statement is
// finalized; a function's result pointer until the step that made it ends. A
// row that stores it stores a plain NULL, and sqlite3_value_dup of it is a
// plain NULL, as in SQLite.

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"

import engine "../engine"

@(private)
Pointer_Entry :: struct {
	data:    rawptr,
	type:    string,
	destroy: Destroy_Callback,
}

// Pointer_Binding is a pointer a statement's parameter holds.
@(private)
Pointer_Binding :: struct {
	index: int,
	token: i64,
}

@(private = "file")
pointer_lock: sync.Mutex
@(private = "file")
pointer_table: map[i64]Pointer_Entry
@(private = "file")
pointer_next: i64

// step_pointers are the result pointers made on this thread by the step that
// is running, released when it ends.
@(private, thread_local)
step_pointers: [dynamic]i64

// pointer_value registers a pointer and returns the NULL that carries it. A
// pointer without a type cannot be read back, so it is a plain NULL whose
// destructor runs now.
@(private)
pointer_value :: proc(data: rawptr, type: cstring, destroy: Destroy_Callback) -> (engine.Value, i64) {
	if type == nil {
		if destroy != nil do destroy(data)
		return engine.value_null(), 0
	}
	sync.mutex_lock(&pointer_lock)
	defer sync.mutex_unlock(&pointer_lock)
	if pointer_table == nil do pointer_table = make(map[i64]Pointer_Entry, 8, runtime.heap_allocator())
	pointer_next += 1
	token := pointer_next
	pointer_table[token] = Pointer_Entry {
		data    = data,
		type    = strings.clone(string(type), runtime.heap_allocator()),
		destroy = destroy,
	}
	value := engine.value_null()
	value.i = token
	return value, token
}

// pointer_release forgets a token and runs its destructor.
@(private)
pointer_release :: proc(token: i64) {
	if token == 0 do return
	sync.mutex_lock(&pointer_lock)
	entry, found := pointer_table[token]
	if found do delete_key(&pointer_table, token)
	sync.mutex_unlock(&pointer_lock)
	if !found do return
	delete(entry.type, runtime.heap_allocator())
	if entry.destroy != nil do entry.destroy(entry.data)
}

// pointer_of reads the pointer a value carries when its type is `type`.
@(private)
pointer_of :: proc(value: engine.Value, type: cstring) -> rawptr {
	if value.kind != .Null || value.i == 0 || type == nil do return nil
	sync.mutex_lock(&pointer_lock)
	defer sync.mutex_unlock(&pointer_lock)
	entry, found := pointer_table[value.i]
	if !found || entry.type != string(type) do return nil
	return entry.data
}

// stmt_pointer_drop releases the pointer parameter `index` (0-based) holds,
// before the parameter takes another value.
@(private)
stmt_pointer_drop :: proc(stmt: ^Statement, index: int) {
	for i := 0; i < len(stmt.pointers); i += 1 {
		if stmt.pointers[i].index != index do continue
		pointer_release(stmt.pointers[i].token)
		unordered_remove(&stmt.pointers, i)
		return
	}
}

@(private)
stmt_pointers_release :: proc(stmt: ^Statement) {
	for binding in stmt.pointers do pointer_release(binding.token)
	clear(&stmt.pointers)
}

// step_pointers_mark and step_pointers_end bracket one step: the result
// pointers its functions made go when it ends.
@(private)
step_pointers_mark :: proc() -> int {
	return len(step_pointers)
}

@(private)
step_pointers_end :: proc(mark: int) {
	for len(step_pointers) > mark do pointer_release(pop(&step_pointers))
	// The outermost step gives the list's memory back. delete leaves the header
	// pointing at the freed block, so the header is reset too.
	if len(step_pointers) == 0 && cap(step_pointers) > 0 {
		delete(step_pointers)
		step_pointers = nil
	}
}

@(export)
sqlite3_bind_pointer :: proc "c" (handle: rawptr, index: c.int, data: rawptr, type: cstring, destroy: Destroy_Callback) -> c.int {
	context = engine.oom_context()
	stmt := stmt_of(handle)
	if stmt == nil {
		if destroy != nil do destroy(data)
		return SQLITE_MISUSE
	}
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) {
		if destroy != nil do destroy(data)
		return SQLITE_RANGE
	}
	stmt_pointer_drop(stmt, int(index) - 1)
	value, token := pointer_value(data, type, destroy)
	if !engine.error_drop(engine.embed_bind(stmt.stmt, int(index) - 1, value)) {
		pointer_release(token)
		return SQLITE_ERROR
	}
	if token != 0 do append(&stmt.pointers, Pointer_Binding{index = int(index) - 1, token = token})
	return SQLITE_OK
}

@(export)
sqlite3_result_pointer :: proc "c" (handle: rawptr, data: rawptr, type: cstring, destroy: Destroy_Callback) {
	context = engine.oom_context()
	ctx := context_of(handle)
	if ctx == nil {
		if destroy != nil do destroy(data)
		return
	}
	value, token := pointer_value(data, type, destroy)
	if token != 0 do append(&step_pointers, token)
	context_set(ctx, value)
}

@(export)
sqlite3_value_pointer :: proc "c" (handle: rawptr, type: cstring) -> rawptr {
	context = engine.oom_context()
	box := box_of(handle)
	if box == nil do return nil
	return pointer_of(box.value, type)
}
