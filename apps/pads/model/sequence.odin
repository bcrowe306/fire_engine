package pads_model

import "core:math"
import "core:mem"
import "core:slice"

import app "app:core"
import "fire:clip"
import fc "fire:core"

// Sequence slots in a project.
SLOTS :: 64
// The longest a sequence can be, in bars.
MAX_BARS :: 64
// Beats in a bar (Pads is in 4/4).
BEATS_PER_BAR :: 4

// One note of a sequence: a pad hit, held for `length` beats.
Seq_Note :: struct {
	start:       f64, // beats from the sequence's start
	length:      f64, // beats, > 0
	pad:         u8,  // 0..PADS-1
	pitch:       i8,  // semitones from the pad's own pitch (keyboard mode)
	velocity:    f32, // 0..1
	probability: f32, // 0..1: the chance it plays each time round
	muted:       bool, // kept in place, but silent
}

// A note grid: quantize and swing step, and the editor's snap.
Grid :: enum u8 {
	Quarter,         // 1/4
	Eighth,          // 1/8
	Eighth_Triplet,  // 1/8T
	Sixteenth,       // 1/16
	Sixteenth_Triplet,
	Thirty_Second,
	Thirty_Second_Triplet,
	Sixty_Fourth,
}

// Grid names, as the UI shows them.
GRID_NAMES := [Grid]cstring{
	.Quarter = "1/4", .Eighth = "1/8", .Eighth_Triplet = "1/8T", .Sixteenth = "1/16",
	.Sixteenth_Triplet = "1/16T", .Thirty_Second = "1/32", .Thirty_Second_Triplet = "1/32T", .Sixty_Fourth = "1/64",
}

// A grid step in beats (quarter notes).
grid_beats :: proc "contextless" (g: Grid) -> f64 {
	switch g {
	case .Quarter:               return 1
	case .Eighth:                return 0.5
	case .Eighth_Triplet:        return 1.0 / 3
	case .Sixteenth:             return 0.25
	case .Sixteenth_Triplet:     return 1.0 / 6
	case .Thirty_Second:         return 0.125
	case .Thirty_Second_Triplet: return 1.0 / 12
	case .Sixty_Fourth:          return 0.0625
	}
	return 0.25
}

// A sequence: notes for the pads over `bars` bars, looping. A value: its
// notes slice is its own (clone_sequence copies it).
Sequence :: struct {
	bars:       int,  // 1..MAX_BARS
	swing:      f32,  // 0..1 (see clip.swing)
	swing_grid: Grid, // which notes swing: 1/8 or 1/16
	notes:      []Seq_Note, // sorted by start, then pad
	points:     []Auto_Point, // automation, sorted by lane, then beat
	ccs:        []Seq_Cc,     // MIDI CC lanes, sorted by pad, controller, beat
	name:       [24]u8, // "" = "Sequence N"
	bpm:        f64,    // its own tempo (it takes over when it plays); 0 = the project's
	color:      u32,    // 0xRRGGBB; 0 = its slot's colour from SEQ_PALETTE
	loops:      [PADS]f32, // each track's own loop, beats (0: none; see `track_beats`)
}

// One step of a pad's MIDI CC lane: controller `cc` goes to `value` at
// `beat` (and stays there until the next).
Seq_Cc :: struct {
	beat:  f64,
	pad:   u8,
	cc:    u8, // 0..127
	value: u8, // 0..127
}

// The CC events of pad `pad`'s controller `cc` in `s` (a view into s.ccs)
// and where they start.
cc_points :: proc(s: Sequence, pad, cc: int) -> (points: []Seq_Cc, first: int) {
	lo, hi := -1, -1
	for c, i in s.ccs do if int(c.pad) == pad && int(c.cc) == cc {
		if lo < 0 do lo = i
		hi = i + 1
	}
	if lo < 0 do return nil, 0
	return s.ccs[lo:hi], lo
}

