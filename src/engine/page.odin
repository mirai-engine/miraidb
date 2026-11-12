package engine

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// A page file is the on-disk materialisation used by the page store: fixed-size
// pages, a slotted layout for variable-length rows, a free list in the header
// page, and a buffer pool that decides what stays in memory.
//
// The commit log is still the truth. Pages are written after the record that
// describes them, and the header records the sequence the pages are complete
// up to; a page file that does not match the log is discarded and rebuilt by
// replaying. That order is what the fault-injection tests check: the header may
// name the old sequence or the new one, never a sequence whose pages did not
// land.
//
// Page 0 is the file header. A rows page holds cells that grow up from the
// header and slots that grow down from the end; a slot whose length is zero is
// a deleted cell, and the page compacts itself once the holes grow past half a
// page. A free page links to the next one through its own header, so the free
// list survives a crash.

PAGE_SIZE :: 4096
PAGE_MAGIC :: u32(0x4D52_5047) // "MRPG"
PAGE_VERSION :: u32(1)
PAGE_HEADER_LEN :: 32
PAGE_SLOT_LEN :: 4
PAGE_MAX_FRAMES :: 1 << 20

// Page_Id is the index of a page in the file; page 0 is the header.
Page_Id :: u32
NO_PAGE_ID :: Page_Id(0xFFFF_FFFF)

Page_Kind :: enum u8 {
	Free = 0,
	Rows = 1,
}

// Page_Header is the decoded form of the first bytes of every page.
Page_Header :: struct {
	kind:       Page_Kind,
	slots:      u16,
	slot_start: u16,
	free_start: u16,
	dead:       u16,
	row_count:  u16,
	next_free:  Page_Id,
}

@(private)
page_put_u16 :: proc(dst: []u8, v: u16) {
	dst[0] = u8(v)
	dst[1] = u8(v >> 8)
}

@(private)
page_get_u16 :: proc(src: []u8) -> u16 {
	return u16(src[0]) | u16(src[1]) << 8
}

@(private)
page_header_encode :: proc(data: []u8, header: Page_Header) {
	for i in 0 ..< PAGE_HEADER_LEN do data[i] = 0
	data[0] = u8(header.kind)
	page_put_u16(data[2:4], header.slots)
	page_put_u16(data[4:6], header.slot_start)
	page_put_u16(data[6:8], header.free_start)
	page_put_u16(data[8:10], header.dead)
	page_put_u16(data[10:12], header.row_count)
	put_u32_le(data[12:16], u32(header.next_free))
}

@(private)
page_header_decode :: proc(data: []u8) -> Page_Header {
	return Page_Header {
		kind = Page_Kind(data[0]),
		slots = page_get_u16(data[2:4]),
		slot_start = page_get_u16(data[4:6]),
		free_start = page_get_u16(data[6:8]),
		dead = page_get_u16(data[8:10]),
		row_count = page_get_u16(data[10:12]),
		next_free = Page_Id(get_u32_le(data[12:16])),
	}
}

// page_stamp computes the checksum with the checksum field zeroed, so a reader
// can verify the whole page without trusting the header it just read.
@(private)
page_stamp :: proc(data: []u8) -> u32 {
	saved := get_u32_le(data[16:20])
	put_u32_le(data[16:20], 0)
	sum := crc32c(data)
	put_u32_le(data[16:20], saved)
	return sum
}

@(private)
page_seal :: proc(data: []u8) {
	put_u32_le(data[16:20], 0)
	put_u32_le(data[16:20], crc32c(data))
}

@(private)
page_valid :: proc(data: []u8) -> bool {
	header := page_header_decode(data)
	if header.kind != .Rows && header.kind != .Free do return false
	if header.kind == .Rows {
		if header.slot_start < PAGE_HEADER_LEN || header.slot_start > PAGE_SIZE do return false
		if header.free_start < PAGE_HEADER_LEN || header.free_start > PAGE_SIZE do return false
		if header.free_start > header.slot_start do return false
		if int(header.slots) * PAGE_SLOT_LEN > PAGE_SIZE - int(header.slot_start) do return false
	}
	return page_stamp(data) == get_u32_le(data[16:20])
}

