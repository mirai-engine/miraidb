package engine

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"

// Allocation failure (D23). Every allocator the engine hands out is guarded: an
// allocation the system refuses releases a ballast held for this moment and is
// tried again, so the work in flight finishes the step it is in instead of
// reading a nil. The thread is then short: the statement stops at its next
// checkpoint with Out_Of_Memory and is taken back, and the next statement runs
// only once the ballast is held again. A failure with no ballast left is what it
// was before, the caller's nil.

OOM_BALLAST_SIZE :: 4 * mem.Megabyte

@(private = "file")
oom_ballast: rawptr

// The thread spent the ballast and its statement has not answered for it yet.
@(private = "file", thread_local)
oom_short_flag: bool

// A test's injected failure: from the nth guarded allocation of this thread on,
// the system refuses every one, as a machine out of memory does, and the
// ballast is a budget of bytes rather than memory given back.
@(private = "file", thread_local)
oom_fail_from: int
@(private = "file", thread_local)
oom_calls: int
@(private = "file", thread_local)
oom_budget: int
// The statement was given its budget: the bytes the ballast gives back, whichever
// thread released it.
@(private = "file", thread_local)
oom_granted: bool

// oom_hold takes the ballast when it is not held. It is false when the system
// refuses it, which is the engine being out of memory.
oom_hold :: proc() -> bool {
	// An injected failure is this thread's machine out of memory, whatever
	// another thread holds.
	if oom_injected() do return false
	if intrinsics.atomic_load(&oom_ballast) != nil do return true
	block, err := runtime.heap_allocator_proc(nil, .Alloc_Non_Zeroed, OOM_BALLAST_SIZE, 16, nil, 0)
	if err != .None || block == nil do return false
	// Touched, so the pages are the process's and not a promise of them.
	for i := 0; i < len(block); i += 4096 do block[i] = 0
	if _, swapped := intrinsics.atomic_compare_exchange_strong(&oom_ballast, nil, raw_data(block)); !swapped {
		runtime.heap_allocator_proc(nil, .Free, 0, 0, raw_data(block), OOM_BALLAST_SIZE)
	}
	return true
}

// oom_settle is a statement's start: true when the ballast is held, which
// clears what the statement before spent of it.
oom_settle :: proc() -> bool {
	if !oom_hold() do return false
	oom_short_flag = false
	oom_granted = false
	return true
}

// oom_short is true once this thread's statement needed the ballast.
oom_short :: proc() -> bool {
	return oom_short_flag
}

// oom_error is the error a statement that ran out of memory answers.
oom_error :: proc() -> Error {
	return errf(.Out_Of_Memory, "out of memory")
}

// oom_check is a statement's checkpoint: the error when it ran out of memory.
oom_check :: proc() -> Error {
	if oom_short_flag do return oom_error()
	return ERROR_NONE
}

// oom_inject makes this thread's nth guarded allocation and every later one fail;
// zero stops it. Tests only.
oom_inject :: proc(nth: int) {
	oom_fail_from = nth
	oom_calls = 0
	oom_budget = 0
	oom_granted = false
}

// oom_injected_calls is how many guarded allocations ran since oom_inject.
oom_injected_calls :: proc() -> int {
	return oom_calls
}

@(private = "file")
oom_injected :: proc() -> bool {
	return oom_fail_from > 0 && oom_calls >= oom_fail_from
}

// oom_rescue answers a refused allocation of size bytes: true when it may be
// tried again. Releasing the ballast gives memory back to the whole process, so
// a thread that finds it released already tries again as well.
@(private = "file")
oom_rescue :: proc(size: int) -> bool {
	if block := intrinsics.atomic_exchange(&oom_ballast, nil); block != nil {
		runtime.heap_allocator_proc(nil, .Free, 0, 0, block, OOM_BALLAST_SIZE)
	}
	oom_short_flag = true
	if oom_fail_from == 0 do return true
	if !oom_granted {
		oom_granted = true
		oom_budget = OOM_BALLAST_SIZE
	}
	if oom_budget < size do return false
	oom_budget -= size
	return true
}

@(private = "file")
oom_guarded :: proc(
	backing: mem.Allocator_Proc,
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location,
) -> ([]byte, mem.Allocator_Error) {
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if oom_fail_from > 0 {
			oom_calls += 1
			if oom_injected() {
				if !oom_rescue(size) do return nil, .Out_Of_Memory
				return backing(data, mode, size, alignment, old_memory, old_size, location)
			}
		}
		block, err := backing(data, mode, size, alignment, old_memory, old_size, location)
		if err != .Out_Of_Memory || size == 0 do return block, err
		if !oom_rescue(size) do return block, err
		return backing(data, mode, size, alignment, old_memory, old_size, location)
	}
	return backing(data, mode, size, alignment, old_memory, old_size, location)
}

@(private = "file")
oom_arena_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	return oom_guarded(virtual.arena_allocator_proc, data, mode, size, alignment, old_memory, old_size, location)
}

@(private = "file")
oom_heap_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	return oom_guarded(runtime.heap_allocator_proc, data, mode, size, alignment, old_memory, old_size, location)
}

@(private = "file")
oom_wrapped_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	backing := (^mem.Allocator)(data)
	return oom_guarded(backing.procedure, backing.data, mode, size, alignment, old_memory, old_size, location)
}

// arena_allocator_guarded is virtual.arena_allocator with the engine's answer to
// a refused allocation.
arena_allocator_guarded :: proc(arena: ^virtual.Arena) -> mem.Allocator {
	return mem.Allocator{oom_arena_proc, arena}
}

// oom_heap_allocator is the heap with the engine's answer to a refused allocation.
oom_heap_allocator :: proc "contextless" () -> mem.Allocator {
	return mem.Allocator{oom_heap_proc, nil}
}

// oom_allocator guards another allocator; backing must outlive what it returns.
oom_allocator :: proc(backing: ^mem.Allocator) -> mem.Allocator {
	return mem.Allocator{oom_wrapped_proc, backing}
}

// oom_context is runtime.default_context with the guarded heap: what an entry
// point from C, or a program's main, runs the engine under.
oom_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = oom_heap_allocator()
	return ctx
}
