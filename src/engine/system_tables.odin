package engine

import "core:mem"
import "core:strings"

// System tables expose the catalog as ordinary queryable data. They are built
// per statement from the live schema and are not stored or logged.
SYSTEM_TABLES :: []string {
	"_tables",
	"_columns",
	"_indexes",
	PG_TABLES,
	INFORMATION_SCHEMA_TABLES,
	INFORMATION_SCHEMA_COLUMNS,
}

// The PostgreSQL catalog views a client or a driver reads first, as system tables
// with the columns PostgreSQL names. The parser maps `pg_catalog.pg_tables`,
// `information_schema.tables` and `information_schema.columns` onto them.
PG_TABLES :: "_pg_tables"
INFORMATION_SCHEMA_TABLES :: "_information_schema_tables"
INFORMATION_SCHEMA_COLUMNS :: "_information_schema_columns"

// pg_catalog_table maps a PostgreSQL schema-qualified name onto this engine:
// `public.t` is `t`, and the catalog views are the system tables above. A schema
// it does not know is left alone, so `ATTACH … AS s` keeps working.
pg_catalog_table :: proc(schema, name: string) -> (string, bool) {
	switch {
	case strings.equal_fold(schema, "public"), strings.equal_fold(schema, "main"):
		// `main` is SQLite's name for the database itself.
		return name, true
	case strings.equal_fold(schema, "information_schema"):
		if strings.equal_fold(name, "tables") do return INFORMATION_SCHEMA_TABLES, true
		if strings.equal_fold(name, "columns") do return INFORMATION_SCHEMA_COLUMNS, true
	case strings.equal_fold(schema, "pg_catalog"):
		if strings.equal_fold(name, "pg_tables") do return PG_TABLES, true
	}
	return "", false
}

// pg_type_name is the name PostgreSQL's catalog prints for a column type.
pg_type_name :: proc(t: Column_Type) -> string {
	#partial switch t.kind {
	case .Bool:
		return "boolean"
	case .Int, .Uint:
		switch t.width {
		case 1, 2:
			return "smallint"
		case 4:
			return "integer"
		case 16:
			return "numeric"
		}
		return "bigint"
	case .Float:
		return t.width == 4 ? "real" : "double precision"
	case .String:
		return "text"
	case .Bytes:
		return "bytea"
	case .Timestamp:
		return "timestamp without time zone"
	case .Duration:
		return "interval"
	case .Uuid:
		return "uuid"
	}
	return "USER-DEFINED"
}

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
	case strings.equal_fold(name, PG_TABLES):
		schema.columns = make([]Column, 4, alloc)
		schema.columns[0] = Column{name = "schemaname", type = text}
		schema.columns[1] = Column{name = "tablename", type = text}
		schema.columns[2] = Column{name = "tableowner", type = text}
		schema.columns[3] = Column{name = "hasindexes", type = boolean}
	case strings.equal_fold(name, INFORMATION_SCHEMA_TABLES):
		schema.columns = make([]Column, 4, alloc)
		schema.columns[0] = Column{name = "table_catalog", type = text}
		schema.columns[1] = Column{name = "table_schema", type = text}
		schema.columns[2] = Column{name = "table_name", type = text}
		schema.columns[3] = Column{name = "table_type", type = text}
	case strings.equal_fold(name, INFORMATION_SCHEMA_COLUMNS):
		integer := Column_Type{kind = .Int, width = 8}
		schema.columns = make([]Column, 8, alloc)
		schema.columns[0] = Column{name = "table_catalog", type = text}
		schema.columns[1] = Column{name = "table_schema", type = text}
		schema.columns[2] = Column{name = "table_name", type = text}
		schema.columns[3] = Column{name = "column_name", type = text}
		schema.columns[4] = Column{name = "ordinal_position", type = integer}
		schema.columns[5] = Column{name = "data_type", type = text}
		schema.columns[6] = Column{name = "is_nullable", type = text}
		schema.columns[7] = Column{name = "column_default", type = text}
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
		case strings.equal_fold(name, PG_TABLES):
			values := make([]Value, 4, alloc)
			values[0] = value_string("public")
			values[1] = value_string(strings.clone(table_name, alloc))
			values[2] = value_string("miraidb")
			values[3] = value_bool(len(table.schema.indexes) > 0)
			append(&out, Row{id = Row_Id(next_id), values = values})
			next_id += 1
		case strings.equal_fold(name, INFORMATION_SCHEMA_TABLES):
			values := make([]Value, 4, alloc)
			values[0] = value_string("miraidb")
			values[1] = value_string("public")
			values[2] = value_string(strings.clone(table_name, alloc))
			values[3] = value_string("BASE TABLE")
			append(&out, Row{id = Row_Id(next_id), values = values})
			next_id += 1
		case strings.equal_fold(name, INFORMATION_SCHEMA_COLUMNS):
			for column, position in table.schema.columns {
				values := make([]Value, 8, alloc)
				values[0] = value_string("miraidb")
				values[1] = value_string("public")
				values[2] = value_string(strings.clone(table_name, alloc))
				values[3] = value_string(strings.clone(column.name, alloc))
				values[4] = value_int(i64(position + 1))
				values[5] = value_string(pg_type_name(column.type))
				values[6] = value_string(column.not_null ? "NO" : "YES")
				if column.has_default {
					values[7] = value_string(value_format(column.default_value, alloc))
				} else {
					values[7] = value_null()
				}
				append(&out, Row{id = Row_Id(next_id), values = values})
				next_id += 1
			}
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
				values := make([]Value, 4, alloc)
				values[0] = value_string(strings.clone(table_name, alloc))
				values[1] = value_string(strings.clone(index.name, alloc))
				values[2] = value_string(index_parts_text(table, index, alloc))
				values[3] = value_bool(index.unique)
				append(&out, Row{id = Row_Id(next_id), values = values})
				next_id += 1
			}
		}
	}
	return out
}
