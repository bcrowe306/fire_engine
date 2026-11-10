package pads_model

import "core:math"

import app "app:core"
import "fire:clip"
import "fire:dsp"
import "fire:sampler"
import tb "fire:timebase"

// Steps a song can have.
SONG_STEPS :: 64

// One step of a song: a sequence slot, played `repeats` times.
Song_Step :: struct {
	slot:    u8,
	repeats: u8, // 1..16
}

// The song: sequence slots one after another (Koala's chain).
Song :: struct {
	steps: [SONG_STEPS]Song_Step,
	count: int,
	loop:  bool, // back to the first step after the last (otherwise it stops)
}

// When a sequence picked while playing takes over.
Switch_At :: enum u8 {
	End,  // at the end of the playing sequence
	Bar,  // at the next bar
	Beat, // at the next beat
	Now,  // at once (on the next frame)
}

// Names, as the UI shows them.
SWITCH_NAMES := [Switch_At]cstring{.End = "At sequence end", .Bar = "Next bar", .Beat = "Next beat", .Now = "At once"}

// --- editing the song ----------------------------------------------------------------------

// Replaces the song with `new`, undoably.
set_song :: proc(m: ^Model, name: string, new: Song) {
	if m.project.song == new do return
	app.set_value(&m.history, name, {3000, 0}, m.project.song, new, proc(ctx: rawptr, k: app.Key, v: Song) {
		mm := (^Model)(ctx)
		mm.project.song = v
		if mm.project.song_mode do mm.engine.seq_dirty = true
	})
	app.seal(&m.history)
}

// Adds slot `slot` at the end of the song (or after step `after`).
song_add :: proc(m: ^Model, slot: int, after := -1, repeats := 1) {
	s := m.project.song
	if s.count >= SONG_STEPS do return
	at := s.count if after < 0 else clamp(after + 1, 0, s.count)
	copy(s.steps[at + 1:s.count + 1], s.steps[at:s.count])
	s.steps[at] = {u8(slot), u8(clamp(repeats, 1, 16))}
	s.count += 1
	set_song(m, "Add to Song", s)
}

// Removes step `i`.
song_remove :: proc(m: ^Model, i: int) {
	s := m.project.song
	if i < 0 || i >= s.count do return
	copy(s.steps[i:s.count - 1], s.steps[i + 1:s.count])
	s.count -= 1
	s.steps[s.count] = {}
	set_song(m, "Remove from Song", s)
}

// Moves step `from` to `to`.
song_move :: proc(m: ^Model, from, to: int) {
	s := m.project.song
	if from < 0 || from >= s.count || to < 0 || to >= s.count || from == to do return
	step := s.steps[from]
	if from < to do copy(s.steps[from:to], s.steps[from + 1:to + 1])
	else do copy(s.steps[to + 1:from + 1], s.steps[to:from])
	s.steps[to] = step
	set_song(m, "Move in Song", s)
}

// Sets how many times step `i` plays.
song_repeats :: proc(m: ^Model, i, repeats: int) {
	s := m.project.song
	if i < 0 || i >= s.count do return
	s.steps[i].repeats = u8(clamp(repeats, 1, 16))
	set_song(m, "Set Repeats", s)
}

// Merges sequence `from` into sequence `to`: its notes and automation laid
// over `to`'s (which grows to the longer of the two). One undo step.
merge_sequences :: proc(m: ^Model, from, to: int) {
	if from == to || from < 0 || to < 0 || from >= SLOTS || to >= SLOTS do return
	a, b := m.project.sequences[to], m.project.sequences[from]
	notes := make([dynamic]Seq_Note, 0, len(a.notes) + len(b.notes), context.temp_allocator)
	append(&notes, ..a.notes)
	append(&notes, ..b.notes)
	points := make([dynamic]Auto_Point, 0, len(a.points) + len(b.points), context.temp_allocator)
	append(&points, ..a.points)
	append(&points, ..b.points)
	a.notes, a.points = notes[:], points[:]
	a.bars = max(a.bars, b.bars)
	set_sequence(m, to, .Notes, "Merge Sequences", a)
}

