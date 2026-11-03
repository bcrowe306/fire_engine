package test_midi

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:testing"
import "core:thread"
import "core:time"

import "fire:core"
import "fire:midi"
import "fire:rt"
import kit "fire:testkit"

// --- messages and UMP ------------------------------------------------------------

@(test)
message_lengths :: proc(t: ^testing.T) {
	cases := [][2]int{
		{0x00, 0}, {0x7F, 0}, {0x80, 3}, {0x9F, 3}, {0xA0, 3}, {0xB5, 3}, {0xC0, 2}, {0xDF, 2}, {0xE3, 3},
		{0xF0, 0}, {0xF1, 2}, {0xF2, 3}, {0xF3, 2}, {0xF4, 0}, {0xF6, 1}, {0xF7, 0}, {0xF8, 1}, {0xFE, 1}, {0xFF, 1},
	}
	for c in cases do testing.expectf(t, midi.message_length(u8(c[0])) == c[1], "status %2X: length %d, want %d", c[0], midi.message_length(u8(c[0])), c[1])
}

@(test)
ump_short_round_trip :: proc(t: ^testing.T) {
	for status in 0x80 ..= 0xFF {
		n := midi.message_length(u8(status))
		bytes := [3]u8{u8(status), 0x12, 0x7F}
		word, ok := midi.ump_from_short(bytes, 3)
		testing.expect_value(t, ok, n > 0)
		if !ok do continue
		testing.expect_value(t, midi.ump_word_count(word), 1)
		testing.expect_value(t, (word >> 24) & 0xF, 3) // group
		back, back_ok := midi.ump_to_short(word)
		testing.expect(t, back_ok)
		want := bytes
		if n < 3 do want[2] = 0
		if n < 2 do want[1] = 0
		testing.expectf(t, back == want, "status %2X: %v → %8X → %v", status, bytes, word, back)
	}
	// Known encoding from the UMP spec: note on, channel 1, key 60, velocity 100.
	word, _ := midi.ump_from_short({0x90, 60, 100})
	testing.expect_value(t, word, 0x2090_3C64)
}

@(test)
sysex_packets_round_trip :: proc(t: ^testing.T) {
	storage: [64]u8
	for n in ([]int{0, 1, 5, 6, 7, 12, 13, 40}) {
		payload := make([]u8, n, context.temp_allocator)
		for &b, i in payload do b = u8(i * 7 + 1) & 0x7F
		a := midi.Sysex_Assembler{buffer = storage[:]}
		count := midi.ump_sysex_packet_count(n)
		result: midi.Sysex_Result
		for i in 0 ..< count {
			words := midi.ump_sysex_packet(payload, i)
			testing.expect_value(t, midi.ump_word_count(words[0]), 2)
			result = midi.sysex_assemble(&a, words)
			if i < count - 1 do testing.expect_value(t, result, midi.Sysex_Result.None)
		}
		testing.expectf(t, result == .Complete, "len %d: result %v", n, result)
		got := midi.assembler_message(&a)
		testing.expectf(t, len(got) == n && mem.compare(got, payload) == 0, "len %d: payload mismatch %v", n, got)
	}
}

@(test)
sysex_overflow_and_orphans_are_dropped :: proc(t: ^testing.T) {
	storage: [8]u8
	a := midi.Sysex_Assembler{buffer = storage[:]}
	payload: [20]u8
	results: [dynamic]midi.Sysex_Result
	results.allocator = context.temp_allocator
	for i in 0 ..< midi.ump_sysex_packet_count(20) do append(&results, midi.sysex_assemble(&a, midi.ump_sysex_packet(payload[:], i)))
	testing.expect_value(t, results[len(results) - 1], midi.Sysex_Result.Dropped)

	// A Continue without a Start is malformed.
	orphan := midi.ump_sysex_packet(payload[:], 1)
	testing.expect_value(t, midi.sysex_assemble(&a, orphan), midi.Sysex_Result.Dropped)
}

// --- input decoding and scheduling -------------------------------------------------

