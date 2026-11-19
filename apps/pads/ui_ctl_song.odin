// The song on a controller's display (Push 2's Master): the transport at
// the left (tempo, where it is as bar.beat and as time, the loop or
// marker), the master's level at the right, the lanes between (scrolling
// with the position; each clip with its notes). The window's Song tab's
// state is the same (the cursor, the selected lane and clip are the core's
// `song_edit`, the snap the window's). The first knob is the position on
// every tab; the tabs on the upper row:
//
// - Song: the lane's clips one by one, the lane, the sequence and length a
//   clip inserted gets, the snap, the zoom; Insert, Song Mode, Cue, Loop,
//   + Lane, Fit.
// - Clip: the lane's clips one by one; the selected one's start and length
//   (rippling: the lane's later clips move with its end), transpose,
//   sequence and part; Mute, Duplicate, Delete (both rippling), Name,
//   Whole, Cue, To Cursor, Insert.
// - Lanes: the selected lane: Mute, Solo, Rename, + Lane.
// - Arrangement: which; New, Duplicate, Rename, Delete, Clear.
// - Markers: go to one, the loop's ends; Add, Rename, Delete, Loop, Start
//   Here, End Here, Cue.
// - Tempo: the tempo and the time signature at the cursor; a point's ramp;
//   Add Point, Remove Point, Remove Meter.
//
// A clip goes in from the controller's grid and its lane buttons
// (`song_add_at_cursor`: inserted, the lane's later clips moving on); here,
// Insert does the same on the selected lane.
package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// The Song view's own state: its tab, its zoom (bars across, or the whole
// song), the beat at its left edge, Shift held, when the cursor last moved.
Ctl_Song :: struct {
	tab:   int,
	bars:  int, // bars across (0: SONG_BARS)
	fit:   bool, // the whole song across (no scrolling)
	start: f64,
	shift: bool,
	caption: string, // the tab's words over the lanes (at the right), this drawing's
	cursor_was: f64, // the cursor as last drawn, and when it moved (s)
	moved_at:   f64,
	playing:    bool, // the song played as last drawn
}

SONG_TABS := []string{"Song", "Clip", "Lanes", "Arrangement", "Markers", "Tempo"}

// The lengths a clip added at the cursor gets: its sequence's, or bars.
SONG_ADD_BARS := []int{0, 1, 2, 4, 8, 16, 32}

// Bars across the lanes until zoomed.
SONG_BARS :: 8

// How far into the lanes the position followed stays (it scrolls them).
SONG_FOLLOW :: 0.25

// The song view: the transport at the left (one column), the master's
// level at the right (one), the lanes between (six).
@(private)
ctl_song :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	cs := &a.ctl.song
	inp := ctx.input
	if inp != nil {
		if inp.pressed[int(pa.View_Button.Shift)] do cs.shift = true
		if inp.released[int(pa.View_Button.Shift)] do cs.shift = false
	}
	if k := ctl_tabs(ctx, SONG_TABS, cs.tab); k >= 0 && k < len(SONG_TABS) do cs.tab = k
	plot := im.Vec2{full.x, full.y - CTL_PLOT_Y - CTL_KNOBS_H - CTL_BUTTONS_H - 4} // (the knobs: a row of value bars)
	e, _ := pa.song_edit_state(&a.api)
	cs.caption = ""
	// Every tab: the position on the first knob.
	ctl_song_cursor(ctx, 0, &e, plot)
	switch cs.tab {
	case 0: ctl_song_main(ctx, &e, plot, full)
	case 1: ctl_song_clip(ctx, &e, plot, full)
	case 2: ctl_song_lanes(ctx, &e, plot, full)
	case 3: ctl_song_arrangement(ctx, &e, plot, full)
	case 4: ctl_song_markers(ctx, &e, plot, full)
	case 5: ctl_song_tempo(ctx, &e, plot, full)
	}
	e, _ = pa.song_edit_state(&a.api)
	lanes := im.Vec2{full.x - 2 * CTL_COL, plot.y}
	ctl_song_lanes_draw(a, e, CTL_COL, lanes)
	ctl_song_transport(a, e, {2, plot.y}, CTL_COL - 6)
	ctl_song_master(a, full.x - CTL_COL + 4, plot.y)
	if cs.caption != "" {
		ui.text_push(.Label)
		ctl_caption(cs.caption, CTL_COL + lanes.x - im.CalcTextSize(fmt.ctprintf("%s", cs.caption)).x - 8)
		ui.text_pop()
	}
	ui.knob_input.drawn = 8
}

// --- the picture ----------------------------------------------------------------------------------

// The lanes shown (from the first shown: as many as the song has, the
// selected one among them; eight at most).
@(private)
song_rows :: proc(a: ^App, e: pa.Song_Edit) -> int {
	n := max(pm.song_lanes(&a.m.project.song), int(e.lane) + 1, 1)
	return clamp(n - int(e.first_lane), 1, 8)
}

// Where the song plays now (song beats; -1: it doesn't).
@(private)
song_playhead :: proc(a: ^App) -> f64 {
	_, _, beat := pm.song_progress(&a.m.engine)
	return beat
}

