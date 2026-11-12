package pads_model

import "core:math"
import "core:strings"

import tb "fire:timebase"
import "fire:transport"

// The song's time: its tempo lane (points at any beat, a line or a step
// to the next), its time signature lane, its markers (locators), and
// the range its loop goes round. All in song beats (the song starts at
// 0); kept in `Song`, so each arrangement has its own and they undo with
// it.

// Tempo points a song can have.
MAX_TEMPO_POINTS :: 64

// Markers a song can have.
MAX_MARKERS :: 32

// A point of the tempo lane: from `beat`, `bpm`; with `ramp`, a line to
// the next point's tempo (else it holds until there).
Tempo_Point :: struct {
	beat: f64,
	bpm:  f64,
	ramp: bool,
}

// A named place in the song to jump to.
Marker :: struct {
	beat: f64,
	name: [24]u8,
}

// A marker's name.
marker_name :: proc(m: ^Marker) -> string {
	return strings.truncate_to_byte(string(m.name[:]), 0)
}

// The song's tempo points as played: its lane, or (with none) the
// project's tempo throughout.
song_tempo_points :: proc(p: ^Project, allocator := context.temp_allocator) -> []Tempo_Point {
	s := &p.song
	if s.tempo_count > 0 do return s.tempo[:s.tempo_count]
	out := make([]Tempo_Point, 1, allocator)
	out[0] = {0, p.bpm, false}
	return out
}

// The tempo at song beat `beat` (from `song_tempo_points`).
song_tempo_at :: proc(p: ^Project, beat: f64) -> f64 {
	return tempo_in(song_tempo_points(p), beat)
}

// The tempo at `beat` of points `pts` (sorted).
tempo_in :: proc(pts: []Tempo_Point, beat: f64) -> f64 {
	if len(pts) == 0 do return 120
	if beat <= pts[0].beat do return pts[0].bpm
	for i in 0 ..< len(pts) {
		pt := pts[i]
		if i + 1 == len(pts) || beat < pts[i + 1].beat {
			if !pt.ramp || i + 1 == len(pts) do return pt.bpm
			n := pts[i + 1]
			return pt.bpm + (n.bpm - pt.bpm) * (beat - pt.beat) / max(n.beat - pt.beat, 1e-9)
		}
	}
	return pts[len(pts) - 1].bpm
}

// Where the song's bars start (in beats, from 0 to its end, or to
// `until` when that is later): bars of the project's time signature, a new
// bar at each point of the time signature lane in its own. Temporary
// allocator.
song_bars :: proc(p: ^Project, until := 0.0) -> []f64 {
	out := make([dynamic]f64, context.temp_allocator)
	end := max(song_beats(p), until)
	s := &p.song
	at := 0.0
	sig := p.transport.time_sig
	k := 0
	for at < end - 1e-9 && len(out) < 100_000 {
		for k < s.meter_count && s.meters[k].beat <= at + 1e-9 {
			sig = s.meters[k].sig
			k += 1
		}
		append(&out, at)
		next := at + bar_len(sig)
		if k < s.meter_count && s.meters[k].beat < next - 1e-9 {
			next = s.meters[k].beat
			sig = s.meters[k].sig
			k += 1
		}
		at = next
	}
	append(&out, at)
	return out[:]
}

// The bar song beat `beat` is in (0-based), and where it starts.
song_bar_at :: proc(p: ^Project, beat: f64) -> (bar: int, start: f64) {
	bars := song_bars(p, beat + 1)
	for i := len(bars) - 1; i >= 0; i -= 1 do if bars[i] <= beat + 1e-9 do return i, bars[i]
	return 0, 0
}

// The time signature at song beat `beat`: the lane's there, or the
// project's.
song_meter_at :: proc(p: ^Project, beat: f64) -> Time_Sig {
	sig := p.transport.time_sig
	for mt in p.song.meters[:p.song.meter_count] do if mt.beat <= beat + 1e-9 do sig = mt.sig
	return sig
}

// --- editing -----------------------------------------------------------------------------

// Adds (or, at the same beat, replaces) a tempo point. One undo step.
// The first point the lane gets keeps the song's start at the project's
// tempo.
tempo_point_add :: proc(m: ^Model, pt: Tempo_Point) {
	s := m.project.song
	if s.tempo_count == 0 && pt.beat > 1e-6 do tempo_insert(&s, {0, m.project.bpm, false})
	tempo_insert(&s, pt)
	set_song(m, "Add Tempo Point", s)
}

