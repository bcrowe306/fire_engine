package midi

import "base:intrinsics"
import "core:mem"

import "fire:rt"

// Complete SysEx messages from driver threads to the control thread. One
// producer at a time (Midi_Input serializes its drivers) and one consumer.
// Payloads (without F0/F7) live in a byte ring; descriptors in an SPSC queue.
// Fields are internal.
Sysex_Queue :: struct {
	bytes:   []u8, // power-of-two length
	mask:    u64, // len(bytes) - 1
	write:   u64, // producer only
	read:    u64, // atomic; advanced by the consumer
	descs:   rt.Spsc_Queue(Sysex_Desc), // one per queued message
	dropped: u64, // atomic
}

// Where one queued message's payload lies in the byte ring.
@(private)
Sysex_Desc :: struct {
	time_ns: u64,
	port:    u8,
	start:   u64,
	len:     int,
}

// One complete SysEx message, returned by `sysex_pop`.
Sysex_Message :: struct {
	time_ns: u64, // host clock time of arrival (of the final byte)
	port:    u8, // port index given at open
	data:    []u8, // payload without F0/F7; owned by the caller of sysex_pop
}

// Control thread. Allocates a byte ring of at least `byte_capacity` bytes
// (rounded up to a power of two) and room for `message_capacity` messages.
// Free with `sysex_queue_destroy` and the same allocator.
sysex_queue_init :: proc(q: ^Sysex_Queue, byte_capacity, message_capacity: int, allocator := context.allocator) -> mem.Allocator_Error {
	cap := 1
	for cap < byte_capacity do cap <<= 1
	q.bytes = make([]u8, cap, allocator) or_return
	q.mask = u64(cap - 1)
	q.write, q.read, q.dropped = 0, 0, 0
	return rt.spsc_init(&q.descs, message_capacity, allocator)
}

// Control thread. Frees what `sysex_queue_init` allocated.
sysex_queue_destroy :: proc(q: ^Sysex_Queue, allocator := context.allocator) {
	delete(q.bytes, allocator)
	rt.spsc_destroy(&q.descs, allocator)
	q.bytes = nil
}

// Producer (driver thread). No allocation. Returns false (and counts a drop)
// when full.
sysex_push :: proc "contextless" (q: ^Sysex_Queue, time_ns: u64, port: u8, payload: []u8) -> bool {
	free := u64(len(q.bytes)) - (q.write - intrinsics.atomic_load_explicit(&q.read, .Acquire))
	if u64(len(payload)) > free || rt.spsc_len(&q.descs) >= rt.spsc_capacity(&q.descs) {
		intrinsics.atomic_add_explicit(&q.dropped, 1, .Relaxed)
		return false
	}
	for b, i in payload do q.bytes[(q.write + u64(i)) & q.mask] = b
	desc := Sysex_Desc{time_ns, port, q.write, len(payload)}
	q.write += u64(len(payload))
	rt.spsc_push(&q.descs, desc) // publishes the bytes (release)
	return true
}

// Consumer (control thread). Returns the oldest message; its `data` is
// allocated with `allocator` and owned by the caller. ok = false when the queue
// is empty (or the allocation failed, which discards the message).
sysex_pop :: proc(q: ^Sysex_Queue, allocator := context.allocator) -> (msg: Sysex_Message, ok: bool) {
	desc := rt.spsc_pop(&q.descs) or_return
	data, err := make([]u8, desc.len, allocator)
	if err == nil {
		for &b, i in data do b = q.bytes[(desc.start + u64(i)) & q.mask]
	}
	intrinsics.atomic_store_explicit(&q.read, desc.start + u64(desc.len), .Release)
	if err != nil do return {}, false
	return {desc.time_ns, desc.port, data}, true
}

// [rt] Any thread. Messages dropped so far: too long, malformed, or lost to a
// full queue.
sysex_dropped :: proc "contextless" (q: ^Sysex_Queue) -> u64 {
	return intrinsics.atomic_load_explicit(&q.dropped, .Relaxed)
}