// The ruler (bars, the loop, markers), the lanes shown (the selected one
// lit), their clips in their sequences' colours with their notes (the
// selected outlined, muted dim), the cursor, the playhead; `x` in, `size`
// big. They scroll with the position (the playhead while the song plays,
// unless the cursor moved since in the last two seconds; else the cursor).
@(private)
ctl_song_lanes_draw :: proc(a: ^App, e: pa.Song_Edit, x: f32, size: im.Vec2) {
	m := &a.m
	p := &m.project
	s := &p.song
	cs := &a.ctl.song
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0, y0 := o.x + x, o.y + CTL_PLOT_Y
	w, h := size.x, size.y
	bar := pm.bar_beats(p)
	// The view.
	total := pm.song_beats(p)
	now := im.GetTime()
	if e.cursor != cs.cursor_was {
		cs.cursor_was, cs.moved_at = e.cursor, now
	}
	head := song_playhead(a)
	if head >= 0 && !cs.playing do cs.moved_at = -1e9 // (it starts: the playhead leads)
	cs.playing = head >= 0
	follow := e.cursor
	if head >= 0 && now - cs.moved_at > 2 do follow = head
	span := f64(cs.bars if cs.bars > 0 else SONG_BARS) * bar
	if cs.fit {
		span = max(math.ceil((total + bar) / bar) * bar, 4 * bar)
		cs.start = 0
	} else {
		cs.start = max(follow - span * SONG_FOLLOW, 0)
	}
	ppb := f32(f64(w) / span)
	xb :: proc(x0, ppb: f32, start, b: f64) -> f32 { return x0 + f32(b - start) * ppb }
	ruler: f32 = 14
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x0 + w, y0 + h}, ui.col(ui.PLOT_BG), 3)
	im.DrawList_PushClipRect(dl, {x0, y0}, {x0 + w, y0 + h}, true)
	defer im.DrawList_PopClipRect(dl)
	ui.text_push(.Label)
	defer ui.text_pop()
	// The loop on the ruler.
	if s.loop_on && s.loop_end > s.loop_start {
		im.DrawList_AddRectFilled(dl, {xb(x0, ppb, cs.start, s.loop_start), y0}, {xb(x0, ppb, cs.start, s.loop_end), y0 + ruler - 2}, ui.col(ui.with_alpha(t.accent, 0.35)), 2)
	}
	// Bars: a line each (every few when they're close), numbered.
	bars := pm.song_bars(p, cs.start + span + bar)
	every := max(int(math.ceil(f64(28) / (f64(ppb) * bar))), 1)
	lanes_y := y0 + ruler
	for b, k in bars {
		if b < cs.start - bar || k % every != 0 do continue
		bx := xb(x0, ppb, cs.start, b)
		im.DrawList_AddLine(dl, {bx, lanes_y}, {bx, y0 + h}, ui.col(ui.with_alpha(t.text, 0.10)))
		im.DrawList_AddText(dl, {bx + 2, y0}, ui.col(t.text_dim), fmt.ctprintf("%d", k + 1))
	}
	// Markers: a flag on the ruler.
	for &mk in s.markers[:s.marker_count] {
		mx := xb(x0, ppb, cs.start, mk.beat)
		im.DrawList_AddTriangleFilled(dl, {mx, y0 + ruler - 1}, {mx - 4, y0 + ruler - 7}, {mx + 4, y0 + ruler - 7}, ui.col(t.warn))
		im.DrawList_AddText(dl, {mx + 5, y0}, ui.col(t.warn), fmt.ctprintf("%s", pm.marker_name(&mk)))
	}
	// The lanes.
	rows := song_rows(a, e)
	lh := (h - ruler) / f32(rows)
	for r in 0 ..< rows {
		lane := int(e.first_lane) + r
		ly := lanes_y + f32(r) * lh
		if lane == int(e.lane) do im.DrawList_AddRectFilled(dl, {x0, ly}, {x0 + w, ly + lh}, ui.col(ui.with_alpha(t.text, 0.07)))
		l := s.lanes[lane]
		if l.mute || l.solo {
			im.DrawList_AddRectFilled(dl, {x0, ly + 1}, {x0 + 3, ly + lh - 1}, ui.col(t.warn if l.mute else t.accent))
		}
	}
	sel := int(e.clip)
	for c, i in s.clips[:s.count] {
		r := int(c.lane) - int(e.first_lane)
		if r < 0 || r >= rows do continue
		cx0 := xb(x0, ppb, cs.start, c.at)
		cx1 := xb(x0, ppb, cs.start, pm.clip_end(c))
		if cx1 < x0 || cx0 > x0 + w do continue
		ly := lanes_y + f32(r) * lh
		col := ui.rgb(pm.sequence_color(p, int(c.slot)))
		heard := pm.clip_heard(s, i)
		if !heard do col = ui.mix(ui.PLOT_BG, col, 0.3)
		lo, hi := im.Vec2{cx0 + 1, ly + 1}, im.Vec2{cx1 - 1, ly + lh - 1}
		im.DrawList_AddRectFilled(dl, lo, hi, ui.col(col), 2)
		named := lh >= 13 && hi.x - lo.x > 18
		song_clip_notes(a, c, lo, hi, (im.GetTextLineHeight() if named && lh >= 22 else 0), ui.mix(col, ui.PLOT_BG, 0.78))
		if i == sel do im.DrawList_AddRect(dl, {cx0, ly}, {cx1, ly + lh}, ui.col(t.text), 2, 2)
		if named {
			name := pm.sequence_name(p, int(c.slot))
			if label := clip_label(c); label != "" do name = label
			im.DrawList_PushClipRect(dl, {cx0 + 2, ly}, {cx1 - 2, ly + lh}, true)
			ty := ly + 1 if lh >= 22 else ly + (lh - im.GetTextLineHeight()) / 2
			im.DrawList_AddText(dl, {cx0 + 4, ty}, ui.col(ui.PLOT_BG), fmt.ctprintf("%s", name))
			im.DrawList_PopClipRect(dl)
		}
	}
	// The playhead (the song playing) and the cursor.
	if head >= 0 {
		hx := xb(x0, ppb, cs.start, head)
		im.DrawList_AddLine(dl, {hx, y0}, {hx, y0 + h}, ui.col(t.text), 1)
	}
	cx := xb(x0, ppb, cs.start, e.cursor)
	im.DrawList_AddLine(dl, {cx, y0}, {cx, y0 + h}, ui.col(t.accent), 2)
	im.DrawList_AddTriangleFilled(dl, {cx - 5, y0}, {cx + 5, y0}, {cx, y0 + 6}, ui.col(t.accent))
}