// --- Buffer pool -----------------------------------------------------------

Page_Frame :: struct {
	id:    Page_Id,
	valid: bool,
	dirty: bool,
	pins:  int,
	used:  bool,
	data:  []u8,
}

Page_File :: struct {
	vfs:   ^Vfs,
	file:  ^Vfs_File,
	path:  string,

	frames:    []Page_Frame,
	frame_map: map[Page_Id]int,
	clock:     int,

	page_count:   Page_Id,
	free_head:    Page_Id,
	free_pages:   u32,
	applied_seq:  u64,
	// stats, for tests and for honest documentation
	writes:    u64,
	reads:     u64,
	evictions: u64,
	pins_live: u32,
}

page_file_create :: proc(vfs: ^Vfs, path: string, frames: int) -> (^Page_File, Error) {
	count := frames
	if count <= 0 do count = 16
	if count > PAGE_MAX_FRAMES do count = PAGE_MAX_FRAMES
	system := log_vfs_or_os(vfs)
	file, open_err := system.ops.open(system, path, {.Read, .Write, .Create})
	if open_err.kind != .None {
		return nil, errf(.Io, "cannot create the page file %s: %s", path, open_err.message)
	}
	pf := new(Page_File)
	pf.vfs = system
	pf.file = file
	pf.path = strings.clone(path)
	pf.frames = make([]Page_Frame, count)
	for i in 0 ..< count {
		pf.frames[i].data = make([]u8, PAGE_SIZE)
		pf.frames[i].id = NO_PAGE_ID
	}
	pf.frame_map = make(map[Page_Id]int)
	pf.page_count = 1
	pf.free_head = NO_PAGE_ID

	// The header page is written through the same path as any other page, so a
	// crash before it lands leaves an empty file, which `open` reports as
	// unformatted instead of pretending it has data.
	header := pf.frames[0].data
	page_header_encode(header, Page_Header{kind = .Rows, slot_start = PAGE_SIZE, free_start = PAGE_HEADER_LEN})
	page_file_header_encode(header, pf)
	page_seal(header)
	if write_err := page_write_raw(pf, 0, header); write_err.kind != .None {
		page_file_destroy_unopened(pf)
		return nil, write_err
	}
	if sync_err := system.ops.sync(file); sync_err.kind != .None {
		page_file_destroy_unopened(pf)
		return nil, sync_err
	}
	return pf, ERROR_NONE
}

// page_file_open reads an existing page file. A file whose header is missing or
// does not verify is reported as corrupt: the caller discards it and rebuilds
// from the log rather than trusting it.
page_file_open :: proc(vfs: ^Vfs, path: string, frames: int) -> (^Page_File, Error) {
	count := frames
	if count <= 0 do count = 16
	if count > PAGE_MAX_FRAMES do count = PAGE_MAX_FRAMES
	system := log_vfs_or_os(vfs)
	file, open_err := system.ops.open(system, path, {.Read, .Write})
	if open_err.kind != .None {
		return nil, errf(.Io, "cannot open the page file %s: %s", path, open_err.message)
	}
	pf := new(Page_File)
	pf.vfs = system
	pf.file = file
	pf.path = strings.clone(path)
	pf.frames = make([]Page_Frame, count)
	for i in 0 ..< count {
		pf.frames[i].data = make([]u8, PAGE_SIZE)
		pf.frames[i].id = NO_PAGE_ID
	}
	pf.frame_map = make(map[Page_Id]int)

	header := make([]u8, PAGE_SIZE)
	defer delete(header)
	if read_err := page_read_raw(pf, 0, header); read_err.kind != .None {
		page_file_destroy_unopened(pf)
		return nil, errf(.Corrupt_Log, "the page file %s has no readable header", path)
	}
	if !page_valid(header) || !page_file_magic_ok(header) {
		page_file_destroy_unopened(pf)
		return nil, errf(.Corrupt_Log, "the page file %s has a corrupt header", path)
	}
	page_file_header_decode(pf, header)
	if pf.page_count == 0 {
		page_file_destroy_unopened(pf)
		return nil, errf(.Corrupt_Log, "the page file %s declares no pages", path)
	}
	return pf, ERROR_NONE
}

