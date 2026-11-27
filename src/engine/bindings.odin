package engine

import "core:mem"
import "core:reflect"

// The resolved statement (A1.8): what the resolution works out for a node of
// the parse lives beside the tree, in an array read by the node's number, so a
// run reads it with an index and a comparison instead of looking a name up per
// row. A map keyed by the node was tried first and lost: on a narrow table its
// hash, probe and check cost what the name lookup it saved did.

// Column_Binding is the column a reference names among its own query's
// sources: the FROM item it is in (`from`, in the order the statement writes
// them), its position in that table's schema, and the schema's identity
// (Table_Schema.ident), which the run checks so a source that is not the one
// resolved (a frame the plan laid out otherwise, a copy with another shape)
// falls back to the lookup by name and never to another column's value.
// `column` < 0 is no link: the reference names something else (an enclosing
// query's row, a view's or a CTE's column, a hidden column, a column USING
// shares) and is resolved by name, as before.
Column_Binding :: struct {
	ident:  u32,
	from:   u16,
	column: i32,
}

// Call_Kind is what a call reaches, decided by its resolution (A1.8d). .None
// is no link: the call is found by its name when it runs, as before (an
// aggregate, a min or max of several arguments, grouping, RAISE, a call with
// FILTER or ORDER BY, a call outside a kept statement).
Call_Kind :: enum u8 {
	None,
	// Host is a program's function registered to answer before a builtin of
	// its name (Scalar_Function_Def.overrides), kept in the link.
	Host,
	Json,
	Time,
	// Builtin is one of the engine's scalar functions, or a name it does not
	// have, which its dispatch hands to the program's functions at the end.
	Builtin,
}

// Call_Link is the function a call reaches: its kind, and for a builtin the
// name the dispatch switches on, lowered and with SQLite's other spellings
// made the engine's (`lowered` is the name as written, lowered, for the words
// of an error). The registry it was read from is part of the catalog: a
// function registered or dropped moves the generation, so a link never
// outlives the function it names.
Call_Link :: struct {
	kind:     Call_Kind,
	lowered:  string,
	dispatch: string,
	host:     Scalar_Function_Def,
}

// Statement_Bindings are the links of one parsed query: `columns[id - base]`
// and `calls[id - base]` for a node of its block (Node_Id).
Statement_Bindings :: struct {
	base:    Node_Id,
	columns: []Column_Binding,
	calls:   []Call_Link,
}

// statement_resolve checks the names `statement` uses (sql_resolve_names) and
// makes the links of `query`, the parse it is the tree of, which are then the
// transaction's for the statement (Tx.bindings; the caller gives the previous
// ones back). Without a query, what the resolution rewrites lives in the
// transaction's arena and no link is made.
//
// A kept tree is resolved once per catalog generation (A1.8c): what the
// resolution works out depends on the catalog alone, so a run at the
// generation its last resolution held for takes the statement as that
// resolution left it, and its links, instead of walking the tree again. Only
// the query's own statement is kept so: a part of it run on its own (a write's
// body without its CTEs, the statement an attached database runs) is resolved
// as before.
@(private)
statement_resolve :: proc(tx: ^Tx, statement: ^Statement, query: ^Query) -> Error {
	if query == nil {
		tx.bindings = nil
		return sql_resolve_names(tx, statement, tx.alloc)
	}
	bindings := &query.bindings
	root := statement_is_root(statement, query)
	generation, holds := tx_catalog_generation(tx)
	if root && holds && query.resolved_at == generation + 1 {
		statement^ = query.resolved
		tx.bindings = bindings
		return ERROR_NONE
	}
	if root do query.resolved_at = 0
	alloc := arena_allocator_guarded(&query.arena)
	count := int(query.node_count) + 1
	if len(bindings.columns) != count {
		bindings.base = query.node_base
		bindings.columns = make([]Column_Binding, count, alloc)
		bindings.calls = make([]Call_Link, count, alloc)
	}
	for &binding in bindings.columns do binding = Column_Binding{column = -1}
	for &link in bindings.calls do link = {}
	tx.bindings = bindings
	err := sql_resolve_names(tx, statement, alloc, bindings)
	// The catalog is read again after the walk: one that moved during it (an
	// attached database's, read live) leaves nothing kept.
	if root && err.kind == .None && holds {
		if after, still := tx_catalog_generation(tx); still && after == generation {
			query.resolved = statement^
			query.resolved_at = generation + 1
		}
	}
	return err
}

// column_bound is the source and column a linked reference reads, when the
// link holds for the context's sources: the FROM item's source, at the
// position the plan runs it in (Eval_Ctx.positions), with the schema the link
// was made against. Anything else answers false and the caller looks the name
// up.
column_bound :: #force_inline proc(ctx: ^Eval_Ctx, id: Node_Id) -> (source: ^Source, column: int, ok: bool) {
	bindings := ctx.bindings
	if bindings == nil || id <= bindings.base do return nil, -1, false
	local := id - bindings.base
	if local >= Node_Id(len(bindings.columns)) do return nil, -1, false
	binding := bindings.columns[local]
	if binding.column < 0 do return nil, -1, false
	at := int(binding.from)
	if ctx.positions != nil {
		if at >= len(ctx.positions) do return nil, -1, false
		at = ctx.positions[at]
	}
	if at >= len(ctx.sources) do return nil, -1, false
	source = &ctx.sources[at]
	if source.table == nil || source.table.schema.ident != binding.ident do return nil, -1, false
	return source, int(binding.column), true
}

// statement_is_root says `statement` is the query's own statement as parsed,
// not a part of it: the same variant with the same bytes. Only the variant's
// own bytes are compared, since a variant made into a Statement again leaves
// the rest of the union as it finds it.
@(private)
statement_is_root :: proc(statement: ^Statement, query: ^Query) -> bool {
	kind := reflect.union_variant_typeid(statement^)
	if kind == nil || kind != reflect.union_variant_typeid(query.statement) do return false
	return mem.compare_ptrs(statement, &query.statement, type_info_of(kind).size) == 0
}

// call_bound is the link of a call, when its resolution made one.
call_bound :: #force_inline proc(ctx: ^Eval_Ctx, id: Node_Id) -> (^Call_Link, bool) {
	bindings := ctx.bindings
	if bindings == nil || id <= bindings.base do return nil, false
	local := id - bindings.base
	if local >= Node_Id(len(bindings.calls)) do return nil, false
	link := &bindings.calls[local]
	return link, link.kind != .None
}
