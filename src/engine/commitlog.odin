package engine

import "core:os"
import "core:fmt"
import "core:strings"

// The commit log is the durability layer: every committed transaction is one
// record, appended before the in-memory state is updated. Replaying the records
// in order rebuilds the state exactly.
//
// File layout:
//
//	header   24 bytes: "MIRADB01" + u32 version + u32 reserved + u64 base_seq
//	record   16 + N : u32 payload_len | u32 payload_crc32c | u64 commit_seq | payload
//
// base_seq is the sequence of the last transaction folded into a compacted
// snapshot. Replay starts at base_seq + 1, so subsequent commits keep their
// original numbers after a compaction.
//
// A torn or corrupt record ends the replay at the previous record; the file is
// then truncated so the next append starts on a clean record boundary.

LOG_MAGIC :: "MIRADB01"
LOG_VERSION :: u32(16)
LOG_HEADER_LEN :: 24
LOG_RECORD_HEADER_LEN :: 16

// LOG_STREAM_INITIAL is the buffer a streaming replay starts with. It grows to the
// largest record it meets, so the cost is one record, not one log.
LOG_STREAM_INITIAL :: 64 * 1024

// Durability selects when the log waits for stable storage.
// Checksum selects the record integrity check stored in the log header.
Checksum :: enum u32 {
	Default = 0, // store option only: use CRC32C
	None    = 1, // no per-record digest: faster, detects nothing
	CRC32C  = 2, // every record carries a CRC32C of its payload
}

Durability :: enum u8 {
	Full,    // fsync every commit
	Batched, // fsync every LOG_SYNC_BATCH commits and on close
	None,    // never fsync; the OS decides when to flush
}

LOG_SYNC_BATCH :: 64

// Segments cap the size of one file. Rotation appends, never splits a record:
// the new segment's header records the last commit before it.
LOG_SEGMENT_MAX :: i64(256 << 10)

// The offset index is a sidecar: <log>.index holds one (seq, offset) pair per
// record, so replay can seek straight to the first record after a snapshot
// instead of parsing the history. It is derived data: a missing, stale or
// truncated index only costs a scan, never correctness.
LOG_INDEX_MAGIC :: "MIRADX01"
LOG_INDEX_HEADER_LEN :: 16
LOG_INDEX_ENTRY_LEN :: 16

Log_Index_Entry :: struct {
	seq:    u64,
	offset: i64,
}

// Log_File is the handle the log reads and writes with. Every operation goes
// through a Vfs, so the same code serves real files, an in-memory file system
// and a quota wrapper. A nil Vfs means the OS backend.
Log_File :: struct {
	vfs:  ^Vfs,
	file: ^Vfs_File,
}

@(private)
log_vfs_or_os :: proc(vfs: ^Vfs) -> ^Vfs {
	if vfs == nil do return vfs_os()
	return vfs
}

log_file_exists :: proc(vfs: ^Vfs, path: string) -> bool {
	if vfs == nil do return os.exists(path)
	file, open_err := vfs.ops.open(vfs, path, {.Read})
	if open_err.kind != .None do return false
	vfs.ops.close(file)
	return true
}

log_file_open :: proc(vfs: ^Vfs, path: string, mode: Vfs_Mode) -> (^Log_File, Error) {
	system := log_vfs_or_os(vfs)
	inner, open_err := system.ops.open(system, path, mode)
	if open_err.kind != .None do return nil, open_err
	handle := new(Log_File)
	handle.vfs = system
	handle.file = inner
	return handle, ERROR_NONE
}

log_file_close :: proc(handle: ^Log_File) {
	if handle == nil do return
	if handle.file != nil do handle.vfs.ops.close(handle.file)
	free(handle)
}

// log_file_write appends the whole payload or reports a failure. A write that
// lands only part of the bytes is a failure, not a success: the caller must not
// record a commit whose record is incomplete.
log_file_write :: proc(handle: ^Log_File, data: []u8) -> (int, Error) {
	written, write_err := handle.vfs.ops.write(handle.file, data)
	if write_err.kind != .None do return written, write_err
	if written != len(data) {
		return written, errf(.Io, "short write: %d of %d bytes", written, len(data))
	}
	return written, ERROR_NONE
}

log_file_read :: proc(handle: ^Log_File, buffer: []u8) -> (int, Error) {
	return handle.vfs.ops.read(handle.file, buffer)
}

log_file_seek :: proc(handle: ^Log_File, offset: i64) -> (i64, Error) {
	return handle.vfs.ops.seek(handle.file, offset)
}

log_file_seek_end :: proc(handle: ^Log_File) -> (i64, Error) {
	return log_file_seek(handle, handle.vfs.ops.size(handle.file))
}

log_file_size :: proc(handle: ^Log_File) -> i64 {
	return handle.vfs.ops.size(handle.file)
}

log_file_sync :: proc(handle: ^Log_File) -> Error {
	return handle.vfs.ops.sync(handle.file)
}

log_file_truncate :: proc(handle: ^Log_File, size: i64) -> Error {
	return handle.vfs.ops.truncate(handle.file, size)
}

