#+build windows

package engine

import "core:os"

import win "core:sys/windows"

// Windows side of Db_Lock: LockFileEx on a byte of the lock file, with
// LOCKFILE_FAIL_IMMEDIATELY so a second opener is refused instead of waiting.
// The handle is created without FILE_SHARE_DELETE but with read and write
// sharing, because the lock, not the share mode, is what enforces ownership.
//
// The file is opened through core:os so UTF-8 paths, creation semantics and
// attributes stay the same as every other file the engine touches; the handle
// is the first field of the file's implementation, which is what LockFileEx
// needs.

// File_Impl_Head mirrors the leading fields of core:os's Windows File_Impl:
// the public File, then the native handle.
@(private)
File_Impl_Head :: struct {
	file: os.File,
	handle: win.HANDLE,
}

lock_os_open :: proc(path: string) -> (uintptr, Error) {
	file, open_err := os.open(path, {.Read, .Write, .Create})
	if open_err != nil {
		return 0, errf(.Io, "cannot open the lock file %s: %v", path, open_err)
	}
	handle := (^File_Impl_Head)(file.impl).handle
	if handle == nil || handle == win.INVALID_HANDLE_VALUE {
		_ = os.close(file)
		return 0, errf(.Io, "cannot open the lock file %s", path)
	}
	return uintptr(handle), ERROR_NONE
}

// lock_os_overlapped splits a 64-bit byte offset the way OVERLAPPED wants it.
@(private)
lock_os_overlapped :: proc(offset: u64) -> win.OVERLAPPED {
	overlapped: win.OVERLAPPED
	overlapped.Offset = u32(offset & 0xFFFF_FFFF)
	overlapped.OffsetHigh = u32(offset >> 32)
	return overlapped
}

// The locked bytes sit past any content the lock file will hold. A Windows
// byte-range lock also applies to other handles of the same file, even in the
// same process, so locking byte zero would make the owner text unwritable.
lock_os_acquire :: proc(handle: uintptr, offset: u64, exclusive: bool) -> bool {
	overlapped := lock_os_overlapped(offset)
	flags := u32(win.LOCKFILE_FAIL_IMMEDIATELY)
	if exclusive do flags |= win.LOCKFILE_EXCLUSIVE_LOCK
	return win.LockFileEx(win.HANDLE(handle), flags, 0, 1, 0, &overlapped) != false
}

lock_os_release :: proc(handle: uintptr, offset: u64) {
	overlapped := lock_os_overlapped(offset)
	_ = win.UnlockFileEx(win.HANDLE(handle), 0, 1, 0, &overlapped)
}

lock_os_close :: proc(handle: uintptr) {
	_ = win.CloseHandle(win.HANDLE(handle))
}

// lock_os_acquire_range locks `length` bytes from `offset`, shared or exclusive,
// without waiting: SQLite's file locks are ranges (its SHARED range is 510
// bytes), and a lock some other handle holds fails at once.
lock_os_acquire_range :: proc(handle: uintptr, offset: u64, length: u32, exclusive: bool) -> bool {
	overlapped := lock_os_overlapped(offset)
	flags := u32(win.LOCKFILE_FAIL_IMMEDIATELY)
	if exclusive do flags |= win.LOCKFILE_EXCLUSIVE_LOCK
	return win.LockFileEx(win.HANDLE(handle), flags, 0, length, 0, &overlapped) != false
}

lock_os_release_range :: proc(handle: uintptr, offset: u64, length: u32) {
	overlapped := lock_os_overlapped(offset)
	_ = win.UnlockFileEx(win.HANDLE(handle), 0, length, 0, &overlapped)
}

// lock_os_read_at reads from `offset` through the locking handle, so reading
// the file never opens (and closes) another handle on it.
lock_os_read_at :: proc(handle: uintptr, offset: u64, buffer: []u8) -> int {
	total := 0
	for total < len(buffer) {
		overlapped := lock_os_overlapped(offset + u64(total))
		read: win.DWORD
		if !win.ReadFile(win.HANDLE(handle), raw_data(buffer[total:]), win.DWORD(len(buffer) - total), &read, &overlapped) do break
		if read == 0 do break
		total += int(read)
	}
	return total
}

lock_os_size :: proc(handle: uintptr) -> i64 {
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(win.HANDLE(handle), &size) do return -1
	return i64(size)
}
