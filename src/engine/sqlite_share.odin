package engine

import "base:runtime"
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
//
// Another process -- this engine or SQLite itself -- is coordinated with the way
// SQLite coordinates, through the operating system's byte-range locks on the
// file at SQLite's own offsets:
//
//   - reading the file takes SHARED (the 510-byte shared range, shared);
//   - writing takes RESERVED (one byte, exclusive) from the first write to the
//     transaction's end, so a second writer anywhere waits for its busy timeout
//     and fails with SQLITE_BUSY;
//   - the commit takes PENDING, which stops new readers, and then EXCLUSIVE (the
//     shared range, exclusive), which waits for the readers there are, while the
//     file is written;
//   - a connection compares the file's change counter (offset 24 of the
//     header) with the one it last saw before a statement outside a
//     transaction, and reads the file again when it moved.
//
// Every lock and every read goes through one handle per file in the process:
// on POSIX closing any other descriptor of the file would drop the process's
// locks on it. The mirror's own writes still open the file; they happen under
// EXCLUSIVE, at the end of the commit, so what a close drops early is a lock
// the commit no longer needs.

// SQLite's lock offsets (os.h).
@(private)
SQLITE_PENDING_BYTE :: u64(0x4000_0000)
@(private)
SQLITE_RESERVED_BYTE :: SQLITE_PENDING_BYTE + 1
@(private)
SQLITE_SHARED_FIRST :: SQLITE_PENDING_BYTE + 2
@(private)
SQLITE_SHARED_SIZE :: u32(510)
// How long a commit waits for another process's readers before it writes.
@(private)
SQLITE_EXCLUSIVE_WAIT_MS :: 5000

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
	// handle is the process's handle on the file, for the locks and the reads
	// (has_handle is false when the file could not be opened for writing: the
	// connections then coordinate within the process only). reserved says this
	// process holds RESERVED; readers counts the reads holding SHARED.
	handle:     uintptr,
	has_handle: bool,
	reserved:   bool,
	readers:    int,
}

// The registry outlives every connection and is shared by every thread, so it
// lives on the process heap: a caller's context.allocator may be a per-task
// arena (the test runner's is) that is gone while other threads still read the
// map.
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
	context.allocator = runtime.heap_allocator()
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	if sqlite_shares == nil do sqlite_shares = make(map[string]^Sqlite_Share)
	share, found := sqlite_shares[key]
	if !found {
		share = new(Sqlite_Share)
		share.path = strings.clone(key)
		sqlite_shares[share.path] = share
		if handle, open_err := lock_os_open(path); open_err.kind == .None {
			share.handle = handle
			share.has_handle = true
		} else {
			error_free(&open_err)
		}
	}
	share.refs += 1
	conn.share = share
	conn.share_generation = share.generation
	conn.store.mirror_guard = sqlite_share_mirror_guard
	conn.store.mirror_guard_ctx = share
	if counter, ok := sqlite_share_counter(share); ok do conn.share_counter = counter
}

// sqlite_share_leave lets go of the file at close.
sqlite_share_leave :: proc(conn: ^Embed_Conn) {
	share := conn.share
	if share == nil do return
	context.allocator = runtime.heap_allocator()
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	if share.writer == conn {
		share.writer = nil
		sqlite_share_os_unreserve(share)
	}
	share.refs -= 1
	conn.share = nil
	if conn.store != nil {
		conn.store.mirror_guard = nil
		conn.store.mirror_guard_ctx = nil
	}
	if share.refs > 0 do return
	if share.has_handle do lock_os_close(share.handle)
	delete_key(&sqlite_shares, share.path)
	delete(share.path)
	free(share)
}

// sqlite_share_acquire takes the write lock, waiting up to the connection's
// busy timeout for the connection that holds it.
@(private)
sqlite_share_acquire :: proc(conn: ^Embed_Conn) -> bool {
	share := conn.share
	wait := busy_wait_begin(conn)
	for {
		sync.lock(&sqlite_shares_mutex)
		taken := share.writer == nil || share.writer == conn
		if taken {
			// Then any other process's writer: RESERVED.
			if share.reserved || sqlite_share_os_try(share, SQLITE_RESERVED_BYTE, 1, true) {
				share.reserved = share.has_handle
				share.writer = conn
			} else {
				taken = false
			}
		}
		sync.unlock(&sqlite_shares_mutex)
		if taken do return true
		if !busy_wait_again(conn, &wait) do return false
	}
}