log_file_remove :: proc(vfs: ^Vfs, path: string) -> Error {
	if vfs != nil do return vfs.ops.remove(vfs, path)
	if err := os.remove(path); err != nil do return errf(.Io, "cannot remove %s: %v", path, err)
	return ERROR_NONE
}

// log_file_read_all loads a whole file through the VFS.
log_file_read_all :: proc(vfs: ^Vfs, path: string) -> ([]u8, Error) {
	if vfs == nil {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil do return nil, errf(.Io, "cannot read %s: %v", path, read_err)
		return data, ERROR_NONE
	}
	handle, open_err := log_file_open(vfs, path, {.Read})
	if open_err.kind != .None do return nil, open_err
	defer log_file_close(handle)
	size := log_file_size(handle)
	if size <= 0 do return make([]u8, 0), ERROR_NONE
	data := make([]u8, int(size))
	total := 0
	for total < len(data) {
		read, read_err := log_file_read(handle, data[total:])
		if read_err.kind != .None {
			delete(data)
			return nil, read_err
		}
		if read == 0 do break
		total += read
	}
	return data[:total], ERROR_NONE
}

Commit_Log :: struct {
	file:       ^Log_File,
	vfs:        ^Vfs,
	path:       string,
	durability: Durability,
	checksum:   Checksum,
	size:       i64,
	base_seq:   u64,
	pending:    int, // commits since the last sync in Batched mode
	// memory_mode keeps the log in a buffer instead of a file: commits are still
	// recorded (for simulation and tests) but nothing is durable.
	memory_mode: bool,
	memory:      [dynamic]u8,
	// segment is the index of the live file and directory the database folder.
	segment:   int,
	directory: string,
}

// log_segment_path names segment 0 `<db>/log` (so databases from before
// segments keep working); later segments are `<db>/log.<n>`.
log_segment_path :: proc(db_path: string, index: int) -> string {
	if index == 0 do return strings.concatenate({db_path, "/log"})
	return fmt.aprintf("%s/log.%d", db_path, index)
}

@(private)
log_last_segment_index :: proc(db_path: string, vfs: ^Vfs = nil) -> int {
	index := 0
	for {
		path := log_segment_path(db_path, index + 1)
		exists := log_file_exists(vfs, path)
		delete(path)
		if !exists do break
		index += 1
	}
	return index
}

@(private)
log_segment_base :: proc(path: string, vfs: ^Vfs = nil) -> u64 {
	file, open_err := log_file_open(vfs, path, {.Read})
	if open_err.kind != .None do return 0
	defer log_file_close(file)
	header: [LOG_HEADER_LEN]u8
	n, read_err := log_file_read(file, header[:])
	if read_err.kind != .None || n != LOG_HEADER_LEN do return 0
	if string(header[:8]) != LOG_MAGIC do return 0
	return get_u64_le(header[16:24])
}

log_open :: proc(
	db_path: string,
	create: bool,
	durability: Durability,
	checksum: Checksum,
	vfs: ^Vfs = nil,
) -> (Commit_Log, Error) {
	log := Commit_Log{durability = durability, directory = db_path, checksum = checksum, vfs = vfs}
	index := log_last_segment_index(db_path, vfs)
	path := log_segment_path(db_path, index)
	log.path = path
	log.segment = index
	exists := log_file_exists(vfs, path)
	if !exists {
		if !create {
			return log, errf(.Io, "log %s does not exist", path)
		}
		file, open_err := log_file_open(vfs, path, {.Read, .Write, .Create, .Trunc})
		if open_err.kind != .None {
			return log, errf(.Io, "cannot create %s: %v", path, open_err.message)
		}
		header: [LOG_HEADER_LEN]u8
		copy(header[:8], LOG_MAGIC)
		put_u32_le(header[8:12], LOG_VERSION)
		put_u32_le(header[12:16], u32(checksum))
		put_u64_le(header[16:24], 0)
		if _, write_err := log_file_write(file, header[:]); write_err.kind != .None {
			log_file_close(file)
			return log, errf(.Io, "cannot write the log header: %v", write_err.message)
		}
		if durability == .Full {
			if sync_err := log_file_sync(file); sync_err.kind != .None {
				log_file_close(file)
				return log, errf(.Io, "cannot sync the log header: %v", sync_err.message)
			}
		}
		log.file = file
		log.size = i64(LOG_HEADER_LEN)
		return log, ERROR_NONE
	}

	file, open_err := log_file_open(vfs, path, {.Read, .Write})
	if open_err.kind != .None {
		return log, errf(.Io, "cannot open %s: %v", path, open_err.message)
	}
	header: [LOG_HEADER_LEN]u8
	n, read_err := log_file_read(file, header[:])
	if read_err.kind != .None || n != LOG_HEADER_LEN {
		log_file_close(file)
		return log, errf(.Corrupt_Log, "%s is shorter than a log header", path)
	}
	if string(header[:8]) != LOG_MAGIC {
		log_file_close(file)
		return log, errf(.Corrupt_Log, "%s is not a miraidb log (bad magic)", path)
	}
	version := get_u32_le(header[8:12])
	if version > LOG_VERSION {
		log_file_close(file)
		return log, errf(.Format_Too_New, "%s uses log format %d, this build reads %d", path, version, LOG_VERSION)
	}
	if version < LOG_VERSION {
		log_file_close(file)
		return log, errf(.Corrupt_Log, "%s uses log format %d, this build reads %d", path, version, LOG_VERSION)
	}
	checksum_id := get_u32_le(header[12:16])
	if checksum_id != u32(Checksum.None) && checksum_id != u32(Checksum.CRC32C) {
		log_file_close(file)
		return log, errf(.Corrupt_Log, "%s uses an unknown checksum id %d", path, checksum_id)
	}
	log.checksum = Checksum(checksum_id)
	log.base_seq = get_u64_le(header[16:24])
	// Continue appending at the end.
	end, seek_err := log_file_seek_end(file)
	if seek_err.kind != .None {
		log_file_close(file)
		return log, errf(.Io, "cannot seek to the end of %s: %v", path, seek_err.message)
	}
	log.file = file
	log.size = end
	// The offset index is an OS-only cache: a virtual file system has no place
	// for a sidecar and does not need one.
	if vfs == nil do log_index_ensure(path)
	return log, ERROR_NONE
}

