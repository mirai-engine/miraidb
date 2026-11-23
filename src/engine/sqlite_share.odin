package engine

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
	sqlite_share_attach(conn, sqlite_share_take(path))
}

// sqlite_share_take is the file's share, made the first time, with one more
// reference: what an open reads the file under before its connection exists.
@(private)
sqlite_share_take :: proc(path: string) -> ^Sqlite_Share {
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
	return share
}

// sqlite_share_attach makes the connection one of the share's, which already
// counts it.
@(private)
sqlite_share_attach :: proc(conn: ^Embed_Conn, share: ^Sqlite_Share) {
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
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
	sqlite_share_hashes_clear(conn)
	delete(conn.share_hashes)
	conn.share_hashes = nil
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	if share.writer == conn {
		share.writer = nil
		sqlite_share_os_unreserve(share)
	}
	conn.share = nil
	if conn.store != nil {
		conn.store.mirror_guard = nil
		conn.store.mirror_guard_ctx = nil
	}
	sqlite_share_unref(share)
}

// sqlite_share_drop gives back a reference sqlite_share_take took for an
// open that failed.
@(private)
sqlite_share_drop :: proc(share: ^Sqlite_Share) {
	context.allocator = runtime.heap_allocator()
	sync.lock(&sqlite_shares_mutex)
	defer sync.unlock(&sqlite_shares_mutex)
	sqlite_share_unref(share)
}

// sqlite_share_unref lets one reference go; the last closes the handle. The
// caller holds the registry mutex.
@(private)
sqlite_share_unref :: proc(share: ^Sqlite_Share) {
	share.refs -= 1
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
	// Most commits change a table or two: those are reloaded, and the store
	// keeps the rest. Anything else (a schema change, a file this cannot hash)
	// reads the whole file again, as before.
	file, parse_err := sqlite_file_from_bytes(image)
	parsed := parse_err.kind == .None
	if !parsed do error_free(&parse_err)
	defer if parsed do sqlite_file_destroy(&file)
	hashes := make(map[string]Share_Tree, 16, context.temp_allocator)
	if parsed do sqlite_share_hash_file(&file, &hashes, conn.share_hashes)
	caught_up := parsed && sqlite_share_catch_up(conn, &file, hashes, mirror)
	if !caught_up {
		if replace_err := store_replace_content(store, image, true); replace_err.kind != .None {
			// The store keeps what it had and stays the file's, so the next
			// statement tries again; this one fails rather than read it.
			store_set_sqlite_mirror(store, mirror)
			sqlite_share_hashes_clear(conn)
			return replace_err
		}
		store_set_sqlite_mirror(store, mirror)
	}
	if parsed {
		sqlite_share_hashes_keep(conn, hashes)
	} else {
		sqlite_share_hashes_clear(conn)
	}
	store.foreign_keys_off, store.sqlite_rules = foreign_keys_off, sqlite_rules
	store.last_changes, store.total_changes, store.last_row_id = last_changes, total_changes, last_row_id
	conn.share_generation = generation
	if counted do conn.share_counter = counter
	return ERROR_NONE
}

// SHARE_HASH_SCHEMA and SHARE_HASH_SEQUENCE key the hashes of sqlite_master
// (with the header integers a program sets) and of sqlite_sequence; no table
// name starts with a zero byte.
@(private)
SHARE_HASH_SCHEMA :: "\x00schema"
@(private)
SHARE_HASH_SEQUENCE :: "\x00sequence"

// Share_Tree is what a connection knows of one b-tree of the file: a hash of
// its rows, its root, and the pages it is made of with a sum of each page's
// bytes. A tree whose root is the same and whose pages all hold the same bytes
// is the same tree, so its rows are not read again. The schema and
// sqlite_sequence keep the hash alone and are always hashed again.
Share_Tree :: struct {
	hash:  u64,
	root:  u32,
	pages: []u32,
	sums:  []u64,
}

