#+build !windows

package engine

import "core:strings"

// POSIX side of Db_Lock: an fcntl write lock over the whole file, released by
// the kernel when the descriptor or the process goes away.
//
// fcntl locks are owned by the process, not by the descriptor, so the registry
// in lock.odin is what makes a second open inside the same process fail.

lock_os_open :: proc(path: string) -> (uintptr, Error) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, posix.O_Flags{.RDWR, .CREAT}, posix.mode_t(0o644))
	if fd < 0 {
		return 0, errf(.Io, "cannot open the lock file %s", path)
	}
	return uintptr(fd), ERROR_NONE
}

lock_os_acquire :: proc(handle: uintptr) -> bool {
	request := posix.flock {
		l_type   = .WRLCK,
		l_whence = 0, // SEEK_SET
		l_start  = 0,
		l_len    = 0, // to the end of the file
	}
	return posix.fcntl(posix.FD(handle), .SETLK, &request) == 0
}

lock_os_release :: proc(handle: uintptr) {
	request := posix.flock {
		l_type   = .UNLCK,
		l_whence = 0,
		l_start  = 0,
		l_len    = 0,
	}
	_ = posix.fcntl(posix.FD(handle), .SETLK, &request)
}

lock_os_close :: proc(handle: uintptr) {
	_ = posix.close(posix.FD(handle))
}