// log_rotate closes the live segment and opens the next one. The caller is about
// to append the record for `next_seq`, so the new header's base is one less.
@(private)
log_rotate :: proc(log: ^Commit_Log, next_seq: u64) -> Error {
	if log.file != nil {
		if log.durability == .Full {
			_ = log_file_sync(log.file)
		}
		log_file_close(log.file)
		log.file = nil
	}
	new_index := log.segment + 1
	new_path := log_segment_path(log.directory, new_index)
	file, open_err := log_file_open(log.vfs, new_path, {.Read, .Write, .Create, .Trunc})
	if open_err.kind != .None {
		return errf(.Io, "cannot create %s: %v", new_path, open_err.message)
	}
	header: [LOG_HEADER_LEN]u8
	copy(header[:8], LOG_MAGIC)
	put_u32_le(header[8:12], LOG_VERSION)
	put_u32_le(header[12:16], u32(log.checksum))
	put_u64_le(header[16:24], next_seq - 1)
	if _, write_err := log_file_write(file, header[:]); write_err.kind != .None {
		log_file_close(file)
		return errf(.Io, "cannot write the segment header: %v", write_err.message)
	}
	if log.durability != .None {
		if sync_err := log_file_sync(file); sync_err.kind != .None {
			log_file_close(file)
			return errf(.Io, "cannot sync the segment header: %v", sync_err.message)
		}
	}
	log.file = file
	log.path = new_path
	log.segment = new_index
	log.size = LOG_HEADER_LEN
	log.base_seq = next_seq - 1
	if log.vfs == nil do log_index_ensure(new_path)
	return ERROR_NONE
}

// log_open_memory starts an empty log backed by a buffer instead of a file.
log_open_memory :: proc() -> Commit_Log {
	log := Commit_Log{durability = .None, memory_mode = true, checksum = .CRC32C}
	header: [LOG_HEADER_LEN]u8
	copy(header[:8], LOG_MAGIC)
	put_u32_le(header[8:12], LOG_VERSION)
	put_u32_le(header[12:16], u32(Checksum.CRC32C))
	put_u64_le(header[16:24], 0)
	for byte in header do append(&log.memory, byte)
	log.size = LOG_HEADER_LEN
	return log
}

log_close :: proc(log: ^Commit_Log) {
	if log.memory_mode {
		delete(log.memory)
		log.memory_mode = false
		return
	}
	if log.file != nil {
		if log.durability != .None {
			log_file_sync(log.file)
		}
		log_file_close(log.file)
		log.file = nil
	}
}

// log_append writes one transaction record and, when durable, waits for it to
// reach stable storage before returning.
log_append :: proc(log: ^Commit_Log, commit_seq: u64, payload: []u8) -> Error {
	record := make([]u8, LOG_RECORD_HEADER_LEN + len(payload))
	defer delete(record)
	put_u32_le(record[0:4], u32(len(payload)))
	put_u32_le(record[4:8], log.checksum == .None ? 0 : crc32c(payload))
	put_u64_le(record[8:16], commit_seq)
	copy(record[LOG_RECORD_HEADER_LEN:], payload)
	if log.memory_mode {
		for byte in record do append(&log.memory, byte)
		log.size += i64(len(record))
		return ERROR_NONE
	}
	if log.size >= LOG_SEGMENT_MAX {
		if rotate_err := log_rotate(log, commit_seq); rotate_err.kind != .None {
			return rotate_err
		}
	}
	if log.file == nil do return ERROR_NONE
	if _, write_err := log_file_write(log.file, record); write_err.kind != .None {
		// Keep the kind: a quota rejection is not an I/O failure.
		return write_err
	}
	record_offset := log.size
	log.size += i64(len(record))
	if log.vfs == nil do log_index_append(log.path, commit_seq, record_offset)
	#partial switch log.durability {
	case .Full:
		if sync_err := log_file_sync(log.file); sync_err.kind != .None do return sync_err
	case .Batched:
		log.pending += 1
		if log.pending >= LOG_SYNC_BATCH {
			if sync_err := log_file_sync(log.file); sync_err.kind != .None do return sync_err
			log.pending = 0
		}
	case .None:
	}
	return ERROR_NONE
}