// Replaces pad `pad`'s controller `cc` events from beat `lo` to `hi` of
// slot `slot` with `events` (drawn, or nothing: erased): one undo step.
replace_cc_range :: proc(m: ^Model, slot, pad, cc: int, lo, hi: f64, events: []Seq_Cc) {
	s := m.project.sequences[slot]
	out := make([dynamic]Seq_Cc, 0, len(s.ccs) + len(events), context.temp_allocator)
	for c in s.ccs {
		if int(c.pad) == pad && int(c.cc) == cc && c.beat >= lo - 1e-9 && c.beat <= hi + 1e-9 do continue
		append(&out, c)
	}
	append(&out, ..events)
	s.ccs = out[:]
	set_sequence(m, slot, .Notes, "Draw CC", s)
	app.seal(&m.history)
}

// Adds one CC event to slot `slot` (one undo step).
add_cc :: proc(m: ^Model, slot: int, c: Seq_Cc) {
	s := m.project.sequences[slot]
	out := make([dynamic]Seq_Cc, 0, len(s.ccs) + 1, context.temp_allocator)
	append(&out, ..s.ccs)
	cc := c
	cc.cc, cc.value = min(cc.cc, 127), min(cc.value, 127)
	append(&out, cc)
	s.ccs = out[:]
	set_sequence(m, slot, .Notes, "Add CC", s)
}

// Moves CC event `index` of slot `slot` (drags merge).
set_cc :: proc(m: ^Model, slot, index: int, c: Seq_Cc) {
	s := m.project.sequences[slot]
	if index < 0 || index >= len(s.ccs) do return
	out := slice.clone(s.ccs, context.temp_allocator)
	cc := c
	cc.cc, cc.value = min(cc.cc, 127), min(cc.value, 127)
	out[index] = cc
	s.ccs = out
	set_sequence(m, slot, .Automation, "Move CC", s)
}

// Colours sequences take by their slot, until given one.
SEQ_PALETTE := [8]u32{0x58a6ff, 0xf5a623, 0x7ee787, 0xff7b72, 0xd2a8ff, 0x56d4dd, 0xffa657, 0xf778ba}

// Sequence `slot`'s colour.
sequence_color :: proc(p: ^Project, slot: int) -> u32 {
	c := p.sequences[slot].color
	return c if c != 0 else SEQ_PALETTE[slot % len(SEQ_PALETTE)]
}

// What an automation lane moves.
Lane_Param :: enum u8 {
	Volume, // dB
	Pitch,  // semitones (whole)
	Eq_Low, // dB
	Eq_Mid,
	Eq_High,
	Cutoff,    // Hz
	Resonance, // percent
	// A plug-in pad's parameters (which: `Pad.plugin_lanes`), 0..100 % of
	// each one's range.
	Plugin_1, Plugin_2, Plugin_3, Plugin_4, Plugin_5, Plugin_6, Plugin_7, Plugin_8,
}

// Lane names, as the UI shows them.
LANE_NAMES := [Lane_Param]cstring{.Volume = "Volume", .Pitch = "Pitch", .Eq_Low = "EQ low", .Eq_Mid = "EQ mid", .Eq_High = "EQ high", .Cutoff = "Cutoff", .Resonance = "Resonance",
	.Plugin_1 = "Plug-in 1", .Plugin_2 = "Plug-in 2", .Plugin_3 = "Plug-in 3", .Plugin_4 = "Plug-in 4",
	.Plugin_5 = "Plug-in 5", .Plugin_6 = "Plug-in 6", .Plugin_7 = "Plug-in 7", .Plugin_8 = "Plug-in 8"}

// A lane parameter's range, in its units.
lane_range :: proc "contextless" (p: Lane_Param) -> (lo, hi: f32) {
	switch p {
	case .Volume:                   return -48, 12
	case .Pitch:                    return -24, 24
	case .Eq_Low, .Eq_Mid, .Eq_High: return -15, 15
	case .Cutoff:                   return 20, 20_000
	case .Resonance:                return 0, 100
	case .Plugin_1 ..= .Plugin_8:   return 0, 100
	}
	return 0, 1
}

