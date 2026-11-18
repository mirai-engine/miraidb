#+build !windows

package engine

import "core:strings"
import "core:sys/posix"

// POSIX side of Db_Lock: an fcntl write lock over the whole file, released by
// the kernel when the descriptor or the process goes away.
//
// fcntl locks are owned by the process, not by the descriptor, so the registry
// in lock.odin is what makes a second open inside the same process fail.

lock_os_open :: proc(path: string) -> (uintptr, Error) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	// 0644: readable by everyone, writable by the owner. mode_t is a bit_set, so
	// the permissions are named rather than written as an octal number.
	fd := posix.open(
		cpath,
		posix.O_Flags{.RDWR, .CREAT},
		posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH},
	)
	if fd < 0 {
		return 0, errf(.Io, "cannot open the lock file %s", path)
	}
	return uintptr(fd), ERROR_NONE
}

// One byte per role, so a reader (shared on the reader byte) can join a writer
// (shared on it too, exclusive on the writer byte) instead of colliding with it.
lock_os_acquire :: proc(handle: uintptr, offset: u64, exclusive: bool) -> bool {
	request := posix.flock {
		l_type   = exclusive ? .WRLCK : .RDLCK,
		l_whence = 0, // SEEK_SET
		l_start  = posix.off_t(offset),
		l_len    = 1,
	}
	return posix.fcntl(posix.FD(handle), .SETLK, &request) == 0
}

lock_os_release :: proc(handle: uintptr, offset: u64) {
	request := posix.flock {
		l_type   = .UNLCK,
		l_whence = 0,
		l_start  = posix.off_t(offset),
		l_len    = 1,
	}
	_ = posix.fcntl(posix.FD(handle), .SETLK, &request)
}

lock_os_close :: proc(handle: uintptr) {
	_ = posix.close(posix.FD(handle))
}

// lock_os_acquire_range locks `length` bytes from `offset`, shared or exclusive,
// without waiting: SQLite's file locks are ranges (its SHARED range is 510
// bytes), and a lock another process holds fails at once.
lock_os_acquire_range :: proc(handle: uintptr, offset: u64, length: u32, exclusive: bool) -> bool {
	request := posix.flock {
		l_type   = exclusive ? .WRLCK : .RDLCK,
		l_whence = 0,
		l_start  = posix.off_t(offset),
		l_len    = posix.off_t(length),
	}
	return posix.fcntl(posix.FD(handle), .SETLK, &request) == 0
}

lock_os_release_range :: proc(handle: uintptr, offset: u64, length: u32) {
	request := posix.flock {
		l_type   = .UNLCK,
		l_whence = 0,
		l_start  = posix.off_t(offset),
		l_len    = posix.off_t(length),
	}
	_ = posix.fcntl(posix.FD(handle), .SETLK, &request)
}

// lock_os_read_at reads from `offset` through the locking descriptor: closing
// any other descriptor of the file would drop every lock this process holds
// on it, which is how fcntl locks work.
lock_os_read_at :: proc(handle: uintptr, offset: u64, buffer: []u8) -> int {
	total := 0
	for total < len(buffer) {
		remaining := len(buffer) - total
		got := posix.pread(posix.FD(handle), raw_data(buffer[total:]), uint(remaining), posix.off_t(offset + u64(total)))
		if got <= 0 do break
		total += int(got)
	}
	return total
}

lock_os_size :: proc(handle: uintptr) -> i64 {
	info: posix.stat_t
	if posix.fstat(posix.FD(handle), &info) != .OK do return -1
	return i64(info.st_size)
}