@(private)
tempo_insert :: proc(s: ^Song, pt: Tempo_Point) {
	pt := pt
	pt.beat = max(pt.beat, 0)
	pt.bpm = clamp(pt.bpm, 40, 300)
	for &x in s.tempo[:s.tempo_count] do if abs(x.beat - pt.beat) < 1e-6 {
		x = pt
		return
	}
	if s.tempo_count >= MAX_TEMPO_POINTS do return
	i := 0
	for i < s.tempo_count && s.tempo[i].beat < pt.beat do i += 1
	copy(s.tempo[i + 1:s.tempo_count + 1], s.tempo[i:s.tempo_count])
	s.tempo[i] = pt
	s.tempo_count += 1
}

// Moves tempo point `i` (a drag: seal when it ends). It stays between its
// neighbours.
tempo_point_set :: proc(m: ^Model, i: int, pt: Tempo_Point) {
	s := m.project.song
	if i < 0 || i >= s.tempo_count do return
	lo := s.tempo[i - 1].beat + 1.0 / 64 if i > 0 else 0
	hi := s.tempo[i + 1].beat - 1.0 / 64 if i + 1 < s.tempo_count else math.F64_MAX
	s.tempo[i] = {clamp(pt.beat, lo, hi) if i > 0 else 0, clamp(pt.bpm, 40, 300), pt.ramp}
	set_song_drag(m, "Move Tempo Point", s)
}

// Removes tempo point `i` (the first stays while there are others).
tempo_point_remove :: proc(m: ^Model, i: int) {
	s := m.project.song
	if i < 0 || i >= s.tempo_count || (i == 0 && s.tempo_count > 1) do return
	copy(s.tempo[i:s.tempo_count - 1], s.tempo[i + 1:s.tempo_count])
	s.tempo_count -= 1
	set_song(m, "Remove Tempo Point", s)
}

// Sets the time signature from song beat `beat` on (moved to the start of
// the bar it is in; at the same beat, replaced). One undo step.
meter_set :: proc(m: ^Model, beat: f64, ts: Time_Sig) {
	if ts.num <= 0 || ts.den <= 0 do return
	s := m.project.song
	_, start := song_bar_at(&m.project, max(beat, 0))
	meter_insert(&s, {start, ts})
	set_song(m, "Time Signature", s)
}

@(private)
meter_insert :: proc(s: ^Song, mt: Meter_Point) {
	for &x in s.meters[:s.meter_count] do if abs(x.beat - mt.beat) < 1e-6 {
		x = mt
		return
	}
	if s.meter_count >= MAX_METERS do return
	i := 0
	for i < s.meter_count && s.meters[i].beat < mt.beat do i += 1
	copy(s.meters[i + 1:s.meter_count + 1], s.meters[i:s.meter_count])
	s.meters[i] = mt
	s.meter_count += 1
}

// Removes time signature point `i`.
meter_remove :: proc(m: ^Model, i: int) {
	s := m.project.song
	if i < 0 || i >= s.meter_count do return
	copy(s.meters[i:s.meter_count - 1], s.meters[i + 1:s.meter_count])
	s.meter_count -= 1
	s.meters[s.meter_count] = {}
	set_song(m, "Remove Time Signature", s)
}

// Adds a marker at `beat` named `name` (in order). Returns its index.
marker_add :: proc(m: ^Model, beat: f64, name: string) -> int {
	s := m.project.song
	if s.marker_count >= MAX_MARKERS do return -1
	i := 0
	for i < s.marker_count && s.markers[i].beat <= beat do i += 1
	copy(s.markers[i + 1:s.marker_count + 1], s.markers[i:s.marker_count])
	mk := Marker{beat = max(beat, 0)}
	copy(mk.name[:len(mk.name) - 1], name)
	s.markers[i] = mk
	s.marker_count += 1
	set_song(m, "Add Marker", s)
	return i
}

// Renames marker `i`.
marker_rename :: proc(m: ^Model, i: int, name: string) {
	s := m.project.song
	if i < 0 || i >= s.marker_count do return
	s.markers[i].name = {}
	copy(s.markers[i].name[:len(s.markers[i].name) - 1], name)
	set_song(m, "Rename Marker", s)
}