// Which track an automation's target is on (.None: it is one of a pad's
// own lanes, `Lane.pad`'s `Lane.param`).
Auto_Track :: enum u8 {
	None,
	Pad,
	Bus,
	Main,
}

// Which of a track's devices an automation moves.
Auto_Device :: enum u8 {
	Sound,  // a pad's instrument (sampler, synth, plug-in): any of its parameters
	Insert, // a pad's insert `slot`, or a bus's or main's effect `slot`
	Volume, // a pad's, a bus's or main's fader
	Pan,    // a bus's or main's pan (a pad's is its Sound's)
	Send,   // a pad's send `slot` (into bus slot + 1)
	Eq,     // a pad's EQ
}

// What an automation moves, anywhere: a parameter of a device of a track,
// and its range (plain units, as the device's node gave it when the
// automation was made, so it can be drawn without the node).
Auto_Target :: struct {
	track:   Auto_Track,
	index:   u8, // the pad, or the bus (0-based; main: 0)
	device:  Auto_Device,
	slot:    u8, // the insert or the send
	param:   fc.Param_Id, // the device's parameter (Volume and Send: the gain's dB; Pan: the pan's position)
	lo, hi:  f32,
	stepped: bool, // whole values only
	log:     bool, // drawn on a log scale (frequencies)
}

// An automation lane: one of a pad's own (`pad`'s `param`, with no
// target) or any parameter (`target`).
Lane :: struct {
	pad:    u8,
	param:  Lane_Param,
	target: Auto_Target,
}

// Whether two lanes are the same lane.
lane_equal :: proc "contextless" (a, b: Lane) -> bool {
	if a.target.track != .None || b.target.track != .None {
		x, y := a.target, b.target
		return x.track == y.track && x.index == y.index && x.device == y.device && x.slot == y.slot && x.param == y.param
	}
	return a.pad == b.pad && a.param == b.param
}

// The order lanes are kept in (a sequence's points sorted by lane, then
// beat).
lane_less :: proc "contextless" (a, b: Lane) -> bool {
	x, y := a.target, b.target
	if x.track != y.track do return x.track < y.track
	if x.track == .None {
		if a.pad != b.pad do return a.pad < b.pad
		return a.param < b.param
	}
	if x.index != y.index do return x.index < y.index
	if x.device != y.device do return x.device < y.device
	if x.slot != y.slot do return x.slot < y.slot
	return x.param < y.param
}

// Lane `l`'s range, in its units.
lane_range_of :: proc "contextless" (l: Lane) -> (lo, hi: f32) {
	if l.target.track != .None {
		if l.target.hi > l.target.lo do return l.target.lo, l.target.hi
		return 0, 1
	}
	return lane_range(l.param)
}

// One point of an automation lane: the lane's parameter is `value` at
// `beat`, moving to the next point in a line (or a curve). A lane is every
// point with the same lane.
Auto_Point :: struct {
	using lane: Lane,
	beat:  f64,
	value: f32, // in the parameter's units (see lane_range_of)
	curve: f32, // the segment to the next point: 0 a line, -1..1 bending (as clip's Curve tension)
}

// Pad `pad`'s own `param` lane.
pad_lane :: proc "contextless" (pad: int, param: Lane_Param) -> Lane {
	return {pad = u8(pad), param = param}
}

// The points of lane `l` in `s` (a view into s.points) and where they
// start.
lane_points_of :: proc(s: Sequence, l: Lane) -> (points: []Auto_Point, first: int) {
	lo, hi := -1, -1
	for p, i in s.points do if lane_equal(p.lane, l) {
		if lo < 0 do lo = i
		hi = i + 1
	}
	if lo < 0 do return nil, 0
	return s.points[lo:hi], lo
}

