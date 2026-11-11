package pads_model

import "base:intrinsics"
import "core:math"
import "core:mem"

import fc "fire:core"
import "fire:synth"
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
	port:    string, // the output port's id (interned); "" = the default output (Settings)
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
	out_port: [PADS]u8,  // each pad's MIDI out: the output port's index (255: none open)
	in_port:  [PADS]i16, // each pad's MIDI in: IN_ALL (the drum map), IN_NONE, or an input port's index
	in_channel: [PADS]u8, // 0 = any, 1..16
	armed:    [PADS]bool, // armed tracks: their own MIDI input plays them (and records)
	kinds:    [PADS]Pad_Kind, // each track's device
	slicers:  [PADS]Slicer_Play, // a slicer track's base note, mono, gate
	// Audio thread: each track's events this block (its device reads them
	// through its `Track_In` node), and a slicer's sequencer note waiting
	// for its pitch (which slice) in the expression after it.
	tracks:   [PADS]Track_Events,
	waiting:  [PADS]struct { id: fc.Note_Id, velocity: f32, offset: u32, set: bool },
	// A keyed track's sounding notes' keys, by id (its note-offs carry the
	// key their note-on had: a plug-in matches them by key).
	sounding: [PADS][KEYED_NOTES]struct { id: fc.Note_Id, key: u8 },
	sounding_at: [PADS]u8,
	midi_in_hits:  [PADS]u32, // atomic: MIDI notes that played each pad (activity lights)
	midi_out_hits: [PADS]u32, // atomic: MIDI notes each pad sent
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
	silence:  u32, // atomic: raised to silence every voice (`silence_all`)
	silenced: u32, // audio thread: the last `silence` acted on
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
	for &m, k in r.midi_map do m = i16(k) if k < PADS else -1
	for &x in r.in_port do x = IN_ALL // (until `sync` says otherwise)
	for &x in r.out_port do x = 255
	pf.arp_init(&r.arp, {})
	pf.repeat_init(&r.repeat, {})
	return fc.node_make(&router_vtable, r, allocator), r
}

// The pad a key plays, or -1.
@(private)
pad_of_key :: proc "contextless" (key: u8) -> int {
	i := int(key)
	return i if i < PADS else -1
}

// [rt]
@(private)
router_process :: proc(self: rawptr, ctx: ^fc.Process_Context) {
	r := (^Router)(self)
	out := ctx.events_out
	if out == nil do return
	for s in rt.spsc_pop(&r.settings) do router_set(r, s, out)
	// Asked to silence everything: every voice of every pad, at once.
	for &t in r.tracks do t.count = 0
	if want := intrinsics.atomic_load(&r.silence); want != r.silenced {
		r.silenced = want
		for i in 0 ..< PADS do track_push(r, i, {0, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = fc.NOTE_KEY_ALL}})
		r.holding = {}
	}
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
			// Pitch bend, the mod wheel and channel pressure: to the synth
			// the notes from there play, as its wheels and aftertouch.
			if status == 0xE0 || status == 0xD0 || (status == 0xB0 && v.bytes[1] == 1) {
				t := armed_listener(r, int(v.port), int((v.bytes[0] & 15) + 1))
				if t >= 0 && r.kinds[t] == .Plugin {
					track_push(r, t, e) // (a plug-in: as MIDI)
					continue
				}
				if t < 0 || r.kinds[t] != .Synth do continue
				param: fc.Param_Id
				value: f64
				switch status {
				case 0xE0:
					param = synth.global_param(.Pitch_Wheel)
					value = (f64(int(v.bytes[2] & 0x7F) << 7 | int(v.bytes[1] & 0x7F)) - 8192) / 8192
				case 0xD0:
					param = synth.global_param(.Aftertouch)
					value = f64(v.bytes[1] & 0x7F) / 127
				case:
					param = synth.global_param(.Mod_Wheel)
					value = f64(v.bytes[2] & 0x7F) / 127
				}
				track_push(r, t, {e.offset, fc.Param_Value{param = param, value = clamp(value, -1, 1)}})
				continue
			}
			if status != 0x90 && status != 0x80 do continue
			key := v.bytes[1] & 0x7F
			on := status == 0x90 && v.bytes[2] > 0
			vel := f32(v.bytes[2]) / 127
			ch := (v.bytes[0] & 15) + 1
			// An armed track listening to this port (and channel): it plays,
			// chromatically (the key's distance from C3 its pitch).
			if t := armed_listener(r, int(v.port), int(ch)); t >= 0 {
				h := Hit{pad = u8(t), on = on, velocity = vel, pitch = i8(int(key) - KEYS_CENTER), keyboard = true}
				r.keys_pad[key] = h.pad
				fc.event_writer_push(&live, {e.offset, note(on, KEYS_CHANNEL, key, vel)})
				rt.spsc_push(&r.taken, Taken{hit = h, beat = beat, playing = playing, midi_key = i16(key)})
				if on do intrinsics.atomic_add(&r.midi_in_hits[t], 1)
				continue
			}
			// Else the drum map, for tracks that take any port's MIDI.
			p := r.midi_map[key]
			if p >= 0 && r.in_port[p] != IN_ALL do p = -1
			rt.spsc_push(&r.taken, Taken{hit = {pad = u8(max(p, 0)), on = on, velocity = vel}, beat = beat, playing = playing, midi_key = i16(key), no_pad = p < 0})
			if p >= 0 {
				fc.event_writer_push(&live, {e.offset, note(on, 0, pad_key(int(p)), vel)})
				if on do intrinsics.atomic_add(&r.midi_in_hits[p], 1)
			}
		case fc.Note_On, fc.Note_Off, fc.Note_Expression:
			sound(r, out, e) // the sequencer (a note's pitch comes as its expression)
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
	// A slicer's sequencer note that came without a pitch: its first slice.
	for &w, i in r.waiting do if w.set {
		slice_on(r, i, w.offset, w.id, 0, w.velocity)
		w.set = false
	}
}

