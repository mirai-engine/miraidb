package engine

// Virtual file system.
//
// The commit log talks to storage through `Vfs` instead of `core:os` so tests can
// keep a database in memory, a host can bound the bytes it writes, and a future
// page backend can reuse the same surface. Three implementations ship here: the
// OS, an in-memory one for tests and simulation, and a quota wrapper.

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

Vfs_Mode_Bit :: enum u8 {
	Read,
	Write,
	Create,
	Trunc,
}
Vfs_Mode :: bit_set[Vfs_Mode_Bit]

Vfs :: struct {
	ops:  ^Vfs_Ops,
	data: rawptr,
}

Vfs_File :: struct {
	ops:  ^Vfs_Ops,
	vfs:  ^Vfs,
	data: rawptr,
}

Vfs_Ops :: struct {
	open:     proc(vfs: ^Vfs, path: string, mode: Vfs_Mode) -> (^Vfs_File, Error),
	close:    proc(file: ^Vfs_File),
	read:     proc(file: ^Vfs_File, buffer: []u8) -> (int, Error),
	write:    proc(file: ^Vfs_File, data: []u8) -> (int, Error),
	seek:     proc(file: ^Vfs_File, offset: i64) -> (i64, Error),
	truncate: proc(file: ^Vfs_File, size: i64) -> Error,
	sync:     proc(file: ^Vfs_File) -> Error,
	size:     proc(file: ^Vfs_File) -> i64,
	remove:   proc(vfs: ^Vfs, path: string) -> Error,
}

// --- OS backend ------------------------------------------------------------

@(private)
Vfs_Os_File :: struct {
	handle: ^os.File,
}

@(private)
vfs_os_open :: proc(vfs: ^Vfs, path: string, mode: Vfs_Mode) -> (^Vfs_File, Error) {
	file_mode: os.File_Flags
	if .Read in mode do file_mode |= {.Read}
	if .Write in mode do file_mode |= {.Write}
	if .Create in mode do file_mode |= {.Create}
	if .Trunc in mode do file_mode |= {.Trunc}
	handle, open_err := os.open(path, file_mode)
	if open_err != nil do return nil, errf(.Io, "cannot open %s: %v", path, open_err)
	file := new(Vfs_File)
	file.ops = vfs.ops
	file.vfs = vfs
	file.data = new(Vfs_Os_File)
	(cast(^Vfs_Os_File)file.data).handle = handle
	return file, ERROR_NONE
}

@(private)
vfs_os_close :: proc(file: ^Vfs_File) {
	inner := cast(^Vfs_Os_File)file.data
	if inner != nil && inner.handle != nil do os.close(inner.handle)
	free(inner)
	free(file)
}

@(private)
vfs_os_read :: proc(file: ^Vfs_File, buffer: []u8) -> (int, Error) {
	inner := cast(^Vfs_Os_File)file.data
	read, read_err := os.read(inner.handle, buffer)
	if read_err != nil do return 0, errf(.Io, "read failed: %v", read_err)
	return read, ERROR_NONE
}

@(private)
vfs_os_write :: proc(file: ^Vfs_File, data: []u8) -> (int, Error) {
	inner := cast(^Vfs_Os_File)file.data
	written, write_err := os.write(inner.handle, data)
	if write_err != nil do return 0, errf(.Io, "write failed: %v", write_err)
	return written, ERROR_NONE
}

@(private)
vfs_os_seek :: proc(file: ^Vfs_File, offset: i64) -> (i64, Error) {
	inner := cast(^Vfs_Os_File)file.data
	position, seek_err := os.seek(inner.handle, offset, .Start)
	if seek_err != nil do return 0, errf(.Io, "seek failed: %v", seek_err)
	return position, ERROR_NONE
}

@(private)
vfs_os_truncate :: proc(file: ^Vfs_File, size: i64) -> Error {
	inner := cast(^Vfs_Os_File)file.data
	if err := os.truncate(inner.handle, size); err != nil {
		return errf(.Io, "truncate failed: %v", err)
	}
	return ERROR_NONE
}

