package sqlite_compat

// The database as a whole: its image (sqlite3_serialize, sqlite3_deserialize),
// a copy into another connection (sqlite3_backup_*), and what a connection
// says about the databases it holds (sqlite3_db_filename, _db_name,
// _db_readonly, _txn_state). The image is SQLite's file format, written and
// read by the engine's own writer and importer (src/engine/sqlite_image.odin).

import "core:c"
import "core:slice"
import "core:strings"

import engine "../engine"

SQLITE_SERIALIZE_NOCOPY :: c.uint(0x001)
SQLITE_DESERIALIZE_FREEONCLOSE :: c.uint(1)
SQLITE_DESERIALIZE_RESIZEABLE :: c.uint(2)
SQLITE_DESERIALIZE_READONLY :: c.uint(4)

SQLITE_TXN_NONE :: c.int(0)
SQLITE_TXN_READ :: c.int(1)
SQLITE_TXN_WRITE :: c.int(2)

// schema_is_main reports the name of the database a connection opened: NULL
// and "main" both name it.
@(private)
schema_is_main :: proc(schema: cstring) -> bool {
	return schema == nil || strings.equal_fold(string(schema), "main")
}

// sqlite3_serialize answers the database as the bytes of a SQLite file, from
// sqlite3_malloc. There is no copy of the database kept as one block of
// memory, so SQLITE_SERIALIZE_NOCOPY answers NULL, which SQLite does for a
// database that has none either.
@(export)
sqlite3_serialize :: proc "c" (handle: rawptr, schema: cstring, size: ^i64, flags: c.uint) -> [^]u8 {
	context = engine.oom_context()
	if size != nil do size^ = -1
	db := db_of(handle)
	if db == nil || !schema_is_main(schema) do return nil
	if flags & SQLITE_SERIALIZE_NOCOPY != 0 do return nil
	image, err := db_image(db)
	if !engine.error_drop(err) do return nil
	defer delete(image)
	block := ([^]u8)(sqlite_alloc(len(image)))
	if block == nil do return nil
	copy(block[:len(image)], image)
	if size != nil do size^ = i64(len(image))
	return block
}

// db_image is the connection's committed database as a SQLite file image. A
// connection inside a transaction holds the store's lock, so the image is
// built without taking it again.
@(private)
db_image :: proc(db: ^Database) -> ([]u8, engine.Error) {
	if db.conn.tx != nil {
		image, _, _, err := engine.sqlite_file_image(db.conn.store)
		return image, err
	}
	return engine.store_sqlite_image(db.conn.store)
}

// sqlite3_deserialize makes the connection's database hold the image. The
// bytes are copied (an image handed over with FREEONCLOSE is freed now, since
// nothing keeps it), and a database opened on a SQLite file stops writing that
// file, as SQLite's deserialized connection lives in memory. Bytes that are not
// a database are taken, as SQLite takes them, and every statement then fails
// with SQLITE_NOTADB. With SQLITE_DESERIALIZE_READONLY a write fails with
// SQLITE_READONLY.
@(export)
sqlite3_deserialize :: proc "c" (handle: rawptr, schema: cstring, data: [^]u8, db_size: i64, buffer_size: i64, flags: c.uint) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	defer if flags & SQLITE_DESERIALIZE_FREEONCLOSE != 0 && data != nil do sqlite3_free(data)
	if !schema_is_main(schema) {
		set_error(db, "not an error")
		return SQLITE_ERROR
	}
	if db_size < 0 || (db_size > 0 && data == nil) do return SQLITE_MISUSE
	if db.conn.tx != nil {
		set_error(db, "database is locked")
		db.last_code, db.last_extended = SQLITE_BUSY, SQLITE_BUSY
		return SQLITE_BUSY
	}
	image := db_size > 0 ? data[:db_size] : nil
	store := db.conn.store
	store.read_only = false
	db.not_a_database = false
	err := engine.store_replace_content(store, image, true)
	if err.kind == .Invalid_Argument || err.kind == .Corrupt_Log || err.kind == .Sql_Unsupported {
		engine.error_free(&err)
		db.not_a_database = true
		err = engine.store_replace_content(store, nil, true)
	}
	if err.kind != .None {
		code := sqlite_code(err)
		set_error_from(db, err)
		db.last_code, db.last_extended = code, code
		return code
	}
	if flags & SQLITE_DESERIALIZE_READONLY != 0 do store.read_only = true
	db.in_memory = true
	delete(db.filename)
	db.filename = strings.clone_to_cstring("")
	return SQLITE_OK
}

