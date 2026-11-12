package engine

import "core:mem"
import "core:strings"
import "core:slice"

// Type_Kind is the static type of a column. The engine keeps a small, fixed set
// so rows stay cheap and comparisons are unambiguous.
Type_Kind :: enum u8 {
	Bool,
	Int,
	Uint,
	Float,
	String,
	Bytes,
	Timestamp,
	Uuid,
	Duration,
	Identity,
	Connection,
	// Structural types: UNIT has one inhabitant (null), OPTION(T) is a typed
	// nullable and RESULT(T, E) is a tagged pair with exactly one side set.
	Unit,
	Option,
	Result,
	// Array(T) holds a variable-length list of T; Product(T1, T2) holds a fixed
	// pair. Both reuse the inner/right component slots.
	Array,
	Product,
	// Any keeps the storage class the value arrived with: the SQLite column with
	// no declared type (or NUMERIC affinity) stores integers, reals, text, blobs
	// and nulls in the same column.
	Any,
}

// Column_Type is a static type. `width` narrows integers (1, 2, 4 or 8 bytes)
// and floats (4 or 8); zero means the default width for the kind (8).
Column_Type :: struct {
	kind:  Type_Kind,
	width: u8,
	// inner and right carry the components of OPTION(T) and RESULT(T, E).
	inner_kind:  Type_Kind,
	inner_width: u8,
	right_kind:  Type_Kind,
	right_width: u8,
	// components holds every member of a PRODUCT(T1, T2, ...) in order.
	components: []Column_Type,
}

// type_inner is the payload type of OPTION(T).
type_inner :: proc(t: Column_Type) -> Column_Type {
	return Column_Type{kind = t.inner_kind, width = t.inner_width}
}

// type_right is the error type of RESULT(T, E).
type_right :: proc(t: Column_Type) -> Column_Type {
	return Column_Type{kind = t.right_kind, width = t.right_width}
}

type_bool :: Column_Type{kind = .Bool}
type_int :: Column_Type{kind = .Int, width = 8}
type_uint :: Column_Type{kind = .Uint, width = 8}
type_float :: Column_Type{kind = .Float, width = 8}
type_string :: Column_Type{kind = .String}
type_bytes :: Column_Type{kind = .Bytes}
type_timestamp :: Column_Type{kind = .Timestamp}
type_uuid :: Column_Type{kind = .Uuid}
type_duration :: Column_Type{kind = .Duration}
type_identity :: Column_Type{kind = .Identity}
type_connection :: Column_Type{kind = .Connection}

type_int_width :: proc(width: u8) -> Column_Type {
	return Column_Type{kind = .Int, width = width}
}

type_uint_width :: proc(width: u8) -> Column_Type {
	return Column_Type{kind = .Uint, width = width}
}

type_float_width :: proc(width: u8) -> Column_Type {
	return Column_Type{kind = .Float, width = width}
}

type_kind_name :: proc(kind: Type_Kind) -> string {
	switch kind {
	case .Bool:
		return "BOOLEAN"
	case .Int:
		return "INTEGER"
	case .Uint:
		return "UINTEGER"
	case .Float:
		return "DOUBLE"
	case .String:
		return "TEXT"
	case .Bytes:
		return "BLOB"
	case .Timestamp:
		return "TIMESTAMP"
	case .Uuid:
		return "UUID"
	case .Duration:
		return "DURATION"
	case .Identity:
		return "IDENTITY"
	case .Connection:
		return "CONNECTION"
	case .Unit:
		return "UNIT"
	case .Option:
		return "OPTION"
	case .Result:
		return "RESULT"
	case .Array:
		return "ARRAY"
	case .Product:
		return "PRODUCT"
	case .Any:
		return "ANY"
	}
	return "UNKNOWN"
}

type_kind_from_name :: proc(name: string) -> (kind: Type_Kind, width: u8, ok: bool) {
	switch strings.to_upper(name) {
	case "BOOL", "BOOLEAN":
		return .Bool, 0, true
	case "TINYINT", "INT1":
		return .Int, 1, true
	case "SMALLINT", "INT2":
		return .Int, 2, true
	case "INT4":
		return .Int, 4, true
	case "INT128", "I128":
		return .Int, 16, true
	case "INT", "INTEGER", "BIGINT", "INT8", "INT64":
		return .Int, 8, true
	case "UTINYINT", "UINT1":
		return .Uint, 1, true
	case "USMALLINT", "UINT2":
		return .Uint, 2, true
	case "UINT4":
		return .Uint, 4, true
	case "UINT128", "U128":
		return .Uint, 16, true
	case "UINT", "UINTEGER", "UBIGINT", "UINT8", "UINT64":
		return .Uint, 8, true
	case "FLOAT4", "REAL32":
		return .Float, 4, true
	case "REAL", "DOUBLE", "FLOAT", "FLOAT8", "FLOAT64":
		return .Float, 8, true
	case "TEXT", "STRING", "VARCHAR":
		return .String, 0, true
	case "BLOB", "BYTES", "BYTEA":
		return .Bytes, 0, true
	case "TIMESTAMP", "TIMESTAMPTZ", "DATETIME":
		return .Timestamp, 0, true
	case "UUID":
		return .Uuid, 0, true
	case "DURATION", "INTERVAL":
		return .Duration, 0, true
	case "IDENTITY":
		return .Identity, 0, true
	case "CONNECTION", "CONNECTION_ID":
		return .Connection, 0, true
	case "ANY":
		return .Any, 0, true
	case "UNIT", "VOID":
		return .Unit, 0, true
	}
	return {}, 0, false
}

