package rt

import "base:intrinsics"
import "core:mem"

// Bounded lock-free multi-producer / multi-consumer queue (Vyukov's design:
// each cell carries a sequence number saying whose turn it is). Any thread
// may push and pop. Capacity is rounded up to a power of two.
Mpmc_Queue :: struct($T: typeid) {
	cells: []Mpmc_Cell(T),
	mask:  u64,
	_:     [CACHE_LINE]u8,
	head:  u64, // next position to push
	_:     [CACHE_LINE - size_of(u64)]u8,
	tail:  u64, // next position to pop
	_:     [CACHE_LINE - size_of(u64)]u8,
}

@(private)
Mpmc_Cell :: struct($T: typeid) {
	sequence: u64,
	value:    T,
}

// Control thread. Allocates room for at least `capacity` items (rounded up to
// a power of two, minimum 2) with `allocator`. Free with `mpmc_destroy`.
mpmc_init :: proc(q: ^Mpmc_Queue($T), capacity: int, allocator := context.allocator) -> mem.Allocator_Error {
	assert(capacity > 0)
	cap := 2
	for cap < capacity do cap <<= 1
	q.cells = make([]Mpmc_Cell(T), cap, allocator) or_return
	for &c, i in q.cells do c.sequence = u64(i)
	q.mask = u64(cap - 1)
	q.head, q.tail = 0, 0
	return nil
}

// Control thread. Frees the cells; pass the allocator given to `mpmc_init`.
// No thread may use the queue afterwards.
mpmc_destroy :: proc(q: ^Mpmc_Queue($T), allocator := context.allocator) {
	delete(q.cells, allocator)
	q.cells = nil
}

// [rt] Any thread. Copies `value` in; returns false (and drops it) if full.
// Lock-free: may retry under contention but never blocks.
mpmc_push :: proc "contextless" (q: ^Mpmc_Queue($T), value: T) -> bool {
	pos := intrinsics.atomic_load_explicit(&q.head, .Relaxed)
	for {
		cell := &q.cells[pos & q.mask]
		seq := intrinsics.atomic_load_explicit(&cell.sequence, .Acquire)
		diff := i64(seq) - i64(pos)
		if diff == 0 {
			if _, ok := intrinsics.atomic_compare_exchange_weak_explicit(&q.head, pos, pos + 1, .Relaxed, .Relaxed); ok {
				cell.value = value
				intrinsics.atomic_store_explicit(&cell.sequence, pos + 1, .Release)
				return true
			}
		} else if diff < 0 {
			return false // full: the cell still holds an unpopped value
		}
		pos = intrinsics.atomic_load_explicit(&q.head, .Relaxed)
	}
}

// [rt] Any thread. Takes the oldest value; returns false if empty.
// Lock-free: may retry under contention but never blocks.
mpmc_pop :: proc "contextless" (q: ^Mpmc_Queue($T)) -> (value: T, ok: bool) {
	pos := intrinsics.atomic_load_explicit(&q.tail, .Relaxed)
	for {
		cell := &q.cells[pos & q.mask]
		seq := intrinsics.atomic_load_explicit(&cell.sequence, .Acquire)
		diff := i64(seq) - i64(pos + 1)
		if diff == 0 {
			if _, won := intrinsics.atomic_compare_exchange_weak_explicit(&q.tail, pos, pos + 1, .Relaxed, .Relaxed); won {
				value = cell.value
				intrinsics.atomic_store_explicit(&cell.sequence, pos + q.mask + 1, .Release)
				return value, true
			}
		} else if diff < 0 {
			return {}, false // empty: the cell has not been written for this lap
		}
		pos = intrinsics.atomic_load_explicit(&q.tail, .Relaxed)
	}
}

// [rt] Maximum number of items the queue holds (the rounded-up capacity).
mpmc_capacity :: proc "contextless" (q: ^Mpmc_Queue($T)) -> int {
	return len(q.cells)
}