// sqlite_share_page_sum sums a page's bytes, eight at a time.
@(private)
sqlite_share_page_sum :: proc(page: []u8) -> u64 {
	hash := u64(0xcbf29ce484222325) ~ u64(len(page))
	words := len(page) / 8
	for i in 0 ..< words {
		hash = (hash ~ intrinsics.unaligned_load((^u64)(&page[i * 8]))) * 0x9e3779b97f4a7c15
		hash ~= hash >> 29
	}
	for b in page[words * 8:] {
		hash = (hash ~ u64(b)) * 0x9e3779b97f4a7c15
		hash ~= hash >> 29
	}
	return hash
}

// sqlite_share_tree_same says the tree the connection knows is still the
// file's: the same root, and every page of it holding the same bytes.
@(private)
sqlite_share_tree_same :: proc(file: ^Sqlite_File, known: Share_Tree, root: u32) -> bool {
	if known.root != root || len(known.pages) == 0 || len(known.pages) != len(known.sums) do return false
	for page_no, i in known.pages {
		page := sqlite_page(file, page_no)
		if len(page) != int(file.page_size) || sqlite_share_page_sum(page) != known.sums[i] do return false
	}
	return true
}

// sqlite_share_hash_tree hashes a b-tree's rows, each its rowid and its whole
// payload (overflow included), in key order: FNV-1a over the bytes. `pages`,
// when given, collects the pages the tree is made of.
@(private)
sqlite_share_hash_tree :: proc(file: ^Sqlite_File, root: u32, table: bool, pages: ^[dynamic]u32 = nil) -> (u64, bool) {
	Ctx :: struct {
		hash: u64,
	}
	ctx := Ctx{hash = 0xcbf29ce484222325}
	mix :: proc(ctx: ^Ctx, bytes: []u8) {
		for b in bytes {
			ctx.hash ~= u64(b)
			ctx.hash *= 0x100000001b3
		}
	}
	visit := proc(user: rawptr, rowid: i64, payload: []u8) -> bool {
		ctx := (^Ctx)(user)
		id := rowid
		mix(ctx, ([^]u8)(&id)[:size_of(i64)])
		length := len(payload)
		mix(ctx, ([^]u8)(&length)[:size_of(int)])
		mix(ctx, payload)
		return true
	}
	if !sqlite_walk(file, root, table, visit, &ctx, 0, pages) do return 0, false
	return ctx.hash, true
}

// sqlite_share_hash_schema hashes sqlite_master's rows without their rootpage:
// the mirror gives a table that outgrows its page a new root, which says
// nothing of the schema, and the mirror is built again from the file anyway.
@(private)
sqlite_share_hash_schema :: proc(file: ^Sqlite_File) -> (u64, bool) {
	Ctx :: struct {
		hash: u64,
	}
	ctx := Ctx{hash = 0xcbf29ce484222325}
	mix :: proc(ctx: ^Ctx, bytes: []u8) {
		for b in bytes {
			ctx.hash ~= u64(b)
			ctx.hash *= 0x100000001b3
		}
	}
	visit := proc(user: rawptr, rowid: i64, payload: []u8) -> bool {
		ctx := (^Ctx)(user)
		values, decoded := sqlite_record(payload, context.temp_allocator)
		if !decoded do return false
		id := rowid
		mix(ctx, ([^]u8)(&id)[:size_of(i64)])
		for value, column in values {
			if column == 3 do continue
			kind := u8(value.kind)
			mix(ctx, ([^]u8)(&kind)[:1])
			text := value.kind == .String ? value.s : ""
			length := len(text)
			mix(ctx, ([^]u8)(&length)[:size_of(int)])
			mix(ctx, transmute([]u8)text)
		}
		return true
	}
	if !sqlite_walk(file, 1, true, visit, &ctx, 0) do return 0, false
	return ctx.hash, true
}