// column_type_name is the SQL name of a full column type, width included.
column_type_name :: proc(t: Column_Type) -> string {
	#partial switch t.kind {
	case .Int:
		switch t.width {
		case 1:
			return "TINYINT"
		case 2:
			return "SMALLINT"
		case 4:
			return "INT"
		case 16:
			return "INT128"
		case:
			return "BIGINT"
		}
	case .Uint:
		switch t.width {
		case 1:
			return "UTINYINT"
		case 2:
			return "USMALLINT"
		case 4:
			return "UINT4"
		case 16:
			return "UINT128"
		case:
			return "UBIGINT"
		}
	case .Float:
		return t.width == 4 ? "FLOAT4" : "DOUBLE"
	case .Unit:
		return "UNIT"
	case .Array:
		return strings.concatenate(
			{"ARRAY(", column_type_name(type_inner(t)), ")"},
			context.temp_allocator,
		)
	case .Product:
		parts := make([dynamic]string, 0, len(t.components) + 2, context.temp_allocator)
		append(&parts, "PRODUCT(")
		for component, i in t.components {
			if i > 0 do append(&parts, ", ")
			append(&parts, column_type_name(component))
		}
		append(&parts, ")")
		return strings.concatenate(parts[:], context.temp_allocator)
	case .Option:
		return strings.concatenate(
			{"OPTION(", column_type_name(type_inner(t)), ")"},
			context.temp_allocator,
		)
	case .Result:
		return strings.concatenate(
			{
				"RESULT(",
				column_type_name(type_inner(t)),
				", ",
				column_type_name(type_right(t)),
				")",
			},
			context.temp_allocator,
		)
	}
	return type_kind_name(t.kind)
}

// type_is_integer reports whether the type maps to an integer kind.
type_is_integer :: proc(t: Column_Type) -> bool {
	return t.kind == .Int || t.kind == .Uint
}

// Sequence configures an auto-increment column: the first value handed out, the
// step, and the bounds it must stay in.
Sequence :: struct {
	start:     i64,
	increment: i64,
	min:       i64,
	max:       i64,
}

default_sequence :: proc() -> Sequence {
	return Sequence{start = 1, increment = 1, min = min(i64), max = max(i64)}
}

Column :: struct {
	name:           string,
	type:           Column_Type,
	// named_type is the catalog name the column was declared with, kept next to
	// the resolved type so a schema keeps its reference after replay.
	named_type:     string,
	unique:         bool,
	not_null:       bool,
	auto_increment: bool,
	sequence:       Sequence,
	has_default:    bool,
	default_value:  Value,
	// collation is the declared COLLATE of the column ("" means BINARY), used
	// when a comparison or a sort does not attach one of its own.
	collation:      string,
	// generated columns are computed when a row is written; generated_sql is the
	// expression text evaluated against the row being stored.
	generated:      bool,
	generated_sql:  string,
}

// Index_Algorithm selects how an index answers equality lookups. Btree keeps
// every entry ordered and supports ranges; Hash maps the key to its rows; Direct
// is the same map restricted to a unique single column, so a key names one row.
Index_Algorithm :: enum u8 {
	Btree,
	Hash,
	Direct,
}

Index_Schema :: struct {
	name:      string,
	columns:   []int,
	unique:    bool,
	implicit:  bool, // generated from the primary key or a UNIQUE column
	algorithm: Index_Algorithm,
}

// Foreign_Key_Action is what happens to referencing rows when the referenced key
// is deleted or updated.
Foreign_Key_Action :: enum u8 {
	Restrict,
	Cascade,
}

// Foreign_Key ties `columns` of a table to `ref_columns` of `ref_table`. Both
// lists hold column positions in their own tables.
Foreign_Key :: struct {
	name:        string,
	columns:     []int,
	ref_table:   string,
	ref_columns: []int,
	on_delete:   Foreign_Key_Action,
	on_update:   Foreign_Key_Action,
}

Table_Schema :: struct {
	name:                 string,
	columns:              []Column,
	indexes:              []Index_Schema,
	// ephemeral marks a temporary table: it is applied but never logged, so it
	// disappears on reopen.
	ephemeral:            bool,
	// event marks an append-only table: rows can be inserted and read but not
	// updated, deleted or truncated.
	event:                bool,
	// primary_key lists the column positions, in key order. It may be empty.
	primary_key:          []int,
	auto_increment_column: int,
	// foreign_keys ties this table's columns to a parent table.
	foreign_keys:         []Foreign_Key,
}

NO_COLUMN :: -1

// schema_column_index finds a column by name, case-insensitively.
schema_column_index :: proc(schema: ^Table_Schema, name: string) -> (int, bool) {
	for col, i in schema.columns {
		if strings.equal_fold(col.name, name) do return i, true
	}
	return NO_COLUMN, false
}

schema_has_primary_key :: proc(schema: ^Table_Schema) -> bool {
	return len(schema.primary_key) > 0
}

// schema_index_matches reports whether an index covers exactly these columns.
schema_index_matches :: proc(index: ^Index_Schema, columns: []int) -> bool {
	if len(index.columns) != len(columns) do return false
	for col, i in columns {
		if index.columns[i] != col do return false
	}
	return true
}

