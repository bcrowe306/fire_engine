package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// The Song tab: the song as lanes of clips (any sequence on any lane, as
// long as you like, several playing at once). Across the top its bar
// (the arrangement, the tools, snap, a new lane, merging, the tempo lane,
// fitting it in); down the left every sequence to drag in; beside them the
// song's time (markers, the ruler, time signatures, tempo) over its lanes,
// on a grid of bars; under them the selected clip's settings.

// The Song tab's state: the clips selected, the tool, the view (zoom and
// scroll), what a drag is doing, renaming.
Song_State :: struct {
	cur:         int, // the clip whose settings show (-1: none)
	sel:         pm.Clip_Set, // the selected clips
	focused:     bool, // the Song tab has the keyboard (its clip keys work)
	tool:        Song_Tool,
	snap:        Song_Snap,
	copied:      [pm.SONG_CLIPS]pm.Song_Clip, // clips copied
	copied_n:    int,
	rename_open: bool,
	rename_buf:  [24]u8,
	label_buf:   [16]u8,
	label_for:   int,
	lane_rename: int, // the lane being renamed (-1: none)
	lane_open:   bool,
	lane_buf:    [16]u8,
	// The view: points a beat (0: fit the song on the next frame) and the
	// beat at the left edge.
	ppb:         f32,
	scroll:      f64,
	lane_h:      f32, // a lane's height now
	// A drag in the lanes.
	drag:        Song_Drag,
	drag_clip:   int,
	drag_from:   pm.Song, // the song as the drag began
	drag_sel:    pm.Clip_Set, // what it moves
	drag_x:      f32, // where it began
	drag_y:      f32,
	drag_beat:   f64, // the song beat it began at
	drag_lane:   int,
	box_sel:     pm.Clip_Set, // the selection before a box (Shift: added to)
	drop_lane:   int, // a sequence dragged in: where it would land
	drop_beat:   f64,
	// The bottom area: folded on coming to the Song tab (and unfolded on
	// leaving it, if it was this that folded it).
	shown_frame: i32,
	folded_it:   bool,
	time:        Song_Time_Ui, // the markers, the loop range, the tempo lane
}

// The Song tab's tools.
Song_Tool :: enum u8 {
	Select, // click, Shift- or Cmd-click, drag a box; drag clips to move them (Alt: copies), their ends to resize
	Draw,   // drag along a lane to paint the current sequence there
}

// What a clip's place and length snap to.
Song_Snap :: enum u8 {
	Bar,
	Beat,
	Off, // (to a 1/16)
}

// The names the snap shows.
SONG_SNAP_NAMES := [Song_Snap]cstring{.Bar = "Bar", .Beat = "Beat", .Off = "Off"}

// What a drag in the lanes does.
@(private)
Song_Drag :: enum u8 {
	None,
	Press, // the mouse is down on a clip: a click, unless it moves
	Move,  // the selection, in time and across lanes (Alt as it began: copies)
	Start, // a clip's left edge: where it begins (its notes stay where they are)
	End,   // its right edge: how long it is
	Draw,  // painting a new clip along a lane
	Box,   // a box selecting the clips it touches
}

// Where song beats are across the lanes: `x0` is beat `scroll`, `ppb`
// points a beat; `x1` is the right edge.
@(private)
Song_View :: struct {
	x0, x1: f32,
	scroll: f64,
	ppb:    f32,
}

@(private)
beat_x :: proc(v: Song_View, b: f64) -> f32 {
	return v.x0 + f32(b - v.scroll) * v.ppb
}

@(private)
x_beat :: proc(v: Song_View, x: f32) -> f64 {
	return v.scroll + f64((x - v.x0) / max(v.ppb, 1e-6))
}

// The lane headers' width, a lane's height, the top rows' heights.
@(private)
SONG_HEAD :: 104
@(private)
SONG_LANE_H :: 50 // (at least; lanes grow to fill the view, up to twice that)
@(private)
SONG_ROW_H :: 18

draw_song :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	if ss.cur >= p.song.count do ss.cur = p.song.count - 1
	for i in p.song.count ..< pm.SONG_CLIPS do ss.sel -= {i}
	ss.focused = im.IsWindowFocused({.RootWindow, .ChildWindows})
	fold_pads_while_shown(a, &ss.shown_frame, &ss.folded_it)
	song_keys(a)

	draw_arrangement_bar(a)
	im.Spacing()
	avail := im.GetContentRegionAvail()
	strip_h := im.GetFrameHeight() + 2 * im.GetStyle().WindowPadding.y + 2
	list_w: f32 = 168
	if im.BeginChild("##songlist", {list_w, avail.y - strip_h - 6}) do draw_song_side(a)
	im.EndChild()
	im.SameLine(0, 8)
	if im.BeginChild("##songtime", {avail.x - list_w - 8, avail.y - strip_h - 6}, {}, {.NoScrollbar, .NoScrollWithMouse}) do draw_song_lanes(a)
	im.EndChild()
	if im.BeginChild("##clipstrip", {avail.x, strip_h}, {.FrameStyle}, {.NoScrollbar}) do draw_clip_strip(a)
	im.EndChild()
}

// Coming to a tab that wants the height (Song, Perform) folds the pads
// area; leaving it unfolds it again if this folded it. (Unfolding it there
// keeps it unfolded.) `shown` and `folded_it` are the tab's own.
fold_pads_while_shown :: proc(a: ^App, shown: ^i32, folded_it: ^bool) {
	frame := im.GetFrameCount()
	if shown^ < frame - 1 && !a.ws.bottom_folded {
		a.ws.bottom_folded = true
		folded_it^ = true
	}
	if !a.ws.bottom_folded do folded_it^ = false
	shown^ = frame
}

// Each frame, after the panels: with neither Song nor Perform in view, the
// pads area they folded unfolds again (going from one to the other, it
// stays folded, the one in view keeping it so).
fold_pads_check :: proc(a: ^App) {
	frame := im.GetFrameCount()
	song, perf := &a.song_ui, &a.perf
	song_on, perf_on := song.shown_frame == frame, perf.shown_frame == frame
	if !song.folded_it && !perf.folded_it do return
	if !song_on && !perf_on {
		a.ws.bottom_folded = false
		song.folded_it, perf.folded_it = false, false
		return
	}
	song.folded_it, perf.folded_it = song_on, perf_on && !song_on
}

