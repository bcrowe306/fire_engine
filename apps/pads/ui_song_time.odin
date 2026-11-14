package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// The song's time on the Song tab, over its lanes: its markers in a strip
// (click one to go there, drag to move, double-click the strip for a new
// one, right-click to rename or remove), the ruler (the loop range), the
// time signature lane, and the tempo lane (double-click for a point, drag
// one, right-click for a ramp or to remove it).

// What the song time's drags and popups hold.
Song_Time_Ui :: struct {
	ruler_x:     f32, // a press on the ruler (0: none)
	ruler_moved: bool,
	ruler_from:  f64,
	menu_x:      f32, // where the ruler's menu was opened
	marker_drag: int, // the marker being dragged (-1: none)
	marker_x:    f32,
	marker_moved: bool,
	rename:      int, // the marker being renamed
	rename_open: bool,
	rename_buf:  [24]u8,
	point_drag:  int, // the tempo point being dragged (-1: none)
	point_menu:  int,
	lo, hi:      f64, // the tempo lane's range (held still while a point is dragged)
	show_tempo:  bool, // the tempo lane shows (it does anyway while the song has points)
	meter_at:    f64, // the bar a time signature is being picked for
}

// Whether the tempo lane shows.
tempo_lane_shown :: proc(a: ^App) -> bool {
	return a.song_ui.time.show_tempo || a.m.project.song.tempo_count > 0
}

// The markers strip (above the ruler): click one to go there, drag to
// move it, double-click the strip for a new one, right-click to rename or
// remove it.
draw_song_markers :: proc(a: ^App, v: Song_View) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	t := ui.theme()
	h: f32 = SONG_ROW_H
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##markers", {max(v.x1 - v.x0, 4), h})
	ui.name("song markers")
	hot, down, active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	dl := im.GetWindowDrawList()
	mx := im.GetIO().MousePos.x
	im.DrawList_PushClipRect(dl, {v.x0, pos.y}, {v.x1, pos.y + h}, true)
	over := -1
	for &mk, i in p.song.markers[:p.song.marker_count] {
		x := beat_x(v, mk.beat)
		name := pm.marker_name(&mk)
		tw := im.CalcTextSize(fmt.ctprintf("%s", name)).x
		if hot && mx >= x - 4 && mx <= x + tw + 12 do over = i
		c := t.warn if i == over || i == tm.marker_drag else t.accent
		im.DrawList_AddTriangleFilled(dl, {x, pos.y + 2}, {x + 8, pos.y + 2}, {x, pos.y + h - 2}, ui.col(c))
		im.DrawList_AddText(dl, {x + 10, pos.y + 1}, ui.col(t.text), fmt.ctprintf("%s", name))
	}
	im.DrawList_PopClipRect(dl)
	if hot && over >= 0 && tm.marker_drag < 0 do im.SetTooltip("%s", fmt.ctprintf("%s: click to go there, drag to move, right-click to rename", pm.marker_name(&p.song.markers[over])))
	if hot && over < 0 && tm.marker_drag < 0 do im.SetTooltip("Double-click: a marker here")
	if down && over >= 0 do tm.marker_drag, tm.marker_x, tm.marker_moved = over, mx, false
	if active && tm.marker_drag >= 0 && abs(mx - tm.marker_x) > 3 {
		tm.marker_moved = true
		b := max(math.round(x_beat(v, mx)), 0) // (to the beat)
		pm.marker_move(m, tm.marker_drag, b)
		// (It stays the dragged one where the order put it.)
		for k in 0 ..< p.song.marker_count do if p.song.markers[k].beat == b do tm.marker_drag = k
	}
	if !active && tm.marker_drag >= 0 {
		if tm.marker_moved do app.seal(&m.history)
		else do pm.song_jump(&m.engine, p.song.markers[tm.marker_drag].beat)
		tm.marker_drag = -1
	}
	if hot && over < 0 && im.IsMouseDoubleClicked(.Left) {
		_, b := pm.song_bar_at(p, max(x_beat(v, mx), 0))
		k := pm.marker_add(m, b, fmt.tprintf("Marker %d", p.song.marker_count + 1))
		if k >= 0 do tm.rename, tm.rename_open = k, true
	}
	if hot && over >= 0 && im.IsMouseClicked(.Right) {
		tm.rename = over
		im.OpenPopup("##markermenu")
	}
	if im.BeginPopup("##markermenu") {
		if im.MenuItem("Rename…") do tm.rename_open = true
		if im.MenuItem("Go there") do pm.song_jump(&m.engine, p.song.markers[tm.rename].beat)
		if im.MenuItem("Remove") do pm.marker_remove(m, tm.rename)
		im.EndPopup()
	}
	draw_marker_rename(a)
}

