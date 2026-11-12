package engine

import "core:fmt"
import "core:mem"
import "core:strings"

// json_each and json_tree are table-valued functions: one JSON text in, one row
// per node out. They materialize into a temporary table, so the executor scans
// them exactly like a view and the planner needs no new case.
//
// Columns match SQLite: key, value, type, atom, id, parent, fullkey, path.
// `json_each` yields the direct children of the root (or the root itself when it
// is a scalar); `json_tree` walks the whole document depth first, containers
// included. Ids are assigned in that walk order, so the parent column is stable
// for one statement.

JSON_TABLE_FUNCTIONS :: []string{"json_each", "json_tree"}

is_json_table_function :: proc(name: string) -> bool {
	for candidate in JSON_TABLE_FUNCTIONS {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

@(private)
json_table_schema :: proc(name: string, alloc: mem.Allocator) -> Table_Schema {
	columns := make([]Column, 8, alloc)
	columns[0] = Column{name = "key", type = Column_Type{kind = .Any}}
	columns[1] = Column{name = "value", type = Column_Type{kind = .Any}}
	columns[2] = Column{name = "type", type = Column_Type{kind = .String}}
	columns[3] = Column{name = "atom", type = Column_Type{kind = .Any}}
	columns[4] = Column{name = "id", type = Column_Type{kind = .Int}}
	columns[5] = Column{name = "parent", type = Column_Type{kind = .Int}}
	columns[6] = Column{name = "fullkey", type = Column_Type{kind = .String}}
	columns[7] = Column{name = "path", type = Column_Type{kind = .String}}
	return Table_Schema{name = strings.clone(name, alloc), columns = columns}
}

// json_table_value is the `value` column: the SQL value for a scalar and the
// JSON text for a container. Booleans become 1/0, as SQLite reports them.
@(private)
json_table_value :: proc(node: Json_Value, alloc: mem.Allocator) -> Value {
	#partial switch node.kind {
	case .Bool:
		return value_int(node.boolean ? 1 : 0)
	case .Array, .Object:
		return value_string(json_write(node, alloc))
	}
	return json_to_value(node, alloc)
}

// json_table_atom is the scalar behind a node, or NULL for a container.
@(private)
json_table_atom :: proc(node: Json_Value, alloc: mem.Allocator) -> Value {
	#partial switch node.kind {
	case .Array, .Object:
		return value_null()
	}
	return json_table_value(node, alloc)
}

@(private)
Json_Table_Writer :: struct {
	table:   ^Table,
	tree:    bool,
	next_id: i64,
	alloc:   mem.Allocator,
	err:     Error,
}

@(private)
json_table_add :: proc(
	w: ^Json_Table_Writer,
	node: Json_Value,
	key: Value,
	fullkey: string,
	parent_key: string,
	parent_id: i64,
) {
	w.next_id += 1
	id := w.next_id
	values := make([]Value, 8, w.alloc)
	values[0] = key
	values[1] = json_table_value(node, w.alloc)
	values[2] = value_string(json_type_name(node))
	values[3] = json_table_atom(node, w.alloc)
	values[4] = value_int(id)
	values[5] = parent_id == 0 ? value_null() : value_int(parent_id)
	values[6] = value_string(fullkey)
	values[7] = value_string(parent_key)
	if insert_err := table_insert(w.table, Row_Id(id), values); insert_err.kind != .None {
		w.err = insert_err
	}
}

// json_table_child_key builds the key, fullkey and path of one child. Arrays
// index and objects name their children; SQLite writes an object member as
// `$.name` (quoted when the name is not a plain identifier).
@(private)
json_table_child :: proc(
	parent: Json_Value,
	index: int,
	parent_path: string,
	alloc: mem.Allocator,
) -> (key: Value, fullkey: string) {
	if parent.kind == .Array {
		key = value_int(i64(index))
		fullkey = strings.concatenate({parent_path, "[", fmt.aprintf("%d", index, allocator = alloc), "]"}, alloc)
		return key, fullkey
	}
	name := parent.keys[index]
	key = value_string(strings.clone(name, alloc))
	fullkey = strings.concatenate({parent_path, ".", json_table_key_text(name, alloc)}, alloc)
	return key, fullkey
}

// json_table_key_text quotes a member name when it would not read back plainly.
@(private)
json_table_key_text :: proc(name: string, alloc: mem.Allocator) -> string {
	plain := len(name) > 0
	if plain {
		for c in name {
			if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
				plain = false
				break
			}
		}
	}
	if plain do return name
	builder := strings.builder_make(alloc)
	strings.write_byte(&builder, '"')
	for c in transmute([]u8)name {
		if c == '"' || c == '\\' do strings.write_byte(&builder, '\\')
		strings.write_byte(&builder, c)
	}
	strings.write_byte(&builder, '"')
	return strings.to_string(builder)
}

// json_table_walk_tree inserts a node and, for a container, its children.
@(private)
json_table_walk_tree :: proc(
	w: ^Json_Table_Writer,
	node: Json_Value,
	key: Value,
	fullkey: string,
	parent_key: string,
	parent_id: i64,
) {
	if w.err.kind != .None do return
	json_table_add(w, node, key, fullkey, parent_key, parent_id)
	if node.kind != .Array && node.kind != .Object do return
	id := w.next_id
	children := node.kind == .Array ? len(node.items) : len(node.keys)
	for index in 0 ..< children {
		child_key, child_fullkey := json_table_child(node, index, fullkey, w.alloc)
		if node.kind == .Array {
			json_table_walk_tree(w, node.items[index], child_key, child_fullkey, fullkey, id)
		} else {
			json_table_walk_tree(w, node.values[index], child_key, child_fullkey, fullkey, id)
		}
		if w.err.kind != .None do return
	}
}

// tx_materialize_json_table builds the temporary table one json_each or
// json_tree reference reads.
tx_materialize_json_table :: proc(tx: ^Tx, name: string, args: []Value) -> (^Table, Error) {
	if len(args) != 1 {
		return nil, errf(.Invalid_Argument, "%s takes exactly one JSON argument", name)
	}
	text: string
	#partial switch args[0].kind {
	case .String:
		text = args[0].s
	case .Null:
		return nil, errf(.Invalid_Argument, "%s needs JSON text, not NULL", name)
	case:
		return nil, errf(.Invalid_Argument, "%s needs a JSON text argument", name)
	}
	root, parsed := json_parse(text, tx.alloc)
	if !parsed do return nil, errf(.Invalid_Argument, "%s got invalid JSON", name)

	schema := json_table_schema(name, tx.alloc)
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	w := Json_Table_Writer {
		table   = table,
		tree    = strings.equal_fold(name, "json_tree"),
		alloc   = tx.alloc,
		next_id = 0,
	}
	if w.tree {
		json_table_walk_tree(&w, root, value_null(), "$", "$", 0)
	} else if root.kind == .Array || root.kind == .Object {
		children := root.kind == .Array ? len(root.items) : len(root.keys)
		for index in 0 ..< children {
			child_key, child_fullkey := json_table_child(root, index, "$", w.alloc)
			node := root.kind == .Array ? root.items[index] : root.values[index]
			json_table_add(&w, node, child_key, child_fullkey, "$", 0)
			if w.err.kind != .None do break
		}
	} else {
		// A scalar document is a single row with no key.
		json_table_add(&w, root, value_null(), "$", "$", 0)
	}
	if w.err.kind != .None {
		table_destroy(table)
		return nil, w.err
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}
