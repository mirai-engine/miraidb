package engine

import "core:os"
import "core:fmt"
import "core:sync"
import "core:mem"
import "core:strings"
import "base:runtime"
import "core:thread"
import "core:time"

// Store_Options controls how a database is opened.
Store_Options :: struct {
	// persistent keeps the database in a commit log on disk. When false the
	// database is purely in memory and disappears on close.
	persistent: bool,
	// create makes the database directory and log when they are missing.
	create: bool,
	// durable gates the durability mode. When false the log never fsyncs
	// (Durability.None); when true it uses `durability`, which defaults to
	// Full (fsync every commit).
	durable:    bool,
	durability: Durability,
	// checksum defaults to CRC32C; Checksum.None disables record digests.
	checksum:   Checksum,
	// in_memory_log records commits in a buffer instead of a file. The tables are
	// already in memory, so the database is ephemeral either way; this mode is
	// for simulation and tests that want the commit path without a disk.
	in_memory_log: bool,
	// vfs replaces the file system the log talks to. The default is the OS.
	// in-memory Vfs keeps a persistent database in RAM, which is how a host
	// builds a scratch database without a disk.
	vfs: ^Vfs,
	// compact_after_bytes starts the background compactor: when the log grows
	// past this many bytes a worker rewrites it as one snapshot. Zero leaves it
	// off. It only applies to a persistent database on the OS file system.
	compact_after_bytes: u64,
	// paged_tables puts the rows of tables created from now on in page files
	// under <path>/tables instead of the in-memory row map. The page file is a
	// cache of the log: it is rebuilt from the log when it is opened, so a
	// crash never leaves it as the only copy. Existing tables stay in memory.
	paged_tables: bool,
	// read_only opens the directory as a reader: it takes the shared side of the
	// lock, so it can run beside a writer, and it refuses to write. A reader
	// replays the log into memory, so it never touches the writer's page files.
	read_only: bool,
	// page_frames is how many 4 KiB pages of each table file stay in the buffer
	// pool. Zero means the default.
	page_frames: int,
}

// STORE_DEFAULT_PAGE_FRAMES is the pool size when the caller does not set one.
STORE_DEFAULT_PAGE_FRAMES :: 256

// BACKGROUND_COMPACT_INTERVAL is how often the worker looks at the log size.
BACKGROUND_COMPACT_INTERVAL_MS :: 100

// Store is one database: a set of tables plus the commit sequence that orders
// every change. It is safe for one writer and many readers; the write lock is
// held for the whole duration of a write transaction.
Store :: struct {
	// host is the process that owns this store, when there is one. It lets a
	// statement reach the module registry (LOAD EXTENSION); a store used without a
	// host simply records the catalog row.
	host: ^Host,
	// lock is the ownership of the database directory, when it is on the OS file
	// system. A virtual file system and an in-memory log have no second process.
	lock: Db_Lock,
	mutex:         sync.RW_Mutex,
	tables:        map[string]^Table,
	commit_seq:    u64,
	// last_commit_us is the wall clock of the last applied commit, fixed when
	// the commit lands (not when the transaction started).
	last_commit_us: i64,
	// latency histograms: bucket i counts the commits and queries that took
	// between 2^(i-1) and 2^i microseconds (bucket 0 is under one microsecond).
	commit_latency: [LATENCY_BUCKETS]u64,
	query_latency:  [LATENCY_BUCKETS]u64,
	commit_count:   u64,
	query_count:    u64,
	next_table_id: u32,
	// last_changes and last_row_id answer changes() and last_insert_rowid():
	// the row count of the last mutation and the row id of the last insert.
	last_changes:  i64,
	last_row_id:   i64,
	total_changes: i64,
	path:          string,
	// alloc is the allocator the store was opened with. A worker thread (the
	// background compactor) has its own context, so it must allocate and free
	// with the same allocator the store's memory came from.
	alloc:         mem.Allocator,
	// read_cache is the most recent read snapshot, reused while commit_seq does
	// not change; retired keeps the older ones alive while a transaction reads
	// them, and cache_mutex serializes who publishes and who evicts.
	read_cache:    ^Frozen_Cache,
	retired:       [dynamic]^Frozen_Cache,
	cache_mutex:   sync.Mutex,
	variables:     map[string]Value,
	// cancelled asks the next row loop to stop. It is cooperative: a running
	// statement checks it between rows, so the caller still owns the outcome.
	cancelled:     bool,
	// grants_checked caches whether the permission catalog has any rows, so a
	// database that never granted anything skips the check entirely.
	grants_checked: bool,
	grants_active:  bool,
	// identity is the caller the policies see. A server would set it per
	// connection; the embedded API sets it per store.
	identity:      Identity,
	// max_rows_per_query caps how many rows one SELECT may produce; zero is
	// unlimited. Quotas are per store, so a host sets them per database.
	max_rows_per_query: u64,
	// max_work_per_call caps the work one statement may spend; zero is
	// unlimited. work_used accumulates what the store spent so far.
	max_work_per_call: u64,
	work_used:         u64,
	// rows_scanned is how many rows every scan visited since the last reset. It is
	// what proves a predicate narrows a scan instead of being checked per row.
	rows_scanned: u64,
	// stream_scans counts the queries answered by the page-streaming path: they
	// never collected the table, which is the claim the memory test rests on.
	stream_scans: u64,
	// apply_seq is the commit being applied; table versions are stamped with it.
	apply_seq:           u64,
	// attached holds the databases ATTACH opened, by name. They are read-only
	// and their catalog lives in `_attach`.
	attached:            map[string]^Store,
	// sqlite_mirror is the .sqlite file this database was opened from. After a
	// commit the pages the commit touched are written back to it, so the file
	// stays a SQLite database a client can open. The commit log is still the
	// truth; the mirror is a cache of it in another format.
	sqlite_mirror:       string,
	// mirror is that file's layout, read once and then patched page by page.
	mirror:              ^Sqlite_Mirror,
	// The cost of the mirror, in pages: what a commit had to write, and how many
	// commits fell back to re-encoding the whole file.
	mirror_pages_written: int,
	mirror_bytes_written: u64,
	mirror_full_writes:   int,
	// mirror_reason says why the last commit re-encoded the mirrored file.
	mirror_reason:        string,
	log:           Commit_Log,
	vfs:           ^Vfs,
	persistent:    bool,
	last_error:    Error,
	// compact_thread, compact_stop and compact_bytes drive the opt-in
	// background compactor. The worker holds the same write lock compaction
	// always takes, so a writer pauses instead of failing.
	compact_thread:     ^thread.Thread,
	compact_stop:       bool,
	compact_bytes:      u64,
	// compact_floor is the size right after the last rewrite. A snapshot of a
	// large database can be bigger than the threshold, so the worker waits for
	// the log to double before rewriting again instead of spinning.
	compact_floor:      u64,
	// compact_count counts successful background rewrites; a test can wait on it
	// instead of inferring from a file size.
	compact_count:      u64,
	// on_commit runs after a transaction is durable and visible, with a copy of
	// the applied ops (kind, name, row id and values are valid; schema and index
	// references are borrowed). Subscriptions use it to publish deltas.
	on_commit:     proc(ctx: rawptr, store: ^Store, ops: []Store_Op),
	on_commit_ctx: rawptr,
	// replay_records and replay_buffer_bytes are what the last replay walked and
	// the largest record it had to hold. They are diagnostics a test reads to
	// prove the log is not loaded whole.
	replay_records:      u64,
	replay_buffer_bytes: int,
	// stats holds what ANALYZE measured, keyed by table name, and stats_seq the
	// sequence it was measured at. It is a planner cache: see stats.odin.
	stats:     map[string]Table_Stats,
	stats_seq: u64,
	// replays_skipped counts opens that used the catalog and the page files
	// instead of replaying. One means the database opened without walking the log.
	replays_skipped:     u64,
	// read_only says the directory is open as a reader: the lock is shared, the
	// page files are not touched, and every write is refused.
	read_only:           bool,
	// paged_tables and page_frames are the options new tables inherit, and
	// has_paged says whether any table of this store is paged: a read then keeps
	// the store lock for the whole transaction instead of taking a snapshot.
	paged_tables: bool,
	page_frames:  int,
	has_paged:    bool,
}