@(private)
vfs_os_sync :: proc(file: ^Vfs_File) -> Error {
	inner := cast(^Vfs_Os_File)file.data
	if err := os.sync(inner.handle); err != nil do return errf(.Io, "sync failed: %v", err)
	return ERROR_NONE
}

@(private)
vfs_os_size :: proc(file: ^Vfs_File) -> i64 {
	inner := cast(^Vfs_Os_File)file.data
	size, size_err := os.file_size(inner.handle)
	if size_err != nil do return 0
	return size
}

@(private)
vfs_os_remove :: proc(vfs: ^Vfs, path: string) -> Error {
	if err := os.remove(path); err != nil do return errf(.Io, "cannot remove %s: %v", path, err)
	return ERROR_NONE
}

@(private)
vfs_os_ops := Vfs_Ops {
	open     = vfs_os_open,
	close    = vfs_os_close,
	read     = vfs_os_read,
	write    = vfs_os_write,
	seek     = vfs_os_seek,
	truncate = vfs_os_truncate,
	sync     = vfs_os_sync,
	size     = vfs_os_size,
	remove   = vfs_os_remove,
}

@(private)
vfs_os_singleton := Vfs {
	ops  = &vfs_os_ops,
	data = nil,
}

// vfs_os is the default file system: real files through core:os.
vfs_os :: proc() -> ^Vfs {
	return &vfs_os_singleton
}

// --- Memory backend --------------------------------------------------------

Memory_Vfs :: struct {
	files: map[string][]u8,
	mutex: sync.Mutex,
}

@(private)
Vfs_Memory_File :: struct {
	vfs:      ^Memory_Vfs,
	path:     string,
	position: int,
	writable: bool,
}

@(private)
vfs_memory_open :: proc(vfs: ^Vfs, path: string, mode: Vfs_Mode) -> (^Vfs_File, Error) {
	inner := cast(^Memory_Vfs)vfs.data
	sync.lock(&inner.mutex)
	defer sync.unlock(&inner.mutex)
	_, exists := inner.files[path]
	if .Create not_in mode && !exists {
		if .Read in mode || .Write in mode {
			return nil, errf(.Io, "no such file: %s", path)
		}
	}
	if .Create in mode && !exists do inner.files[path] = make([]u8, 0)
	if .Trunc in mode do inner.files[path] = make([]u8, 0)
	file := new(Vfs_File)
	file.ops = vfs.ops
	file.vfs = vfs
	file.data = new(Vfs_Memory_File)
	entry := cast(^Vfs_Memory_File)file.data
	entry.vfs = inner
	entry.path = strings.clone(path)
	entry.writable = .Write in mode
	return file, ERROR_NONE
}

@(private)
vfs_memory_close :: proc(file: ^Vfs_File) {
	entry := cast(^Vfs_Memory_File)file.data
	if entry != nil do delete(entry.path)
	free(entry)
	free(file)
}

@(private)
vfs_memory_read :: proc(file: ^Vfs_File, buffer: []u8) -> (int, Error) {
	entry := cast(^Vfs_Memory_File)file.data
	inner := entry.vfs
	sync.lock(&inner.mutex)
	defer sync.unlock(&inner.mutex)
	data := inner.files[entry.path]
	if entry.position >= len(data) do return 0, ERROR_NONE
	take := min(len(buffer), len(data) - entry.position)
	copy(buffer[:take], data[entry.position:entry.position + take])
	entry.position += take
	return take, ERROR_NONE
}

@(private)
vfs_memory_write :: proc(file: ^Vfs_File, data: []u8) -> (int, Error) {
	entry := cast(^Vfs_Memory_File)file.data
	if !entry.writable do return 0, errf(.Permission_Denied, "file is not open for writing")
	inner := entry.vfs
	sync.lock(&inner.mutex)
	defer sync.unlock(&inner.mutex)
	current := inner.files[entry.path]
	needed := entry.position + len(data)
	if needed > len(current) {
		grown := make([]u8, needed)
		copy(grown, current)
		delete(current)
		current = grown
	}
	copy(current[entry.position:entry.position + len(data)], data)
	inner.files[entry.path] = current
	entry.position = needed
	return len(data), ERROR_NONE
}