// Backup is one copy in progress. SQLite copies pages a step at a time; this
// copies the whole database when the steps reach the last page, from the
// source as it is then, in one transaction of the destination, so a reader of
// the destination sees the old database or the new one. The page counts are
// the source image's pages, so a loop that reports progress reads what
// SQLite's would.
Backup :: struct {
	dest:      ^Database,
	source:    ^Database,
	// source_store is the database copied: the main one, an attached one, or
	// none for the temp database, which is empty here.
	source_store: ^engine.Store,
	// source_seq is the source's commit when the copy started: a commit since
	// starts the copy over, as SQLite restarts a backup whose source changed.
	source_seq: u64,
	pages:     c.int,
	copied:    c.int,
	started:   bool,
	done:      bool,
	// code is the error a step met, which finish answers.
	code:      c.int,
}

@(private)
backup_fail :: proc(db: ^Database, code: c.int, message: string) {
	set_error(db, message)
	db.last_code, db.last_extended = code, code
}

// sqlite3_backup_init starts copying source's database into dest's. Only the
// main database of either side can be named here.
@(export)
sqlite3_backup_init :: proc "c" (dest_handle: rawptr, dest_name: cstring, source_handle: rawptr, source_name: cstring) -> rawptr {
	context = engine.oom_context()
	dest := db_of(dest_handle)
	source := db_of(source_handle)
	if dest == nil || source == nil do return nil
	if dest == source {
		backup_fail(dest, SQLITE_ERROR, "source and destination must be distinct")
		return nil
	}
	if !schema_is_main(dest_name) {
		backup_fail(dest, SQLITE_ERROR, strings.concatenate({"unknown database ", string(dest_name)}, context.temp_allocator))
		return nil
	}
	// The source may be main, temp (empty here) or an attached database.
	source_store := source.conn.store
	if !schema_is_main(source_name) {
		name := string(source_name)
		if strings.equal_fold(name, "temp") {
			source_store = nil
		} else if attached, found := source.conn.store.attached[name]; found && attached != nil {
			source_store = attached
		} else {
			backup_fail(dest, SQLITE_ERROR, strings.concatenate({"unknown database ", name}, context.temp_allocator))
			return nil
		}
	}
	// A BEGIN that has not read anything yet holds nothing, as in SQLite.
	if sqlite3_txn_state(dest_handle, nil) != SQLITE_TXN_NONE {
		backup_fail(dest, SQLITE_ERROR, "destination database is in use")
		return nil
	}
	backup := new(Backup)
	backup.dest = dest
	backup.source = source
	backup.source_store = source_store
	engine.handle_register(rawptr(backup))
	return rawptr(backup)
}

// backup_image is the source database as SQLite file bytes.
@(private)
backup_image :: proc(backup: ^Backup) -> ([]u8, engine.Error) {
	if backup.source_store == backup.source.conn.store do return db_image(backup.source)
	if backup.source_store != nil do return engine.store_sqlite_image(backup.source_store)
	// The temp database: nothing in it.
	empty, open_err := engine.store_open("", {persistent = false})
	if open_err.kind != .None do return nil, open_err
	defer engine.store_close(empty)
	return engine.store_sqlite_image(empty)
}

@(private)
backup_of :: proc(handle: rawptr) -> ^Backup {
	if !engine.handle_is_live(handle) do return nil
	return cast(^Backup)handle
}

// sqlite3_backup_step copies n more pages, or every page left when n is
// negative, and answers SQLITE_DONE once the last one is copied.
@(export)
sqlite3_backup_step :: proc "c" (handle: rawptr, pages: c.int) -> c.int {
	context = engine.oom_context()
	backup := backup_of(handle)
	if backup == nil do return SQLITE_MISUSE
	if backup.done do return SQLITE_DONE
	if backup.code != SQLITE_OK do return backup.code
	if backup.dest.conn.tx != nil || backup.source.conn.tx != nil {
		// A transaction open on either side holds the lock the copy needs.
		return SQLITE_BUSY
	}
	// A source that committed since the copy started is copied again from
	// its first page.
	if backup.started && backup.source_store != nil && backup.source_store.commit_seq != backup.source_seq {
		backup.started = false
		backup.copied = 0
	}
	if !backup.started {
		image, err := backup_image(backup)
		if !engine.error_drop(err) {
			backup.code = SQLITE_ERROR
			return backup.code
		}
		backup.pages = c.int(engine.sqlite_image_page_count(image))
		delete(image)
		backup.started = true
		if backup.source_store != nil do backup.source_seq = backup.source_store.commit_seq
	}
	if pages < 0 || backup.copied + pages >= backup.pages {
		backup.copied = backup.pages
	} else {
		backup.copied += pages
		return SQLITE_OK
	}
	// The last step copies the source as it is now.
	image, err := backup_image(backup)
	if !engine.error_drop(err) {
		backup.code = SQLITE_ERROR
		return backup.code
	}
	defer delete(image)
	backup.pages = c.int(engine.sqlite_image_page_count(image))
	backup.copied = backup.pages
	if replace_err := engine.store_replace_content(backup.dest.conn.store, image, false); replace_err.kind != .None {
		backup.code = sqlite_code(replace_err)
		set_error_from(backup.dest, replace_err)
		backup.dest.last_code, backup.dest.last_extended = backup.code, backup.code
		return backup.code
	}
	backup.done = true
	return SQLITE_DONE
}

