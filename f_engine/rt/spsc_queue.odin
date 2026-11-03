package rt

import "base:intrinsics"
import "core:mem"

// Assumed cache line size in bytes, used to pad shared atomics apart and
// avoid false sharing.
CACHE_LINE :: 64

// Bounded lock-free single-producer / single-consumer queue.
// Exactly one thread may push and exactly one (other) thread may pop.
// Capacity is rounded up to a power of two.
Spsc_Queue :: struct($T: typeid) {
	buffer: []T,
	mask:   u64,
	_:      [CACHE_LINE]u8,
	head:   u64, // written by consumer only
	_:      [CACHE_LINE - size_of(u64)]u8,
	tail:   u64, // written by producer only
	_:      [CACHE_LINE - size_of(u64)]u8,
}

// Control thread. Allocates room for at least `capacity` items (rounded up to
// a power of two) with `allocator`. Free with `spsc_destroy`.
spsc_init :: proc(q: ^Spsc_Queue($T), capacity: int, allocator := context.allocator) -> mem.Allocator_Error {
	assert(capacity > 0)
	cap := 1
	for cap < capacity do cap <<= 1
	q.buffer = make([]T, cap, allocator) or_return
	q.mask = u64(cap - 1)
	q.head = 0
	q.tail = 0
	return nil
}

// Control thread. Frees the buffer; pass the allocator given to `spsc_init`.
// Neither endpoint may use the queue afterwards.
spsc_destroy :: proc(q: ^Spsc_Queue($T), allocator := context.allocator) {
	delete(q.buffer, allocator)
	q.buffer = nil
}

// [rt] Producer side. Copies `value` in; returns false (and drops it) if full.
spsc_push :: proc "contextless" (q: ^Spsc_Queue($T), value: T) -> bool {
	tail := intrinsics.atomic_load_explicit(&q.tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&q.head, .Acquire)
	if tail - head > q.mask do return false
	q.buffer[tail & q.mask] = value
	intrinsics.atomic_store_explicit(&q.tail, tail + 1, .Release)
	return true
}

// [rt] Consumer side. Takes the oldest value; returns false if empty.
spsc_pop :: proc "contextless" (q: ^Spsc_Queue($T)) -> (value: T, ok: bool) {
	head := intrinsics.atomic_load_explicit(&q.head, .Relaxed)
	tail := intrinsics.atomic_load_explicit(&q.tail, .Acquire)
	if head == tail do return {}, false
	value = q.buffer[head & q.mask]
	intrinsics.atomic_store_explicit(&q.head, head + 1, .Release)
	return value, true
}

// [rt] Number of queued items. Approximate; exact only when called from
// either endpoint thread.
spsc_len :: proc "contextless" (q: ^Spsc_Queue($T)) -> int {
	tail := intrinsics.atomic_load_explicit(&q.tail, .Acquire)
	head := intrinsics.atomic_load_explicit(&q.head, .Acquire)
	return int(tail - head)
}

// [rt] Maximum number of items the queue holds (the rounded-up capacity).
spsc_capacity :: proc "contextless" (q: ^Spsc_Queue($T)) -> int {
	return len(q.buffer)
}