// Moves marker `i` to `beat` (a drag: seal when it ends); the markers
// stay in order.
marker_move :: proc(m: ^Model, i: int, beat: f64) {
	s := m.project.song
	if i < 0 || i >= s.marker_count do return
	mk := s.markers[i]
	mk.beat = max(beat, 0)
	copy(s.markers[i:s.marker_count - 1], s.markers[i + 1:s.marker_count])
	n := s.marker_count - 1
	j := 0
	for j < n && s.markers[j].beat <= mk.beat do j += 1
	copy(s.markers[j + 1:n + 1], s.markers[j:n])
	s.markers[j] = mk
	set_song_drag(m, "Move Marker", s)
}

// Removes marker `i`.
marker_remove :: proc(m: ^Model, i: int) {
	s := m.project.song
	if i < 0 || i >= s.marker_count do return
	copy(s.markers[i:s.marker_count - 1], s.markers[i + 1:s.marker_count])
	s.marker_count -= 1
	set_song(m, "Remove Marker", s)
}

// The marker after (or, `back`, before) song beat `beat`, or -1.
marker_next :: proc(p: ^Project, beat: f64, back := false) -> int {
	s := &p.song
	if back {
		for i := s.marker_count - 1; i >= 0; i -= 1 do if s.markers[i].beat < beat - 1e-6 do return i
		return -1
	}
	for i in 0 ..< s.marker_count do if s.markers[i].beat > beat + 1e-6 do return i
	return -1
}

// Sets the song's loop range (beats; `on` false: the whole song). A drag
// when `drag` (seal when it ends).
set_song_loop :: proc(m: ^Model, on: bool, start, end: f64, drag := false) {
	s := m.project.song
	a, b := min(start, end), max(start, end)
	s.loop_on, s.loop_start, s.loop_end = on && b - a >= 1.0 / 16, max(a, 0), max(b, 0)
	if drag do set_song_drag(m, "Loop Range", s)
	else do set_song(m, "Loop Range", s)
}

// --- the engine's tempo map ------------------------------------------------------------

// The tempo map song plan `pl` plays by, in timeline beats from 0: its
// tempo lane and its time signature lane, laid out `passes` times
// round its loop (it goes round in its clip while the timeline counts on).
// Temporary allocator.
song_tempo_map :: proc(p: ^Project, pl: Plan, passes: int) -> (m: tb.Tempo_Map) {
	pts := song_tempo_points(p)
	_ = tb.tempo_map_init(&m, pts[0].bpm if len(pts) > 0 else 120, meter_of(p.transport.time_sig), context.temp_allocator)
	end := song_beats(p)
	lo, hi := 0.0, end
	looping := pl.loop_end > pl.loop_start
	if looping do lo, hi = pl.loop_start, pl.loop_end
	// Each pass: its song beats [from, to) at timeline beat `at`.
	Pass :: struct { from, to, at: f64 }
	runs := make([dynamic]Pass, context.temp_allocator)
	append(&runs, Pass{0, hi if looping else end, pl.at})
	if looping do for k in 1 ..< max(passes, 1) do append(&runs, Pass{lo, hi, pl.at + hi + f64(k - 1) * (hi - lo)})
	// Tempo: at each pass's start its tempo there, then its points.
	Entry :: struct { at, bpm: f64, ramp: bool, song: f64 }
	es := make([dynamic]Entry, context.temp_allocator)
	ramping :: proc(pts: []Tempo_Point, beat: f64) -> bool {
		r := false
		for pt in pts do if pt.beat <= beat do r = pt.ramp
		return r
	}
	for r in runs {
		append(&es, Entry{r.at, tempo_in(pts, r.from), ramping(pts, r.from), r.from})
		for pt in pts do if pt.beat > r.from && pt.beat < r.to do append(&es, Entry{r.at + pt.beat - r.from, pt.bpm, pt.ramp, pt.beat})
	}
	for e, i in es {
		target := -1.0
		if e.ramp {
			// To the next entry's tempo; a pass ends where its loop does, at
			// the tempo the song has there.
			if i + 1 < len(es) {
				n := es[i + 1]
				target = n.bpm if n.song > e.song else tempo_in(pts, hi)
			}
		}
		_ = tb.tempo_map_set_tempo(&m, tb.Beats(e.at), e.bpm, target)
	}
	// Time signatures: the lane's points (each a bar's start), each pass
	// (its start in the signature there).
	bar := i64(0)
	last_at, last_len := 0.0, bar_len(p.transport.time_sig)
	cur := p.transport.time_sig
	for r in runs {
		change :: proc(m: ^tb.Tempo_Map, at: f64, want: Time_Sig, bar: ^i64, last_at, last_len: ^f64, cur: ^Time_Sig) {
			if want == cur^ do return
			bar^ += i64(math.floor((at - last_at^) / last_len^ + 1e-6))
			_ = tb.tempo_map_set_meter(m, bar^, meter_of(want))
			last_at^, last_len^, cur^ = at, bar_len(want), want
		}
		change(&m, r.at, song_meter_at(p, r.from), &bar, &last_at, &last_len, &cur)
		for mt in p.song.meters[:p.song.meter_count] do if mt.beat > r.from + 1e-9 && mt.beat < r.to - 1e-9 {
			change(&m, r.at + mt.beat - r.from, mt.sig, &bar, &last_at, &last_len, &cur)
		}
	}
	return
}

