package record

import "base:intrinsics"
import "core:mem"

import "fire:clip"
import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// Settings for `midi_recorder_create`.
Midi_Recorder_Settings :: struct {
	timeline:       core.Timeline_Id, // takes are placed on it and recorded while it plays; zero = record whenever armed
	latency_frames: int, // how late events arrive after they were played (usually 0 for MIDI)
	max_events:     int, // events held for the control thread; 0 = 8192 (more are dropped and counted)
}

// A finished MIDI take: a clip of what was played, from `start` on the
// timeline. Release the clip with `clip.midi_clip_release`.
Midi_Take :: struct {
	clip:   ^clip.Midi_Clip, // notes from the take's start; `length` beats long
	run:    int,      // counts recordings: a new run starts at each start, punch-in or locate
	pass:   int,      // loop passes within the run, from 0
	start:  tb.Beats, // timeline position of the clip's beat 0
	length: tb.Beats,
}

// Records the events it receives (notes, per-note expression, MIDI channel
// messages) into clips. From `midi_recorder_create`; the node owns it and
// frees it when destroyed. Procs not marked [rt] are for the control
// thread, which must call `midi_recorder_poll` regularly (every UI frame,
// say): that is where events become clips. Fields are internal.
Midi_Recorder :: struct {
	settings:  Midi_Recorder_Settings,
	allocator: mem.Allocator,
	commands:  rt.Spsc_Queue(Gate_Command), // control → audio
	events:    rt.Spsc_Queue(Midi_Message), // audio → control
	recording: bool, // atomic
	dropped:   u64,  // atomic: events lost for lack of room
	gate:      Gate, // audio side
	// Control side.
	open:      bool,
	take:      Midi_Take,
	builder:   clip.Midi_Builder,
	held:      [dynamic]Held_Note,
	last_pos:  tb.Beats, // latest position seen in this take
	changed:   bool, // notes finished since the last `midi_recorder_progress`
	done:      [dynamic]Midi_Take,
}

@(private)
Midi_Message :: struct {
	kind:    enum u8 {Begin, Event, End},
	run:     i32,
	pass:    i32,
	pos:     tb.Beats,
	payload: core.Event_Payload,
}

@(private)
Held_Note :: struct {
	on:         core.Note_On,
	start:      tb.Beats, // from the take's start
	expression: [dynamic]clip.Expression_Point,
}

@(private)
midi_recorder_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error { return .None },
	process = midi_recorder_process,
	reset   = proc(self: rawptr) {},
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	destroy = proc(self: rawptr, allocator: mem.Allocator) { midi_recorder_free((^Midi_Recorder)(self)) },
}

// Control thread. Makes a recorder node with no audio channels: connect
// events into it (`graph.connect_events(g, graph.INPUT, id)` for the
// device's MIDI input).
midi_recorder_create :: proc(settings: Midi_Recorder_Settings, allocator := context.allocator) -> (node: core.Node, r: ^Midi_Recorder, err: core.Error) {
	if settings.latency_frames < 0 || settings.max_events < 0 do return {}, nil, .Invalid_Argument
	r = new(Midi_Recorder, allocator)
	if r == nil do return {}, nil, .Out_Of_Memory
	r.settings, r.allocator = settings, allocator
	r.gate = {timeline = settings.timeline, latency = settings.latency_frames}
	r.held = make([dynamic]Held_Note, allocator)
	r.done = make([dynamic]Midi_Take, allocator)
	ae := rt.spsc_init(&r.commands, 64, allocator)
	if ae == nil do ae = rt.spsc_init(&r.events, settings.max_events if settings.max_events > 0 else 8192, allocator)
	if ae != nil {
		midi_recorder_free(r)
		return {}, nil, .Out_Of_Memory
	}
	return core.node_make(&midi_recorder_vtable, r, allocator), r, .None
}

// Control thread. Arms or disarms the recorder, from its next block. Armed,
// it records while its timeline plays (and inside the punch range, if set).
midi_recorder_arm :: proc(r: ^Midi_Recorder, armed: bool) -> core.Error {
	return .None if rt.spsc_push(&r.commands, Gate_Command{kind = .Arm if armed else .Disarm}) else .Out_Of_Memory
}