// Clip `c`'s notes in `lo`..`hi` (below `top` of it: its name), each
// pass round its part of the sequence, in colour `nc`.
@(private)
song_clip_notes :: proc(a: ^App, c: pm.Song_Clip, lo, hi: im.Vec2, top: f32, nc: ui.Color) {
	p := &a.m.project
	period := pm.clip_period(p, c)
	whole := pm.seq_beats(p, p.sequences[c.slot])
	w := hi.x - lo.x
	if period <= 0 || whole <= 0 || w < 4 || hi.y - lo.y - top < 4 do return
	minis := seq_minis(a, int(c.slot))
	if len(minis) == 0 do return
	dl := im.GetWindowDrawList()
	ppb := w / f32(max(c.length, 1e-9))
	y0, y1 := lo.y + top + 2, hi.y - 2
	ph := math.mod(c.phase, period)
	im.DrawList_PushClipRect(dl, lo, hi, true)
	for off := -ph; off < c.length - 1e-9; off += period {
		px := lo.x + f32(off) * ppb // where this pass's part starts
		pa_, pb := max(px, lo.x), min(px + f32(period) * ppb, hi.x)
		if pb <= pa_ do continue
		im.DrawList_PushClipRect(dl, {pa_, lo.y}, {pb, hi.y}, true)
		sx := px - f32(c.start) * ppb // the whole sequence's left
		ui.mini_notes(dl, minis, {sx, y0}, {sx + f32(whole) * ppb, y1}, nc)
		im.DrawList_PopClipRect(dl)
		if off > 0 do im.DrawList_AddLine(dl, {px, lo.y + 2}, {px, lo.y + 6}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.7)), 1)
	}
	im.DrawList_PopClipRect(dl)
}

// The left column: the tempo and time signature, where the song is (the
// playhead while it plays, else the cursor) as bar.beat.sixteenth and as
// time, the loop or the marker it's past.
@(private)
ctl_song_transport :: proc(a: ^App, e: pa.Song_Edit, at: im.Vec2, w: f32) {
	p := &a.m.project
	s := &p.song
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0, y0 := o.x + at.x, o.y + CTL_PLOT_Y
	h := at.y
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x0 + w, y0 + h}, ui.col(ui.PLOT_BG), 3)
	head := song_playhead(a)
	pos := head if head >= 0 else e.cursor
	sig := pm.song_meter_at(p, pos)
	x := x0 + 6
	y := y0 + 2
	ui.text_push(.Caption)
	im.DrawList_AddText(dl, {x, y}, ui.col(t.text_dim), fmt.ctprintf("%.2f BPM  %d/%d", pm.song_tempo_at(p, pos), sig.num, sig.den))
	y += im.GetTextLineHeight() + 1
	ui.text_pop()
	ui.text_push(.Body)
	bar, start := pm.song_bar_at(p, pos)
	in_bar := pos - start
	beat := int(math.floor(in_bar + 1e-9))
	six := int(math.floor((in_bar - f64(beat)) * 4 + 1e-6))
	im.DrawList_AddText(dl, {x, y}, ui.col(t.ok if head >= 0 else t.text), fmt.ctprintf("%d.%d.%d", bar + 1, beat + 1, six + 1))
	y += im.GetTextLineHeight()
	ui.text_pop()
	ui.text_push(.Caption)
	secs := pm.song_seconds_between(p, 0, pos)
	im.DrawList_AddText(dl, {x, y}, ui.col(t.text), fmt.ctprintf("%d:%02d.%d", int(secs) / 60, int(secs) % 60, int(secs * 10) % 10))
	y += im.GetTextLineHeight() + 1
	past: string
	switch {
	case s.loop_on && s.loop_end > s.loop_start:
		past = fmt.tprintf("Loop %s–%s", song_pos_name(p, s.loop_start), song_pos_name(p, s.loop_end))
	case:
		for &mk in s.markers[:s.marker_count] do if mk.beat <= pos + 1e-9 do past = pm.marker_name(&mk)
	}
	if past != "" {
		im.DrawList_PushClipRect(dl, {x0, y0}, {x0 + w, y0 + h}, true)
		im.DrawList_AddText(dl, {x, y}, ui.col(t.warn), fmt.ctprintf("%s", past))
		im.DrawList_PopClipRect(dl)
	}
	ui.text_pop()
}

