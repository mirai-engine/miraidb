package engine

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// A database directory belongs to one process at a time. The owner takes an
// operating system lock on a file inside the directory, so a second process is
// refused instead of writing into a log it does not own, and the lock disappears
// with the process even when it is killed.
//
// The lock is advisory at the OS level, so the engine also keeps a process-wide
// registry of the paths it holds: on POSIX a second open of the same file from
// the same process would be granted by the kernel, and this is what turns it
// into the same refusal a second process receives.
//
// A virtual file system has no OS file and no second process; `store_open`
// skips the lock when one is configured.

// LOCK_FILE_NAME is the file inside the database directory that carries the
// lock and the name of the owner.
LOCK_FILE_NAME :: "lock"

// Two bytes, two questions. The writer byte is taken exclusively and only by a
// writer, so a second writer is refused no matter who is reading. The reader byte
// is taken shared by readers and writers alike: a reader can open beside a
// writer, and a writer can tell that readers are around by trying to take it
// exclusively for the moment it rewrites the log.
LOCK_WRITER_OFFSET :: u64(0xFFFF_FFFC)
LOCK_READER_OFFSET :: u64(0xFFFF_FFFD)

// Db_Lock_Role is what the opener intends to do with the directory. A reader can
// join a writer; a writer cannot join a writer.
Db_Lock_Role :: enum u8 {
	Reader,
	Writer,
}

// Db_Lock is the exclusive ownership of one database directory.
Db_Lock :: struct {
	// handle is the platform's file descriptor or handle. It is a uintptr so the
	// struct can be shared by the platform files without leaking their types.
	handle: uintptr,
	path:   string,
	// key is the absolute path, the identity of the lock in the registry.
	key:  string,
	role: Db_Lock_Role,
	// reader_held says the shared reader byte is held; compacting says it was
	// upgraded to exclusive for a log rewrite.
	reader_held: bool,
	compacting:  bool,
	held:        bool,
}

@(private)
lock_registry_mutex: sync.Mutex

@(private)
lock_registry_writers: map[string]bool

@(private)
lock_registry_readers: map[string]int

// The registry is only needed where the kernel would hand a second lock of the
// same file to the same process. POSIX fcntl locks are per process; Windows
// byte-range locks conflict between handles, so the OS already refuses there.
@(private)
lock_registry_needed :: proc() -> bool {
	return ODIN_OS != .Windows
}

// db_lock_acquire opens the directory in `role`. A writer is exclusive against
// other writers and joins the readers; a reader only joins the reader byte, so it
// can open while a writer works. It creates the lock file when it is missing and
// records the owner in it, so a refusal can name the process that has the
// database open.
db_lock_acquire :: proc(directory: string, role: Db_Lock_Role = .Writer) -> (Db_Lock, Error) {
	path, join_err := filepath.join({directory, LOCK_FILE_NAME}, context.temp_allocator)
	if join_err != nil {
		return {}, errf(.Io, "cannot build the lock path for %s: %v", directory, join_err)
	}
	key, key_err := filepath.abs(path, context.temp_allocator)
	if key_err != nil {
		return {}, errf(.Io, "cannot resolve %s: %v", path, key_err)
	}

	registry := lock_registry_needed()
	if registry {
		sync.lock(&lock_registry_mutex)
		defer if registry {
			sync.unlock(&lock_registry_mutex)
		}
		if lock_registry_writers == nil {
			lock_registry_writers = make(map[string]bool)
		}
		if lock_registry_readers == nil {
			lock_registry_readers = make(map[string]int)
		}
		// A writer is exclusive against another writer. A reader joins whoever is
		// there: that is the whole point of the role.
		if role == .Writer && key in lock_registry_writers {
			return {}, lock_refusal(directory, path)
		}
	}

	handle, open_err := lock_os_open(path)
	if open_err.kind != .None {
		return {}, open_err
	}
	if role == .Writer {
		if !lock_os_acquire(handle, LOCK_WRITER_OFFSET, true) {
			lock_os_close(handle)
			return {}, lock_refusal(directory, path)
		}
	}
	if !lock_os_acquire(handle, LOCK_READER_OFFSET, false) {
		if role == .Writer do lock_os_release(handle, LOCK_WRITER_OFFSET)
		lock_os_close(handle)
		return {}, errf(.Locked, "database %s is being rewritten", directory)
	}
	if role == .Writer {
		lock_write_owner(path)
		if registry {
			lock_registry_writers[key] = true
		}
	}
	if registry {
		lock_registry_readers[key] += 1
	}
	return Db_Lock {
		handle = handle,
		path = strings.clone(path, context.allocator),
		key = strings.clone(key, context.allocator),
		role = role,
		reader_held = true,
		held = true,
	}, ERROR_NONE
}