// Control thread. Changes `latency_frames`, from the next block. Not while
// recording.
midi_recorder_set_latency :: proc(r: ^Midi_Recorder, frames: int) -> core.Error {
	if frames < 0 do return .Invalid_Argument
	return .None if rt.spsc_push(&r.commands, Gate_Command{kind = .Latency, a = tb.Beats(frames)}) else .Out_Of_Memory
}

// Control thread. Records only from timeline position `punch_in` to `punch_out`.
midi_recorder_set_punch :: proc(r: ^Midi_Recorder, punch_in, punch_out: tb.Beats) -> core.Error {
	if !(punch_out > punch_in) do return .Invalid_Argument
	return .None if rt.spsc_push(&r.commands, Gate_Command{kind = .Punch, a = punch_in, b = punch_out}) else .Out_Of_Memory
}

// Control thread. Removes the punch range.
midi_recorder_clear_punch :: proc(r: ^Midi_Recorder) -> core.Error {
	return .None if rt.spsc_push(&r.commands, Gate_Command{kind = .No_Punch}) else .Out_Of_Memory
}

// Control thread. Turns recorded events into clips, then returns the next
// finished take, if any (iterate with `for take in`). The caller owns its
// clip. A loop pass is finished when the timeline wraps.
midi_recorder_poll :: proc(r: ^Midi_Recorder) -> (take: Midi_Take, ok: bool) {
	drain(r)
	if len(r.done) == 0 do return {}, false
	take = r.done[0]
	ordered_remove(&r.done, 0)
	return take, true
}

// Control thread. The take being recorded, so far: its finished notes and
// controllers (notes still held are left out until released). `ok` is false
// when nothing is being recorded, or nothing changed since the last call;
// otherwise the caller owns the clip. For overdubbing, merge it into the
// clip that is playing as you go (see `clip.add_clip`).
midi_recorder_progress :: proc(r: ^Midi_Recorder) -> (take: Midi_Take, ok: bool) {
	drain(r)
	if !r.open || !r.changed do return {}, false
	r.changed = false
	take = r.take
	take.length = max(r.last_pos - r.take.start, 1e-6)
	r.builder.length, r.builder.loop_start, r.builder.loop_end = take.length, 0, take.length
	take.clip, _ = clip.midi_build(&r.builder, r.allocator)
	return take, take.clip != nil
}

// [rt] Whether a take is being recorded, and the events lost so far for lack
// of room (poll more often, or raise `max_events`).
midi_recorder_status :: proc "contextless" (r: ^Midi_Recorder) -> (recording: bool, dropped_events: u64) {
	return intrinsics.atomic_load(&r.recording), intrinsics.atomic_load(&r.dropped)
}

@(private)
midi_recorder_free :: proc(r: ^Midi_Recorder) {
	for t in r.done do clip.midi_clip_release(t.clip)
	delete(r.done)
	for h in r.held do delete(h.expression)
	delete(r.held)
	if r.open do clip.midi_builder_destroy(&r.builder)
	rt.spsc_destroy(&r.commands, r.allocator)
	rt.spsc_destroy(&r.events, r.allocator)
	free(r, r.allocator)
}

// --- the audio side ----------------------------------------------------------------------

// [rt]
@(private)
midi_recorder_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	r := (^Midi_Recorder)(self)
	for c in rt.spsc_pop(&r.commands) do gate_command(&r.gate, c)
	gate_process(&r.gate, ctx, {
		user = r,
		begin = proc "contextless" (user: rawptr, g: ^Gate, frame: i64, pos: tb.Beats) -> bool {
			return push_event((^Midi_Recorder)(user), {kind = .Begin, run = g.run, pass = g.pass, pos = pos})
		},
		data = proc "contextless" (user: rawptr, g: ^Gate, e: ^History, a, b: i64, at: int) {
			r := (^Midi_Recorder)(user)
			for ev in g.ctx.events_in {
				o := int(ev.offset)
				if o < at || o >= at + int(b - a) do continue
				#partial switch _ in ev.payload {
				case core.Note_On, core.Note_Off, core.Note_Expression, core.Midi_Raw:
					push_event(r, {kind = .Event, pos = position(g, e, a + i64(o - at)), payload = ev.payload})
				}
			}
		},
		end = proc "contextless" (user: rawptr, g: ^Gate) {
			push_event((^Midi_Recorder)(user), {kind = .End, pos = g.last_pos})
		},
	})
	intrinsics.atomic_store(&r.recording, r.gate.taking)
}

