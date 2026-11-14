package pads_api

import "core:strings"

import pf "fire:perform"
import pm "../model"

// Sequences there are (slots 0..SEQUENCES-1).
SEQUENCES :: pm.SLOTS
// The longest a sequence is (bars).
MAX_BARS :: pm.MAX_BARS

// A grid: quantize, swing, input quantize, note repeat and the
// arpeggiator step by one.
Grid :: enum i32 {
	Quarter,
	Eighth,
	Eighth_Triplet,
	Sixteenth,
	Sixteenth_Triplet,
	Thirty_Second,
	Thirty_Second_Triplet,
	Sixty_Fourth, // (not note repeat's nor the arpeggiator's)
}

// A pad's own automation lane (beside any parameter: a Param_Ref).
Pad_Lane :: enum i32 {
	Volume,    // dB
	Pitch,     // semitones
	Eq_Low,    // dB
	Eq_Mid,
	Eq_High,
	Cutoff,    // Hz
	Resonance, // percent
}

// How the arpeggiator walks the held notes.
Arp_Mode :: enum i32 {
	Up,
	Down,
	Up_Down,
	Random,
	As_Played,
}

// Sequence `slot` now (its name: sequence_name).
Sequence_State :: struct {
	used:       bool, // it has notes, automation or takes
	current:    bool, // the one shown and played (Pattern)
	bars:       i64,
	beats:      f64,  // how long it is
	bpm:        f64,  // its own tempo (0: the project's)
	color:      i64,  // 0xRRGGBB, as shown (its own or its slot's)
	swing:      f32,  // 0..1
	swing_grid: Grid,
	notes:      i64,  // sequence_note 0..notes-1
	points:     i64,  // automation points (sequence_point)
	ccs:        i64,  // MIDI CC steps (sequence_cc)
}

// A note.
Note :: struct {
	start:       f64,  // beats from the sequence's top
	length:      f64,  // beats (> 0)
	pad:         i64,  // the pad it plays
	pitch:       i64,  // semitones from the pad's own (-64..63; keyboard mode)
	velocity:    f32,  // 0..1
	probability: f32,  // 0..1: its chance each time round
	muted:       bool, // kept, silent
}

// A MIDI CC step: pad `pad`'s controller `cc` goes to `value` at `beat`.
Cc :: struct {
	beat:  f64,
	pad:   i64,
	cc:    i64, // 0..127
	value: i64, // 0..127
}

// An automation point.
Point :: struct {
	beat:     f64,
	value:    f32,  // in its parameter's units
	curve:    f32,  // the segment to the next: 0 a line, -1..1 bending
	own:      bool, // a pad's own lane (`pad`, `pad_lane`), else a parameter's (`param`)
	pad:      i64,
	pad_lane: Pad_Lane,
	param:    Param_Ref,
}

// A pad's note repeat and arpeggiator (its MIDI effects).
Midi_Fx :: struct {
	repeat:      bool,
	repeat_rate: Grid, // Quarter .. Thirty_Second_Triplet
	repeat_gate: f32,  // 0.05..1 of a step
	arp:         bool,
	arp_mode:    Arp_Mode,
	arp_rate:    Grid,
	arp_octaves: i64,  // 1..4
	arp_gate:    f32,  // 0.05..1
	arp_latch:   bool, // it goes on after the keys are let go
}

// The sequence shown and played (Pattern).
sequence_current :: proc(api: ^Api) -> (i64, Result) {
	return i64(api.core.m.project.slot), .Ok
}

// Sequence `slot` now.
sequence_state :: proc(api: ^Api, slot: i64) -> (Sequence_State, Result) {
	if r := slot_ok(api, slot); r != .Ok do return {}, r
	m := &api.core.m
	p := &m.project
	s := p.sequences[slot]
	return {
		used = pm.slot_used(m, int(slot)), current = int(slot) == p.slot, bars = i64(s.bars), beats = pm.seq_beats(p, s), bpm = s.bpm,
		color = i64(pm.sequence_color(p, int(slot))), swing = s.swing, swing_grid = Grid(s.swing_grid),
		notes = i64(len(s.notes)), points = i64(len(s.points)), ccs = i64(len(s.ccs)),
	}, .Ok
}

// Sequence `slot`'s name: its own, else "Sequence N". Temporary.
sequence_name :: proc(api: ^Api, slot: i64) -> (string, Result) {
	if r := slot_ok(api, slot); r != .Ok do return "", r
	return pm.sequence_name(&api.core.m.project, int(slot)), .Ok
}