// The right column: the master's level (left and right, peak held) and
// its peak in dB.
@(private)
ctl_song_master :: proc(a: ^App, x: f32, h: f32) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0, y0 := o.x + x, o.y + CTL_PLOT_Y
	w := f32(CTL_COL) - 6
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x0 + w, y0 + h}, ui.col(ui.PLOT_BG), 3)
	v := &a.mixer.buses[pm.BUSES]
	top, bottom := y0 + 4, y0 + h - 4
	meter_bars(a, dl, v, x0 + 8, top, bottom, 10)
	// Its scale.
	ui.text_push(.Caption)
	defer ui.text_pop()
	for db in ([]f32{0, -12, -24, -48}) {
		y := bottom - (bottom - top) * fader_frac(db)
		im.DrawList_AddLine(dl, {x0 + 31, y}, {x0 + 35, y}, ui.col(t.text_dim))
		im.DrawList_AddText(dl, {x0 + 37, y - im.GetTextLineHeight() / 2}, ui.col(t.text_dim), fmt.ctprintf("%.0f", db))
	}
	im.DrawList_AddText(dl, {x0 + w - im.CalcTextSize("Master").x - 4, y0 + 2}, ui.col(t.text), "Master")
	peak := max(v[0].hold, v[1].hold)
	text := fmt.ctprintf("%.1f", 20 * math.log10(peak)) if peak > 1e-5 else "-inf"
	im.DrawList_AddText(dl, {x0 + w - im.CalcTextSize(text).x - 4, y0 + h - im.GetTextLineHeight() - 2}, ui.col(t.danger if peak >= 1 else t.text), text)
}

// --- the cursor and positions ---------------------------------------------------------------------------

// Song beat `b` as bar.beat (and sixteenth, off the beat), from 1.
@(private)
song_pos_name :: proc(p: ^pm.Project, b: f64) -> string {
	bar, start := pm.song_bar_at(p, b)
	in_bar := b - start
	beat := int(math.floor(in_bar + 1e-9))
	six := int(math.floor((in_bar - f64(beat)) * 4 + 1e-6))
	if six == 0 do return fmt.tprintf("%d.%d", bar + 1, beat + 1)
	return fmt.tprintf("%d.%d.%d", bar + 1, beat + 1, six + 1)
}

// `beat` moved `n` steps: bars (the snap's Bar), beats (Beat, or `fine`),
// sixteenths (Off). Not before the start.
@(private)
song_step :: proc(a: ^App, beat: f64, n: int, fine: bool) -> f64 {
	p := &a.m.project
	snap := a.song_ui.snap
	if fine && snap == .Bar do snap = .Beat
	switch snap {
	case .Off:  return max(math.round(beat * 4) / 4 + f64(n) * 0.25, 0)
	case .Beat: return max(math.round(beat) + f64(n), 0)
	case .Bar:
	}
	bars := pm.song_bars(p, beat + f64(abs(n) + 2) * 16 + 64)
	k := 0
	for b, i in bars do if b <= beat + 1e-9 do k = i
	to := k + n
	if n < 0 && beat > bars[k] + 1e-9 do to += 1 // (mid-bar, back: to this bar's start first)
	return bars[clamp(to, 0, len(bars) - 1)]
}

// Knob `n`: the cursor, its place as bar.beat (the clip it lands in on the
// selected lane selected; none: none).
@(private)
ctl_song_cursor :: proc(ctx: ^View_Ctx, n: int, e: ^pa.Song_Edit, plot: im.Vec2) {
	a := ctx.a
	if k, _ := ctl_value_box(ctx, n, "Position", song_pos_name(&a.m.project, e.cursor), CTL_STEP, plot); k != 0 {
		to := song_step(a, e.cursor, k, a.ctl.song.shift)
		pa.song_set_cursor(&a.api, to)
		at, _ := pa.song_clip_at(&a.api, e.lane, to)
		pa.song_select_clip(&a.api, at)
		e^, _ = pa.song_edit_state(&a.api)
	}
}

// Knob `n`: the selected lane's clips one after another (each selected,
// the cursor at its start: a lane button inserts before it), then its end
// (the cursor there: one goes after them all).
@(private)
ctl_song_step :: proc(ctx: ^View_Ctx, n: int, e: ^pa.Song_Edit, plot: im.Vec2) {
	a := ctx.a
	p := &a.m.project
	s := &p.song
	order := pm.lane_clips(s, int(e.lane))
	names := make([]string, len(order) + 1, context.temp_allocator)
	cur := len(order)
	for x, k in order {
		names[k] = fmt.tprintf("%d %s", k + 1, pm.sequence_name(p, int(s.clips[x].slot)))
		if x == int(e.clip) do cur = k
	}
	names[len(order)] = "End"
	if int(e.clip) < 0 || int(s.clips[max(int(e.clip), 0)].lane) != int(e.lane) {
		// (none selected here: the first at or after the cursor)
		for x, k in order do if s.clips[x].at >= e.cursor - 1e-9 {
			cur = k
			break
		}
	}
	if k, _ := ctl_choice(ctx, n, 8, "Clip", names, cur, plot); k >= 0 {
		if k < len(order) {
			pa.song_select_clip(&a.api, i64(order[k]))
			pa.song_set_cursor(&a.api, s.clips[order[k]].at)
		} else {
			pa.song_select_clip(&a.api, -1)
			pa.song_set_cursor(&a.api, pm.lane_end(s, int(e.lane)))
		}
		e^, _ = pa.song_edit_state(&a.api)
	}
}

// The song's lanes as choices ("Lane 3", or its name): as many as it has,
// one more (a new one).
@(private)
song_lane_names :: proc(a: ^App) -> []string {
	s := &a.m.project.song
	n := min(pm.song_lanes(s) + 1, pm.SONG_LANES)
	names := make([]string, n, context.temp_allocator)
	for &x, k in names do x = pm.lane_name(s, k)
	return names
}

// The sequences in use (and the current one): slots and names.
@(private)
song_sequences :: proc(a: ^App) -> (slots: []int, names: []string) {
	m := &a.m
	ss := make([dynamic]int, context.temp_allocator)
	ns := make([dynamic]string, context.temp_allocator)
	for k in 0 ..< pm.SLOTS do if pm.slot_used(m, k) || k == m.project.slot {
		append(&ss, k)
		append(&ns, pm.sequence_name(&m.project, k))
	}
	return ss[:], ns[:]
}

