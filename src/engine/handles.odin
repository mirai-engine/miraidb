package engine

import "core:sync"

// --- Live handles -----------------------------------------------------------
//
// A C ABI hands out opaque pointers. Asking whether one is still valid by
// dereferencing it is the bug this file exists to prevent: after finalize the
// memory is free, so the only safe question is "is this pointer in the live
// set", which is answered by value and never touches what it points at (D29).
//
// Both embedding layers (the miraidb_* ABI and the sqlite3_* facade) register
// their handles here, and every entry point asks before it dereferences. A
// handle that was forgotten answers "not live", which the layer reports as a
// misuse error instead of reading freed memory.

@(private)
handles_mutex: sync.Mutex

@(private)
live_handles: map[rawptr]bool

handle_register :: proc(handle: rawptr) {
	if handle == nil do return
	sync.lock(&handles_mutex)
	defer sync.unlock(&handles_mutex)
	if live_handles == nil do live_handles = make(map[rawptr]bool)
	live_handles[handle] = true
}

handle_is_live :: proc(handle: rawptr) -> bool {
	if handle == nil do return false
	sync.lock(&handles_mutex)
	defer sync.unlock(&handles_mutex)
	if live_handles == nil do return false
	return live_handles[handle]
}

// handle_forget removes a handle and reports whether it was live, which is how a
// double finalize is told apart from a finalize of something this layer never
// handed out.
handle_forget :: proc(handle: rawptr) -> bool {
	if handle == nil do return false
	sync.lock(&handles_mutex)
	defer sync.unlock(&handles_mutex)
	if live_handles == nil do return false
	was := live_handles[handle]
	delete_key(&live_handles, handle)
	return was
}