SR :: 48_000.0
NS_PER_FRAME :: 1e9 / SR

make_input :: proc(t: ^testing.T, cfg := midi.Input_Config{}) -> ^midi.Midi_Input {
	in_ := new(midi.Midi_Input)
	testing.expect_value(t, midi.input_init(in_, cfg), mem.Allocator_Error.None)
	return in_
}

free_input :: proc(in_: ^midi.Midi_Input) {
	midi.input_destroy(in_)
	free(in_)
}

collect :: proc(in_: ^midi.Midi_Input, block_ns: u64, frames: int) -> []core.Event {
	buf := make([]core.Event, 256, context.temp_allocator)
	w := core.Event_Writer{buffer = buf}
	midi.input_process(in_, block_ns, frames, SR, &w)
	return core.event_writer_events(&w)
}

@(test)
ump_input_is_decoded_with_sysex_separate :: proc(t: ^testing.T) {
	in_ := make_input(t)
	defer free_input(in_)

	words: [dynamic]u32
	words.allocator = context.temp_allocator
	note, _ := midi.ump_from_short({0x91, 64, 90})
	clock, _ := midi.ump_from_short({0xF8, 0, 0})
	append(&words, note)
	payload := []u8{0x7E, 0x7F, 0x06, 0x01, 0x10, 0x20, 0x30, 0x40}
	for i in 0 ..< midi.ump_sysex_packet_count(len(payload)) {
		w := midi.ump_sysex_packet(payload, i)
		append(&words, w[0], w[1])
	}
	append(&words, clock)
	append(&words, 0x4090_3C00, 0xFFFF_0000) // MIDI 2.0 note on: no MIDI 1.0 meaning here
	midi.input_push_ump(in_, 1_000, 2, words[:])

	events := collect(in_, 0, 512)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		testing.expect_value(t, events[0].payload.(core.Midi_Raw), core.Midi_Raw{{0x91, 64, 90}, 2})
		testing.expect_value(t, events[1].payload.(core.Midi_Raw), core.Midi_Raw{{0xF8, 0, 0}, 2})
	}
	msg, ok := midi.sysex_pop(&in_.sysex, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, msg.port, 2)
	testing.expect_value(t, msg.time_ns, 1_000)
	testing.expect(t, mem.compare(msg.data, payload) == 0)
	testing.expect_value(t, midi.input_stats(in_).ignored, 1)
}

// Events arrive with jittery timestamps between callbacks; with the suggested
// latency they all land at exactly t + latency, whatever the block sizes.
@(test)
scheduling_is_jitter_free_at_fixed_latency :: proc(t: ^testing.T) {
	BUFFER :: 256
	BASE_NS :: u64(5_000_000_000)
	output_offset_ns := u64(math.floor(f64(3 * BUFFER) * NS_PER_FRAME)) // callback → presentation
	latency := midi.suggested_latency_ns(output_offset_ns, BUFFER, SR)

	for pattern in 0 ..< 2 { // 0: whole driver buffers, 1: split into uneven chunks
		in_ := make_input(t)
		defer free_input(in_)
		midi.input_set_latency(in_, latency)

		rng := kit.Rng{state = 99}
		sent: [dynamic]u64
		sent.allocator = context.temp_allocator
		Placed :: struct {time_ns: u64, pos: i64}
		got: [dynamic]Placed
		got.allocator = context.temp_allocator

		sample: i64 = 0
		for cb in 0 ..< 200 {
			block_ns := BASE_NS + u64(f64(sample) * NS_PER_FRAME)
			callback_ns := block_ns - output_offset_ns
			// Up to 3 events arrived since the previous callback.
			prev := callback_ns - u64(math.floor(f64(BUFFER) * NS_PER_FRAME))
			for _ in 0 ..< kit.rng_range(&rng, 0, 3) {
				arrival := prev + u64(kit.rng_next_f64(&rng) * BUFFER * NS_PER_FRAME)
				append(&sent, arrival)
				idx := len(sent) - 1 // identifies the event: 14 bits in the two data bytes
				midi.input_push_short(in_, arrival, 0, {0x90, u8(idx & 0x7F), u8(idx >> 7)})
			}
			chunks := []int{BUFFER} if pattern == 0 else []int{100, 1, 55, 100}
			for n in chunks {
				chunk_ns := BASE_NS + u64(f64(sample) * NS_PER_FRAME)
				for e in collect(in_, chunk_ns, n) {
					testing.expectf(t, int(e.offset) < n, "offset %d ≥ chunk %d", e.offset, n)
					got_pos := sample + i64(e.offset)
					raw := e.payload.(core.Midi_Raw)
					append(&got, Placed{sent[int(raw.bytes[1]) | int(raw.bytes[2]) << 7], got_pos})
				}
				sample += i64(n)
			}
			_ = cb
		}
		testing.expectf(t, len(got) > 100, "only %d events placed", len(got))
		testing.expect_value(t, midi.input_stats(in_).late, 0)
		for p in got {
			want := math.floor(f64(p.time_ns + latency - BASE_NS) / NS_PER_FRAME)
			testing.expectf(t, f64(p.pos) == want, "pattern %d: event at %d ns placed at %d, want %v", pattern, p.time_ns, p.pos, want)
		}
	}
}

