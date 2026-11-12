package engine

// The commit queue sits between prepared transactions and the group commit. It
// serves the highest priority first, first-in first-out inside a priority, and
// promotes a low-priority entry that waited COMMIT_QUEUE_AGING drains, so a
// steady stream of high-priority work cannot starve the rest.

import "core:sync"

COMMIT_QUEUE_AGING :: 16

Commit_Priority :: enum u8 {
	Low,
	Normal,
	High,
}

Commit_Entry :: struct {
	prepared: ^Prepared_Tx,
	priority: Commit_Priority,
	// waited counts the drains this entry survived.
	waited:  int,
	arrival: u64,
}

Commit_Queue :: struct {
	mutex:        sync.Mutex,
	entries:      [dynamic]Commit_Entry,
	next_arrival: u64,
	promoted:     u64,
}

Commit_Queue_Stats :: struct {
	pending:  int,
	promoted: u64,
}

// commit_queue_push hands a prepared transaction to the queue. The queue owns it
// from then on: store_commit_queue destroys every entry it takes.
commit_queue_push :: proc(
	queue: ^Commit_Queue,
	prepared: ^Prepared_Tx,
	priority := Commit_Priority.Normal,
) -> u64 {
	sync.lock(&queue.mutex)
	defer sync.unlock(&queue.mutex)
	arrival := queue.next_arrival
	queue.next_arrival += 1
	append(
		&queue.entries,
		Commit_Entry{prepared = prepared, priority = priority, arrival = arrival},
	)
	return arrival
}

commit_queue_len :: proc(queue: ^Commit_Queue) -> int {
	sync.lock(&queue.mutex)
	defer sync.unlock(&queue.mutex)
	return len(queue.entries)
}

commit_queue_stats :: proc(queue: ^Commit_Queue) -> Commit_Queue_Stats {
	sync.lock(&queue.mutex)
	defer sync.unlock(&queue.mutex)
	return Commit_Queue_Stats{pending = len(queue.entries), promoted = queue.promoted}
}

// commit_queue_rank is the sort key. An entry that waited COMMIT_QUEUE_AGING
// drains competes at the highest priority; ties go to the earlier arrival, so
// the aged entry is served before any fresher work and the wait is bounded.
@(private)
commit_queue_rank :: proc(entry: Commit_Entry) -> (priority: int, arrival: u64) {
	if entry.waited >= COMMIT_QUEUE_AGING {
		return int(Commit_Priority.High), entry.arrival
	}
	return int(entry.priority), entry.arrival
}

// commit_queue_drain removes up to `max` entries in service order. Everything
// that stays behind ages by one round.
commit_queue_drain :: proc(queue: ^Commit_Queue, max_entries: int) -> []^Prepared_Tx {
	sync.lock(&queue.mutex)
	defer sync.unlock(&queue.mutex)
	out := make([dynamic]^Prepared_Tx, 0, max_entries)
	for len(out) < max_entries && len(queue.entries) > 0 {
		best := 0
		best_priority, best_arrival := commit_queue_rank(queue.entries[0])
		for entry, index in queue.entries {
			priority, arrival := commit_queue_rank(entry)
			if priority > best_priority || (priority == best_priority && arrival < best_arrival) {
				best = index
				best_priority = priority
				best_arrival = arrival
			}
		}
		entry := queue.entries[best]
		if best_priority > int(entry.priority) do queue.promoted += 1
		unordered_remove(&queue.entries, best)
		append(&out, entry.prepared)
	}
	for &entry in queue.entries do entry.waited += 1
	return out[:]
}

commit_queue_destroy :: proc(queue: ^Commit_Queue) {
	sync.lock(&queue.mutex)
	defer sync.unlock(&queue.mutex)
	delete(queue.entries)
	queue.entries = nil
}