// Shows and plays sequence `slot`: at once when stopped; playing, when
// the launch quantize says. Not an edit.
sequence_select :: proc(api: ^Api, slot: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	pm.select_slot(&api.core.m, int(slot))
	return .Ok
}

// Names sequence `slot` (up to 23 bytes; "": "Sequence N" again), undoably.
sequence_set_name :: proc(api: ^Api, slot: i64, name: string) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if len(strings.trim_space(name)) > 23 do return fail(api, .Invalid_Argument, "a sequence's name is up to 23 bytes")
	pm.rename_sequence(&api.core.m, int(slot), name)
	return .Ok
}

// Sets sequence `slot`'s length (1..64 bars), undoably. Notes past the end
// are kept (they come back if it grows) but don't play.
sequence_set_bars :: proc(api: ^Api, slot: i64, bars: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if bars < 1 || bars > MAX_BARS do return fail(api, .Invalid_Argument, "a sequence is 1..64 bars")
	pm.set_bars(&api.core.m, int(slot), int(bars))
	edited(api)
	return .Ok
}

// Gives sequence `slot` its own tempo (40..300 BPM; 0: the project's),
// undoably.
sequence_set_tempo :: proc(api: ^Api, slot: i64, bpm: f64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if bpm != 0 && !(bpm >= 40 && bpm <= 300) do return fail(api, .Invalid_Argument, "the tempo is 40..300 BPM (0: the project's)")
	pm.set_sequence_tempo(&api.core.m, int(slot), bpm)
	edited(api)
	return .Ok
}

// Colours sequence `slot` (0xRRGGBB; 0: its slot's), undoably.
sequence_set_color :: proc(api: ^Api, slot: i64, color: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if color < 0 || color > 0xffffff do return fail(api, .Invalid_Argument, "a colour is 0xRRGGBB")
	pm.set_sequence_color(&api.core.m, int(slot), u32(color))
	return .Ok
}

// Swings sequence `slot`'s off-beats of `grid` (Eighth or Sixteenth) by
// `amount` (0..1), undoably.
sequence_set_swing :: proc(api: ^Api, slot: i64, amount: f32, grid: Grid) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if !(amount >= 0 && amount <= 1) do return fail(api, .Invalid_Argument, "swing is 0..1")
	if grid != .Eighth && grid != .Sixteenth do return fail(api, .Invalid_Argument, "swing is on 1/8 or 1/16")
	pm.set_swing(&api.core.m, int(slot), amount, pm.Grid(grid))
	edited(api)
	return .Ok
}

// Moves sequence `slot`'s notes toward `grid` by `strength` (0..1; 1: onto
// it), undoably.
sequence_quantize :: proc(api: ^Api, slot: i64, grid: Grid, strength: f64 = 1) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if grid < min(Grid) || grid > max(Grid) do return fail(api, .Invalid_Argument, "no such grid")
	if !(strength >= 0 && strength <= 1) do return fail(api, .Invalid_Argument, "strength is 0..1")
	pm.quantize_sequence(&api.core.m, int(slot), pm.Grid(grid), strength)
	edited(api)
	return .Ok
}

// Copies sequence `slot` (all of it, named "… copy") into the next empty
// slot and shows it: which. Not_Found when every slot is used.
sequence_duplicate :: proc(api: ^Api, slot: i64) -> (i64, Result) {
	if r := slot_ok(api, slot); r != .Ok do return -1, r
	to := pm.duplicate_sequence(&api.core.m, int(slot))
	if to < 0 do return -1, fail(api, .Not_Found, "every slot is used")
	edited(api)
	return i64(to), .Ok
}

// Copies sequence `from` onto slot `to` (what was there replaced), undoably.
sequence_copy :: proc(api: ^Api, from, to: i64) -> Result {
	if r := slot_ok(api, from); r != .Ok do return r
	if r := slot_ok(api, to); r != .Ok do return r
	pm.copy_sequence(&api.core.m, int(from), int(to))
	edited(api)
	return .Ok
}

// Doubles sequence `slot`: twice as long, its notes and automation again
// in the new half. Undoably; Invalid_Argument past 64 bars.
sequence_double :: proc(api: ^Api, slot: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if api.core.m.project.sequences[slot].bars * 2 > MAX_BARS do return fail(api, .Invalid_Argument, "it would be longer than 64 bars")
	pm.double_sequence(&api.core.m, int(slot))
	edited(api)
	return .Ok
}

// Empties sequence `slot` (its notes and automation), undoably.
sequence_clear :: proc(api: ^Api, slot: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	pm.clear_sequence(&api.core.m, int(slot))
	edited(api)
	return .Ok
}

