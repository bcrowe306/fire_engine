package pads_model

import "core:math"

import app "app:core"

// What part of the transport's settings an edit changes (edits of the same
// part merge: a dragged level is one step).
Transport_Field :: enum {
	Loop,
	Count_In,
	Metro_Level,
	Metro_Rec_Only,
	Time_Sig,
	Quantize,
	Quantize_Strength,
	Quantize_Swing,
}

// Sets the transport's settings to `new` (part `field`, named `name`),
// undoably.
set_transport :: proc(m: ^Model, field: Transport_Field, name: string, new: Transport) {
	if m.project.transport == new do return
	app.set_value(&m.history, name, {4000, int(field)}, m.project.transport, new, proc(ctx: rawptr, k: app.Key, v: Transport) {
		mm := (^Model)(ctx)
		mm.project.transport = v
		mm.engine.seq_dirty = true // the loop, the bar length
	})
}

// Where the playhead is, as a musician counts it: bar, beat (from 1) and
// sixteenth (from 1), from beat `beat` of a sequence at the project's time
// signature. Before the start (counting in), bar is 0 or below.
position_of :: proc(p: ^Project, beat: f64) -> (bar, beat_in_bar, sixteenth: int) {
	bb := bar_beats(p)
	unit := 4 / f64(max(p.transport.time_sig.den, 1)) // a beat of the signature, in quarters
	b := math.floor(beat / bb + 1e-9)
	in_bar := beat - b * bb
	beat_in_bar = int(math.floor(in_bar / unit + 1e-9)) + 1
	sixteenth = int(math.floor((in_bar - f64(beat_in_bar - 1) * unit) / 0.25 + 1e-9)) + 1
	return int(b) + 1, beat_in_bar, sixteenth
}

// Tap tempo: taps (their times) average into a tempo; a pause of more
// than TAP_RESET seconds starts again.
Tap_Tempo :: struct {
	taps:  [8]f64, // seconds
	count: int,
}

// A pause between taps longer than this (seconds) starts a new tempo.
TAP_RESET :: 2.0

// One tap at `now` seconds (on any steady clock: the app's frame time).
// Returns the tempo the taps so far make (the average of the last
// intervals), or 0 until there are two.
tap :: proc(t: ^Tap_Tempo, now: f64) -> f64 {
	if t.count > 0 && now - t.taps[(t.count - 1) % len(t.taps)] > TAP_RESET do t.count = 0
	t.taps[t.count % len(t.taps)] = now
	t.count += 1
	n := min(t.count, len(t.taps))
	if n < 2 do return 0
	span := now - t.taps[(t.count - n) % len(t.taps)]
	if span <= 0 do return 0
	return clamp(60 * f64(n - 1) / span, 40, 300)
}