// log_rewind cuts the log back to a previous size. It is used when a commit
// record was appended but applying it failed, so the log never keeps a change
// the database rejected.
log_rewind :: proc(log: ^Commit_Log, size: i64) -> Error {
	if log.file == nil do return ERROR_NONE
	if truncate_err := log_file_truncate(log.file, size); truncate_err.kind != .None {
		return errf(.Io, "cannot rewind the commit log: %v", truncate_err.message)
	}
	if log.vfs == nil do log_index_truncate(log.path, size)
	if _, seek_err := log_file_seek(log.file, size); seek_err.kind != .None {
		return errf(.Io, "cannot seek after rewinding the log: %v", seek_err.message)
	}
	log.size = size
	return ERROR_NONE
}

log_index_path :: proc(log_path: string) -> string {
	return strings.concatenate({log_path, ".index"})
}

@(private)
log_index_write_header :: proc(file: ^os.File) -> Error {
	header: [LOG_INDEX_HEADER_LEN]u8
	copy(header[:8], LOG_INDEX_MAGIC)
	put_u32_le(header[8:12], LOG_VERSION)
	put_u32_le(header[12:16], LOG_INDEX_ENTRY_LEN)
	if _, write_err := os.write(file, header[:]); write_err != nil {
		return errf(.Io, "cannot write the log index header: %v", write_err)
	}
	return ERROR_NONE
}

@(private)
log_index_append :: proc(log_path: string, seq: u64, offset: i64) {
	index_path := log_index_path(log_path)
	defer delete(index_path)
	file, open_err := os.open(index_path, {.Read, .Write, .Create})
	if open_err != nil do return
	defer os.close(file)
	size, size_err := os.file_size(file)
	if size_err != nil do return
	if size == 0 {
		// A sidecar created here starts with its header. Without it every lookup
		// rejects the file and the index is dead weight: a database created by
		// this build used to have no usable index at all.
		if header_err := log_index_write_header(file); header_err.kind != .None do return
	}
	if _, seek_err := os.seek(file, 0, .End); seek_err != nil do return
	entry: [LOG_INDEX_ENTRY_LEN]u8
	put_u64_le(entry[0:8], seq)
	put_u64_le(entry[8:16], u64(offset))
	_, _ = os.write(file, entry[:])
}

// log_index_last returns the highest sequence the sidecar names, which is the
// sequence of the last record in the log. It is derived data: a missing or
// unreadable index reports found = false, and the caller replays instead.
log_index_last :: proc(log_path: string) -> (seq: u64, found: bool) {
	index_path := log_index_path(log_path)
	defer delete(index_path)
	file, open_err := os.open(index_path, {.Read})
	if open_err != nil do return 0, false
	defer os.close(file)
	header: [LOG_INDEX_HEADER_LEN]u8
	n, read_err := os.read(file, header[:])
	if read_err != nil || n != LOG_INDEX_HEADER_LEN do return 0, false
	if string(header[:8]) != LOG_INDEX_MAGIC do return 0, false
	if get_u32_le(header[8:12]) != LOG_VERSION do return 0, false
	if get_u32_le(header[12:16]) != LOG_INDEX_ENTRY_LEN do return 0, false
	size, size_err := os.file_size(file)
	entries := (size - LOG_INDEX_HEADER_LEN) / LOG_INDEX_ENTRY_LEN
	if size_err != nil || entries <= 0 do return 0, false
	// The sidecar is append-only, so the last entry is the last record.
	if _, seek_err := os.seek(file, size - LOG_INDEX_ENTRY_LEN, .Start); seek_err != nil {
		return 0, false
	}
	entry: [LOG_INDEX_ENTRY_LEN]u8
	got, entry_err := os.read(file, entry[:])
	if entry_err != nil || got != LOG_INDEX_ENTRY_LEN do return 0, false
	return get_u64_le(entry[0:8]), true
}

// log_index_ensure creates the sidecar for a log that predates it, or whose
// index was removed. It is a best-effort cache rebuild.
@(private)
log_index_ensure :: proc(log_path: string) {
	index_path := log_index_path(log_path)
	defer delete(index_path)
	if os.exists(index_path) do return
	file, open_err := os.open(index_path, {.Read, .Write, .Create, .Trunc})
	if open_err != nil do return
	if log_index_write_header(file).kind != .None {
		os.close(file)
		return
	}
	os.close(file)
	records, _, _, read_err := log_read_at(log_path, LOG_HEADER_LEN)
	if read_err.kind != .None do return
	for record in records {
		log_index_append(log_path, record.seq, record.offset)
	}
}