// The ruler: bars on the grid's step (labelled where they fit), the loop
// range. A click plays the song from its bar; a drag along it is the loop
// range (in bars); right-click for its menu (a marker, loop a bar, the
// whole song).
draw_song_ruler :: proc(a: ^App, v: Song_View) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	t := ui.theme()
	h: f32 = 20
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##ruler", {max(v.x1 - v.x0, 4), h})
	ui.name("song ruler")
	hot, down, active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	if im.IsItemClicked(.Right) do im.OpenPopup("##rulermenu")
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, {v.x0, pos.y}, {v.x1, pos.y + h}, ui.col(ui.PLOT_BG), 3)
	im.DrawList_PushClipRect(dl, {v.x0, pos.y}, {v.x1, pos.y + h}, true)
	s := &p.song
	if s.loop_on {
		la, lb := beat_x(v, s.loop_start), beat_x(v, s.loop_end)
		lc := t.accent if p.transport.loop else t.text_dim
		im.DrawList_AddRectFilled(dl, {la, pos.y}, {lb, pos.y + h}, ui.col(ui.with_alpha(lc, 0.35)), 2)
	}
	every, _ := grid_every(p, v)
	// Labels at least 34 points apart (a multiple of the grid's step).
	lab := every
	for f32(lab) * f32(pm.bar_beats(p)) * v.ppb < 34 do lab *= 2
	end_beat := x_beat(v, v.x1)
	bars := pm.song_bars(p, end_beat + 1)
	for b, k in bars {
		if b > end_beat do break
		if k % every != 0 do continue
		x := beat_x(v, b)
		if x < v.x0 - 40 do continue
		strong := k % lab == 0
		im.DrawList_AddLine(dl, {x, pos.y + (7 if strong else 13)}, {x, pos.y + h}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.45 if strong else 0.2)), 1)
		if strong do im.DrawList_AddText(dl, {x + 3, pos.y + 2}, ui.col(t.text_dim), fmt.ctprintf("%d", k + 1))
	}
	im.DrawList_PopClipRect(dl)
	mx := im.GetIO().MousePos.x
	at_bar :: proc(p: ^pm.Project, v: Song_View, mx: f32) -> f64 {
		_, s := pm.song_bar_at(p, max(x_beat(v, mx), 0))
		return s
	}
	bar_after :: proc(p: ^pm.Project, b: f64) -> f64 {
		n, _ := pm.song_bar_at(p, b)
		starts := pm.song_bars(p, b + 32)
		return starts[n + 1] if n + 1 < len(starts) else b + pm.bar_beats(p)
	}
	if hot && !tm.ruler_moved {
		b := at_bar(p, v, mx)
		x := beat_x(v, b)
		im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + h}, ui.col(ui.with_alpha(t.warn, 0.6)), 1)
		im.SetTooltip("%s", fmt.ctprintf("Click: play the song from bar %d · drag: the loop range · right-click: markers, the loop", bar_of(p, b)))
	}
	if down do tm.ruler_x, tm.ruler_moved, tm.ruler_from = mx, false, at_bar(p, v, mx)
	if active && abs(mx - tm.ruler_x) > 4 {
		tm.ruler_moved = true
		b := at_bar(p, v, mx)
		lo, hi := min(tm.ruler_from, b), bar_after(p, max(tm.ruler_from, b))
		pm.set_song_loop(m, true, lo, hi, drag = true)
		im.SetTooltip("%s", fmt.ctprintf("Loop bars %d to %d", bar_of(p, lo), bar_of(p, hi - 1e-6)))
	}
	if !active && tm.ruler_x != 0 {
		if tm.ruler_moved {
			app.seal(&m.history)
			if !p.transport.loop do p.transport.loop = true // (a range to loop: looping)
			m.engine.seq_dirty = true
		} else {
			pa.transport_set_song_mode(&a.api, true)
			pa.transport_play(&a.api, from_beat = max(tm.ruler_from, 0))
		}
		tm.ruler_x, tm.ruler_moved = 0, false
	}
	if im.BeginPopup("##rulermenu") {
		if tm.menu_x == 0 do tm.menu_x = mx
		b := at_bar(p, v, tm.menu_x)
		if im.MenuItem(fmt.ctprintf("Add a marker at bar %d", bar_of(p, b))) {
			k := pm.marker_add(m, b, fmt.tprintf("Marker %d", p.song.marker_count + 1))
			if k >= 0 do tm.rename, tm.rename_open = k, true
		}
		if im.MenuItem(fmt.ctprintf("Loop bar %d", bar_of(p, b))) do pm.set_song_loop(m, true, b, bar_after(p, b))
		if im.MenuItem("Loop the whole song", nil, false, p.song.loop_on) do pm.set_song_loop(m, false, 0, 0)
		im.Separator()
		if im.BeginMenu(fmt.ctprintf("Time signature from bar %d", bar_of(p, b))) {
			for ts in SONG_METERS do if im.MenuItem(fmt.ctprintf("%d/%d", ts.num, ts.den)) do pm.meter_set(m, b, ts)
			im.EndMenu()
		}
		im.EndPopup()
	} else {
		tm.menu_x = 0
	}
}