// The points of pad `pad`'s `param` lane in `s` (a view into s.points) and
// where they start.
lane_points :: proc(s: Sequence, pad: int, param: Lane_Param) -> (points: []Auto_Point, first: int) {
	lo, hi := -1, -1
	for p, i in s.points do if p.target.track == .None && int(p.pad) == pad && p.param == param {
		if lo < 0 do lo = i
		hi = i + 1
	}
	if lo < 0 do return nil, 0
	return s.points[lo:hi], lo
}

// Adds a point to slot `slot`'s automation (one undo step).
add_point :: proc(m: ^Model, slot: int, p: Auto_Point) {
	s := m.project.sequences[slot]
	points := make([dynamic]Auto_Point, 0, len(s.points) + 1, context.temp_allocator)
	append(&points, ..s.points)
	pp := p
	lo, hi := lane_range_of(p.lane)
	pp.value = clamp(pp.value, lo, hi)
	append(&points, pp)
	s.points = points[:]
	set_sequence(m, slot, .Notes, "Add Automation", s)
}

// Moves point `index` of slot `slot`'s automation (drags merge).
set_point :: proc(m: ^Model, slot, index: int, p: Auto_Point) {
	s := m.project.sequences[slot]
	if index < 0 || index >= len(s.points) do return
	points := slice.clone(s.points, context.temp_allocator)
	pp := p
	lo, hi := lane_range_of(p.lane)
	pp.value = clamp(pp.value, lo, hi)
	points[index] = pp
	s.points = points
	set_sequence(m, slot, .Automation, "Move Automation", s)
}

// Removes point `index` of slot `slot`'s automation.
remove_point :: proc(m: ^Model, slot, index: int) {
	s := m.project.sequences[slot]
	if index < 0 || index >= len(s.points) do return
	points := make([dynamic]Auto_Point, 0, len(s.points), context.temp_allocator)
	for p, i in s.points do if i != index do append(&points, p)
	s.points = points[:]
	set_sequence(m, slot, .Notes, "Delete Automation", s)
}

// Removes pad `pad`'s `param` lane from slot `slot`.
clear_lane :: proc(m: ^Model, slot, pad: int, param: Lane_Param) {
	clear_lane_of(m, slot, pad_lane(pad, param))
}

// Removes lane `l` from slot `slot`.
clear_lane_of :: proc(m: ^Model, slot: int, l: Lane) {
	s := m.project.sequences[slot]
	points := make([dynamic]Auto_Point, 0, len(s.points), context.temp_allocator)
	for p in s.points do if !lane_equal(p.lane, l) do append(&points, p)
	s.points = points[:]
	set_sequence(m, slot, .Notes, "Clear Automation", s)
}

// An empty one-bar sequence.
default_sequence :: proc() -> Sequence {
	return {bars = 1, swing_grid = .Sixteenth}
}

// The sequence's length in beats (its bars at the project's time
// signature).
seq_beats :: proc "contextless" (p: ^Project, s: Sequence) -> f64 {
	return f64(s.bars) * bar_beats(p)
}

// A bar's length in beats (quarter notes) at the project's time signature:
// 4 in 4/4, 3 in 3/4, 3 in 6/8.
bar_beats :: proc "contextless" (p: ^Project) -> f64 {
	ts := p.transport.time_sig
	if ts.num <= 0 || ts.den <= 0 do return BEATS_PER_BAR
	return f64(ts.num) * 4 / f64(ts.den)
}

// A copy of `s` with its own notes.
clone_sequence :: proc(s: Sequence, allocator := context.allocator) -> Sequence {
	c := s
	c.notes = slice.clone(s.notes, allocator)
	c.points = slice.clone(s.points, allocator)
	c.ccs = slice.clone(s.ccs, allocator)
	return c
}

// Frees `s`'s notes.
delete_sequence :: proc(s: ^Sequence) {
	delete(s.notes)
	delete(s.points)
	delete(s.ccs)
	s.notes, s.points, s.ccs = nil, nil, nil
}