// The song's clips in order (by where they start, then lane).
@(private)
song_clip_order :: proc(a: ^App) -> []int {
	s := &a.m.project.song
	order := make([]int, s.count, context.temp_allocator)
	for &x, i in order do x = i
	// (insertion sort: the song's clips at hand)
	cl := s.clips[:s.count]
	for i in 1 ..< len(order) {
		j := i
		for j > 0 {
			x, y := cl[order[j - 1]], cl[order[j]]
			if x.at < y.at - 1e-9 || (abs(x.at - y.at) <= 1e-9 && x.lane <= y.lane) do break
			order[j - 1], order[j] = order[j], order[j - 1]
			j -= 1
		}
	}
	return order
}

// --- the tabs -----------------------------------------------------------------------------------

// Song: where a clip goes and what it is; the song as a whole.
@(private)
ctl_song_main :: proc(ctx: ^View_Ctx, e: ^pa.Song_Edit, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	p := &m.project
	cs := &a.ctl.song
	ctl_song_step(ctx, 1, e, plot)
	if k, _ := ctl_choice(ctx, 2, 8, "Lane", song_lane_names(a), int(e.lane), plot); k >= 0 do pa.song_select_lane(&a.api, i64(k))
	slots, names := song_sequences(a)
	cur := 0
	for x, i in slots do if x == p.slot do cur = i
	if k, _ := ctl_choice(ctx, 3, 8, "Sequence", names, cur, plot); k >= 0 do pa.sequence_select(&a.api, i64(slots[k]))
	bar := pm.bar_beats(p)
	lens := make([]string, len(SONG_ADD_BARS), context.temp_allocator)
	cur = 0
	for b, i in SONG_ADD_BARS {
		lens[i] = fmt.tprintf("%d bar%s", b, "" if b == 1 else "s") if b > 0 else fmt.tprintf("Its own (%d)", p.sequences[p.slot].bars)
		if abs(f64(b) * bar - e.length) < 1e-9 do cur = i
	}
	if k, _ := ctl_choice(ctx, 4, 8, "Length", lens, cur, plot); k >= 0 do pa.song_set_add_length(&a.api, f64(SONG_ADD_BARS[k]) * bar)
	snaps := []string{"Bar", "Beat", "Off"}
	if k, _ := ctl_choice(ctx, 5, 8, "Snap", snaps, int(a.song_ui.snap), plot); k >= 0 do a.song_ui.snap = Song_Snap(k)
	if k, _ := ctl_value_box(ctx, 7, "Zoom", "Whole song" if cs.fit else fmt.tprintf("%d bars", cs.bars if cs.bars > 0 else SONG_BARS), CTL_STEP, plot); k != 0 {
		now := cs.bars if cs.bars > 0 else SONG_BARS
		if cs.fit do now = max(int(math.ceil(pm.song_beats(p) / bar)) + 1, 4)
		cs.bars = clamp(now + k * max(now / 8, 1), 2, 512)
		cs.fit = false
	}
	st, _ := pa.song_state(&a.api)
	tr, _ := pa.transport_state(&a.api)
	if pr, _ := ctl_button(ctx, 0, "Insert", false, full); pr do song_add_here(a, e.lane)
	if pr, _ := ctl_button(ctx, 1, "Song Mode", tr.song_mode, full); pr do pa.transport_set_song_mode(&a.api, !tr.song_mode)
	if pr, _ := ctl_button(ctx, 2, "Cue", false, full); pr do pa.song_jump(&a.api, e.cursor)
	if pr, _ := ctl_button(ctx, 3, "Loop", st.loop_on, full); pr do song_loop_toggle(a, e.cursor)
	if pr, _ := ctl_button(ctx, 4, "+ Lane", false, full); pr {
		if l, r := pa.song_add_lane(&a.api); r == .Ok do pa.song_select_lane(&a.api, l)
	}
	if pr, _ := ctl_button(ctx, 5, "Fit", cs.fit, full); pr do cs.fit = !cs.fit
	a.ctl.song.caption = fmt.tprintf("%s · %s · %d bars", pm.arrangement_name(p, p.arrangement), clock_text(st.seconds), max(len(pm.song_bars(p)) - 1, 0) if st.beats > 0 else 0)
}

// The current sequence at the cursor on lane `lane` (the cursor moves to
// its end), or why not.
@(private)
song_add_here :: proc(a: ^App, lane: i64) {
	if _, r := pa.song_add_at_cursor(&a.api, lane); r == .Busy do ui.toast(&a.ws.toasts, .Warning, "The song is full")
}

// The loop on or off (on without a range: the cursor's bar and three more).
@(private)
song_loop_toggle :: proc(a: ^App, cursor: f64) {
	st, _ := pa.song_state(&a.api)
	lo, hi := st.loop_start, st.loop_end
	if !st.loop_on && !(hi > lo) {
		_, lo = pm.song_bar_at(&a.m.project, cursor)
		hi = song_step(a, lo, 4, false) if a.song_ui.snap == .Bar else lo + 4 * pm.bar_beats(&a.m.project)
	}
	pa.song_set_loop(&a.api, !st.loop_on, lo, hi)
}

