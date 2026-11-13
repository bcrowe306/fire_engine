package pads_model

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "fire:clip"
import "fire:dsp"
import "fire:sampler"
import "fire:synth"
import tb "fire:timebase"

// Clips a song can have.
SONG_CLIPS :: 128

// Lanes a song can have.
SONG_LANES :: 16

// A lane of the song: its name, and whether it is muted or soloed.
Song_Lane :: struct {
	name: [16]u8,
	mute: bool,
	solo: bool,
}

// A clip of the song: sequence `slot` on lane `lane` from song beat `at`
// for `length` beats, going round its part of the sequence (`start` and
// `part` beats of it; `part` 0: to the sequence's end) as many times as fit
// (the last time cut short); muted, transposed, named, as it says.
Song_Clip :: struct {
	lane:      u8,
	slot:      u8,
	at:        f64, // song beat it starts at
	length:    f64, // beats it plays
	start:     f64, // beats into the sequence its part starts at
	part:      f64, // its part's beats (0: from start to the sequence's end)
	phase:     f64, // beats into its part it begins at (its left edge trimmed: the notes stay where they were)
	transpose: i8,  // semitones added to its notes
	mute:      bool, // in the song, but silent
	label:     [16]u8, // a section's name ("Verse"), shown on the clip
}

// A time signature from song beat `beat` (a bar starts there) on.
Meter_Point :: struct {
	beat: f64,
	sig:  Time_Sig,
}

// Time signature changes a song can have.
MAX_METERS :: 32

// A set of song clips (their indices).
Clip_Set :: bit_set[0 ..< SONG_CLIPS; u128]

// How many beats clip `c` plays each time round (its part of the sequence).
clip_period :: proc(p: ^Project, c: Song_Clip) -> f64 {
	l := seq_beats(p, p.sequences[c.slot])
	start := clamp(c.start, 0, max(l - 1.0 / 64, 0))
	rest := l - start
	return min(c.part, rest) if c.part > 0 else rest
}

// Where clip `c` ends, in song beats.
clip_end :: proc(c: Song_Clip) -> f64 {
	return c.at + c.length
}

// A clip's label ("" when it has none).
clip_label :: proc(c: ^Song_Clip) -> string {
	return strings.truncate_to_byte(string(c.label[:]), 0)
}

// A lane's name ("Lane 1"... when it has none).
lane_name :: proc(s: ^Song, i: int) -> string {
	if i >= 0 && i < SONG_LANES {
		if n := strings.truncate_to_byte(string(s.lanes[i].name[:]), 0); n != "" do return n
	}
	return fmt.tprintf("Lane %d", i + 1)
}

// How many lanes the song shows (at least one, and every clip's).
song_lanes :: proc(s: ^Song) -> int {
	n := max(s.lane_count, 1)
	for c in s.clips[:s.count] do n = max(n, int(c.lane) + 1)
	return min(n, SONG_LANES)
}

// Whether lane `i` is silent: muted, or another one soloed.
lane_silent :: proc(s: ^Song, i: int) -> bool {
	if i < 0 || i >= SONG_LANES do return true
	if s.lanes[i].mute do return true
	for l in s.lanes[:SONG_LANES] do if l.solo do return !s.lanes[i].solo
	return false
}

// Whether clip `i` plays (not muted, its lane not silent).
clip_heard :: proc(s: ^Song, i: int) -> bool {
	if i < 0 || i >= s.count do return false
	return !s.clips[i].mute && !lane_silent(s, int(s.clips[i].lane))
}

// Whether two clips play the same (one run of audio).
@(private)
clips_alike :: proc(a, b: Song_Clip) -> bool {
	return a.slot == b.slot && a.start == b.start && a.part == b.part && a.mute == b.mute && a.transpose == b.transpose
}

// The song's length in seconds, at its tempo.
song_seconds :: proc(p: ^Project) -> f64 {
	return song_seconds_between(p, 0, song_beats(p))
}

// Changes clip `i` to `c`, undoably.
set_song_clip :: proc(m: ^Model, i: int, c: Song_Clip, name: string) {
	s := m.project.song
	if i < 0 || i >= s.count do return
	s.clips[i] = clip_fit(c)
	set_song(m, name, s)
}