// schema_validate checks the invariants a schema must satisfy before it is used
// to build a table. Every failure is a user error, not an engine bug.
schema_validate :: proc(schema: ^Table_Schema) -> Error {
	if len(schema.name) == 0 {
		return errf(.Invalid_Argument, "table name is empty")
	}
	if len(schema.columns) == 0 {
		return errf(.Invalid_Argument, "table %s has no columns", schema.name)
	}
	if len(schema.name) == 0 do return errf(.Invalid_Argument, "a table needs a name")
	seen := make(map[string]bool, len(schema.columns))
	defer delete(seen)
	auto_count := 0
	for col, i in schema.columns {
		if len(col.name) == 0 {
			return errf(.Invalid_Argument, "table %s has a column without a name", schema.name)
		}
		if col.type.kind == .Unit && col.not_null {
			return errf(.Invalid_Argument, "column %s is UNIT and cannot be NOT NULL", col.name)
		}
		if col.type.kind == .Product {
			if len(col.type.components) < 2 {
				return errf(.Invalid_Argument, "column %s has a PRODUCT without components", col.name)
			}
			for component in col.type.components {
				#partial switch component.kind {
				case .Product, .Array, .Option, .Result, .Unit:
					return errf(
						.Invalid_Argument,
						"column %s has a structural component in PRODUCT",
						col.name,
					)
				}
			}
		}
		lower := strings.to_lower(col.name)
		defer delete(lower)
		if lower in seen {
			return errf(.Invalid_Argument, "table %s repeats column %s", schema.name, col.name)
		}
		seen[lower] = true
		if col.has_default && col.not_null && col.default_value.kind == .Null {
			return errf(.Invalid_Argument, "column %s.%s defaults to NULL but is NOT NULL", schema.name, col.name)
		}
		if col.auto_increment {
			auto_count += 1
			if col.sequence.increment == 0 {
				return errf(.Invalid_Argument, "column %s.%s has a zero sequence increment", schema.name, col.name)
			}
			if col.sequence.min > col.sequence.max {
				return errf(.Invalid_Argument, "column %s.%s has an inverted sequence range", schema.name, col.name)
			}
			if col.sequence.start < col.sequence.min || col.sequence.start > col.sequence.max {
				return errf(.Invalid_Argument, "column %s.%s starts a sequence outside its range", schema.name, col.name)
			}
			if !type_is_integer(col.type) {
				return errf(
					.Auto_Increment_Requires_Integer,
					"column %s.%s is auto increment but not an integer",
					schema.name,
					col.name,
				)
			}
			if len(schema.primary_key) != 1 || schema.primary_key[0] != i {
				return errf(
					.Invalid_Argument,
					"column %s.%s is auto increment but is not the whole primary key",
					schema.name,
					col.name,
				)
			}
		}
	}
	if auto_count > 1 {
		return errf(.Invalid_Argument, "table %s declares more than one auto increment column", schema.name)
	}
	pk_seen := make(map[int]bool, len(schema.primary_key))
	defer delete(pk_seen)
	for col in schema.primary_key {
		if col < 0 || col >= len(schema.columns) {
			return errf(.Invalid_Argument, "table %s has a primary key column that does not exist", schema.name)
		}
		if col in pk_seen {
			return errf(.Invalid_Argument, "table %s repeats a primary key column", schema.name)
		}
		pk_seen[col] = true
	}
	for idx, i in schema.indexes {
		if len(idx.name) == 0 {
			return errf(.Invalid_Argument, "table %s has an index without a name", schema.name)
		}
		if len(idx.columns) == 0 {
			return errf(.Invalid_Argument, "index %s has no columns", idx.name)
		}
		seen_columns := make(map[int]bool, len(idx.columns))
		defer delete(seen_columns)
		for col in idx.columns {
			if col < 0 || col >= len(schema.columns) {
				return errf(.Invalid_Argument, "index %s refers to a missing column", idx.name)
			}
			if col in seen_columns {
				return errf(.Invalid_Argument, "index %s repeats a column", idx.name)
			}
			seen_columns[col] = true
		}
		for other, j in schema.indexes {
			if i == j do continue
			if strings.equal_fold(idx.name, other.name) {
				return errf(.Index_Exists, "table %s repeats index %s", schema.name, idx.name)
			}
		}
	}
	// A self-reference is allowed; the parent's key must be unique, which the
	// execution layer checks once the parent schema is available.
	for fk in schema.foreign_keys {
		if len(fk.columns) == 0 || len(fk.columns) != len(fk.ref_columns) {
			return errf(.Invalid_Argument, "foreign key %s has mismatched columns", fk.name)
		}
		if len(fk.ref_table) == 0 {
			return errf(.Invalid_Argument, "foreign key %s has no referenced table", fk.name)
		}
		for col in fk.columns {
			if col < 0 || col >= len(schema.columns) {
				return errf(.Invalid_Argument, "foreign key %s refers to a missing column", fk.name)
			}
		}
	}
	return ERROR_NONE
}

// schema_column_key_index finds the index whose leading columns are exactly the
// given columns, used to satisfy equality predicates.
// schema_columns_unique reports whether a column set is the primary key or a
// unique index, which is what a foreign key must point at.
schema_columns_unique :: proc(schema: ^Table_Schema, columns: []int) -> bool {
	if len(columns) == len(schema.primary_key) {
		matches := true
		for col, i in columns do if schema.primary_key[i] != col do matches = false
		if matches do return true
	}
	for index in schema.indexes {
		if !index.unique || len(index.columns) != len(columns) do continue
		matches := true
		for col, i in columns do if index.columns[i] != col do matches = false
		if matches do return true
	}
	return false
}

