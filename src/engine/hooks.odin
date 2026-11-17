package engine

import "core:strings"

// --- Hooks an embedding layer installs -------------------------------------
//
// The classic embedded API lets a program watch its connection: a callback per
// row a statement changes (sqlite3_update_hook), one that can veto a commit
// (sqlite3_commit_hook) and one when a transaction rolls back
// (sqlite3_rollback_hook). The engine calls them through the store, and the
// sqlite3_* facade is what installs them. With none installed each check is
// one nil comparison.

Row_Change :: enum u8 {
	Insert,
	Update,
	Delete,
}

// Row_Change_Hook runs after a row of a user table changed, with the table's
// name and the row's id as SQLite names it: the INTEGER PRIMARY KEY when the
// table has one. It runs for rows a trigger changes too, and not for the rows a
// REPLACE removes, nor for the engine's catalog tables, as in SQLite.
Row_Change_Hook :: #type proc(ctx: rawptr, change: Row_Change, table: string, rowid: i64)

// Commit_Hook runs when a transaction that changed something is about to
// commit; answering true turns the commit into a rollback.
Commit_Hook :: #type proc(ctx: rawptr) -> bool

// Rollback_Hook runs when a transaction is rolled back by ROLLBACK or by a
// vetoed commit. It does not run for a statement that fails on its own, nor
// for a connection that closes with a transaction open, as in SQLite.
Rollback_Hook :: #type proc(ctx: rawptr)

Store_Hooks :: struct {
	row_change:     Row_Change_Hook,
	row_change_ctx: rawptr,
	commit:         Commit_Hook,
	commit_ctx:     rawptr,
	rollback:       Rollback_Hook,
	rollback_ctx:   rawptr,
	// authorizer is asked about every action of a statement while it is
	// prepared (authorize.odin).
	authorizer:     Authorizer,
	authorizer_ctx: rawptr,
}

// catalog_table_name reports a table the engine keeps for itself, whose
// changes are not the program's.
@(private)
catalog_table_name :: proc(name: string) -> bool {
	for candidate in ([]string {
		META_TABLE, ATTACH_TABLE, CLIENT_TABLE, EXTENSION_TABLE, VIRTUAL_TABLE, REDUCER_TABLE,
		SCHEDULE_TABLE, REQUEST_TABLE, POLICY_TABLE, ROLE_TABLE, GRANT_TABLE, TYPE_TABLE,
		TOKEN_TABLE, TRIGGER_TABLE, VAR_TABLE, VIEW_TABLE,
	}) {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

// hook_rowid is the id SQLite would report for row `id` of `name` as the
// transaction sees it.
@(private)
hook_rowid :: proc(tx: ^Tx, name: string, id: Row_Id) -> i64 {
	table := tx_table_probe(tx, name)
	if table == nil do return i64(id)
	row, found := tx_get(tx, name, id)
	if !found do return i64(id)
	value, ok := rowid_value(Source{table = table, row = row})
	if !ok do return i64(id)
	return value.i
}

@(private)
hook_row_change :: proc(tx: ^Tx, change: Row_Change, name: string, rowid: i64) {
	hooks := &tx.store.hooks
	if hooks.row_change == nil || catalog_table_name(name) do return
	hooks.row_change(hooks.row_change_ctx, change, name, rowid)
}

// store_fire_rollback runs the rollback hook; the embedding layer calls it for
// a ROLLBACK statement.
store_fire_rollback :: proc(store: ^Store) {
	if store == nil || store.hooks.rollback == nil do return
	store.hooks.rollback(store.hooks.rollback_ctx)
}
