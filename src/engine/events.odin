package engine

import "core:mem"
import "core:strings"

// Event tables are append-only. They double as an outbox: a consumer reads
// rows from a cursor with `events_read`, then advances it to `last.id + 1`, so
// no extra subscription state is needed on the server side.

event_tables :: proc(store: ^Store, alloc: mem.Allocator) -> []string {
	names := store_table_names(store, context.allocator)
	defer delete(names)
	out := make([dynamic]string, 0, len(names), alloc)
	for name in names {
		if strings.has_prefix(name, "_") do continue
		if table, exists := store.tables[name]; exists && table.schema.event {
			append(&out, name)
		}
	}
	return out[:]
}

// events_read returns the rows of an event table whose id is greater than or
// equal to `from_id`, at most `limit` of them (zero means no limit), in
// `alloc`. It reads from the cursor on (tx_collect_from): it used to collect
// the whole table on every read, so a consumer near the end of 50 000 events
// paid for all of them. The values are copied into `alloc`, strings
// included: they pointed into the table, or into the read's arena for a paged
// table, which the read frees.
events_read :: proc(
	host: ^Host,
	table: string,
	from_id: Row_Id,
	limit: int,
	alloc: mem.Allocator,
) -> ([]Row, Error) {
	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	found: [dynamic]Row
	defer delete(found)
	if collect_err := tx_collect_from(tx, table, from_id, limit, &found); collect_err.kind != .None {
		return nil, collect_err
	}
	out := make([]Row, len(found), alloc)
	for row, i in found do out[i] = Row{id = row.id, values = values_clone_in(row.values, alloc)}
	return out, ERROR_NONE
}
