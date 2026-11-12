package pads_model

import "core:math"

import "fire:transport"

// The launcher (pattern mode): the sequence pads' four columns are lanes,
// each playing one sequence at a time, all of them together. A launch
// replaces its column's sequence at the launch quantize (the others play
// on); a stop ends the column there.

// Columns the launcher has (the sequence pads' columns: a bank is 4 × 4).
LAUNCH_COLS :: 4

// The column sequence `slot` launches in (its pad's column in its bank).
launch_col :: proc "contextless" (slot: int) -> int {
	return slot % LAUNCH_COLS
}

// A launcher column: what it plays (-1: nothing) and since when (timeline
// beat), and what takes over at `at` (`next` -1: it stops; `queued` false:
// nothing).
Launch_Col :: struct {
	slot:   int,
	since:  f64,
	queued: bool,
	next:   int,
	at:     f64,
}

// The launcher's columns.
Launcher :: struct {
	cols: [LAUNCH_COLS]Launch_Col,
}

// Whether any column plays.
launcher_playing :: proc(l: ^Launcher) -> bool {
	for c in l.cols do if c.slot >= 0 do return true
	return false
}

// Where a change asked for at timeline beat `beat` happens: at once, on
// the next beat, the next bar, or (End) when column `col`'s sequence (or,
// with none, the leading one's) comes round.
@(private)
launch_at :: proc(e: ^Engine, col: int, beat: f64) -> f64 {
	p := e.project
	switch p.switch_at {
	case .Now:  return beat + 1e-6
	case .Beat: return math.floor(beat + 1e-9) + 1
	case .Bar:  return (math.floor(beat / bar_beats(p) + 1e-9) + 1) * bar_beats(p)
	case .End:
		c := e.launch.cols[col]
		if c.slot < 0 do for x in e.launch.cols do if x.slot >= 0 {
			c = x
			break
		}
		if c.slot < 0 do return (math.floor(beat / bar_beats(p) + 1e-9) + 1) * bar_beats(p)
		l := seq_beats(p, p.sequences[c.slot])
		return c.since + (math.floor((beat - c.since) / l + 1e-9) + 1) * l
	}
	return beat
}

// Picks sequence `slot`. Stopped, at once; playing, when the project's
// `switch_at` says (a bar, a beat, the end of what plays), exactly there.
// `solo`: the other columns stop then too (picking a sequence to edit, or
// from the toolbar); else it takes its own column only (the launcher).
queue_slot :: proc(e: ^Engine, slot: int, solo := true) {
	p := e.project
	if slot < 0 || slot >= SLOTS do return
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	beat := f64(pos)
	col := launch_col(slot)
	l := &e.launch
	if !playing || p.song_mode {
		p.slot = slot
		for &c, k in l.cols {
			c.queued = false
			if k == col do c.slot = slot
			else if solo do c.slot = -1
		}
		if !playing do e.plan.at = 0
		e.seq_dirty = true
		return
	}
	// Already so (nothing queued to change it): nothing to do.
	same := l.cols[col].slot == slot && !l.cols[col].queued
	if solo do for c, k in l.cols do if k != col && (c.slot >= 0 || c.queued) do same = false
	if same {
		p.slot = slot // (launched again: the editor shows it)
		return
	}
	b := launch_at(e, col, beat)
	for &c, k in l.cols {
		if k == col {
			c.queued, c.next, c.at = true, slot, b
		} else if solo && (c.slot >= 0 || (c.queued && c.next >= 0)) {
			c.queued, c.next, c.at = true, -1, b
		}
	}
	if p.switch_at == .Now do launch_apply(e, b)
	e.seq_dirty = true
}

// Stops launcher column `col` (at the launch quantize while playing).
stop_column :: proc(e: ^Engine, col: int) {
	if col < 0 || col >= LAUNCH_COLS do return
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	c := &e.launch.cols[col]
	if !playing || e.project.song_mode {
		c.slot, c.queued = -1, false
		e.seq_dirty = true
		return
	}
	if c.slot < 0 && !c.queued do return
	b := launch_at(e, col, f64(pos))
	c.queued, c.next, c.at = true, -1, b
	if e.project.switch_at == .Now do launch_apply(e, b)
	e.seq_dirty = true
}

// Stops every column (at the launch quantize while playing).
stop_all_columns :: proc(e: ^Engine) {
	for k in 0 ..< LAUNCH_COLS do stop_column(e, k)
}

// Launches row `row` (0: the bottom) of bank `bank`: each of its
// sequences that has anything, in its column, together.
launch_row :: proc(m: ^Model, bank, row: int) {
	e := &m.engine
	_, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	last := -1
	for col in 0 ..< LAUNCH_COLS {
		slot := bank * 16 + row * LAUNCH_COLS + col
		if slot >= SLOTS || !slot_used(m, slot) do continue
		queue_slot(e, slot, solo = !playing && last < 0) // (stopped: the row alone)
		last = slot
	}
	if last >= 0 && !playing do play(e)
}