// Changes clip `i` to `c` as part of a drag (one undo step; seal when it
// ends).
set_song_clip_drag :: proc(m: ^Model, i: int, c: Song_Clip, name: string) {
	s := m.project.song
	if i < 0 || i >= s.count do return
	s.clips[i] = clip_fit(c)
	set_song_drag(m, name, s)
}

// A clip kept in bounds.
@(private)
clip_fit :: proc(c: Song_Clip) -> Song_Clip {
	c := c
	c.at = max(c.at, 0)
	c.length = max(c.length, 1.0 / 16)
	c.start = max(c.start, 0)
	c.part = max(c.part, 0)
	c.phase = max(c.phase, 0)
	c.lane = min(c.lane, SONG_LANES - 1)
	c.transpose = i8(clamp(int(c.transpose), -48, 48))
	return c
}

// Arrangements a project keeps (songs, exported apart).
ARRANGEMENTS :: 16

// One arrangement: a name, and its song.
Arrangement :: struct {
	name: [24]u8,
	song: Song,
}

// The song: clips of sequences on lanes, any number playing at once.
Song :: struct {
	clips:      [SONG_CLIPS]Song_Clip,
	count:      int,
	lanes:      [SONG_LANES]Song_Lane,
	lane_count: int, // lanes made (clips may be on later ones)
	// (Whether it goes round is the transport's loop.)
	tempo:       [MAX_TEMPO_POINTS]Tempo_Point, // its tempo lane, by beat (none: the project's tempo)
	tempo_count: int,
	meters:      [MAX_METERS]Meter_Point, // its time signature lane, by beat (none: the project's)
	meter_count: int,
	markers:      [MAX_MARKERS]Marker, // its locators, by beat
	marker_count: int,
	loop_on:    bool, // the loop goes round loop_start..loop_end (beats) instead of the whole song
	loop_start: f64,
	loop_end:   f64,
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

// Replaces the song with `new` as part of a drag: the drag's moves (one
// `name`) merge into one undo step; seal when it ends.
set_song_drag :: proc(m: ^Model, name: string, new: Song) {
	if m.project.song == new do return
	app.set_value(&m.history, name, {3000, 1}, m.project.song, new, proc(ctx: rawptr, k: app.Key, v: Song) {
		mm := (^Model)(ctx)
		mm.project.song = v
		if mm.project.song_mode do mm.engine.seq_dirty = true
	})
}

// Where lane `lane`'s last clip ends (0: it has none).
lane_end :: proc(s: ^Song, lane: int) -> f64 {
	end := 0.0
	for c in s.clips[:s.count] do if int(c.lane) == lane do end = max(end, clip_end(c))
	return end
}

// Puts sequence `slot` into the song: on lane `lane` at song beat `at`
// (-1: after the lane's last clip), `length` beats long (0: the sequence
// `repeats` times). Returns its index, or -1 when the song is full.
song_add :: proc(m: ^Model, slot: int, repeats := 1, lane := 0, at := -1.0, length := 0.0, name := "Add to Song") -> int {
	s := m.project.song
	if s.count >= SONG_CLIPS || slot < 0 || slot >= SLOTS do return -1
	ln := clamp(lane, 0, SONG_LANES - 1)
	c := Song_Clip{lane = u8(ln), slot = u8(slot)}
	c.at = at if at >= 0 else lane_end(&s, ln)
	c.length = length if length > 0 else seq_beats(&m.project, m.project.sequences[slot]) * f64(clamp(repeats, 1, 64))
	s.clips[s.count] = clip_fit(c)
	s.count += 1
	s.lane_count = max(s.lane_count, ln + 1)
	set_song(m, name, s)
	return s.count - 1
}

// Removes clip `i`.
song_remove :: proc(m: ^Model, i: int) {
	if i < 0 || i >= m.project.song.count do return
	song_remove_clips(m, {i})
}

// Removes the clips in `sel`: one undo step.
song_remove_clips :: proc(m: ^Model, sel: Clip_Set, name := "Remove from Song") {
	s := m.project.song
	n := 0
	for i in 0 ..< s.count do if i not_in sel {
		s.clips[n] = s.clips[i]
		n += 1
	}
	for i in n ..< s.count do s.clips[i] = {}
	s.count = n
	set_song(m, name, s)
}

// Adds `clips` to the song (as many as fit), `dt` beats later and `dl`
// lanes down: one undo step. Returns the clips they became.
song_insert_clips :: proc(m: ^Model, clips: []Song_Clip, dt := 0.0, dl := 0, name := "Paste Clips") -> (added: Clip_Set) {
	s := m.project.song
	for c in clips {
		if s.count >= SONG_CLIPS do break
		x := c
		x.at += dt
		x.lane = u8(clamp(int(c.lane) + dl, 0, SONG_LANES - 1))
		s.clips[s.count] = clip_fit(x)
		s.lane_count = max(s.lane_count, int(x.lane) + 1)
		added += {s.count}
		s.count += 1
	}
	if added != {} do set_song(m, name, s)
	return
}

// Moves the clips in `sel` (as `from` had them) `dt` beats and `dl` lanes
// (a drag: seal when it ends; `from` may have clips the song doesn't yet:
// copies being placed).
song_move_clips :: proc(m: ^Model, from: Song, sel: Clip_Set, dt: f64, dl: int, name := "Move Clips") {
	s := m.project.song
	// The earliest and the top lane stay in the song.
	lo, top := math.F64_MAX, SONG_LANES
	for i in 0 ..< from.count do if i in sel {
		lo = min(lo, from.clips[i].at)
		top = min(top, int(from.clips[i].lane))
	}
	t := max(dt, -lo)
	ld := max(dl, -top)
	s.count = max(s.count, from.count)
	for i in 0 ..< from.count do if i in sel {
		c := from.clips[i]
		c.at += t
		c.lane = u8(clamp(int(c.lane) + ld, 0, SONG_LANES - 1))
		s.clips[i] = clip_fit(c)
		s.lane_count = max(s.lane_count, int(c.lane) + 1)
	}
	set_song_drag(m, name, s)
}

// Duplicates the clips in `sel` right after themselves (the whole
// selection's span later, on their lanes). Returns the copies.
song_duplicate_clips :: proc(m: ^Model, sel: Clip_Set) -> Clip_Set {
	s := &m.project.song
	picked := make([dynamic]Song_Clip, context.temp_allocator)
	lo, hi := math.F64_MAX, 0.0
	for i in 0 ..< s.count do if i in sel {
		append(&picked, s.clips[i])
		lo, hi = min(lo, s.clips[i].at), max(hi, clip_end(s.clips[i]))
	}
	if len(picked) == 0 do return {}
	return song_insert_clips(m, picked[:], hi - lo, 0, "Duplicate Clips")
}

// Adds a lane at the bottom. Returns it, or -1 when there are as many as
// can be.
lane_add :: proc(m: ^Model) -> int {
	s := m.project.song
	n := song_lanes(&s)
	if n >= SONG_LANES do return -1
	s.lane_count = n + 1
	set_song(m, "Add Lane", s)
	return n
}

// Changes lane `i` (its name, mute and solo).
lane_set :: proc(m: ^Model, i: int, l: Song_Lane, name: string) {
	s := m.project.song
	if i < 0 || i >= SONG_LANES do return
	s.lanes[i] = l
	s.lane_count = max(s.lane_count, i + 1)
	set_song(m, name, s)
}

// Renames lane `i`.
lane_rename :: proc(m: ^Model, i: int, name: string) {
	if i < 0 || i >= SONG_LANES do return
	l := m.project.song.lanes[i]
	l.name = {}
	copy(l.name[:len(l.name) - 1], name)
	lane_set(m, i, l, "Rename Lane")
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
	for c in p.song.clips[:p.song.count] do total = max(total, clip_end(c))
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
	step:   int, // the song clip, or -1
	offset: f64, // beats into the sequence each period starts at (a clip's part)
	lane:   int, // the song lane (0: a pattern's)
	silent: bool, // a muted clip, or one on a silent lane
}

// What the sequencer plays, as one clip placed at timeline beat `at`: its
// segments (in order of their starts; a song's may overlap), and the part
// that loops (loop_end 0: nothing loops; it ends).
Plan :: struct {
	segs:       [2 * SONG_CLIPS + 2]Segment, // (a clip that begins partway into its part: two)
	alike:      [2 * SONG_CLIPS + 2]bool, // a song's segment plays as the one before it on its lane, right up to it (one audio run)
	count:      int,
	loop_start: f64,
	loop_end:   f64,
	at:         f64,
}

// Sequence `slot` looping from timeline beat `at`.
plan_pattern :: proc(p: ^Project, slot: int, at: f64) -> (pl: Plan) {
	l := seq_beats(p, p.sequences[slot])
	pl.segs[0] = {slot = slot, span = l, period = l, step = -1}
	pl.count, pl.loop_start, pl.loop_end, pl.at = 1, 0, l, at
	return
}

// What plays now (`cur`, a pattern) until timeline beat `b`, then sequence
// `slot` looping from there.
plan_switch :: proc(p: ^Project, cur: Plan, slot: int, b: f64) -> (pl: Plan) {
	first := cur.segs[0]
	span := max(b - cur.at, 0)
	l := seq_beats(p, p.sequences[slot])
	pl.segs[0] = {slot = first.slot, span = span, period = first.period, step = -1, offset = first.offset}
	pl.segs[1] = {slot = slot, start = span, span = l, period = l, step = -1}
	pl.alike[1] = first.slot == slot && first.offset == 0
	pl.count, pl.loop_start, pl.loop_end, pl.at = 2, span, span + l, cur.at
	return
}

// The song from timeline beat `at`: every clip, in order of where it
// starts (then its lane).
plan_song :: proc(p: ^Project, at: f64) -> (pl: Plan) {
	s := &p.song
	order := make([dynamic]int, 0, s.count, context.temp_allocator)
	for i in 0 ..< s.count do append(&order, i)
	clips := s.clips
	sort_clips :: proc(order: []int, clips: ^[SONG_CLIPS]Song_Clip) {
		for i in 1 ..< len(order) {
			k := order[i]
			j := i
			for j > 0 {
				o := order[j - 1]
				if clips[o].at < clips[k].at || (clips[o].at == clips[k].at && clips[o].lane <= clips[k].lane) do break
				order[j] = o
				j -= 1
			}
			order[j] = k
		}
	}
	sort_clips(order[:], &clips)
	end := 0.0
	n := 0
	for k in order {
		c := clips[k]
		l := clip_period(p, c)
		if l <= 0 do continue
		offset := clamp(c.start, 0, seq_beats(p, p.sequences[c.slot]))
		seg := Segment{slot = int(c.slot), start = c.at, span = c.length, period = l, step = k, offset = offset, lane = int(c.lane), silent = !clip_heard(s, k)}
		ph := math.mod(c.phase, l)
		if ph > 1e-9 {
			// Its first pass from partway in, then whole ones.
			first := min(l - ph, c.length)
			a := seg
			a.span, a.period, a.offset = first, l - ph, offset + ph
			pl.segs[n] = a
			n += 1
			if c.length - first > 1e-9 {
				seg.start, seg.span = c.at + first, c.length - first
				pl.segs[n] = seg
				n += 1
			}
		} else {
			// Alike the clip ending where it starts on its lane, if any.
			for b, j in pl.segs[:n] {
				if b.lane == int(c.lane) && abs(b.start + b.span - c.at) < 1e-9 && b.offset == offset && clips_alike(clips[b.step], c) && abs(b.span - math.round(b.span / max(b.period, 1e-9)) * b.period) < 1e-9 do pl.alike[n] = true
				_ = j
			}
			pl.segs[n] = seg
			n += 1
		}
		end = max(end, c.at + c.length)
	}
	pl.count, pl.at = n, at
	if p.transport.loop do pl.loop_start, pl.loop_end = 0, end
	// Its loop range, inside the song.
	if p.transport.loop && p.song.loop_on {
		a, b := clamp(p.song.loop_start, 0, end), clamp(p.song.loop_end, 0, end)
		if b - a >= 1.0 / 16 do pl.loop_start, pl.loop_end = a, b
	}
	return
}

// The segment of plan `pl` that leads at plan beat `x` (from its start):
// the heard one covering it on the topmost lane (else any covering it), or
// -1.
plan_top :: proc(pl: ^Plan, x: f64) -> int {
	best := -1
	for s, i in pl.segs[:pl.count] {
		if x < s.start || x >= s.start + s.span do continue
		if best < 0 {
			best = i
			continue
		}
		b := pl.segs[best]
		if (b.silent && !s.silent) || (b.silent == s.silent && s.lane < b.lane) do best = i
	}
	return best
}

// Where timeline beat `beat` falls in plan `pl`: the segment leading there
// (`plan_top`, or sequence `prefer`'s when it plays there), its slot, and
// the beat within the sequence; false before the plan starts, after it
// ends, or where nothing plays.
plan_locate :: proc(pl: Plan, beat: f64, prefer := -1) -> (seg: int, slot: int, rel: f64, ok: bool) {
	pl := pl
	if pl.count == 0 do return
	x := beat - pl.at
	if x < 0 do return
	if pl.loop_end > pl.loop_start && x >= pl.loop_end {
		x = pl.loop_start + math.mod(x - pl.loop_start, pl.loop_end - pl.loop_start)
	}
	i := plan_top(&pl, x)
	// Sequence `prefer`'s segment there, when it plays (the launcher: the
	// one being edited).
	if prefer >= 0 do for s, k in pl.segs[:pl.count] do if s.slot == prefer && x >= s.start && x < s.start + s.span {
		i = k
		break
	}
	if i < 0 do return
	s := pl.segs[i]
	return i, s.slot, s.offset + math.mod(x - s.start, s.period), true
}

// Where the plan ends on the timeline (for a song that doesn't loop), or
// 0 if it loops.
plan_end :: proc(pl: Plan) -> f64 {
	pl := pl
	if pl.loop_end > pl.loop_start || pl.count == 0 do return 0
	end := 0.0
	for s in pl.segs[:pl.count] do end = max(end, s.start + s.span)
	return pl.at + end
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
		if sg.silent do continue // there, but not heard
		if sg.step >= 0 do transpose = int(p.song.clips[sg.step].transpose)
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
		if sg.silent do continue
		s := p.sequences[sg.slot]
		l := seq_beats(p, s)
		lo, hi := sg.offset, min(sg.offset + sg.period, l)
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for pt in s.points {
				if pt.target.track != .None || int(pt.pad) != pad || pt.beat < lo - 1e-9 || pt.beat > hi + 1e-9 || off + pt.beat - lo > sg.span do continue
				at := tb.Beats(sg.start + off + pt.beat - lo)
				v := f64(pt.value)
				shape := clip.Segment_Shape.Curve if pt.curve != 0 else .Linear
				// A plug-in: its lanes move the parameters they were given (the
				// rest of its voice lanes, nothing).
				if p.pads[pad].kind == .Plugin {
					#partial switch pt.param {
					case .Plugin_1 ..= .Plugin_8:
						l := p.pads[pad].plugin_lanes[int(pt.param) - int(Lane_Param.Plugin_1)]
						if l.id == 0 do continue
						clip.automation_add_point(&vb, l.id, at, f64(l.lo) + v / 100 * f64(l.hi - l.lo), shape, pt.curve); any_voice = true
						continue
					case .Pitch, .Cutoff, .Resonance:
						continue
					}
				} else if pt.param >= .Plugin_1 {
					continue
				}
				// A synth: pitch is its transpose, cutoff and resonance filter 1's
				// (cutoff as a key, so a lane sweeps it in even steps of pitch).
				if p.pads[pad].kind == .Synth {
					#partial switch pt.param {
					case .Pitch:
						clip.automation_add_point(&vb, synth.global_param(.Transpose), at, math.round(v), .Step); any_voice = true
						continue
					case .Cutoff:
						key := 69 + 12 * math.log2(max(v, 1) / 440)
						clip.automation_add_point(&vb, synth.filter_param(1, .Cutoff), at, key, shape, pt.curve); any_voice = true
						continue
					case .Resonance:
						clip.automation_add_point(&vb, synth.filter_param(1, .Resonance), at, v / 100, shape, pt.curve); any_voice = true
						continue
					}
				}
				switch pt.param {
				case .Volume:  clip.automation_add_point(&fb, dsp.GAIN_PARAM_DB, at, v, shape, pt.curve); any_fader = true
				case .Pitch:   clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_TRANSPOSE, at, math.round(v), .Step); any_voice = true
				case .Eq_Low:  clip.automation_add_point(&eb, dsp.eq_band_param(0, .Gain_Db), at, v, shape, pt.curve); any_eq = true
				case .Eq_Mid:  clip.automation_add_point(&eb, dsp.eq_band_param(1, .Gain_Db), at, v, shape, pt.curve); any_eq = true
				case .Eq_High: clip.automation_add_point(&eb, dsp.eq_band_param(2, .Gain_Db), at, v, shape, pt.curve); any_eq = true
				case .Cutoff:    clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_FILTER_CUTOFF, at, v, shape, pt.curve); any_voice = true
				case .Resonance: clip.automation_add_point(&vb, sampler.SAMPLER_PARAM_FILTER_RESONANCE, at, v, shape, pt.curve); any_voice = true
				case .Plugin_1 ..= .Plugin_8: // (above)
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

