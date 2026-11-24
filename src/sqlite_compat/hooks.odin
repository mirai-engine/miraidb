package sqlite_compat

// The connection hooks of the classic API: a callback per changed row
// (sqlite3_update_hook), one that may veto a commit (sqlite3_commit_hook) and
// one when a transaction rolls back (sqlite3_rollback_hook). Each call
// replaces the hook and answers the argument the previous one was given; a
// NULL callback removes it. The engine calls them through the store's hooks
// (src/engine/hooks.odin).

import "core:c"
import "core:strings"
import "core:time"

import engine "../engine"

SQLITE_DELETE :: c.int(9)
SQLITE_INSERT :: c.int(18)
SQLITE_UPDATE :: c.int(23)
// A commit the commit hook vetoed fails as this constraint code.
SQLITE_CONSTRAINT_COMMITHOOK :: c.int(19 | 2 << 8)

Commit_Callback :: #type proc "c" (arg: rawptr) -> c.int
Update_Callback :: #type proc "c" (arg: rawptr, op: c.int, database: cstring, table: cstring, rowid: c.longlong)

@(private)
hook_commit :: proc(ctx: rawptr) -> bool {
	db := (^Database)(ctx)
	if db.commit_hook == nil do return false
	if db.commit_hook(db.commit_arg) == 0 do return false
	db.function_code = SQLITE_CONSTRAINT_COMMITHOOK
	return true
}

@(private)
hook_rollback :: proc(ctx: rawptr) {
	db := (^Database)(ctx)
	if db.rollback_hook != nil do db.rollback_hook(db.rollback_arg)
}

@(private)
hook_row :: proc(ctx: rawptr, change: engine.Row_Change, table: string, rowid: i64) {
	db := (^Database)(ctx)
	if db.update_hook == nil do return
	op := SQLITE_INSERT
	switch change {
	case .Insert:
		op = SQLITE_INSERT
	case .Update:
		op = SQLITE_UPDATE
	case .Delete:
		op = SQLITE_DELETE
	}
	name := strings.clone_to_cstring(table, context.temp_allocator)
	db.update_hook(db.update_arg, op, "main", name, c.longlong(rowid))
}

@(export)
sqlite3_commit_hook :: proc "c" (handle: rawptr, callback: Commit_Callback, arg: rawptr) -> rawptr {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return nil
	previous := db.commit_arg
	db.commit_hook = callback
	db.commit_arg = arg
	hooks := &db.conn.store.hooks
	hooks.commit = callback == nil ? nil : hook_commit
	hooks.commit_ctx = rawptr(db)
	return previous
}

@(export)
sqlite3_rollback_hook :: proc "c" (handle: rawptr, callback: Destroy_Callback, arg: rawptr) -> rawptr {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return nil
	previous := db.rollback_arg
	db.rollback_hook = callback
	db.rollback_arg = arg
	hooks := &db.conn.store.hooks
	hooks.rollback = callback == nil ? nil : hook_rollback
	hooks.rollback_ctx = rawptr(db)
	return previous
}

@(export)
sqlite3_update_hook :: proc "c" (handle: rawptr, callback: Update_Callback, arg: rawptr) -> rawptr {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return nil
	previous := db.update_arg
	db.update_hook = callback
	db.update_arg = arg
	hooks := &db.conn.store.hooks
	hooks.row_change = callback == nil ? nil : hook_row
	hooks.row_change_ctx = rawptr(db)
	return previous
}

Progress_Callback :: #type proc "c" (arg: rawptr) -> c.int

@(private)
hook_progress :: proc(ctx: rawptr) -> bool {
	db := (^Database)(ctx)
	return db.progress_hook != nil && db.progress_hook(db.progress_arg) != 0
}

// sqlite3_progress_handler calls `callback` every `every` steps of a running
// statement, and a non-zero answer interrupts it (SQLITE_INTERRUPT). A step
// here is a row the statement visits, where SQLite counts bytecode
// instructions, so a statement that visits no row never calls it. A NULL
// callback or a count under 1 removes it.
@(export)
sqlite3_progress_handler :: proc "c" (handle: rawptr, every: c.int, callback: Progress_Callback, arg: rawptr) {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return
	db.progress_hook = callback
	db.progress_arg = arg
	if callback == nil || every < 1 {
		engine.store_set_progress(db.conn.store, 0, nil, nil)
		return
	}
	engine.store_set_progress(db.conn.store, int(every), hook_progress, rawptr(db))
}

// --- Trace -------------------------------------------------------------------

SQLITE_TRACE_STMT :: c.uint(0x01)
SQLITE_TRACE_PROFILE :: c.uint(0x02)
SQLITE_TRACE_ROW :: c.uint(0x04)
SQLITE_TRACE_CLOSE :: c.uint(0x08)

Trace_Callback :: #type proc "c" (event: c.uint, ctx: rawptr, p: rawptr, x: rawptr) -> c.int
Legacy_Trace_Callback :: #type proc "c" (ctx: rawptr, sql: cstring)

