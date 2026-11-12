package engine

import "core:fmt"
import "core:mem"
import "core:strings"

// export_sql renders every user table as INSERT statements, in table-name
// order and row order. Text is quoted and escaped; other kinds use the same
// textual form the engine prints, which parses back as SQL.
export_sql :: proc(host: ^Host, alloc: mem.Allocator) -> string {
	names := make([dynamic]string, 0, len(host.store.tables), alloc)
	for name in host.store.tables {
		if len(name) > 0 && name[0] == '_' do continue
		append(&names, name)
	}
	slice_sort_strings(names[:])
	builder := strings.builder_make(alloc)
	for name in names {
		result, select_err := sql_execute(host.store, fmt.tprintf("SELECT * FROM %s", name))
		if select_err.kind != .None do continue
		for row in result.rows {
			fmt.sbprintf(&builder, "INSERT INTO %s VALUES (", name)
			for v, i in row {
				if i > 0 do fmt.sbprint(&builder, ", ")
				fmt.sbprint(&builder, value_sql_literal(v))
			}
			fmt.sbprint(&builder, ");\n")
		}
		sql_result_destroy(&result)
	}
	return strings.to_string(builder)
}

@(private)
value_sql_literal :: proc(v: Value) -> string {
	#partial switch v.kind {
	case .Null, .Default:
		return "NULL"
	case .String:
		escaped, _ := strings.replace_all(v.s, "'", "''")
		return fmt.aprintf("'%s'", escaped)
	case:
		return value_format(v, context.temp_allocator)
	}
}