// Which part of a sequence an edit changes: consecutive edits of the same
// part of the same slot merge into one undo step (a drag, a record pass).
Seq_Field :: enum {
	Notes,
	Note_Drag,
	Velocity,
	Probability,
	Record,
	Bars,
	Swing,
	Automation,
	Name,
	Tempo,
	Paint, // notes drawn in one drag (one undo step)
	Erase, // notes swept away in one drag
	Color,
	Mute,
	Track_Loop,
}

// The beats pad `pad`'s part of sequence `s` goes round in: its own
// loop (polymeter: 3 beats in a 4/4 bar drifts against it, starting again
// at each of the sequence's passes), or the sequence.
track_beats :: proc(p: ^Project, s: Sequence, pad: int) -> f64 {
	l := seq_beats(p, s)
	if pad < 0 || pad >= PADS do return l
	if x := f64(s.loops[pad]); x > 0 && x < l - 1e-9 do return x
	return l
}

// Sets pad `pad`'s loop in sequence `slot` to `beats` (0 or the sequence's
// length or more: none), undoably.
set_track_loop :: proc(m: ^Model, slot, pad: int, beats: f64) {
	if slot < 0 || slot >= SLOTS || pad < 0 || pad >= PADS do return
	s := m.project.sequences[slot]
	l := seq_beats(&m.project, s)
	b := f32(0) if beats <= 0 || beats >= l - 1e-9 else f32(max(beats, 1.0 / 16))
	if s.loops[pad] == b do return
	s.loops[pad] = b
	set_sequence(m, slot, .Track_Loop, "Track Loop", s)
	m.engine.audio_dirty = true // (an audio track's mix goes round in it)
}

// Sequence `s`'s notes as they play: a looped track's (those inside its
// loop) again each time round it, to the sequence's end, each cut at its
// loop's end; the others as they are. Temporary allocator; sorted as
// `s.notes` is only when nothing loops.
played_notes :: proc(p: ^Project, s: Sequence) -> []Seq_Note {
	any := false
	for x in s.loops do if x > 0 do any = true
	if !any do return s.notes
	l := seq_beats(p, s)
	out := make([dynamic]Seq_Note, 0, len(s.notes) * 2, context.temp_allocator)
	for n in s.notes {
		t := track_beats(p, s, int(n.pad))
		if t >= l - 1e-9 {
			append(&out, n)
			continue
		}
		if n.start >= t - 1e-9 do continue // (past its loop: not heard)
		for off := 0.0; n.start + off < l - 1e-9; off += t {
			x := n
			x.start += off
			x.length = min(n.length, t - n.start, l - x.start)
			append(&out, x)
		}
	}
	return out[:]
}

// Replaces slot `slot`'s sequence with `new` (copied), undoably, as an edit
// of `field` named `name`. Edits of the same field merge until the history
// is sealed.
set_sequence :: proc(m: ^Model, slot: int, field: Seq_Field, name: string, new: Sequence) {
	if slot < 0 || slot >= SLOTS do return
	old := m.project.sequences[slot]
	n := clone_sequence(new)
	kept := resolve_overlaps(n.notes)
	delete(n.notes)
	n.notes = kept
	sort_notes(n.notes)
	slice.sort_by(n.points, proc(x, y: Auto_Point) -> bool {
		if !lane_equal(x.lane, y.lane) do return lane_less(x.lane, y.lane)
		return x.beat < y.beat
	})
	slice.sort_by(n.ccs, proc(x, y: Seq_Cc) -> bool {
		if x.pad != y.pad do return x.pad < y.pad
		if x.cc != y.cc do return x.cc < y.cc
		return x.beat < y.beat
	})
	if sequences_equal(old, n) {
		delete_sequence(&n)
		return
	}
	c := new_clone(Set_Sequence{slot = slot, field = field, old = clone_sequence(old), new = n})
	app.execute(&m.history, {vtable = &set_sequence_vtable, data = c, name = name})
}

@(private)
Set_Sequence :: struct {
	slot:  int,
	field: Seq_Field,
	old:   Sequence,
	new:   Sequence,
}