schema_index_for_columns :: proc(schema: ^Table_Schema, columns: []int) -> (int, bool) {
	outer: for idx, i in schema.indexes {
		if len(idx.columns) < len(columns) do continue
		for col, j in columns {
			if idx.columns[j] != col do continue outer
		}
		return i, true
	}
	return NO_COLUMN, false
}

// column_default returns the value used when an insert omits a column.
column_default :: proc(col: Column) -> Value {
	if col.has_default do return col.default_value
	if col.auto_increment do return value_int(col.sequence.start)
	// An omitted value is NULL when the column accepts it, as SQLite and the SQL
	// standard expect; NOT NULL columns still get a usable zero value.
	if !col.not_null do return value_null()
	#partial switch col.type.kind {
	case .Bool:
		return value_bool(false)
	case .Int, .Timestamp:
		return value_int(0)
	case .Uint:
		return value_uint(0)
	case .Float:
		return value_float(0)
	case .String:
		return value_string("")
	case .Bytes:
		return value_bytes(nil)
	case .Uuid:
		return value_uuid({})
	case .Duration:
		return value_duration(0)
	case .Identity:
		return value_identity({})
	case .Connection:
		return value_connection(0)
	}
	return value_null()
}

// type_split_pair finds the comma that separates two component types at the
// top level of a `T1, T2` body.
@(private)
type_split_pair :: proc(body: string) -> int {
	depth := 0
	for i in 0 ..< len(body) {
		switch body[i] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 0 do return i
		}
	}
	return -1
}

// type_split_components splits a component list on its top-level commas.
@(private)
type_split_components :: proc(body: string) -> ([]string, bool) {
	parts := make([dynamic]string, 0, 2, context.temp_allocator)
	start := 0
	depth := 0
	for i in 0 ..< len(body) {
		switch body[i] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 0 {
				append(&parts, strings.trim_space(body[start:i]))
				start = i + 1
			}
		}
	}
	append(&parts, strings.trim_space(body[start:]))
	for part in parts {
		if len(part) == 0 do return nil, false
	}
	return parts[:], true
}

// type_parse_text rebuilds a Column_Type from its SQL spelling, which is how the
// type catalog stores bases that are themselves structural.
type_parse_text :: proc(text: string) -> (Column_Type, bool) {
	trimmed := strings.trim_space(text)
	upper := strings.to_upper(trimmed)
	if strings.has_prefix(upper, "OPTION(") && strings.has_suffix(trimmed, ")") {
		inner, ok := type_parse_text(trimmed[7:len(trimmed) - 1])
		if !ok do return {}, false
		return Column_Type{kind = .Option, inner_kind = inner.kind, inner_width = inner.width}, true
	}
	if strings.has_prefix(upper, "ARRAY(") && strings.has_suffix(trimmed, ")") {
		inner, ok := type_parse_text(trimmed[6:len(trimmed) - 1])
		if !ok do return {}, false
		return Column_Type{kind = .Array, inner_kind = inner.kind, inner_width = inner.width}, true
	}
	if strings.has_prefix(upper, "PRODUCT(") && strings.has_suffix(trimmed, ")") {
		body := trimmed[8:len(trimmed) - 1]
		parts, ok := type_split_components(body)
		if !ok || len(parts) < 2 do return {}, false
		components := make([]Column_Type, len(parts), context.temp_allocator)
		for part, i in parts {
			component, parsed := type_parse_text(part)
			if !parsed do return {}, false
			components[i] = component
		}
		return Column_Type{kind = .Product, components = components}, true
	}
	if strings.has_prefix(upper, "RESULT(") && strings.has_suffix(trimmed, ")") {
		body := trimmed[7:len(trimmed) - 1]
		split := type_split_pair(body)
		if split < 0 do return {}, false
		ok_type, ok_ok := type_parse_text(body[:split])
		err_type, err_ok := type_parse_text(body[split + 1:])
		if !ok_ok || !err_ok do return {}, false
		return Column_Type {
			kind = .Result,
			inner_kind = ok_type.kind,
			inner_width = ok_type.width,
			right_kind = err_type.kind,
			right_width = err_type.width,
		}, true
	}
	if kind, width, found := type_kind_from_name(trimmed); found {
		return Column_Type{kind = kind, width = width}, true
	}
	return {}, false
}

