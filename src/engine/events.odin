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
// equal to `from_id`, at most `limit` of them (zero means no limit).
events_read :: proc(
	host: ^Host,
	table: string,
	from_id: Row_Id,
	limit: int,
	alloc: mem.Allocator,
) -> ([]Row, Error) {
	tx := tx_begin_read(host.store)
	defer tx_end(tx)
	all: [dynamic]Row
	defer delete(all)
	if collect_err := tx_collect(tx, table, &all); collect_err.kind != .None {
		return nil, collect_err
	}
	out := make([dynamic]Row, 0, 8, alloc)
	for row in all {
		if row.id < from_id do continue
		if limit > 0 && len(out) >= limit do break
		values := make([]Value, len(row.values), alloc)
		copy(values, row.values)
		append(&out, Row{id = row.id, values = values})
	}
	return out[:], ERROR_NONE
}
