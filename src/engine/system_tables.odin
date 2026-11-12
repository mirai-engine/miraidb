package engine

import "core:mem"
import "core:strings"

// System tables expose the catalog as ordinary queryable data. They are built
// per statement from the live schema and are not stored or logged.
SYSTEM_TABLES :: []string{"_tables", "_columns", "_indexes"}

is_system_table :: proc(name: string) -> bool {
	for candidate in SYSTEM_TABLES {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

// system_table_schema is the schema the executor resolves columns against.
system_table_schema :: proc(name: string, alloc: mem.Allocator) -> Table_Schema {
	text := Column_Type{kind = .String, width = 8}
	boolean := Column_Type{kind = .Bool, width = 1}
	schema := Table_Schema{name = name}
	switch {
	case strings.equal_fold(name, "_tables"):
		schema.columns = make([]Column, 1, alloc)
		schema.columns[0] = Column{name = "name", type = text}
	case strings.equal_fold(name, "_columns"):
		schema.columns = make([]Column, 7, alloc)
		schema.columns[0] = Column{name = "table", type = text}
		schema.columns[1] = Column{name = "name", type = text}
		schema.columns[2] = Column{name = "type", type = text}
		schema.columns[3] = Column{name = "not_null", type = boolean}
		schema.columns[4] = Column{name = "unique", type = boolean}
		schema.columns[5] = Column{name = "default", type = text}
		schema.columns[6] = Column{name = "named", type = text}
	case:
		schema.columns = make([]Column, 4, alloc)
		schema.columns[0] = Column{name = "table", type = text}
		schema.columns[1] = Column{name = "name", type = text}
		schema.columns[2] = Column{name = "columns", type = text}
		schema.columns[3] = Column{name = "unique", type = boolean}
	}
	return schema
}

// system_table_rows materializes the catalog for one system table, in
// table-name order and then column/index order.
system_table_rows :: proc(tx: ^Tx, name: string, alloc: mem.Allocator) -> [dynamic]Row {
	out := make([dynamic]Row, 0, 8, alloc)
	names := store_table_names(tx.store, context.allocator)
	defer delete(names)
	next_id := u64(1)
	for table_name in names {
		if strings.has_prefix(table_name, "_") do continue
		table, exists := tx.store.tables[table_name]
		if !exists do continue
		switch {
		case strings.equal_fold(name, "_tables"):
			values := make([]Value, 1, alloc)
			values[0] = value_string(strings.clone(table_name, alloc))
			append(&out, Row{id = Row_Id(next_id), values = values})
			next_id += 1
		case strings.equal_fold(name, "_columns"):
			for column in table.schema.columns {
				values := make([]Value, 7, alloc)
				values[0] = value_string(strings.clone(table_name, alloc))
				values[1] = value_string(strings.clone(column.name, alloc))
				values[2] = value_string(strings.clone(column_type_name(column.type), alloc))
				values[3] = value_bool(column.not_null)
				values[4] = value_bool(column.unique)
				if column.has_default {
					values[5] = value_string(value_format(column.default_value, alloc))
				} else {
					values[5] = value_string("")
				}
				values[6] = value_string(strings.clone(column.named_type, alloc))
				append(&out, Row{id = Row_Id(next_id), values = values})
				next_id += 1
			}
		case:
			for index in table.schema.indexes {
				column_list := ""
				for position, i in index.columns {
					if i > 0 do column_list = strings.concatenate({column_list, ", "})
					column_list = strings.concatenate({column_list, table.schema.columns[position].name})
				}
				values := make([]Value, 4, alloc)
				values[0] = value_string(strings.clone(table_name, alloc))
				values[1] = value_string(strings.clone(index.name, alloc))
				values[2] = value_string(column_list)
				values[3] = value_bool(index.unique)
				append(&out, Row{id = Row_Id(next_id), values = values})
				next_id += 1
			}
		}
	}
	return out
}