// Clip: the selected clip's settings (its place and length ripple: the
// lane's later clips move with its end).
@(private)
ctl_song_clip :: proc(ctx: ^View_Ctx, e: ^pa.Song_Edit, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	p := &m.project
	s := &p.song
	ctl_song_step(ctx, 1, e, plot)
	if pr, _ := ctl_button(ctx, 7, "Insert", false, full); pr {
		song_add_here(a, e.lane)
		e^, _ = pa.song_edit_state(&a.api)
	}
	i := int(e.clip)
	if i < 0 || i >= s.count {
		a.ctl.song.caption = "No clips yet: a pad picks a sequence, a lane button puts it at the cursor" if s.count == 0 else "No clip selected: turn Clip, or Select and a lane button"
		return
	}
	c := s.clips[i]
	fine := a.ctl.song.shift
	// Its place and length (the snap's steps), transpose; a turn a step,
	// one undo step a touch.
	drag :: proc(a: ^App, i: int, c: pm.Song_Clip, name: string) {
		pm.set_song_clip_drag(&a.m, i, c, name) // api-lint: a knob's turns, one undo step (as the Song tab's drags)
	}
	ripple :: proc(a: ^App, i: int, at, length: f64, name: string) {
		pm.song_ripple_edit(&a.m, i, at, length, name) // api-lint: a knob's turns, one undo step (the lane's later clips moving with it)
	}
	if k, en := ctl_value_box(ctx, 2, "Start", song_pos_name(p, c.at), CTL_STEP, plot); k != 0 || en {
		if k != 0 {
			to := song_step(a, c.at, k, fine)
			ripple(a, i, to, c.length, "Move Clip")
			pa.song_set_cursor(&a.api, s.clips[i].at)
		}
		if en do app.seal(&m.history)
	}
	bar := pm.bar_beats(p)
	if k, en := ctl_value_box(ctx, 3, "Length", fmt.tprintf("%.4g bar%s", c.length / bar, "" if abs(c.length - bar) < 1e-9 else "s"), CTL_STEP, plot); k != 0 || en {
		if k != 0 {
			end := song_step(a, pm.clip_end(c), k, fine)
			ripple(a, i, c.at, max(end - c.at, 0.25), "Clip Length")
		}
		if en do app.seal(&m.history)
	}
	if k, en := ctl_value_box(ctx, 4, "Transpose", fmt.tprintf("%+d st", c.transpose), CTL_STEP, plot); k != 0 || en {
		if k != 0 {
			x := c
			x.transpose = i8(clamp(int(c.transpose) + k, -24, 24))
			drag(a, i, x, "Transpose Clip")
		}
		if en do app.seal(&m.history)
	}
	slots, snames := song_sequences(a)
	scur := 0
	for x, k in slots do if x == int(c.slot) do scur = k
	if k, _ := ctl_choice(ctx, 5, 8, "Sequence", snames, scur, plot); k >= 0 {
		x := song_clip_api(c)
		x.slot, x.start, x.part, x.phase = i64(slots[k]), 0, 0, 0
		pa.song_set_clip(&a.api, i64(i), x)
	}
	// The part of its sequence it goes round (beats).
	whole := pm.seq_beats(p, p.sequences[c.slot])
	if k, en := ctl_value_box(ctx, 6, "Part From", fmt.tprintf("%.4g beats", c.start), CTL_STEP, plot); k != 0 || en {
		if k != 0 {
			x := c
			x.start = clamp(c.start + f64(k) * (0.25 if fine else 1), 0, max(whole - 0.25, 0))
			if x.part > 0 do x.part = min(x.part, whole - x.start)
			x.phase = 0
			drag(a, i, x, "Clip Part")
		}
		if en do app.seal(&m.history)
	}
	period := pm.clip_period(p, c)
	if k, en := ctl_value_box(ctx, 7, "Part Length", "Whole" if c.part == 0 && c.start == 0 else fmt.tprintf("%.4g beats", period), CTL_STEP, plot); k != 0 || en {
		if k != 0 {
			x := c
			to := clamp(period + f64(k) * (0.25 if fine else 1), 0.25, max(whole - c.start, 0.25))
			x.part = 0 if to >= whole - c.start - 1e-9 else to
			x.phase = 0
			drag(a, i, x, "Clip Part")
		}
		if en do app.seal(&m.history)
	}
	if pr, _ := ctl_button(ctx, 0, "Mute", c.mute, full); pr {
		x := song_clip_api(c)
		x.mute = !c.mute
		pa.song_set_clip(&a.api, i64(i), x)
	}
	if pr, _ := ctl_button(ctx, 1, "Duplicate", false, full); pr do pa.song_ripple_duplicate(&a.api, i64(i))
	if pr, _ := ctl_button(ctx, 2, "Delete", false, full); pr do pa.song_ripple_remove(&a.api, {i64(i)})
	if pr, _ := ctl_button(ctx, 3, "Name", false, full); pr do song_name_clip(a, i)
	if pr, _ := ctl_button(ctx, 4, "Whole", c.start == 0 && c.part == 0 && c.phase == 0, full); pr {
		x := song_clip_api(c)
		x.start, x.part, x.phase = 0, 0, 0
		pa.song_set_clip(&a.api, i64(i), x)
	}
	if pr, _ := ctl_button(ctx, 5, "Cue", false, full); pr {
		pa.song_set_cursor(&a.api, c.at)
		pa.song_jump(&a.api, c.at)
	}
	if pr, _ := ctl_button(ctx, 6, "To Cursor", false, full); pr {
		x := song_clip_api(c)
		x.at = e.cursor
		pa.song_set_clip(&a.api, i64(i), x) // (the clips it then lies over make way)
	}
	label := clip_label(c)
	a.ctl.song.caption = fmt.tprintf("%s%s · %s to %s · %s", pm.sequence_name(p, int(c.slot)), fmt.tprintf(" (%s)", label) if label != "" else "", song_pos_name(p, c.at), song_pos_name(p, pm.clip_end(c)), pm.lane_name(s, int(c.lane)))
}