// Busy_Wait is one wait for a lock: until a deadline, or for as long as the
// connection's busy handler says to try again.
@(private)
Busy_Wait :: struct {
	deadline: time.Tick,
	count:    int,
}

@(private)
busy_wait_begin :: proc(conn: ^Embed_Conn) -> Busy_Wait {
	return Busy_Wait{deadline = time.tick_add(time.tick_now(), time.Duration(max(conn.busy_timeout_ms, 0)) * time.Millisecond)}
}

// busy_wait_again says whether to try the lock once more, after waiting: the
// handler waits as it likes (SQLite's sleeps), the timeout a millisecond.
@(private)
busy_wait_again :: proc(conn: ^Embed_Conn, wait: ^Busy_Wait) -> bool {
	if conn.busy_handler != nil {
		again := conn.busy_handler(conn.busy_user, wait.count)
		wait.count += 1
		return again
	}
	if time.tick_diff(time.tick_now(), wait.deadline) <= 0 do return false
	time.sleep(time.Millisecond)
	return true
}

@(private)
sqlite_share_release :: proc(conn: ^Embed_Conn) {
	share := conn.share
	sync.lock(&sqlite_shares_mutex)
	if share.writer == conn {
		share.writer = nil
		sqlite_share_os_unreserve(share)
	}
	sync.unlock(&sqlite_shares_mutex)
}

// sqlite_share_os_try takes one OS lock without waiting; with no handle there
// is no other process to wait for.
@(private)
sqlite_share_os_try :: proc(share: ^Sqlite_Share, offset: u64, length: u32, exclusive: bool) -> bool {
	if !share.has_handle do return true
	return lock_os_acquire_range(share.handle, offset, length, exclusive)
}

// sqlite_share_os_unreserve lets RESERVED go. The caller holds the registry
// mutex.
@(private)
sqlite_share_os_unreserve :: proc(share: ^Sqlite_Share) {
	if !share.reserved do return
	lock_os_release_range(share.handle, SQLITE_RESERVED_BYTE, 1)
	share.reserved = false
}

// sqlite_share_read_begin takes SHARED for a read of the file, waiting up to
// the connection's busy timeout or handler while another process commits (it holds PENDING or EXCLUSIVE). The
// reads of this process share one lock.
@(private)
sqlite_share_read_begin :: proc(share: ^Sqlite_Share, conn: ^Embed_Conn) -> bool {
	if !share.has_handle do return true
	wait := busy_wait_begin(conn)
	for {
		sync.lock(&sqlite_shares_mutex)
		taken := share.readers > 0
		if !taken && lock_os_acquire_range(share.handle, SQLITE_PENDING_BYTE, 1, false) {
			// PENDING is taken shared and let go, as SQLite does: a writer
			// waiting to commit holds it, and no new reader starts then.
			taken = lock_os_acquire_range(share.handle, SQLITE_SHARED_FIRST, SQLITE_SHARED_SIZE, false)
			lock_os_release_range(share.handle, SQLITE_PENDING_BYTE, 1)
		}
		if taken do share.readers += 1
		sync.unlock(&sqlite_shares_mutex)
		if taken do return true
		if !busy_wait_again(conn, &wait) do return false
	}
}

@(private)
sqlite_share_read_end :: proc(share: ^Sqlite_Share) {
	if !share.has_handle do return
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	share.readers -= 1
	if share.readers == 0 do lock_os_release_range(share.handle, SQLITE_SHARED_FIRST, SQLITE_SHARED_SIZE)
}

// sqlite_share_counter reads the file's change counter through the share's
// handle (offset 24 of the header).
@(private)
sqlite_share_counter :: proc(share: ^Sqlite_Share) -> (u32, bool) {
	if !share.has_handle do return 0, false
	header: [28]u8
	if lock_os_read_at(share.handle, 0, header[:]) < 28 do return 0, false
	return u32(header[24]) << 24 | u32(header[25]) << 16 | u32(header[26]) << 8 | u32(header[27]), true
}

// sqlite_share_read_file reads the whole file through the share's handle.
@(private)
sqlite_share_read_file :: proc(share: ^Sqlite_Share, path: string) -> ([]u8, bool) {
	if !share.has_handle {
		image, read_err := os.read_entire_file(path, context.allocator)
		return image, read_err == nil
	}
	size := lock_os_size(share.handle)
	if size < 0 do return nil, false
	image := make([]u8, int(size))
	if lock_os_read_at(share.handle, 0, image) != len(image) {
		delete(image)
		return nil, false
	}
	return image, true
}

