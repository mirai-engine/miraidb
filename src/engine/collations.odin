package engine

import "core:slice"
import "core:strings"

// A collation decides when two texts are equal and which one comes first. Three
// are built in and they are the ones the engine can *fold*: BINARY compares bytes,
// NOCASE lowercases both sides, RTRIM drops trailing spaces, and every one of them
// turns the comparison into a byte comparison of the folded text. That folding is
// what lets an index key, an `ORDER BY` key and a `GROUP BY` key order the way the
// comparison does.
//
// A host collation is a comparison a program supplies, and it cannot be folded: two
// texts may compare equal and still differ byte for byte. So a host collation is
// used where a comparison happens - `WHERE`, `ON`, `HAVING`, `CASE` - and refused
// where the engine needs a key it can order by bytes: `ORDER BY`, `GROUP BY`,
// `DISTINCT`, an index and a column declaration. A refusal is a message, not a
// quiet fallback to BINARY: a query that answers in the wrong order is worse than
// one that does not run.
//
// The registry belongs to the process, not to the log, exactly like the host
// function registry: opening a database again starts with no collations.

// Collation_Fn compares two texts and answers negative, zero or positive, the way
// `std::string::compare` and SQLite's own collations do.
Collation_Fn :: #type proc(a: string, b: string, user: rawptr) -> int

Collation_Def :: struct {
	compare: Collation_Fn,
	user:    rawptr,
}

// collation_is_builtin reports whether a name is one of the three the engine folds.
collation_is_builtin :: proc(name: string) -> bool {
	return strings.equal_fold(name, "binary") ||
		strings.equal_fold(name, "nocase") ||
		strings.equal_fold(name, "rtrim")
}

// store_register_collation adds or replaces one host collation by name,
// case-insensitively. The three built-in names are reserved: refusing them keeps a
// program from changing what `COLLATE NOCASE` means for everybody else.
store_register_collation :: proc(
	store: ^Store,
	name: string,
	compare: Collation_Fn,
	user: rawptr = nil,
) -> Error {
	if store == nil do return errf(.Invalid_Argument, "no database")
	if len(name) == 0 do return errf(.Invalid_Argument, "a collation needs a name")
	if compare == nil do return errf(.Invalid_Argument, "collation %s has no comparison", name)
	if collation_is_builtin(name) {
		return errf(.Invalid_Argument, "collation %s is built in and cannot be replaced", name)
	}
	// The map owns its keys, and `strings.to_lower` answers the argument itself when
	// it is already lower case: the map keeps a copy, and the temporary (when there
	// is one) is freed here. A lookup walks with equal_fold for the same reason the
	// function registry does - a handful of entries, no key to build per call.
	for stored, _ in store.collations {
		if strings.equal_fold(stored, name) {
			store.collations[stored] = Collation_Def{compare = compare, user = user}
			return ERROR_NONE
		}
	}
	lowercased := strings.to_lower(name)
	key := strings.clone(lowercased)
	if raw_data(lowercased) != raw_data(name) do delete(lowercased)
	store.collations[key] = Collation_Def{compare = compare, user = user}
	return ERROR_NONE
}

// store_unregister_collation drops one host collation and reports whether one was
// there. A statement that already resolved it keeps the comparison it took.
store_unregister_collation :: proc(store: ^Store, name: string) -> bool {
	if store == nil do return false
	stored_key: string
	for stored, _ in store.collations {
		if strings.equal_fold(stored, name) {
			stored_key = stored
			break
		}
	}
	if len(stored_key) == 0 do return false
	map_erase(&store.collations, stored_key)
	delete(stored_key)
	return true
}

// store_collation looks a host collation up. The name is folded, so `Spanish` and
// `spanish` are the same collation.
store_collation :: proc(store: ^Store, name: string) -> (Collation_Def, bool) {
	if store == nil do return {}, false
	for stored, def in store.collations {
		if strings.equal_fold(stored, name) do return def, true
	}
	return {}, false
}

// store_collation_count is how many host collations are registered. It exists so a
// test and the C smoke can say the registry was emptied.
store_collation_count :: proc(store: ^Store) -> int {
	if store == nil do return 0
	return len(store.collations)
}