@(private)
page_file_destroy_unopened :: proc(pf: ^Page_File) {
	if pf.file != nil do pf.vfs.ops.close(pf.file)
	for &frame in pf.frames do delete(frame.data)
	delete(pf.frames)
	delete(pf.frame_map)
	delete(pf.path)
	free(pf)
}

// The header page carries the file-wide numbers the free list and the replay
// need: how many pages exist, where the free list starts, and the commit
// sequence the pages are complete up to.
page_file_header_encode :: proc(data: []u8, pf: ^Page_File) {
	put_u32_le(data[20:24], PAGE_MAGIC)
	put_u32_le(data[24:28], PAGE_VERSION)
	put_u32_le(data[28:32], u32(PAGE_SIZE))
	put_u32_le(data[32:36], u32(pf.page_count))
	put_u32_le(data[36:40], u32(pf.free_head))
	put_u32_le(data[40:44], pf.free_pages)
	put_u64_le(data[44:52], pf.applied_seq)
}

page_file_header_decode :: proc(pf: ^Page_File, data: []u8) {
	pf.page_count = Page_Id(get_u32_le(data[32:36]))
	pf.free_head = Page_Id(get_u32_le(data[36:40]))
	pf.free_pages = get_u32_le(data[40:44])
	pf.applied_seq = get_u64_le(data[44:52])
}

page_file_magic_ok :: proc(data: []u8) -> bool {
	return get_u32_le(data[20:24]) == PAGE_MAGIC && get_u32_le(data[24:28]) == PAGE_VERSION && get_u32_le(data[28:32]) == u32(PAGE_SIZE)
}

@(private)
page_write_raw :: proc(pf: ^Page_File, id: Page_Id, data: []u8) -> Error {
	seek, seek_err := pf.vfs.ops.seek(pf.file, i64(id) * PAGE_SIZE)
	if seek_err.kind != .None do return seek_err
	if seek != i64(id) * PAGE_SIZE {
		return errf(.Io, "cannot seek to page %d of %s", id, pf.path)
	}
	if write_err := vfs_write_all(pf.file, data); write_err.kind != .None {
		return errf(.Io, "cannot write page %d of %s: %s", id, pf.path, write_err.message)
	}
	pf.writes += 1
	return ERROR_NONE
}

@(private)
page_read_raw :: proc(pf: ^Page_File, id: Page_Id, into: []u8) -> Error {
	seek, seek_err := pf.vfs.ops.seek(pf.file, i64(id) * PAGE_SIZE)
	if seek_err.kind != .None do return seek_err
	if seek != i64(id) * PAGE_SIZE {
		return errf(.Io, "cannot seek to page %d of %s", id, pf.path)
	}
	total := 0
	for total < PAGE_SIZE {
		read, read_err := pf.vfs.ops.read(pf.file, into[total:])
		if read_err.kind != .None do return read_err
		if read <= 0 do break
		total += read
	}
	if total != PAGE_SIZE do return errf(.Corrupt_Log, "page %d of %s is short (%d bytes)", id, pf.path, total)
	pf.reads += 1
	return ERROR_NONE
}

// page_flush writes every dirty frame, then the header page with the new
// sequence. The order matters: a header that names a sequence is a promise that
// every page of that sequence is on disk.
page_flush :: proc(pf: ^Page_File, applied_seq: u64) -> Error {
	for &frame in pf.frames {
		if !frame.valid || !frame.dirty do continue
		if frame.id == 0 do continue
		page_seal(frame.data)
		if write_err := page_write_raw(pf, frame.id, frame.data); write_err.kind != .None {
			return write_err
		}
		frame.dirty = false
	}
	if pf.applied_seq != applied_seq do pf.applied_seq = applied_seq
	header := pf.frames[0].data
	page_header_encode(header, Page_Header{kind = .Rows, slot_start = PAGE_SIZE, free_start = PAGE_HEADER_LEN})
	page_file_header_encode(header, pf)
	page_seal(header)
	if write_err := page_write_raw(pf, 0, header); write_err.kind != .None do return write_err
	pf.frames[0].valid = true
	pf.frames[0].dirty = false
	pf.frames[0].pins = 0
	if sync_err := pf.vfs.ops.sync(pf.file); sync_err.kind != .None do return sync_err
	return ERROR_NONE
}