// The arrangement picker (its menu: new, duplicate, rename, delete), the
// tools, snap, a new lane, merging, the tempo lane, fitting the song in,
// and its length.
@(private)
draw_arrangement_bar :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	im.SetNextItemWidth(170)
	if ui.combo("##arrangement", fmt.ctprintf("%s  %s", ui.ICON_LIST_ORDERED, pm.arrangement_name(p, p.arrangement))) {
		for k in 0 ..< p.arrangement_count {
			if im.Selectable(fmt.ctprintf("%s###arr%d", pm.arrangement_name(p, k), k), k == p.arrangement) do pm.select_arrangement(m, k)
		}
		im.Separator()
		if im.Selectable(ui.ICON_PLUS + "  New Arrangement") do pm.add_arrangement(m)
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Arrangements: each a song of its own (Song mode and export play the current one); right-click for more")
	if im.BeginPopupContextItem("##arrmenu") {
		if im.MenuItem(ui.ICON_PLUS + "  New Arrangement") do pm.add_arrangement(m)
		if im.MenuItem(ui.ICON_COPY_PLUS + "  Duplicate") do pm.add_arrangement(m, copy_of = p.arrangement)
		if im.MenuItem(ui.ICON_PENCIL + "  Rename…") {
			ss.rename_buf = {}
			copy(ss.rename_buf[:len(ss.rename_buf) - 1], pm.arrangement_name(p, p.arrangement))
			ss.rename_open = true
		}
		if im.MenuItem(ui.ICON_TRASH_2 + "  Delete", nil, false, p.arrangement_count > 1) do pm.delete_arrangement(m, p.arrangement)
		im.EndPopup()
	}
	if ss.rename_open {
		im.OpenPopup("Rename Arrangement")
		ss.rename_open = false
	}
	if im.BeginPopupModal("Rename Arrangement", nil, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(240)
		done := im.InputText("##arr_rename", cstring(&ss.rename_buf[0]), len(ss.rename_buf), {.EnterReturnsTrue, .AutoSelectAll})
		ui.name("arrangement rename")
		if done || im.Button("Rename") {
			pm.rename_arrangement(m, p.arrangement, strings.truncate_to_byte(string(ss.rename_buf[:]), 0))
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
	// The tools.
	im.SameLine(0, 14)
	tools := [2]struct { tool: Song_Tool, icon: string, tip: cstring }{
		{.Select, ui.ICON_MOUSE_POINTER_2, "Select (V): click, Shift- or Cmd-click, drag a box; drag clips to move them (Alt: copies), their ends to resize"},
		{.Draw, ui.ICON_PENCIL, "Draw (B): drag along a lane to paint the current sequence there"},
	}
	for tl, k in tools {
		if k > 0 do im.SameLine(0, 2)
		if ui.icon_button(tl.icon, tl.tip, on = ss.tool == tl.tool) do ss.tool = tl.tool
	}
	im.SameLine(0, 10)
	ui.icon_button(ui.ICON_MAGNET, "Snap: where clips start and end (Shift while dragging: to the beat)", on = ss.snap != .Off)
	im.SameLine(0, 2)
	im.SetNextItemWidth(78)
	if ui.combo("##songsnap", SONG_SNAP_NAMES[ss.snap]) {
		for s in Song_Snap do if im.Selectable(SONG_SNAP_NAMES[s], s == ss.snap) do ss.snap = s
		im.EndCombo()
	}
	ui.name("song snap")
	im.SameLine(0, 10)
	if im.Button(ui.ICON_PLUS + "  Lane") do pm.lane_add(m)
	ui.name("add lane")
	if im.IsItemHovered() do im.SetTooltip("A new lane at the bottom")
	im.SameLine(0, 6)
	im.SetNextItemWidth(150)
	if ui.combo("##merge", "Merge into this…") {
		for k in 0 ..< pm.SLOTS do if k != p.slot && pm.slot_used(m, k) {
			if im.Selectable(fmt.ctprintf("%s###m%d", pm.sequence_name(p, k), k)) do pm.merge_sequences(m, k, p.slot)
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Lay another sequence's notes over the current one")
	im.SameLine(0, 10)
	tm := &ss.time
	shown := tempo_lane_shown(a)
	if ui.toggle("Tempo lane", &shown) do tm.show_tempo = shown
	if im.IsItemHovered() do im.SetTooltip("The song's tempo under its time signatures (shown while it has points)")
	im.SameLine(0, 6)
	if ui.icon_button(ui.ICON_MAXIMIZE_2, "Fit the song in (Cmd+0); Cmd+scroll zooms, scrolling sideways moves along") do ss.ppb = 0
	// Its length, at the right.
	total := pm.song_beats(p)
	text := fmt.ctprintf("%s · %d bars", clock_text(pm.song_seconds(p)), max(len(pm.song_bars(p)) - 1, 0) if total > 0 else 0)
	tw := im.CalcTextSize(text).x
	im.SameLine(max(im.GetCursorPosX() + 8, im.GetCursorPosX() + im.GetContentRegionAvail().x - tw - 8))
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", text)
	ui.name("song length")
}

// "1:23": seconds as minutes and seconds.
@(private)
clock_text :: proc(secs: f64) -> string {
	s := int(math.round(max(secs, 0)))
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// Beat `b` snapped as the Song tab snaps (to its bars, beats or 1/16;
// Shift: beats instead of bars).
@(private)
song_snap :: proc(a: ^App, b: f64) -> f64 {
	p := &a.m.project
	s := a.song_ui.snap
	if s == .Bar && im.GetIO().KeyShift do s = .Beat
	switch s {
	case .Bar:
		bars := pm.song_bars(p, b + 64)
		best := 0.0
		for x in bars do if abs(x - b) < abs(best - b) do best = x
		return best
	case .Beat: return math.round(b)
	case .Off:  return math.round(b * 16) / 16
	}
	return b
}

// The grid's step: every 1, 2, 4, 8... bars, as many as keep its lines at
// least 24 points apart; and whether the beats show too.
@(private)
grid_every :: proc(p: ^pm.Project, v: Song_View) -> (bars: int, beats: bool) {
	bar_px := f32(pm.bar_beats(p)) * v.ppb
	bars = 1
	for f32(bars) * bar_px < 24 && bars < 1 << 12 do bars *= 2
	return bars, v.ppb >= 12
}

// The song's time over its lanes: the markers, the ruler, the time
// signature lane and the tempo lane on top; the lanes under them (their
// headers at the left), the grid behind the clips, the playhead through
// it all. Cmd+scroll zooms round the mouse, scrolling sideways moves along.
@(private)
draw_song_lanes :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	t := ui.theme()
	io := im.GetIO()
	origin := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	total := pm.song_beats(p)
	v := Song_View{x0 = origin.x + SONG_HEAD, x1 = origin.x + avail.x - 4, scroll = ss.scroll, ppb = ss.ppb}
	// Fit: the song and four bars more (at least 16 bars) across.
	if ss.ppb <= 0 {
		shown := max(total + 4 * pm.bar_beats(p), 16 * pm.bar_beats(p))
		ss.ppb = (v.x1 - v.x0) / f32(shown)
		ss.scroll = 0
		v.ppb, v.scroll = ss.ppb, 0
	}
	// Zoom and scroll, over the time area.
	over := im.IsWindowHovered({.ChildWindows}) && io.MousePos.x >= v.x0
	if over && io.KeyCtrl && io.MouseWheel != 0 {
		at := x_beat(v, io.MousePos.x)
		ss.ppb = clamp(ss.ppb * math.pow(f32(1.2), io.MouseWheel), 0.5, 200)
		ss.scroll = max(at - f64((io.MousePos.x - v.x0) / ss.ppb), 0)
	} else if over && (io.MouseWheelH != 0 || (io.KeyShift && io.MouseWheel != 0)) {
		d := io.MouseWheelH if io.MouseWheelH != 0 else io.MouseWheel
		ss.scroll = max(ss.scroll - f64(d * 40 / ss.ppb), 0)
	}
	if ss.focused && !io.WantTextInput && io.KeyCtrl && im.IsKeyPressed(._0, false) do ss.ppb = 0
	v.ppb, v.scroll = ss.ppb, ss.scroll
	dl := im.GetWindowDrawList()
	// The top rows: markers, the ruler, time signatures, tempo.
	label :: proc(dl: ^im.DrawList, x, y: f32, text: cstring) {
		im.DrawList_AddText(dl, {x + 6, y + 1}, ui.col(ui.theme().text_dim), text)
	}
	y := origin.y
	label(dl, origin.x, y, "Markers")
	im.SetCursorScreenPos({v.x0, y})
	draw_song_markers(a, v)
	y += SONG_ROW_H
	ruler_y := y
	im.SetCursorScreenPos({v.x0, y})
	draw_song_ruler(a, v)
	y += 20
	label(dl, origin.x, y, "Time")
	im.SetCursorScreenPos({v.x0, y})
	draw_meter_lane(a, v)
	y += SONG_ROW_H
	if tempo_lane_shown(a) {
		label(dl, origin.x, y + 4, "Tempo")
		im.SetCursorScreenPos({v.x0, y})
		draw_tempo_lane(a, v)
		y += 40
	}
	y += 2
	// The lanes, scrolling up and down under them.
	im.SetCursorScreenPos({origin.x, y})
	lanes_h := origin.y + avail.y - y
	ss.lane_h = clamp((lanes_h - im.GetFrameHeight() - 12) / f32(max(pm.song_lanes(&p.song), 1)), SONG_LANE_H, 2 * SONG_LANE_H)
	lane_flags: im.WindowFlags = {.NoScrollWithMouse} if io.KeyCtrl || io.KeyShift else {}
	if im.BeginChild("##lanes", {avail.x, lanes_h}, {}, lane_flags) {
		draw_lanes_body(a, v, total)
	}
	im.EndChild()
	// The playhead (or, stopped in song mode, where it starts) through it all.
	_, _, beat := pm.song_progress(&m.engine)
	if beat >= 0 {
		x := beat_x(v, beat)
		if x >= v.x0 && x <= v.x1 {
			im.DrawList_AddLine(dl, {x, ruler_y}, {x, min(origin.y + avail.y, y + f32(pm.song_lanes(&p.song)) * ss.lane_h)}, ui.col(t.warn), 2)
			im.DrawList_AddTriangleFilled(dl, {x - 5, ruler_y}, {x + 5, ruler_y}, {x, ruler_y + 7}, ui.col(t.warn))
		}
		// Following it: the view moves along when it passes the right edge.
		if x > v.x1 - 20 && ss.drag == .None do ss.scroll = beat - f64((v.x1 - v.x0) * 0.1 / v.ppb)
	}
}

// The lanes: each one's header (its name, Mute and Solo) and, beside it,
// its clips on the grid. Clips are dragged to move (Alt: copies), their ends
// to resize; empty space takes a box (Select) or a painted clip (Draw), a
// double-click the current sequence, and a sequence dropped from the list.
@(private)
draw_lanes_body :: proc(a: ^App, v: Song_View, total: f64) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	t := ui.theme()
	io := im.GetIO()
	s := &p.song
	n_lanes := pm.song_lanes(s)
	origin := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	body_h := f32(n_lanes) * a.song_ui.lane_h
	lane_y :: proc(origin: im.Vec2, i: int, h: f32) -> f32 { return origin.y + f32(i) * h }
	// The background and the grid.
	im.DrawList_AddRectFilled(dl, {v.x0, origin.y}, {v.x1, origin.y + body_h}, ui.col(ui.PLOT_BG), t.radius)
	im.DrawList_PushClipRect(dl, {v.x0, origin.y}, {v.x1, origin.y + body_h}, true)
	every, beats := grid_every(p, v)
	end_beat := x_beat(v, v.x1)
	bars := pm.song_bars(p, end_beat + 1)
	for b, k in bars {
		if b > end_beat do break
		x := beat_x(v, b)
		if x < v.x0 - 1 do continue
		strong := k % every == 0
		if !strong && !beats do continue
		im.DrawList_AddLine(dl, {x, origin.y}, {x, origin.y + body_h}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.16 if strong else 0.07)), 1)
		if beats && k + 1 < len(bars) {
			for bb := b + 1; bb < bars[k + 1] - 1e-9; bb += 1 {
				bx := beat_x(v, bb)
				im.DrawList_AddLine(dl, {bx, origin.y}, {bx, origin.y + body_h}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.04)), 1)
			}
		}
	}
	// Past the song's end, shaded a little.
	if total > 0 {
		xe := beat_x(v, total)
		if xe < v.x1 do im.DrawList_AddRectFilled(dl, {max(xe, v.x0), origin.y}, {v.x1, origin.y + body_h}, ui.col(ui.with_alpha(t.bg, 0.35)))
	}
	// The loop range, faintly.
	if s.loop_on {
		la, lb := beat_x(v, s.loop_start), beat_x(v, s.loop_end)
		lc := t.accent if p.transport.loop else t.text_dim
		im.DrawList_AddRectFilled(dl, {la, origin.y}, {lb, origin.y + body_h}, ui.col(ui.with_alpha(lc, 0.06)))
	}
	for i in 1 ..< n_lanes {
		yy := lane_y(origin, i, a.song_ui.lane_h)
		im.DrawList_AddLine(dl, {v.x0, yy}, {v.x1, yy}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.1)), 1)
	}
	im.DrawList_PopClipRect(dl)
	// The headers.
	for i in 0 ..< n_lanes do draw_lane_header(a, i, {origin.x, lane_y(origin, i, a.song_ui.lane_h)})
	draw_lane_rename(a)
	// The clips: each an item (named "clip N"), drawn and dragged.
	mx, my := io.MousePos.x, io.MousePos.y
	EDGE :: 7
	clicked_clip := false
	im.DrawList_PushClipRect(dl, {v.x0, origin.y}, {v.x1, origin.y + body_h}, true)
	for i in 0 ..< s.count {
		c := s.clips[i]
		xa, xb := beat_x(v, c.at), beat_x(v, pm.clip_end(c))
		if xb < v.x0 || xa > v.x1 do continue
		top := lane_y(origin, int(c.lane), a.song_ui.lane_h) + 3
		bottom := top + a.song_ui.lane_h - 6
		ra, rb := max(xa, v.x0), min(xb, v.x1)
		im.SetCursorScreenPos({ra, top})
		im.PushIDInt(i32(i))
		im.InvisibleButton("##clip", {max(rb - ra, 2), bottom - top})
		ui.name(fmt.tprintf("clip %d", i + 1))
		hovered, pressed, active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
		item_menu(a, {kind = .Song_Clip, index = i}, "##clipmenu")
		im.PopID()
		edge := Song_Drag.Move
		if hovered && ss.drag == .None {
			if mx < xa + EDGE && xb - xa > 3 * EDGE do edge = .Start
			else if mx > xb - EDGE do edge = .End
			if edge != .Move do im.SetMouseCursor(.ResizeEW)
		}
		if pressed {
			clicked_clip = true
			ss.drag_clip, ss.drag_x, ss.drag_y = i, mx, my
			ss.drag_from = s^
			ss.drag_beat = x_beat(v, mx)
			ss.drag_lane = int(c.lane)
			if edge == .Move {
				ss.drag = .Press
			} else {
				ss.drag = edge
				ss.cur = i
				if i not_in ss.sel do ss.sel = {i}
			}
		}
		if hovered && im.IsMouseDoubleClicked(.Left) {
			pa.sequence_select(&a.api, i64(int(c.slot)))
			ui.panel_focus(&a.ws, "sequence")
		}
		_ = active
		draw_clip(a, i, c, {xa, top}, {xb, bottom}, hovered && ss.drag == .None, edge)
	}
	// A clip being painted, or a sequence about to be dropped: where it lands.
	if ss.drag == .Box {
		a0 := im.Vec2{min(ss.drag_x, mx), min(ss.drag_y, my)}
		b0 := im.Vec2{max(ss.drag_x, mx), max(ss.drag_y, my)}
		im.DrawList_AddRectFilled(dl, a0, b0, ui.col(ui.with_alpha(t.accent, 0.12)))
		im.DrawList_AddRect(dl, a0, b0, ui.col(ui.with_alpha(t.accent, 0.7)), 2)
	}
	im.DrawList_PopClipRect(dl)
	// The empty space: a box, a painted clip, a double-click, a drop.
	im.SetCursorScreenPos({v.x0, origin.y})
	im.InvisibleButton("##lanespace", {max(v.x1 - v.x0, 4), body_h})
	ui.name("song lanes")
	space_hot, space_down, space_active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	lane_at := clamp(int((my - origin.y) / a.song_ui.lane_h), 0, pm.SONG_LANES - 1)
	if space_hot && ss.drag == .None {
		if ss.tool == .Draw do im.SetTooltip("%s", fmt.ctprintf("Drag: paint %s along this lane", pm.sequence_name(p, p.slot)))
	}
	if space_hot && ss.tool == .Select && im.IsMouseDoubleClicked(.Left) && ss.drag == .None {
		b := song_snap(a, x_beat(v, mx))
		k := pm.song_add(m, p.slot, lane = lane_at, at = max(b, 0))
		if k >= 0 do ss.sel, ss.cur = {k}, k
	} else if space_down && !clicked_clip {
		ss.drag_x, ss.drag_y = mx, my
		ss.drag_from = s^
		ss.drag_beat = x_beat(v, mx)
		ss.drag_lane = lane_at
		if ss.tool == .Draw {
			ss.drag = .Draw
		} else {
			ss.drag = .Box
			ss.box_sel = ss.sel if io.KeyShift || io.KeyCtrl else {}
		}
	}
	// A sequence dragged from the list onto a lane.
	ss.drop_lane = -1
	if im.BeginDragDropTarget() {
		b := song_snap(a, max(x_beat(v, mx), 0))
		ss.drop_lane, ss.drop_beat = lane_at, b
		if pl := im.AcceptDragDropPayload("SEQUENCE"); pl != nil {
			k := pm.song_add(m, int((^i32)(pl.Data)^), lane = lane_at, at = b)
			if k >= 0 do ss.sel, ss.cur = {k}, k
		}
		im.EndDragDropTarget()
	}
	if ss.drop_lane >= 0 && im.GetDragDropPayload() != nil {
		pl := im.GetDragDropPayload()
		slot := int((^i32)(pl.Data)^) if pl.DataSize == size_of(i32) else p.slot
		if slot >= 0 && slot < pm.SLOTS {
			xa := beat_x(v, ss.drop_beat)
			xb := beat_x(v, ss.drop_beat + pm.seq_beats(p, p.sequences[slot]))
			yy := lane_y(origin, ss.drop_lane, a.song_ui.lane_h)
			im.DrawList_AddRect(dl, {xa, yy + 3}, {xb, yy + a.song_ui.lane_h - 3}, ui.col(ui.rgb(pm.sequence_color(p, slot))), 5, 2)
		}
	}
	// The lane under the last one: a new lane.
	im.SetCursorScreenPos({origin.x, origin.y + body_h + 4})
	if n_lanes < pm.SONG_LANES {
		if im.Button(ui.ICON_PLUS + "  Lane##below") do pm.lane_add(m)
		ui.name("add lane below")
	}
	if s.count == 0 {
		msg: cstring = "Drag a sequence onto a lane, double-click a lane, or paint with the pencil"
		ts := im.CalcTextSize(msg)
		im.DrawList_AddText(dl, {v.x0 + max((v.x1 - v.x0 - ts.x) / 2, 8), origin.y + (a.song_ui.lane_h - ts.y) / 2}, ui.col(t.text_dim), msg)
	}
	song_drag_update(a, v, origin, space_active)
}