// The song's length in beats.
song_beats :: proc(p: ^Project) -> f64 {
	total := 0.0
	for st in p.song.steps[:p.song.count] do total += seq_beats(p.sequences[st.slot]) * f64(max(st.repeats, 1))
	return total
}

// --- what plays ----------------------------------------------------------------------------

// A stretch of what the sequencer plays: sequence `slot`, its notes
// repeated every `period` beats from `start` for `span` beats (clip beats).
Segment :: struct {
	slot:   int,
	start:  f64,
	span:   f64,
	period: f64,
	step:   int, // the song step, or -1
}

// What the sequencer plays, as one clip placed at timeline beat `at`: its
// segments, and the part that loops (loop_end 0: nothing loops; it ends).
Plan :: struct {
	segs:       [SONG_STEPS + 2]Segment,
	count:      int,
	loop_start: f64,
	loop_end:   f64,
	at:         f64,
}

// Sequence `slot` looping from timeline beat `at`.
plan_pattern :: proc(p: ^Project, slot: int, at: f64) -> (pl: Plan) {
	l := seq_beats(p.sequences[slot])
	pl.segs[0] = {slot, 0, l, l, -1}
	pl.count, pl.loop_start, pl.loop_end, pl.at = 1, 0, l, at
	return
}

// What plays now (`cur`, a pattern) until timeline beat `b`, then sequence
// `slot` looping from there.
plan_switch :: proc(p: ^Project, cur: Plan, slot: int, b: f64) -> (pl: Plan) {
	first := cur.segs[0]
	span := max(b - cur.at, 0)
	l := seq_beats(p.sequences[slot])
	pl.segs[0] = {first.slot, 0, span, first.period, -1}
	pl.segs[1] = {slot, span, l, l, -1}
	pl.count, pl.loop_start, pl.loop_end, pl.at = 2, span, span + l, cur.at
	return
}

// The song from timeline beat `at`.
plan_song :: proc(p: ^Project, at: f64) -> (pl: Plan) {
	start := 0.0
	for st, i in p.song.steps[:p.song.count] {
		l := seq_beats(p.sequences[st.slot])
		span := l * f64(max(st.repeats, 1))
		pl.segs[i] = {int(st.slot), start, span, l, i}
		start += span
	}
	pl.count, pl.at = p.song.count, at
	if p.song.loop do pl.loop_start, pl.loop_end = 0, start
	return
}

// Where timeline beat `beat` falls in plan `pl`: the segment, its slot,
// and the beat within the sequence; false before the plan starts or after
// it ends.
plan_locate :: proc(pl: Plan, beat: f64) -> (seg: int, slot: int, rel: f64, ok: bool) {
	pl := pl
	if pl.count == 0 do return
	x := beat - pl.at
	if x < 0 do return
	if pl.loop_end > pl.loop_start && x >= pl.loop_end {
		x = pl.loop_start + math.mod(x - pl.loop_start, pl.loop_end - pl.loop_start)
	}
	for s, i in pl.segs[:pl.count] {
		if x >= s.start && x < s.start + s.span {
			return i, s.slot, math.mod(x - s.start, s.period), true
		}
	}
	return
}

// Where the plan ends on the timeline (for a song that doesn't loop), or
// 0 if it loops.
plan_end :: proc(pl: Plan) -> f64 {
	pl := pl
	if pl.loop_end > pl.loop_start || pl.count == 0 do return 0
	last := pl.segs[pl.count - 1]
	return pl.at + last.start + last.span
}