// sqlite_share_hash_file fills `out` with the hash of every table the file
// declares, of its schema and of sqlite_sequence. A table whose tree `known`
// still matches keeps what is known of it (the entry shares its pages with
// `known`); the rest are walked. A tree it cannot walk is left out, and a table
// missing from the hashes is always reloaded.
@(private)
sqlite_share_hash_file :: proc(file: ^Sqlite_File, out: ^map[string]Share_Tree, known: map[string]Share_Tree = nil) {
	if schema, ok := sqlite_share_hash_schema(file); ok {
		// The header's schema cookie, user_version, application_id and the
		// rest of what a program sets (bytes 40 to 91): the change counter and
		// the page count move with every commit and say nothing of content.
		page_one := sqlite_page(file, 1)
		if len(page_one) >= 92 {
			// The page size (bytes 16 and 17) too: a VACUUM to another size
			// rewrites every page without changing a row.
			for b in page_one[16:18] {
				schema ~= u64(b)
				schema *= 0x100000001b3
			}
			for b in page_one[40:92] {
				schema ~= u64(b)
				schema *= 0x100000001b3
			}
			out[SHARE_HASH_SCHEMA] = Share_Tree{hash = schema}
		}
	}
	if file.sequence_root != 0 {
		if sequence, ok := sqlite_share_hash_tree(file, file.sequence_root, true); ok do out[SHARE_HASH_SEQUENCE] = Share_Tree{hash = sequence}
	} else {
		out[SHARE_HASH_SEQUENCE] = Share_Tree{}
	}
	for &table in file.tables {
		if before, has_before := known[table.name]; has_before && sqlite_share_tree_same(file, before, table.root_page) {
			out[table.name] = before
			continue
		}
		pages := make([dynamic]u32, 0, 16, context.temp_allocator)
		hash, ok := sqlite_share_hash_tree(file, table.root_page, !table.without_rowid, &pages)
		if !ok do continue
		sums := make([]u64, len(pages), context.temp_allocator)
		for page_no, i in pages do sums[i] = sqlite_share_page_sum(sqlite_page(file, page_no))
		out[table.name] = Share_Tree{hash = hash, root = table.root_page, pages = pages[:], sums = sums}
	}
}

// sqlite_share_catch_up brings the store up to the file by reloading only the
// tables whose rows changed since the store last matched it. It answers false,
// leaving the store as it was, whenever that is not enough: no hashes kept, a
// schema or sqlite_sequence that moved, a table it does not reload row by row.
@(private)
sqlite_share_catch_up :: proc(conn: ^Embed_Conn, file: ^Sqlite_File, hashes: map[string]Share_Tree, mirror: string) -> bool {
	kept := conn.share_hashes
	if len(kept) == 0 do return false
	for key in ([]string{SHARE_HASH_SCHEMA, SHARE_HASH_SEQUENCE}) {
		now, has_now := hashes[key]
		before, has_before := kept[key]
		if !has_now || !has_before || now.hash != before.hash do return false
	}
	changed := make([dynamic]^Sqlite_Table, 0, 4, context.temp_allocator)
	for &table in file.tables {
		now, has_now := hashes[table.name]
		before, has_before := kept[table.name]
		if has_now && has_before && now.hash == before.hash do continue
		if table.without_rowid || len(table.columns) == 0 do return false
		append(&changed, &table)
	}
	if len(changed) == 0 do return true
	store := conn.store
	for table in changed {
		if _, found := store.tables[table.name]; !found do return false
	}
	// The rows are the file's: no hook reports them, no trigger runs again, and
	// the commit does not write them back.
	saved_commit, saved_row := store.hooks.commit, store.hooks.row_change
	store.hooks.commit, store.hooks.row_change = nil, nil
	defer store.hooks.commit, store.hooks.row_change = saved_commit, saved_row
	saved_keys := store.foreign_keys_off
	store.foreign_keys_off = true
	defer store.foreign_keys_off = saved_keys
	delete(store.sqlite_mirror)
	store.sqlite_mirror = ""
	mirror_destroy(store.mirror)
	store.mirror = nil
	tx := tx_begin_write(store)
	tx.no_triggers = true
	ok := true
	reload: for table in changed {
		if truncate_err := tx_truncate(tx, table.name); truncate_err.kind != .None {
			error_free(&truncate_err)
			ok = false
			break reload
		}
		rows, rows_err := sqlite_table_rows(file, table, context.allocator)
		if rows_err.kind != .None {
			error_free(&rows_err)
			ok = false
			break reload
		}
		defer {
			for row in rows {
				for value in row do value_deep_free(value, context.allocator)
				delete(row)
			}
			delete(rows)
		}
		for row in rows {
			if _, insert_err := tx_insert(tx, table.name, row); insert_err.kind != .None {
				error_free(&insert_err)
				ok = false
				break reload
			}
		}
	}
	if ok {
		if commit_err := tx_commit(tx); commit_err.kind != .None {
			error_free(&commit_err)
			ok = false
		}
	} else {
		tx_rollback(tx)
	}
	store_set_sqlite_mirror(store, mirror)
	return ok
}