// value_coerce converts a value to the column type with SQL-like rules. It is
// the single place where the engine decides what fits a column, so inserts, SQL
// literals and index keys all agree.
value_coerce :: proc(v: Value, t: Column_Type) -> (Value, Error) {
	if t.kind == .Unit {
		if v.kind == .Null do return value_null(), ERROR_NONE
		return {}, errf(.Invalid_Type, "UNIT carries no value")
	}
	if t.kind == .Option {
		if v.kind == .Null do return value_null(), ERROR_NONE
		return value_coerce(v, type_inner(t))
	}
	if t.kind == .Array {
		if v.kind == .Null do return value_null(), ERROR_NONE
		if v.kind != .Array {
			return {}, errf(.Invalid_Type, "%s needs an array", column_type_name(t))
		}
		items := make([]Value, len(v.list), context.temp_allocator)
		for item, i in v.list {
			coerced, err := value_coerce(item, type_inner(t))
			if err.kind != .None do return {}, err
			items[i] = coerced
		}
		return Value{kind = .Array, list = items}, ERROR_NONE
	}
	if t.kind == .Product {
		if v.kind == .Null do return value_null(), ERROR_NONE
		if v.kind != .Product || len(v.list) != len(t.components) {
			return {}, errf(
				.Invalid_Type,
				"%s needs %d components",
				column_type_name(t),
				len(t.components),
			)
		}
		items := make([]Value, len(t.components), context.temp_allocator)
		for item, i in v.list {
			coerced, err := value_coerce(item, t.components[i])
			if err.kind != .None do return {}, err
			items[i] = coerced
		}
		return Value{kind = .Product, list = items}, ERROR_NONE
	}
	if t.kind == .Result {
		if v.kind == .Null do return value_null(), ERROR_NONE
		if v.kind != .Product || len(v.list) != 2 {
			return {}, errf(.Invalid_Type, "RESULT needs a two-element product")
		}
		ok_side := v.list[0].kind != .Null
		err_side := v.list[1].kind != .Null
		if ok_side == err_side {
			return {}, errf(.Invalid_Type, "RESULT needs exactly one side set")
		}
		items := make([]Value, 2, context.temp_allocator)
		if ok_side {
			coerced, err := value_coerce(v.list[0], type_inner(t))
			if err.kind != .None do return {}, err
			items[0] = coerced
			items[1] = value_null()
		} else {
			coerced, err := value_coerce(v.list[1], type_right(t))
			if err.kind != .None do return {}, err
			items[0] = value_null()
			items[1] = coerced
		}
		return Value{kind = .Product, list = items}, ERROR_NONE
	}
	if v.kind == .Null {
		return value_null(), ERROR_NONE
	}
	switch t.kind {
	case .Any:
		// The column keeps whatever storage class the value arrived with.
		return v, ERROR_NONE
	case .Unit, .Option, .Result, .Array, .Product:
		// Handled above, before the null shortcut.
		return {}, errf(.Invalid_Type, "structural type not coerced")
	case .Bool:
		#partial switch v.kind {
		case .Bool:
			return v, ERROR_NONE
		case .Int:
			return value_bool(v.i != 0), ERROR_NONE
		case .Uint:
			return value_bool(v.u != 0), ERROR_NONE
		}
	case .Int:
		if t.width == 16 {
			big: i128
			#partial switch v.kind {
			case .Int:
				big = i128(v.i)
			case .Uint:
				big = i128(v.u)
			case .Timestamp:
				big = i128(v.i)
			case .Int128:
				big = i128(value_big(v))
			case .Uint128:
				if value_big(v) > u128(max(i128)) {
					return {}, errf(.Invalid_Type, "value does not fit %s", column_type_name(t))
				}
				big = i128(value_big(v))
			case .Float:
				if v.f != v.f || v.f < -1.7e38 || v.f > 1.7e38 {
					return {}, errf(.Invalid_Type, "value %v does not fit %s", v.f, column_type_name(t))
				}
				big = i128(v.f)
			case:
				return {}, type_mismatch(v, t)
			}
			return value_int128(big), ERROR_NONE
		}
		converted: i64
		#partial switch v.kind {
		case .Int:
			converted = v.i
		case .Uint:
			if v.u > u64(max(i64)) {
				return {}, errf(.Invalid_Type, "value %v does not fit %s", v.u, column_type_name(t))
			}
			converted = i64(v.u)
		case .Timestamp:
			converted = v.i
		case .Int128:
			value := i128(value_big(v))
			if value < i128(min(i64)) || value > i128(max(i64)) {
				return {}, errf(.Invalid_Type, "value does not fit %s", column_type_name(t))
			}
			converted = i64(value)
		case .Uint128:
			if value_big(v) > u128(max(i64)) {
				return {}, errf(.Invalid_Type, "value does not fit %s", column_type_name(t))
			}
			converted = i64(value_big(v))
		case .Float:
			if v.f != v.f || v.f < -9.2e18 || v.f > 9.2e18 {
				return {}, errf(.Invalid_Type, "value %v does not fit %s", v.f, column_type_name(t))
			}
			converted = i64(v.f)
		case:
			return {}, type_mismatch(v, t)
		}
		if !i64_fits_width(converted, t.width) {
			return {}, errf(.Invalid_Type, "value %d does not fit %s", converted, column_type_name(t))
		}
		return value_int(converted), ERROR_NONE
	case .Uint:
		if t.width == 16 {
			big: u128
			#partial switch v.kind {
			case .Uint:
				big = u128(v.u)
			case .Int:
				if v.i < 0 {
					return {}, errf(.Invalid_Type, "negative value does not fit %s", column_type_name(t))
				}
				big = u128(v.i)
			case .Uint128:
				big = value_big(v)
			case .Int128:
				if i128(value_big(v)) < 0 {
					return {}, errf(.Invalid_Type, "negative value does not fit %s", column_type_name(t))
				}
				big = value_big(v)
			case .Float:
				if v.f < 0 || v.f != v.f || v.f > 3.4e38 {
					return {}, errf(.Invalid_Type, "value %v does not fit %s", v.f, column_type_name(t))
				}
				big = u128(v.f)
			case:
				return {}, type_mismatch(v, t)
			}
			return value_uint128(big), ERROR_NONE
		}
		converted: u64
		#partial switch v.kind {
		case .Uint:
			converted = v.u
		case .Int:
			if v.i < 0 {
				return {}, errf(.Invalid_Type, "negative value does not fit %s", column_type_name(t))
			}
			converted = u64(v.i)
		case .Int128:
			value := i128(value_big(v))
			if value < 0 || u128(value) > u128(max(u64)) {
				return {}, errf(.Invalid_Type, "value does not fit %s", column_type_name(t))
			}
			converted = u64(value)
		case .Uint128:
			if value_big(v) > u128(max(u64)) {
				return {}, errf(.Invalid_Type, "value does not fit %s", column_type_name(t))
			}
			converted = u64(value_big(v))
		case .Float:
			if v.f < 0 || v.f != v.f || v.f > 1.8e19 {
				return {}, errf(.Invalid_Type, "value %v does not fit %s", v.f, column_type_name(t))
			}
			converted = u64(v.f)
		case:
			return {}, type_mismatch(v, t)
		}
		if !u64_fits_width(converted, t.width) {
			return {}, errf(.Invalid_Type, "value %d does not fit %s", converted, column_type_name(t))
		}
		return value_uint(converted), ERROR_NONE
	case .Float:
		converted: f64
		#partial switch v.kind {
		case .Float:
			converted = v.f
		case .Int, .Timestamp:
			converted = f64(v.i)
		case .Uint:
			converted = f64(v.u)
		case:
			return {}, type_mismatch(v, t)
		}
		if t.width == 4 {
			converted = f64(f32(converted))
		}
		return value_float(converted), ERROR_NONE
	case .String:
		if v.kind == .String do return v, ERROR_NONE
	case .Bytes:
		if v.kind == .Bytes do return v, ERROR_NONE
	case .Timestamp:
		#partial switch v.kind {
		case .Timestamp:
			return v, ERROR_NONE
		case .Int:
			return value_timestamp(Timestamp(v.i)), ERROR_NONE
		case .Uint:
			return value_timestamp(Timestamp(i64(v.u))), ERROR_NONE
		case .String:
			// Accept an integer number of microseconds given as text.
			if parsed, ok := value_parse_number(v.s); ok {
				if i, int_ok := value_to_i64(parsed); int_ok {
					return value_timestamp(Timestamp(i)), ERROR_NONE
				}
			}
		}
	case .Uuid:
		#partial switch v.kind {
		case .Uuid:
			return v, ERROR_NONE
		case .String:
			if parsed, ok := uuid_parse(v.s); ok {
				return value_uuid(parsed), ERROR_NONE
			}
		}
	case .Duration:
		#partial switch v.kind {
		case .Duration:
			return v, ERROR_NONE
		case .Int, .Timestamp:
			return value_duration(Duration(v.i)), ERROR_NONE
		case .Uint:
			return value_duration(Duration(i64(v.u))), ERROR_NONE
		case .String:
			if parsed, ok := value_parse_number(v.s); ok {
				if i, int_ok := value_to_i64(parsed); int_ok {
					return value_duration(Duration(i)), ERROR_NONE
				}
			}
		}
	case .Identity:
		#partial switch v.kind {
		case .Identity:
			return v, ERROR_NONE
		case .Bytes:
			if len(v.bytes) == 32 {
				id: Identity
				copy(id[:], v.bytes)
				return value_identity(id), ERROR_NONE
			}
		case .String:
			if parsed, ok := identity_parse(v.s); ok {
				return value_identity(parsed), ERROR_NONE
			}
		}
	case .Connection:
		#partial switch v.kind {
		case .Connection:
			return v, ERROR_NONE
		case .Uint:
			return value_connection(v.u), ERROR_NONE
		case .Int:
			if v.i >= 0 do return value_connection(u64(v.i)), ERROR_NONE
		}
	}
	return {}, type_mismatch(v, t)
}