// log_index_lookup returns the offset of one record when the sidecar agrees
// with the log bytes at that position.
@(private)
log_index_lookup :: proc(log_path: string, seq: u64) -> (offset: i64, found: bool) {
	index_path := log_index_path(log_path)
	defer delete(index_path)
	file, open_err := os.open(index_path, {.Read})
	if open_err != nil do return 0, false
	defer os.close(file)
	header: [LOG_INDEX_HEADER_LEN]u8
	n, read_err := os.read(file, header[:])
	if read_err != nil || n != LOG_INDEX_HEADER_LEN do return 0, false
	if string(header[:8]) != LOG_INDEX_MAGIC do return 0, false
	if get_u32_le(header[8:12]) != LOG_VERSION do return 0, false
	if get_u32_le(header[12:16]) != LOG_INDEX_ENTRY_LEN do return 0, false
	entry: [LOG_INDEX_ENTRY_LEN]u8
	for {
		got, entry_err := os.read(file, entry[:])
		if entry_err != nil || got != LOG_INDEX_ENTRY_LEN do return 0, false
		if get_u64_le(entry[0:8]) == seq {
			return i64(get_u64_le(entry[8:16])), true
		}
	}
}

@(private)
log_offset_matches :: proc(log_path: string, offset: i64, seq: u64) -> bool {
	file, open_err := os.open(log_path, {.Read})
	if open_err != nil do return false
	defer os.close(file)
	if _, seek_err := os.seek(file, offset, .Start); seek_err != nil do return false
	record: [LOG_RECORD_HEADER_LEN]u8
	n, read_err := os.read(file, record[:])
	if read_err != nil || n != LOG_RECORD_HEADER_LEN do return false
	return get_u64_le(record[8:16]) == seq
}

// log_index_truncate drops entries at or after `size`, matching a log rewind.
log_index_truncate :: proc(log_path: string, size: i64) {
	index_path := log_index_path(log_path)
	defer delete(index_path)
	file, open_err := os.open(index_path, {.Read, .Write})
	if open_err != nil do return
	defer os.close(file)
	data, read_err := os.read_entire_file(index_path, context.allocator)
	if read_err != nil do return
	defer delete(data)
	if len(data) < LOG_INDEX_HEADER_LEN do return
	keep := 0
	position := LOG_INDEX_HEADER_LEN
	for position + LOG_INDEX_ENTRY_LEN <= len(data) {
		if i64(get_u64_le(data[position + 8:position + 16])) >= size do break
		keep += 1
		position += LOG_INDEX_ENTRY_LEN
	}
	_ = os.truncate(file, i64(LOG_INDEX_HEADER_LEN + keep * LOG_INDEX_ENTRY_LEN))
}

// log_read returns every valid record payload in order. It stops at the first
// torn, corrupt or out-of-order record and reports the byte offset where the
// valid region ends, so the caller can truncate the tail.
Log_Record :: struct {
	seq:     u64,
	offset:  i64,
	payload: []u8,
}

log_read :: proc(path: string, vfs: ^Vfs = nil) -> (records: []Log_Record, valid_len: i64, base_seq: u64, err: Error) {
	return log_read_at(path, LOG_HEADER_LEN, vfs)
}

// log_read_from is log_read starting at the first record after `min_seq`, using
// the sidecar index when it is trustworthy.
log_read_from :: proc(
	path: string,
	min_seq: u64,
	vfs: ^Vfs = nil,
) -> (records: []Log_Record, valid_len: i64, base_seq: u64, err: Error) {
	start := i64(LOG_HEADER_LEN)
	if vfs == nil {
		if offset, found := log_index_lookup(path, min_seq + 1); found {
			// A stale sidecar must never make the replay skip real records.
			if log_offset_matches(path, offset, min_seq + 1) {
				start = offset
			}
		}
	}
	return log_read_at(path, start, vfs)
}

// log_read_segments concatenates the segments that may hold records after
// `min_seq`. It reads each header to skip whole files, then uses the offset
// index for the segment where the first needed record lives.
log_read_segments :: proc(
	db_path: string,
	min_seq: u64,
	vfs: ^Vfs = nil,
) -> (records: []Log_Record, valid_len: i64, last_path: string, err: Error) {
	out := make([dynamic]Log_Record)
	ctx := Log_Read_Ctx{out = &out}
	valid, last, read_err := log_stream_segments(db_path, min_seq, vfs, &ctx, log_read_visit)
	if read_err.kind != .None {
		return nil, 0, "", read_err
	}
	return out[:], valid, last, ERROR_NONE
}
// Log_Stream_Stats records what a streaming replay actually held in memory, so a
// test can prove the whole log never entered it at once.
Log_Stream_Stats :: struct {
	records:      u64,
	bytes_read:   u64,
	// buffer_bytes is the largest record the walk had to hold, which is the bound
	// the replay costs, instead of the size of the log.
	buffer_bytes: int,
}

// Log_Stream_Visitor receives one validated record. The payload lives in the
// walk's buffer and is only valid during the call; a visitor that needs it later
// must copy it.
Log_Stream_Visitor :: proc(ctx: rawptr, record: Log_Record) -> bool