// Clip `c`'s section name ("": none). Temporary.
@(private)
clip_label :: proc(c: pm.Song_Clip) -> string {
	l := c.label
	return strings.clone(strings.truncate_to_byte(string(l[:]), 0), context.temp_allocator)
}

// Names clip `i`'s section in the window's dialog (a controller's name
// editor types into it). (The Song tab is showing: Master showed it; a
// `ui_show` here would close the dialog as it opens, moving the focus.)
@(private)
song_name_clip :: proc(a: ^App, i: int) {
	ss := &a.song_ui
	ss.section_for = i
	ss.section_buf = {}
	copy(ss.section_buf[:len(ss.section_buf) - 1], clip_label(a.m.project.song.clips[i]))
	ss.section_open = true
}

// Lanes: the selected lane: mute, solo, its name; a new one.
@(private)
ctl_song_lanes :: proc(ctx: ^View_Ctx, e: ^pa.Song_Edit, plot, full: im.Vec2) {
	a := ctx.a
	s := &a.m.project.song
	if k, _ := ctl_choice(ctx, 1, 8, "Lane", song_lane_names(a), int(e.lane), plot); k >= 0 do pa.song_select_lane(&a.api, i64(k))
	l, _ := pa.song_lane(&a.api, e.lane)
	if pr, _ := ctl_button(ctx, 0, "Mute", l.mute, full); pr {
		l.mute = !l.mute
		pa.song_set_lane(&a.api, e.lane, l)
	}
	if pr, _ := ctl_button(ctx, 1, "Solo", l.solo, full); pr {
		l.solo = !l.solo
		pa.song_set_lane(&a.api, e.lane, l)
	}
	if pr, _ := ctl_button(ctx, 2, "Rename", false, full); pr {
		a.song_ui.lane_rename = int(e.lane)
		a.song_ui.lane_open = true
	}
	if pr, _ := ctl_button(ctx, 3, "+ Lane", false, full); pr {
		if n, r := pa.song_add_lane(&a.api); r == .Ok do pa.song_select_lane(&a.api, n)
	}
	n := 0
	for c in s.clips[:s.count] do if i64(c.lane) == e.lane do n += 1
	a.ctl.song.caption = fmt.tprintf("%s · %d clip%s%s%s", pm.lane_name(s, int(e.lane)), n, "" if n == 1 else "s", " · muted" if l.mute else "", " · solo" if l.solo else "")
}

// Arrangement: which is the song; a new one, a copy, its name, away; the
// song cleared.
@(private)
ctl_song_arrangement :: proc(ctx: ^View_Ctx, e: ^pa.Song_Edit, plot, full: im.Vec2) {
	a := ctx.a
	p := &a.m.project
	names := make([]string, p.arrangement_count, context.temp_allocator)
	for &x, k in names do x = pm.arrangement_name(p, k)
	if k, _ := ctl_choice(ctx, 1, 8, "Arrangement", names, p.arrangement, plot); k >= 0 do pa.song_select_arrangement(&a.api, i64(k))
	if pr, _ := ctl_button(ctx, 0, "New", false, full); pr do pa.song_add_arrangement(&a.api)
	if pr, _ := ctl_button(ctx, 1, "Duplicate", false, full); pr do pa.song_add_arrangement(&a.api, i64(p.arrangement))
	if pr, _ := ctl_button(ctx, 2, "Rename", false, full); pr {
		ss := &a.song_ui
		ss.rename_buf = {}
		copy(ss.rename_buf[:len(ss.rename_buf) - 1], pm.arrangement_name(p, p.arrangement))
		ss.rename_open = true
	}
	if p.arrangement_count > 1 {
		if pr, _ := ctl_button(ctx, 3, "Delete", false, full); pr do pa.song_delete_arrangement(&a.api, i64(p.arrangement))
	}
	if pr, _ := ctl_button(ctx, 4, "Clear Song", false, full); pr {
		pa.song_clear(&a.api)
		pa.song_select_clip(&a.api, -1)
	}
	a.ctl.song.caption = fmt.tprintf("Arrangement %d of %d: %s", p.arrangement + 1, p.arrangement_count, pm.arrangement_name(p, p.arrangement))
}

// The marker at the cursor (-1: none).
@(private)
marker_at :: proc(s: ^pm.Song, beat: f64) -> int {
	for mk, k in s.markers[:s.marker_count] do if abs(mk.beat - beat) < 1e-6 do return k
	return -1
}