// [rt]
@(private)
push_event :: proc "contextless" (r: ^Midi_Recorder, m: Midi_Message) -> bool {
	if rt.spsc_push(&r.events, m) do return true
	intrinsics.atomic_add(&r.dropped, 1)
	return false
}

// --- the control side --------------------------------------------------------------------

// Turns everything the audio thread recorded into takes.
@(private)
drain :: proc(r: ^Midi_Recorder) {
	for m in rt.spsc_pop(&r.events) {
		switch m.kind {
		case .Begin:
			if r.open do close_take(r, r.last_pos)
			r.open, r.changed = true, false
			r.take = {run = int(m.run), pass = int(m.pass), start = m.pos}
			r.last_pos = m.pos
			clip.midi_builder_init(&r.builder, 1, r.allocator)
		case .Event:
			if r.open {
				r.last_pos = max(r.last_pos, m.pos)
				add_event(r, m.pos - r.take.start, m.payload)
			}
		case .End:
			if r.open do close_take(r, m.pos)
		}
	}
}

@(private)
add_event :: proc(r: ^Midi_Recorder, at: tb.Beats, payload: core.Event_Payload) {
	#partial switch v in payload {
	case core.Note_On:
		append(&r.held, Held_Note{on = v, start = at, expression = make([dynamic]clip.Expression_Point, r.allocator)})
	case core.Note_Off:
		for h, i in r.held do if same_note(h.on, v.id, v.channel, v.key) {
			end_note(r, h, at, v.velocity)
			ordered_remove(&r.held, i)
			break
		}
	case core.Note_Expression:
		for &h in r.held do if same_note(h.on, v.id, v.channel, v.key) {
			append(&h.expression, clip.Expression_Point{at = at - h.start, kind = v.kind, value = v.value})
			break
		}
	case core.Midi_Raw:
		if v.bytes[0] >= 0x80 && v.bytes[0] < 0xF0 && v.bytes[0] & 0xF0 != 0x80 && v.bytes[0] & 0xF0 != 0x90 {
			clip.add_controller(&r.builder, at, v.bytes) // channel messages other than notes
			r.changed = true
		}
	}
}

// Matches a note by id, or by channel and key when either has no id (the
// device's notes usually have none).
@(private)
same_note :: proc(on: core.Note_On, id: core.Note_Id, channel, key: u8) -> bool {
	if on.id != core.NOTE_ID_ANY && id != core.NOTE_ID_ANY do return on.id == id
	return on.channel == channel && on.key == key
}

@(private)
end_note :: proc(r: ^Midi_Recorder, h: Held_Note, at: tb.Beats, release: f32) {
	n := clip.add_note(&r.builder, h.start, at - h.start, h.on.key, h.on.velocity, h.on.channel, release)
	for x in h.expression do clip.add_expression(&r.builder, n, x.at, x.kind, x.value)
	delete(h.expression)
	r.changed = true
}

// Ends notes still held at the take's end, builds its clip, and queues it.
@(private)
close_take :: proc(r: ^Midi_Recorder, end: tb.Beats) {
	length := end - r.take.start
	for h in r.held do end_note(r, h, length, 0.5)
	clear(&r.held)
	r.take.length = max(length, 1e-6)
	r.builder.length, r.builder.loop_start, r.builder.loop_end = r.take.length, 0, r.take.length
	r.take.clip, _ = clip.midi_build(&r.builder, r.allocator)
	clip.midi_builder_destroy(&r.builder)
	if r.take.clip != nil do append(&r.done, r.take)
	r.open = false
}