// collation_compare answers how two texts compare under a name the engine knows.
// It is the one place that decides what a collation name means, so a comparison in
// SQL and a comparison in the C ABI cannot drift apart.
collation_compare :: proc(store: ^Store, name: string, a: string, b: string) -> (int, bool) {
	if len(name) == 0 || strings.equal_fold(name, "binary") {
		return strings.compare(a, b), true
	}
	if strings.equal_fold(name, "nocase") {
		left := strings.to_lower(a, context.temp_allocator)
		right := strings.to_lower(b, context.temp_allocator)
		return strings.compare(left, right), true
	}
	if strings.equal_fold(name, "rtrim") {
		left := strings.trim_right(a, " ")
		right := strings.trim_right(b, " ")
		return strings.compare(left, right), true
	}
	if def, found := store_collation(store, name); found {
		return def.compare(a, b, def.user), true
	}
	return 0, false
}

// collation_problem names why a collation cannot be used here, or returns the zero
// error when it can. `needs_key` is the engine saying "I am about to fold this into
// an order key", which a host collation cannot survive.
collation_problem :: proc(store: ^Store, name: string, needs_key: bool) -> Error {
	if len(name) == 0 do return ERROR_NONE
	if collation_is_builtin(name) do return ERROR_NONE
	if _, found := store_collation(store, name); found {
		if needs_key {
			return errf(
				.Sql_Unsupported,
				"collation %s cannot order, group or key: a host comparison is not a folded key, and only BINARY, NOCASE and RTRIM can be folded",
				name,
			)
		}
		return ERROR_NONE
	}
	// SQLite refuses an unknown name too: a comparison that falls back to BINARY
	// answers a question nobody asked.
	return errf(.Invalid_Argument, "no such collation: %s", name)
}

// expr_collation_problem is collation_problem over the collation an expression
// attaches, and the collation its column declares, when there is one.
expr_collation_problem :: proc(ctx: ^Eval_Ctx, expr: ^Expr, needs_key: bool) -> Error {
	name, has := collate_name(expr)
	if !has do name, has = column_collation(ctx, expr)
	if !has do return ERROR_NONE
	return collation_problem(ctx.tx != nil ? ctx.tx.store : nil, name, needs_key)
}

// Collation_Check is the state one walk carries: the database whose registry
// answers, the name of the clause for the message, and whether the engine is about
// to fold the text into a key.
Collation_Check :: struct {
	store:     ^Store,
	clause:    string,
	needs_key: bool,
	problem:   Error,
}

@(private)
collation_check_visit :: proc(expr: ^Expr, user: rawptr) -> bool {
	check := (^Collation_Check)(user)
	collate, is_collate := expr^.(Collate_Expr)
	if is_collate {
		problem := collation_problem(check.store, collate.name, check.needs_key)
		if problem.kind != .None {
			check.problem = problem
			return false
		}
	}
	// A window's PARTITION BY and ORDER BY are keys as surely as the statement's
	// own GROUP BY and ORDER BY are, so they are checked as keys.
	if window, is_window := expr^.(Window_Expr); is_window {
		nested := Collation_Check{store = check.store, clause = check.clause, needs_key = true}
		for item in window.partition do expr_walk(item, collation_check_visit, &nested)
		if nested.problem.kind != .None {
			check.problem = nested.problem
			return false
		}
		for item in window.order_by do expr_walk(item.expr, collation_check_visit, &nested)
		if nested.problem.kind != .None {
			check.problem = nested.problem
			return false
		}
	}
	// A window frame's offset is a value, not a key: it is walked with the same
	// setting the caller asked for, which is what the recursion above already did.
	return true
}

// collation_check_expr refuses a collation name inside one expression: an unknown
// name anywhere (SQLite refuses it too), and a host comparison where the engine
// needs to fold the text into a key it can order or group by.
collation_check_expr :: proc(
	store: ^Store,
	expr: ^Expr,
	clause: string,
	needs_key: bool,
) -> Error {
	if expr == nil do return ERROR_NONE
	check := Collation_Check{store = store, clause = clause, needs_key = needs_key}
	expr_walk(expr, collation_check_visit, &check)
	return check.problem
}