// log_stream_read fills `buffer` completely or reports how many bytes it got.
@(private)
log_stream_read :: proc(handle: ^Log_File, buffer: []u8) -> (int, Error) {
	total := 0
	for total < len(buffer) {
		read, read_err := log_file_read(handle, buffer[total:])
		if read_err.kind != .None do return total, read_err
		if read <= 0 do break
		total += read
	}
	return total, ERROR_NONE
}

// log_stream_at replays one log file from `start`, record by record. It holds one
// record at a time: the same validation the whole-file reader did (magic and
// checksum id from the header, CRC per record, consecutive sequences, a torn
// tail stops the walk), with a buffer that only grows to the largest record.
log_stream_at :: proc(
	vfs: ^Vfs,
	path: string,
	start: i64,
	ctx: rawptr,
	visit: Log_Stream_Visitor,
	stats: ^Log_Stream_Stats = nil,
) -> (valid_len: i64, base_seq: u64, err: Error) {
	file, open_err := log_file_open(vfs, path, {.Read})
	if open_err.kind != .None {
		return 0, 0, errf(.Io, "cannot read the commit log %s: %v", path, open_err.message)
	}
	defer log_file_close(file)
	header: [LOG_HEADER_LEN]u8
	header_len, header_err := log_stream_read(file, header[:])
	if header_err.kind != .None {
		return 0, 0, errf(.Io, "cannot read the commit log %s: %v", path, header_err.message)
	}
	if header_len < LOG_HEADER_LEN {
		return 0, 0, errf(.Corrupt_Log, "%s is shorter than a log header", path)
	}
	if string(header[:8]) != LOG_MAGIC {
		return 0, 0, errf(.Corrupt_Log, "%s is not a miraidb log (bad magic)", path)
	}
	checksum_id := get_u32_le(header[12:16])
	if checksum_id != u32(Checksum.None) && checksum_id != u32(Checksum.CRC32C) {
		return 0, 0, errf(.Corrupt_Log, "%s uses an unknown checksum id %d", path, checksum_id)
	}
	base_seq = get_u64_le(header[16:24])
	size := log_file_size(file)
	pos := start
	if pos < LOG_HEADER_LEN || pos > size {
		return 0, base_seq, errf(.Io, "log offset %d is outside %s", start, path)
	}
	if _, seek_err := log_file_seek(file, pos); seek_err.kind != .None do return 0, base_seq, seek_err
	buffer := make([]u8, LOG_STREAM_INITIAL)
	defer delete(buffer)
	expected_seq := base_seq + 1
	first := true
	valid_len = pos
	for pos + LOG_RECORD_HEADER_LEN <= size {
		record_header: [LOG_RECORD_HEADER_LEN]u8
		n, read_err := log_stream_read(file, record_header[:])
		if read_err.kind != .None do break
		if n < LOG_RECORD_HEADER_LEN do break
		length := int(get_u32_le(record_header[0:4]))
		stored_crc := get_u32_le(record_header[4:8])
		seq := get_u64_le(record_header[8:16])
		if length < 0 || pos + LOG_RECORD_HEADER_LEN + i64(length) > size do break
		if len(buffer) < length {
			delete(buffer)
			buffer = make([]u8, length)
			if stats != nil {
				stats.buffer_bytes = length
			}
		}
		payload := buffer[:length]
		payload_n, payload_err := log_stream_read(file, payload)
		if payload_err.kind != .None || payload_n != length do break
		if checksum_id == u32(Checksum.CRC32C) && crc32c(payload) != stored_crc do break
		if first {
			expected_seq = seq
			first = false
		}
		if seq != expected_seq do break
		pos += LOG_RECORD_HEADER_LEN + i64(length)
		valid_len = pos
		expected_seq += 1
		if stats != nil {
			stats.records += 1
			stats.bytes_read += u64(LOG_RECORD_HEADER_LEN + length)
		}
		keep := visit(ctx, Log_Record{seq = seq, offset = pos - i64(length) - LOG_RECORD_HEADER_LEN, payload = payload})
		if !keep do break
	}
	return valid_len, base_seq, ERROR_NONE
}

// Log_Read_Ctx collects the whole log, for the callers that need the records
// after the walk (the sidecar rebuild). Each payload is copied out.
@(private)
Log_Read_Ctx :: struct {
	out: ^[dynamic]Log_Record,
}

@(private)
log_read_visit :: proc(ctx: rawptr, record: Log_Record) -> bool {
	collect := cast(^Log_Read_Ctx)ctx
	payload := make([]u8, len(record.payload))
	copy(payload, record.payload)
	append(collect.out, Log_Record{seq = record.seq, offset = record.offset, payload = payload})
	return true
}