@(private)
type_mismatch :: proc(v: Value, t: Column_Type) -> Error {
	return errf(
		.Invalid_Type,
		"cannot use a %s value as %s",
		value_kind_name(v.kind),
		column_type_name(t),
	)
}

@(private)
i64_fits_width :: proc(v: i64, width: u8) -> bool {
	switch width {
	case 1:
		return v >= -128 && v <= 127
	case 2:
		return v >= -32768 && v <= 32767
	case 4:
		return v >= -2147483648 && v <= 2147483647
	}
	return true
}

@(private)
u64_fits_width :: proc(v: u64, width: u8) -> bool {
	switch width {
	case 1:
		return v <= 255
	case 2:
		return v <= 65535
	case 4:
		return v <= 4294967295
	}
	return true
}

// index_encode writes one index definition, used by CREATE INDEX records.
index_encode :: proc(w: ^Byte_Writer, index: ^Index_Schema) {
	bw_write_string(w, index.name)
	flags := u8(0)
	if index.unique do flags |= 1 << 0
	if index.implicit do flags |= 1 << 1
	bw_write_u8(w, flags)
	bw_write_u8(w, u8(index.algorithm))
	bw_write_u32(w, u32(len(index.columns)))
	for col in index.columns do bw_write_u32(w, u32(col))
}

index_decode :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> Index_Schema {
	index: Index_Schema
	index.name = br_read_string(r, alloc)
	flags := br_read_u8(r)
	index.unique = flags & (1 << 0) != 0
	index.implicit = flags & (1 << 1) != 0
	index.algorithm = Index_Algorithm(br_read_u8(r))
	n := int(br_read_u32(r))
	if r.bad do return index
	columns := make([]int, n, alloc)
	for i in 0 ..< n do columns[i] = int(br_read_u32(r))
	index.columns = columns
	return index
}