// Pad `pad`'s own loop in sequence `slot`: `beats` long (0, or the
// sequence's length or more: none). Undoably.
sequence_set_track_loop :: proc(api: ^Api, slot: i64, pad: i64, beats: f64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if _, r := pad_of(api, pad); r != .Ok do return r
	if beats < 0 do return fail(api, .Invalid_Argument, "a loop is 0 beats or more")
	pm.set_track_loop(&api.core.m, int(slot), int(pad), beats)
	edited(api)
	return .Ok
}

// Note `index` of sequence `slot` (in order: by start, then pad).
sequence_note :: proc(api: ^Api, slot: i64, index: i64) -> (Note, Result) {
	if r := slot_ok(api, slot); r != .Ok do return {}, r
	notes := api.core.m.project.sequences[slot].notes
	if index < 0 || index >= i64(len(notes)) do return {}, fail(api, .Not_Found, "no such note")
	n := notes[index]
	return {start = n.start, length = n.length, pad = i64(n.pad), pitch = i64(n.pitch), velocity = n.velocity, probability = n.probability, muted = n.muted}, .Ok
}

// Adds note `n` to sequence `slot` (where it overlaps one of its pad's and
// pitch, the new one wins): its index. Undoably.
sequence_add_note :: proc(api: ^Api, slot: i64, n: Note) -> (i64, Result) {
	if r := slot_ok(api, slot); r != .Ok do return -1, r
	sn, r := seq_note(api, n)
	if r != .Ok do return -1, r
	pm.add_note(&api.core.m, int(slot), sn)
	edited(api)
	return note_index(api, slot, sn), .Ok
}

// Changes note `index` of sequence `slot` to `n`: its index now (notes stay
// in order). Undoably (a gesture's moves merge).
sequence_set_note :: proc(api: ^Api, slot: i64, index: i64, n: Note) -> (i64, Result) {
	if r := slot_ok(api, slot); r != .Ok do return -1, r
	if index < 0 || index >= i64(len(api.core.m.project.sequences[slot].notes)) do return -1, fail(api, .Not_Found, "no such note")
	sn, r := seq_note(api, n)
	if r != .Ok do return -1, r
	// The step is named for what changed ("Set Velocity"), and merges with
	// the same change's next (a drag).
	old := api.core.m.project.sequences[slot].notes[index]
	field, name := pm.Seq_Field.Note_Drag, "Edit Note"
	x := old
	x.velocity = sn.velocity
	if x == sn && old.velocity != sn.velocity do field, name = .Velocity, "Set Velocity"
	x = old
	x.probability = sn.probability
	if x == sn && old.probability != sn.probability do field, name = .Probability, "Set Chance"
	x = old
	x.muted = sn.muted
	if x == sn && old.muted != sn.muted do field, name = .Mute, "Mute Note"
	pm.set_note(&api.core.m, int(slot), int(index), sn, field, name)
	edited(api)
	return note_index(api, slot, sn), .Ok
}

// Removes the notes `indices` of sequence `slot`: one undo step.
sequence_remove_notes :: proc(api: ^Api, slot: i64, indices: []i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	count := i64(len(api.core.m.project.sequences[slot].notes))
	ix := make([]int, len(indices), context.temp_allocator)
	for x, k in indices {
		if x < 0 || x >= count do return fail(api, .Not_Found, "no such note")
		ix[k] = int(x)
	}
	pm.remove_notes(&api.core.m, int(slot), ix, "Delete Note" if len(ix) == 1 else "Delete Notes")
	edited(api)
	return .Ok
}

// MIDI CC step `index` of sequence `slot` (by pad, controller, beat).
sequence_cc :: proc(api: ^Api, slot: i64, index: i64) -> (Cc, Result) {
	if r := slot_ok(api, slot); r != .Ok do return {}, r
	ccs := api.core.m.project.sequences[slot].ccs
	if index < 0 || index >= i64(len(ccs)) do return {}, fail(api, .Not_Found, "no such CC step")
	c := ccs[index]
	return {beat = c.beat, pad = i64(c.pad), cc = i64(c.cc), value = i64(c.value)}, .Ok
}

// Adds MIDI CC step `c` to sequence `slot`, undoably.
sequence_add_cc :: proc(api: ^Api, slot: i64, c: Cc) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if _, r := pad_of(api, c.pad); r != .Ok do return r
	if c.cc < 0 || c.cc > 127 || c.value < 0 || c.value > 127 || c.beat < 0 do return fail(api, .Invalid_Argument, "a controller and its value are 0..127, at a beat of 0 or more")
	pm.add_cc(&api.core.m, int(slot), {beat = c.beat, pad = u8(c.pad), cc = u8(c.cc), value = u8(c.value)})
	edited(api)
	return .Ok
}