// Store_Op is one atomic change inside a transaction. The same representation
// is serialized into the commit log and applied at replay time.
Store_Op_Kind :: enum u8 {
	Create_Table = 1,
	Insert       = 2,
	Update       = 3,
	Delete       = 4,
	Truncate     = 5,
	Drop_Table   = 6,
	Create_Index = 7,
	Drop_Index   = 8,
	Alter_Table  = 9,
}

Store_Op :: struct {
	kind:   Store_Op_Kind,
	name:   string,
	schema: Table_Schema,
	index:  Index_Schema,
	row_id: Row_Id,
	values: []Value,
}

store_open :: proc(path: string, options: Store_Options) -> (^Store, Error) {
	store := new(Store)
	store.alloc = context.allocator
	store.tables = make(map[string]^Table)
	store.attached = make(map[string]^Store)
	store.variables = make(map[string]Value)
	store.persistent = options.persistent
	store.vfs = options.vfs
	store.path = path
	store.paged_tables = options.paged_tables
	store.read_only = options.read_only
	if store.read_only {
		if options.create {
			free(store)
			return nil, errf(.Invalid_Argument, "a read-only open cannot create the database")
		}
		// The page files belong to the writer: a reader replays into memory.
		store.paged_tables = false
	}
	store.page_frames = options.page_frames
	if store.page_frames <= 0 do store.page_frames = STORE_DEFAULT_PAGE_FRAMES
	if options.in_memory_log {
		store.log = log_open_memory()
		return store, ERROR_NONE
	}
	if !options.persistent {
		return store, ERROR_NONE
	}
	if len(path) == 0 {
		free(store)
		return nil, errf(.Invalid_Argument, "a persistent database needs a path")
	}
	// A virtual file system has no directories: the log path names the file.
	if options.vfs == nil && !os.exists(path) {
		if !options.create {
			free(store)
			return nil, errf(.Io, "database %s does not exist", path)
		}
		if mkdir_err := os.make_directory_all(path); mkdir_err != nil {
			free(store)
			return nil, errf(.Io, "cannot create %s: %v", path, mkdir_err)
		}
	}
	// The directory is owned from here on. A second process that finds it held is
	// refused with the owner's pid instead of appending to a log it does not own.
	if options.vfs == nil {
		role := store.read_only ? Db_Lock_Role.Reader : Db_Lock_Role.Writer
		lock, lock_err := db_lock_acquire(path, role)
		if lock_err.kind != .None {
			free(store)
			return nil, lock_err
		}
		store.lock = lock
	}
	durability := options.durability
	if !options.durable do durability = .None
	checksum := options.checksum
	if checksum == .Default do checksum = .CRC32C
	log, log_err := log_open(path, options.create, durability, checksum, options.vfs)
	if log_err.kind != .None {
		db_lock_release(&store.lock)
		free(store)
		return nil, log_err
	}
	store.log = log
	// A paged database whose page files and catalog name the sequence the log
	// ends at needs no replay: the pages are the rows and the catalog is the
	// schema. Anything short of that falls back to discarding the pages and
	// rebuilding them from the log, which is what every open did before.
	trusted := false
	if store.paged_tables && store.vfs == nil && !store.read_only {
		trusted_ok, trusted_err := store_open_trusted(store)
		if trusted_err.kind != .None {
			log_close(&store.log)
			db_lock_release(&store.lock)
			free(store)
			return nil, trusted_err
		}
		trusted = trusted_ok
	}
	if !trusted {
		if discard_err := store_discard_pages(store); discard_err.kind != .None {
			log_close(&store.log)
			db_lock_release(&store.lock)
			free(store)
			return nil, discard_err
		}
		if snapshot_err := store_load_snapshot(store); snapshot_err.kind != .None {
			log_close(&store.log)
			db_lock_release(&store.lock)
			free(store)
			return nil, snapshot_err
		}
		if replay_err := store_replay(store); replay_err.kind != .None {
			log_close(&store.log)
			db_lock_release(&store.lock)
			free(store)
			return nil, replay_err
		}
	}
	// Statistics are a planner cache and load without a replay: the file carries
	// its own checksum, and a stale one only means plans read older numbers.
	stats_load(store)
	// Databases ATTACH recorded come back with the principal; a path that no
	// longer opens is reported, never fatal.
	if attach_err := store_attach_restore(store); attach_err.kind != .None {
		store.last_error = attach_err
	}
	if options.compact_after_bytes > 0 {
		// A database opened with the option always gets the worker; if the
		// thread cannot start, compaction stays available through the explicit
		// call and the failure is reported, not hidden.
		if !store_start_background_compaction(store, options.compact_after_bytes) {
			store.last_error = errf(.Internal, "cannot start the background compactor")
		}
	}
	return store, ERROR_NONE
}

store_log_path :: proc(directory: string) -> string {
	return strings.concatenate({directory, "/log"})
}