@(private)
set_sequence_vtable := app.Command_VTable {
	apply = proc(data: rawptr, ctx: rawptr) {
		c := (^Set_Sequence)(data)
		put_sequence((^Model)(ctx), c.slot, c.new)
	},
	revert = proc(data: rawptr, ctx: rawptr) {
		c := (^Set_Sequence)(data)
		put_sequence((^Model)(ctx), c.slot, c.old)
	},
	merge = proc(data: rawptr, next: rawptr) -> bool {
		a, b := (^Set_Sequence)(data), (^Set_Sequence)(next)
		if a.slot != b.slot || a.field != b.field || a.field == .Notes do return false
		delete_sequence(&a.new)
		a.new = b.new
		b.new = {}
		return true
	},
	destroy = proc(data: rawptr, allocator: mem.Allocator) {
		c := (^Set_Sequence)(data)
		delete_sequence(&c.old)
		delete_sequence(&c.new)
		free(c)
	},
}

@(private)
put_sequence :: proc(m: ^Model, slot: int, s: Sequence) {
	delete_sequence(&m.project.sequences[slot])
	m.project.sequences[slot] = clone_sequence(s)
	m.engine.seq_dirty = true
}

@(private)
sequences_equal :: proc(a, b: Sequence) -> bool {
	return a.bars == b.bars && a.swing == b.swing && a.swing_grid == b.swing_grid && a.name == b.name && a.bpm == b.bpm && a.color == b.color && a.loops == b.loops && slice.equal(a.notes, b.notes) && slice.equal(a.points, b.points) && slice.equal(a.ccs, b.ccs)
}

// Notes of one pad and pitch never overlap: taken in order (later ones are
// newer and win), a note cuts an older one that starts before it short (to
// end where it starts), removes one that starts at the same time or inside
// it, and pushes the start of one that runs on past its end (that part
// stays). Returns what is kept, as a new slice.
resolve_overlaps :: proc(notes: []Seq_Note, allocator := context.allocator) -> []Seq_Note {
	EPS :: 1e-9
	kept := make([dynamic]Seq_Note, 0, len(notes), allocator)
	for x in notes {
		x_end := x.start + x.length
		for k := 0; k < len(kept); {
			o := &kept[k]
			if o.pad != x.pad || o.pitch != x.pitch {
				k += 1
				continue
			}
			o_end := o.start + o.length
			if o_end <= x.start + EPS || o.start >= x_end - EPS { // apart
				k += 1
				continue
			}
			if o.start < x.start - EPS {
				o.length = x.start - o.start // the older one ends where this starts
				k += 1
			} else if o.start > x.start + EPS && o_end > x_end + EPS {
				o.length, o.start = o_end - x_end, x_end // its tail outlasts this one
				k += 1
			} else {
				ordered_remove(&kept, k) // covered: gone
			}
		}
		append(&kept, x)
	}
	return kept[:]
}

@(private)
sort_notes :: proc(notes: []Seq_Note) {
	slice.sort_by(notes, proc(x, y: Seq_Note) -> bool {
		if x.start != y.start do return x.start < y.start
		return x.pad < y.pad
	})
}

// The current slot's sequence (read it; change it with set_sequence).
current_sequence :: proc(m: ^Model) -> Sequence {
	return m.project.sequences[m.project.slot]
}

// Adds a note to slot `slot` (one undo step).
add_note :: proc(m: ^Model, slot: int, n: Seq_Note) {
	s := m.project.sequences[slot]
	notes := make([dynamic]Seq_Note, 0, len(s.notes) + 1, context.temp_allocator)
	append(&notes, ..s.notes)
	nn := n
	nn.length = max(nn.length, 1.0 / 64)
	if nn.probability == 0 do nn.probability = 1
	append(&notes, nn)
	s.notes = notes[:]
	set_sequence(m, slot, .Notes, "Add Note", s)
}

