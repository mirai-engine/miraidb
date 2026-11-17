package sqlite_compat

// The connection hooks of the classic API: a callback per changed row
// (sqlite3_update_hook), one that may veto a commit (sqlite3_commit_hook) and
// one when a transaction rolls back (sqlite3_rollback_hook). Each call
// replaces the hook and answers the argument the previous one was given; a
// NULL callback removes it. The engine calls them through the store's hooks
// (src/engine/hooks.odin).

import "base:runtime"
import "core:c"
import "core:strings"

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
	context = runtime.default_context()
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
	context = runtime.default_context()
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
	context = runtime.default_context()
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
