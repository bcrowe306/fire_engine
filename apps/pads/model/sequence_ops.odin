package pads_model

import "core:fmt"
import "core:strings"

import app "app:core"

// Sequences as things to work with: names, their own tempo, duplicating,
// and parts of them copied into others.

// Sequence `slot`'s name: its own, or "Sequence N".
sequence_name :: proc(p: ^Project, slot: int, allocator := context.temp_allocator) -> string {
	s := &p.sequences[slot]
	own := strings.truncate_to_byte(string(s.name[:]), 0)
	if own != "" do return strings.clone(own, allocator)
	return fmt.aprintf("Sequence %d", slot + 1, allocator = allocator)
}

// Renames sequence `slot` ("" goes back to "Sequence N"), undoably.
rename_sequence :: proc(m: ^Model, slot: int, name: string) {
	if slot < 0 || slot >= SLOTS do return
	s := m.project.sequences[slot]
	s.name = {}
	trimmed := strings.trim_space(name)
	if trimmed != fmt.tprintf("Sequence %d", slot + 1) do copy(s.name[:len(s.name) - 1], trimmed)
	set_sequence(m, slot, .Name, "Rename Sequence", s)
	app.seal(&m.history)
}

// Gives sequence `slot` its own tempo (0: the project's), undoably. While
// it plays it sets the tempo, from exactly where it takes over.
set_sequence_tempo :: proc(m: ^Model, slot: int, bpm: f64) {
	if slot < 0 || slot >= SLOTS do return
	s := m.project.sequences[slot]
	s.bpm = clamp(bpm, 40, 300) if bpm > 0 else 0
	set_sequence(m, slot, .Tempo, "Sequence Tempo", s)
}

// The tempo sequence `slot` plays at: its own, or the project's.
sequence_tempo :: proc(p: ^Project, slot: int) -> f64 {
	b := p.sequences[slot].bpm
	return b if b > 0 else p.bpm
}

// The first empty slot after `slot` (going round), or -1 if all are used.
next_empty_slot :: proc(m: ^Model, slot: int) -> int {
	for k in 1 ..< SLOTS {
		i := (slot + k) % SLOTS
		if !slot_used(m, i) do return i
	}
	return -1
}

// Duplicates sequence `from` (its notes, automation, length, swing, tempo,
// its audio takes, named "… copy") into the next empty slot, and selects
// it; one undo step. Returns the new slot, or -1 when none is free.
duplicate_sequence :: proc(m: ^Model, from: int) -> int {
	to := next_empty_slot(m, from)
	if to < 0 do return -1
	app.begin(&m.history, "Duplicate Sequence")
	defer app.end(&m.history)
	s := m.project.sequences[from]
	s.name = {}
	copy(s.name[:len(s.name) - 1], fmt.tprintf("%s copy", sequence_name(&m.project, from)))
	set_sequence(m, to, .Notes, "Duplicate Sequence", s)
	for c, pad in m.project.clips[from] do if c.sample != 0 do set_clip(m, to, pad, "Duplicate Sequence", c)
	app.seal(&m.history)
	select_slot(m, to)
	return to
}

// Part of a sequence, to paste into another: its notes and automation,
// from 0 at the part's start, and how long it is.
Seq_Part :: struct {
	notes:  [dynamic]Seq_Note,
	points: [dynamic]Auto_Point,
	beats:  f64,
	pads:   [PADS]bool, // which pads it holds (a paste replaces only theirs)
	all:    bool,       // every pad
}

// Frees a part.
part_destroy :: proc(c: ^Seq_Part) {
	delete(c.notes)
	delete(c.points)
	c^ = {}
}

// Copies beats `lo` to `hi` of sequence `slot` (the pads in `pads`, or
// every pad when nil) into `out`: notes that start there (cut at `hi`) and
// automation points there.
copy_part :: proc(p: ^Project, slot: int, lo, hi: f64, pads: ^[PADS]bool, out: ^Seq_Part) {
	part_destroy(out)
	out.beats = max(hi - lo, 0)
	out.all = pads == nil
	if pads != nil do out.pads = pads^
	else do for &x in out.pads do x = true
	s := p.sequences[slot]
	for n in s.notes do if n.start >= lo - 1e-9 && n.start < hi - 1e-9 && out.pads[n.pad] {
		x := n
		x.start -= lo
		x.length = min(x.length, out.beats - x.start)
		append(&out.notes, x)
	}
	for pt in s.points do if pt.beat >= lo - 1e-9 && pt.beat <= hi + 1e-9 && out.pads[pt.pad] {
		x := pt
		x.beat -= lo
		append(&out.points, x)
	}
}

// Pastes `part` into sequence `slot` at beat `at`, as one undo step named
// `name`: with `replace`, what its pads had there goes first; otherwise it
// lays over (its notes win where they overlap). The sequence grows to fit
// (up to MAX_BARS).
paste_part :: proc(m: ^Model, slot: int, part: ^Seq_Part, at: f64, replace := true, name := "Paste") {
	if slot < 0 || slot >= SLOTS || part.beats <= 0 do return
	p := &m.project
	s := p.sequences[slot]
	end := at + part.beats
	need := int((end - 1e-9) / bar_beats(p)) + 1
	s.bars = clamp(max(s.bars, need), 1, MAX_BARS)
	notes := make([dynamic]Seq_Note, 0, len(s.notes) + len(part.notes), context.temp_allocator)
	for n in s.notes {
		if replace && part.pads[n.pad] && n.start >= at - 1e-9 && n.start < end - 1e-9 do continue
		append(&notes, n)
	}
	for n in part.notes { // after the old ones: newer, they win
		x := n
		x.start += at
		if x.start < seq_beats(p, s) do append(&notes, x)
	}
	points := make([dynamic]Auto_Point, 0, len(s.points) + len(part.points), context.temp_allocator)
	for pt in s.points {
		if replace && part.pads[pt.pad] && pt.beat >= at - 1e-9 && pt.beat <= end + 1e-9 do continue
		append(&points, pt)
	}
	for pt in part.points {
		x := pt
		x.beat += at
		append(&points, x)
	}
	s.notes, s.points = notes[:], points[:]
	set_sequence(m, slot, .Notes, name, s)
	app.seal(&m.history)
}

// Copies bars `bar_lo`..`bar_hi` (1-based, inclusive) of sequence `from`
// (the pads in `pads`, or all) to sequence `to` from bar `at_bar`,
// replacing or laying over what is there: one undo step.
copy_bars :: proc(m: ^Model, from, bar_lo, bar_hi: int, pads: ^[PADS]bool, to, at_bar: int, replace := true) {
	bb := bar_beats(&m.project)
	part: Seq_Part
	defer part_destroy(&part)
	copy_part(&m.project, from, f64(bar_lo - 1) * bb, f64(bar_hi) * bb, pads, &part)
	paste_part(m, to, &part, f64(at_bar - 1) * bb, replace, "Copy Bars")
}

// Removes the notes of `pads` (or every pad, nil) starting between beats
// `lo` and `hi` of sequence `slot`, undoably.
clear_part :: proc(m: ^Model, slot: int, lo, hi: f64, pads: ^[PADS]bool) {
	s := m.project.sequences[slot]
	notes := make([dynamic]Seq_Note, 0, len(s.notes), context.temp_allocator)
	for n in s.notes {
		if (pads == nil || pads[n.pad]) && n.start >= lo - 1e-9 && n.start < hi - 1e-9 do continue
		append(&notes, n)
	}
	s.notes = notes[:]
	set_sequence(m, slot, .Notes, "Delete Notes", s)
	app.seal(&m.history)
}