// The time signature lane: the signature from the song's start and each
// change, at the bar it starts. Click a change (or the start) to pick
// another, double-click the lane for a change at that bar; right-click a
// change to remove it.
draw_meter_lane :: proc(a: ^App, v: Song_View) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	h: f32 = SONG_ROW_H
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##meterlane", {max(v.x1 - v.x0, 4), h})
	ui.name("time signature lane")
	hot := im.IsItemHovered()
	dl := im.GetWindowDrawList()
	mx := im.GetIO().MousePos.x
	s := &p.song
	im.DrawList_PushClipRect(dl, {v.x0, pos.y}, {v.x1, pos.y + h}, true)
	over := -2 // -1: the song's start (the project's), else a change
	start_text := fmt.ctprintf("%d/%d", p.transport.time_sig.num, p.transport.time_sig.den)
	draw_sig :: proc(dl: ^im.DrawList, x, y: f32, text: cstring, hot: bool) -> f32 {
		t := ui.theme()
		w := im.CalcTextSize(text).x + 10
		im.DrawList_AddRectFilled(dl, {x, y + 1}, {x + w, y + SONG_ROW_H - 1}, ui.col(t.raised if !hot else ui.lighten(t.raised, 0.1)), 3)
		im.DrawList_AddText(dl, {x + 5, y + 1}, ui.col(t.text if hot else t.text_dim), text)
		return w
	}
	x0 := beat_x(v, 0)
	if s.meter_count == 0 || s.meters[0].beat > 1e-9 {
		w0 := im.CalcTextSize(start_text).x + 10
		if hot && mx >= x0 && mx < x0 + w0 do over = -1
		draw_sig(dl, x0, pos.y, start_text, over == -1)
	}
	for mt, i in s.meters[:s.meter_count] {
		x := beat_x(v, mt.beat)
		text := fmt.ctprintf("%d/%d", mt.sig.num, mt.sig.den)
		w := im.CalcTextSize(text).x + 10
		if hot && mx >= x && mx < x + w do over = i
		draw_sig(dl, x, pos.y, text, over == i)
	}
	im.DrawList_PopClipRect(dl)
	if hot {
		if over >= -1 do im.SetTooltip("Click: another time signature · right-click: remove the change")
		else do im.SetTooltip("Double-click: a time signature change at this bar")
	}
	if hot && over >= -1 && im.IsMouseClicked(.Left) {
		tm.meter_at = 0 if over == -1 else s.meters[over].beat
		im.OpenPopup("##meterpick")
	}
	if hot && over < -1 && im.IsMouseDoubleClicked(.Left) {
		_, b := pm.song_bar_at(p, max(x_beat(v, mx), 0))
		tm.meter_at = b
		im.OpenPopup("##meterpick")
	}
	if hot && over >= 0 && im.IsMouseClicked(.Right) do pm.meter_remove(m, over)
	if im.BeginPopup("##meterpick") {
		im.TextDisabled("%s", fmt.ctprintf("From bar %d", bar_of(p, tm.meter_at)))
		cur := pm.song_meter_at(p, tm.meter_at)
		for ts in SONG_METERS do if im.Selectable(fmt.ctprintf("%d/%d", ts.num, ts.den), ts == cur) do pm.meter_set(m, tm.meter_at, ts)
		im.EndPopup()
	}
}

