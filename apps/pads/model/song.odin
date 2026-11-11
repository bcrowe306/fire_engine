package pads_model

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "fire:clip"
import "fire:dsp"
import "fire:sampler"
import tb "fire:timebase"

// Steps a song can have.
SONG_STEPS :: 64

// One step of a song: a sequence slot (or part of it: `start` and
// `length` beats of it), played `repeats` times; muted, transposed, at its
// own tempo, named, as it says.
Song_Step :: struct {
	slot:      u8,
	repeats:   u8,  // 1..16
	start:     f64, // beats into the sequence it starts at
	length:    f64, // beats it plays from there (0: to the sequence's end)
	mute:      bool, // in the arrangement, but silent
	transpose: i8,  // semitones added to its notes
	bpm:       f64, // its own tempo (0: the sequence's, or the project's)
	label:     [16]u8, // a section's name ("Verse"), shown on the timeline
}

// How many beats step `st` plays each time round (its part of the sequence).
step_period :: proc(p: ^Project, st: Song_Step) -> f64 {
	l := seq_beats(p, p.sequences[st.slot])
	start := clamp(st.start, 0, max(l - 1.0 / 64, 0))
	rest := l - start
	return min(st.length, rest) if st.length > 0 else rest
}

// The tempo song step `i` plays at.
step_tempo :: proc(p: ^Project, i: int) -> f64 {
	st := p.song.steps[i]
	return st.bpm if st.bpm > 0 else sequence_tempo(p, int(st.slot))
}

// Whether two steps play the same (one run of audio, one tempo).
@(private)
steps_alike :: proc(a, b: Song_Step) -> bool {
	return a.slot == b.slot && a.start == b.start && a.length == b.length && a.mute == b.mute && a.transpose == b.transpose && a.bpm == b.bpm
}

// The song's length in seconds, at each step's tempo.
song_seconds :: proc(p: ^Project) -> f64 {
	total := 0.0
	for st, i in p.song.steps[:p.song.count] do total += step_period(p, st) * f64(max(st.repeats, 1)) * 60 / step_tempo(p, i)
	return total
}

// A step's label ("" when it has none).
step_label :: proc(st: ^Song_Step) -> string {
	return strings.truncate_to_byte(string(st.label[:]), 0)
}

// Changes song step `i` to `st`, undoably (drags of one setting merge).
set_step :: proc(m: ^Model, i: int, st: Song_Step, name: string) {
	s := m.project.song
	if i < 0 || i >= s.count do return
	s.steps[i] = st
	set_song(m, name, s)
}

// Arrangements a project keeps (songs: each a chain of steps, exported apart).
ARRANGEMENTS :: 16

// One arrangement: a name, and its song.
Arrangement :: struct {
	name: [24]u8,
	song: Song,
}

// The song: sequence slots one after another (Koala's chain).
Song :: struct {
	steps: [SONG_STEPS]Song_Step,
	count: int,
	// (Whether it goes round is the transport's loop.)
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
	s.steps[at] = {slot = u8(slot), repeats = u8(clamp(repeats, 1, 16))}
	s.count += 1
	set_song(m, "Add to Song", s)
}

// Puts sequence `slot` into the song as step `at` (the steps from there
// move along), undoably.
song_insert :: proc(m: ^Model, slot, at: int, repeats := 1) {
	if at > 0 do song_add(m, slot, at - 1, repeats)
	else do song_add_first(m, slot, repeats)
}

