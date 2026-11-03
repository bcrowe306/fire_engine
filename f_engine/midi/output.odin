package midi

import "base:intrinsics"
import "core:mem"
import "core:thread"
import "core:time"

import "fire:rt"

Output_Event :: struct {
	time_ns: u64, // host clock; when the message should leave the port
	port:    Port,
	bytes:   [3]u8,
}

// Short messages from the audio thread to the OS. The audio thread pushes
// timestamped events; a sender thread hands them to the driver, which
// schedules them (CoreMIDI) or sends them at once. Timestamps should lead the
// wall clock by at least the output latency, so sending is never late.
Midi_Output :: struct {
	driver:  ^Driver,
	queue:   rt.Spsc_Queue(Output_Event),
	thread:  ^thread.Thread,
	running: bool, // atomic
	dropped: u64,  // atomic: queue full
	errors:  u64,  // atomic: driver send failed
	sent:    u64,  // atomic
}

output_init :: proc(o: ^Midi_Output, d: ^Driver, capacity := 4096, allocator := context.allocator) -> mem.Allocator_Error {
	o.driver = d
	return rt.spsc_init(&o.queue, capacity, allocator)
}

output_destroy :: proc(o: ^Midi_Output, allocator := context.allocator) {
	output_stop(o)
	rt.spsc_destroy(&o.queue, allocator)
}

output_start :: proc(o: ^Midi_Output) {
	if o.thread != nil do return
	intrinsics.atomic_store(&o.running, true)
	o.thread = thread.create_and_start_with_data(o, sender_main)
}

// Sends whatever is still queued, then joins the thread.
output_stop :: proc(o: ^Midi_Output) {
	if o.thread == nil do return
	intrinsics.atomic_store(&o.running, false)
	thread.join(o.thread)
	thread.destroy(o.thread)
	o.thread = nil
}

// [rt] Audio thread. Returns false (and counts a drop) when the queue is full.
output_push :: proc "contextless" (o: ^Midi_Output, e: Output_Event) -> bool {
	if rt.spsc_push(&o.queue, e) do return true
	intrinsics.atomic_add_explicit(&o.dropped, 1, .Relaxed)
	return false
}

// [rt] Time of frame `offset` in a block presented at `block_ns`.
frame_time_ns :: proc "contextless" (block_ns: u64, offset: int, sample_rate: f64) -> u64 {
	return block_ns + u64(f64(offset) * 1e9 / sample_rate)
}

// Events leave in queue order. For drivers that cannot schedule, the sender
// holds each one until its time (to within the ~0.5 ms polling step); the
// audio thread pushes in time order, so holding the head holds nothing back.
@(private)
sender_main :: proc(data: rawptr) {
	o := (^Midi_Output)(data)
	held: Output_Event
	holding := false
	for {
		running := intrinsics.atomic_load(&o.running)
		for {
			if !holding {
				e, ok := rt.spsc_pop(&o.queue)
				if !ok do break
				held, holding = e, true
			}
			if !o.driver.can_schedule && running && held.time_ns > rt.host_time_ns() do break // not yet due
			holding = false
			send_one(o, held)
		}
		if !running && !holding do break
		// Poll every 0.5 ms; while holding, wake at the held message's time
		// instead if that is sooner.
		wait := 500 * time.Microsecond
		if holding {
			now := rt.host_time_ns()
			if held.time_ns > now do wait = min(wait, time.Duration(held.time_ns - now))
		}
		rt.precise_sleep(wait)
	}
}

@(private)
send_one :: proc(o: ^Midi_Output, e: Output_Event) {
	n := message_length(e.bytes[0])
	if n == 0 {
		intrinsics.atomic_add(&o.errors, 1)
		return
	}
	bytes := e.bytes
	if send(o.driver, e.port, bytes[:n], e.time_ns) == .None {
		intrinsics.atomic_add(&o.sent, 1)
	} else {
		intrinsics.atomic_add(&o.errors, 1)
	}
}
