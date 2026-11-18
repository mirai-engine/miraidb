package sqlite_compat

// Application-defined collations: sqlite3_create_collation registers a C
// comparison SQL names with COLLATE. It answers wherever a comparison happens
// (WHERE, ON, CASE, IN, BETWEEN) and in ORDER BY, where the engine ranks the
// values under it (collations.odin). A collation registered with a UTF-16 text
// representation is handed UTF-16 bytes, as in SQLite. sqlite3_collation_needed
// lets a program register one the first time a statement names it.

import "base:runtime"
import "core:c"
import "core:strings"

import engine "../engine"

Collation_Callback :: #type proc "c" (arg: rawptr, n1: c.int, s1: rawptr, n2: c.int, s2: rawptr) -> c.int
Collation_Needed_Callback :: #type proc "c" (arg: rawptr, db: rawptr, text_rep: c.int, name: cstring)
Collation_Needed16_Callback :: #type proc "c" (arg: rawptr, db: rawptr, text_rep: c.int, name: rawptr)

// Collation is one registration on one connection.
Collation :: struct {
	name:       string,
	arg:        rawptr,
	compare:    Collation_Callback,
	destroy:    Destroy_Callback,
	utf16:      bool,
	big_endian: bool,
}

@(private)
collation_call :: proc(a: string, b: string, user: rawptr) -> int {
	collation := (^Collation)(user)
	if collation == nil || collation.compare == nil do return 0
	if !collation.utf16 {
		return int(collation.compare(collation.arg, c.int(len(a)), raw_data(a), c.int(len(b)), raw_data(b)))
	}
	wide_a := utf16_encode(a, collation.big_endian, context.temp_allocator)
	wide_b := utf16_encode(b, collation.big_endian, context.temp_allocator)
	return int(collation.compare(collation.arg, utf16_bytes(wide_a), raw_data(wide_a), utf16_bytes(wide_b), raw_data(wide_b)))
}

@(private)
collation_destroy :: proc(collation: ^Collation) {
	if collation.destroy != nil do collation.destroy(collation.arg)
	delete(collation.name)
	free(collation)
}

// collation_drop forgets the registration of `name`, running its destructor.
@(private)
collation_drop :: proc(db: ^Database, name: string) {
	for i := 0; i < len(db.collations); i += 1 {
		if !strings.equal_fold(db.collations[i].name, name) do continue
		engine.store_unregister_collation(db.conn.store, name)
		collation_destroy(db.collations[i])
		ordered_remove(&db.collations, i)
		return
	}
}

@(private)
collations_close :: proc(db: ^Database) {
	for collation in db.collations {
		engine.store_unregister_collation(db.conn.store, collation.name)
		collation_destroy(collation)
	}
	delete(db.collations)
}

@(private)
create_collation :: proc(
	handle: rawptr,
	name: string,
	text_rep: c.int,
	arg: rawptr,
	compare: Collation_Callback,
	destroy: Destroy_Callback,
) -> c.int {
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	utf16, big_endian := text_encoding_order(text_rep)
	rep := text_rep & ~c.int(0x08) // SQLITE_UTF16_ALIGNED
	if rep < SQLITE_UTF8 || rep > SQLITE_UTF16 {
		// SQLITE_ANY (5) is accepted as UTF-8, as SQLite does.
		if rep != 5 do return set_error_code(db, SQLITE_MISUSE, "bad parameter or other API misuse")
	}
	// A comparison an active statement may be using is not replaced, as in
	// SQLite.
	for existing in db.collations {
		if strings.equal_fold(existing.name, name) && db_has_active_statement(db) {
			return set_error_code(db, SQLITE_BUSY, "unable to delete/modify collation sequence due to active statements")
		}
	}
	// The old comparison goes, destructor and all, whatever replaces it.
	collation_drop(db, name)
	if compare == nil do return SQLITE_OK
	collation := new(Collation)
	collation^ = Collation {
		name       = strings.clone(name),
		arg        = arg,
		compare    = compare,
		destroy    = destroy,
		utf16      = utf16,
		big_endian = big_endian,
	}
	// BINARY, NOCASE and RTRIM may be replaced on the connection, as in SQLite.
	err := engine.store_register_collation(db.conn.store, name, collation_call, rawptr(collation), replace_builtin = true)
	if err.kind != .None {
		engine.error_free(&err)
		collation_destroy(collation)
		return SQLITE_ERROR
	}
	append(&db.collations, collation)
	return SQLITE_OK
}

@(private)
set_error_code :: proc(db: ^Database, code: c.int, message: string) -> c.int {
	set_error(db, message)
	db.last_code = code
	db.last_extended = code
	return code
}

@(export)
sqlite3_create_collation :: proc "c" (handle: rawptr, name: cstring, text_rep: c.int, arg: rawptr, compare: Collation_Callback) -> c.int {
	context = runtime.default_context()
	if name == nil do return SQLITE_MISUSE
	return create_collation(handle, string(name), text_rep, arg, compare, nil)
}

@(export)
sqlite3_create_collation_v2 :: proc "c" (
	handle: rawptr,
	name: cstring,
	text_rep: c.int,
	arg: rawptr,
	compare: Collation_Callback,
	destroy: Destroy_Callback,
) -> c.int {
	context = runtime.default_context()
	if name == nil do return SQLITE_MISUSE
	return create_collation(handle, string(name), text_rep, arg, compare, destroy)
}

@(export)
sqlite3_create_collation16 :: proc "c" (handle: rawptr, name: rawptr, text_rep: c.int, arg: rawptr, compare: Collation_Callback) -> c.int {
	context = runtime.default_context()
	if name == nil do return SQLITE_MISUSE
	decoded := utf16_decode(name, -1, NATIVE_BIG_ENDIAN)
	defer delete(decoded)
	return create_collation(handle, decoded, text_rep, arg, compare, nil)
}

@(private)
hook_collation_needed :: proc(ctx: rawptr, name: string) {
	db := (^Database)(ctx)
	if db.collation_needed != nil {
		text := strings.clone_to_cstring(name, context.temp_allocator)
		db.collation_needed(db.collation_needed_arg, rawptr(db), SQLITE_UTF8, text)
	} else if db.collation_needed16 != nil {
		wide := utf16_encode(name, NATIVE_BIG_ENDIAN, context.temp_allocator)
		db.collation_needed16(db.collation_needed_arg, rawptr(db), SQLITE_UTF16, raw_data(wide))
	}
}

@(private)
collation_needed_install :: proc(db: ^Database) {
	hooks := &db.conn.store.hooks
	installed := db.collation_needed != nil || db.collation_needed16 != nil
	hooks.collation_needed = installed ? hook_collation_needed : nil
	hooks.collation_needed_ctx = rawptr(db)
}

@(export)
sqlite3_collation_needed :: proc "c" (handle: rawptr, arg: rawptr, callback: Collation_Needed_Callback) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	db.collation_needed = callback
	db.collation_needed16 = nil
	db.collation_needed_arg = arg
	collation_needed_install(db)
	return SQLITE_OK
}

@(export)
sqlite3_collation_needed16 :: proc "c" (handle: rawptr, arg: rawptr, callback: Collation_Needed16_Callback) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	db.collation_needed16 = callback
	db.collation_needed = nil
	db.collation_needed_arg = arg
	collation_needed_install(db)
	return SQLITE_OK
}