@(export)
sqlite3_backup_remaining :: proc "c" (handle: rawptr) -> c.int {
	context = engine.oom_context()
	backup := backup_of(handle)
	if backup == nil do return 0
	return backup.pages - backup.copied
}

@(export)
sqlite3_backup_pagecount :: proc "c" (handle: rawptr) -> c.int {
	context = engine.oom_context()
	backup := backup_of(handle)
	if backup == nil do return 0
	return backup.pages
}

// sqlite3_backup_finish ends the copy. A copy that did not reach its last
// step changed nothing; the answer is the error a step met, if any.
@(export)
sqlite3_backup_finish :: proc "c" (handle: rawptr) -> c.int {
	context = engine.oom_context()
	backup := backup_of(handle)
	if backup == nil do return SQLITE_OK
	code := backup.code
	if code == SQLITE_BUSY do code = SQLITE_OK
	if code == SQLITE_OK && engine.handle_is_live(rawptr(backup.dest)) {
		backup.dest.last_code, backup.dest.last_extended = SQLITE_OK, SQLITE_OK
	}
	engine.handle_forget(handle)
	free(backup)
	return code
}

// sqlite3_db_filename is the absolute path of the file a database lives in,
// "" for one in memory, and NULL for a name the connection does not hold.
@(export)
sqlite3_db_filename :: proc "c" (handle: rawptr, schema: cstring) -> cstring {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return nil
	if schema_is_main(schema) do return db.filename
	if strings.equal_fold(string(schema), "temp") do return ""
	if attached, found := db.conn.store.attached[string(schema)]; found && attached != nil {
		// An attached database's file is the path it was attached from.
		return ""
	}
	return nil
}

// sqlite3_db_name names the connection's databases by index: 0 is main, 1 is
// temp, and the attached ones follow in name order.
@(export)
sqlite3_db_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil || index < 0 do return nil
	switch index {
	case 0:
		return "main"
	case 1:
		return "temp"
	}
	names := make([dynamic]string, 0, len(db.conn.store.attached), context.temp_allocator)
	for name in db.conn.store.attached do append(&names, name)
	slice.sort(names[:])
	at := int(index) - 2
	if at >= len(names) do return nil
	delete(db.attached_name)
	db.attached_name = strings.clone_to_cstring(names[at])
	return db.attached_name
}

// sqlite3_db_readonly is 1 for a read-only database, 0 for a writable one and
// -1 for a name the connection does not hold. An attached database answers
// for its own store, as SQLite's does.
@(export)
sqlite3_db_readonly :: proc "c" (handle: rawptr, schema: cstring) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return -1
	if schema_is_main(schema) do return db.conn.store.read_only ? 1 : 0
	if strings.equal_fold(string(schema), "temp") do return 0
	if attached, found := db.conn.store.attached[string(schema)]; found do return attached.read_only ? 1 : 0
	return -1
}

// sqlite3_txn_state is the transaction the connection holds on a database:
// none, a read (a BEGIN that has read a table) or a write (one that has
// written). NULL asks for the highest over every database; a name the
// connection does not hold is -1.
@(export)
sqlite3_txn_state :: proc "c" (handle: rawptr, schema: cstring) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return -1
	if schema != nil && !schema_is_main(schema) {
		if strings.equal_fold(string(schema), "temp") do return SQLITE_TXN_NONE
		if _, found := db.conn.store.attached[string(schema)]; found do return SQLITE_TXN_NONE
		return -1
	}
	tx := db.conn.tx
	if tx == nil do return SQLITE_TXN_NONE
	if tx.wrote do return SQLITE_TXN_WRITE
	if engine.tx_read_any(tx) do return SQLITE_TXN_READ
	return SQLITE_TXN_NONE
}