// [control] The queued changes due by timeline beat `b` happen: each
// column takes its next sequence (or stops) from where it was queued.
@(private)
launch_apply :: proc(e: ^Engine, b: f64) {
	p := e.project
	for &c, k in e.launch.cols do if c.queued && c.at <= b + 1e-9 {
		c.slot, c.since, c.queued = c.next, c.at, false
		if e.rec_open do append(&e.rec_log, Launch_Event{k, c.slot, c.at, c.at})
		if c.slot >= 0 do p.slot = c.slot // (the editor shows the one launched last)
	}
	e.plan.at = b
	e.seq_dirty = true
}

// [control] Starting to play: every column from the top (and, with none
// playing, the current sequence in its own).
@(private)
launch_play :: proc(e: ^Engine) {
	l := &e.launch
	for &c in l.cols do c.queued = false
	if !launcher_playing(l) || l.cols[launch_col(e.project.slot)].slot < 0 {
		for &c in l.cols do c.slot = -1
		l.cols[launch_col(e.project.slot)].slot = e.project.slot
	}
	for &c in l.cols do c.since = 0
}

// The earliest queued launch: its sequence and how far off it is (in
// beats), if one is queued.
pending_switch :: proc(e: ^Engine) -> (slot: int, in_beats: f64, ok: bool) {
	pos, _, _ := transport.timeline_status(e.host.clock, e.timeline)
	best := -1
	for c, k in e.launch.cols do if c.queued && c.next >= 0 && (best < 0 || c.at < e.launch.cols[best].at) do best = k
	if best < 0 do return
	c := e.launch.cols[best]
	return c.next, c.at - f64(pos), true
}

// What launcher column `col` is doing: the sequence it plays (-1: none),
// how far through its pass (0..1), and what is queued in it and in how
// many beats (`queued` false: nothing; `next` -1: it stops).
column_state :: proc(e: ^Engine, col: int) -> (slot: int, frac: f64, next: int, in_beats: f64, queued: bool) {
	c := e.launch.cols[col]
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	slot = c.slot
	if slot >= 0 && playing && !e.project.song_mode {
		l := seq_beats(e.project, e.project.sequences[slot])
		if l > 0 do frac = math.mod(max(f64(pos) - c.since, 0), l) / l
	}
	if c.queued do return slot, frac, c.next, c.at - f64(pos), true
	return slot, frac, -1, 0, false
}

// The launcher's plan: from `at` (the latest change), each playing
// column's sequence going round from where it started; a queued change
// takes over exactly where it is queued. It loops over a length every
// column fits a whole number of times (up to 64 bars).
plan_launch :: proc(p: ^Project, l: ^Launcher, at: f64) -> (pl: Plan) {
	pl.at = at
	// The earliest queued change after `at`: before it, what plays now.
	e := math.F64_MAX
	for c in l.cols do if c.queued && c.at > at + 1e-9 do e = min(e, c.at)
	cols := l.cols
	from := at
	if e < math.F64_MAX {
		for c, k in cols do if c.slot >= 0 do col_segments(p, &pl, c.slot, k, c.since, at, e)
		for &c in cols do if c.queued && c.at <= e + 1e-9 {
			c.slot, c.since, c.queued = c.next, c.at, false
		}
		from = e
	}
	// From there on: the loop.
	length := launch_loop(p, cols)
	if length <= 0 {
		pl.loop_start, pl.loop_end = from - at, from - at // (nothing more plays)
		if pl.count == 0 do pl.loop_start, pl.loop_end = 0, 0
		return
	}
	for c, k in cols do if c.slot >= 0 do col_segments(p, &pl, c.slot, k, c.since, from, from + length)
	pl.loop_start, pl.loop_end = from - at, from - at + length
	return
}

// The length the columns' sequences all fit a whole number of times (in
// 1/16 beats, at most 64 bars; past that, the longest's passes as fit).
@(private)
launch_loop :: proc(p: ^Project, cols: [LAUNCH_COLS]Launch_Col) -> f64 {
	gcd :: proc(a, b: int) -> int {
		a, b := a, b
		for b != 0 do a, b = b, a % b
		return a
	}
	CAP :: 64 * 4 * 16
	l := 0
	longest := 0
	for c in cols do if c.slot >= 0 {
		n := max(int(math.round(seq_beats(p, p.sequences[c.slot]) * 16)), 1)
		longest = max(longest, n)
		l = n if l == 0 else l / gcd(l, n) * n
		if l > CAP {
			l = max(CAP / longest, 1) * longest
			break
		}
	}
	return f64(l) / 16
}