// A clip: its sequence's colour, its name (or section), its notes along it
// (each pass, from where its part starts), a notch where its sequence goes
// round, hatched when muted, outlined when selected, grips at its ends.
@(private)
draw_clip :: proc(a: ^App, i: int, c: pm.Song_Clip, lo, hi: im.Vec2, hovered: bool, edge: Song_Drag) {
	p := &a.m.project
	ss := &a.song_ui
	t := ui.theme()
	dl := im.GetWindowDrawList()
	col := ui.rgb(pm.sequence_color(p, int(c.slot)))
	heard := pm.clip_heard(&p.song, i)
	if !heard do col = ui.mix(col, ui.PLOT_BG, 0.6)
	sel := i in ss.sel
	fill := ui.mix(col, ui.PLOT_BG, 0.2 if sel else 0.42)
	if hovered do fill = ui.lighten(fill, 0.05)
	if ss.drag == .Move && i in ss.drag_sel && !im.GetIO().KeyAlt do fill = ui.with_alpha(fill, 0.85)
	im.DrawList_AddRectFilled(dl, {lo.x + 1, lo.y}, {hi.x - 1, hi.y}, ui.col(fill), 5)
	w := hi.x - lo.x
	// Its notes: the sequence's, each pass.
	period := pm.clip_period(p, c)
	full := pm.seq_beats(p, p.sequences[c.slot])
	if period > 0 && full > 0 && w > 6 {
		ppb := w / f32(max(c.length, 1e-9))
		minis := seq_minis(a, int(c.slot))
		nc := ui.with_alpha(ui.mix(col, t.text, 0.55), 0.8)
		top := lo.y + im.GetTextLineHeight() + 6
		ph := math.mod(c.phase, period)
		im.DrawList_PushClipRect(dl, {lo.x + 2, lo.y}, {hi.x - 2, hi.y}, true)
		for off := -ph; off < c.length - 1e-9; off += period {
			px := lo.x + f32(off) * ppb // where this pass's part starts
			pa, pb := max(px, lo.x), min(px + f32(period) * ppb, hi.x)
			if pb <= pa do continue
			im.DrawList_PushClipRect(dl, {pa, lo.y}, {pb, hi.y}, true)
			sx := px - f32(c.start) * ppb // the whole sequence's left
			ui.mini_notes(dl, minis, {sx, top}, {sx + f32(full) * ppb, hi.y - 4}, nc)
			im.DrawList_PopClipRect(dl)
			if off > 0 do im.DrawList_AddLine(dl, {px, lo.y + 4}, {px, lo.y + 10}, ui.col(ui.with_alpha(t.text, 0.5)), 1)
		}
		im.DrawList_PopClipRect(dl)
	}
	if !heard do for x := lo.x + 4; x < hi.x - 4; x += 7 do im.DrawList_AddLine(dl, {x, hi.y - 2}, {min(x + 8, hi.x - 2), lo.y + 2}, ui.col(ui.with_alpha(t.text, 0.1)), 1)
	// Its name.
	if w > 18 {
		label := pm.clip_label(&p.song.clips[i])
		name := pm.sequence_name(p, int(c.slot))
		text := fmt.ctprintf("%s · %s", label, name) if label != "" else fmt.ctprintf("%s", name)
		if c.transpose != 0 do text = fmt.ctprintf("%s  %+d", text, c.transpose)
		im.DrawList_PushClipRect(dl, {lo.x + 2, lo.y}, {hi.x - 4, hi.y}, true)
		im.DrawList_AddText(dl, {max(lo.x, im.GetWindowPos().x + SONG_HEAD) + 7, lo.y + 3}, ui.col(t.text if heard else t.text_dim), text)
		im.DrawList_PopClipRect(dl)
	}
	if sel do im.DrawList_AddRect(dl, {lo.x + 1, lo.y}, {hi.x - 1, hi.y}, ui.col(t.text), 5, 2 if i == ss.cur else 1.5)
	// Its grips, while hovered or selected (the one under the mouse lit).
	dragged := (ss.drag == .Start || ss.drag == .End) && ss.drag_clip == i
	if (sel || hovered || dragged) && w > 16 {
		for e in ([2]Song_Drag{.Start, .End}) {
			hot := hovered && edge == e || dragged && ss.drag == e
			gx := lo.x + 3 if e == .Start else hi.x - 5
			im.DrawList_AddRectFilled(dl, {gx, lo.y + 10}, {gx + 2, hi.y - 10}, ui.col(t.warn if hot else ui.with_alpha(t.text, 0.5)), 1)
		}
	}
}

