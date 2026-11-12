package engine

import "core:os"
import "core:strings"
import "core:sync"

// A snapshot is a standalone copy of the whole state at one commit sequence. It
// is optional: the commit log alone can rebuild the database. Loading one turns
// startup into "snapshot + the records after it" instead of "the whole history",
// and compaction writes one so a checkpoint stays cheap.
//
// File layout:
//
//	header  40 bytes: "MIRASNP1" + u32 version | u32 reserved | u64 base_seq
//	                  | u64 payload_len | u32 payload_crc32c | u32 reserved
//	payload         : the same op list a compacted log record holds
//
// The payload uses the commit log encoding, so both files share one decoder and
// one format version.

SNAPSHOT_MAGIC :: "MIRASNP1"
SNAPSHOT_VERSION :: LOG_VERSION
SNAPSHOT_HEADER_LEN :: 40

store_snapshot_path :: proc(directory: string) -> string {
	return strings.concatenate({directory, "/snapshot"})
}

// store_snapshot is the public name for writing <database>/snapshot.
store_snapshot :: proc(store: ^Store) -> Error {
	return store_write_snapshot(store)
}

// store_write_snapshot persists the state at the current commit sequence.
store_write_snapshot :: proc(store: ^Store) -> Error {
	if store.log.memory_mode || !store.persistent {
		return errf(.Invalid_Argument, "an in-memory database has no snapshot")
	}
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store_write_snapshot_locked(store)
}

// store_state_payload encodes every table, its indexes and its rows as one op
// list. The caller owns the result.
@(private)
store_state_payload :: proc(store: ^Store) -> []u8 {
	ops := make([dynamic]Store_Op)
	defer delete(ops)
	names := make([dynamic]string, 0, len(store.tables))
	for name in store.tables do append(&names, name)
	slice_sort_strings(names[:])
	for name in names {
		table := store.tables[name]
		append(&ops, Store_Op{kind = .Create_Table, name = name, schema = table.schema})
		rows := make([dynamic]Row)
		table_collect(table, &rows, max(u64))
		for row in rows {
			append(&ops, Store_Op{kind = .Insert, name = name, row_id = row.id, values = row.values})
		}
		delete(rows)
	}
	delete(names)
	return tx_encode_ops(ops[:])
}

@(private)
store_write_snapshot_locked :: proc(store: ^Store) -> Error {
	if store.vfs != nil {
		return errf(.Sql_Unsupported, "snapshots need the OS file system")
	}
	payload := store_state_payload(store)
	defer delete(payload)
	return store_write_snapshot_payload(store, payload)
}

@(private)
store_write_snapshot_payload :: proc(store: ^Store, payload: []u8) -> Error {
	path := store_snapshot_path(store.path)
	temp_path := strings.concatenate({store.path, "/snapshot.tmp"})
	defer delete(temp_path)
	file, open_err := os.open(temp_path, {.Read, .Write, .Create, .Trunc})
	if open_err != nil {
		return errf(.Io, "cannot create %s: %v", temp_path, open_err)
	}
	data := make([]u8, SNAPSHOT_HEADER_LEN + len(payload))
	defer delete(data)
	copy(data[:8], SNAPSHOT_MAGIC)
	put_u32_le(data[8:12], SNAPSHOT_VERSION)
	put_u32_le(data[12:16], 0)
	put_u64_le(data[16:24], store.commit_seq)
	put_u64_le(data[24:32], u64(len(payload)))
	put_u32_le(data[32:36], crc32c(payload))
	put_u32_le(data[36:40], 0)
	copy(data[SNAPSHOT_HEADER_LEN:], payload)
	if _, write_err := os.write(file, data); write_err != nil {
		os.close(file)
		return errf(.Io, "cannot write the snapshot: %v", write_err)
	}
	if sync_err := os.sync(file); sync_err != nil {
		os.close(file)
		return errf(.Io, "cannot sync the snapshot: %v", sync_err)
	}
	os.close(file)
	// Windows cannot rename over an existing file.
	if os.exists(path) {
		if remove_err := os.remove(path); remove_err != nil {
			return errf(.Io, "cannot replace the old snapshot: %v", remove_err)
		}
	}
	if rename_err := os.rename(temp_path, path); rename_err != nil {
		return errf(.Io, "cannot publish the snapshot: %v", rename_err)
	}
	return ERROR_NONE
}

// store_load_snapshot applies the snapshot file if one exists and leaves
// commit_seq at the snapshot boundary. Replay then skips everything at or below
// that sequence.
store_load_snapshot :: proc(store: ^Store) -> Error {
	path := store_snapshot_path(store.path)
	if !os.exists(path) do return ERROR_NONE
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return errf(.Io, "cannot read the snapshot %s: %v", path, read_err)
	}
	defer delete(data)
	if len(data) < SNAPSHOT_HEADER_LEN {
		return errf(.Corrupt_Log, "%s is shorter than a snapshot header", path)
	}
	if string(data[:8]) != SNAPSHOT_MAGIC {
		return errf(.Corrupt_Log, "%s is not a miraidb snapshot (bad magic)", path)
	}
	version := get_u32_le(data[8:12])
	if version > SNAPSHOT_VERSION {
		return errf(
			.Format_Too_New,
			"%s uses snapshot format %d, this build reads %d",
			path,
			version,
			SNAPSHOT_VERSION,
		)
	}
	if version < SNAPSHOT_VERSION {
		return errf(
			.Corrupt_Log,
			"%s uses snapshot format %d, this build reads %d",
			path,
			version,
			SNAPSHOT_VERSION,
		)
	}
	base_seq := get_u64_le(data[16:24])
	payload_len := int(get_u64_le(data[24:32]))
	stored_crc := get_u32_le(data[32:36])
	if payload_len < 0 || SNAPSHOT_HEADER_LEN + payload_len != len(data) {
		return errf(.Corrupt_Log, "%s has a truncated snapshot payload", path)
	}
	payload := data[SNAPSHOT_HEADER_LEN:]
	if crc32c(payload) != stored_crc {
		return errf(.Corrupt_Log, "%s has a corrupt snapshot payload", path)
	}
	if apply_err := store_apply_payload(store, payload, store.commit_seq + 1); apply_err.kind != .None {
		return errf(.Corrupt_Log, "snapshot %s cannot be applied: %s", path, apply_err.message)
	}
	store.commit_seq = base_seq
	return ERROR_NONE
}