@(test)
late_events_go_to_offset_zero :: proc(t: ^testing.T) {
	in_ := make_input(t)
	defer free_input(in_)
	midi.input_set_latency(in_, 1_000_000)
	midi.input_push_short(in_, 1, 0, {0xB0, 7, 100}) // due long ago
	events := collect(in_, 10_000_000_000, 64)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 do testing.expect_value(t, events[0].offset, 0)
	testing.expect_value(t, midi.input_stats(in_).late, 1)
}

@(test)
future_events_wait_and_out_of_order_arrivals_are_sorted :: proc(t: ^testing.T) {
	in_ := make_input(t)
	defer free_input(in_)
	block := u64(math.floor(f64(64) * NS_PER_FRAME))
	// Two ports deliver slightly out of order; one event is two blocks ahead.
	midi.input_push_short(in_, 2 * block + 10, 1, {0x90, 3, 1})
	midi.input_push_short(in_, 30_000, 0, {0x90, 2, 1})
	midi.input_push_short(in_, 10_000, 1, {0x90, 1, 1})

	first := collect(in_, 0, 64)
	testing.expect_value(t, len(first), 2)
	if len(first) == 2 {
		testing.expect_value(t, first[0].payload.(core.Midi_Raw).bytes[1], 1)
		testing.expect_value(t, first[1].payload.(core.Midi_Raw).bytes[1], 2)
		testing.expect(t, first[0].offset <= first[1].offset)
	}
	testing.expect_value(t, len(collect(in_, block, 64)), 0)
	third := collect(in_, 2 * block, 64)
	testing.expect_value(t, len(third), 1)
	if len(third) == 1 do testing.expect_value(t, third[0].offset, 0)
}

@(test)
full_buffers_drop_and_count :: proc(t: ^testing.T) {
	in_ := make_input(t, {queue_capacity = 4, pending_capacity = 2, sysex_bytes = 64, sysex_messages = 4, max_sysex_len = 16})
	defer free_input(in_)
	for i in 0 ..< 6 do midi.input_push_short(in_, u64(1e12) + u64(i), 0, {0x90, u8(i), 1}) // far future
	testing.expect_value(t, midi.input_stats(in_).dropped, 2) // queue holds 4
	collect(in_, 0, 64)
	testing.expect_value(t, midi.input_stats(in_).dropped, 4) // pending holds 2
}

// --- SysEx queue --------------------------------------------------------------------

Sysex_Stress :: struct {
	q:     midi.Sysex_Queue,
	count: int,
	done:  bool,
}