// What a drag in the lanes does as the mouse moves, and when it ends.
@(private)
song_drag_update :: proc(a: ^App, v: Song_View, origin: im.Vec2, space_active: bool) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	io := im.GetIO()
	mx, my := io.MousePos.x, io.MousePos.y
	if ss.drag == .None do return
	held := im.IsMouseDown(.Left)
	from := ss.drag_from
	switch ss.drag {
	case .None:
	case .Press:
		if !held {
			select_clip(ss, ss.drag_clip) // a click
			ss.drag = .None
		} else if abs(mx - ss.drag_x) > 4 || abs(my - ss.drag_y) > 4 {
			if ss.drag_clip not_in ss.sel do select_clip(ss, ss.drag_clip)
			ss.drag = .Move
			ss.drag_sel = ss.sel
			// Alt as it begins: copies (the originals stay; one undo step).
			if io.KeyAlt {
				copies: pm.Clip_Set
				for k in 0 ..< from.count do if k in ss.sel && from.count < pm.SONG_CLIPS {
					from.clips[from.count] = from.clips[k]
					copies += {from.count}
					from.count += 1
				}
				ss.drag_from, ss.drag_sel = from, copies
			}
		}
	case .Move:
		if !held {
			app.seal(&m.history)
			if ss.drag_sel != ss.sel {
				ss.sel = ss.drag_sel
				for k in 0 ..< pm.SONG_CLIPS do if k in ss.sel {
					ss.cur = k
					break
				}
			}
			ss.drag = .None
			return
		}
		im.SetMouseCursor(.ResizeAll)
		lead := from.clips[ss.drag_clip] if ss.drag_clip < from.count else pm.Song_Clip{}
		dt := song_snap(a, lead.at + x_beat(v, mx) - ss.drag_beat) - lead.at
		dl := int(math.floor((my - origin.y) / a.song_ui.lane_h)) - ss.drag_lane
		copying := ss.drag_sel != ss.sel
		pm.song_move_clips(m, from, ss.drag_sel, dt, dl, "Copy Clips" if copying else "Move Clips")
		im.SetTooltip("%s", fmt.ctprintf("%s bar %d%s", "Copy to" if copying else "Move to", bar_of(p, max(lead.at + dt, 0)), fmt.tprintf(", %s", pm.lane_name(&p.song, clamp(int(lead.lane) + dl, 0, pm.SONG_LANES - 1))) if dl != 0 else ""))
	case .Start, .End:
		if !held {
			app.seal(&m.history)
			ss.drag = .None
			return
		}
		im.SetMouseCursor(.ResizeEW)
		i := ss.drag_clip
		if i >= from.count do return
		o := from.clips[i]
		c := o
		period := pm.clip_period(p, o)
		snap_min := 1.0 / 16
		if ss.drag == .End {
			e := song_snap(a, pm.clip_end(o) + x_beat(v, mx) - ss.drag_beat)
			c.length = max(e - o.at, snap_min)
		} else {
			b := clamp(song_snap(a, o.at + x_beat(v, mx) - ss.drag_beat), 0, pm.clip_end(o) - snap_min)
			d := b - o.at
			c.at, c.length = b, o.length - d
			if period > 0 do c.phase = math.mod(math.mod(o.phase + d, period) + period, period)
		}
		pm.set_song_clip_drag(m, i, c, "Clip Start" if ss.drag == .Start else "Clip Length")
		passes := c.length / max(period, 1e-9)
		im.SetTooltip("%s", fmt.ctprintf("%s: bar %d, %g beats (%s × its sequence)", pm.sequence_name(p, int(c.slot)), bar_of(p, c.at), c.length, fmt.tprintf("%.2g", passes)))
	case .Draw:
		slot := p.slot
		b0 := song_snap(a, max(ss.drag_beat, 0))
		cur := x_beat(v, mx)
		length := song_snap(a, cur) - b0
		if abs(mx - ss.drag_x) < 4 do length = pm.seq_beats(p, p.sequences[slot]) // a click: its own length
		length = max(length, 1.0 / 16)
		if from.count >= pm.SONG_CLIPS {
			ss.drag = .None
			return
		}
		s := from
		s.clips[s.count] = {lane = u8(ss.drag_lane), slot = u8(slot), at = b0, length = length}
		s.count += 1
		s.lane_count = max(s.lane_count, ss.drag_lane + 1)
		pm.set_song_drag(m, "Draw Clip", s)
		if !held {
			app.seal(&m.history)
			ss.sel, ss.cur = {s.count - 1}, s.count - 1
			ss.drag = .None
			return
		}
		im.SetTooltip("%s", fmt.ctprintf("%s: %g beats", pm.sequence_name(p, slot), length))
	case .Box:
		if !held {
			if abs(mx - ss.drag_x) < 3 && abs(my - ss.drag_y) < 3 && ss.box_sel == {} {
				ss.sel, ss.cur = {}, -1 // a click on nothing
			}
			ss.drag = .None
			return
		}
		lo_b, hi_b := x_beat(v, min(ss.drag_x, mx)), x_beat(v, max(ss.drag_x, mx))
		l0 := int(math.floor((min(ss.drag_y, my) - origin.y) / a.song_ui.lane_h))
		l1 := int(math.floor((max(ss.drag_y, my) - origin.y) / a.song_ui.lane_h))
		sel := ss.box_sel
		for c, k in p.song.clips[:p.song.count] {
			if int(c.lane) >= l0 && int(c.lane) <= l1 && c.at < hi_b && pm.clip_end(c) > lo_b do sel += {k}
		}
		ss.sel = sel
		ss.cur = -1
		for k in 0 ..< p.song.count do if k in sel {
			ss.cur = k
			break
		}
	}
	_ = space_active
}