// Removes the notes of slot `slot` at `indices` (one undo step).
remove_notes :: proc(m: ^Model, slot: int, indices: []int, name := "Delete Note") {
	s := m.project.sequences[slot]
	notes := make([dynamic]Seq_Note, 0, len(s.notes), context.temp_allocator)
	for n, i in s.notes do if !slice.contains(indices, i) do append(&notes, n)
	s.notes = notes[:]
	set_sequence(m, slot, .Notes, name, s)
}

// Changes note `index` of slot `slot` to `n`, as an edit of `field`
// (moves and resizes while dragging merge, as do velocity changes).
set_note :: proc(m: ^Model, slot, index: int, n: Seq_Note, field: Seq_Field, name: string) {
	s := m.project.sequences[slot]
	if index < 0 || index >= len(s.notes) do return
	// The edited note last: it is the newest, so it wins where it overlaps.
	notes := make([dynamic]Seq_Note, 0, len(s.notes), context.temp_allocator)
	for x, i in s.notes do if i != index do append(&notes, x)
	append(&notes, n)
	s.notes = notes[:]
	set_sequence(m, slot, field, name, s)
}

// Empties slot `slot`.
clear_sequence :: proc(m: ^Model, slot: int) {
	s := m.project.sequences[slot]
	s.notes, s.points = nil, nil
	set_sequence(m, slot, .Notes, "Clear Sequence", s)
}

// Sets slot `slot`'s length. Notes past the new end are kept (they come
// back if it grows again) but do not play.
set_bars :: proc(m: ^Model, slot, bars: int) {
	s := m.project.sequences[slot]
	s.bars = clamp(bars, 1, MAX_BARS)
	set_sequence(m, slot, .Bars, "Set Length", s)
}

// Doubles slot `slot`: twice as long, its notes repeated in the new half.
double_sequence :: proc(m: ^Model, slot: int) {
	s := m.project.sequences[slot]
	if s.bars * 2 > MAX_BARS do return
	length := seq_beats(&m.project, s)
	notes := make([dynamic]Seq_Note, 0, len(s.notes) * 2, context.temp_allocator)
	for n in s.notes do if n.start < length do append(&notes, n)
	count := len(notes)
	for i in 0 ..< count {
		n := notes[i]
		n.start += length
		append(&notes, n)
	}
	s.notes = notes[:]
	points := make([dynamic]Auto_Point, 0, len(s.points) * 2, context.temp_allocator)
	for p in s.points do if p.beat < length do append(&points, p)
	pc := len(points)
	for i in 0 ..< pc {
		p := points[i]
		p.beat += length
		append(&points, p)
	}
	s.points = points[:]
	s.bars *= 2
	set_sequence(m, slot, .Notes, "Double Sequence", s)
}

// Sets slot `slot`'s swing.
set_swing :: proc(m: ^Model, slot: int, swing: f32, grid: Grid) {
	s := m.project.sequences[slot]
	s.swing, s.swing_grid = clamp(swing, 0, 1), grid
	set_sequence(m, slot, .Swing, "Set Swing", s)
}

// Moves slot `slot`'s notes towards `grid` by `strength` (1 = onto it), as
// one undo step. Notes are never moved past the sequence's end.
quantize_sequence :: proc(m: ^Model, slot: int, grid: Grid, strength: f64 = 1) {
	s := m.project.sequences[slot]
	notes := slice.clone(s.notes, context.temp_allocator)
	g := grid_beats(grid)
	length := seq_beats(&m.project, s)
	for &n in notes {
		q := quantize_beat(n.start, g)
		if q >= length do q -= g
		n.start += (q - n.start) * strength
	}
	s.notes = notes
	set_sequence(m, slot, .Notes, "Quantize", s)
}

// `beat` rounded to the nearest multiple of `step`.
quantize_beat :: proc "contextless" (beat, step: f64) -> f64 {
	return math.round(beat / step) * step if step > 0 else beat
}

// Copies slot `from` onto slot `to`.
copy_sequence :: proc(m: ^Model, from, to: int) {
	if from == to do return
	set_sequence(m, to, .Notes, "Paste Sequence", m.project.sequences[from])
}

