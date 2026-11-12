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

// The locked byte sits far past any content the lock file will hold. A Windows
// byte-range lock also applies to other handles of the same file, even in the
// same process, so locking byte zero would make the owner text unwritable.
LOCK_BYTE_OFFSET :: u32(0xFFFF_FFFE)

lock_os_acquire :: proc(handle: uintptr) -> bool {
	overlapped: win.OVERLAPPED
	overlapped.Offset = LOCK_BYTE_OFFSET
	overlapped.OffsetHigh = LOCK_BYTE_OFFSET
	flags := win.LOCKFILE_EXCLUSIVE_LOCK | win.LOCKFILE_FAIL_IMMEDIATELY
	return win.LockFileEx(win.HANDLE(handle), flags, 0, 1, 0, &overlapped) != false
}

lock_os_release :: proc(handle: uintptr) {
	overlapped: win.OVERLAPPED
	overlapped.Offset = LOCK_BYTE_OFFSET
	overlapped.OffsetHigh = LOCK_BYTE_OFFSET
	_ = win.UnlockFileEx(win.HANDLE(handle), 0, 1, 0, &overlapped)
}

lock_os_close :: proc(handle: uintptr) {
	_ = win.CloseHandle(win.HANDLE(handle))
}