// The bar song beat `b` is in (1-based).
@(private)
bar_of :: proc(p: ^pm.Project, b: f64) -> int {
	n, _ := pm.song_bar_at(p, b)
	return n + 1
}

// A lane's header: its name (double-click to rename) and Mute and Solo.
@(private)
draw_lane_header :: proc(a: ^App, i: int, pos: im.Vec2) {
	m := &a.m
	s := &m.project.song
	ss := &a.song_ui
	t := ui.theme()
	dl := im.GetWindowDrawList()
	l := s.lanes[i]
	h: f32 = a.song_ui.lane_h
	im.DrawList_AddRectFilled(dl, {pos.x, pos.y + 1}, {pos.x + SONG_HEAD - 6, pos.y + h - 1}, ui.col(t.raised), t.radius)
	im.PushIDInt(i32(i))
	defer im.PopID()
	name := pm.lane_name(s, i)
	im.SetCursorScreenPos({pos.x, pos.y + 2})
	im.InvisibleButton("##lanename", {SONG_HEAD - 6, h / 2 - 2})
	ui.name(fmt.tprintf("lane %d", i + 1))
	if im.IsItemHovered() {
		im.SetTooltip("Double-click: rename")
		if im.IsMouseDoubleClicked(.Left) {
			ss.lane_rename, ss.lane_open = i, true
		}
	}
	im.DrawList_PushClipRect(dl, pos, {pos.x + SONG_HEAD - 8, pos.y + h}, true)
	im.DrawList_AddText(dl, {pos.x + 8, pos.y + 5}, ui.col(t.text if !pm.lane_silent(s, i) else t.text_dim), fmt.ctprintf("%s", name))
	im.DrawList_PopClipRect(dl)
	bs := im.GetFrameHeight() * 0.8
	im.SetCursorScreenPos({pos.x + 4, pos.y + h - bs - 4})
	if ui.icon_button("M", fmt.ctprintf("Mute %s", name), on = l.mute, size = bs, color = t.warn) {
		l.mute = !l.mute
		pm.lane_set(m, i, l, "Mute Lane")
	}
	im.SetCursorScreenPos({pos.x + 6 + bs, pos.y + h - bs - 4})
	if ui.icon_button("S", fmt.ctprintf("Solo %s", name), on = l.solo, size = bs) {
		l.solo = !l.solo
		pm.lane_set(m, i, l, "Solo Lane")
	}
}

