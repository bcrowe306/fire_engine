package pads_model

import "core:math"
import "core:mem"
import "core:slice"

import app "app:core"

// Sequence slots in a project.
SLOTS :: 32
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
}

// An empty one-bar sequence.
default_sequence :: proc() -> Sequence {
	return {bars = 1, swing_grid = .Sixteenth}
}

// The sequence's length in beats.
seq_beats :: proc "contextless" (s: Sequence) -> f64 {
	return f64(s.bars * BEATS_PER_BAR)
}

// A copy of `s` with its own notes.
clone_sequence :: proc(s: Sequence, allocator := context.allocator) -> Sequence {
	c := s
	c.notes = slice.clone(s.notes, allocator)
	return c
}

// Frees `s`'s notes.
delete_sequence :: proc(s: ^Sequence) {
	delete(s.notes)
	s.notes = nil
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
}

// Replaces slot `slot`'s sequence with `new` (copied), undoably, as an edit
// of `field` named `name`. Edits of the same field merge until the history
// is sealed.
set_sequence :: proc(m: ^Model, slot: int, field: Seq_Field, name: string, new: Sequence) {
	if slot < 0 || slot >= SLOTS do return
	old := m.project.sequences[slot]
	n := clone_sequence(new)
	sort_notes(n.notes)
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
	return a.bars == b.bars && a.swing == b.swing && a.swing_grid == b.swing_grid && slice.equal(a.notes, b.notes)
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
	notes := slice.clone(s.notes, context.temp_allocator)
	notes[index] = n
	s.notes = notes
	set_sequence(m, slot, field, name, s)
}

// Empties slot `slot`.
clear_sequence :: proc(m: ^Model, slot: int) {
	s := m.project.sequences[slot]
	s.notes = nil
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
	length := seq_beats(s)
	notes := make([dynamic]Seq_Note, 0, len(s.notes) * 2, context.temp_allocator)
	for n in s.notes do if n.start < length do append(&notes, n)
	count := len(notes)
	for i in 0 ..< count {
		n := notes[i]
		n.start += length
		append(&notes, n)
	}
	s.notes = notes[:]
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
	length := seq_beats(s)
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

// Makes `slot` the current one (what plays and is edited). Not undoable:
// a view, not an edit.
select_slot :: proc(m: ^Model, slot: int) {
	if slot < 0 || slot >= SLOTS || slot == m.project.slot do return
	m.project.slot = slot
	m.engine.seq_dirty = true
}

// Whether slot `slot` holds any notes.
slot_used :: proc(m: ^Model, slot: int) -> bool {
	return len(m.project.sequences[slot].notes) > 0
}
