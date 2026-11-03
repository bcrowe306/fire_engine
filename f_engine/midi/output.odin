package midi

import "base:intrinsics"
import "core:mem"
import "core:thread"
import "core:time"

import "fire:core"
import "fire:rt"

// One short message for `output_push`.
Output_Event :: struct {
	time_ns: u64, // host clock; when the message should leave the port
	port:    Port, // an output or virtual output of the Midi_Output's driver
	bytes:   [3]u8, // MIDI 1.0 short message; unused bytes are ignored
}

// Short messages from the audio thread to the OS. The audio thread pushes
// timestamped events; a sender thread hands them to the driver, which
// schedules them (CoreMIDI) or sends them at once. Timestamps should lead the
// wall clock by at least the output latency, so sending is never late.
//
// Set up with `output_init`, then `output_start`; free with `output_destroy`.
// The counters may be read atomically from any thread.
Midi_Output :: struct {
	driver:  ^Driver, // driver the sender thread sends through
	queue:   rt.Spsc_Queue(Output_Event), // audio thread → sender thread
	thread:  ^thread.Thread, // sender thread; nil when stopped
	running: bool, // atomic
	dropped: u64,  // atomic: queue full
	errors:  u64,  // atomic: driver send failed
	sent:    u64,  // atomic
}

// Control thread. Allocates a queue of `capacity` events for sending through
// driver `d`. Does not start the sender thread (see `output_start`).
output_init :: proc(o: ^Midi_Output, d: ^Driver, capacity := 4096, allocator := context.allocator) -> mem.Allocator_Error {
	o.driver = d
	return rt.spsc_init(&o.queue, capacity, allocator)
}

// Control thread. Stops the sender (sending what is queued) and frees the
// queue. Use the allocator given to `output_init`.
output_destroy :: proc(o: ^Midi_Output, allocator := context.allocator) {
	output_stop(o)
	rt.spsc_destroy(&o.queue, allocator)
}

// Control thread. Starts the high-priority sender thread. Does nothing if it
// is already running.
output_start :: proc(o: ^Midi_Output) {
	if o.thread != nil do return
	intrinsics.atomic_store(&o.running, true)
	// High priority: messages held for drivers that cannot schedule leave
	// when this thread wakes.
	o.thread = thread.create_and_start_with_data(o, sender_main, priority = .High)
}

// Control thread. Sends whatever is still queued, then joins the thread.
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

// [rt] Pushes the `core.Midi_Raw` events among `events` (offsets into a
// block presented at `block_ns`) to `o`, each to `ports[raw.port]`. Other
// event kinds, and port indexes outside `ports`, are skipped. Returns how
// many were queued. Use it to send a graph's MIDI output:
//
//	midi.output_push_events(&out, core.event_writer_events(&writer), ports[:], block.output_ns, sample_rate)
output_push_events :: proc "contextless" (o: ^Midi_Output, events: []core.Event, ports: []Port, block_ns: u64, sample_rate: f64) -> (pushed: int) {
	for e in events {
		raw := e.payload.(core.Midi_Raw) or_continue
		if int(raw.port) >= len(ports) do continue
		if output_push(o, {frame_time_ns(block_ns, int(e.offset), sample_rate), ports[raw.port], raw.bytes}) do pushed += 1
	}
	return
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
