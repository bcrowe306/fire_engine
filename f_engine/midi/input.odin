package midi

import "base:intrinsics"
import "core:mem"
import "core:sync"

import "fire:core"
import "fire:rt"

MAX_PORTS :: 16

Input_Event :: struct {
	time_ns: u64, // host clock (rt.host_time_ns)
	port:    u8,
	bytes:   [3]u8,
}

// Collects MIDI input from driver threads and places it, sample-accurately,
// into audio blocks.
//
// Timing: an event received at host time t is played at t + latency_ns. With
// latency ≥ (output_ns − callback_ns) + one driver period, every event arrives
// before its block is rendered, so timing is jitter-free at a fixed latency.
// Use `suggested_latency_ns`. Events that arrive too late for their slot are
// placed at offset 0 and counted in `late`.
Midi_Input :: struct {
	queue:         rt.Spsc_Queue(Input_Event),
	producer_lock: sync.Mutex, // driver threads; never taken by the audio thread
	sysex:         Sysex_Queue,
	assemblers:    [MAX_PORTS]Sysex_Assembler,
	parsers:       [MAX_PORTS]Byte_Parser, // for drivers that deliver MIDI 1.0 bytes
	sysex_storage: []u8,
	latency_ns:    u64,

	// Audio thread only.
	pending:     []Input_Event, // sorted by time
	pending_len: int,

	// Counters (atomic).
	late:    u64,
	dropped: u64, // short messages lost to a full queue or pending buffer
	ignored: u64, // UMP messages with no MIDI 1.0 meaning (MIDI 2.0 voice, utility...)
}

Input_Config :: struct {
	queue_capacity:   int, // short messages in flight
	pending_capacity: int, // messages waiting for a future block
	sysex_bytes:      int, // SysEx byte ring to the control thread
	sysex_messages:   int,
	max_sysex_len:    int, // longer SysEx messages are dropped
}

default_input_config :: proc() -> Input_Config {
	return {4096, 4096, 1 << 16, 256, 8192}
}

input_init :: proc(in_: ^Midi_Input, cfg := Input_Config{}, allocator := context.allocator) -> (err: mem.Allocator_Error) {
	cfg := cfg
	if cfg == {} do cfg = default_input_config()
	rt.spsc_init(&in_.queue, cfg.queue_capacity, allocator) or_return
	sysex_queue_init(&in_.sysex, cfg.sysex_bytes, cfg.sysex_messages, allocator) or_return
	in_.pending = make([]Input_Event, cfg.pending_capacity, allocator) or_return
	in_.sysex_storage = make([]u8, cfg.max_sysex_len * MAX_PORTS, allocator) or_return
	for &a, i in in_.assemblers do a.buffer = in_.sysex_storage[i * cfg.max_sysex_len:][:cfg.max_sysex_len]
	return nil
}

input_destroy :: proc(in_: ^Midi_Input, allocator := context.allocator) {
	rt.spsc_destroy(&in_.queue, allocator)
	sysex_queue_destroy(&in_.sysex, allocator)
	delete(in_.pending, allocator)
	delete(in_.sysex_storage, allocator)
	in_.pending, in_.sysex_storage = nil, nil
}

// Latency that makes input timing jitter-free: the gap between a callback and
// the presentation of its first frame, plus one driver period.
suggested_latency_ns :: proc "contextless" (output_offset_ns: u64, buffer_frames: int, sample_rate: f64) -> u64 {
	return output_offset_ns + u64(f64(buffer_frames) * 1e9 / sample_rate)
}

input_set_latency :: proc "contextless" (in_: ^Midi_Input, latency_ns: u64) {
	intrinsics.atomic_store_explicit(&in_.latency_ns, latency_ns, .Relaxed)
}

// --- driver side (any non-realtime thread) -------------------------------------

input_push_short :: proc "contextless" (in_: ^Midi_Input, time_ns: u64, port: u8, bytes: [3]u8) {
	sync.mutex_lock(&in_.producer_lock)
	defer sync.mutex_unlock(&in_.producer_lock)
	push_locked(in_, {time_ns, port, bytes})
}

// Decodes a run of UMP words (MIDI 1.0 protocol). SysEx goes to the SysEx queue.
input_push_ump :: proc "contextless" (in_: ^Midi_Input, time_ns: u64, port: u8, words: []u32) {
	sync.mutex_lock(&in_.producer_lock)
	defer sync.mutex_unlock(&in_.producer_lock)
	for i := 0; i < len(words); {
		n := ump_word_count(words[i])
		if i + n > len(words) do break
		switch words[i] >> 28 {
		case UMP_SYSTEM, UMP_MIDI1_VOICE:
			if bytes, ok := ump_to_short(words[i]); ok {
				push_locked(in_, {time_ns, port, bytes})
			} else {
				intrinsics.atomic_add_explicit(&in_.ignored, 1, .Relaxed)
			}
		case UMP_DATA64:
			a := &in_.assemblers[min(int(port), MAX_PORTS - 1)]
			switch sysex_assemble(a, {words[i], words[i + 1]}) {
			case .Complete: sysex_push(&in_.sysex, time_ns, port, assembler_message(a))
			case .Dropped:  intrinsics.atomic_add_explicit(&in_.sysex.dropped, 1, .Relaxed)
			case .None:
			}
		case:
			intrinsics.atomic_add_explicit(&in_.ignored, 1, .Relaxed)
		}
		i += n
	}
}

// Running-status state for one byte-stream source. SysEx bytes go to the
// port's Sysex_Assembler buffer.
Byte_Parser :: struct {
	status:   u8, // current running status (0 = none)
	data:     [2]u8,
	have:     int,
	need:     int,
	in_sysex: bool,
}