page_file_close :: proc(pf: ^Page_File) {
	if pf == nil do return
	page_file_destroy_unopened(pf)
}

// page_load pins a page and returns its frame. Loading evicts when the pool is
// full; eviction writes a dirty page back before reusing it.
page_load :: proc(pf: ^Page_File, id: Page_Id) -> (^Page_Frame, Error) {
	if index, found := pf.frame_map[id]; found {
		frame := &pf.frames[index]
		frame.pins += 1
		frame.used = true
		pf.pins_live += 1
		return frame, ERROR_NONE
	}
	slot := -1
	for &frame, i in pf.frames {
		if !frame.valid {
			slot = i
			break
		}
	}
	if slot < 0 {
		evicted, evict_err := page_evict(pf)
		if evict_err.kind != .None do return nil, evict_err
		slot = evicted
	}
	frame := &pf.frames[slot]
	frame.valid = true
	frame.dirty = false
	frame.pins = 1
	frame.used = true
	frame.id = id
	pf.frame_map[id] = slot
	pf.pins_live += 1
	if read_err := page_read_raw(pf, id, frame.data); read_err.kind != .None {
		frame.valid = false
		delete_key(&pf.frame_map, id)
		pf.pins_live -= 1
		return nil, read_err
	}
	if !page_valid(frame.data) {
		frame.valid = false
		delete_key(&pf.frame_map, id)
		pf.pins_live -= 1
		return nil, errf(.Corrupt_Log, "page %d of %s fails its checksum", id, pf.path)
	}
	return frame, ERROR_NONE
}

page_release :: proc(pf: ^Page_File, frame: ^Page_Frame, dirty: bool) {
	if frame.pins > 0 do frame.pins -= 1
	if pf.pins_live > 0 do pf.pins_live -= 1
	if dirty do frame.dirty = true
}

@(private)
page_evict :: proc(pf: ^Page_File) -> (int, Error) {
	count := len(pf.frames)
	for attempt in 0 ..< count * 2 {
		index := (pf.clock + attempt) % count
		frame := &pf.frames[index]
		if !frame.valid || frame.pins > 0 do continue
		if frame.used {
			frame.used = false
			continue
		}
		if frame.dirty {
			page_seal(frame.data)
			if write_err := page_write_raw(pf, frame.id, frame.data); write_err.kind != .None {
				return -1, write_err
			}
			frame.dirty = false
		}
		delete_key(&pf.frame_map, frame.id)
		frame.valid = false
		frame.id = NO_PAGE_ID
		pf.evictions += 1
		pf.clock = (index + 1) % count
		return index, ERROR_NONE
	}
	return -1, errf(.Quota_Exceeded, "the page pool has no unpinned frame")
}

// page_alloc hands out a page from the free list or grows the file. The page is
// not written until it is dirty, so an allocation that the transaction never
// commits costs nothing on disk.
page_alloc :: proc(pf: ^Page_File) -> (Page_Id, Error) {
	if pf.free_head != NO_PAGE_ID {
		id := pf.free_head
		page, load_err := page_load(pf, id)
		if load_err.kind != .None do return 0, load_err
		header := page_header_decode(page.data)
		pf.free_head = header.next_free
		page_release(pf, page, false)
		if pf.free_pages > 0 do pf.free_pages -= 1
		frame, frame_err := page_frame_new(pf, id)
		if frame_err.kind != .None do return 0, frame_err
		page_release(pf, frame, true)
		return id, ERROR_NONE
	}
	id := pf.page_count
	pf.page_count += 1
	frame, frame_err := page_frame_new(pf, id)
	if frame_err.kind != .None do return 0, frame_err
	page_release(pf, frame, true)
	return id, ERROR_NONE
}