// SQLITE_TRACE_LEGACY marks the mask sqlite3_trace set: the STMT event goes
// to its callback, with the statement's text.
@(private)
SQLITE_TRACE_LEGACY :: c.uint(0x40)

// sqlite3_trace is the older trace: `callback` gets the text of each
// statement as it starts. It replaces sqlite3_trace_v2's callback, and
// answers the argument the previous one had.
@(export)
sqlite3_trace :: proc "c" (handle: rawptr, callback: Legacy_Trace_Callback, ctx: rawptr) -> rawptr {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return nil
	previous := db.trace_arg
	db.trace_hook = nil
	db.trace_legacy = callback
	db.trace_arg = ctx
	db.trace_mask = callback == nil ? 0 : SQLITE_TRACE_STMT | SQLITE_TRACE_LEGACY
	return previous
}

// sqlite3_trace_v2 reports the events `mask` names: STMT when a statement
// starts running (with its text), ROW for each row, PROFILE when it ends (with
// the nanoseconds it ran) and CLOSE when the connection closes. A zero mask or
// a NULL callback turns it off.
@(export)
sqlite3_trace_v2 :: proc "c" (handle: rawptr, mask: c.uint, callback: Trace_Callback, ctx: rawptr) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	if callback == nil do db.trace_mask = 0
	else do db.trace_mask = mask
	db.trace_hook = callback
	db.trace_legacy = nil
	db.trace_arg = ctx
	return SQLITE_OK
}

@(private)
trace_start :: proc(stmt: ^Statement) {
	db := stmt.db
	if db.trace_mask == 0 || stmt.traced do return
	stmt.traced = true
	stmt.started = time.now()._nsec
	if db.trace_mask & SQLITE_TRACE_LEGACY != 0 {
		db.trace_legacy(db.trace_arg, stmt.sql_text)
	} else if db.trace_mask & SQLITE_TRACE_STMT != 0 {
		db.trace_hook(SQLITE_TRACE_STMT, db.trace_arg, rawptr(stmt), rawptr(stmt.sql_text))
	}
}

@(private)
trace_row :: proc(stmt: ^Statement) {
	db := stmt.db
	if db.trace_mask & SQLITE_TRACE_ROW != 0 do db.trace_hook(SQLITE_TRACE_ROW, db.trace_arg, rawptr(stmt), nil)
}

@(private)
trace_end :: proc(stmt: ^Statement) {
	db := stmt.db
	if !stmt.traced do return
	stmt.traced = false
	if db.trace_mask & SQLITE_TRACE_PROFILE != 0 {
		elapsed := i64(time.now()._nsec - stmt.started)
		db.trace_hook(SQLITE_TRACE_PROFILE, db.trace_arg, rawptr(stmt), rawptr(&elapsed))
	}
}

@(private)
trace_close :: proc(db: ^Database) {
	if db.trace_mask & SQLITE_TRACE_CLOSE != 0 do db.trace_hook(SQLITE_TRACE_CLOSE, db.trace_arg, rawptr(db), nil)
}

// --- Authorizer ----------------------------------------------------------------

SQLITE_DENY :: c.int(1)
SQLITE_IGNORE :: c.int(2)

Authorizer_Callback :: #type proc "c" (arg: rawptr, action: c.int, arg1: cstring, arg2: cstring, database: cstring, inner: cstring) -> c.int

@(private)
optional_cstring :: proc(text: Maybe(string)) -> cstring {
	value, present := text.?
	if !present do return nil
	return strings.clone_to_cstring(value, context.temp_allocator)
}

@(private)
hook_authorize :: proc(ctx: rawptr, request: engine.Auth_Request) -> engine.Auth_Answer {
	db := (^Database)(ctx)
	answer := db.authorizer(
		db.authorizer_arg,
		c.int(request.action),
		optional_cstring(request.arg1),
		optional_cstring(request.arg2),
		optional_cstring(request.database),
		optional_cstring(request.inner),
	)
	switch answer {
	case SQLITE_OK:
		return .Allow
	case SQLITE_IGNORE:
		return .Ignore
	}
	// SQLITE_DENY, and any answer SQLite does not define, refuse.
	return .Deny
}

// sqlite3_set_authorizer installs a callback the engine asks, while a
// statement is prepared, about each thing it will do: SQLITE_OK allows it,
// SQLITE_DENY fails the prepare with SQLITE_AUTH, and SQLITE_IGNORE reads a
// column as NULL, leaves an assigned column alone, or makes the statement do
// nothing. A NULL callback removes it.
@(export)
sqlite3_set_authorizer :: proc "c" (handle: rawptr, callback: Authorizer_Callback, arg: rawptr) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	db.authorizer = callback
	db.authorizer_arg = arg
	hooks := &db.conn.store.hooks
	hooks.authorizer = callback == nil ? nil : hook_authorize
	hooks.authorizer_ctx = rawptr(db)
	return SQLITE_OK
}