@(private)
meter_of :: proc(ts: Time_Sig) -> tb.Meter {
	if ts.num <= 0 || ts.den <= 0 do return {4, 4}
	return {i32(ts.num), i32(ts.den)}
}

@(private)
bar_len :: proc(ts: Time_Sig) -> f64 {
	if ts.num <= 0 || ts.den <= 0 do return BEATS_PER_BAR
	return f64(ts.num) * 4 / f64(ts.den)
}

// [control] Song mode, each frame: the timeline leads the clock with the
// song's tempo map (laid out a few passes ahead of where it plays), and
// the live tempo is the song's where it stands (what shows when stopped).
@(private)
song_map_sync :: proc(e: ^Engine) {
	p := e.project
	c := e.host.clock
	if !e.map_on {
		transport.set_leader(c, e.timeline)
		e.map_on, e.map_dirty = true, true
	}
	pos, on, _ := transport.timeline_status(c, e.timeline)
	pl := e.plan
	beat := f64(pos) - pl.at
	pass := 0
	if pl.loop_end > pl.loop_start && beat >= pl.loop_end do pass = 1 + int((beat - pl.loop_end) / (pl.loop_end - pl.loop_start))
	if e.map_dirty || pass + 2 >= e.map_passes {
		m := song_tempo_map(p, pl, pass + 4)
		transport.set_tempo_map(c, e.timeline, &m)
		e.map_passes, e.map_dirty = pass + 4, false
	}
	if !on {
		want := song_tempo_at(p, song_position(pl, f64(pos)))
		if e.bpm != want {
			transport.set_tempo(c, want)
			e.bpm = want
		}
	}
}

// Where timeline beat `beat` is in song plan `pl`, in song beats (round its
// loop).
song_position :: proc(pl: Plan, beat: f64) -> f64 {
	x := max(beat - pl.at, 0)
	if pl.loop_end > pl.loop_start && x >= pl.loop_end do x = pl.loop_start + math.mod(x - pl.loop_start, pl.loop_end - pl.loop_start)
	return x
}

// Seconds from song beat `a` to `b` at the song's tempo.
song_seconds_between :: proc(p: ^Project, a, b: f64) -> f64 {
	pts := song_tempo_points(p)
	if b <= a || len(pts) == 0 do return 0
	total := 0.0
	for i in 0 ..< len(pts) {
		lo := pts[i].beat if i > 0 else math.inf_f64(-1)
		hi := pts[i + 1].beat if i + 1 < len(pts) else math.inf_f64(1)
		x0, x1 := max(a, lo), min(b, hi)
		if x1 <= x0 do continue
		if !pts[i].ramp || i + 1 == len(pts) {
			total += (x1 - x0) * 60 / pts[i].bpm
		} else {
			t0, t1 := tempo_in(pts, x0), tempo_in(pts, x1)
			slope := (pts[i + 1].bpm - pts[i].bpm) / max(hi - lo, 1e-9)
			total += (x1 - x0) * 60 / t0 if abs(slope) < 1e-9 else 60 / slope * math.ln(t1 / t0)
		}
	}
	return total
}

// Song mode: plays from song beat `beat` (playing), or makes it where
// play starts (stopped).
song_jump :: proc(e: ^Engine, beat: f64) {
	_, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	e.cue = max(beat, 0)
	if playing {
		play(e, from_beat = e.cue)
		return
	}
	transport.locate(e.host.clock, e.timeline, tb.Beats(e.cue))
}