// Removes the MIDI CC steps of pad `pad`'s controller `cc` in sequence
// `slot` from beat `from` to `to`, undoably.
sequence_clear_cc :: proc(api: ^Api, slot: i64, pad: i64, cc: i64, from, to: f64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if _, r := pad_of(api, pad); r != .Ok do return r
	if cc < 0 || cc > 127 || to < from do return fail(api, .Invalid_Argument, "a controller is 0..127, from a beat to a later one")
	pm.replace_cc_range(&api.core.m, int(slot), int(pad), int(cc), from, to, nil)
	return .Ok
}

// Automation point `index` of sequence `slot` (by lane, then beat).
sequence_point :: proc(api: ^Api, slot: i64, index: i64) -> (Point, Result) {
	if r := slot_ok(api, slot); r != .Ok do return {}, r
	pts := api.core.m.project.sequences[slot].points
	if index < 0 || index >= i64(len(pts)) do return {}, fail(api, .Not_Found, "no such point")
	p := pts[index]
	out := Point{beat = p.beat, value = p.value, curve = p.curve}
	if p.target.track == .None {
		out.own, out.pad, out.pad_lane = true, i64(p.pad), Pad_Lane(min(int(p.param), int(max(Pad_Lane))))
	} else {
		t := p.target
		out.param = {track = Track(t.track), index = i64(t.index), device = Device(t.device), slot = i64(t.slot), param = i64(t.param)}
	}
	return out, .Ok
}

// Adds a point to parameter `ref`'s automation in sequence `slot`: at
// `beat`, `value` (its units, in its range), `curve` (-1..1) to the next.
// Undoably.
sequence_add_point :: proc(api: ^Api, slot: i64, ref: Param_Ref, beat: f64, value: f32, curve: f32 = 0) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	info, r := param_info(api, ref)
	if r != .Ok do return r
	if !info.automatable do return fail(api, .Unsupported, "that parameter isn't automated")
	if !(f64(value) >= info.min && f64(value) <= info.max) do return fail(api, .Invalid_Argument, "out of the parameter's range")
	if beat < 0 || !(curve >= -1 && curve <= 1) do return fail(api, .Invalid_Argument, "a point is at a beat of 0 or more, its curve -1..1")
	t := auto_target(ref)
	t.lo, t.hi, t.stepped, t.log = f32(info.min), f32(info.max), info.stepped, info.log
	pad := u8(ref.index) if ref.track == .Pad else 0
	pm.add_point(&api.core.m, int(slot), {lane = {pad = pad, target = t}, beat = beat, value = value, curve = curve})
	edited(api)
	return .Ok
}

// Adds a point to pad `pad`'s own `lane` in sequence `slot`. Undoably.
sequence_add_pad_point :: proc(api: ^Api, slot: i64, pad: i64, lane: Pad_Lane, beat: f64, value: f32, curve: f32 = 0) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if _, r := pad_of(api, pad); r != .Ok do return r
	if lane < min(Pad_Lane) || lane > max(Pad_Lane) do return fail(api, .Invalid_Argument, "no such lane")
	lo, hi := pm.lane_range(pm.Lane_Param(lane))
	if !(value >= lo && value <= hi) do return fail(api, .Invalid_Argument, "out of the lane's range")
	if beat < 0 || !(curve >= -1 && curve <= 1) do return fail(api, .Invalid_Argument, "a point is at a beat of 0 or more, its curve -1..1")
	pm.add_point(&api.core.m, int(slot), {lane = pm.pad_lane(int(pad), pm.Lane_Param(lane)), beat = beat, value = value, curve = curve})
	edited(api)
	return .Ok
}

// Removes automation point `index` of sequence `slot`, undoably.
sequence_remove_point :: proc(api: ^Api, slot: i64, index: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if index < 0 || index >= i64(len(api.core.m.project.sequences[slot].points)) do return fail(api, .Not_Found, "no such point")
	pm.remove_point(&api.core.m, int(slot), int(index))
	edited(api)
	return .Ok
}

// Input quantize: notes recorded move toward `grid` by `strength` (0..1),
// its off-beats swung by `swing` (0..1). Undoably.
sequence_set_input_quantize :: proc(api: ^Api, on: bool, grid: Grid, strength: f32, swing: f32) -> Result {
	if grid < min(Grid) || grid > max(Grid) do return fail(api, .Invalid_Argument, "no such grid")
	if !(strength >= 0 && strength <= 1) || !(swing >= 0 && swing <= 1) do return fail(api, .Invalid_Argument, "strength and swing are 0..1")
	n := api.core.m.project.transport
	n.quantize = {on = on, grid = pm.Grid(grid), strength = strength, swing = swing}
	return set_transport(api, .Quantize, "Input Quantize", n)
}

