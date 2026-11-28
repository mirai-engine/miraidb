package engine

import "core:strings"
import "core:sync"

// A database image is the bytes a SQLite file holds. sqlite3_serialize answers
// the store's; sqlite3_deserialize and the last step of sqlite3_backup replace
// a store's content with one. Both go through the SQLite format, so what
// travels is what a SQLite file can say: the tables, rows, indexes, views,
// triggers, AUTOINCREMENT counters and the header integers.

// store_sqlite_image is the committed state as a SQLite database image. The
// caller owns the bytes.
store_sqlite_image :: proc(store: ^Store, alloc := context.allocator) -> ([]u8, Error) {
	sync.shared_lock(&store.mutex)
	defer sync.shared_unlock(&store.mutex)
	image, _, _, err := sqlite_file_image(store, alloc)
	return image, err
}

// store_replace_content makes the store hold what `image` holds, in one
// transaction: everything the program sees goes (its tables, views, triggers
// and header integers), and the image's take its place. An empty image
// leaves an empty database. The hooks a program installed hear nothing, as
// SQLite's copy of pages tells them nothing. `detach` stops mirroring a SQLite
// file, as a deserialized connection no longer writes the file it was opened
// on; otherwise a mirrored file is rewritten with the new content.
store_replace_content :: proc(store: ^Store, image: []u8, detach: bool) -> Error {
	file: Sqlite_File
	has_file := len(image) > 0
	if has_file {
		parsed, parse_err := sqlite_file_from_bytes(image)
		if parse_err.kind != .None do return parse_err
		file = parsed
	}
	defer if has_file do sqlite_file_destroy(&file)
	saved_commit := store.hooks.commit
	saved_row := store.hooks.row_change
	saved_event := store.hooks.row_event
	store.hooks.commit = nil
	store.hooks.row_change = nil
	store.hooks.row_event = nil
	defer {
		store.hooks.commit = saved_commit
		store.hooks.row_change = saved_row
		store.hooks.row_event = saved_event
	}
	if detach && len(store.sqlite_mirror) > 0 {
		delete(store.sqlite_mirror)
		store.sqlite_mirror = ""
		mirror_destroy(store.mirror)
		store.mirror = nil
	}
	// The text the old file kept describes objects that are going.
	store_mirror_kept_destroy(store)
	tx := tx_begin_write(store)
	for name in tx_table_names(tx, context.temp_allocator) {
		table := tx_table_probe(tx, name)
		if table == nil || table.schema.ephemeral do continue
		if strings.has_prefix(name, "_") && name != VIEW_TABLE && name != TRIGGER_TABLE && name != HEADER_TABLE do continue
		if drop_err := tx_drop_table(tx, name); drop_err.kind != .None {
			tx_rollback(tx)
			return drop_err
		}
	}
	if has_file {
		if _, _, import_err := sqlite_import_tx(&file, tx); import_err.kind != .None {
			tx_rollback(tx)
			return import_err
		}
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None do return commit_err
	if has_file do sqlite_import_finish(&file, store)
	return ERROR_NONE
}