// log_stream_segments is log_read_segments without the materialisation: it walks
// the segments that may hold records after `min_seq` and hands each one to the
// visitor. `last_path` is allocated and belongs to the caller.
log_stream_segments :: proc(
	db_path: string,
	min_seq: u64,
	vfs: ^Vfs,
	ctx: rawptr,
	visit: Log_Stream_Visitor,
	stats: ^Log_Stream_Stats = nil,
) -> (valid_len: i64, last_path: string, err: Error) {
	count := log_last_segment_index(db_path, vfs) + 1
	paths := make([]string, count)
	for i in 0 ..< count do paths[i] = log_segment_path(db_path, i)
	defer {
		for path in paths do delete(path)
		delete(paths)
	}
	start_index := 0
	for i in 0 ..< count {
		start_index = i
		if log_segment_base(paths[i], vfs) + 1 > min_seq do break
	}
	for i in start_index ..< count {
		start := i64(LOG_HEADER_LEN)
		if i == start_index && vfs == nil {
			if offset, found := log_index_lookup(paths[i], min_seq + 1); found {
				if log_offset_matches(paths[i], offset, min_seq + 1) {
					start = offset
				}
			}
		}
		segment_valid, _, segment_err := log_stream_at(vfs, paths[i], start, ctx, visit, stats)
		if segment_err.kind != .None do return 0, "", segment_err
		valid_len = segment_valid
		if last_path != "" do delete(last_path)
		last_path = strings.clone(paths[i])
	}
	return valid_len, last_path, ERROR_NONE
}

@(private)
log_read_at :: proc(
	path: string,
	start: i64,
	vfs: ^Vfs = nil,
) -> (records: []Log_Record, valid_len: i64, base_seq: u64, err: Error) {
	out := make([dynamic]Log_Record)
	ctx := Log_Read_Ctx{out = &out}
	valid, base, read_err := log_stream_at(vfs, path, start, &ctx, log_read_visit)
	if read_err.kind != .None {
		return nil, 0, 0, read_err
	}
	return out[:], valid, base, ERROR_NONE
}
// log_truncate cuts the file back to a known-good length.
log_truncate :: proc(path: string, size: i64, vfs: ^Vfs = nil) -> Error {
	file, open_err := log_file_open(vfs, path, {.Read, .Write})
	if open_err.kind != .None {
		return errf(.Io, "cannot open %s to truncate: %v", path, open_err.message)
	}
	defer log_file_close(file)
	if truncate_err := log_file_truncate(file, size); truncate_err.kind != .None {
		return errf(.Io, "cannot truncate %s: %v", path, truncate_err.message)
	}
	return ERROR_NONE
}

// log_write_snapshot replaces a log with a single compacted record. The caller
// renames the result over the live file once it is durable.
log_write_snapshot :: proc(path: string, base_seq: u64, seq: u64, payload: []u8, vfs: ^Vfs = nil) -> Error {
	file, open_err := log_file_open(vfs, path, {.Read, .Write, .Create, .Trunc})
	if open_err.kind != .None {
		return errf(.Io, "cannot create %s: %v", path, open_err.message)
	}
	header: [LOG_HEADER_LEN]u8
	copy(header[:8], LOG_MAGIC)
	put_u32_le(header[8:12], LOG_VERSION)
	put_u32_le(header[12:16], u32(Checksum.CRC32C))
	put_u64_le(header[16:24], base_seq)
	if _, write_err := log_file_write(file, header[:]); write_err.kind != .None {
		log_file_close(file)
		return errf(.Io, "cannot write the snapshot header: %v", write_err.message)
	}
	record := make([]u8, LOG_RECORD_HEADER_LEN + len(payload))
	defer delete(record)
	put_u32_le(record[0:4], u32(len(payload)))
	put_u32_le(record[4:8], crc32c(payload))
	put_u64_le(record[8:16], seq)
	copy(record[LOG_RECORD_HEADER_LEN:], payload)
	if _, write_err := log_file_write(file, record); write_err.kind != .None {
		log_file_close(file)
		return errf(.Io, "cannot write the snapshot record: %v", write_err.message)
	}
	if sync_err := log_file_sync(file); sync_err.kind != .None {
		log_file_close(file)
		return errf(.Io, "cannot sync the snapshot: %v", sync_err.message)
	}
	if truncate_err := log_file_truncate(file, i64(LOG_HEADER_LEN + len(record))); truncate_err.kind != .None {
		log_file_close(file)
		return errf(.Io, "cannot size the snapshot: %v", truncate_err.message)
	}
	log_file_close(file)
	return ERROR_NONE
}

// --- little-endian helpers used by the log format ---------------------------

put_u32_le :: proc(dst: []u8, v: u32) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
	dst[2] = u8(v >> 16)
	dst[3] = u8(v >> 24)
}

put_u64_le :: proc(dst: []u8, v: u64) {
	put_u32_le(dst[0:4], u32(v))
	put_u32_le(dst[4:8], u32(v >> 32))
}

get_u32_le :: proc(src: []u8) -> u32 {
	return u32(src[0]) | u32(src[1]) << 8 | u32(src[2]) << 16 | u32(src[3]) << 24
}

get_u64_le :: proc(src: []u8) -> u64 {
	return u64(get_u32_le(src[0:4])) | u64(get_u32_le(src[4:8])) << 32
}

log_format_report :: proc(path: string) -> string {
	return fmt.aprintf("log %s (version %d)", path, LOG_VERSION)
}

// --- Streaming reader ------------------------------------------------------

