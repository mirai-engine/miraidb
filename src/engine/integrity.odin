package engine

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// fk_check_child_one verifies one foreign key of one stored row. A key with a
// NULL component is not enforced, which is the SQL rule.
@(private)
fk_check_child_one :: proc(tx: ^Tx, fk: Foreign_Key, values: []Value) -> Error {
	for column in fk.columns {
		if values[column].kind == .Null do return ERROR_NONE
	}
	found, check_err := fk_parent_exists(tx, fk, values)
	if check_err.kind != .None do return check_err
	if !found {
		return errf(
			.Invalid_Argument,
			"foreign key %s has no matching row in %s",
			fk.name,
			fk.ref_table,
		)
	}
	return ERROR_NONE
}

// store_integrity_check reports what is wrong with the database: a row that no
// longer matches its schema, a unique key that repeats, an index that does not
// answer with the row feeding it, or a foreign key that points nowhere. An
// empty result is a healthy database. It runs on a read snapshot, so a commit
// cannot move the rows under it, and it is a diagnostic: the cost is linear in
// the rows of every table plus one index probe per row.
store_integrity_check :: proc(store: ^Store, alloc: mem.Allocator) -> [dynamic]string {
	problems := make([dynamic]string, 0, 4, alloc)
	tx := tx_begin_read(store)
	defer tx_end(tx)
	names := store_table_names(store, alloc)
	defer delete(names, alloc)
	slice.sort(names)
	for name in names {
		table, table_err := tx_table(tx, name)
		if table_err.kind != .None {
			append(&problems, fmt.aprintf("table %s is unreadable: %s", name, table_err.message, allocator = alloc))
			continue
		}
		live := make([dynamic]Row)
		if collect_err := tx_collect(tx, name, &live); collect_err.kind != .None {
			append(&problems, fmt.aprintf("table %s is unreadable: %s", name, collect_err.message, allocator = alloc))
			delete(live)
			continue
		}
		for row in live {
			if len(row.values) != len(table.schema.columns) {
				append(
					&problems,
					fmt.aprintf(
						"%s row %d has %d values for %d columns",
						name,
						u64(row.id),
						len(row.values),
						len(table.schema.columns),
						allocator = alloc,
					),
				)
			}
			for index, i in table.indexes {
				ids := table_index_lookup(table, i, row.values)
				holds := false
				for id in ids {
					if id == row.id {
						holds = true
						break
					}
				}
				delete(ids)
				if !holds {
					append(&problems,
						fmt.aprintf(
							"index %s misses %s row %d",
							index.schema.name,
							name,
							u64(row.id),
							allocator = alloc,
						),
					)
				}
			}
			if fk_err := fk_check_child(tx, table, row.values); fk_err.kind != .None {
				append(
					&problems,
					fmt.aprintf("%s row %d: %s", name, u64(row.id), fk_err.message, allocator = alloc),
				)
			}
		}
		for index, i in table.indexes {
			if !index.unique do continue
			seen := make(map[string]Row_Id)
			for row in live {
				key := unique_key(tx, table, i, row.values)
				if holder, taken := seen[key]; taken {
					append(&problems,
						fmt.aprintf(
							"unique index %s repeats the key of %s rows %d and %d",
							index.schema.name,
							name,
							u64(holder),
							u64(row.id),
							allocator = alloc,
						),
					)
				}
				seen[key] = row.id
			}
			delete(seen)
		}
		delete(live)
	}
	return problems
}

// Foreign_Key_Problem is one orphan a foreign_key_check found: the child row,
// the parent table it should reach and the position of the constraint.
Foreign_Key_Problem :: struct {
	table:  string,
	row_id: Row_Id,
	parent: string,
	index:  int,
}

// store_foreign_key_check reports every child row whose foreign key does not
// resolve to a parent row.
store_foreign_key_check :: proc(store: ^Store, alloc: mem.Allocator) -> [dynamic]Foreign_Key_Problem {
	problems := make([dynamic]Foreign_Key_Problem, 0, 4, alloc)
	tx := tx_begin_read(store)
	defer tx_end(tx)
	names := store_table_names(store, alloc)
	defer delete(names, alloc)
	slice.sort(names)
	for name in names {
		table, table_err := tx_table(tx, name)
		if table_err.kind != .None do continue
		live := make([dynamic]Row)
		if collect_err := tx_collect(tx, name, &live); collect_err.kind != .None {
			delete(live)
			continue
		}
		for row in live {
			for key, i in table.schema.foreign_keys {
				if fk_err := fk_check_child_one(tx, key, row.values); fk_err.kind != .None {
					append(&problems,
						Foreign_Key_Problem {
							table = strings.clone(name, alloc),
							row_id = row.id,
							parent = strings.clone(key.ref_table, alloc),
							index = i,
						},
					)
				}
			}
		}
		delete(live)
	}
	return problems
}