// select_collation_guard runs the checks a SELECT needs before it produces a row,
// so a statement that cannot honour a collation is refused instead of answering in
// the wrong order. Every clause is checked: a name nobody knows is an error
// wherever it appears, and a host comparison is refused only where a key is built.
select_collation_guard :: proc(tx: ^Tx, stmt: Select_Stmt) -> Error {
	store := tx != nil ? tx.store : nil
	for item in stmt.projections {
		// DISTINCT compares the output rows, so a projection is a key when the
		// statement asks for distinct ones.
		if err := collation_check_expr(store, item.expr, "SELECT", stmt.is_distinct); err.kind != .None {
			return err
		}
	}
	if err := collation_check_expr(store, stmt.where_clause, "WHERE", false); err.kind != .None {
		return err
	}
	for expr in stmt.group_by {
		if err := collation_check_expr(store, expr, "GROUP BY", true); err.kind != .None do return err
	}
	if err := collation_check_expr(store, stmt.having, "HAVING", false); err.kind != .None do return err
	// ORDER BY ranks a host collation's values instead of folding them (the
	// slots below), so it only refuses a name nobody knows.
	for item in stmt.order_by {
		if err := collation_check_expr(store, item.expr, "ORDER BY", false); err.kind != .None do return err
	}
	for join in stmt.joins {
		if err := collation_check_expr(store, join.on, "JOIN", false); err.kind != .None do return err
	}
	return ERROR_NONE
}

// --- ORDER BY under a host collation ----------------------------------------
//
// An order key is compared byte by byte, and a host comparison has no bytes to
// fold into. So the key gets a slot instead: the value's rank among every value
// the same ORDER BY term takes in the statement, under SQLite's order (NULL,
// then numbers, then text by the collation, then blobs). The slots are written
// with zeros while the keys are built and filled once every row is known, just
// before the sort. Two values the collation calls equal share a rank, so the
// next term or the row id decides between them, as in SQLite.

Host_Order_Slot :: struct {
	key:        []u8,
	offset:     int,
	term:       int,
	value:      Value,
	collation:  string,
	descending: bool,
}

// host_order_collation reports a term whose collation is a host one.
@(private)
host_order_collation :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (string, bool) {
	if ctx == nil || ctx.tx == nil do return "", false
	name, has := collate_name(expr)
	if !has do name, has = column_collation(ctx, expr)
	if !has || len(name) == 0 || collation_is_builtin(name) do return "", false
	if _, found := store_collation(ctx.tx.store, name); !found do return "", false
	return name, true
}

@(private = "file", thread_local)
host_sort_store: ^Store

@(private = "file")
host_value_class :: proc(v: Value) -> int {
	#partial switch v.kind {
	case .Null, .Default:
		return 0
	case .String:
		return 2
	case .Bytes:
		return 3
	}
	return 1
}

@(private = "file")
host_value_compare :: proc(a, b: ^Host_Order_Slot) -> int {
	ca, cb := host_value_class(a.value), host_value_class(b.value)
	if ca != cb do return ca < cb ? -1 : 1
	switch ca {
	case 0:
		return 0
	case 2:
		order, _ := collation_compare(host_sort_store, a.collation, a.value.s, b.value.s)
		return order
	case 3:
		return strings.compare(string(a.value.bytes), string(b.value.bytes))
	}
	order, ok := value_compare(a.value, b.value)
	if !ok do return 0
	return int(order)
}

// host_order_resolve fills every slot with its rank.
@(private)
host_order_resolve :: proc(store: ^Store, slots: []Host_Order_Slot) {
	if len(slots) == 0 do return
	host_sort_store = store
	defer host_sort_store = nil
	order := make([]^Host_Order_Slot, len(slots), context.temp_allocator)
	for &slot, i in slots do order[i] = &slot
	slice.sort_by(order, proc(a, b: ^Host_Order_Slot) -> bool {
		if a.term != b.term do return a.term < b.term
		return host_value_compare(a, b) < 0
	})
	rank: u64 = 0
	for slot, i in order {
		if i > 0 {
			previous := order[i - 1]
			if previous.term != slot.term {
				rank = 0
			} else if host_value_compare(previous, slot) != 0 {
				rank += 1
			}
		}
		for b in 0 ..< 8 {
			byte := u8(rank >> uint(56 - 8 * b))
			slot.key[slot.offset + b] = slot.descending ? ~byte : byte
		}
	}
}