@(private)
vfs_memory_seek :: proc(file: ^Vfs_File, offset: i64) -> (i64, Error) {
	entry := cast(^Vfs_Memory_File)file.data
	if offset < 0 do return 0, errf(.Invalid_Argument, "negative offset")
	entry.position = int(offset)
	return offset, ERROR_NONE
}

@(private)
vfs_memory_truncate :: proc(file: ^Vfs_File, size: i64) -> Error {
	entry := cast(^Vfs_Memory_File)file.data
	inner := entry.vfs
	sync.lock(&inner.mutex)
	defer sync.unlock(&inner.mutex)
	current := inner.files[entry.path]
	if size < 0 do return errf(.Invalid_Argument, "negative size")
	if int(size) <= len(current) {
		inner.files[entry.path] = current[:int(size)]
	} else {
		grown := make([]u8, int(size))
		copy(grown, current)
		inner.files[entry.path] = grown
	}
	return ERROR_NONE
}

@(private)
vfs_memory_sync :: proc(file: ^Vfs_File) -> Error {
	return ERROR_NONE
}

@(private)
vfs_memory_size :: proc(file: ^Vfs_File) -> i64 {
	entry := cast(^Vfs_Memory_File)file.data
	inner := entry.vfs
	sync.lock(&inner.mutex)
	defer sync.unlock(&inner.mutex)
	return i64(len(inner.files[entry.path]))
}

@(private)
vfs_memory_remove :: proc(vfs: ^Vfs, path: string) -> Error {
	inner := cast(^Memory_Vfs)vfs.data
	sync.lock(&inner.mutex)
	defer sync.unlock(&inner.mutex)
	if data, exists := inner.files[path]; exists {
		delete(data)
		delete_key(&inner.files, path)
	}
	return ERROR_NONE
}

@(private)
vfs_memory_ops := Vfs_Ops {
	open     = vfs_memory_open,
	close    = vfs_memory_close,
	read     = vfs_memory_read,
	write    = vfs_memory_write,
	seek     = vfs_memory_seek,
	truncate = vfs_memory_truncate,
	sync     = vfs_memory_sync,
	size     = vfs_memory_size,
	remove   = vfs_memory_remove,
}

// vfs_memory_new builds an in-memory file system, useful for tests and
// deterministic simulations.
vfs_memory_new :: proc() -> ^Vfs {
	inner := new(Memory_Vfs)
	inner.files = make(map[string][]u8)
	vfs := new(Vfs)
	vfs.ops = &vfs_memory_ops
	vfs.data = inner
	return vfs
}

vfs_memory_destroy :: proc(vfs: ^Vfs) {
	if vfs == nil || vfs.data == nil do return
	inner := cast(^Memory_Vfs)vfs.data
	for _, data in inner.files do delete(data)
	delete(inner.files)
	free(inner)
	free(vfs)
}

// --- Quota wrapper ---------------------------------------------------------

Quota_Vfs :: struct {
	inner:    ^Vfs,
	limit:    u64,
	used:     u64,
	exceeded: bool,
}

@(private)
Vfs_Quota_File :: struct {
	vfs:  ^Quota_Vfs,
	file: ^Vfs_File,
}

@(private)
vfs_quota_open :: proc(vfs: ^Vfs, path: string, mode: Vfs_Mode) -> (^Vfs_File, Error) {
	inner := cast(^Quota_Vfs)vfs.data
	file, open_err := inner.inner.ops.open(inner.inner, path, mode)
	if open_err.kind != .None do return nil, open_err
	wrapper := new(Vfs_File)
	wrapper.ops = vfs.ops
	wrapper.vfs = vfs
	wrapper.data = new(Vfs_Quota_File)
	entry := cast(^Vfs_Quota_File)wrapper.data
	entry.vfs = inner
	entry.file = file
	return wrapper, ERROR_NONE
}