store_close :: proc(store: ^Store) {
	if store == nil do return
	store_stop_background_compaction(store)
	// A paged table is flushed before it is closed so a clean shutdown leaves the
	// page files current; a crash leaves them stale, which the next open rebuilds.
	if !store.read_only {
		if flush_err := store_flush_pages(store, store.commit_seq); flush_err.kind != .None {
			store.last_error = flush_err
		}
	}
	// Cached read snapshots own their cloned tables; release them before the
	// live tables so nothing is destroyed twice.
	frozen_cache_destroy(store.read_cache)
	for cache in store.retired do frozen_cache_destroy(cache)
	delete(store.retired)
	for _, table in store.tables {
		table_destroy(table)
	}
	delete(store.tables)
	for _, attached in store.attached do store_close(attached)
	delete(store.attached)
	mirror_destroy(store.mirror)
	delete(store.mirror_reason)
	delete(store.sqlite_mirror)
	for name, value in store.variables {
		delete(name)
		value_deep_free(value, context.allocator)
	}
	delete(store.variables)
	stats_destroy(store)
	log_close(&store.log)
	db_lock_release(&store.lock)
	free(store)
}

// store_set_sqlite_mirror makes every later commit write the state back to
// `path`, which must already hold this database. The caller owns `path`.
store_set_sqlite_mirror :: proc(store: ^Store, path: string) {
	if store == nil do return
	delete(store.sqlite_mirror)
	store.sqlite_mirror = strings.clone(path)
	// The layout is read now, while every row the file holds is still in the
	// store: a delete is the one operation that has no values to name its row
	// with, so it needs the map a commit would otherwise build too late.
	mirror_destroy(store.mirror)
	store.mirror = nil
	if built, build_err := mirror_build(store, store.sqlite_mirror); build_err.kind == .None {
		store.mirror = built
	}
}

// store_sqlite_mirror_flush brings the mirrored file up to date with a commit.
// It patches the pages the commit touched; a commit it cannot express that way
// (a schema change, a table it cannot address by rowid, a page that no longer
// fits) re-encodes the file instead. It takes the read lock, so the commit path
// calls it after releasing its own write lock; a failure is reported and never
// fails the commit, because the log is the truth.
store_sqlite_mirror_flush :: proc(store: ^Store, ops: []Store_Op = nil) -> Error {
	if store == nil || len(store.sqlite_mirror) == 0 do return ERROR_NONE
	sync.shared_lock(&store.mutex)
	defer sync.shared_unlock(&store.mutex)
	if store.mirror == nil {
		built, build_err := mirror_build(store, store.sqlite_mirror)
		if build_err.kind != .None {
			delete(store.mirror_reason)
			store.mirror_reason = strings.clone(build_err.message)
			return store_sqlite_mirror_rewrite(store)
		}
		store.mirror = built
	}
	before_pages := store.mirror.pages_written
	before_bytes := store.mirror.bytes_written
	needs_full, apply_err := mirror_apply_commit(store, store.mirror, ops)
	store.mirror_pages_written += store.mirror.pages_written - before_pages
	store.mirror_bytes_written += store.mirror.bytes_written - before_bytes
	if apply_err.kind != .None do return apply_err
	if needs_full {
		delete(store.mirror_reason)
		store.mirror_reason = strings.clone(store.mirror.fallback_reason)
		return store_sqlite_mirror_rewrite(store)
	}
	return ERROR_NONE
}

// store_mirror_crash_before_header arms the crash seam: the next mirror commit
// writes its data pages and stops, leaving the journal behind, which is what a
// process that dies mid-commit leaves on disk. Tests use it to prove the journal
// restores the previous state.
store_mirror_crash_before_header :: proc(store: ^Store) {
	if store == nil || store.mirror == nil do return
	store.mirror.crash_before_header = true
}

// store_sqlite_mirror_rewrite writes the whole state to the mirrored file and
// reads the layout back, which is how a commit the page patcher cannot express
// is handled.
store_sqlite_mirror_rewrite :: proc(store: ^Store) -> Error {
	if store == nil || len(store.sqlite_mirror) == 0 do return ERROR_NONE
	store.mirror_full_writes += 1
	mirror_destroy(store.mirror)
	store.mirror = nil
	_, _, write_err := sqlite_file_write(store, store.sqlite_mirror)
	if write_err.kind != .None do return write_err
	built, build_err := mirror_build(store, store.sqlite_mirror)
	if build_err.kind != .None do return build_err
	store.mirror = built
	store.mirror_bytes_written += u64(store.mirror.page_count * store.mirror.page_size)
	return ERROR_NONE
}

// store_log_bytes reports the bytes the log currently occupies, counting the
// full earlier segments. An in-memory log reports its buffer.
store_log_bytes :: proc(store: ^Store) -> u64 {
	if store == nil do return 0
	sync.shared_lock(&store.mutex)
	defer sync.shared_unlock(&store.mutex)
	if store.log.memory_mode do return u64(len(store.log.memory))
	if !store.persistent do return 0
	total := u64(max(store.log.size, 0))
	if store.log.segment > 0 do total += u64(store.log.segment) * u64(LOG_SEGMENT_MAX)
	return total
}

// store_background_compact_step compacts the log when it is past the threshold
// and reports whether it did. The worker runs it periodically; tests call it
// directly to keep timing out of the assertions.
store_background_compact_step :: proc(store: ^Store) -> bool {
	if store == nil || store.compact_bytes == 0 do return false
	if !store.persistent || store.vfs != nil || store.log.memory_mode do return false
	before := store_log_bytes(store)
	if before < store.compact_bytes do return false
	if store.compact_floor > 0 && before < store.compact_floor * 2 do return false
	if compact_err := store_compact(store); compact_err.kind != .None {
		store.last_error = compact_err
		return false
	}
	store.compact_floor = store_log_bytes(store)
	store.compact_count += 1
	return true
}

@(private)
store_compact_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	store := (^Store)(data)
	// The log, the tables and the paths were allocated with the store's
	// allocator; a thread's default context is not that allocator. A custom
	// allocator handed to a store with background compaction must therefore be
	// safe to use from another thread.
	context.allocator = store.alloc
	for {
		if sync.atomic_load(&store.compact_stop) do break
		time.sleep(BACKGROUND_COMPACT_INTERVAL_MS * time.Millisecond)
		if sync.atomic_load(&store.compact_stop) do break
		_ = store_background_compact_step(store)
	}
}