// Makes `slot` the current one (what plays and is edited): at once when
// stopped; while playing, when `switch_at` says. Not undoable: a view, not
// an edit.
select_slot :: proc(m: ^Model, slot: int) {
	if slot < 0 || slot >= SLOTS do return
	queue_slot(&m.engine, slot)
}

// Sets whether sequence pads play while held (else they launch), undoably.
set_launch_hold :: proc(m: ^Model, on: bool) {
	app.set_value(&m.history, "Launch Mode", {app.Id(LAUNCH_HOLD_KEY), 0}, m.project.launch_hold, on, proc(ctx: rawptr, k: app.Key, v: bool) {
		(^Model)(ctx).project.launch_hold = v
	})
	app.seal(&m.history)
}

@(private) LAUNCH_HOLD_KEY :: 0x7fff_0001

// Sets whether a launched sequence carries on where the playhead is (else
// it starts from its top), undoably.
set_launch_continue :: proc(m: ^Model, on: bool) {
	app.set_value(&m.history, "Launch Continue", {app.Id(LAUNCH_HOLD_KEY), 1}, m.project.launch_continue, on, proc(ctx: rawptr, k: app.Key, v: bool) {
		(^Model)(ctx).project.launch_continue = v
	})
	app.seal(&m.history)
}

// Whether slot `slot` holds anything: notes, automation, an audio take, a
// name or a tempo of its own.
slot_used :: proc(m: ^Model, slot: int) -> bool {
	s := &m.project.sequences[slot]
	if len(s.notes) > 0 || len(s.points) > 0 || s.name[0] != 0 || s.bpm > 0 do return true
	for c in m.project.clips[slot] do if c.sample != 0 do return true
	return false
}

// The General MIDI drum key a drum file's kick is on (A1 when importing drums).
GM_KICK :: 36

// How a MIDI file's notes find pads (see `import_midi`).
Midi_Import :: enum u8 {
	Drums,     // General MIDI drums: key 36 (the kick) is A1, 37 is A2, ...; keys below 36 are skipped
	By_Map,    // each key plays the pad the MIDI map gives it (by default key N is pad N); other keys are skipped
	On_Pad,    // every note plays pad `pad`, pitched (a melody or a bass line)
}

// Reads the MIDI file at `path` into slot `slot`, replacing what is there,
// as one undo step: its notes (every track), as long as the file (whole
// bars, at most MAX_BARS). Returns how many notes it brought in, or -1 if
// the file could not be read.
import_midi :: proc(m: ^Model, path: string, slot: int, how := Midi_Import.Drums, pad := 0) -> int {
	mf, err := clip.midi_file_read(path, context.temp_allocator)
	if err != .None do return -1
	defer clip.midi_file_destroy(&mf)
	notes := make([dynamic]Seq_Note, context.temp_allocator)
	length: f64 = 0
	for tr in mf.tracks {
		c := tr.clip
		if c == nil do continue
		length = max(length, f64(c.length))
		for n in c.notes {
			sn := Seq_Note{start = f64(n.start), length = f64(n.length), velocity = n.velocity, probability = 1}
			switch how {
			case .Drums:
				if n.key < GM_KICK || int(n.key) - GM_KICK >= PADS do continue
				sn.pad = u8(int(n.key) - GM_KICK)
			case .By_Map:
				p := m.project.midi_map[n.key]
				if p < 0 do continue
				sn.pad = u8(p)
			case .On_Pad:
				sn.pad = u8(clamp(pad, 0, PADS - 1))
				sn.pitch = i8(clamp(int(n.key) - KEYS_CENTER, -48, 48))
			}
			append(&notes, sn)
		}
	}
	s := m.project.sequences[slot]
	s.bars = clamp(int(math.ceil(length / bar_beats(&m.project) - 1e-9)), 1, MAX_BARS)
	s.notes = notes[:]
	set_sequence(m, slot, .Notes, "Import MIDI", s)
	return len(notes)
}