// sqlite_share_mirror_guard is the store's hook around the write of its file:
// EXCLUSIVE while it writes (PENDING first, so no new reader starts, then the
// shared range once the readers there are have finished). A reader that keeps
// its lock longer than SQLITE_EXCLUSIVE_WAIT_MS does not stop the commit, which
// the log already holds; the write goes ahead.
@(private)
sqlite_share_mirror_guard :: proc(ctx: rawptr, begin: bool) {
	share := (^Sqlite_Share)(ctx)
	if !share.has_handle do return
	if !begin {
		lock_os_release_range(share.handle, SQLITE_SHARED_FIRST, SQLITE_SHARED_SIZE)
		lock_os_release_range(share.handle, SQLITE_PENDING_BYTE, 1)
		return
	}
	deadline := time.tick_add(time.tick_now(), SQLITE_EXCLUSIVE_WAIT_MS * time.Millisecond)
	for !lock_os_acquire_range(share.handle, SQLITE_PENDING_BYTE, 1, true) {
		if time.tick_diff(time.tick_now(), deadline) <= 0 do break
		time.sleep(time.Millisecond)
	}
	for !lock_os_acquire_range(share.handle, SQLITE_SHARED_FIRST, SQLITE_SHARED_SIZE, true) {
		if time.tick_diff(time.tick_now(), deadline) <= 0 do break
		time.sleep(time.Millisecond)
	}
}

// sqlite_share_refresh reads the file again when another connection committed
// since this one last read or wrote it: one of this process (the generation
// moved) or of any other (the file's change counter moved).
@(private)
sqlite_share_refresh :: proc(conn: ^Embed_Conn) -> Error {
	share := conn.share
	sync.lock(&sqlite_shares_mutex)
	generation := share.generation
	sync.unlock(&sqlite_shares_mutex)
	if generation == conn.share_generation && !share.has_handle do return ERROR_NONE
	// A statement of this thread that holds the file (a function that runs a
	// statement on another connection mid-commit) leaves the read for later.
	if !sync.rw_mutex_try_shared_lock(&share.file) do return ERROR_NONE
	defer sync.rw_mutex_shared_unlock(&share.file)
	store := conn.store
	mirror := strings.clone(store.sqlite_mirror, context.temp_allocator)
	if len(mirror) == 0 do return ERROR_NONE
	// Another process committing past the wait is SQLite's BUSY: reading what
	// the store held before would answer from an older database.
	if !sqlite_share_read_begin(share, conn) do return errf(.Locked, "database is locked")
	defer sqlite_share_read_end(share)
	counter, counted := sqlite_share_counter(share)
	if generation == conn.share_generation && (!counted || counter == conn.share_counter) do return ERROR_NONE
	image, read_ok := sqlite_share_read_file(share, mirror)
	if !read_ok do return errf(.Io, "disk I/O error")
	defer delete(image)
	// What the connection set for itself stays; the content is the file's.
	foreign_keys_off, sqlite_rules := store.foreign_keys_off, store.sqlite_rules
	last_changes, total_changes, last_row_id := store.last_changes, store.total_changes, store.last_row_id
	if replace_err := store_replace_content(store, image, true); replace_err.kind != .None {
		// The store keeps what it had and stays the file's, so the next
		// statement tries again; this one fails rather than read it.
		store_set_sqlite_mirror(store, mirror)
		return replace_err
	}
	store_set_sqlite_mirror(store, mirror)
	store.foreign_keys_off, store.sqlite_rules = foreign_keys_off, sqlite_rules
	store.last_changes, store.total_changes, store.last_row_id = last_changes, total_changes, last_row_id
	conn.share_generation = generation
	if counted do conn.share_counter = counter
	return ERROR_NONE
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
		if refresh_err := sqlite_share_refresh(conn); refresh_err.kind != .None {
			if share.writer == conn && conn.tx == nil do sqlite_share_release(conn)
			return {}, refresh_err
		}
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
		// The file now carries this commit's counter: it is not news here.
		if counter, ok := sqlite_share_counter(share); ok do conn.share_counter = counter
	}
	if holds do sync.rw_mutex_unlock(&share.file)
	if conn.tx == nil do sqlite_share_release(conn)
	return result, err
}