// The clip that plays plan `pl`: each segment's notes on the pads' keys,
// swung, with their chance and pitch.
plan_clip :: proc(p: ^Project, pl: Plan) -> ^clip.Midi_Clip {
	pl := pl
	length := 0.0
	for s in pl.segs[:pl.count] do length = max(length, s.start + s.span)
	if length <= 0 do return nil
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, tb.Beats(length))
	defer clip.midi_builder_destroy(&b)
	if pl.loop_end > pl.loop_start do clip.set_loop(&b, tb.Beats(pl.loop_start), tb.Beats(pl.loop_end))
	else do clip.set_loop(&b, 0, tb.Beats(length))
	for sg in pl.segs[:pl.count] {
		s := p.sequences[sg.slot]
		l := seq_beats(s)
		g := tb.Beats(grid_beats(s.swing_grid))
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for n in s.notes {
				if n.start >= l || int(n.pad) >= PADS || off + n.start >= sg.span - 1e-9 do continue
				start := clip.swing(tb.Beats(n.start), g, f64(s.swing))
				end := clip.swing(tb.Beats(min(n.start + n.length, l)), g, f64(s.swing))
				at := tb.Beats(sg.start + off) + start
				i := clip.add_note(&b, at, max(end - start, 1e-3), pad_key(int(n.pad)), n.velocity, channel = SEQ_CHANNEL, probability = n.probability)
				if n.pitch != 0 do clip.add_expression(&b, i, 0, .Tuning, f64(n.pitch))
			}
		}
	}
	c, err := clip.midi_build(&b)
	return c if err == .None else nil
}

// Pad `pad`'s automation clips for plan `pl` (into its sampler, its EQ
// and its fader), or nil for any with nothing to play.
plan_automation :: proc(p: ^Project, pl: Plan, pad: int) -> (voice, eq, fader: ^clip.Automation_Clip) {
	pl := pl
	length := 0.0
	for s in pl.segs[:pl.count] do length = max(length, s.start + s.span)
	if length <= 0 do return
	vb, eb, fb: clip.Automation_Builder
	clip.automation_builder_init(&vb, tb.Beats(length), context.temp_allocator)
	clip.automation_builder_init(&eb, tb.Beats(length), context.temp_allocator)
	clip.automation_builder_init(&fb, tb.Beats(length), context.temp_allocator)
	defer clip.automation_builder_destroy(&vb)
	defer clip.automation_builder_destroy(&eb)
	defer clip.automation_builder_destroy(&fb)
	any_voice, any_eq, any_fader := false, false, false
	for sg in pl.segs[:pl.count] {
		s := p.sequences[sg.slot]
		l := seq_beats(s)
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for pt in s.points {
				if int(pt.pad) != pad || pt.beat > l || off + pt.beat > sg.span do continue
				at := tb.Beats(sg.start + off + pt.beat)
				v := f64(pt.value)
				switch pt.param {
				case .Volume:  clip.automation_add_point(&fb, dsp.GAIN_PARAM_DB, at, v); any_fader = true
				case .Pitch:   clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_TRANSPOSE, at, math.round(v), .Step); any_voice = true
				case .Eq_Low:  clip.automation_add_point(&eb, dsp.eq_band_param(0, .Gain_Db), at, v); any_eq = true
				case .Eq_Mid:  clip.automation_add_point(&eb, dsp.eq_band_param(1, .Gain_Db), at, v); any_eq = true
				case .Eq_High: clip.automation_add_point(&eb, dsp.eq_band_param(2, .Gain_Db), at, v); any_eq = true
				}
			}
		}
	}
	lo, hi := tb.Beats(pl.loop_start), tb.Beats(pl.loop_end)
	if pl.loop_end <= pl.loop_start do lo, hi = 0, tb.Beats(length)
	clip.automation_set_loop(&vb, lo, hi)
	clip.automation_set_loop(&eb, lo, hi)
	clip.automation_set_loop(&fb, lo, hi)
	if any_voice do voice, _ = clip.automation_build(&vb)
	if any_eq do eq, _ = clip.automation_build(&eb)
	if any_fader do fader, _ = clip.automation_build(&fb)
	return
}
