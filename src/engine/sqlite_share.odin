package engine

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// Connections to one SQLite file in this process see each other the way
// SQLite's do. Each connection keeps its own store, as each SQLite connection
// keeps its own page cache, so what SQLite keeps per connection stays per
// connection (functions, hooks, changes(), the rowid of the last insert,
// PRAGMA foreign_keys). What they share is the file's:
//
//   - a write lock: one connection at a time writes, from its first write
//     to its commit or rollback; another that wants to write waits for its
//     busy timeout and then fails with "database is locked" (SQLITE_BUSY);
//   - a generation: a commit writes the file and moves it on, and a
//     connection reads the file again before its next statement outside a
//     transaction when the generation moved, as SQLite rereads a file whose
//     change counter moved.
//
// A reader is never blocked by another connection's open transaction: it
// reads its own store, which holds the last commit.

@(private)
Sqlite_Share :: struct {
	path:       string,
	refs:       int,
	// writer is the connection that holds the write lock, nil when none does.
	writer:     ^Embed_Conn,
	generation: u64,
	// file guards the file while a statement that may commit writes it, so a
	// connection catching up never reads half a commit.
	file:       sync.RW_Mutex,
}

@(private)
sqlite_shares: map[string]^Sqlite_Share

@(private)
sqlite_shares_mutex: sync.Mutex

// sqlite_share_key is the name the file is shared under: its absolute path,
// without case on Windows, where the file system has none.
@(private)
sqlite_share_key :: proc(path: string) -> string {
	absolute, abs_err := filepath.abs(path, context.temp_allocator)
	key := abs_err == nil ? absolute : path
	when ODIN_OS == .Windows {
		key, _ = strings.replace_all(strings.to_lower(key, context.temp_allocator), "\\", "/", context.temp_allocator)
	}
	return key
}

// sqlite_share_join makes the connection one of the file's.
sqlite_share_join :: proc(conn: ^Embed_Conn, path: string) {
	key := sqlite_share_key(path)
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	if sqlite_shares == nil do sqlite_shares = make(map[string]^Sqlite_Share)
	share, found := sqlite_shares[key]
	if !found {
		share = new(Sqlite_Share)
		share.path = strings.clone(key)
		sqlite_shares[share.path] = share
	}
	share.refs += 1
	conn.share = share
	conn.share_generation = share.generation
}

// sqlite_share_leave lets go of the file at close.
sqlite_share_leave :: proc(conn: ^Embed_Conn) {
	share := conn.share
	if share == nil do return
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	if share.writer == conn do share.writer = nil
	share.refs -= 1
	conn.share = nil
	if share.refs > 0 do return
	delete_key(&sqlite_shares, share.path)
	delete(share.path)
	free(share)
}

// sqlite_share_acquire takes the write lock, waiting up to the connection's
// busy timeout for the connection that holds it.
@(private)
sqlite_share_acquire :: proc(conn: ^Embed_Conn) -> bool {
	share := conn.share
	deadline := time.tick_add(time.tick_now(), time.Duration(conn.busy_timeout_ms) * time.Millisecond)
	for {
		sync.lock(&sqlite_shares_mutex)
		taken := share.writer == nil || share.writer == conn
		if taken do share.writer = conn
		sync.unlock(&sqlite_shares_mutex)
		if taken do return true
		if time.tick_diff(time.tick_now(), deadline) <= 0 do return false
		time.sleep(time.Millisecond)
	}
}

@(private)
sqlite_share_release :: proc(conn: ^Embed_Conn) {
	share := conn.share
	sync.lock(&sqlite_shares_mutex)
	if share.writer == conn do share.writer = nil
	sync.unlock(&sqlite_shares_mutex)
}

// sqlite_share_refresh reads the file again when another connection committed
// since this one last read or wrote it.
@(private)
sqlite_share_refresh :: proc(conn: ^Embed_Conn) {
	share := conn.share
	sync.lock(&sqlite_shares_mutex)
	generation := share.generation
	sync.unlock(&sqlite_shares_mutex)
	if generation == conn.share_generation do return
	// A statement of this thread that holds the file (a function that runs a
	// statement on another connection mid-commit) leaves the read for later.
	if !sync.rw_mutex_try_shared_lock(&share.file) do return
	defer sync.rw_mutex_shared_unlock(&share.file)
	store := conn.store
	mirror := strings.clone(store.sqlite_mirror, context.temp_allocator)
	if len(mirror) == 0 do return
	image, read_err := os.read_entire_file(mirror, context.allocator)
	if read_err != nil do return
	defer delete(image)
	// What the connection set for itself stays; the content is the file's.
	foreign_keys_off, sqlite_rules := store.foreign_keys_off, store.sqlite_rules
	last_changes, total_changes, last_row_id := store.last_changes, store.total_changes, store.last_row_id
	if replace_err := store_replace_content(store, image, true); replace_err.kind != .None {
		error_free(&replace_err)
		return
	}
	store_set_sqlite_mirror(store, mirror)
	store.foreign_keys_off, store.sqlite_rules = foreign_keys_off, sqlite_rules
	store.last_changes, store.total_changes, store.last_row_id = last_changes, total_changes, last_row_id
	conn.share_generation = generation
}

// embed_statement_writes reports a statement that needs the write lock: one
// that is not a plain read.
@(private)
embed_statement_writes :: proc(prepared: ^Stmt_Prepared) -> bool {
	if prepared.is_pragma do return strings.contains(prepared.pragma_body, "=")
	#partial switch _ in prepared.query.statement {
	case Select_Stmt, With_Stmt, Explain_Stmt, Describe_Stmt, Show_Stmt, Commit_Stmt, Rollback_Stmt:
		return false
	}
	return true
}

// embed_run_shared runs a statement on a connection that shares its file:
// outside a transaction it catches up with the file first, a write takes the
// file's write lock until the transaction ends, and a commit moves the
// generation on.
@(private)
embed_run_shared :: proc(conn: ^Embed_Conn, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	share := conn.share
	if conn.tx == nil {
		if embed_statement_writes(prepared) && !sqlite_share_acquire(conn) {
			return {}, errf(.Locked, "database is locked")
		}
		sqlite_share_refresh(conn)
	}
	holds := share.writer == conn
	if holds do sync.rw_mutex_lock(&share.file)
	seq := conn.store.commit_seq
	result, err := embed_run_statement(conn, prepared, params)
	if conn.store.commit_seq != seq && holds {
		sync.lock(&sqlite_shares_mutex)
		share.generation += 1
		conn.share_generation = share.generation
		sync.unlock(&sqlite_shares_mutex)
	}
	if holds do sync.rw_mutex_unlock(&share.file)
	if conn.tx == nil do sqlite_share_release(conn)
	return result, err
}
