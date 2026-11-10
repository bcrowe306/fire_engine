package pads_model

import "base:intrinsics"
import "core:mem"

import fc "fire:core"
import pf "fire:perform"
import "fire:rt"

// MIDI channel (0-based) of the sequencer's notes on their way to the
// router: they skip the live effects.
SEQ_CHANNEL :: 15
// Channel of keyboard-mode notes between the live effects and the pads.
@(private) KEYS_CHANNEL :: 1
// Keyboard-mode notes are keys around this one (a pitch of 0).
@(private) KEYS_CENTER :: 60

// A pad hit, from the UI thread to the router.
Hit :: struct {
	pad:      u8,
	on:       bool,
	velocity: f32,
	pitch:    i8,   // semitones, for a keyboard hit
	keyboard: bool, // one of many notes of the pad (keyboard mode)
}

// A note the router heard live, back to the UI (for recording and MIDI
// learn): a pad hit, or a MIDI note (`midi_key` ≥ 0; `pad` -1 if no pad
// answers it).
Taken :: struct {
	using hit: Hit,
	beat:     f64,  // the sequencer's position then
	playing:  bool, // whether it was playing
	midi_key: i16,  // the MIDI key, or -1 for a hit from the UI
	no_pad:   bool, // a MIDI note no pad answers
}

// What the live effects do; set with `set_perform`.
Perform :: struct {
	arp_on:    bool,
	arp:       pf.Arp_Settings,
	repeat_on: bool,
	repeat:    pf.Repeat_Settings,
}

// A pad's MIDI out: its hits also go out as this note.
Midi_Out :: struct {
	on:      bool,
	channel: u8, // 0..15
	key:     u8,
}

// Plays the pads. Live notes (hits from the UI, and MIDI notes mapped to
// pads) go through the arpeggiator and note repeat when they are on; the
// sequencer's notes go straight to the pads. Then: a pad's hit chokes its
// choke group, a Hold pad stops on its second hit, Gate and Loop pads stop
// on release, keyboard notes play the pad pitched (each its own voice), and
// pads with MIDI out send it. Fields the control thread writes (`groups`,
// `modes`, `capture`, `midi_map`, `midi_out`) are read by the audio thread;
// a torn byte is harmless. Settings for the effects come through `settings`.
Router :: struct {
	queue:    rt.Spsc_Queue(Hit),
	taken:    rt.Spsc_Queue(Taken),
	settings: rt.Spsc_Queue(Perform),
	capture:  bool, // report hits and MIDI notes in `taken`
	timeline: fc.Timeline_Id,
	groups:   [PADS]u8,
	modes:    [PADS]Pad_Mode,
	midi_map: [128]i16, // MIDI key → pad (-1: none)
	midi_out: [PADS]Midi_Out,
	// Audio thread.
	effects:  Perform,
	arp:      pf.Arp,
	repeat:   pf.Repeat,
	live:     [512]fc.Event,
	effected: [1024]fc.Event,
	holding:  [PADS]bool, // Hold pads sounding
	keys_pad: [128]u8,    // keyboard notes: the pad each key plays
	keys_id:  [128]fc.Note_Id,
	next_id:  fc.Note_Id,
	played:   u64, // atomic: hits played (for tests and meters)
	struck:   [PADS]u32, // atomic: times each pad has sounded (the UI lights pads when these move)
}

@(private)
router_vtable := fc.Node_VTable {
	prepare = proc(self: rawptr, cfg: fc.Prepare_Config, a: mem.Allocator) -> fc.Error { return .None },
	process = router_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {
		r := (^Router)(self)
		rt.spsc_destroy(&r.queue, a)
		rt.spsc_destroy(&r.taken, a)
		rt.spsc_destroy(&r.settings, a)
		free(r, a)
	},
}