// Events a track's device can be sent in one block.
TRACK_EVENTS :: 96

// One track's events for its device this block.
Track_Events :: struct {
	events: [TRACK_EVENTS]fc.Event,
	count:  int,
}

// What the router needs of a slicer track.
Slicer_Play :: struct {
	base: u8,   // the key of its first slice
	mono: bool, // a slice cuts off the one before
}

// [rt] Event `e` for track `i`'s device (dropped when its block is full).
@(private)
track_push :: proc "contextless" (r: ^Router, i: int, e: fc.Event) {
	if i < 0 || i >= PADS do return
	t := &r.tracks[i]
	if t.count >= TRACK_EVENTS do return
	t.events[t.count] = e
	t.count += 1
}

// [rt] Slice `slice` of slicer track `i` starts (note `id`; mono: the one
// before stops).
@(private)
slice_on :: proc "contextless" (r: ^Router, i: int, offset: u32, id: fc.Note_Id, slice: int, velocity: f32) {
	s := r.slicers[i]
	if s.mono do track_push(r, i, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = fc.NOTE_KEY_ALL}})
	key := u8(clamp(int(s.base) + slice, 0, 127))
	if id != fc.NOTE_ID_ANY {
		r.sounding[i][r.sounding_at[i] % KEYED_NOTES] = {id, key}
		r.sounding_at[i] += 1
	}
	track_push(r, i, {offset, fc.Note_On{id = id, key = key, velocity = velocity}})
}

// Notes a keyed track remembers the keys of.
KEYED_NOTES :: 32

// [rt] The key keyed track `i`'s note `id` sounds on (forgotten now), or
// `fallback`.
@(private)
sounding_key :: proc "contextless" (r: ^Router, i: int, id: fc.Note_Id, fallback: u8) -> u8 {
	if id == fc.NOTE_ID_ANY do return fallback
	for &n in r.sounding[i] do if n.id == id && id != 0 {
		n.id = 0
		return n.key
	}
	return fallback
}

// [rt] Whether track `i` plays a key a note (a slicer's slices, a synth's
// pitches) rather than its one key.
@(private)
keyed :: #force_inline proc "contextless" (r: ^Router, i: int) -> bool {
	return r.kinds[i] == .Slicer || r.kinds[i] == .Synth || r.kinds[i] == .Plugin
}