// --- Schema serialization: stable across releases ---------------------------

schema_encode :: proc(w: ^Byte_Writer, schema: ^Table_Schema) {
	bw_write_string(w, schema.name)
	flags := u8(0)
	if schema.ephemeral do flags |= 1 << 0
	if schema.event do flags |= 1 << 1
	bw_write_u8(w, flags)
	bw_write_u32(w, u32(len(schema.columns)))
	for col in schema.columns {
		bw_write_string(w, col.name)
		bw_write_u8(w, u8(col.type.kind))
		bw_write_u8(w, col.type.width)
		if col.type.kind == .Option || col.type.kind == .Result || col.type.kind == .Array || col.type.kind == .Product {
			bw_write_u8(w, u8(col.type.inner_kind))
			bw_write_u8(w, col.type.inner_width)
		}
		if col.type.kind == .Result {
			bw_write_u8(w, u8(col.type.right_kind))
			bw_write_u8(w, col.type.right_width)
		}
		if col.type.kind == .Product {
			bw_write_u8(w, u8(len(col.type.components)))
			for component in col.type.components {
				bw_write_u8(w, u8(component.kind))
				bw_write_u8(w, component.width)
			}
		}
		column_flags := u8(0)
		if col.unique do column_flags |= 1 << 1
		if col.not_null do column_flags |= 1 << 2
		if col.auto_increment do column_flags |= 1 << 3
		if col.has_default do column_flags |= 1 << 4
		if len(col.named_type) > 0 do column_flags |= 1 << 5
		if len(col.collation) > 0 do column_flags |= 1 << 6
		if col.generated do column_flags |= 1 << 7
		bw_write_u8(w, column_flags)
		if len(col.named_type) > 0 {
			bw_write_string(w, col.named_type)
		}
		if len(col.collation) > 0 {
			bw_write_string(w, col.collation)
		}
		if col.generated {
			bw_write_string(w, col.generated_sql)
		}
		if col.has_default {
			value_encode(w, col.default_value)
		}
		if col.auto_increment {
			bw_write_i64(w, col.sequence.start)
			bw_write_i64(w, col.sequence.increment)
			bw_write_i64(w, col.sequence.min)
			bw_write_i64(w, col.sequence.max)
		}
	}
	bw_write_u32(w, u32(len(schema.primary_key)))
	for col in schema.primary_key {
		bw_write_u32(w, u32(col))
	}
	bw_write_u32(w, u32(len(schema.foreign_keys)))
	for fk in schema.foreign_keys {
		bw_write_string(w, fk.name)
		bw_write_u8(w, u8(fk.on_delete))
		bw_write_u8(w, u8(fk.on_update))
		bw_write_string(w, fk.ref_table)
		bw_write_u32(w, u32(len(fk.columns)))
		for col in fk.columns do bw_write_u32(w, u32(col))
		bw_write_u32(w, u32(len(fk.ref_columns)))
		for col in fk.ref_columns do bw_write_u32(w, u32(col))
	}
	bw_write_u32(w, u32(len(schema.indexes)))
	for idx in schema.indexes {
		bw_write_string(w, idx.name)
		index_flags := u8(0)
		if idx.unique do index_flags |= 1 << 0
		if idx.implicit do index_flags |= 1 << 1
		bw_write_u8(w, index_flags)
		bw_write_u8(w, u8(idx.algorithm))
		bw_write_u32(w, u32(len(idx.columns)))
		for col in idx.columns {
			bw_write_u32(w, u32(col))
		}
	}
}

