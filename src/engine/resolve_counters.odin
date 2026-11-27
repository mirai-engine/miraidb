package engine

// Resolve_Counters counts what the engine works out again while statements
// run: the name of a column, a function or a collation looked up, a text
// parsed (a statement, a policy, a view, a trigger), the names of a statement
// checked, a join order planned and a memory table's rows counted by reading
// them. The statement path (A1 in the plan) moves
// each of these out of the run, and out of the row first: these numbers are
// how a test says it did.
//
// They are per thread, so a test reads what its own statements did while the
// others run, and counting costs a plain add, not an atomic.
Resolve_Counters :: struct {
	column_names:    u64,
	function_names:  u64,
	collation_names: u64,
	parses:          u64,
	resolutions:     u64,
	plans:           u64,
	row_counts:      u64,
}

@(thread_local, private)
resolve_counted: Resolve_Counters

// resolve_counters is what this thread counted since resolve_counters_reset.
resolve_counters :: proc() -> Resolve_Counters {
	return resolve_counted
}

resolve_counters_reset :: proc() {
	resolve_counted = {}
}