@(private)
song_add_first :: proc(m: ^Model, slot: int, repeats: int) {
	s := m.project.song
	if s.count >= SONG_STEPS do return
	copy(s.steps[1:s.count + 1], s.steps[0:s.count])
	s.steps[0] = {slot = u8(slot), repeats = u8(clamp(repeats, 1, 16))}
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

// A set of song steps (their indices).
Step_Set :: bit_set[0 ..< SONG_STEPS; u64]

// Removes the steps in `sel`: one undo step.
song_remove_steps :: proc(m: ^Model, sel: Step_Set, name := "Remove from Song") {
	s := m.project.song
	out: Song
	for i in 0 ..< s.count do if i not_in sel {
		out.steps[out.count] = s.steps[i]
		out.count += 1
	}
	set_song(m, name, out)
}

// Puts `steps` into the song from step `before` on (the ones there move
// along; as many as fit): one undo step. Returns the steps they became.
song_insert_steps :: proc(m: ^Model, steps: []Song_Step, before: int, name := "Paste Steps") -> (added: Step_Set) {
	s := m.project.song
	at := clamp(before, 0, s.count)
	k := min(len(steps), SONG_STEPS - s.count)
	if k <= 0 do return
	copy(s.steps[at + k:s.count + k], s.steps[at:s.count])
	copy(s.steps[at:at + k], steps[:k])
	s.count += k
	for i in at ..< at + k do added += {i}
	set_song(m, name, s)
	return
}

// Moves the steps in `sel` (in their order) to before step `to` (as the
// song is now; `to` = the count: the end): one undo step. Returns where
// they went.
song_move_steps :: proc(m: ^Model, sel: Step_Set, to: int) -> (moved: Step_Set) {
	s := m.project.song
	picked, rest: Song
	before := 0
	for i in 0 ..< s.count {
		if i in sel {
			picked.steps[picked.count] = s.steps[i]
			picked.count += 1
			if i < to do before += 1
		} else {
			rest.steps[rest.count] = s.steps[i]
			rest.count += 1
		}
	}
	if picked.count == 0 do return
	at := clamp(to - before, 0, rest.count)
	out: Song
	copy(out.steps[:at], rest.steps[:at])
	copy(out.steps[at:at + picked.count], picked.steps[:picked.count])
	copy(out.steps[at + picked.count:rest.count + picked.count], rest.steps[at:rest.count])
	out.count = rest.count + picked.count
	for i in at ..< at + picked.count do moved += {i}
	set_song(m, "Move in Song", out)
	return
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
	for st in p.song.steps[:p.song.count] do total += step_period(p, st) * f64(max(st.repeats, 1))
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
	offset: f64, // beats into the sequence each period starts at (a step's part)
}

// What the sequencer plays, as one clip placed at timeline beat `at`: its
// segments, and the part that loops (loop_end 0: nothing loops; it ends).
Plan :: struct {
	segs:       [SONG_STEPS + 2]Segment,
	alike:      [SONG_STEPS + 2]bool, // a song's segment plays as the one before it (one audio run, one tempo)
	count:      int,
	loop_start: f64,
	loop_end:   f64,
	at:         f64,
}

// Sequence `slot` looping from timeline beat `at`.
plan_pattern :: proc(p: ^Project, slot: int, at: f64) -> (pl: Plan) {
	l := seq_beats(p, p.sequences[slot])
	pl.segs[0] = {slot, 0, l, l, -1, 0}
	pl.count, pl.loop_start, pl.loop_end, pl.at = 1, 0, l, at
	return
}

// What plays now (`cur`, a pattern) until timeline beat `b`, then sequence
// `slot` looping from there.
plan_switch :: proc(p: ^Project, cur: Plan, slot: int, b: f64) -> (pl: Plan) {
	first := cur.segs[0]
	span := max(b - cur.at, 0)
	l := seq_beats(p, p.sequences[slot])
	pl.segs[0] = {first.slot, 0, span, first.period, -1, first.offset}
	pl.segs[1] = {slot, span, l, l, -1, 0}
	pl.alike[1] = first.slot == slot && first.offset == 0
	pl.count, pl.loop_start, pl.loop_end, pl.at = 2, span, span + l, cur.at
	return
}

// The song from timeline beat `at`.
plan_song :: proc(p: ^Project, at: f64) -> (pl: Plan) {
	start := 0.0
	for st, i in p.song.steps[:p.song.count] {
		l := step_period(p, st)
		span := l * f64(max(st.repeats, 1))
		pl.segs[i] = {int(st.slot), start, span, l, i, clamp(st.start, 0, seq_beats(p, p.sequences[st.slot]))}
		pl.alike[i] = i > 0 && steps_alike(p.song.steps[i - 1], st)
		start += span
	}
	pl.count, pl.at = p.song.count, at
	if p.transport.loop do pl.loop_start, pl.loop_end = 0, start
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
			return i, s.slot, s.offset + math.mod(x - s.start, s.period), true
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
		l := seq_beats(p, s)
		g := tb.Beats(grid_beats(s.swing_grid))
		transpose := 0
		if sg.step >= 0 {
			if p.song.steps[sg.step].mute do continue // silent, but there
			transpose = int(p.song.steps[sg.step].transpose)
		}
		lo, hi := sg.offset, min(sg.offset + sg.period, l) // its part of the sequence
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for n in s.notes {
				if n.muted || n.start < lo - 1e-9 || n.start >= hi - 1e-9 || int(n.pad) >= PADS || off + n.start - lo >= sg.span - 1e-9 do continue
				start := clip.swing(tb.Beats(n.start), g, f64(s.swing)) - tb.Beats(lo)
				end := clip.swing(tb.Beats(min(n.start + n.length, hi)), g, f64(s.swing)) - tb.Beats(lo)
				at := tb.Beats(sg.start + off) + start
				i := clip.add_note(&b, at, max(end - start, 1e-3), pad_key(int(n.pad)), n.velocity, channel = SEQ_CHANNEL, probability = n.probability)
				if pitch := int(n.pitch) + transpose; pitch != 0 do clip.add_expression(&b, i, 0, .Tuning, f64(pitch))
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
		l := seq_beats(p, s)
		lo, hi := sg.offset, min(sg.offset + sg.period, l)
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for pt in s.points {
				if int(pt.pad) != pad || pt.beat < lo - 1e-9 || pt.beat > hi + 1e-9 || off + pt.beat - lo > sg.span do continue
				at := tb.Beats(sg.start + off + pt.beat - lo)
				v := f64(pt.value)
				shape := clip.Segment_Shape.Curve if pt.curve != 0 else .Linear
				switch pt.param {
				case .Volume:  clip.automation_add_point(&fb, dsp.GAIN_PARAM_DB, at, v, shape, pt.curve); any_fader = true
				case .Pitch:   clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_TRANSPOSE, at, math.round(v), .Step); any_voice = true
				case .Eq_Low:  clip.automation_add_point(&eb, dsp.eq_band_param(0, .Gain_Db), at, v, shape, pt.curve); any_eq = true
				case .Eq_Mid:  clip.automation_add_point(&eb, dsp.eq_band_param(1, .Gain_Db), at, v, shape, pt.curve); any_eq = true
				case .Eq_High: clip.automation_add_point(&eb, dsp.eq_band_param(2, .Gain_Db), at, v, shape, pt.curve); any_eq = true
				case .Cutoff:    clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_FILTER_CUTOFF, at, v, shape, pt.curve); any_voice = true
				case .Resonance: clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_FILTER_RESONANCE, at, v, shape, pt.curve); any_voice = true
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

// --- arrangements --------------------------------------------------------------------------

// The arrangements, the current one and the song being edited, as one
// value (what an arrangement edit undoes).
@(private)
Arrangements :: struct {
	list:    [ARRANGEMENTS]Arrangement,
	count:   int,
	current: int,
	song:    Song,
}

@(private)
arrangements_of :: proc(p: ^Project) -> (a: Arrangements) {
	// (One assignment each: a tuple of these large arrays costs LLVM minutes at -o:speed.)
	a.list = p.arrangements
	a.song = p.song
	a.count = p.arrangement_count
	a.current = p.arrangement
	a.list[a.current].song = p.song // the one being edited, kept
	return
}

@(private)
put_arrangements :: proc(m: ^Model, name: string, new: Arrangements) {
	old := arrangements_of(&m.project)
	app.set_value(&m.history, name, {app.Id(ARRANGEMENT_KEY), 0}, old, new, proc(ctx: rawptr, key: app.Key, v: Arrangements) {
		m := (^Model)(ctx)
		p := &m.project
		p.arrangements = v.list
		p.song = v.song
		p.arrangement_count = v.count
		p.arrangement = v.current
		m.engine.seq_dirty = true
	})
	app.seal(&m.history)
}

@(private)
ARRANGEMENT_KEY :: 1 << 22

// Arrangement `i`'s name.
arrangement_name :: proc(p: ^Project, i: int) -> string {
	return strings.truncate_to_byte(string(p.arrangements[i].name[:]), 0)
}

// Plays and edits arrangement `i` (its song) from now; the one before is kept.
select_arrangement :: proc(m: ^Model, i: int) {
	p := &m.project
	if i < 0 || i >= p.arrangement_count || i == p.arrangement do return
	a := arrangements_of(p)
	a.current = i
	a.song = a.list[i].song
	put_arrangements(m, "Switch Arrangement", a)
}

// A new empty arrangement after the current one (or, with `copy_of` ≥ 0,
// a copy of that one), selected. Returns it, or -1 when there are
// ARRANGEMENTS already.
add_arrangement :: proc(m: ^Model, copy_of := -1) -> int {
	p := &m.project
	a := arrangements_of(p)
	if a.count >= ARRANGEMENTS do return -1
	at := a.count
	src: Arrangement
	if copy_of >= 0 && copy_of < a.count {
		src = a.list[copy_of]
		src.name = {}
		copy(src.name[:len(src.name) - 1], fmt.tprintf("%s copy", arrangement_name(p, copy_of)))
	} else {
		copy(src.name[:len(src.name) - 1], fmt.tprintf("Song %d", at + 1))
	}
	a.list[at] = src
	a.count += 1
	a.current = at
	a.song = src.song
	put_arrangements(m, "Duplicate Arrangement" if copy_of >= 0 else "New Arrangement", a)
	return at
}

// Renames arrangement `i`.
rename_arrangement :: proc(m: ^Model, i: int, name: string) {
	p := &m.project
	if i < 0 || i >= p.arrangement_count do return
	a := arrangements_of(p)
	a.list[i].name = {}
	copy(a.list[i].name[:len(a.list[i].name) - 1], strings.trim_space(name))
	put_arrangements(m, "Rename Arrangement", a)
}

// Deletes arrangement `i` (not the last one left).
delete_arrangement :: proc(m: ^Model, i: int) {
	p := &m.project
	if i < 0 || i >= p.arrangement_count || p.arrangement_count <= 1 do return
	a := arrangements_of(p)
	copy(a.list[i:a.count - 1], a.list[i + 1:a.count])
	a.count -= 1
	a.list[a.count] = {}
	if a.current >= i do a.current = max(a.current - 1, 0)
	a.song = a.list[a.current].song
	put_arrangements(m, "Delete Arrangement", a)
}

// Where the song is: the step playing, how far through it (0..1, its
// repeats included), and the beat of the song (from its start); -1 when
// the song isn't what plays.
song_progress :: proc(e: ^Engine) -> (step: int, frac: f64, beat: f64) {
	pos, playing := timeline_beat(e)
	if !playing || !e.project.song_mode || e.plan.count == 0 do return -1, 0, -1
	pl := e.plan
	x := pos - pl.at
	if x < 0 do return -1, 0, -1
	if pl.loop_end > pl.loop_start && x >= pl.loop_end do x = pl.loop_start + math.mod(x - pl.loop_start, pl.loop_end - pl.loop_start)
	for s in pl.segs[:pl.count] do if x >= s.start && x < s.start + s.span {
		return s.step, (x - s.start) / max(s.span, 1e-9), x
	}
	return -1, 0, -1
}