// Log_Reader walks one log file record by record without loading it. The
// payload of each record points into an internal buffer and is valid until the
// next call.
Log_Reader :: struct {
	file:         ^Log_File,
	path:         string,
	position:     i64,
	size:         i64,
	expected_seq: u64,
	checksum:     Checksum,
	buffer:       [dynamic]u8,
	finished:     bool,
}

// log_reader_open reads the header and positions the reader at the first
// record. An unknown checksum or a bad magic is reported, so callers can fall
// back to the whole-file reader for diagnostics.
log_reader_open :: proc(path: string, vfs: ^Vfs = nil) -> (^Log_Reader, Error) {
	file, open_err := log_file_open(vfs, path, {.Read})
	if open_err.kind != .None {
		return nil, errf(.Io, "cannot open %s: %v", path, open_err.message)
	}
	header: [LOG_HEADER_LEN]u8
	n, read_err := log_file_read(file, header[:])
	if read_err.kind != .None || n != LOG_HEADER_LEN {
		log_file_close(file)
		return nil, errf(.Corrupt_Log, "%s is shorter than a log header", path)
	}
	if string(header[:8]) != LOG_MAGIC {
		log_file_close(file)
		return nil, errf(.Corrupt_Log, "%s is not a miraidb log (bad magic)", path)
	}
	checksum_id := get_u32_le(header[12:16])
	if checksum_id != u32(Checksum.None) && checksum_id != u32(Checksum.CRC32C) {
		log_file_close(file)
		return nil, errf(.Corrupt_Log, "%s uses an unknown checksum id %d", path, checksum_id)
	}
	size, seek_err := log_file_seek_end(file)
	if seek_err.kind != .None {
		log_file_close(file)
		return nil, errf(.Io, "cannot seek %s: %v", path, seek_err.message)
	}
	_, rewind_err := log_file_seek(file, LOG_HEADER_LEN)
	if rewind_err.kind != .None {
		log_file_close(file)
		return nil, errf(.Io, "cannot seek %s: %v", path, rewind_err.message)
	}
	reader := new(Log_Reader)
	reader.file = file
	reader.path = path
	reader.position = LOG_HEADER_LEN
	reader.size = size
	reader.expected_seq = get_u64_le(header[16:24]) + 1
	reader.checksum = Checksum(checksum_id)
	return reader, ERROR_NONE
}

// log_reader_next returns the next valid record. It stops cleanly at a torn
// tail, a checksum mismatch or a sequence gap.
log_reader_next :: proc(reader: ^Log_Reader) -> (record: Log_Record, ok: bool, err: Error) {
	if reader == nil || reader.file == nil || reader.finished do return {}, false, ERROR_NONE
	if reader.position + LOG_RECORD_HEADER_LEN > reader.size {
		reader.finished = true
		return {}, false, ERROR_NONE
	}
	header: [LOG_RECORD_HEADER_LEN]u8
	if _, seek_err := log_file_seek(reader.file, reader.position); seek_err.kind != .None {
		return {}, false, errf(.Io, "cannot seek %s: %v", reader.path, seek_err.message)
	}
	n, read_err := log_file_read(reader.file, header[:])
	if read_err.kind != .None || n != LOG_RECORD_HEADER_LEN {
		reader.finished = true
		return {}, false, ERROR_NONE
	}
	length := int(get_u32_le(header[0:4]))
	stored_crc := get_u32_le(header[4:8])
	seq := get_u64_le(header[8:16])
	if length < 0 || reader.position + LOG_RECORD_HEADER_LEN + i64(length) > reader.size {
		reader.finished = true
		return {}, false, ERROR_NONE
	}
	resize(&reader.buffer, length)
	if length > 0 {
		payload_n, payload_err := log_file_read(reader.file, reader.buffer[:])
		if payload_err.kind != .None || payload_n != length {
			reader.finished = true
			return {}, false, ERROR_NONE
		}
	}
	payload := reader.buffer[:length]
	if reader.checksum == .CRC32C && crc32c(payload) != stored_crc {
		reader.finished = true
		return {}, false, ERROR_NONE
	}
	if seq != reader.expected_seq {
		reader.finished = true
		return {}, false, ERROR_NONE
	}
	record = Log_Record{seq = seq, offset = reader.position, payload = payload}
	reader.position += LOG_RECORD_HEADER_LEN + i64(length)
	reader.expected_seq += 1
	return record, true, ERROR_NONE
}

log_reader_close :: proc(reader: ^Log_Reader) {
	if reader == nil do return
	if reader.file != nil {
		log_file_close(reader.file)
		reader.file = nil
	}
	delete(reader.buffer)
	free(reader)
}

// log_flush syncs the log if the durability mode asks for it. Group commits
// append with syncing disabled and call this once at the end.
log_flush :: proc(log: ^Commit_Log) -> Error {
	if log == nil || log.file == nil do return ERROR_NONE
	log.pending = 0
	if log.durability == .None do return ERROR_NONE
	if sync_err := log_file_sync(log.file); sync_err.kind != .None {
		return errf(.Io, "cannot sync the commit log: %v", sync_err.message)
	}
	return ERROR_NONE
}