// sqlite_share_hashes_keep makes `hashes` the ones the connection matches. They
// may share pages with the ones it held, so they are copied before those go.
@(private)
sqlite_share_hashes_keep :: proc(conn: ^Embed_Conn, hashes: map[string]Share_Tree) {
	context.allocator = runtime.heap_allocator()
	kept := make(map[string]Share_Tree, max(len(hashes), 16))
	for name, tree in hashes {
		copied := tree
		copied.pages = slice.clone(tree.pages)
		copied.sums = slice.clone(tree.sums)
		kept[strings.clone(name)] = copied
	}
	sqlite_share_hashes_clear(conn)
	delete(conn.share_hashes)
	conn.share_hashes = kept
}

// sqlite_share_hashes_clear forgets the hashes: the next catch-up reads the
// whole file.
@(private)
sqlite_share_hashes_clear :: proc(conn: ^Embed_Conn) {
	context.allocator = runtime.heap_allocator()
	for name, tree in conn.share_hashes {
		delete(name)
		delete(tree.pages)
		delete(tree.sums)
	}
	clear(&conn.share_hashes)
}

// store_mirror_note_touched records what a commit to a shared file changed:
// the tables whose rows it wrote, sqlite_sequence for an AUTOINCREMENT table,
// and the schema for anything else (DDL, a view, a trigger, a header integer,
// a write the file did not take). The connection forgets those hashes after the
// commit, so the next catch-up reloads them instead of trusting a hash of the
// file from before this commit.
@(private)
store_mirror_note_touched :: proc(store: ^Store, ops: []Store_Op, mirror_failed: bool) {
	context.allocator = store.alloc
	note :: proc(store: ^Store, name: string) {
		append(&store.mirror_touched, strings.clone(name))
	}
	if mirror_failed do note(store, SHARE_HASH_SCHEMA)
	for op in ops {
		#partial switch op.kind {
		case .Insert, .Update, .Delete, .Truncate:
			if strings.has_prefix(op.name, "_") {
				note(store, SHARE_HASH_SCHEMA)
				continue
			}
			note(store, op.name)
			if table, found := store.tables[op.name]; found && table.schema.auto_increment_column >= 0 {
				note(store, SHARE_HASH_SEQUENCE)
			}
		case:
			note(store, SHARE_HASH_SCHEMA)
		}
	}
}

// sqlite_share_forget_touched drops the hashes of what the store's own commits
// changed, and empties the list.
@(private)
sqlite_share_forget_touched :: proc(conn: ^Embed_Conn) {
	store := conn.store
	for name in store.mirror_touched {
		if name in conn.share_hashes {
			key, tree := delete_key(&conn.share_hashes, name)
			delete(key, runtime.heap_allocator())
			delete(tree.pages, runtime.heap_allocator())
			delete(tree.sums, runtime.heap_allocator())
		}
		delete(name, store.alloc)
	}
	clear(&store.mirror_touched)
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
	// A statement a function runs in the middle of another on this
	// connection: the outer one holds the file (taking it again waited on
	// this very thread) and lets it go when it ends.
	if conn.share_depth > 0 do return embed_run_statement(conn, prepared, params)
	conn.share_depth += 1
	defer conn.share_depth -= 1
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
	if len(conn.store.mirror_touched) > 0 do sqlite_share_forget_touched(conn)
	if holds do sync.rw_mutex_unlock(&share.file)
	if conn.tx == nil do sqlite_share_release(conn)
	return result, err
}