@(private)
router_create :: proc(allocator := context.allocator) -> (fc.Node, ^Router) {
	r := new(Router, allocator)
	rt.spsc_init(&r.queue, 256, allocator)
	rt.spsc_init(&r.taken, 1024, allocator)
	rt.spsc_init(&r.settings, 16, allocator)
	r.next_id = 1 << 30 // apart from the sequencer's and the effects' ids
	for &m, k in r.midi_map do m = i16(k - PAD_KEY_BASE) if k >= PAD_KEY_BASE && k < PAD_KEY_BASE + PADS else -1
	pf.arp_init(&r.arp, {})
	pf.repeat_init(&r.repeat, {})
	return fc.node_make(&router_vtable, r, allocator), r
}

// The pad a key plays, or -1.
@(private)
pad_of_key :: proc "contextless" (key: u8) -> int {
	i := int(key) - PAD_KEY_BASE
	return i if i >= 0 && i < PADS else -1
}

// [rt]
@(private)
router_process :: proc(self: rawptr, ctx: ^fc.Process_Context) {
	r := (^Router)(self)
	out := ctx.events_out
	if out == nil do return
	for s in rt.spsc_pop(&r.settings) do router_set(r, s, out)
	beat: f64
	playing := false
	if tl := fc.transport_timeline(ctx.transport, r.timeline); tl != nil do beat, playing = f64(tl.position), tl.playing

	// Live notes: the UI's hits (at the start of the block), then MIDI.
	live := fc.Event_Writer{buffer = r.live[:]}
	for h in rt.spsc_pop(&r.queue) {
		if int(h.pad) >= PADS do continue
		if h.keyboard {
			key := u8(clamp(KEYS_CENTER + int(h.pitch), 0, 127))
			r.keys_pad[key] = h.pad
			fc.event_writer_push(&live, {0, note(h.on, KEYS_CHANNEL, key, h.velocity)})
		} else {
			fc.event_writer_push(&live, {0, note(h.on, 0, pad_key(int(h.pad)), h.velocity)})
		}
		if r.capture do rt.spsc_push(&r.taken, Taken{hit = h, beat = beat, playing = playing, midi_key = -1})
	}
	for e in ctx.events_in {
		#partial switch v in e.payload {
		case fc.Midi_Raw:
			status := v.bytes[0] & 0xF0
			if status != 0x90 && status != 0x80 do continue
			key := v.bytes[1] & 0x7F
			on := status == 0x90 && v.bytes[2] > 0
			vel := f32(v.bytes[2]) / 127
			p := r.midi_map[key]
			rt.spsc_push(&r.taken, Taken{hit = {pad = u8(max(p, 0)), on = on, velocity = vel}, beat = beat, playing = playing, midi_key = i16(key), no_pad = p < 0})
			if p >= 0 do fc.event_writer_push(&live, {e.offset, note(on, 0, pad_key(int(p)), vel)})
		case fc.Note_On, fc.Note_Off:
			sound(r, out, e) // the sequencer
		}
	}

	// The live effects, then the pads.
	events := fc.event_writer_events(&live)
	if r.effects.arp_on || r.effects.repeat_on {
		fx := fc.Event_Writer{buffer = r.effected[:]}
		if r.effects.arp_on {
			pf.arp_process(&r.arp, ctx.transport, ctx.frames, events, &fx)
		} else {
			pf.repeat_process(&r.repeat, ctx.transport, ctx.frames, events, &fx)
		}
		events = fc.event_writer_events(&fx)
	}
	for e in events do sound(r, out, e)
}

@(private)
note :: proc "contextless" (on: bool, channel, key: u8, velocity: f32) -> fc.Event_Payload {
	if on do return fc.Note_On{id = fc.NOTE_ID_ANY, channel = channel, key = key, velocity = velocity}
	return fc.Note_Off{id = fc.NOTE_ID_ANY, channel = channel, key = key}
}

// [rt] New effect settings: what the old effect was playing ends.
@(private)
router_set :: proc "contextless" (r: ^Router, s: Perform, out: ^fc.Event_Writer) {
	fx: [64]fc.Event
	w := fc.Event_Writer{buffer = fx[:]}
	if r.effects.arp_on && !s.arp_on do pf.arp_reset(&r.arp, &w)
	if r.effects.repeat_on && !s.repeat_on do pf.repeat_reset(&r.repeat, &w)
	pf.arp_set(&r.arp, s.arp)
	pf.repeat_set(&r.repeat, s.repeat)
	r.effects = s
	for e in fc.event_writer_events(&w) do sound(r, out, e)
}