// Markers: go to one; the loop's ends; a marker at the cursor added,
// named, taken away; the loop on, its ends at the cursor.
@(private)
ctl_song_markers :: proc(ctx: ^View_Ctx, e: ^pa.Song_Edit, plot, full: im.Vec2) {
	a := ctx.a
	p := &a.m.project
	s := &p.song
	here := marker_at(s, e.cursor)
	names := make([]string, s.marker_count + 1, context.temp_allocator)
	names[0] = "—"
	for &mk, k in s.markers[:s.marker_count] do names[k + 1] = fmt.tprintf("%s (%s)", pm.marker_name(&mk), song_pos_name(p, mk.beat))
	if k, _ := ctl_choice(ctx, 1, 8, "Marker", names, here + 1, plot); k > 0 {
		pa.song_set_cursor(&a.api, s.markers[k - 1].beat)
		e^, _ = pa.song_edit_state(&a.api)
		here = k - 1
	}
	st, _ := pa.song_state(&a.api)
	lo, hi := st.loop_start, st.loop_end
	if !(hi > lo) do hi = lo + pm.bar_beats(p)
	if k, _ := ctl_value_box(ctx, 2, "Loop Start", song_pos_name(p, lo), CTL_STEP, plot); k != 0 {
		to := song_step(a, lo, k, a.ctl.song.shift)
		if to < hi do pa.song_set_loop(&a.api, st.loop_on, to, hi)
	}
	if k, _ := ctl_value_box(ctx, 3, "Loop End", song_pos_name(p, hi), CTL_STEP, plot); k != 0 {
		to := song_step(a, hi, k, a.ctl.song.shift)
		if to > lo do pa.song_set_loop(&a.api, st.loop_on, lo, to)
	}
	if pr, _ := ctl_button(ctx, 0, "Add", false, full); pr && here < 0 {
		pa.song_add_marker(&a.api, e.cursor, fmt.tprintf("Marker %d", s.marker_count + 1))
	}
	if here >= 0 {
		if pr, _ := ctl_button(ctx, 1, "Rename", false, full); pr {
			tm := &a.song_ui.time
			tm.rename = here
			tm.rename_open = true
		}
		if pr, _ := ctl_button(ctx, 2, "Delete", false, full); pr do pa.song_remove_marker(&a.api, i64(here))
	}
	if pr, _ := ctl_button(ctx, 3, "Loop", st.loop_on, full); pr do song_loop_toggle(a, e.cursor)
	if pr, _ := ctl_button(ctx, 4, "Start Here", false, full); pr && e.cursor < hi do pa.song_set_loop(&a.api, true, e.cursor, hi)
	if pr, _ := ctl_button(ctx, 5, "End Here", false, full); pr && e.cursor > lo do pa.song_set_loop(&a.api, true, lo, e.cursor)
	if pr, _ := ctl_button(ctx, 6, "Cue", false, full); pr do pa.song_jump(&a.api, e.cursor)
	a.ctl.song.caption = fmt.tprintf("%d marker%s · loop %s %s to %s", s.marker_count, "" if s.marker_count == 1 else "s", "on" if st.loop_on else "off", song_pos_name(p, lo), song_pos_name(p, hi))
}

// The tempo point at the cursor (-1: none).
@(private)
tempo_point_at :: proc(s: ^pm.Song, beat: f64) -> int {
	for pt, k in s.tempo[:s.tempo_count] do if abs(pt.beat - beat) < 1e-6 do return k
	return -1
}

// The time signature change at the cursor's bar (-1: none).
@(private)
meter_point_at :: proc(p: ^pm.Project, beat: f64) -> int {
	_, start := pm.song_bar_at(p, beat)
	for mt, k in p.song.meters[:p.song.meter_count] do if abs(mt.beat - start) < 1e-6 do return k
	return -1
}

// Tempo: the tempo at the cursor (a turn sets a point there), its ramp;
// the time signature from the cursor's bar.
@(private)
ctl_song_tempo :: proc(ctx: ^View_Ctx, e: ^pa.Song_Edit, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	p := &m.project
	s := &p.song
	pt := tempo_point_at(s, e.cursor)
	bpm := pm.song_tempo_at(p, e.cursor)
	if k, en := ctl_value_box(ctx, 1, "Tempo", fmt.tprintf("%.2f BPM%s", bpm, "" if pt >= 0 else " ·"), CTL_STEP, plot); k != 0 || en {
		if k != 0 {
			ramp := s.tempo[pt].ramp if pt >= 0 else false
			pa.history_gesture_begin(&a.api)
			pa.song_add_tempo_point(&a.api, {beat = e.cursor, bpm = clamp(bpm + f64(k) * (0.1 if a.ctl.song.shift else 1), 40, 300), ramp = ramp})
		}
		if en do pa.history_gesture_end(&a.api)
	}
	if pt >= 0 {
		if k, _ := ctl_choice(ctx, 2, 8, "Ramp", OFF_ON, int(s.tempo[pt].ramp), plot); k >= 0 {
			x := s.tempo[pt]
			pa.song_add_tempo_point(&a.api, {beat = x.beat, bpm = x.bpm, ramp = k == 1})
		}
	}
	sig := pm.song_meter_at(p, e.cursor)
	names := make([]string, len(SONG_METERS), context.temp_allocator)
	cur := -1
	for ts, k in SONG_METERS {
		names[k] = fmt.tprintf("%d/%d", ts.num, ts.den)
		if ts == sig do cur = k
	}
	if k, _ := ctl_choice(ctx, 3, 8, "Meter", names, max(cur, 2), plot); k >= 0 {
		_, start := pm.song_bar_at(p, e.cursor)
		pa.song_set_meter(&a.api, start, i64(SONG_METERS[k].num), i64(SONG_METERS[k].den))
	}
	if pr, _ := ctl_button(ctx, 0, "Add Point", pt >= 0, full); pr && pt < 0 do pa.song_add_tempo_point(&a.api, {beat = e.cursor, bpm = bpm})
	if pt >= 0 {
		if pr, _ := ctl_button(ctx, 1, "Remove Point", false, full); pr do pa.song_remove_tempo_point(&a.api, i64(pt))
	}
	if mt := meter_point_at(p, e.cursor); mt >= 0 {
		if pr, _ := ctl_button(ctx, 2, "Remove Meter", false, full); pr do pa.song_remove_meter(&a.api, i64(mt))
	}
	a.ctl.song.caption = fmt.tprintf("%.2f BPM at %s · %d/%d · %d tempo point%s", bpm, song_pos_name(p, e.cursor), sig.num, sig.den, s.tempo_count, "" if s.tempo_count == 1 else "s")
}