// store_start_background_compaction turns the worker on. It returns false when
// the database cannot compact (in memory, a virtual file system, or already
// running), so a caller can fall back to compacting explicitly.
store_start_background_compaction :: proc(store: ^Store, bytes: u64) -> bool {
	if store == nil || bytes == 0 do return false
	if !store.persistent || store.vfs != nil || store.log.memory_mode do return false
	if store.compact_thread != nil do return false
	store.compact_bytes = bytes
	sync.atomic_store(&store.compact_stop, false)
	started := thread.create_and_start_with_data(store, store_compact_worker, name = "miraidb-compact")
	if started == nil do return false
	store.compact_thread = started
	return true
}

// store_stop_background_compaction asks the worker to leave and waits for it, so
// nothing touches the log while it is being closed.
store_stop_background_compaction :: proc(store: ^Store) {
	if store == nil || store.compact_thread == nil do return
	sync.atomic_store(&store.compact_stop, true)
	thread.destroy(store.compact_thread)
	store.compact_thread = nil
}

// store_table returns a table by name. Callers must hold the store lock.
store_table :: proc(store: ^Store, name: string) -> (^Table, Error) {
	if table, ok := store.tables[name]; ok {
		return table, ERROR_NONE
	}
	return nil, errf(.Table_Not_Found, "table %s does not exist", name)
}

store_table_names :: proc(store: ^Store, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(store.tables), alloc)
	for name in store.tables {
		append(&names, name)
	}
	names_sorted := names[:]
	slice_sort_strings(names_sorted)
	return names_sorted
}

// --- Cancellation ----------------------------------------------------------

store_cancel :: proc(store: ^Store) {
	store.cancelled = true
}

store_clear_cancel :: proc(store: ^Store) {
	store.cancelled = false
}

store_cancelled :: proc(store: ^Store) -> bool {
	return store.cancelled
}

// --- Identity --------------------------------------------------------------

store_set_identity :: proc(store: ^Store, identity: Identity) {
	store.identity = identity
}

store_identity :: proc(store: ^Store) -> Identity {
	return store.identity
}

// --- Session variables -----------------------------------------------------

// store_set_variable records a value for the running process. Variables are not
// part of the log: they belong to the session, not to the database.
store_set_variable :: proc(store: ^Store, name: string, value: Value) -> Error {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store_set_variable_locked(store, name, value)
}

// store_set_variable_locked is store_set_variable for a caller that already
// holds the store lock. The lock is not re-entrant across platforms, so the
// statement layer uses these variants instead of nesting locks.
store_set_variable_locked :: proc(store: ^Store, name: string, value: Value) -> Error {
	if len(name) == 0 {
		return errf(.Invalid_Argument, "a variable needs a name")
	}
	key := strings.to_lower(name)
	if existing, found := store.variables[key]; found {
		value_deep_free(existing, context.allocator)
		delete(key)
		key = strings.to_lower(name)
	}
	store.variables[key] = value_clone(value, context.allocator)
	return ERROR_NONE
}

store_get_variable :: proc(store: ^Store, name: string) -> (Value, bool) {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store_get_variable_locked(store, name)
}

// store_get_variable_locked is store_get_variable for a locked caller.
store_get_variable_locked :: proc(store: ^Store, name: string) -> (Value, bool) {
	value, found := store.variables[strings.to_lower(name)]
	if !found do return {}, false
	return value_clone(value, context.allocator), true
}

store_variable_names :: proc(store: ^Store, alloc: mem.Allocator) -> []string {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store_variable_names_locked(store, alloc)
}

// store_variable_names_locked is store_variable_names for a locked caller.
store_variable_names_locked :: proc(store: ^Store, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(store.variables), alloc)
	for name in store.variables do append(&names, name)
	slice_sort_strings(names[:])
	return names[:]
}

// --- Replay ----------------------------------------------------------------

// Replay_Ctx carries the store and the first failure through the record visitor.
@(private)
Replay_Ctx :: struct {
	store: ^Store,
	err:   Error,
}

@(private)
replay_visit :: proc(ctx: rawptr, record: Log_Record) -> bool {
	replay := cast(^Replay_Ctx)ctx
	// A snapshot already covers everything at or below its base sequence.
	if record.seq <= replay.store.commit_seq do return true
	if err := store_apply_payload(replay.store, record.payload, record.seq); err.kind != .None {
		replay.err = errf(.Corrupt_Log, "commit %d cannot be replayed: %s", record.seq, err.message)
		return false
	}
	replay.store.commit_seq = record.seq
	return true
}

// store_replay applies the commits the snapshot does not cover. It walks the log
// record by record: the buffer holds the largest commit it meets, not the whole
// file, so opening a database with a long history costs the largest record
// instead of the history.
store_replay :: proc(store: ^Store) -> Error {
	stats: Log_Stream_Stats
	ctx := Replay_Ctx{store = store}
	valid_len, last_path, read_err := log_stream_segments(
		store.path,
		store.commit_seq,
		store.vfs,
		&ctx,
		replay_visit,
		&stats,
	)
	defer if len(last_path) > 0 do delete(last_path)
	if read_err.kind != .None do return read_err
	if ctx.err.kind != .None do return ctx.err
	store.replay_records = stats.records
	store.replay_buffer_bytes = stats.buffer_bytes
	// Drop a torn tail so the next append starts on a clean record boundary. A
	// reader never truncates: the log belongs to the writer.
	if len(last_path) > 0 && store.log.file != nil && !store.read_only {
		if log_file_size(store.log.file) != valid_len {
			if trunc_err := log_truncate(last_path, valid_len, store.vfs); trunc_err.kind != .None {
				return trunc_err
			}
			if _, seek_err := log_file_seek_end(store.log.file); seek_err.kind != .None {
				return errf(.Io, "cannot seek to the end of the log: %v", seek_err.message)
			}
		}
	}
	// The pages were rebuilt from the log, so they may now claim the sequence the
	// replay reached. Until this flush the header names a sequence no page
	// supports, which a later open would notice and rebuild.
	if !store.read_only {
		if flush_err := store_flush_pages(store, store.commit_seq); flush_err.kind != .None {
			return flush_err
		}
	}
	return ERROR_NONE
}

// --- Paged tables ----------------------------------------------------------

// store_paged_file_name turns a table name into a file name. Letters, digits and
// .-_ survive; every other byte becomes %XX, so a quoted identifier cannot name a
// path outside the directory.
store_paged_file_name :: proc(name: string, alloc: mem.Allocator = context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	for i in 0 ..< len(name) {
		c := name[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', '_':
			strings.write_byte(&builder, c)
		case:
			fmt.sbprintf(&builder, "%%%02x", c)
		}
	}
	return strings.to_string(builder)
}

