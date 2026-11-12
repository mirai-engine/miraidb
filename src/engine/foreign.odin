package engine

import "core:mem"
import "core:strings"

// Foreign key enforcement. Every change goes through tx_insert, tx_update and
// tx_delete, so checking here covers SQL, modules and any other caller. Replay
// applies committed operations directly and does not re-check them.

FK_MAX_DEPTH :: 16

@(private)
Fk_Child :: struct {
	table: ^Table,
	fk:    Foreign_Key,
}

// fk_parent_exists reports whether the parent table has a row whose referenced
// columns equal the child's key.
@(private)
fk_parent_exists :: proc(tx: ^Tx, fk: Foreign_Key, child_values: []Value) -> (bool, Error) {
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, fk.ref_table, &rows); collect_err.kind != .None {
		return false, collect_err
	}
	for row in rows {
		matches := true
		for ref_column, i in fk.ref_columns {
			if !value_equal(row.values[ref_column], child_values[fk.columns[i]]) {
				matches = false
				break
			}
		}
		if matches do return true, ERROR_NONE
	}
	return false, ERROR_NONE
}

// fk_check_child verifies that every foreign key of a row being written has a
// parent. A key with a NULL component is not enforced, which is the SQL rule.
fk_check_child :: proc(tx: ^Tx, table: ^Table, values: []Value) -> Error {
	for fk in table.schema.foreign_keys {
		has_null := false
		for column in fk.columns {
			if values[column].kind == .Null do has_null = true
		}
		if has_null do continue
		found, check_err := fk_parent_exists(tx, fk, values)
		if check_err.kind != .None do return check_err
		if !found {
			return errf(
				.Invalid_Argument,
				"foreign key %s on %s has no matching row in %s",
				fk.name,
				table.schema.name,
				fk.ref_table,
			)
		}
	}
	return ERROR_NONE
}

// fk_referencing lists the foreign keys of other tables that point at `parent`.
@(private)
fk_referencing :: proc(tx: ^Tx, parent: string, alloc: mem.Allocator) -> []Fk_Child {
	out := make([dynamic]Fk_Child, 0, 4, alloc)
	for name, table in tx.store.tables {
		if tx.state.dropped[name] do continue
		for fk in table.schema.foreign_keys {
			if !strings.equal_fold(fk.ref_table, parent) do continue
			append(&out, Fk_Child{table = table, fk = fk})
		}
	}
	for _, table in tx.state.created {
		for fk in table.schema.foreign_keys {
			if !strings.equal_fold(fk.ref_table, parent) do continue
			append(&out, Fk_Child{table = table, fk = fk})
		}
	}
	return out[:]
}

// fk_children_matching returns the rows of `child` whose key equals `values`.
@(private)
fk_children_matching :: proc(
	tx: ^Tx,
	child: Fk_Child,
	values: []Value,
	out: ^[dynamic]Row,
) -> Error {
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, child.table.schema.name, &rows); collect_err.kind != .None {
		return collect_err
	}
	for row in rows {
		matches := true
		for ref_column, i in child.fk.ref_columns {
			if !value_equal(row.values[child.fk.columns[i]], values[ref_column]) {
				matches = false
				break
			}
		}
		if matches do append(out, row)
	}
	return ERROR_NONE
}

// fk_parent_delete applies ON DELETE of every foreign key that references the
// row being removed. It runs before the delete is staged, so a cascade sees the
// children and a restrict fails the statement.
fk_parent_delete :: proc(
	tx: ^Tx,
	table_name: string,
	values: []Value,
	depth: int = 0,
) -> Error {
	if depth > FK_MAX_DEPTH {
		return errf(.Invalid_Argument, "foreign key cascade is deeper than %d", FK_MAX_DEPTH)
	}
	referencing := fk_referencing(tx, table_name, tx.alloc)
	for child in referencing {
		rows := make([dynamic]Row)
		if match_err := fk_children_matching(tx, child, values, &rows); match_err.kind != .None {
			delete(rows)
			return match_err
		}
		if len(rows) == 0 {
			delete(rows)
			continue
		}
		if child.fk.on_delete == .Restrict {
			delete(rows)
			return errf(
				.Invalid_Argument,
				"cannot delete from %s: %s still references it (foreign key %s)",
				table_name,
				child.table.schema.name,
				child.fk.name,
			)
		}
		for row in rows {
			if cascade_err := fk_parent_delete(tx, child.table.schema.name, row.values, depth + 1); cascade_err.kind != .None {
				delete(rows)
				return cascade_err
			}
			if delete_err := tx_delete(tx, child.table.schema.name, row.id); delete_err.kind != .None {
				delete(rows)
				return delete_err
			}
		}
		delete(rows)
	}
	return ERROR_NONE
}

// fk_parent_update applies ON UPDATE when a key a child points at changes.
fk_parent_update :: proc(
	tx: ^Tx,
	table_name: string,
	old_values: []Value,
	new_values: []Value,
	depth: int = 0,
) -> Error {
	if depth > FK_MAX_DEPTH do return errf(.Invalid_Argument, "foreign key cascade is too deep")
	referencing := fk_referencing(tx, table_name, tx.alloc)
	for child in referencing {
		changed := false
		for ref_column in child.fk.ref_columns {
			if !value_equal(old_values[ref_column], new_values[ref_column]) {
				changed = true
				break
			}
		}
		if !changed do continue
		rows := make([dynamic]Row)
		if match_err := fk_children_matching(tx, child, old_values, &rows); match_err.kind != .None {
			delete(rows)
			return match_err
		}
		if len(rows) == 0 {
			delete(rows)
			continue
		}
		if child.fk.on_update == .Restrict {
			delete(rows)
			return errf(
				.Invalid_Argument,
				"cannot change the key of %s: %s still references it (foreign key %s)",
				table_name,
				child.table.schema.name,
				child.fk.name,
			)
		}
		for row in rows {
			child_values := make([]Value, len(row.values), tx.alloc)
			copy(child_values, row.values)
			for ref_column, i in child.fk.ref_columns {
				child_values[child.fk.columns[i]] = new_values[ref_column]
			}
			if update_err := tx_update(tx, child.table.schema.name, row.id, child_values); update_err.kind != .None {
				delete(rows)
				return update_err
			}
		}
		delete(rows)
	}
	return ERROR_NONE
}
