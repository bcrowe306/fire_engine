package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// The song's time on the Song tab: its markers in a strip above the
// timeline (click one to go there, drag to move, double-click the strip
// for a new one, right-click to rename or remove), the loop range on the
// ruler, and the tempo lane under the steps (double-click for a point,
// drag one, right-click for a ramp or to remove it).

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
}

// Whether the tempo lane shows.
tempo_lane_shown :: proc(a: ^App) -> bool {
	return a.song_ui.time.show_tempo || a.m.project.song.tempo_count > 0
}

// Where song beats are across the timeline (the same as its blocks).
@(private)
song_x :: proc(b, total: f64, x0, x1: f32) -> f32 {
	return x0 + (x1 - x0) * f32(b / max(total, 1e-9))
}

draw_song_markers :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	t := ui.theme()
	total := pm.song_beats(p)
	if total <= 0 do return
	w := im.GetContentRegionAvail().x
	h: f32 = 18
	pos := im.GetCursorScreenPos()
	x0, x1 := pos.x + 6, pos.x + w - 70
	im.InvisibleButton("##markers", {w, h})
	ui.name("song markers")
	hot, down, active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	dl := im.GetWindowDrawList()
	mx := im.GetIO().MousePos.x
	over := -1
	for &mk, i in p.song.markers[:p.song.marker_count] {
		x := song_x(mk.beat, total, x0, x1)
		name := pm.marker_name(&mk)
		tw := im.CalcTextSize(fmt.ctprintf("%s", name)).x
		if hot && mx >= x - 4 && mx <= x + tw + 12 do over = i
		c := t.warn if i == over || i == tm.marker_drag else t.accent
		im.DrawList_AddTriangleFilled(dl, {x, pos.y + 2}, {x + 8, pos.y + 2}, {x, pos.y + h - 2}, ui.col(c))
		im.DrawList_AddText(dl, {x + 10, pos.y + 1}, ui.col(t.text), fmt.ctprintf("%s", name))
	}
	im.DrawList_AddText(dl, {x1 + 8, pos.y + 1}, ui.col(t.text_dim), "Markers")
	if hot && over >= 0 && tm.marker_drag < 0 do im.SetTooltip("%s", fmt.ctprintf("%s: click to go there, drag to move, right-click to rename", pm.marker_name(&p.song.markers[over])))
	if hot && over < 0 && tm.marker_drag < 0 do im.SetTooltip("Double-click: a marker here")
	if down && over >= 0 do tm.marker_drag, tm.marker_x, tm.marker_moved = over, mx, false
	if active && tm.marker_drag >= 0 && abs(mx - tm.marker_x) > 3 {
		tm.marker_moved = true
		b := clamp(math.round(f64((mx - x0) / (x1 - x0)) * total), 0, total) // (to the beat)
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
		_, b := pm.song_bar_at(p, clamp(f64((mx - x0) / (x1 - x0)) * total, 0, total))
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

draw_tempo_lane :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	t := ui.theme()
	total := pm.song_beats(p)
	if total <= 0 || !tempo_lane_shown(a) do return
	w := im.GetContentRegionAvail().x
	h: f32 = 40
	pos := im.GetCursorScreenPos()
	x0, x1 := pos.x + 6, pos.x + w - 70
	im.InvisibleButton("##tempolane", {w, h})
	ui.name("tempo lane")
	hot, down, active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.PLOT_BG), t.radius)
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
	// The curve.
	prev: im.Vec2
	n := 96
	for k in 0 ..= n {
		b := total * f64(k) / f64(n)
		q := im.Vec2{song_x(b, total, x0, x1), y_of(pm.tempo_in(pts, b), tm.lo, tm.hi, top, bottom)}
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
	// The points (the lane's own only: without one it shows the steps').
	over := -1
	if lane do for pt, i in pts {
		c := im.Vec2{song_x(pt.beat, total, x0, x1), y_of(pt.bpm, tm.lo, tm.hi, top, bottom)}
		if hot && abs(mx - c.x) < 6 && abs(my - c.y) < 8 do over = i
		r: f32 = 5 if i == over || i == tm.point_drag else 4
		im.DrawList_AddCircleFilled(dl, c, r, ui.col(t.warn if i == over || i == tm.point_drag else t.text))
		if i == over || i == tm.point_drag do im.DrawList_AddText(dl, {c.x + 6, top}, ui.col(t.text), fmt.ctprintf("%.1f", pt.bpm))
	}
	// The playhead, and the tempo now.
	step, _, beat := pm.song_progress(&m.engine)
	now := pm.song_tempo_at(p, max(beat, 0))
	if step >= 0 {
		x := song_x(beat, total, x0, x1)
		im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + h}, ui.col(t.warn), 1)
	}
	im.DrawList_AddText(dl, {x1 + 8, pos.y + 4}, ui.col(t.text_dim), "Tempo")
	im.DrawList_AddText(dl, {x1 + 8, pos.y + 4 + im.GetTextLineHeight()}, ui.col(t.text), fmt.ctprintf("%.1f", now))
	if hot && tm.point_drag < 0 {
		if over >= 0 do im.SetTooltip("Drag: its place and tempo · right-click: a ramp to the next, or remove it")
		else do im.SetTooltip("%s", fmt.ctprintf("Double-click: a tempo point%s", "" if lane else " (the steps' tempos become points)"))
	}
	beat_at :: proc(mx, x0, x1: f32, total: f64) -> f64 { return clamp(math.round(f64((mx - x0) / (x1 - x0)) * total), 0, total) }
	bpm_at :: proc(my, top, bottom: f32, lo, hi: f64) -> f64 { return math.round(lo + (hi - lo) * f64((bottom - my) / (bottom - top))) }
	if hot && over < 0 && im.IsMouseDoubleClicked(.Left) {
		b := beat_at(mx, x0, x1, total)
		pm.tempo_point_add(m, {b, bpm_at(my, top, bottom, tm.lo, tm.hi), false})
	}
	if down && over >= 0 do tm.point_drag = over
	if active && tm.point_drag >= 0 {
		pt := p.song.tempo[tm.point_drag]
		pm.tempo_point_set(m, tm.point_drag, {beat_at(mx, x0, x1, total), bpm_at(my, top, bottom, tm.lo, tm.hi), pt.ramp})
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

// The song's markers as a list (the Song tab's side): each one to go to,
// and one more where it plays (or starts).
draw_marker_list :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	tm := &a.song_ui.time
	im.TextDisabled("Markers")
	im.SameLine()
	if ui.icon_button(ui.ICON_PLUS, "A marker where the song plays (or starts)") {
		_, _, beat := pm.song_progress(&m.engine)
		b := beat if beat >= 0 else m.engine.cue
		_, start := pm.song_bar_at(p, max(b, 0))
		k := pm.marker_add(m, start, fmt.tprintf("Marker %d", p.song.marker_count + 1))
		if k >= 0 do tm.rename, tm.rename_open = k, true
	}
	im.Separator()
	if p.song.marker_count == 0 do im.TextDisabled("None yet: double-click above the timeline")
	for &mk, i in p.song.markers[:p.song.marker_count] {
		if im.Selectable(fmt.ctprintf("%s##mk%d", pm.marker_name(&mk), i)) do pm.song_jump(&m.engine, mk.beat)
		ui.name(fmt.tprintf("marker %s", pm.marker_name(&mk)))
		im.SameLine(im.GetContentRegionAvail().x - 40)
		n, _ := pm.song_bar_at(p, mk.beat)
		im.TextDisabled("%s", fmt.ctprintf("bar %d", n + 1))
	}
	draw_marker_rename(a)
	im.Spacing()
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