@(test)
sysex_queue_two_thread_stress :: proc(t: ^testing.T) {
	s: Sysex_Stress
	s.count = 20_000
	testing.expect_value(t, midi.sysex_queue_init(&s.q, 1024, 32), mem.Allocator_Error.None)
	defer midi.sysex_queue_destroy(&s.q)

	producer := thread.create_and_start_with_data(&s, proc(p: rawptr) {
		s := (^Sysex_Stress)(p)
		buf: [300]u8
		for i := 0; i < s.count; {
			n := (i * 37) % len(buf)
			for &b, k in buf[:n] do b = u8(i + k) & 0x7F
			if midi.sysex_push(&s.q, u64(i), u8(i & 0xF), buf[:n]) do i += 1
		}
	})
	bad, got := 0, 0
	for got < s.count {
		msg, ok := midi.sysex_pop(&s.q, context.temp_allocator)
		if !ok {
			thread.yield()
			continue
		}
		i := int(msg.time_ns)
		if i != got || len(msg.data) != (i * 37) % 300 do bad += 1
		for b, k in msg.data do if b != u8(i + k) & 0x7F {
			bad += 1
			break
		}
		got += 1
		free_all(context.temp_allocator)
	}
	thread.join(producer)
	thread.destroy(producer)
	testing.expect_value(t, bad, 0)
}

// --- output -------------------------------------------------------------------------

Sent :: struct {
	port:    midi.Port,
	bytes:   [3]u8,
	len:     int,
	time_ns: u64,
}

Fake_Midi :: struct {
	driver: midi.Driver,
	sent:   [64]Sent,
	count:  int, // atomic
	sent_at: [64]u64, // host time when send was called
}

fake_vtable := midi.Driver_VTable {
	send = proc(d: ^midi.Driver, port: midi.Port, message: []u8, time_ns: u64) -> core.Error {
		f := (^Fake_Midi)(d.data)
		s := Sent{port = port, len = len(message), time_ns = time_ns}
		copy(s.bytes[:], message)
		f.sent[f.count] = s
		f.sent_at[f.count] = rt.host_time_ns()
		intrinsics.atomic_add(&f.count, 1)
		return .None
	},
}

@(test)
output_sender_delivers_in_order_with_timestamps :: proc(t: ^testing.T) {
	f: Fake_Midi
	f.driver = {vtable = &fake_vtable, data = &f}
	o: midi.Midi_Output
	testing.expect_value(t, midi.output_init(&o, &f.driver, 64), mem.Allocator_Error.None)
	defer midi.output_destroy(&o)
	midi.output_start(&o)

	block_ns := u64(7_000_000_000)
	for i in 0 ..< 10 {
		bytes := [3]u8{0x90, u8(60 + i), 100} if i % 2 == 0 else [3]u8{0xC0, u8(i), 0}
		ok := midi.output_push(&o, {midi.frame_time_ns(block_ns, i * 48, SR), midi.Port(1 + i % 2), bytes})
		testing.expect(t, ok)
	}
	start := time.tick_now()
	for intrinsics.atomic_load(&f.count) < 10 && time.tick_since(start) < 2 * time.Second do time.sleep(time.Millisecond)
	midi.output_stop(&o)

	testing.expect_value(t, f.count, 10)
	for s, i in f.sent[:f.count] {
		testing.expect_value(t, s.port, midi.Port(1 + i % 2))
		testing.expect_value(t, s.len, 3 if i % 2 == 0 else 2)
		testing.expect_value(t, s.time_ns, block_ns + u64(f64(i * 48) * NS_PER_FRAME))
	}
	testing.expect_value(t, o.errors, 0)
}

@(test)
output_push_is_realtime_safe :: proc(t: ^testing.T) {
	f: Fake_Midi
	f.driver = {vtable = &fake_vtable, data = &f}
	o: midi.Midi_Output
	midi.output_init(&o, &f.driver, 4)
	defer midi.output_destroy(&o)

	trap: kit.Trap_Allocator
	context.allocator = kit.trap_allocator(&trap)
	context.temp_allocator = context.allocator
	for i in 0 ..< 6 do midi.output_push(&o, {u64(i), 1, {0x80, 1, 0}})
	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, o.dropped, 2)
}

// --- byte-stream parser ----------------------------------------------------------------