// The marker rename box (a popup over everything).
@(private)
draw_marker_rename :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	if tm.rename_open {
		tm.rename_open = false
		if tm.rename >= 0 && tm.rename < p.song.marker_count {
			tm.rename_buf = {}
			copy(tm.rename_buf[:len(tm.rename_buf) - 1], pm.marker_name(&p.song.markers[tm.rename]))
			im.OpenPopup("Rename marker")
		}
	}
	if im.BeginPopupModal("Rename marker", nil, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(220)
		done := im.InputText("##mkname", cstring(&tm.rename_buf[0]), len(tm.rename_buf), {.EnterReturnsTrue, .AutoSelectAll})
		ui.name("marker name")
		if done || im.Button("Rename") {
			pm.marker_rename(m, tm.rename, strings.truncate_to_byte(string(tm.rename_buf[:]), 0))
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
}

draw_tempo_lane :: proc(a: ^App, v: Song_View) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	t := ui.theme()
	h: f32 = 40
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##tempolane", {max(v.x1 - v.x0, 4), h})
	ui.name("tempo lane")
	hot, down, active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, {v.x0, pos.y}, {v.x1, pos.y + h}, ui.col(ui.PLOT_BG), t.radius)
	pts := pm.song_tempo_points(p)
	lane := p.song.tempo_count > 0
	// Its range: the tempos it has, and some room (still while dragging).
	if tm.point_drag < 0 {
		lo, hi := 1000.0, 0.0
		for pt in pts do lo, hi = min(lo, pt.bpm), max(hi, pt.bpm)
		tm.lo, tm.hi = max(lo - 20, 40), min(hi + 20, 300)
	}
	top, bottom := pos.y + 4, pos.y + h - 4
	y_of :: proc(bpm, lo, hi: f64, top, bottom: f32) -> f32 { return bottom - (bottom - top) * f32((bpm - lo) / max(hi - lo, 1)) }
	mx, my := im.GetIO().MousePos.x, im.GetIO().MousePos.y
	im.DrawList_PushClipRect(dl, {v.x0, pos.y}, {v.x1, pos.y + h}, true)
	// The curve, across what shows.
	prev: im.Vec2
	n := 120
	b0, b1 := max(x_beat(v, v.x0), 0), x_beat(v, v.x1)
	for k in 0 ..= n {
		b := b0 + (b1 - b0) * f64(k) / f64(n)
		q := im.Vec2{beat_x(v, b), y_of(pm.tempo_in(pts, b), tm.lo, tm.hi, top, bottom)}
		if k > 0 {
			if ramping_at(pts, b) {
				im.DrawList_AddLine(dl, prev, q, ui.col(t.accent), 2)
			} else { // (a step: flat, then up or down at once)
				im.DrawList_AddLine(dl, prev, {q.x, prev.y}, ui.col(t.accent), 2)
				if abs(q.y - prev.y) > 0.5 do im.DrawList_AddLine(dl, {q.x, prev.y}, q, ui.col(t.accent), 2)
			}
		}
		prev = q
	}
	// The points (the lane's own only: without one it is the project's tempo).
	over := -1
	if lane do for pt, i in pts {
		c := im.Vec2{beat_x(v, pt.beat), y_of(pt.bpm, tm.lo, tm.hi, top, bottom)}
		if hot && abs(mx - c.x) < 6 && abs(my - c.y) < 8 do over = i
		r: f32 = 5 if i == over || i == tm.point_drag else 4
		im.DrawList_AddCircleFilled(dl, c, r, ui.col(t.warn if i == over || i == tm.point_drag else t.text))
		if i == over || i == tm.point_drag do im.DrawList_AddText(dl, {c.x + 6, top}, ui.col(t.text), fmt.ctprintf("%.1f", pt.bpm))
	}
	// The tempo now.
	_, _, beat := pm.song_progress(&m.engine)
	now := pm.song_tempo_at(p, max(beat, 0))
	im.DrawList_PopClipRect(dl)
	im.DrawList_AddText(dl, {v.x0 - SONG_HEAD + 6, pos.y + 4 + im.GetTextLineHeight()}, ui.col(t.text), fmt.ctprintf("%.1f", now))
	if hot && tm.point_drag < 0 {
		if over >= 0 do im.SetTooltip("Drag: its place and tempo · right-click: a ramp to the next, or remove it")
		else do im.SetTooltip("Double-click: a tempo point")
	}
	beat_at :: proc(v: Song_View, mx: f32) -> f64 { return max(math.round(x_beat(v, mx)), 0) }
	bpm_at :: proc(my, top, bottom: f32, lo, hi: f64) -> f64 { return math.round(lo + (hi - lo) * f64((bottom - my) / (bottom - top))) }
	if hot && over < 0 && im.IsMouseDoubleClicked(.Left) {
		pm.tempo_point_add(m, {beat_at(v, mx), bpm_at(my, top, bottom, tm.lo, tm.hi), false})
	}
	if down && over >= 0 do tm.point_drag = over
	if active && tm.point_drag >= 0 {
		pt := p.song.tempo[tm.point_drag]
		pm.tempo_point_set(m, tm.point_drag, {beat_at(v, mx), bpm_at(my, top, bottom, tm.lo, tm.hi), pt.ramp})
		im.SetTooltip("%s", fmt.ctprintf("%.0f BPM at beat %.0f", p.song.tempo[tm.point_drag].bpm, p.song.tempo[tm.point_drag].beat + 1))
	}
	if !active && tm.point_drag >= 0 {
		app.seal(&m.history)
		tm.point_drag = -1
	}
	if hot && over >= 0 && im.IsMouseClicked(.Right) {
		tm.point_menu = over
		im.OpenPopup("##pointmenu")
	}
	if im.BeginPopup("##pointmenu") {
		i := tm.point_menu
		if i >= 0 && i < p.song.tempo_count {
			pt := p.song.tempo[i]
			if im.MenuItem("Ramp to the next point", nil, pt.ramp, i + 1 < p.song.tempo_count) {
				pt.ramp = !pt.ramp
				pm.tempo_point_set(m, i, pt)
				app.seal(&m.history)
			}
			if im.MenuItem("Remove", nil, false, i > 0 || p.song.tempo_count == 1) do pm.tempo_point_remove(m, i)
		}
		im.EndPopup()
	}
}

// Whether the tempo lane ramps into song beat `b`.
@(private)
ramping_at :: proc(pts: []pm.Tempo_Point, b: f64) -> bool {
	r := false
	for pt, i in pts do if pt.beat < b && i + 1 < len(pts) do r = pt.ramp
	return r
}

// The song goes to the marker after (or, `back`, before) where it plays
// or starts (the song's start when there is none before).
marker_step :: proc(a: ^App, back: bool) {
	m := &a.m
	p := &m.project
	_, _, beat := pm.song_progress(&m.engine)
	at := beat if beat >= 0 else m.engine.cue
	// (Going back from just past a marker goes to the one before it.)
	if back && beat >= 0 do at -= 0.5
	k := pm.marker_next(p, at, back)
	if k >= 0 {
		pm.song_jump(&m.engine, p.song.markers[k].beat)
	} else if back {
		pm.song_jump(&m.engine, 0)
	}
}