// page_frame_new gives a frame to a page that has no content yet: nothing is
// read, the frame is initialised empty and marked dirty so the next flush writes
// it. It is what makes allocation cheap before a commit.
@(private)
page_frame_new :: proc(pf: ^Page_File, id: Page_Id) -> (^Page_Frame, Error) {
	if _, exists := pf.frame_map[id]; exists {
		frame, load_err := page_load(pf, id)
		return frame, load_err
	}
	slot := -1
	for &frame, i in pf.frames {
		if !frame.valid {
			slot = i
			break
		}
	}
	if slot < 0 {
		evicted, evict_err := page_evict(pf)
		if evict_err.kind != .None do return nil, evict_err
		slot = evicted
	}
	frame := &pf.frames[slot]
	frame.valid = true
	frame.dirty = true
	frame.pins = 1
	frame.used = true
	frame.id = id
	pf.frame_map[id] = slot
	pf.pins_live += 1
	for i in 0 ..< PAGE_SIZE do frame.data[i] = 0
	page_header_encode(frame.data, Page_Header{kind = .Rows, slot_start = PAGE_SIZE, free_start = PAGE_HEADER_LEN})
	return frame, ERROR_NONE
}

page_free :: proc(pf: ^Page_File, id: Page_Id) {
	frame, err := page_load(pf, id)
	if err.kind != .None do return
	logical := page_header_decode(frame.data)
	logical.kind = .Free
	logical.slots = 0
	logical.slot_start = PAGE_SIZE
	logical.free_start = PAGE_HEADER_LEN
	logical.row_count = 0
	logical.dead = 0
	logical.next_free = pf.free_head
	page_header_encode(frame.data, logical)
	page_release(pf, frame, true)
	pf.free_head = id
	pf.free_pages += 1
}

page_resident :: proc(pf: ^Page_File) -> int {
	count := 0
	for frame in pf.frames do if frame.valid do count += 1
	return count
}

// --- Slotted rows ----------------------------------------------------------

@(private)
page_slot_get :: proc(data: []u8, slot: u16) -> (offset: u16, length: u16) {
	at := PAGE_SIZE - (int(slot) + 1) * PAGE_SLOT_LEN
	offset = page_get_u16(data[at:at + 2])
	length = page_get_u16(data[at + 2:at + 4])
	return
}

@(private)
page_slot_put :: proc(data: []u8, slot: u16, offset: u16, length: u16) {
	at := PAGE_SIZE - (int(slot) + 1) * PAGE_SLOT_LEN
	page_put_u16(data[at:at + 2], offset)
	page_put_u16(data[at + 2:at + 4], length)
}

// page_compact rewrites the live cells at the bottom of the page and rebuilds
// the slot array, dropping the holes left by deleted rows.
@(private)
page_compact :: proc(data: []u8) {
	header := page_header_decode(data)
	cells: [dynamic]u8
	defer delete(cells)
	slots: [dynamic][2]u16
	defer delete(slots)
	write := PAGE_HEADER_LEN
	for slot in 0 ..< int(header.slots) {
		offset, length := page_slot_get(data, u16(slot))
		if length == 0 do continue
		append(&slots, [2]u16{u16(write), length})
		append(&cells, ..data[int(offset):int(offset) + int(length)])
		write += int(length)
	}
	for i in PAGE_HEADER_LEN ..< PAGE_SIZE do data[i] = 0
	copy(data[PAGE_HEADER_LEN:], cells[:])
	new_slot_start := PAGE_SIZE - len(slots) * PAGE_SLOT_LEN
	header.slots = u16(len(slots))
	header.slot_start = u16(new_slot_start)
	header.free_start = u16(write)
	header.dead = 0
	page_header_encode(data, header)
	for slot, i in slots {
		page_slot_put(data, u16(i), slot[0], slot[1])
	}
}