drain :: proc(in_: ^midi.Midi_Input) -> []core.Midi_Raw {
	out := make([dynamic]core.Midi_Raw, context.temp_allocator)
	for e in collect(in_, 0, 4096) do append(&out, e.payload.(core.Midi_Raw))
	return out[:]
}

@(test)
byte_parser_running_status_and_realtime :: proc(t: ^testing.T) {
	in_ := make_input(t)
	defer free_input(in_)
	// Note on, running-status note on, clock inside a message, program
	// change (2 bytes), song position (system common, cancels running status),
	// then a stray data byte that must be ignored.
	stream := []u8{0x90, 60, 100, 62, 0xF8, 90, 0xC3, 5, 0xF2, 0x10, 0x20, 0x33}
	midi.input_push_bytes(in_, 1, 4, stream[:5]) // split mid-message
	midi.input_push_bytes(in_, 1, 4, stream[5:])
	got := drain(in_)
	want := []core.Midi_Raw{
		{{0x90, 60, 100}, 4}, {{0xF8, 0, 0}, 4}, {{0x90, 62, 90}, 4}, {{0xC3, 5, 0}, 4}, {{0xF2, 0x10, 0x20}, 4},
	}
	testing.expect_value(t, len(got), len(want))
	for w, i in want do if i < len(got) do testing.expectf(t, got[i] == w, "message %d: got %v want %v", i, got[i], w)
	testing.expect_value(t, midi.input_stats(in_).ignored, 1)
}

@(test)
byte_parser_sysex_split_interleaved_and_aborted :: proc(t: ^testing.T) {
	in_ := make_input(t)
	defer free_input(in_)
	// SysEx split over three calls with a clock byte inside it.
	midi.input_push_bytes(in_, 5, 2, {0xF0, 0x7E, 0x01})
	midi.input_push_bytes(in_, 5, 2, {0x02, 0xF8, 0x03})
	midi.input_push_bytes(in_, 5, 2, {0x04, 0xF7})
	msg, ok := midi.sysex_pop(&in_.sysex, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, mem.compare(msg.data, []u8{0x7E, 0x01, 0x02, 0x03, 0x04}) == 0)
	testing.expect_value(t, msg.port, 2)
	got := drain(in_)
	testing.expect_value(t, len(got), 1) // the clock
	// A status byte inside SysEx aborts it; the status byte still counts.
	midi.input_push_bytes(in_, 6, 2, {0xF0, 0x11, 0x22, 0x80, 64, 0})
	_, ok = midi.sysex_pop(&in_.sysex, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, midi.input_stats(in_).sysex_dropped, 1)
	got = drain(in_)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 do testing.expect_value(t, got[0], core.Midi_Raw{{0x80, 64, 0}, 2})
}

// WinMM-style drivers cannot schedule: the sender must hold each message
// until its time, then send it (never early, and not much late).
@(test)
output_sender_holds_until_due_when_driver_cannot_schedule :: proc(t: ^testing.T) {
	f: Fake_Midi
	f.driver = {vtable = &fake_vtable, data = &f, can_schedule = false}
	o: midi.Midi_Output
	testing.expect_value(t, midi.output_init(&o, &f.driver, 64), mem.Allocator_Error.None)
	defer midi.output_destroy(&o)
	midi.output_start(&o)

	base := rt.host_time_ns() + 20_000_000
	for i in 0 ..< 5 do midi.output_push(&o, {base + u64(i) * 10_000_000, 1, {0x90, u8(i), 1}})
	start := time.tick_now()
	for intrinsics.atomic_load(&f.count) < 5 && time.tick_since(start) < 2 * time.Second do time.sleep(time.Millisecond)
	midi.output_stop(&o)

	testing.expect_value(t, f.count, 5)
	for i in 0 ..< f.count {
		due := base + u64(i) * 10_000_000
		late := i64(f.sent_at[i]) - i64(due)
		testing.expectf(t, late >= 0 && late < 5_000_000, "message %d sent %d ns after its time", i, late)
	}
}