schema_decode :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> Table_Schema {
	schema: Table_Schema
	schema.name = br_read_string(r, alloc)
	schema_flags := br_read_u8(r)
	schema.ephemeral = schema_flags & (1 << 0) != 0
	schema.event = schema_flags & (1 << 1) != 0
	if r.bad do return schema
	auto_increment_column := NO_COLUMN
	column_count := int(br_read_u32(r))
	if r.bad do return schema
	columns := make([]Column, column_count, alloc)
	for i in 0 ..< column_count {
		col: Column
		col.name = br_read_string(r, alloc)
		col.type.kind = Type_Kind(br_read_u8(r))
		col.type.width = br_read_u8(r)
		if col.type.kind == .Option || col.type.kind == .Result || col.type.kind == .Array || col.type.kind == .Product {
			col.type.inner_kind = Type_Kind(br_read_u8(r))
			col.type.inner_width = br_read_u8(r)
		}
		if col.type.kind == .Result {
			col.type.right_kind = Type_Kind(br_read_u8(r))
			col.type.right_width = br_read_u8(r)
		}
		if col.type.kind == .Product {
			count := int(br_read_u8(r))
			components := make([]Column_Type, count, alloc)
			for component_index in 0 ..< count {
				components[component_index] = Column_Type {
					kind  = Type_Kind(br_read_u8(r)),
					width = br_read_u8(r),
				}
			}
			col.type.components = components
		}
		flags := br_read_u8(r)
		col.unique = flags & (1 << 1) != 0
		col.not_null = flags & (1 << 2) != 0
		col.auto_increment = flags & (1 << 3) != 0
		col.has_default = flags & (1 << 4) != 0
		if flags & (1 << 5) != 0 {
			col.named_type = br_read_string(r, alloc)
		}
		if flags & (1 << 6) != 0 {
			col.collation = br_read_string(r, alloc)
		}
		if flags & (1 << 7) != 0 {
			col.generated = true
			col.generated_sql = br_read_string(r, alloc)
		}
		if col.has_default {
			col.default_value = value_decode(r, alloc)
		}
		if col.auto_increment {
			col.sequence.start = br_read_i64(r)
			col.sequence.increment = br_read_i64(r)
			col.sequence.min = br_read_i64(r)
			col.sequence.max = br_read_i64(r)
		}
		if r.bad do return schema
		if col.auto_increment do auto_increment_column = i
		columns[i] = col
	}
	npk := int(br_read_u32(r))
	if r.bad do return schema
	primary_key := make([]int, npk, alloc)
	for i in 0 ..< npk {
		primary_key[i] = int(br_read_u32(r))
	}
	nfks := int(br_read_u32(r))
	if r.bad do return schema
	fks := make([]Foreign_Key, nfks, alloc)
	for i in 0 ..< nfks {
		fk: Foreign_Key
		fk.name = br_read_string(r, alloc)
		fk.on_delete = Foreign_Key_Action(br_read_u8(r))
		fk.on_update = Foreign_Key_Action(br_read_u8(r))
		fk.ref_table = br_read_string(r, alloc)
		ncols := int(br_read_u32(r))
		fk.columns = make([]int, ncols, alloc)
		for j in 0 ..< ncols do fk.columns[j] = int(br_read_u32(r))
		nrefs := int(br_read_u32(r))
		fk.ref_columns = make([]int, nrefs, alloc)
		for j in 0 ..< nrefs do fk.ref_columns[j] = int(br_read_u32(r))
		fks[i] = fk
	}
	schema.foreign_keys = fks
	nindexes := int(br_read_u32(r))
	if r.bad do return schema
	indexes := make([]Index_Schema, nindexes, alloc)
	for i in 0 ..< nindexes {
		idx: Index_Schema
		idx.name = br_read_string(r, alloc)
		flags := br_read_u8(r)
		idx.unique = flags & (1 << 0) != 0
		idx.implicit = flags & (1 << 1) != 0
		idx.algorithm = Index_Algorithm(br_read_u8(r))
		n := int(br_read_u32(r))
		if r.bad do return schema
		cols := make([]int, n, alloc)
		for j in 0 ..< n {
			cols[j] = int(br_read_u32(r))
		}
		idx.columns = cols
		indexes[i] = idx
	}
	schema.columns = columns
	schema.indexes = indexes
	schema.primary_key = primary_key
	schema.auto_increment_column = auto_increment_column
	return schema
}

schema_destroy :: proc(schema: ^Table_Schema, alloc: mem.Allocator) {
	for col in schema.columns {
		delete(col.name, alloc)
		if col.has_default {
			value_deep_free(col.default_value, alloc)
		}
	}
	delete(schema.columns, alloc)
	for idx in schema.indexes {
		delete(idx.name, alloc)
		delete(idx.columns, alloc)
	}
	delete(schema.indexes, alloc)
	delete(schema.primary_key, alloc)
	delete(schema.name, alloc)
	schema^ = {}
}

// schema_has_unique_column reports whether a column participates in any unique
// index, including being the primary key.
schema_column_is_unique :: proc(schema: ^Table_Schema, col: int) -> bool {
	if schema.columns[col].unique do return true
	if len(schema.primary_key) == 1 && schema.primary_key[0] == col do return true
	for idx in schema.indexes {
		if !idx.unique do continue
		if len(idx.columns) == 1 && idx.columns[0] == col do return true
	}
	return false
}

// schema_copy duplicates a schema into `alloc`.
schema_copy :: proc(schema: ^Table_Schema, alloc: mem.Allocator) -> Table_Schema {
	out := schema^
	out.name = strings.clone(schema.name, alloc)
	out.primary_key = slice.clone(schema.primary_key, alloc)
	out.columns = make([]Column, len(schema.columns), alloc)
	for col, i in schema.columns {
		out.columns[i] = col
		out.columns[i].name = strings.clone(col.name, alloc)
		if len(col.named_type) > 0 {
			out.columns[i].named_type = strings.clone(col.named_type, alloc)
		}
		if len(col.collation) > 0 {
			out.columns[i].collation = strings.clone(col.collation, alloc)
		}
		if col.generated {
			out.columns[i].generated_sql = strings.clone(col.generated_sql, alloc)
		}
		if col.has_default {
			out.columns[i].default_value = value_clone(col.default_value, alloc)
		}
		if len(col.type.components) > 0 {
			out.columns[i].type.components = slice.clone(col.type.components, alloc)
		}
	}
	out.foreign_keys = make([]Foreign_Key, len(schema.foreign_keys), alloc)
	for fk, i in schema.foreign_keys {
		out.foreign_keys[i] = fk
		out.foreign_keys[i].name = strings.clone(fk.name, alloc)
		out.foreign_keys[i].ref_table = strings.clone(fk.ref_table, alloc)
		out.foreign_keys[i].columns = slice.clone(fk.columns, alloc)
		out.foreign_keys[i].ref_columns = slice.clone(fk.ref_columns, alloc)
	}
	out.indexes = make([]Index_Schema, len(schema.indexes), alloc)
	for idx, i in schema.indexes {
		out.indexes[i] = idx
		out.indexes[i].name = strings.clone(idx.name, alloc)
		out.indexes[i].columns = slice.clone(idx.columns, alloc)
	}
	return out
}