@(private)
vfs_quota_close :: proc(file: ^Vfs_File) {
	entry := cast(^Vfs_Quota_File)file.data
	if entry != nil && entry.file != nil do entry.file.ops.close(entry.file)
	free(entry)
	free(file)
}

@(private)
vfs_quota_read :: proc(file: ^Vfs_File, buffer: []u8) -> (int, Error) {
	entry := cast(^Vfs_Quota_File)file.data
	return entry.file.ops.read(entry.file, buffer)
}

@(private)
vfs_quota_write :: proc(file: ^Vfs_File, data: []u8) -> (int, Error) {
	entry := cast(^Vfs_Quota_File)file.data
	inner := entry.vfs
	if inner.limit > 0 && inner.used + u64(len(data)) > inner.limit {
		inner.exceeded = true
		return 0, errf(.Quota_Exceeded, "write of %d bytes exceeds the %d byte limit", len(data), inner.limit)
	}
	written, write_err := entry.file.ops.write(entry.file, data)
	if write_err.kind == .None do inner.used += u64(written)
	return written, write_err
}

@(private)
vfs_quota_seek :: proc(file: ^Vfs_File, offset: i64) -> (i64, Error) {
	entry := cast(^Vfs_Quota_File)file.data
	return entry.file.ops.seek(entry.file, offset)
}

@(private)
vfs_quota_truncate :: proc(file: ^Vfs_File, size: i64) -> Error {
	entry := cast(^Vfs_Quota_File)file.data
	return entry.file.ops.truncate(entry.file, size)
}

@(private)
vfs_quota_sync :: proc(file: ^Vfs_File) -> Error {
	entry := cast(^Vfs_Quota_File)file.data
	return entry.file.ops.sync(entry.file)
}

@(private)
vfs_quota_size :: proc(file: ^Vfs_File) -> i64 {
	entry := cast(^Vfs_Quota_File)file.data
	return entry.file.ops.size(entry.file)
}

@(private)
vfs_quota_remove :: proc(vfs: ^Vfs, path: string) -> Error {
	inner := cast(^Quota_Vfs)vfs.data
	return inner.inner.ops.remove(inner.inner, path)
}

@(private)
vfs_quota_ops := Vfs_Ops {
	open     = vfs_quota_open,
	close    = vfs_quota_close,
	read     = vfs_quota_read,
	write    = vfs_quota_write,
	seek     = vfs_quota_seek,
	truncate = vfs_quota_truncate,
	sync     = vfs_quota_sync,
	size     = vfs_quota_size,
	remove   = vfs_quota_remove,
}

// vfs_quota_new wraps another file system with a byte budget.
vfs_quota_new :: proc(inner: ^Vfs, limit: u64) -> ^Vfs {
	wrapper := new(Quota_Vfs)
	wrapper.inner = inner
	wrapper.limit = limit
	vfs := new(Vfs)
	vfs.ops = &vfs_quota_ops
	vfs.data = wrapper
	return vfs
}

vfs_quota_destroy :: proc(vfs: ^Vfs) {
	if vfs == nil || vfs.data == nil do return
	free(vfs.data)
	free(vfs)
}

// --- Convenience -----------------------------------------------------------

// vfs_write_all writes a whole payload, honouring short writes.
vfs_write_all :: proc(file: ^Vfs_File, data: []u8) -> Error {
	offset := 0
	for offset < len(data) {
		written, write_err := file.ops.write(file, data[offset:])
		if write_err.kind != .None do return write_err
		if written <= 0 do return errf(.Io, "short write")
		offset += written
	}
	return ERROR_NONE
}

// vfs_read_all reads up to `size` bytes starting at the current position.
vfs_read_all :: proc(file: ^Vfs_File, size: int, alloc := context.allocator) -> ([]u8, Error) {
	buffer := make([]u8, size, alloc)
	read_total := 0
	for read_total < size {
		read, read_err := file.ops.read(file, buffer[read_total:])
		if read_err.kind != .None {
			delete(buffer, alloc)
			return nil, read_err
		}
		if read == 0 do break
		read_total += read
	}
	return buffer[:read_total], ERROR_NONE
}

_ :: mem