store_table_page_path :: proc(store: ^Store, name: string) -> string {
	file := store_paged_file_name(name)
	defer delete(file)
	return fmt.aprintf("%s/tables/%s", store.path, file)
}

store_table_index_dir :: proc(store: ^Store, name: string) -> string {
	file := store_paged_file_name(name)
	defer delete(file)
	return fmt.aprintf("%s/indexes/%s", store.path, file)
}

store_remove_page_file :: proc(store: ^Store, name: string) {
	path := store_table_page_path(store, name)
	defer delete(path)
	system := log_vfs_or_os(store.vfs)
	_ = system.ops.remove(system, path)
}

// store_table_new creates the table object for a .Create_Table op. With paging
// on, a user table gets a page file; internal tables stay in memory because the
// engine scans them whole (the full-text shadow tables, the catalogs) and paging
// them would add I/O without removing a scan.
store_table_new :: proc(store: ^Store, schema_in: Table_Schema) -> (^Table, Error) {
	schema := schema_in
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	if !store.paged_tables do return table, ERROR_NONE
	if !store.persistent {
		table_destroy(table)
		return nil, errf(.Invalid_Argument, "paged tables need a persistent store")
	}
	if strings.has_prefix(table.schema.name, "_") do return table, ERROR_NONE
	path := store_table_page_path(store, table.schema.name)
	defer delete(path)
	rows, rows_err := page_rows_create(store.vfs, path, store.page_frames)
	if rows_err.kind != .None {
		table_destroy(table)
		return nil, rows_err
	}
	table.paged = rows
	store.has_paged = true
	// Each index gets its own page file next to the table's, and the keys stop
	// living in the table arena. A store without a directory (a memory VFS) still
	// gets files, they just share one flat name space.
	index_dir := store_table_index_dir(store, table.schema.name)
	table.index_dir = index_dir
	table.index_vfs = store.vfs
	table.index_frames = store.page_frames
	if store.vfs == nil {
		if mkdir_err := os.make_directory_all(index_dir); mkdir_err != nil {
			table_destroy(table)
			return nil, errf(.Io, "cannot create %s: %v", index_dir, mkdir_err)
		}
	}
	for _, i in table.indexes {
		if attach_err := table_index_attach_pages(table, i); attach_err.kind != .None {
			table_destroy(table)
			return nil, attach_err
		}
	}
	return table, ERROR_NONE
}

// store_discard_pages throws away the page and index files and recreates their
// directories. They are a cache over the log, so a file that does not match the
// log is dropped and rebuilt by the replay.
@(private)
store_discard_pages :: proc(store: ^Store) -> Error {
	if !store.paged_tables || store.vfs != nil do return ERROR_NONE
	dirs := [?]string{"/tables", "/indexes"}
	for suffix in dirs {
		dir := strings.concatenate({store.path, suffix})
		defer delete(dir)
		if remove_err := os.remove_all(dir); remove_err != nil && os.exists(dir) {
			return errf(.Io, "cannot clear %s: %v", dir, remove_err)
		}
		if mkdir_err := os.make_directory_all(dir); mkdir_err != nil {
			return errf(.Io, "cannot create %s: %v", dir, mkdir_err)
		}
	}
	return ERROR_NONE
}

// store_open_trusted opens a paged database from its page files. It reports true
// only when the catalog validates, its sequence is the one the log ends at, and
// every table and index file carries that same sequence; anything else reports
// false with no error and the caller replays.
//
// The log index is what makes the test cheap: it names the last record without
// reading the log, so comparing three numbers decides whether the pages are the
// whole state.
@(private)
store_open_trusted :: proc(store: ^Store) -> (ok: bool, err: Error) {
	log_path := store_log_path(store.path)
	defer delete(log_path)
	last, found := log_index_last(log_path)
	if !found || last == 0 do return false, ERROR_NONE
	seq, entries, valid := catalog_read(store)
	if !valid do return false, ERROR_NONE
	defer catalog_entries_destroy(entries)
	if seq != last do return false, ERROR_NONE
	opened := make([dynamic]^Table, 0, len(entries))
	defer {
		if !ok {
			for table in opened do table_destroy(table)
		}
		delete(opened)
	}
	for &entry in entries {
		table, open_err := store_table_open_paged(store, &entry, seq)
		if open_err.kind != .None {
			// A missing, stale or unreadable file is not an error: the log can
			// rebuild it.
			return false, ERROR_NONE
		}
		append(&opened, table)
	}
	for table in opened {
		store.tables[table.schema.name] = table
		store.next_table_id += 1
		store.has_paged = true
	}
	store.commit_seq = last
	store.apply_seq = last
	store.replays_skipped += 1
	return true, ERROR_NONE
}

// store_table_open_paged builds one table of a trusted open: the schema comes
// from the catalog, the rows and the index keys from the files the last commit
// flushed. Every file has to name `seq`, because that is the promise the catalog
// makes.
@(private)
store_table_open_paged :: proc(store: ^Store, entry: ^Catalog_Entry, seq: u64) -> (^Table, Error) {
	schema := entry.schema
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	if strings.has_prefix(table.schema.name, "_") {
		table_destroy(table)
		return nil, errf(.Corrupt_Log, "the catalog names the system table %s", entry.schema.name)
	}
	path := store_table_page_path(store, table.schema.name)
	defer delete(path)
	rows, rows_err := page_rows_open(store.vfs, path, store.page_frames)
	if rows_err.kind != .None {
		table_destroy(table)
		return nil, rows_err
	}
	if rows.file.applied_seq != seq {
		page_rows_close(rows)
		table_destroy(table)
		return nil, errf(.Io, "page file %s is at sequence %d, not %d", path, rows.file.applied_seq, seq)
	}
	table.paged = rows
	table.index_dir = store_table_index_dir(store, table.schema.name)
	table.index_vfs = store.vfs
	table.index_frames = store.page_frames
	for _, i in table.indexes {
		if attach_err := table_index_open_pages(table, i); attach_err.kind != .None {
			table_destroy(table)
			return nil, attach_err
		}
		if table.indexes[i].pages.file.applied_seq != seq {
			page_seq := table.indexes[i].pages.file.applied_seq
			table_destroy(table)
			return nil, errf(.Io, "index %s is at sequence %d, not %d", table.indexes[i].schema.name, page_seq, seq)
		}
	}
	table.next_row_id = entry.next_row_id
	table.next_sequence = entry.next_sequence
	table.next_int_key = entry.next_int_key
	table.apply_seq = seq
	return table, ERROR_NONE
}