// Parses a MIDI 1.0 byte stream (as from ALSA rawmidi/sequencer decoding or
// WinMM): running status, real-time bytes anywhere (even inside other
// messages), SysEx split across calls. Complete SysEx goes to the SysEx queue.
input_push_bytes :: proc "contextless" (in_: ^Midi_Input, time_ns: u64, port: u8, bytes: []u8) {
	sync.mutex_lock(&in_.producer_lock)
	defer sync.mutex_unlock(&in_.producer_lock)
	i := min(int(port), MAX_PORTS - 1)
	p, a := &in_.parsers[i], &in_.assemblers[i]
	for b in bytes {
		switch {
		case b >= 0xF8: // real-time: never disturbs the message in progress
			if message_length(b) == 1 do push_locked(in_, {time_ns, port, {b, 0, 0}})
		case b == 0xF0:
			if p.in_sysex do intrinsics.atomic_add_explicit(&in_.sysex.dropped, 1, .Relaxed) // unterminated
			p.in_sysex, p.status, p.have = true, 0, 0
			a.len, a.overflowed, a.active = 0, false, true
		case b == 0xF7:
			if !p.in_sysex do continue
			p.in_sysex, a.active = false, false
			if a.overflowed {
				intrinsics.atomic_add_explicit(&in_.sysex.dropped, 1, .Relaxed)
			} else {
				sysex_push(&in_.sysex, time_ns, port, assembler_message(a))
			}
		case b >= 0x80:
			if p.in_sysex { // a status byte ends SysEx without F7: drop it
				p.in_sysex, a.active = false, false
				intrinsics.atomic_add_explicit(&in_.sysex.dropped, 1, .Relaxed)
			}
			n := message_length(b)
			if n == 0 { // undefined status: ignore it and what follows
				p.status = 0
				intrinsics.atomic_add_explicit(&in_.ignored, 1, .Relaxed)
				continue
			}
			p.status, p.have, p.need = b, 0, n - 1
			if p.need == 0 {
				push_locked(in_, {time_ns, port, {b, 0, 0}})
				p.status = 0 // system messages cancel running status
			}
		case p.in_sysex:
			if a.len < len(a.buffer) {
				a.buffer[a.len] = b
				a.len += 1
			} else {
				a.overflowed = true
			}
		case p.status != 0:
			p.data[p.have] = b
			p.have += 1
			if p.have == p.need {
				push_locked(in_, {time_ns, port, {p.status, p.data[0], p.data[1] if p.need == 2 else 0}})
				p.have = 0
				if p.status >= 0xF0 do p.status = 0 // no running status for system common
			}
		case:
			intrinsics.atomic_add_explicit(&in_.ignored, 1, .Relaxed) // stray data byte
		}
	}
}

@(private)
push_locked :: proc "contextless" (in_: ^Midi_Input, e: Input_Event) {
	if !rt.spsc_push(&in_.queue, e) do intrinsics.atomic_add_explicit(&in_.dropped, 1, .Relaxed)
}

// --- audio thread ----------------------------------------------------------------

// [rt] Writes the MIDI events due in this block to `out` as core.Midi_Raw, in
// time order. `block_ns` is the presentation time of the block's first frame
// (Io_Block.output_ns).
input_process :: proc "contextless" (in_: ^Midi_Input, block_ns: u64, frames: int, sample_rate: f64, out: ^core.Event_Writer) {
	for e in rt.spsc_pop(&in_.queue) do insert_pending(in_, e)
	if frames <= 0 do return

	latency := i64(intrinsics.atomic_load_explicit(&in_.latency_ns, .Relaxed))
	ns_per_frame := 1e9 / sample_rate
	end_ns := i64(block_ns) + i64(f64(frames) * ns_per_frame)
	emitted := 0
	for e in in_.pending[:in_.pending_len] {
		due := i64(e.time_ns) + latency
		if due >= end_ns do break
		offset := 0
		if due < i64(block_ns) {
			intrinsics.atomic_add_explicit(&in_.late, 1, .Relaxed)
		} else {
			offset = min(int(f64(due - i64(block_ns)) / ns_per_frame), frames - 1)
		}
		core.event_writer_push(out, {u32(offset), core.Midi_Raw{e.bytes, e.port}})
		emitted += 1
	}
	if emitted > 0 {
		copy(in_.pending[:], in_.pending[emitted:in_.pending_len])
		in_.pending_len -= emitted
	}
}

// [rt] Keeps `pending` sorted by time; events usually arrive in order, so this
// is an append.
@(private)
insert_pending :: proc "contextless" (in_: ^Midi_Input, e: Input_Event) {
	if in_.pending_len == len(in_.pending) {
		intrinsics.atomic_add_explicit(&in_.dropped, 1, .Relaxed)
		return
	}
	i := in_.pending_len
	for i > 0 && in_.pending[i - 1].time_ns > e.time_ns {
		in_.pending[i] = in_.pending[i - 1]
		i -= 1
	}
	in_.pending[i] = e
	in_.pending_len += 1
}

Input_Stats :: struct {
	late, dropped, ignored, sysex_dropped: u64,
}

input_stats :: proc "contextless" (in_: ^Midi_Input) -> Input_Stats {
	return {
		late          = intrinsics.atomic_load_explicit(&in_.late, .Relaxed),
		dropped       = intrinsics.atomic_load_explicit(&in_.dropped, .Relaxed),
		ignored       = intrinsics.atomic_load_explicit(&in_.ignored, .Relaxed),
		sysex_dropped = sysex_dropped(&in_.sysex),
	}
}