// db_lock_rewriting takes the reader byte exclusively for the duration of a log
// rewrite, so no reader is replaying the file being replaced. It returns false
// when a reader holds it, and leaves the lock as it found it.
db_lock_rewriting :: proc(lock: ^Db_Lock, wanted: bool) -> bool {
	if lock == nil || !lock.held || lock.role != .Writer do return false
	if wanted {
		if lock.compacting do return true
		if lock.reader_held {
			lock_os_release(lock.handle, LOCK_READER_OFFSET)
			lock.reader_held = false
		}
		if !lock_os_acquire(lock.handle, LOCK_READER_OFFSET, true) {
			// Put the shared hold back; if that fails too the writer simply keeps
			// being refused for rewrites, which is the safe side.
			lock.reader_held = lock_os_acquire(lock.handle, LOCK_READER_OFFSET, false)
			return false
		}
		lock.compacting = true
		return true
	}
	if !lock.compacting do return true
	lock_os_release(lock.handle, LOCK_READER_OFFSET)
	lock.compacting = false
	lock.reader_held = lock_os_acquire(lock.handle, LOCK_READER_OFFSET, false)
	return lock.reader_held
}

// db_lock_release gives the directory back. It is safe on a zero lock, so close
// paths do not need to branch.
db_lock_release :: proc(lock: ^Db_Lock) {
	if lock == nil || !lock.held do return
	if lock.compacting do lock_os_release(lock.handle, LOCK_READER_OFFSET)
	if lock.reader_held do lock_os_release(lock.handle, LOCK_READER_OFFSET)
	if lock.role == .Writer do lock_os_release(lock.handle, LOCK_WRITER_OFFSET)
	lock_os_close(lock.handle)
	if lock_registry_readers != nil {
		sync.lock(&lock_registry_mutex)
		if lock_registry_readers[lock.key] > 1 {
			lock_registry_readers[lock.key] -= 1
		} else {
			delete_key(&lock_registry_readers, lock.key)
		}
		if lock.role == .Writer && lock_registry_writers != nil {
			delete_key(&lock_registry_writers, lock.key)
		}
		sync.unlock(&lock_registry_mutex)
	}
	delete(lock.path)
	delete(lock.key)
	lock^ = {}
}

// lock_refusal builds the error a second opener sees. The owner text is written
// by `lock_write_owner`; a lock file whose content cannot be read still refuses.
@(private)
lock_refusal :: proc(directory, path: string) -> Error {
	owner := lock_read_owner(path)
	defer delete(owner)
	return errf(.Locked, "database %s is already open by %s", directory, owner)
}

@(private)
lock_write_owner :: proc(path: string) {
	text := fmt.aprintf(
		"pid %d since %d",
		os.get_pid(),
		time.time_to_unix(time.now()),
	)
	defer delete(text)
	_ = os.write_entire_file(path, text)
}

@(private)
lock_read_owner :: proc(path: string) -> string {
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil || len(data) == 0 do return strings.clone("another process")
	text := strings.trim_space(string(data))
	if len(text) == 0 do return strings.clone("another process")
	return strings.clone(text)
}