// The lane rename box.
@(private)
draw_lane_rename :: proc(a: ^App) {
	m := &a.m
	ss := &a.song_ui
	if ss.lane_open {
		ss.lane_open = false
		if ss.lane_rename >= 0 && ss.lane_rename < pm.SONG_LANES {
			ss.lane_buf = {}
			copy(ss.lane_buf[:len(ss.lane_buf) - 1], pm.lane_name(&m.project.song, ss.lane_rename))
			im.OpenPopup("Rename lane")
		}
	}
	if im.BeginPopupModal("Rename lane", nil, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(200)
		done := im.InputText("##lanerename", cstring(&ss.lane_buf[0]), len(ss.lane_buf), {.EnterReturnsTrue, .AutoSelectAll})
		ui.name("lane name")
		if done || im.Button("Rename") {
			pm.lane_rename(m, ss.lane_rename, strings.trim_space(strings.truncate_to_byte(string(ss.lane_buf[:]), 0)))
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
}

// Selects clip `i`: alone, or with Shift or Cmd one more (or less). Its
// settings show.
@(private)
select_clip :: proc(ss: ^Song_State, i: int) {
	io := im.GetIO()
	if io.KeyShift || io.KeyCtrl { // (Cmd on macOS)
		ss.sel ~= {i}
	} else {
		ss.sel = {i}
	}
	ss.cur = i if i in ss.sel else -1
}

// The clips the keys act on: the selection, else the clip showing.
@(private)
song_targets :: proc(a: ^App) -> pm.Clip_Set {
	ss := &a.song_ui
	if ss.sel != {} do return ss.sel
	if ss.cur >= 0 && ss.cur < a.m.project.song.count do return {ss.cur}
	return {}
}

// Whether the Song tab's keys act on clips: it has the keyboard, with clips selected.
song_editing :: proc(a: ^App) -> bool {
	return a.song_ui.focused && song_targets(a) != {}
}

// Copies the selected clips (Cmd+C). False when none are.
song_copy :: proc(a: ^App) -> bool {
	ss := &a.song_ui
	sel := song_targets(a)
	if sel == {} do return false
	ss.copied_n = 0
	for c, i in a.m.project.song.clips[:a.m.project.song.count] do if i in sel {
		ss.copied[ss.copied_n] = c
		ss.copied_n += 1
	}
	ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Copied %d clip%s", ss.copied_n, "" if ss.copied_n == 1 else "s"))
	return true
}

// Pastes the copied clips on their lanes: right after the selection (or,
// with none, where the song plays or starts, to the bar); they become the
// selection.
song_paste :: proc(a: ^App) {
	ss := &a.song_ui
	m := &a.m
	p := &m.project
	if ss.copied_n == 0 do return
	lo := math.F64_MAX
	for c in ss.copied[:ss.copied_n] do lo = min(lo, c.at)
	to := 0.0
	sel := song_targets(a)
	if sel != {} {
		for c, i in p.song.clips[:p.song.count] do if i in sel do to = max(to, pm.clip_end(c))
	} else {
		_, _, beat := pm.song_progress(&m.engine)
		b := beat if beat >= 0 else m.engine.cue
		_, to = pm.song_bar_at(p, max(b, 0))
	}
	added := pm.song_insert_clips(m, ss.copied[:ss.copied_n], to - lo)
	if added == {} do return
	ss.sel = added
	for k in 0 ..< pm.SONG_CLIPS do if k in added {
		ss.cur = k
		break
	}
}

// Duplicates the selected clips right after themselves (Cmd+D).
song_duplicate :: proc(a: ^App) {
	ss := &a.song_ui
	sel := song_targets(a)
	if sel == {} do return
	added := pm.song_duplicate_clips(&a.m, sel)
	if added == {} do return
	ss.sel = added
	for k in 0 ..< pm.SONG_CLIPS do if k in added {
		ss.cur = k
		break
	}
}

// Removes the selected clips (Delete, Backspace).
song_delete :: proc(a: ^App) {
	ss := &a.song_ui
	sel := song_targets(a)
	if sel == {} do return
	pm.song_remove_clips(&a.m, sel)
	ss.sel, ss.cur = {}, -1
}

// The Song tab's keys, while it has the keyboard: Backspace removes the
// selected clips, Cmd+X cuts them, Cmd+A selects them all, V and B pick the
// tools. (Delete, Cmd+C, Cmd+V and Cmd+D are the app's shortcuts, which
// come here while the tab has the keyboard.)
@(private)
song_keys :: proc(a: ^App) {
	ss := &a.song_ui
	io := im.GetIO()
	if !ss.focused || io.WantTextInput do return
	n := a.m.project.song.count
	if io.KeyCtrl && im.IsKeyPressed(.A, false) {
		ss.sel = {}
		for k in 0 ..< n do ss.sel += {k}
		return
	}
	if io.KeyCtrl && im.IsKeyPressed(.X, false) {
		if song_copy(a) do song_delete(a)
		return
	}
	if io.KeyCtrl || io.KeyAlt do return
	if im.IsKeyPressed(.Backspace, false) do song_delete(a)
	if im.IsKeyPressed(.V, false) do ss.tool = .Select
	if im.IsKeyPressed(.B, false) do ss.tool = .Draw
	if im.IsKeyPressed(.Escape, false) {
		ss.tool = .Select
		ss.sel, ss.cur = {}, -1
	}
}

// Every sequence slot, to build the song from: its colour, name, length,
// own tempo and how many clips of it the song has (the playing one lit).
// Click to edit it, drag it onto a lane (or double-click it, or its +, for
// the end of the first lane); right-click for its commands (its colour
// among them).
@(private)
draw_song_side :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	t := ui.theme()
	im.TextDisabled("Sequences")
	im.Separator()
	playing := -1
	if c, _, _ := pm.song_progress(&m.engine); c >= 0 && c < p.song.count do playing = int(p.song.clips[c].slot)
	dl := im.GetWindowDrawList()
	first_empty := -1
	for k in 0 ..< pm.SLOTS do if !pm.slot_used(m, k) && k != p.slot {
		first_empty = k
		break
	}
	for k in 0 ..< pm.SLOTS {
		used := pm.slot_used(m, k)
		if !used && k != p.slot && k != first_empty do continue // (the sequences in use, the current one, and one empty: a new one)
		im.PushIDInt(i32(k))
		s := p.sequences[k]
		uses := 0
		for c in p.song.clips[:p.song.count] do if int(c.slot) == k do uses += 1
		w := im.GetContentRegionAvail().x
		h: f32 = 38 if used else 22
		pos := im.GetCursorScreenPos()
		btn := im.GetFrameHeight()
		clicked := im.InvisibleButton("##seq", {w - (btn + 4 if used else 0), h})
		ui.name(fmt.tprintf("song seq %d", k + 1))
		hovered := im.IsItemHovered()
		if hovered && im.IsMouseDoubleClicked(.Left) && used do pm.song_add(m, k)
		else if clicked do pa.sequence_select(&a.api, i64(k))
		item_menu(a, seq_target(k), "##sidemenu")
		if used && im.BeginDragDropSource() {
			slot := i32(k)
			im.SetDragDropPayload("SEQUENCE", &slot, size_of(slot))
			im.Text("%s", fmt.ctprintf("%s", pm.sequence_name(p, k)))
			im.EndDragDropSource()
		}
		c := ui.rgb(pm.sequence_color(p, k))
		bg := t.raised if used else ui.mix(t.bg, t.raised, 0.4)
		if k == playing do bg = ui.mix(t.raised, c, 0.55)
		else if k == p.slot do bg = ui.mix(t.raised, c, 0.25)
		if hovered do bg = ui.lighten(bg, 0.06)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		im.DrawList_AddRectFilled(dl, {pos.x, pos.y}, {pos.x + 4, pos.y + h}, ui.col(c if used else ui.with_alpha(c, 0.3)), 2)
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + (4 if used else (h - im.GetTextLineHeight()) / 2)}, ui.col(t.text if used else t.text_dim), fmt.ctprintf("%s", pm.sequence_name(p, k)))
		if used {
			info := fmt.tprintf("%d bar%s%s", s.bars, "" if s.bars == 1 else "s", fmt.tprintf(" · %.0f BPM", s.bpm) if s.bpm > 0 else "")
			if uses > 0 do info = fmt.tprintf("%s · %d in song", info, uses)
			im.DrawList_AddText(dl, {pos.x + 10, pos.y + 4 + im.GetTextLineHeightWithSpacing() - 2}, ui.col(t.text_dim), fmt.ctprintf("%s", info))
			im.SameLine(0, 4)
			im.SetCursorScreenPos({pos.x + w - btn, pos.y + (h - btn) / 2})
			if ui.icon_button(ui.ICON_PLUS, fmt.ctprintf("Add %s at the end of the first lane", pm.sequence_name(p, k))) do pm.song_add(m, k)
		}
		im.SetCursorScreenPos({pos.x, pos.y + h + 3})
		im.Dummy({1, 0})
		im.PopID()
	}
}