// store_flush_pages writes every dirty page and its header at `seq`. The log is
// already durable when the commit path calls it, so a header that names a
// sequence never promises a change the log does not have.
store_flush_pages :: proc(store: ^Store, seq: u64) -> Error {
	if !store.has_paged do return ERROR_NONE
	for _, table in store.tables {
		if table.paged == nil do continue
		if flush_err := page_rows_flush(table.paged, seq); flush_err.kind != .None {
			return flush_err
		}
		for &index in table.indexes {
			if index.pages == nil do continue
			if flush_err := ordered_flush(index.pages, seq); flush_err.kind != .None {
				return flush_err
			}
		}
	}
	// The catalog names the sequence the pages now carry, so the next open can
	// read the schemas instead of replaying to find them. It is a cache: a failed
	// write costs a replay, never the commit.
	if catalog_err := catalog_write(store, seq); catalog_err.kind != .None {
		store.last_error = catalog_err
	}
	return ERROR_NONE
}

// store_apply_payload decodes and applies one commit record. It is used both by
// replay and by the commit path (the latter already holds the write lock).
store_apply_payload :: proc(store: ^Store, payload: []u8, seq: u64) -> Error {
	store.apply_seq = seq
	r: Byte_Reader
	br_init(&r, payload)
	count := int(br_read_u32(&r))
	if r.bad do return errf(.Corrupt_Log, "commit payload is truncated")
	for _ in 0 ..< count {
		op, op_err := store_op_decode(&r)
		if op_err.kind != .None do return op_err
		if apply_err := store_apply(store, op); apply_err.kind != .None {
			return apply_err
		}
	}
	if r.bad do return errf(.Corrupt_Log, "commit payload is truncated")
	return ERROR_NONE
}

store_apply :: proc(store: ^Store, op: Store_Op) -> Error {
	#partial switch op.kind {
	case .Insert, .Update, .Delete, .Truncate:
		if table, exists := store.tables[op.name]; exists do table.apply_seq = store.apply_seq
	}
	switch op.kind {
	case .Create_Table:
		if _, exists := store.tables[op.name]; exists {
			return errf(.Table_Exists, "table %s already exists", op.name)
		}
		schema := op.schema
		table, table_err := store_table_new(store, schema)
		if table_err.kind != .None do return table_err
		// The table arena owns its schema name; keying by it keeps the map entry
		// valid as long as the table exists.
		store.tables[table.schema.name] = table
		store.next_table_id += 1
		return ERROR_NONE
	case .Alter_Table:
		existing, exists := store.tables[op.name]
		if !exists do return errf(.Table_Not_Found, "table %s does not exist", op.name)
		if existing.paged != nil {
			return errf(.Sql_Unsupported, "alter a table that uses the page store")
		}
		schema := op.schema
		replacement, table_err := table_create(&schema)
		if table_err.kind != .None do return table_err
		for id, row in existing.rows {
			values := alter_row_values(&existing.schema, op.schema, row.values, context.allocator)
			defer delete(values)
			if insert_err := table_insert(replacement, id, values); insert_err.kind != .None {
				return insert_err
			}
		}
		replacement.next_row_id = existing.next_row_id
		replacement.next_sequence = existing.next_sequence
		map_erase(&store.tables, op.name)
		table_destroy(existing)
		store.tables[replacement.schema.name] = replacement
		return ERROR_NONE
	case .Drop_Table:
		if table, ok := store.tables[op.name]; ok {
			// Remove the map entry before destroying the table: the stored key
			// lives in the table's arena.
			map_erase(&store.tables, op.name)
			// The planner must not keep the shape of a table that is gone.
			stats_forget(store, op.name)
			paged := table.paged != nil
			if paged {
				system := log_vfs_or_os(store.vfs)
				for &index in table.indexes {
					if index.pages == nil do continue
					_ = system.ops.remove(system, index.pages.path)
				}
			}
			table_destroy(table)
			if paged do store_remove_page_file(store, op.name)
		}
		return ERROR_NONE
	case .Insert:
		table, table_err := store_table(store, op.name)
		if table_err.kind != .None do return table_err
		if insert_err := table_insert(table, op.row_id, op.values); insert_err.kind != .None {
			return insert_err
		}
		table.next_row_id = max(table.next_row_id, u64(op.row_id) + 1)
		return ERROR_NONE
	case .Update:
		table, table_err := store_table(store, op.name)
		if table_err.kind != .None do return table_err
		return table_update(table, op.row_id, op.values)
	case .Delete:
		table, table_err := store_table(store, op.name)
		if table_err.kind != .None do return table_err
		table_delete(table, op.row_id)
		return ERROR_NONE
	case .Truncate:
		table, table_err := store_table(store, op.name)
		if table_err.kind != .None do return table_err
		table_truncate(table)
		return ERROR_NONE
	case .Create_Index:
		table, table_err := store_table(store, op.name)
		if table_err.kind != .None do return table_err
		return table_add_index(table, op.index)
	case .Drop_Index:
		table, table_err := store_table(store, op.name)
		if table_err.kind != .None do return table_err
		return table_drop_index(table, op.index.name)
	}
	return errf(.Corrupt_Log, "unknown operation %d", u8(op.kind))
}

// --- Operation serialization ----------------------------------------------

store_op_encode :: proc(w: ^Byte_Writer, op: Store_Op) {
	bw_write_u8(w, u8(op.kind))
	bw_write_string(w, op.name)
	switch op.kind {
	case .Create_Table, .Alter_Table:
		schema := op.schema
		schema_encode(w, &schema)
	case .Create_Index:
		index := op.index
		index_encode(w, &index)
	case .Drop_Index:
		bw_write_string(w, op.index.name)
	case .Insert, .Update:
		bw_write_u64(w, u64(op.row_id))
		bw_write_u32(w, u32(len(op.values)))
		for value in op.values {
			value_encode(w, value)
		}
	case .Delete:
		bw_write_u64(w, u64(op.row_id))
	case .Truncate, .Drop_Table:
	}
}

