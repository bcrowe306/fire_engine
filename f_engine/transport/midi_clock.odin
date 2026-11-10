package transport

import "core:math"
import "core:mem"

import "fire:core"
import tb "fire:timebase"

// MIDI Timing Clock, sent 24 times per quarter note by `midi_clock_create`.
MIDI_CLOCK :: u8(0xF8)
// MIDI Start: play from the top.
MIDI_START :: u8(0xFA)
// MIDI Continue: play from the last Song Position Pointer.
MIDI_CONTINUE :: u8(0xFB)
// MIDI Stop.
MIDI_STOP :: u8(0xFC)
// MIDI Song Position Pointer: a 14-bit position in sixteenth notes, LSB first.
MIDI_SONG_POSITION :: u8(0xF2)

// Settings for a MIDI clock node.
Midi_Clock_Settings :: struct {
	follow:             core.Timeline_Id, // timeline whose start, stop and position are sent; zero = clock ticks only
	port:               u8,   // `core.Midi_Raw.port` of every message
	send_while_stopped: bool, // keep ticking on the grid while `follow` is stopped
}

// Creates a node that emits MIDI clock as `core.Midi_Raw` events, exactly on
// the frame each message is due. Give it 0 audio channels, event-connect it
// to the graph's output, and forward the events to a MIDI port with
// `midi.output_push_events`.
//
// While `follow` plays, ticks fall on its 24ths of a beat, so the receiver's
// beats line up with the timeline's. It sends Start when the timeline starts
// at 0, otherwise Song Position (rounded down to a sixteenth) then Continue;
// Stop when it stops; and Stop, Song Position, Continue when it jumps (a
// locate or loop wrap). Otherwise ticks fall on the grid. Control thread.
midi_clock_create :: proc(settings: Midi_Clock_Settings, allocator := context.allocator) -> core.Node {
	m := new(Midi_Clock, allocator)
	m.settings = settings
	return core.node_make(&midi_clock_vtable, m, allocator)
}

@(private)
Midi_Clock :: struct {
	settings: Midi_Clock_Settings,
}

@(private)
midi_clock_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = midi_clock_process,
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
	type_id = MIDI_CLOCK_TYPE_ID,
	state_version = 1,
	save    = save_midi_clock,
}

@(private)
midi_clock_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Midi_Clock)(self)
	t := ctx.transport
	if t == nil || ctx.events_out == nil do return
	send := proc "contextless" (m: ^Midi_Clock, out: ^core.Event_Writer, offset: int, bytes: [3]u8) {
		core.event_writer_push(out, {u32(offset), core.Midi_Raw{bytes, m.settings.port}})
	}
	tl := core.transport_timeline(t, m.settings.follow)
	if tl != nil {
		// Transport messages first: the block was split, so they are due at frame 0.
		if .Stopped in tl.flags do send(m, ctx.events_out, 0, {MIDI_STOP, 0, 0})
		if tl.playing && .Started in tl.flags && abs(f64(tl.position)) < 1e-9 {
			send(m, ctx.events_out, 0, {MIDI_START, 0, 0})
		} else if tl.playing && (.Started in tl.flags || .Jumped in tl.flags) {
			if .Started not_in tl.flags do send(m, ctx.events_out, 0, {MIDI_STOP, 0, 0})
			spp := u16(clamp(math.floor(f64(tl.position) * 4 + 1e-9), 0, 0x3FFF))
			send(m, ctx.events_out, 0, {MIDI_SONG_POSITION, u8(spp & 0x7F), u8(spp >> 7)})
			send(m, ctx.events_out, 0, {MIDI_CONTINUE, 0, 0})
		}
	}
	if tl != nil && !tl.playing && !m.settings.send_while_stopped do return
	// Ticks at every 24th of a beat from here to the end of the call: on the
	// timeline's beats while it plays, otherwise on the grid's.
	following := tl != nil && tl.playing
	first := core.timeline_next_multiple(t, tl, 1.0 / 24) if following else core.transport_next_multiple(t, 1.0 / 24)
	for k := math.round(f64(first) * 24); ; k += 1 {
		at := tb.Beats(k / 24)
		offset := core.timeline_offset_of(t, tl, at) if following else core.transport_offset_of(t, at)
		if offset >= ctx.frames do break
		send(m, ctx.events_out, offset, {MIDI_CLOCK, 0, 0})
	}
}