// page_insert_cell places one cell and returns its slot. It compacts first when
// the holes make the room, and reports false when the page cannot hold it.
@(private)
page_insert_cell :: proc(data: []u8, cell: []u8) -> (slot: u16, ok: bool) {
	if len(cell) + PAGE_SLOT_LEN > PAGE_SIZE - PAGE_HEADER_LEN do return 0, false
	header := page_header_decode(data)
	room := int(header.slot_start) - int(header.free_start)
	if room < len(cell) + PAGE_SLOT_LEN && header.dead > 0 {
		page_compact(data)
		header = page_header_decode(data)
	}
	if int(header.slot_start) - int(header.free_start) < len(cell) + PAGE_SLOT_LEN do return 0, false
	if len(cell) > 0xFFFF do return 0, false
	offset := header.free_start
	copy(data[int(offset):], cell)
	free_start := offset + u16(len(cell))
	slot = header.slots
	slot_start := header.slot_start - PAGE_SLOT_LEN
	page_header_encode(
		data,
		Page_Header {
			kind = .Rows,
			slots = header.slots + 1,
			slot_start = slot_start,
			free_start = free_start,
			dead = header.dead,
			row_count = header.row_count + 1,
			next_free = header.next_free,
		},
	)
	page_slot_put(data, slot, offset, u16(len(cell)))
	return slot, true
}

@(private)
page_delete_cell :: proc(data: []u8, slot: u16) -> bool {
	offset, length := page_slot_get(data, slot)
	if length == 0 do return false
	page_slot_put(data, slot, offset, 0)
	header := page_header_decode(data)
	deleted := int(length) + PAGE_SLOT_LEN
	if deleted > 0xFFFF - int(header.dead) do deleted = 0xFFFF - int(header.dead)
	header.dead += u16(deleted)
	if header.row_count > 0 do header.row_count -= 1
	page_header_encode(data, header)
	return true
}

// --- Rows over pages -------------------------------------------------------

Row_Location :: struct {
	page: Page_Id,
	slot: u16,
}

Page_Rows :: struct {
	file:      ^Page_File,
	directory: map[Row_Id]Row_Location,
	rows:      u64,
	pages:     u32,
}

page_rows_create :: proc(vfs: ^Vfs, path: string, frames: int) -> (^Page_Rows, Error) {
	file, err := page_file_create(vfs, path, frames)
	if err.kind != .None do return nil, err
	rows := new(Page_Rows)
	rows.file = file
	rows.directory = make(map[Row_Id]Row_Location)
	return rows, ERROR_NONE
}

// page_rows_open reads the pages and rebuilds the row directory from them. It
// does not trust the directory: the pages are the truth, and a page that fails
// its checksum aborts the open so the caller can rebuild from the log.
page_rows_open :: proc(vfs: ^Vfs, path: string, frames: int) -> (^Page_Rows, Error) {
	file, err := page_file_open(vfs, path, frames)
	if err.kind != .None do return nil, err
	rows := new(Page_Rows)
	rows.file = file
	rows.directory = make(map[Row_Id]Row_Location)
	for id in 1 ..< file.page_count {
		frame, load_err := page_load(file, id)
		if load_err.kind != .None {
			page_rows_close(rows)
			return nil, load_err
		}
		header := page_header_decode(frame.data)
		if header.kind == .Rows {
			for slot in 0 ..< int(header.slots) {
				offset, length := page_slot_get(frame.data, u16(slot))
				if length < 8 do continue
				row_id := Row_Id(get_u64_le(frame.data[offset:offset + 8]))
				rows.directory[row_id] = Row_Location{page = id, slot = u16(slot)}
			}
		}
		page_release(file, frame, false)
	}
	rows.rows = u64(len(rows.directory))
	return rows, ERROR_NONE
}

page_rows_close :: proc(rows: ^Page_Rows) {
	if rows == nil do return
	page_file_close(rows.file)
	delete(rows.directory)
	free(rows)
}

@(private)
row_cell_encode :: proc(row_id: Row_Id, values: []Value) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u64(&w, u64(row_id))
	bw_write_u32(&w, u32(len(values)))
	for value in values do value_encode(&w, value)
	out := make([]u8, len(w.data))
	copy(out, w.data[:])
	bw_destroy(&w)
	return out
}