// [rt] One note to the pads.
@(private)
sound :: proc "contextless" (r: ^Router, out: ^fc.Event_Writer, e: fc.Event) {
	switch v in e.payload {
	case fc.Note_On:
		if v.channel == KEYS_CHANNEL {
			i := int(r.keys_pad[v.key])
			if !strike(r, out, e.offset, i) do return
			id := r.next_id
			r.next_id += 1
			if r.keys_id[v.key] != 0 do fc.event_writer_push(out, {e.offset, fc.Note_Off{id = r.keys_id[v.key], key = pad_key(i)}})
			r.keys_id[v.key] = id
			fc.event_writer_push(out, {e.offset, fc.Note_On{id = id, key = pad_key(i), velocity = v.velocity}})
			fc.event_writer_push(out, {e.offset, fc.Note_Expression{id = id, key = pad_key(i), kind = .Tuning, value = f64(int(v.key) - KEYS_CENTER)}})
			midi_send(r, out, e.offset, i, true, v.velocity)
			return
		}
		i := pad_of_key(v.key)
		if i < 0 do return
		if !strike(r, out, e.offset, i) do return
		x := v
		x.channel = 0
		fc.event_writer_push(out, {e.offset, x})
		midi_send(r, out, e.offset, i, true, v.velocity)
	case fc.Note_Off:
		if v.channel == KEYS_CHANNEL {
			i := int(r.keys_pad[v.key])
			if id := r.keys_id[v.key]; id != 0 {
				if r.modes[i] == .Gate || r.modes[i] == .Loop do fc.event_writer_push(out, {e.offset, fc.Note_Off{id = id, key = pad_key(i)}})
				r.keys_id[v.key] = 0
			}
			midi_send(r, out, e.offset, i, false, 0)
			return
		}
		i := pad_of_key(v.key)
		if i < 0 do return
		x := v
		x.channel = 0
		// One-shot and Hold pads play on (the sampler ignores the
		// note-off of a one-shot zone; Hold stops on its next hit).
		if r.modes[i] != .Hold do fc.event_writer_push(out, {e.offset, x})
		midi_send(r, out, e.offset, i, false, 0)
	case fc.Note_Choke, fc.Note_Expression, fc.Param_Value, fc.Param_Ramp, fc.Midi_Raw:
		fc.event_writer_push(out, e)
	}
}

// [rt] Before pad `i` sounds: choke its group. False if it should not sound
// (a Hold pad hit a second time stops instead).
@(private)
strike :: proc "contextless" (r: ^Router, out: ^fc.Event_Writer, offset: u32, i: int) -> bool {
	if r.modes[i] == .Hold && r.holding[i] {
		fc.event_writer_push(out, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = pad_key(i)}})
		r.holding[i] = false
		return false
	}
	if g := r.groups[i]; g != 0 {
		for other in 0 ..< PADS do if other != i && r.groups[other] == g {
			fc.event_writer_push(out, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = pad_key(other)}})
			r.holding[other] = false
		}
	}
	if r.modes[i] == .Hold do r.holding[i] = true
	intrinsics.atomic_add(&r.played, 1)
	intrinsics.atomic_add(&r.struck[i], 1)
	return true
}

// [rt] Pad `i`'s MIDI out, if it has one.
@(private)
midi_send :: proc "contextless" (r: ^Router, out: ^fc.Event_Writer, offset: u32, i: int, on: bool, velocity: f32) {
	m := r.midi_out[i]
	if !m.on do return
	status := (0x90 if on else 0x80) | (m.channel & 15)
	vel := u8(clamp(velocity * 127 + 0.5, 1, 127)) if on else 64
	fc.event_writer_push(out, {offset, fc.Midi_Raw{bytes = {status, m.key & 127, vel}}})
}