store_op_decode :: proc(r: ^Byte_Reader) -> (Store_Op, Error) {
	op: Store_Op
	op.kind = Store_Op_Kind(br_read_u8(r))
	op.name = br_read_string(r, context.allocator)
	if r.bad do return op, errf(.Corrupt_Log, "truncated operation")
	#partial switch op.kind {
	case .Create_Table, .Alter_Table:
		op.schema = schema_decode(r, context.allocator)
	case .Create_Index:
		op.index = index_decode(r, context.allocator)
	case .Drop_Index:
		op.index.name = br_read_string(r, context.allocator)
	case .Insert, .Update:
		op.row_id = Row_Id(br_read_u64(r))
		count := int(br_read_u32(r))
		if r.bad || count < 0 || count > br_remaining(r) {
			return op, errf(.Corrupt_Log, "truncated row")
		}
		values := make([]Value, count)
		for i in 0 ..< count {
			values[i] = value_decode(r, context.allocator)
		}
		op.values = values
	case .Delete:
		op.row_id = Row_Id(br_read_u64(r))
	case .Truncate, .Drop_Table:
	case:
		return op, errf(.Corrupt_Log, "unknown operation %d", u8(op.kind))
	}
	if r.bad do return op, errf(.Corrupt_Log, "truncated operation")
	return op, ERROR_NONE
}

// store_vacuum_into writes a standalone compacted log at path: one snapshot
// record holds the whole state, so the copy replays in one step. It works for
// in-memory databases too, which is how they escape to a file.
store_vacuum_into :: proc(store: ^Store, path: string) -> Error {
	if len(path) == 0 do return errf(.Invalid_Argument, "VACUUM INTO needs a file path")
	if store.vfs != nil {
		return errf(.Sql_Unsupported, "VACUUM INTO needs the OS file system")
	}
	if os.exists(path) do return errf(.Io, "%s already exists", path)
	// A database is a directory holding the log, so the copy needs one too.
	if mkdir_err := os.make_directory_all(path); mkdir_err != nil {
		return errf(.Io, "cannot create %s: %v", path, mkdir_err)
	}
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	payload := store_state_payload(store)
	defer delete(payload)
	base := store.commit_seq == 0 ? u64(0) : store.commit_seq - 1
	log_path := strings.concatenate({path, "/log"})
	defer delete(log_path)
	return log_write_snapshot(log_path, base, store.commit_seq, payload)
}

// store_compact writes a snapshot and rewrites the log as one record holding the
// whole state. Startup becomes O(state) instead of O(history) and the file
// shrinks. The snapshot makes the checkpoint reusable for the next rounds.
store_compact :: proc(store: ^Store) -> Error {
	if store.read_only {
		return errf(.Transaction_Read_Only, "a read-only database cannot be compacted")
	}
	if store.log.memory_mode {
		return errf(.Invalid_Argument, "an in-memory log has nothing to compact")
	}
	if store.vfs != nil {
		return errf(.Sql_Unsupported, "a virtual file system has nothing to compact")
	}
	if !store.persistent {
		return errf(.Invalid_Argument, "an in-memory database has nothing to compact")
	}
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	payload := store_state_payload(store)
	defer delete(payload)
	// Compaction replaces the log file, so it needs the reader byte exclusively:
	// a reader replaying that file must not have it open while it is rewritten.
	if !db_lock_rewriting(&store.lock, true) {
		return errf(.Locked, "database %s has a reader open; compacting waits", store.path)
	}
	defer db_lock_rewriting(&store.lock, false)
	// Publish the snapshot before touching the log: if the log swap fails, the
	// old log still holds every record and replay ignores the extra snapshot.
	if snapshot_err := store_write_snapshot_payload(store, payload); snapshot_err.kind != .None {
		return snapshot_err
	}
	log_path := store_log_path(store.path)
	temp_path := strings.concatenate({store.path, "/log.tmp"})
	defer delete(temp_path)
	base := store.commit_seq == 0 ? u64(0) : store.commit_seq - 1
	durability := store.log.durability
	// The live handle must be closed before replacing the file: Windows cannot
	// rename over an open file.
	log_close(&store.log)
	// Every old segment and sidecar goes away: segment 0 is rewritten below.
	for index := 0; ; index += 1 {
		segment := log_segment_path(store.path, index)
		if !os.exists(segment) {
			delete(segment)
			break
		}
		os.remove(segment)
		index_path := log_index_path(segment)
		if os.exists(index_path) do os.remove(index_path)
		delete(segment)
		delete(index_path)
	}
	if write_err := log_write_snapshot(temp_path, base, store.commit_seq, payload); write_err.kind != .None {
		reopen_after_failure(store, durability)
		return write_err
	}
	if rename_err := os.rename(temp_path, log_path); rename_err != nil {
		reopen_after_failure(store, durability)
		return errf(.Io, "cannot replace the log with the snapshot: %v", rename_err)
	}
	// The rewrite invalidated every offset in the sidecar; log_open rebuilds it.
	index_path := strings.concatenate({log_path, ".index"})
	if os.exists(index_path) do os.remove(index_path)
	delete(index_path)
	reopened, open_err := log_open(store.path, false, durability, store.log.checksum)
	if open_err.kind != .None do return open_err
	store.log = reopened
	// The rewritten log starts with the same payload the snapshot file holds, so
	// the standalone copy is now redundant. Keeping it doubles the size of a
	// compacted database; a failed remove only leaves the old file behind and
	// startup still uses it.
	snapshot_path := store_snapshot_path(store.path)
	defer delete(snapshot_path)
	if os.exists(snapshot_path) do os.remove(snapshot_path)
	return ERROR_NONE
}

// store_memory sums the accounting of every table, including the internal
// `_` tables, for database-level reporting.
store_memory :: proc(store: ^Store) -> Table_Memory {
	sync.shared_lock(&store.mutex)
	defer sync.shared_unlock(&store.mutex)
	total: Table_Memory
	for _, table in store.tables {
		one := table_memory(table)
		total.rows += one.rows
		total.row_bytes += one.row_bytes
		total.index_entries += one.index_entries
		total.index_bytes += one.index_bytes
	}
	return total
}

// store_table_memory reports the storage one table uses, for diagnostics.
store_table_memory :: proc(store: ^Store, name: string) -> (Table_Memory, Error) {
	sync.shared_lock(&store.mutex)
	defer sync.shared_unlock(&store.mutex)
	table, table_err := store_table(store, name)
	if table_err.kind != .None do return {}, table_err
	return table_memory(table), ERROR_NONE
}

@(private)
reopen_after_failure :: proc(store: ^Store, durability: Durability) {
	reopened, open_err := log_open(store.path, false, durability, store.log.checksum)
	if open_err.kind == .None {
		store.log = reopened
	}
}

@(private)
slice_sort_strings :: proc(names: []string) {
	// Insertion sort keeps the dependency list short and is fine for the
	// handful of tables a database has.
	for i in 1 ..< len(names) {
		j := i
		for j > 0 && strings.compare(names[j - 1], names[j]) > 0 {
			names[j - 1], names[j] = names[j], names[j - 1]
			j -= 1
		}
	}
}