@(private)
row_cell_decode :: proc(cell: []u8, alloc: mem.Allocator) -> (row: Row, ok: bool) {
	r: Byte_Reader
	br_init(&r, cell)
	row.id = Row_Id(br_read_u64(&r))
	count := int(br_read_u32(&r))
	if r.bad || count < 0 || count > 1024 do return {}, false
	row.values = make([]Value, count, alloc)
	for i in 0 ..< count {
		row.values[i] = value_decode(&r, alloc)
		if r.bad do return {}, false
	}
	return row, true
}

page_rows_put :: proc(rows: ^Page_Rows, row_id: Row_Id, values: []Value) -> Error {
	cell := row_cell_encode(row_id, values)
	defer delete(cell)
	if location, exists := rows.directory[row_id]; exists {
		page_rows_erase_slot(rows, location)
		delete_key(&rows.directory, row_id)
	}
	// Find a page with room: the last one first, because inserts arrive in order.
	for attempt in 0 ..< 2 {
		start := i64(rows.file.page_count) - 1
		for id := start; id >= 1; id -= 1 {
			frame, load_err := page_load(rows.file, Page_Id(id))
			if load_err.kind != .None do return load_err
			header := page_header_decode(frame.data)
			if header.kind != .Rows {
				page_release(rows.file, frame, false)
				continue
			}
			if _, ok := page_insert_cell(frame.data, cell); ok {
				slot := page_header_decode(frame.data).slots - 1
				page_release(rows.file, frame, true)
				rows.directory[row_id] = Row_Location{page = Page_Id(id), slot = slot}
				rows.rows += 1
				return ERROR_NONE
			}
			page_release(rows.file, frame, false)
		}
		if attempt == 0 {
			// No page has room: a new one is the answer for this and the next
			// inserts.
			id, alloc_err := page_alloc(rows.file)
			if alloc_err.kind != .None do return alloc_err
			rows.pages += 1
			frame, load_err := page_load(rows.file, id)
			if load_err.kind != .None do return load_err
			if _, ok := page_insert_cell(frame.data, cell); !ok {
				page_release(rows.file, frame, false)
				return errf(.Invalid_Argument, "a row of %d bytes does not fit in a page", len(cell))
			}
			page_release(rows.file, frame, true)
			rows.directory[row_id] = Row_Location{page = id, slot = 0}
			rows.rows += 1
			return ERROR_NONE
		}
	}
	return errf(.Internal, "cannot place row %d", row_id)
}

@(private)
page_rows_erase_slot :: proc(rows: ^Page_Rows, location: Row_Location) {
	frame, load_err := page_load(rows.file, location.page)
	if load_err.kind != .None do return
	if page_delete_cell(frame.data, location.slot) {
		if rows.rows > 0 do rows.rows -= 1
	}
	page_release(rows.file, frame, true)
}

page_rows_delete :: proc(rows: ^Page_Rows, row_id: Row_Id) -> bool {
	location, exists := rows.directory[row_id]
	if !exists do return false
	page_rows_erase_slot(rows, location)
	delete_key(&rows.directory, row_id)
	return true
}

// page_rows_contains reports whether a row is live. It reads the directory and
// does not touch the pages, which is what a uniqueness or existence check needs.
page_rows_contains :: proc(rows: ^Page_Rows, row_id: Row_Id) -> bool {
	return row_id in rows.directory
}

// page_rows_get decodes one row into the caller's allocator.
page_rows_get :: proc(rows: ^Page_Rows, row_id: Row_Id, alloc: mem.Allocator) -> (Row, bool) {
	location, exists := rows.directory[row_id]
	if !exists do return {}, false
	frame, load_err := page_load(rows.file, location.page)
	if load_err.kind != .None do return {}, false
	defer page_release(rows.file, frame, false)
	offset, length := page_slot_get(frame.data, location.slot)
	if length == 0 do return {}, false
	return row_cell_decode(frame.data[offset:offset + length], alloc)
}

// Page_Row_Visitor is called for every live row. The values are owned by the
// visitor's arena and are only valid for the duration of the call.
Page_Row_Visitor :: proc(ctx: rawptr, row: Row) -> bool