// The time signatures the song's lane offers.
SONG_METERS := [?]pm.Time_Sig{{2, 4}, {3, 4}, {4, 4}, {5, 4}, {6, 4}, {7, 4}, {3, 8}, {5, 8}, {6, 8}, {7, 8}, {9, 8}, {12, 8}}

// The selected clip's settings, one line: its sequence, its section name,
// where it starts (bar), how long, transposed, muted; its part (which
// beats of its sequence go round) in "…"; duplicate and remove.
@(private)
draw_clip_strip :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	i := ss.cur
	n_sel := card(ss.sel)
	if i < 0 || i >= p.song.count {
		im.AlignTextToFramePadding()
		im.TextDisabled("%s", fmt.ctprintf("%s", fmt.tprintf("%d clips selected", n_sel) if n_sel > 1 else "Select a clip for its settings · drag a sequence onto a lane to add one"))
		return
	}
	c := p.song.clips[i]
	edit :: proc(m: ^pm.Model, i: int, c: pm.Song_Clip, name: string, e: ui.Edit) {
		if e.changed do pm.set_song_clip_drag(m, i, c, name)
		if e.ended do app.seal(&m.history)
	}
	im.AlignTextToFramePadding()
	col := ui.rgb(pm.sequence_color(p, int(c.slot)))
	im.TextColored(transmute(im.Vec4)col, "%s", fmt.ctprintf("%s", ui.ICON_SQUARE))
	im.SameLine(0, 6)
	im.SetNextItemWidth(140)
	if ui.combo("##clipseq", fmt.ctprintf("%s", pm.sequence_name(p, int(c.slot)))) {
		for k in 0 ..< pm.SLOTS do if pm.slot_used(m, k) || k == int(c.slot) {
			if im.Selectable(fmt.ctprintf("%s###cs%d", pm.sequence_name(p, k), k), k == int(c.slot)) {
				x := c
				x.slot, x.start, x.part, x.phase = u8(k), 0, 0, 0
				pm.set_song_clip(m, i, x, "Clip Sequence")
			}
		}
		im.EndCombo()
	}
	ui.name("clip sequence")
	im.SameLine(0, 6)
	if ss.label_for != i {
		ss.label_buf = c.label
		ss.label_for = i
	}
	im.SetNextItemWidth(130)
	if im.InputTextWithHint("##cliplabel", "Section (Verse…)", cstring(&ss.label_buf[0]), len(ss.label_buf)) {
		x := c
		x.label = ss.label_buf
		pm.set_song_clip_drag(m, i, x, "Name Clip")
	}
	ui.name("clip section")
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	// Where and how long (in bars, as numbers to drag or type).
	bar := pm.bar_beats(p)
	im.SameLine(0, 10)
	at := c.at / bar + 1
	e := ui.number_drag("clip start", &at, 1, 9999, 1, 0.25, "Bar  %.4g", 110)
	x := c
	x.at = max((at - 1) * bar, 0)
	edit(m, i, x, "Clip Start", e)
	im.SameLine(0, 6)
	length := c.length / bar
	e = ui.number_drag("clip length", &length, 1.0 / 16, 9999, 1, 0.25, "Length  %.4g bars", 140)
	x = c
	x.length = max(length * bar, 1.0 / 16)
	edit(m, i, x, "Clip Length", e)
	im.SameLine(0, 6)
	tr := f64(c.transpose)
	e = ui.number_drag("clip transpose", &tr, -24, 24, 1, 1, "Transpose  %+.0f", 120)
	x = c
	x.transpose = i8(clamp(int(math.round(tr)), -24, 24))
	edit(m, i, x, "Clip Transpose", e)
	im.SameLine(0, 6)
	mute := c.mute
	if ui.toggle("Mute", &mute) {
		x = c
		x.mute = mute
		pm.set_song_clip(m, i, x, "Mute Clip")
	}
	ui.name("clip mute")
	im.SameLine(0, 6)
	if ui.icon_button(ui.ICON_ELLIPSIS, "More: the part of its sequence it goes round") do im.OpenPopup("##clipmore")
	if im.BeginPopup("##clipmore") {
		full := pm.seq_beats(p, p.sequences[c.slot])
		im.TextDisabled("%s", fmt.ctprintf("The part of %s it goes round (beats)", pm.sequence_name(p, int(c.slot))))
		start := c.start
		e = ui.number_drag("part start", &start, 0, max(full - 0.25, 0), 1, 0.25, "From  %.2f", 140)
		x = c
		x.start = start
		if x.part > 0 do x.part = min(x.part, full - start)
		edit(m, i, x, "Clip Part", e)
		im.SameLine(0, 6)
		part := pm.clip_period(p, c)
		e = ui.number_drag("part length", &part, 0.25, max(full - c.start, 0.25), 1, 0.25, "Length  %.2f", 140)
		x = c
		x.part = 0 if part >= full - c.start - 1e-9 else part
		edit(m, i, x, "Clip Part", e)
		if im.Button("Whole sequence") {
			x = c
			x.start, x.part, x.phase = 0, 0, 0
			pm.set_song_clip(m, i, x, "Clip Part")
		}
		im.EndPopup()
	}
	im.SameLine(0, 10)
	if ui.icon_button(ui.ICON_COPY_PLUS, "Duplicate after itself (Cmd+D)") do song_duplicate(a)
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_X, "Remove (Delete)") do song_delete(a)
	im.SameLine(0, 10)
	im.AlignTextToFramePadding()
	secs := pm.song_seconds_between(p, c.at, pm.clip_end(c))
	im.TextDisabled("%s", fmt.ctprintf("%s%s", clock_text(secs), fmt.tprintf(" · %d selected", n_sel) if n_sel > 1 else ""))
}
