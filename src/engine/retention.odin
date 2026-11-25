package engine

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

// Version retention (D3). A commit that replaces a value keeps the old one, so a
// read at an older sequence (`AS OF`, a pinned read) still sees it. How much of
// that history a store keeps is its retention, and after each commit the store
// drops what the retention no longer needs: with a store that never pruned, an
// embedded process that updated rows kept every value it ever replaced.
//
// - Everything: nothing is dropped (a store opened by the engine's own API).
// - Readers: only what a pinned read is reading (the CLI, the C ABI and the
//   `sqlite3_*` facade, where nothing names an older commit).
// - Commits: what an `AS OF` up to `amount` commits back reads.
// - Seconds: what an `AS OF` at a commit of the last `amount` seconds reads.
//
// A read transaction shares the tables it reads, and a prune skips a shared
// table (store_prune_table); a pinned read holds the store's lock, which the
// prune only tries. Neither loses a version it needs.

Retention_Kind :: enum u8 {
	Everything,
	Readers,
	Commits,
	Seconds,
}

Retention :: struct {
	kind:   Retention_Kind,
	amount: u64,
}

@(private)
Commit_Time :: struct {
	seq: u64,
	us:  i64,
}

// store_set_retention sets how much history the store keeps from the next
// commit on.
store_set_retention :: proc(store: ^Store, retention: Retention) {
	if store == nil do return
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	store.retention = retention
	if retention.kind != .Seconds do clear(&store.commit_times)
}

store_retention :: proc(store: ^Store) -> Retention {
	if store == nil do return {}
	return store.retention
}

// retention_parse reads the text PRAGMA history_retention takes: `everything`
// (or `all`), `readers` (or `none`), `commits=N` and `seconds=N`.
retention_parse :: proc(text: string) -> (Retention, bool) {
	// Not a switch: scripts/function_table.py reads a switch's labels as the
	// names of functions.
	lowered := strings.to_lower(strings.trim(strings.trim_space(text), "'\""), context.temp_allocator)
	if lowered == "everything" || lowered == "all" do return {kind = .Everything}, true
	if lowered == "readers" || lowered == "none" do return {kind = .Readers}, true
	name, _, amount_text := strings.partition(lowered, "=")
	amount, ok := strconv.parse_u64(strings.trim_space(amount_text))
	if !ok do return {}, false
	name = strings.trim_space(name)
	if name == "commits" do return {kind = .Commits, amount = amount}, true
	if name == "seconds" do return {kind = .Seconds, amount = amount}, true
	return {}, false
}

// retention_format is the text PRAGMA history_retention answers.
retention_format :: proc(retention: Retention, alloc := context.temp_allocator) -> string {
	switch retention.kind {
	case .Everything:
		return strings.clone("everything", alloc)
	case .Readers:
		return strings.clone("readers", alloc)
	case .Commits:
		return fmt.aprintf("commits=%d", retention.amount, allocator = alloc)
	case .Seconds:
		return fmt.aprintf("seconds=%d", retention.amount, allocator = alloc)
	}
	return strings.clone("everything", alloc)
}

// store_note_commit_time remembers when a commit landed, for a retention in
// seconds. The caller holds the store's lock.
@(private)
store_note_commit_time :: proc(store: ^Store, seq: u64, us: i64) {
	if store.retention.kind != .Seconds do return
	append(&store.commit_times, Commit_Time{seq = seq, us = us})
}

// store_retain drops the history the retention no longer keeps. It runs after
// a commit, once the commit's lock is released, and only tries the lock: a
// statement or a pinned read holding it means the next commit prunes instead.
store_retain :: proc(store: ^Store) {
	if store == nil || store.retention.kind == .Everything do return
	if !sync.rw_mutex_try_lock(&store.mutex) do return
	defer sync.unlock(&store.mutex)
	cutoff := store.commit_seq
	#partial switch store.retention.kind {
	case .Commits:
		cutoff = store.commit_seq > store.retention.amount ? store.commit_seq - store.retention.amount : 0
	case .Seconds:
		// The state at the last commit older than the window is what an AS OF at
		// the window's start reads; the commits before it are not needed.
		horizon := now_microseconds() - i64(store.retention.amount) * 1_000_000
		cutoff = 0
		kept := 0
		for entry, i in store.commit_times {
			if entry.us >= horizon do break
			cutoff = entry.seq
			kept = i
		}
		if cutoff > 0 do remove_range(&store.commit_times, 0, kept)
	}
	for pinned in store.pinned_reads do cutoff = min(cutoff, pinned)
	if cutoff == 0 do return
	for _, table in store.tables do store_prune_table(table, cutoff)
}