// Pad `pad`'s note repeat and arpeggiator.
sequence_midi_fx :: proc(api: ^Api, pad: i64) -> (Midi_Fx, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return {}, r
	f := p.midi_fx
	return midi_fx_of(f), .Ok
}

// A pad's MIDI effects as the API says them (a gate of 0: 0.5, its default).
midi_fx_of :: proc(f: pm.Perform) -> Midi_Fx {
	return {repeat = f.repeat_on, repeat_rate = Grid(f.repeat.rate), repeat_gate = f.repeat.gate if f.repeat.gate > 0 else 0.5, arp = f.arp_on, arp_mode = Arp_Mode(f.arp.mode),
		arp_rate = Grid(f.arp.rate), arp_octaves = i64(max(f.arp.octaves, 1)), arp_gate = f.arp.gate if f.arp.gate > 0 else 0.5, arp_latch = f.arp.latch}
}

// Sets pad `pad`'s note repeat and arpeggiator, undoably.
sequence_set_midi_fx :: proc(api: ^Api, pad: i64, fx: Midi_Fx) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	rate_ok :: proc(g: Grid) -> bool { return g >= .Quarter && g <= .Thirty_Second_Triplet }
	if !rate_ok(fx.repeat_rate) || !rate_ok(fx.arp_rate) do return fail(api, .Invalid_Argument, "a rate is 1/4 .. 1/32T")
	if fx.arp_mode < min(Arp_Mode) || fx.arp_mode > max(Arp_Mode) do return fail(api, .Invalid_Argument, "no such arpeggio")
	if fx.arp_octaves < 1 || fx.arp_octaves > 4 do return fail(api, .Invalid_Argument, "the arpeggio spans 1..4 octaves")
	if !(fx.repeat_gate >= 0.05 && fx.repeat_gate <= 1) || !(fx.arp_gate >= 0.05 && fx.arp_gate <= 1) do return fail(api, .Invalid_Argument, "a gate is 0.05..1")
	f := p.midi_fx
	f.repeat_on, f.repeat.rate, f.repeat.gate = fx.repeat, pf.Rate(fx.repeat_rate), fx.repeat_gate
	f.arp_on, f.arp.mode, f.arp.rate = fx.arp, pf.Arp_Mode(fx.arp_mode), pf.Rate(fx.arp_rate)
	f.arp.octaves, f.arp.gate, f.arp.latch = int(fx.arp_octaves), fx.arp_gate, fx.arp_latch
	// The step is named for what changed: the note repeat, the arpeggiator.
	old := p.midi_fx
	name := "MIDI Effect"
	if f.arp_on == old.arp_on && f.arp == old.arp do name = "Note Repeat"
	else if f.repeat_on == old.repeat_on && f.repeat == old.repeat do name = "Arpeggiator"
	pm.set_midi_fx(&api.core.m, int(pad), f, name)
	edited(api)
	return .Ok
}

@(private)
slot_ok :: proc(api: ^Api, slot: i64) -> Result {
	if slot < 0 || slot >= SEQUENCES do return fail(api, .Not_Found, "a sequence is 0..63")
	return .Ok
}

@(private)
seq_note :: proc(api: ^Api, n: Note) -> (pm.Seq_Note, Result) {
	if _, r := pad_of(api, n.pad); r != .Ok do return {}, r
	if n.start < 0 || !(n.length > 0) do return {}, fail(api, .Invalid_Argument, "a note starts at a beat of 0 or more and lasts some")
	if n.pitch < -64 || n.pitch > 63 do return {}, fail(api, .Invalid_Argument, "a note's pitch is -64..63")
	if !(n.velocity > 0 && n.velocity <= 1) || !(n.probability >= 0 && n.probability <= 1) do return {}, fail(api, .Invalid_Argument, "velocity is 0..1 (more than 0), chance 0..1")
	return {start = n.start, length = n.length, pad = u8(n.pad), pitch = i8(n.pitch), velocity = n.velocity, probability = n.probability if n.probability > 0 else 1, muted = n.muted}, .Ok
}

// Where note `n` is now in sequence `slot` (-1: gone, overlapped away).
@(private)
note_index :: proc(api: ^Api, slot: i64, n: pm.Seq_Note) -> i64 {
	for x, k in api.core.m.project.sequences[slot].notes {
		if x.pad == n.pad && x.pitch == n.pitch && abs(x.start - n.start) < 1e-9 do return i64(k)
	}
	return -1
}