// The arrangements as they are, into `a` (the one being edited with its
// song as it is now). Large (16 songs): kept off the stack, as a
// thread's stack is 1 MB on Windows.
@(private)
arrangements_of :: proc(p: ^Project, a: ^Arrangements) {
	// (One assignment each: a tuple of these large arrays costs LLVM minutes at -o:speed.)
	a.list = p.arrangements
	a.song = p.song
	a.count = p.arrangement_count
	a.current = p.arrangement
	a.list[a.current].song = p.song // the one being edited, kept
}

// A copy of the arrangements as they are, in the frame's temporary memory.
@(private)
arrangements_now :: proc(p: ^Project) -> ^Arrangements {
	a := new(Arrangements, context.temp_allocator)
	arrangements_of(p, a)
	return a
}

@(private)
put_arrangements :: proc(m: ^Model, name: string, new: ^Arrangements) {
	old := arrangements_now(&m.project)
	app.set_value_big(&m.history, name, {app.Id(ARRANGEMENT_KEY), 0}, old, new, proc(ctx: rawptr, key: app.Key, v: Arrangements) {
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
	a := arrangements_now(p)
	a.current = i
	a.song = a.list[i].song
	put_arrangements(m, "Switch Arrangement", a)
}

// A new empty arrangement after the current one (or, with `copy_of` ≥ 0,
// a copy of that one), selected. Returns it, or -1 when there are
// ARRANGEMENTS already.
add_arrangement :: proc(m: ^Model, copy_of := -1) -> int {
	p := &m.project
	a := arrangements_now(p)
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
	a := arrangements_now(p)
	a.list[i].name = {}
	copy(a.list[i].name[:len(a.list[i].name) - 1], strings.trim_space(name))
	put_arrangements(m, "Rename Arrangement", a)
}

// Deletes arrangement `i` (not the last one left).
delete_arrangement :: proc(m: ^Model, i: int) {
	p := &m.project
	if i < 0 || i >= p.arrangement_count || p.arrangement_count <= 1 do return
	a := arrangements_now(p)
	copy(a.list[i:a.count - 1], a.list[i + 1:a.count])
	a.count -= 1
	a.list[a.count] = {}
	if a.current >= i do a.current = max(a.current - 1, 0)
	a.song = a.list[a.current].song
	put_arrangements(m, "Delete Arrangement", a)
}

// Where the song is: the clip leading (the topmost lane's heard one; -1
// between clips), how far through it (0..1), and the beat of the song
// (from its start); beat -1 when the song isn't what plays.
song_progress :: proc(e: ^Engine) -> (step: int, frac: f64, beat: f64) {
	pos, playing := timeline_beat(e)
	if !playing || !e.project.song_mode || e.plan.count == 0 do return -1, 0, -1
	pl := e.plan
	x := pos - pl.at
	if x < 0 do return -1, 0, -1
	if pl.loop_end > pl.loop_start && x >= pl.loop_end do x = pl.loop_start + math.mod(x - pl.loop_start, pl.loop_end - pl.loop_start)
	i := plan_top(&pl, x)
	if i < 0 do return -1, 0, x // (between clips: no clip, but the song plays on)
	c := e.project.song.clips[pl.segs[i].step] if pl.segs[i].step >= 0 && pl.segs[i].step < e.project.song.count else Song_Clip{at = pl.segs[i].start, length = pl.segs[i].span}
	return pl.segs[i].step, (x - c.at) / max(c.length, 1e-9), x
}