// Adds the segments of sequence `slot` playing in column `col` from
// timeline beat `since` (passes from there), over timeline beats
// [from, to), to plan `pl`.
@(private)
col_segments :: proc(p: ^Project, pl: ^Plan, slot, col: int, since, from, to: f64) {
	l := seq_beats(p, p.sequences[slot])
	if l <= 0 || to <= from + 1e-9 || pl.count + 2 > len(pl.segs) do return
	x := max(from, since)
	if x >= to - 1e-9 do return
	ph := math.mod(x - since, l)
	if ph < 1e-3 || l - ph < 1e-3 do ph = 0 // (a change right on a pass's start: that pass whole, its first note too)
	if ph > 0 {
		span := min(l - ph, to - x)
		pl.segs[pl.count] = {slot = slot, start = x - pl.at, span = span, period = l - ph, step = -1, offset = ph, lane = col}
		pl.count += 1
		x += span
	}
	if x < to - 1e-9 {
		pl.segs[pl.count] = {slot = slot, start = x - pl.at, span = to - x, period = l, step = -1, lane = col}
		pl.count += 1
	}
}

// The sequence recording goes into where several play (pattern mode: the
// one being edited; song mode: the topmost lane's, -1).
editing_slot :: proc(m: ^Model) -> int {
	return -1 if m.project.song_mode else m.project.slot
}

// Launches sequence `slot` in its column (the launcher: the other columns
// play on); stopped, it starts playing, alone.
launch_slot :: proc(m: ^Model, slot: int) {
	_, playing, _ := transport.timeline_status(m.engine.host.clock, m.engine.timeline)
	queue_slot(&m.engine, slot, solo = !playing)
	if !playing do play(&m.engine)
}

// --- recording launches into the song ----------------------------------------------------

// A change the launcher made while recording to the song: column `col`
// plays `slot` (-1: nothing) from timeline beat `at`, its passes counted
// from `since`; `col` -1: the take ends there.
@(private)
Launch_Event :: struct {
	col:   int,
	slot:  int,
	at:    f64,
	since: f64,
}

// Arms (or disarms) recording what is launched into the song. Disarmed
// while playing: the take so far goes into the song.
set_launch_record :: proc(m: ^Model, on: bool) {
	e := &m.engine
	if e.rec_launch == on do return
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	if on {
		e.rec_launch = true
		if playing && !e.project.song_mode do launch_log_start(e, f64(pos))
	} else {
		if playing do launch_log_end(e, f64(pos))
		e.rec_launch = false
		launch_record_poll(m)
	}
}

// Whether launches are being recorded into the song.
launch_recording :: proc(m: ^Model) -> bool {
	return m.engine.rec_launch
}

// [control] A take begins at timeline beat `at`: what each column plays then.
@(private)
launch_log_start :: proc(e: ^Engine, at: f64) {
	clear(&e.rec_log)
	for c, k in e.launch.cols do if c.slot >= 0 do append(&e.rec_log, Launch_Event{k, c.slot, at, c.since})
	e.rec_open = true
}

// [control] The take ends at timeline beat `at`.
@(private)
launch_log_end :: proc(e: ^Engine, at: f64) {
	if !e.rec_open do return
	append(&e.rec_log, Launch_Event{-1, -1, at, at})
	e.rec_open = false
	e.rec_done = true
}

// Each frame: a finished take goes into the song (one undo step): each
// column's stretches as clips on its lane (Lane k for column k), over the
// clips that began on those lanes in its time.
launch_record_poll :: proc(m: ^Model) {
	e := &m.engine
	if !e.rec_done do return
	e.rec_done = false
	defer clear(&e.rec_log)
	p := &m.project
	if len(e.rec_log) < 2 do return
	Open :: struct { slot: int, from, since: f64 }
	open: [LAUNCH_COLS]Open
	for &o in open do o.slot = -1
	parts := make([dynamic]Song_Clip, context.temp_allocator)
	from, to := e.rec_log[0].at, e.rec_log[len(e.rec_log) - 1].at
	used: [LAUNCH_COLS]bool
	close :: proc(p: ^Project, parts: ^[dynamic]Song_Clip, col: int, o: Open, at: f64) {
		if o.slot < 0 || at - o.from < 1.0 / 64 do return
		c := Song_Clip{lane = u8(col), slot = u8(o.slot), at = o.from, length = at - o.from}
		if l := clip_period(p, c); l > 0 do c.phase = math.mod(math.mod(o.from - o.since, l) + l, l)
		if c.phase < 1e-3 do c.phase = 0
		append(parts, c)
	}
	for ev in e.rec_log {
		if ev.col < 0 {
			for o, k in open do close(p, &parts, k, o, ev.at)
			break
		}
		close(p, &parts, ev.col, open[ev.col], ev.at)
		open[ev.col] = {ev.slot, ev.at, ev.since}
		used[ev.col] = true
	}
	if len(parts) == 0 do return
	s := p.song
	// The clips that began on the recorded lanes in the take's time go.
	n := 0
	for c in s.clips[:s.count] {
		if int(c.lane) < LAUNCH_COLS && used[c.lane] && c.at >= from - 1e-9 && c.at < to - 1e-9 do continue
		s.clips[n] = c
		n += 1
	}
	for i in n ..< s.count do s.clips[i] = {}
	s.count = n
	for c in parts {
		if s.count >= SONG_CLIPS do break
		s.clips[s.count] = clip_fit(c)
		s.count += 1
		s.lane_count = max(s.lane_count, int(c.lane) + 1)
	}
	set_song(m, "Record to Song", s)
}
