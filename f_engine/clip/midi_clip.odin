/*
Clips: musical content that plays on the clock's timelines.

A `Midi_Clip` holds notes (with per-note expression) and controller events,
in beats. It is immutable once built: the app keeps its own editable model
and builds a new clip after each edit, then hands it to the players, which
swap it in at their next block. Clips are reference counted, so one clip can
play in several places.

	b: clip.Midi_Builder
	clip.midi_builder_init(&b, length = 4)
	n := clip.add_note(&b, start = 0, length = 1, key = 60, velocity = 0.8)
	clip.add_expression(&b, n, at = 0.5, kind = .Tuning, value = 1) // bend up a semitone
	clip.add_controller(&b, at = 2, bytes = {0xB0, 74, 100})        // CC 74
	c, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)

	node, player := clip.midi_player_create({timeline = song})
	clip.midi_player_set(player, c, {loop = true}) // loops the clip from the timeline's beat 0
	clip.midi_clip_release(c)                     // the player keeps its own reference

Audio clips (`Audio_Clip`, `audio_player_create`) play regions of files
through `fire:stream`, at their own speed or following the tempo.
Automation clips (`Automation_Clip`, `automation_player_create`) move node
parameters along curves, sample-accurately. See /guides/clips/ for placing
clips in arrangements and launchers.
*/
package clip

import "core:mem"
import "core:slice"

import "fire:core"
import tb "fire:timebase"

// One note of a clip.
Note :: struct {
	start:      tb.Beats, // from the clip's start
	length:     tb.Beats, // > 0
	key:        u8,       // 0..127
	channel:    u8,       // 0..15
	velocity:   f32,      // 0..1
	release:    f32,      // release velocity, 0..1
	expression: [2]int,   // range [first, first + count) in `Midi_Clip.expression`
}

// A per-note expression change, `at` beats after the note starts.
Expression_Point :: struct {
	at:    tb.Beats,
	kind:  core.Note_Expression_Kind,
	value: f64, // range depends on `kind` (see core.Note_Expression_Kind)
}

// A MIDI 1.0 channel message (control change, pitch bend, channel or key
// pressure, program change) at a position in the clip.
Controller :: struct {
	at:    tb.Beats,
	bytes: [3]u8,
}

// An immutable MIDI clip. Build with `Midi_Builder`; read its fields freely
// but never change them (players read them on the audio thread). Release
// with `midi_clip_release`.
Midi_Clip :: struct {
	length:      tb.Beats,           // the clip's length in beats
	loop_start:  tb.Beats,           // the part repeated when a placement loops
	loop_end:    tb.Beats,
	notes:       []Note,             // sorted by start, then key
	expression:  []Expression_Point, // grouped by note, each group sorted by `at`
	controllers: []Controller,       // sorted by `at`
	refs:        int,                // control thread
	allocator:   mem.Allocator,
}

// Collects notes and events for a clip. Control thread.
Midi_Builder :: struct {
	length:      tb.Beats,
	loop_start:  tb.Beats,
	loop_end:    tb.Beats,
	notes:       [dynamic]Note,
	expression:  [dynamic]Builder_Expression,
	controllers: [dynamic]Controller,
}

@(private)
Builder_Expression :: struct {
	note:  int,
	point: Expression_Point,
}

// Starts a clip of `length` beats, looping over all of it.
midi_builder_init :: proc(b: ^Midi_Builder, length: tb.Beats, allocator := context.allocator) {
	b^ = {length = length, loop_end = length}
	b.notes = make([dynamic]Note, allocator)
	b.expression = make([dynamic]Builder_Expression, allocator)
	b.controllers = make([dynamic]Controller, allocator)
}

// Frees the builder (not the clips built from it).
midi_builder_destroy :: proc(b: ^Midi_Builder) {
	delete(b.notes)
	delete(b.expression)
	delete(b.controllers)
	b^ = {}
}

// Adds a note; returns its index for `add_expression`. Notes may be added in
// any order.
add_note :: proc(b: ^Midi_Builder, start, length: tb.Beats, key: u8, velocity: f32, channel: u8 = 0, release: f32 = 0.5) -> int {
	append(&b.notes, Note{start = start, length = max(length, 1e-6), key = min(key, 127), channel = channel & 15, velocity = clamp(velocity, 0, 1), release = clamp(release, 0, 1)})
	return len(b.notes) - 1
}

// Adds an expression change to note `note`, `at` beats after it starts.
add_expression :: proc(b: ^Midi_Builder, note: int, at: tb.Beats, kind: core.Note_Expression_Kind, value: f64) {
	append(&b.expression, Builder_Expression{note, {at, kind, value}})
}