// page_rows_each streams the rows page by page. It never holds more than the
// pages the pool has, which is what lets a table larger than memory be read.
page_rows_each :: proc(rows: ^Page_Rows, ctx: rawptr, visit: Page_Row_Visitor) -> Error {
	arena: virtual.Arena
	if init_err := virtual.arena_init_growing(&arena); init_err != .None {
		return errf(.Out_Of_Memory, "cannot create the row arena")
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	for id in 1 ..< rows.file.page_count {
		frame, load_err := page_load(rows.file, id)
		if load_err.kind != .None do return load_err
		header := page_header_decode(frame.data)
		if header.kind != .Rows {
			page_release(rows.file, frame, false)
			continue
		}
		for slot in 0 ..< int(header.slots) {
			offset, length := page_slot_get(frame.data, u16(slot))
			if length == 0 do continue
			row, ok := row_cell_decode(frame.data[offset:offset + length], alloc)
			if !ok {
				page_release(rows.file, frame, false)
				return errf(.Corrupt_Log, "page %d holds a row that cannot be decoded", id)
			}
			keep := visit(ctx, row)
			virtual.arena_free_all(&arena)
			if !keep {
				page_release(rows.file, frame, false)
				return ERROR_NONE
			}
		}
		page_release(rows.file, frame, false)
	}
	return ERROR_NONE
}

// page_rows_scan is page_rows_each for a caller that wants the decoded values to
// outlive the visit: they are allocated in `alloc` and belong to it. It is what
// lets a table collect its rows from pages without decoding twice.
page_rows_scan :: proc(
	rows: ^Page_Rows,
	alloc: mem.Allocator,
	ctx: rawptr,
	visit: Page_Row_Visitor,
) -> Error {
	for id in 1 ..< rows.file.page_count {
		frame, load_err := page_load(rows.file, id)
		if load_err.kind != .None do return load_err
		header := page_header_decode(frame.data)
		if header.kind != .Rows {
			page_release(rows.file, frame, false)
			continue
		}
		for slot in 0 ..< int(header.slots) {
			offset, length := page_slot_get(frame.data, u16(slot))
			if length == 0 do continue
			row, ok := row_cell_decode(frame.data[offset:offset + length], alloc)
			if !ok {
				page_release(rows.file, frame, false)
				return errf(.Corrupt_Log, "page %d holds a row that cannot be decoded", id)
			}
			keep := visit(ctx, row)
			if !keep {
				page_release(rows.file, frame, false)
				return ERROR_NONE
			}
		}
		page_release(rows.file, frame, false)
	}
	return ERROR_NONE
}

// page_rows_truncate empties the table. Every page but the header goes back to
// the free list, so the file keeps its size and the next insert reuses them.
// The directory is the only index of what is live, so clearing it is enough for
// a scan to see nothing; the free list keeps the space accounted for.
page_rows_truncate :: proc(rows: ^Page_Rows) -> Error {
	for id in Page_Id(1) ..< rows.file.page_count {
		page_free(rows.file, id)
	}
	clear(&rows.directory)
	rows.rows = 0
	return ERROR_NONE
}

// page_rows_stats reports what one table occupies, for tests and for PRAGMA
// page_store: pages is the allocated page count, resident how many are in the
// pool, and disk bytes the file size.
Page_Rows_Stats :: struct {
	pages:    u32,
	resident: int,
	rows:     u64,
	disk:     i64,
	reads:    u64,
	writes:   u64,
	evicted:  u64,
}

page_rows_stats :: proc(rows: ^Page_Rows) -> Page_Rows_Stats {
	if rows == nil do return {}
	return Page_Rows_Stats {
		pages = rows.file.page_count,
		resident = page_resident(rows.file),
		rows = rows.rows,
		disk = rows.file.vfs.ops.size(rows.file.file),
		reads = rows.file.reads,
		writes = rows.file.writes,
		evicted = rows.file.evictions,
	}
}

page_rows_flush :: proc(rows: ^Page_Rows, applied_seq: u64) -> Error {
	return page_flush(rows.file, applied_seq)
}