// [rt] The key slice `slice` of slicer track `i` plays on.
@(private)
slice_key :: proc "contextless" (r: ^Router, i: int, slice: int) -> u8 {
	return u8(clamp(int(r.slicers[i].base) + slice, 0, 127))
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
			if old := r.keys_id[v.key]; old != 0 do track_push(r, i, {e.offset, fc.Note_Off{id = old, key = sounding_key(r, i, old, pad_key(i)) if keyed(r, i) else pad_key(i)}})
			r.keys_id[v.key] = id
			if keyed(r, i) { // the key's distance from C3: which slice
				slice_on(r, i, e.offset, id, int(v.key) - KEYS_CENTER, v.velocity)
			} else {
				track_push(r, i, {e.offset, fc.Note_On{id = id, key = pad_key(i), velocity = v.velocity}})
				track_push(r, i, {e.offset, fc.Note_Expression{id = id, key = pad_key(i), kind = .Tuning, value = f64(int(v.key) - KEYS_CENTER)}})
			}
			midi_send(r, out, e.offset, i, true, v.velocity)
			return
		}
		i := pad_of_key(v.key)
		if i < 0 do return
		if !strike(r, out, e.offset, i) do return
		if keyed(r, i) {
			if v.id == fc.NOTE_ID_ANY {
				slice_on(r, i, e.offset, fc.NOTE_ID_ANY, 0, v.velocity) // the pad hit: its first slice
			} else { // the sequencer's: which slice comes in its pitch, next
				if r.waiting[i].set do slice_on(r, i, r.waiting[i].offset, r.waiting[i].id, 0, r.waiting[i].velocity)
				r.waiting[i] = {v.id, v.velocity, e.offset, true}
			}
		} else {
			x := v
			x.channel = 0
			track_push(r, i, {e.offset, x})
		}
		midi_send(r, out, e.offset, i, true, v.velocity)
	case fc.Note_Off:
		if v.channel == KEYS_CHANNEL {
			i := int(r.keys_pad[v.key])
			if id := r.keys_id[v.key]; id != 0 {
				if r.modes[i] == .Gate || r.modes[i] == .Loop || keyed(r, i) do track_push(r, i, {e.offset, fc.Note_Off{id = id, key = sounding_key(r, i, id, pad_key(i)) if keyed(r, i) else pad_key(i)}})
				r.keys_id[v.key] = 0
			}
			midi_send(r, out, e.offset, i, false, 0)
			return
		}
		i := pad_of_key(v.key)
		if i < 0 do return
		x := v
		x.channel = 0
		if keyed(r, i) {
			// (A note-off before its pitch came: it starts first.)
			if r.waiting[i].set && r.waiting[i].id == v.id {
				slice_on(r, i, r.waiting[i].offset, v.id, 0, r.waiting[i].velocity)
				r.waiting[i].set = false
			}
			x.key = slice_key(r, i, 0) if v.id == fc.NOTE_ID_ANY else sounding_key(r, i, v.id, slice_key(r, i, 0))
			track_push(r, i, {e.offset, x}) // (a slice that doesn't gate plays on: its zone is one-shot)
		} else if r.modes[i] != .Hold {
			// One-shot and Hold pads play on (the sampler ignores the
			// note-off of a one-shot zone; Hold stops on its next hit).
			track_push(r, i, {e.offset, x})
		}
		midi_send(r, out, e.offset, i, false, 0)
	case fc.Note_Expression:
		i := pad_of_key(v.key)
		// A slicer's waiting note: its pitch is which slice.
		if i >= 0 && keyed(r, i) && v.kind == .Tuning && r.waiting[i].set && r.waiting[i].id == v.id {
			w := r.waiting[i]
			slice_on(r, i, w.offset, w.id, int(math.round(v.value)), w.velocity)
			r.waiting[i].set = false
			return
		}
		if i >= 0 && keyed(r, i) && v.kind == .Tuning do return // (pitch picks the slice, not the tuning)
		track_push(r, i, e)
	case fc.Note_Choke:
		if v.key == fc.NOTE_KEY_ALL {
			for k in 0 ..< PADS do track_push(r, k, e)
		} else {
			track_push(r, pad_of_key(v.key), {e.offset, fc.Note_Choke{id = v.id, key = fc.NOTE_KEY_ALL}})
		}
	case fc.Param_Value, fc.Param_Ramp, fc.Midi_Raw:
		fc.event_writer_push(out, e)
	}
}

// [rt] Before pad `i` sounds: choke its group. False if it should not sound
// (a Hold pad hit a second time stops instead).
@(private)
strike :: proc "contextless" (r: ^Router, out: ^fc.Event_Writer, offset: u32, i: int) -> bool {
	if r.modes[i] == .Hold && r.holding[i] {
		track_push(r, i, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = fc.NOTE_KEY_ALL}})
		r.holding[i] = false
		return false
	}
	if g := r.groups[i]; g != 0 {
		for other in 0 ..< PADS do if other != i && r.groups[other] == g {
			track_push(r, other, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = fc.NOTE_KEY_ALL}})
			r.holding[other] = false
		}
	}
	if r.modes[i] == .Hold do r.holding[i] = true
	intrinsics.atomic_add(&r.played, 1)
	intrinsics.atomic_add(&r.struck[i], 1)
	return true
}

// [rt] Pad `i`'s MIDI out, if it has one (to its port; 255, none open,
// goes nowhere).
@(private)
midi_send :: proc "contextless" (r: ^Router, out: ^fc.Event_Writer, offset: u32, i: int, on: bool, velocity: f32) {
	m := r.midi_out[i]
	if !m.on do return // (no port open: the host drops it, but it counts as sent)
	status := (0x90 if on else 0x80) | (m.channel & 15)
	vel := u8(clamp(velocity * 127 + 0.5, 1, 127)) if on else 64
	fc.event_writer_push(out, {offset, fc.Midi_Raw{bytes = {status, m.key & 127, vel}, port = r.out_port[i]}})
	if on do intrinsics.atomic_add(&r.midi_out_hits[i], 1)
}

// A pad's MIDI in takes any port's (the drum map).
IN_ALL :: i16(-2)
// A pad's MIDI in takes none.
IN_NONE :: i16(-1)

// [rt] The armed track that listens to input port `port` on channel `ch`
// (1..16), or -1: one on that port first, else an armed synth taking any
// port's MIDI (a synth is played by keys, not by the drum map).
@(private)
armed_listener :: proc "contextless" (r: ^Router, port, ch: int) -> int {
	for i in 0 ..< PADS {
		if !r.armed[i] || int(r.in_port[i]) != port do continue
		if c := r.in_channel[i]; c != 0 && int(c) != ch do continue
		return i
	}
	for i in 0 ..< PADS do if r.armed[i] && (r.kinds[i] == .Synth || r.kinds[i] == .Plugin) && r.in_port[i] == IN_ALL do return i
	return -1
}