// Adds a channel message at `at` (`bytes[0]` is the status byte).
add_controller :: proc(b: ^Midi_Builder, at: tb.Beats, bytes: [3]u8) {
	append(&b.controllers, Controller{at, bytes})
}

// Adds everything in clip `c` (notes with their expression, and
// controllers), `offset` beats later: to edit a clip, merge recordings into
// it (overdub), or join clips. The builder's length and loop are unchanged.
add_clip :: proc(b: ^Midi_Builder, c: ^Midi_Clip, offset: tb.Beats = 0) {
	for n in c.notes {
		i := add_note(b, n.start + offset, n.length, n.key, n.velocity, n.channel, n.release)
		for x in c.expression[n.expression[0]:][:n.expression[1]] do add_expression(b, i, x.at, x.kind, x.value)
	}
	for k in c.controllers do add_controller(b, k.at + offset, k.bytes)
}

// Sets the part a looping placement repeats (default: the whole clip).
set_loop :: proc(b: ^Midi_Builder, start, end: tb.Beats) {
	b.loop_start, b.loop_end = start, end
}

// Makes an immutable clip from the builder's contents, with one reference
// held by the caller. The builder can keep being edited and built again.
midi_build :: proc(b: ^Midi_Builder, allocator := context.allocator) -> (c: ^Midi_Clip, err: core.Error) {
	if !(b.length > 0) || b.loop_start < 0 || b.loop_end <= b.loop_start || b.loop_end > b.length {
		return nil, .Invalid_Argument
	}
	c = new(Midi_Clip, allocator)
	if c == nil do return nil, .Out_Of_Memory
	c^ = {length = b.length, loop_start = b.loop_start, loop_end = b.loop_end, refs = 1, allocator = allocator}

	// Sort notes by start, then key (stable), remembering where each went.
	Order :: struct {
		start: tb.Beats,
		key:   u8,
		index: int,
	}
	order := make([]Order, len(b.notes), context.temp_allocator)
	for &o, i in order do o = {b.notes[i].start, b.notes[i].key, i}
	slice.stable_sort_by(order, proc(x, y: Order) -> bool { return x.start < y.start || (x.start == y.start && x.key < y.key) })
	new_index := make([]int, len(b.notes), context.temp_allocator)
	for o, i in order do new_index[o.index] = i

	exprs := slice.clone(b.expression[:], context.temp_allocator)
	for &e in exprs do e.note = new_index[e.note] if e.note >= 0 && e.note < len(new_index) else -1
	slice.stable_sort_by(exprs, proc(x, y: Builder_Expression) -> bool {
		return x.note < y.note || (x.note == y.note && x.point.at < y.point.at)
	})

	ae: mem.Allocator_Error
	c.notes, ae = make([]Note, len(b.notes), allocator)
	if ae != nil do return build_failed(c)
	for o, i in order do c.notes[i] = b.notes[o.index]
	c.expression, ae = make([]Expression_Point, len(exprs), allocator)
	if ae != nil do return build_failed(c)
	// exprs is sorted by note: hand out consecutive ranges.
	k := 0
	for e in exprs do if e.note < 0 do k += 1 // expression for unknown notes: dropped (they sort first)
	skip := k
	for &n, i in c.notes {
		first := k - skip
		for k < len(exprs) && exprs[k].note == i {
			c.expression[k - skip] = exprs[k].point
			k += 1
		}
		n.expression = {first, k - skip - first}
	}
	c.expression = c.expression[:k - skip]
	c.controllers, ae = slice.clone(b.controllers[:], allocator)
	if ae != nil do return build_failed(c)
	slice.stable_sort_by(c.controllers, proc(x, y: Controller) -> bool { return x.at < y.at })
	return c, .None
}

// Control thread. Adds a reference (one per place the clip is kept).
midi_clip_retain :: proc(c: ^Midi_Clip) {
	if c != nil do c.refs += 1
}

// Control thread. Drops a reference; the clip is freed with the last one.
midi_clip_release :: proc(c: ^Midi_Clip) {
	if c == nil do return
	c.refs -= 1
	if c.refs > 0 do return
	delete(c.notes, c.allocator)
	delete(c.expression, c.allocator)
	delete(c.controllers, c.allocator)
	free(c, c.allocator)
}

// Frees a partly built clip (its unset slices are nil).
@(private)
build_failed :: proc(c: ^Midi_Clip) -> (^Midi_Clip, core.Error) {
	midi_clip_release(c)
	return nil, .Out_Of_Memory
}