// store_set_row_quota caps the rows one SELECT may produce (zero disables it).
store_set_row_quota :: proc(store: ^Store, max_rows: u64) {
	sync.lock(&store.mutex)
	store.max_rows_per_query = max_rows
	sync.unlock(&store.mutex)
}

store_row_quota :: proc(store: ^Store) -> u64 {
	return store.max_rows_per_query
}

// store_set_work_budget caps the work one statement may spend (zero is
// unlimited). Energy counts rows plus returned bytes, so a caller pays roughly
// for the work a statement does rather than for wall-clock time.
store_set_work_budget :: proc(store: ^Store, units: u64) {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	store.max_work_per_call = units
}

store_work_budget :: proc(store: ^Store) -> u64 {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store.max_work_per_call
}

// store_work_used is the total work the store spent since it was opened or
// last reset, across every statement.
store_work_used :: proc(store: ^Store) -> u64 {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store.work_used
}

// store_prune_versions drops row history no reader needs anymore: callers pass
// the oldest read sequence still in use.
store_prune_versions :: proc(store: ^Store, before_seq: u64) {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	for _, table in store.tables {
		table_prune_versions(table, before_seq)
	}
}

// store_rows_scanned is how many rows scans visited since the last reset.
store_rows_scanned :: proc(store: ^Store) -> u64 {
	return sync.atomic_load(&store.rows_scanned)
}

// store_reset_rows_scanned starts a measurement from zero.
store_reset_rows_scanned :: proc(store: ^Store) {
	sync.atomic_store(&store.rows_scanned, 0)
}

store_reset_work :: proc(store: ^Store) {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	store.work_used = 0
}

// statement_work prices one result: a unit per row plus a unit per 64 bytes
// of payload, and one unit per affected row for mutations.
statement_work :: proc(result: ^Sql_Result) -> u64 {
	work := u64(len(result.rows)) + result.row_bytes / 64
	if result.affected > 0 do work += u64(result.affected)
	return work
}

// LATENCY_BUCKETS covers one microsecond to about a quarter of a second.
LATENCY_BUCKETS :: 20

// latency_bucket maps a duration to its histogram bucket: 0 is under one
// microsecond, i covers [2^(i-1), 2^i).
latency_bucket :: proc(microseconds: i64) -> int {
	if microseconds <= 1 do return 0
	bucket := 0
	bound: i64 = 1
	for bound < microseconds && bucket < LATENCY_BUCKETS - 1 {
		bound *= 2
		bucket += 1
	}
	return bucket
}

// store_record_commit_latency and store_record_query_latency feed the
// histograms. They are best effort: a writer already holds the store lock.
store_record_commit_latency :: proc(store: ^Store, microseconds: i64) {
	sync.atomic_add(&store.commit_count, 1)
	sync.atomic_add(&store.commit_latency[latency_bucket(microseconds)], 1)
}

store_record_query_latency :: proc(store: ^Store, microseconds: i64) {
	// A query releases the store lock before it reports, so the counters are
	// atomic: two readers may record at the same time.
	sync.atomic_add(&store.query_count, 1)
	sync.atomic_add(&store.query_latency[latency_bucket(microseconds)], 1)
}

// Latency_Stats is a copy of the latency histograms.
Latency_Stats :: struct {
	commits:       u64,
	queries:       u64,
	commit_bucket: [LATENCY_BUCKETS]u64,
	query_bucket:  [LATENCY_BUCKETS]u64,
}

// store_latency_stats reads the histogram counters under the store lock, so a
// caller never sees a bucket being incremented.
store_latency_stats :: proc(store: ^Store) -> Latency_Stats {
	sync.rw_mutex_shared_lock(&store.mutex)
	defer sync.rw_mutex_shared_unlock(&store.mutex)
	return Latency_Stats {
		commits = store.commit_count,
		queries = store.query_count,
		commit_bucket = store.commit_latency,
		query_bucket = store.query_latency,
	}
}

store_last_commit_us :: proc(store: ^Store) -> i64 {
	return store.last_commit_us
}

// store_commit_queue drains the queue in service order and commits that group.
// The queue owns what it was given, so every drained transaction is destroyed
// here, committed or not.
store_commit_queue :: proc(store: ^Store, queue: ^Commit_Queue, max_entries: int) -> (written: int, err: Error) {
	drained := commit_queue_drain(queue, max_entries)
	if len(drained) == 0 do return 0, ERROR_NONE
	written, err = store_commit_prepared(store, drained)
	for prepared in drained do prepared_destroy(prepared)
	delete(drained)
	return written, err
}

// store_commit_prepared appends and applies a group of prepared transactions,
// syncing the log once at the end. Records keep their own sequence numbers; the
// store is locked only for the duration of the group.
store_commit_prepared :: proc(store: ^Store, prepared: []^Prepared_Tx) -> (int, Error) {
	if len(prepared) == 0 do return 0, ERROR_NONE
	sync.lock(&store.mutex)
	seq := store.commit_seq
	log_before := store.log.size
	saved_durability := store.log.durability
	store.log.durability = .None
	written := 0
	for group in prepared {
		if group == nil do continue
		if len(group.payload) > 0 {
			seq += 1
			if log_err := log_append(&store.log, seq, group.payload); log_err.kind != .None {
				_ = log_rewind(&store.log, log_before)
				store.log.durability = saved_durability
				sync.unlock(&store.mutex)
				return written, log_err
			}
			written += 1
		}
		store.apply_seq = seq
		for op in group.ops {
			if apply_err := store_apply(store, op); apply_err.kind != .None {
				_ = log_rewind(&store.log, log_before)
				store.log.durability = saved_durability
				sync.unlock(&store.mutex)
				return written, apply_err
			}
		}
	}
	store.log.durability = saved_durability
	store.commit_seq = seq
	store.last_commit_us = now_microseconds()
	flush_err := log_flush(&store.log)
	if flush_err.kind == .None {
		// A page-flush failure is not a commit failure: the log holds the change
		// and the pages are a cache, so it is recorded and the commit stands.
		if page_err := store_flush_pages(store, seq); page_err.kind != .None {
			store.last_error = page_err
		}
	}
	notify := store.on_commit
	notify_ctx := store.on_commit_ctx
	sync.unlock(&store.mutex)
	if flush_err.kind != .None do return written, flush_err
	if notify != nil {
		for group in prepared {
			if group == nil do continue
			notify(notify_ctx, store, group.ops)
		}
	}
	return written, ERROR_NONE
}
