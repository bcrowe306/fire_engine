package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// The Song tab's state: the step whose settings show, renaming an
// arrangement.
Song_State :: struct {
	step:        int, // the step whose settings show (-1: none)
	sel:         pm.Step_Set, // the selected steps (Shift: a range, Cmd: one more or less)
	anchor:      int, // where a Shift-click range starts
	focused:     bool, // the Song tab has the keyboard (its step keys work)
	clip:        [pm.SONG_STEPS]pm.Song_Step, // steps copied
	clip_n:      int,
	rename_open: bool,
	rename_buf:  [24]u8,
	label_buf:   [16]u8,
	label_for:   int,
	// Dragging on the timeline: a block's start or end, or the selection.
	drag:        Song_Drag,
	drag_step:   int,
	drag_orig:   pm.Song_Step,
	drag_x:      f32, // where the drag began
	drag_bpp:    f64, // beats a point, while it lasts
	drag_total:  f64, // the song's length as it began (the scale holds still)
	drop_to:     int, // moving: before which step it lands
}

// What a drag on the timeline does.
@(private)
Song_Drag :: enum u8 {
	None,
	Press, // the mouse is down on a block: a click, unless it moves
	Start, // a block's left handle: where its part starts (its end stays)
	End,   // its right handle: how long its part is
	Move,  // the selection, to elsewhere in the song
}

// The song, arranged: the arrangement (several songs, one current), its
// timeline across the top (bars, minutes, its steps in their sequences'
// colours, the playhead; click the ruler to play from there), and below
// it the sequences down the left (drag or double-click into the song),
// the steps in order in the middle (drag to move, the playing one runs a
// bar across), and the selected step's settings on the right: which
// sequence, how many times, which part of it, muted, transposed, its
// tempo, its name.
draw_song :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	if ss.step >= p.song.count do ss.step = p.song.count - 1
	for i in p.song.count ..< pm.SONG_STEPS do ss.sel -= {i}
	ss.focused = im.IsWindowFocused({.RootWindow, .ChildWindows})
	song_keys(a)

	draw_arrangement_bar(a)
	im.Spacing()
	draw_song_timeline(a)
	im.Spacing()

	avail := im.GetContentRegionAvail()
	left_w, right_w: f32 = 220, 300
	if im.BeginChild("##songside", {left_w, avail.y}) do draw_song_side(a)
	im.EndChild()
	im.SameLine(0, 8)
	if im.BeginChild("##songsteps", {max(avail.x - left_w - right_w - 16, 160), avail.y}) do draw_song_steps(a)
	im.EndChild()
	im.SameLine(0, 8)
	if im.BeginChild("##stepsettings", {right_w, avail.y}) do draw_step_settings(a)
	im.EndChild()
}

// The arrangement picker (its menu: new, duplicate, rename, delete),
// Pattern | Song (in the toolbar too), adding the current sequence,
// merging.
@(private)
draw_arrangement_bar :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	im.SetNextItemWidth(180)
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
	im.SameLine(0, 16)
	mode := 1 if p.song_mode else 0
	if ui.segmented("song_mode", {"Pattern", "Song"}, &mode) {
		p.song_mode = mode == 1
		m.engine.seq_dirty = true
	}
	im.SameLine(0, 16)
	if im.Button(fmt.ctprintf("%s  Add %s###addseq", ui.ICON_PLUS, pm.sequence_name(p, p.slot))) do pm.song_add(m, p.slot)
	ui.name("Add the current sequence")
	im.SameLine()
	im.SetNextItemWidth(170)
	if ui.combo("##merge", "Merge into this…") {
		for k in 0 ..< pm.SLOTS do if k != p.slot && pm.slot_used(m, k) {
			if im.Selectable(fmt.ctprintf("%s###m%d", pm.sequence_name(p, k), k)) do pm.merge_sequences(m, k, p.slot)
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Lay another sequence's notes over this one")
}

// "1:23": seconds as minutes and seconds.
@(private)
clock_text :: proc(secs: f64) -> string {
	s := int(math.round(max(secs, 0)))
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// The song across the top: a ruler of bars and minutes (given the
// steps' tempos), its steps as blocks as long as they play (their
// sequences' colours, their names or labels, repeats marked, muted ones
// hatched), the total time, the playhead. Click a block to select it
// (Shift: a range, Cmd: one more), drag its edges to change the part it
// plays (bars; Shift: beats), drag its middle to move the selection; click
// the ruler to play from there.
@(private)
draw_song_timeline :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	t := ui.theme()
	io := im.GetIO()
	total := pm.song_beats(p)
	secs := pm.song_seconds(p)
	w := im.GetContentRegionAvail().x
	ruler_h, lane_h: f32 = 20, 46
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	im.InvisibleButton("##ruler", {w, ruler_h})
	ui.name("song ruler")
	ruler_hot := im.IsItemHovered()
	ruler_clicked := im.IsItemClicked()
	im.InvisibleButton("##timeline", {w, lane_h})
	ui.name("song timeline")
	lane_hot, lane_down, lane_active := im.IsItemHovered(), im.IsItemActivated(), im.IsItemActive()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + ruler_h + lane_h}, ui.col(ui.PLOT_BG), t.radius)
	if total <= 0 {
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + ruler_h + 12}, ui.col(t.text_dim), "The song is empty: drag sequences in from the left.")
		return
	}
	// While an edge is dragged the scale holds still, so the edge stays
	// under the mouse.
	shown := ss.drag_total if ss.drag == .Start || ss.drag == .End else total
	x0, x1 := pos.x + 6, pos.x + w - 70
	bx :: proc(b, total: f64, x0, x1: f32) -> f32 { return x0 + (x1 - x0) * f32(b / total) }
	im.DrawList_PushClipRect(dl, {x0 - 6, pos.y}, {x1 + 2, pos.y + ruler_h + lane_h}, true)
	// The ruler: bars (fewer labels when they crowd).
	bar := pm.bar_beats(p)
	bars := int(math.ceil(max(total, shown) / bar))
	every := max(1, int(math.ceil(f32(bars) * 34 / (x1 - x0))))
	for b in 0 ..= bars {
		x := bx(f64(b) * bar, shown, x0, x1)
		strong := b % every == 0
		im.DrawList_AddLine(dl, {x, pos.y + (8 if strong else 13)}, {x, pos.y + ruler_h}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.4 if strong else 0.15)), 1)
		if strong && b < bars do im.DrawList_AddText(dl, {x + 3, pos.y + 2}, ui.col(t.text_dim), fmt.ctprintf("%d", b + 1))
	}
	// The blocks, and what the mouse is over: a block's handle or its middle.
	EDGE :: 6
	at := 0.0
	top, bottom := pos.y + ruler_h + 3, pos.y + ruler_h + lane_h - 3
	n := p.song.count
	step_x := make([]f32, n + 1, context.temp_allocator)
	mx := io.MousePos.x
	hover_step, hover_edge := -1, Song_Drag.None
	for &st, i in p.song.steps[:n] {
		period := pm.step_period(p, st)
		span := period * f64(max(st.repeats, 1))
		xa, xb := bx(at, shown, x0, x1), bx(at + span, shown, x0, x1)
		step_x[i] = xa
		if lane_hot && mx >= xa && mx < xb {
			hover_step = i
			hover_edge = .Start if mx < xa + EDGE && xb - xa > 3 * EDGE else (.End if mx >= xb - EDGE else .Move)
		}
		at += span
	}
	step_x[n] = bx(at, shown, x0, x1)
	if lane_hot && hover_step < 0 && n > 0 && mx >= step_x[n] - EDGE && mx < step_x[n] + EDGE do hover_step, hover_edge = n - 1, .End
	at = 0
	for &st, i in p.song.steps[:n] {
		period := pm.step_period(p, st)
		xa, xb := step_x[i], step_x[i + 1]
		c := ui.rgb(pm.sequence_color(p, int(st.slot)))
		if st.mute do c = ui.mix(c, ui.PLOT_BG, 0.65)
		sel := i in ss.sel || i == ss.step
		moving := ss.drag == .Move && i in ss.sel
		fill := ui.mix(c, ui.PLOT_BG, 0.25 if sel else 0.45)
		if moving do fill = ui.with_alpha(fill, 0.4)
		im.DrawList_AddRectFilled(dl, {xa + 1, top}, {xb - 1, bottom}, ui.col(fill), 4)
		if sel do im.DrawList_AddRect(dl, {xa + 1, top}, {xb - 1, bottom}, ui.col(t.text), 4, 2 if i == ss.step else 1.5)
		for r in 1 ..< int(max(st.repeats, 1)) { // each repeat
			x := bx(at + period * f64(r), shown, x0, x1)
			im.DrawList_AddLine(dl, {x, top + 6}, {x, bottom - 6}, ui.col(ui.with_alpha(c, 0.8)), 1)
		}
		if st.mute do for x := xa + 4; x < xb - 4; x += 7 do im.DrawList_AddLine(dl, {x, bottom - 2}, {min(x + 8, xb - 2), top + 2}, ui.col(ui.with_alpha(t.text, 0.12)), 1)
		label := pm.step_label(&st)
		if label == "" do label = pm.sequence_name(p, int(st.slot))
		if xb - xa > 24 {
			im.DrawList_PushClipRect(dl, {xa + 2, top}, {xb - 2, bottom}, true)
			im.DrawList_AddText(dl, {xa + 8, top + 4}, ui.col(t.text), fmt.ctprintf("%s", label))
			im.DrawList_AddText(dl, {xa + 8, top + 4 + im.GetTextLineHeight()}, ui.col(t.text_dim), fmt.ctprintf("×%d%s", st.repeats, "  muted" if st.mute else ""))
			im.DrawList_PopClipRect(dl)
		}
		// Its handles: grips at both ends while it is hovered or selected;
		// the one under the mouse (or dragged) lit.
		dragged := (ss.drag == .Start || ss.drag == .End) && ss.drag_step == i
		if sel || hover_step == i || dragged {
			for edge in ([2]Song_Drag{.Start, .End}) {
				hot := hover_step == i && hover_edge == edge || dragged && ss.drag == edge
				gx := xa + 3 if edge == .Start else xb - 5
				gc := t.warn if hot else ui.with_alpha(t.text, 0.55)
				im.DrawList_AddRectFilled(dl, {gx, top + 8}, {gx + 2, bottom - 8}, ui.col(gc), 1)
			}
		}
		at += period * f64(max(st.repeats, 1))
	}
	// Moving: where the selection lands.
	if ss.drag == .Move {
		to := n
		for k in 0 ..< n do if mx < (step_x[k] + step_x[k + 1]) / 2 {
			to = k
			break
		}
		ss.drop_to = to
		x := step_x[to]
		im.DrawList_AddLine(dl, {x, top - 2}, {x, bottom + 2}, ui.col(t.accent), 3)
	}
	// The playhead.
	step, _, beat := pm.song_progress(&m.engine)
	if step >= 0 {
		x := bx(beat, shown, x0, x1)
		im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + ruler_h + lane_h}, ui.col(t.warn), 2)
		im.DrawList_AddTriangleFilled(dl, {x - 5, pos.y}, {x + 5, pos.y}, {x, pos.y + 7}, ui.col(t.warn))
	}
	im.DrawList_PopClipRect(dl)
	im.DrawList_AddText(dl, {x1 + 8, pos.y + 2}, ui.col(t.text), fmt.ctprintf("%s", clock_text(secs)))
	im.DrawList_AddText(dl, {x1 + 8, pos.y + ruler_h + 4}, ui.col(t.text_dim), fmt.ctprintf("%d bars", int(math.ceil(total / bar))))
	if ruler_hot {
		b := clamp(f64((mx - x0) / (x1 - x0)) * total, 0, total)
		b = math.floor(b / bar) * bar
		x := bx(b, total, x0, x1)
		im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + ruler_h}, ui.col(ui.with_alpha(t.warn, 0.6)), 1)
		im.SetTooltip("%s", fmt.ctprintf("Play the song from bar %d", int(b / bar) + 1))
	}
	if ruler_clicked {
		b := math.floor(clamp(f64((mx - x0) / (x1 - x0)) * total, 0, total) / bar) * bar
		p.song_mode = true
		m.engine.seq_dirty = true
		pm.play(&m.engine, from_beat = b)
	}

	// The mouse on the lane.
	if lane_hot && ss.drag == .None {
		if hover_edge == .Start || hover_edge == .End do im.SetMouseCursor(.ResizeEW)
		if hover_edge == .Start do im.SetTooltip("Drag: where its part starts (bars; Shift: beats)")
		if hover_edge == .End do im.SetTooltip("Drag: how long its part is (bars; Shift: beats)")
	}
	if lane_down && hover_step >= 0 {
		ss.drag_step, ss.drag_x = hover_step, mx
		ss.drag_orig = p.song.steps[hover_step]
		ss.drag_bpp = shown / f64(x1 - x0)
		ss.drag_total = total
		ss.drag = hover_edge if hover_edge != .Move else .Press
		if ss.drag != .Press do ss.step = hover_step
	}
	if !lane_active {
		switch ss.drag {
		case .Press: select_step(ss, ss.drag_step) // a click
		case .Start, .End: app.seal(&m.history)
		case .Move:
			moved := pm.song_move_steps(m, ss.sel, ss.drop_to)
			if moved != {} {
				ss.sel = moved
				for k in 0 ..< n do if k in moved {
					ss.step, ss.anchor = k, k
					break
				}
			}
		case .None:
		}
		ss.drag = .None
		return
	}
	switch ss.drag {
	case .Press:
		if abs(mx - ss.drag_x) > 4 {
			if ss.drag_step not_in ss.sel do select_step(ss, ss.drag_step)
			ss.drag = .Move
		}
	case .Start, .End:
		im.SetMouseCursor(.ResizeEW)
		drag_edge(a, f64(mx - ss.drag_x) * ss.drag_bpp)
	case .Move:
		im.SetMouseCursor(.ResizeAll)
	case .None:
	}
}

// A block's edge dragged by `beats` (on the timeline: its repeats' worth):
// its part's start (its end stays) or its length, on bars (Shift: beats),
// within its sequence.
@(private)
drag_edge :: proc(a: ^App, beats: f64) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	i := ss.drag_step
	if i < 0 || i >= p.song.count do return
	o := ss.drag_orig
	full := pm.seq_beats(p, p.sequences[o.slot])
	unit := 1.0 if im.GetIO().KeyShift else pm.bar_beats(p)
	unit = min(unit, full)
	d := beats / f64(max(o.repeats, 1)) // a pass's worth
	end := o.start + pm.step_period(p, o)
	n := o
	snapped :: proc(x, unit: f64) -> f64 { return math.round(x / unit) * unit }
	if ss.drag == .Start {
		start := clamp(snapped(o.start + d, unit), 0, end - min(unit, end - 0.25))
		start = max(start, 0)
		n.start = start
		n.length = 0 if end >= full - 1e-9 else end - start
	} else {
		e := clamp(snapped(end + d, unit), o.start + min(unit, full - o.start), full)
		if end + d >= full - unit / 2 do e = full
		n.length = 0 if e >= full - 1e-9 else e - o.start
	}
	if n != p.song.steps[i] do pm.set_step(m, i, n, "Step Start" if ss.drag == .Start else "Step Length")
	tip := fmt.ctprintf("Plays beats %g–%g of %s (%g of %g)", n.start + 1, n.start + pm.step_period(p, n) + 1, pm.sequence_name(p, int(n.slot)), pm.step_period(p, n), full)
	im.SetTooltip("%s", tip)
}

// Selects step `i`: alone, or with Shift the range from the last one
// clicked, or with Cmd one more (or less). Its settings show.
@(private)
select_step :: proc(ss: ^Song_State, i: int) {
	io := im.GetIO()
	if io.KeyShift && ss.anchor >= 0 {
		ss.sel = {}
		for k in min(ss.anchor, i) ..= max(ss.anchor, i) do ss.sel += {k}
	} else if io.KeyCtrl { // (Cmd on macOS)
		ss.sel ~= {i}
		ss.anchor = i
	} else {
		ss.sel = {i}
		ss.anchor = i
	}
	ss.step = i
}

// The steps the keys act on: the selection, else the step showing.
@(private)
song_targets :: proc(a: ^App) -> pm.Step_Set {
	ss := &a.song_ui
	if ss.sel != {} do return ss.sel
	if ss.step >= 0 && ss.step < a.m.project.song.count do return {ss.step}
	return {}
}

// Whether the Song tab's keys act on steps: it has the keyboard, with steps selected.
song_editing :: proc(a: ^App) -> bool {
	return a.song_ui.focused && song_targets(a) != {}
}

// Moves the selection (or step `from` alone, when it is not selected) to
// before step `to`.
@(private)
move_selection :: proc(a: ^App, from, to: int) {
	ss := &a.song_ui
	sel := ss.sel if from in ss.sel else pm.Step_Set{from}
	moved := pm.song_move_steps(&a.m, sel, to)
	if moved == {} do return
	ss.sel = moved
	for k in 0 ..< pm.SONG_STEPS do if k in moved {
		ss.step, ss.anchor = k, k
		break
	}
}

// Copies the selected steps (Cmd+C). False when none are.
song_copy :: proc(a: ^App) -> bool {
	ss := &a.song_ui
	sel := song_targets(a)
	if sel == {} do return false
	ss.clip_n = 0
	for st, i in a.m.project.song.steps[:a.m.project.song.count] do if i in sel {
		ss.clip[ss.clip_n] = st
		ss.clip_n += 1
	}
	ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Copied %d step%s", ss.clip_n, "" if ss.clip_n == 1 else "s"))
	return true
}

// Pastes the copied steps after the last selected one (or at the song's
// end); they become the selection.
song_paste :: proc(a: ^App, name := "Paste Steps") {
	ss := &a.song_ui
	if ss.clip_n == 0 do return
	sel := song_targets(a)
	at := a.m.project.song.count
	if sel != {} do for k := pm.SONG_STEPS - 1; k >= 0; k -= 1 do if k in sel {
		at = k + 1
		break
	}
	added := pm.song_insert_steps(&a.m, ss.clip[:ss.clip_n], at, name)
	if added == {} do return
	ss.sel, ss.step, ss.anchor = added, at, at
}

// Duplicates the selected steps after the last of them (Cmd+D).
song_duplicate :: proc(a: ^App) {
	if song_copy(a) do song_paste(a, "Duplicate Steps")
}

// Removes the selected steps (Delete, Backspace).
song_delete :: proc(a: ^App) {
	ss := &a.song_ui
	sel := song_targets(a)
	if sel == {} do return
	pm.song_remove_steps(&a.m, sel)
	first := 0
	for k in 0 ..< pm.SONG_STEPS do if k in sel {
		first = k
		break
	}
	ss.sel = {}
	ss.step = min(first, a.m.project.song.count - 1)
}

// The Song tab's keys, while it has the keyboard: Backspace removes the
// selected steps, Cmd+X cuts them, Cmd+A selects them all. (Delete,
// Cmd+C, Cmd+V and Cmd+D are the app's shortcuts, which come here while
// the tab has the keyboard.)
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
	if !io.KeyCtrl && !io.KeyAlt && im.IsKeyPressed(.Backspace, false) do song_delete(a)
}

// The song's steps in order: drag one to move it, a sequence from the
// left onto one to put it before, or onto the end to add it. The playing
// one runs a bar across; click one for its settings.
@(private)
draw_song_steps :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	t := ui.theme()
	playing, frac, _ := pm.song_progress(&m.engine)
	if p.song.count == 0 do im.TextDisabled("The song is empty: double-click or drag sequences from the left.")
	w: f32 = 120
	h: f32 = 76
	for i in 0 ..< p.song.count {
		st := p.song.steps[i]
		if i > 0 do ui.flow(w, 8)
		im.PushIDInt(i32(i))
		pos := im.GetCursorScreenPos()
		dl := im.GetWindowDrawList()
		clicked := im.InvisibleButton("##step", {w, h})
		ui.name(fmt.tprintf("song step %d", i + 1))
		item_menu(a, {kind = .Song_Step, index = i}, "##stepmenu")
		c := ui.rgb(pm.sequence_color(p, int(st.slot)))
		if st.mute do c = ui.mix(c, t.raised, 0.6)
		on := i == playing
		bg := ui.mix(t.raised, c, 0.55 if on else 0.22)
		if im.IsItemHovered() do bg = ui.lighten(bg, 0.06)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		im.DrawList_AddRectFilled(dl, {pos.x, pos.y}, {pos.x + 4, pos.y + h}, ui.col(c), 2)
		if i in ss.sel || i == ss.step do im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, ui.col(t.text), t.radius, 2 if i == ss.step else 1.5)
		label := pm.step_label(&st)
		name := pm.sequence_name(p, int(st.slot))
		im.DrawList_PushClipRect(dl, pos, {pos.x + w - 4, pos.y + h}, true)
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 6}, ui.col(t.text), fmt.ctprintf("%s", label if label != "" else name))
		part := "" if st.start == 0 && st.length == 0 else fmt.tprintf(" · part")
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 6 + im.GetTextLineHeightWithSpacing()}, ui.col(t.text_dim), fmt.ctprintf("×%d · %g beats%s", st.repeats, pm.step_period(p, st), part))
		extra := make([dynamic]string, context.temp_allocator)
		if st.mute do append(&extra, "muted")
		if st.transpose != 0 do append(&extra, fmt.tprintf("%+d st", st.transpose))
		if st.bpm > 0 do append(&extra, fmt.tprintf("%.0f BPM", st.bpm))
		if len(extra) > 0 do im.DrawList_AddText(dl, {pos.x + 10, pos.y + 6 + 2 * im.GetTextLineHeightWithSpacing()}, ui.col(t.warn), fmt.ctprintf("%s", strings.join(extra[:], " · ", context.temp_allocator)))
		im.DrawList_PopClipRect(dl)
		// Playing: how far through it.
		if on do im.DrawList_AddRectFilled(dl, {pos.x + 6, pos.y + h - 5}, {pos.x + 6 + (w - 12) * f32(frac), pos.y + h - 2}, ui.col(t.accent_text), 2)
		if clicked do select_step(ss, i)
		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) do pm.select_slot(m, int(st.slot))
		if im.BeginDragDropSource() {
			k := i32(i)
			im.SetDragDropPayload("SONG_STEP", &k, size_of(k))
			im.Text("%s", fmt.ctprintf("%s", name))
			im.EndDragDropSource()
		}
		if im.BeginDragDropTarget() {
			if pl := im.AcceptDragDropPayload("SONG_STEP"); pl != nil do move_selection(a, int((^i32)(pl.Data)^), i)
			if pl := im.AcceptDragDropPayload("SEQUENCE"); pl != nil do pm.song_insert(m, int((^i32)(pl.Data)^), i)
			im.EndDragDropTarget()
		}
		im.PopID()
	}
	// The end: drop a sequence here to add it.
	if p.song.count > 0 do ui.flow(w, 8)
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##songend", {w, h})
	ui.name("song end")
	dropping := im.GetDragDropPayload() != nil && im.IsItemHovered({.AllowWhenBlockedByActiveItem})
	im.DrawList_AddRect(im.GetWindowDrawList(), pos, {pos.x + w, pos.y + h}, ui.col(ui.with_alpha(t.accent if dropping else t.text, 0.7 if dropping else 0.2)), t.radius, 1.5)
	ts := im.CalcTextSize("+")
	im.DrawList_AddText(im.GetWindowDrawList(), {pos.x + (w - ts.x) / 2, pos.y + (h - ts.y) / 2}, ui.col(t.text_dim), "+")
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload("SEQUENCE"); pl != nil do pm.song_add(m, int((^i32)(pl.Data)^))
		if pl := im.AcceptDragDropPayload("SONG_STEP"); pl != nil do move_selection(a, int((^i32)(pl.Data)^), p.song.count)
		im.EndDragDropTarget()
	}
}

// Every sequence slot, to build the song from: its colour, name, length,
// own tempo and how many times the song plays it (the playing one lit).
// Click to edit it, double-click or + to add it at the song's end, drag it
// onto a step; right-click for its commands (its colour among them).
@(private)
draw_song_side :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	t := ui.theme()
	im.TextDisabled("Sequences")
	im.Separator()
	playing := -1
	if st, _, _ := pm.song_progress(&m.engine); st >= 0 do playing = int(p.song.steps[st].slot)
	dl := im.GetWindowDrawList()
	for k in 0 ..< pm.SLOTS {
		im.PushIDInt(i32(k))
		used := pm.slot_used(m, k)
		s := p.sequences[k]
		uses := 0
		for st in p.song.steps[:p.song.count] do if int(st.slot) == k do uses += int(st.repeats)
		w := im.GetContentRegionAvail().x
		h: f32 = 40 if used else 24
		pos := im.GetCursorScreenPos()
		btn := im.GetFrameHeight()
		clicked := im.InvisibleButton("##seq", {w - (btn + 4 if used else 0), h})
		ui.name(fmt.tprintf("song seq %d", k + 1))
		hovered := im.IsItemHovered()
		if hovered && im.IsMouseDoubleClicked(.Left) && used do pm.song_add(m, k)
		else if clicked do pm.select_slot(m, k)
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
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + (5 if used else (h - im.GetTextLineHeight()) / 2)}, ui.col(t.text if used else t.text_dim), fmt.ctprintf("%s", pm.sequence_name(p, k)))
		if used {
			info := fmt.tprintf("%d bar%s%s", s.bars, "" if s.bars == 1 else "s", fmt.tprintf(" · %.0f BPM", s.bpm) if s.bpm > 0 else "")
			if uses > 0 do info = fmt.tprintf("%s · ×%d", info, uses)
			im.DrawList_AddText(dl, {pos.x + 10, pos.y + 5 + im.GetTextLineHeightWithSpacing() - 2}, ui.col(t.text_dim), fmt.ctprintf("%s", info))
			im.SameLine(0, 4)
			im.SetCursorScreenPos({pos.x + w - btn, pos.y + (h - btn) / 2})
			if ui.icon_button(ui.ICON_PLUS, fmt.ctprintf("Add %s to the song's end", pm.sequence_name(p, k))) do pm.song_add(m, k)
		}
		im.SetCursorScreenPos({pos.x, pos.y + h + 3})
		im.Dummy({1, 0})
		im.PopID()
	}
}

// The selected step's settings: its sequence, how many times, which part
// of it (start and length, drawn over the sequence's length), muted,
// transposed, its own tempo, its name; duplicate and remove.
@(private)
draw_step_settings :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	ss := &a.song_ui
	t := ui.theme()
	im.TextDisabled("Step")
	im.Separator()
	i := ss.step
	if i < 0 || i >= p.song.count {
		im.TextDisabled("Click a step (or the timeline) for its settings.")
		return
	}
	st := p.song.steps[i]
	edit :: proc(m: ^pm.Model, i: int, st: pm.Song_Step, name: string, e: ui.Edit) {
		if e.changed do pm.set_step(m, i, st, name)
		if e.ended do app.seal(&m.history)
	}
	// Its sequence, its name (shown on the timeline).
	im.AlignTextToFramePadding()
	im.Text("%s", fmt.ctprintf("Step %d", i + 1))
	im.SameLine()
	im.SetNextItemWidth(-1)
	if ui.combo("##stepseq", fmt.ctprintf("%s", pm.sequence_name(p, int(st.slot)))) {
		for k in 0 ..< pm.SLOTS do if pm.slot_used(m, k) || k == int(st.slot) {
			if im.Selectable(fmt.ctprintf("%s###ss%d", pm.sequence_name(p, k), k), k == int(st.slot)) {
				n := st
				n.slot, n.start, n.length = u8(k), 0, 0
				pm.set_step(m, i, n, "Step Sequence")
				app.seal(&m.history)
			}
		}
		im.EndCombo()
	}
	if ss.label_for != i {
		ss.label_buf = st.label
		ss.label_for = i
	}
	im.SetNextItemWidth(-1)
	if im.InputTextWithHint("##steplabel", "Section name (Verse, Drop…)", cstring(&ss.label_buf[0]), len(ss.label_buf)) {
		n := st
		n.label = ss.label_buf
		pm.set_step(m, i, n, "Name Step")
	}
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	// How many times, which part, transposed: numbers to drag (a step each
	// four points; Shift: finer), scroll, or double-click and type.
	full := pm.seq_beats(p, p.sequences[st.slot])
	fw := (im.GetContentRegionAvail().x - 6) / 2
	n := st
	reps := f64(st.repeats)
	e := ui.number_drag("Repeats", &reps, 1, 16, 1, 1, "Repeats  ×%.0f", fw)
	n.repeats = u8(clamp(int(reps + 0.5), 1, 16))
	edit(m, i, n, "Step Repeats", e)
	im.SameLine(0, 6)
	start := st.start
	e = ui.number_drag("Start", &start, 0, full - 0.25, 1, 0.25, "Start  %.2f b", fw)
	n = st
	n.start = start
	if n.length > 0 do n.length = min(n.length, full - start) // its end stays inside
	edit(m, i, n, "Step Start", e)
	length := pm.step_period(p, st)
	e = ui.number_drag("Length", &length, 0.25, full - st.start, 1, 0.25, "Length  %.2f b", fw)
	n = st
	n.length = length
	if n.length >= full - st.start - 1e-9 do n.length = 0 // to the end
	edit(m, i, n, "Step Length", e)
	im.SameLine(0, 6)
	tr := f64(st.transpose)
	e = ui.number_drag("Transpose", &tr, -24, 24, 1, 1, "Transpose  %+.0f st", fw)
	n = st
	n.transpose = i8(clamp(int(math.round(tr)), -24, 24))
	edit(m, i, n, "Step Transpose", e)
	// The part over the whole sequence.
	pos := im.GetCursorScreenPos()
	bw := im.GetContentRegionAvail().x
	im.Dummy({bw, 10})
	ui.name("step part")
	dl := im.GetWindowDrawList()
	c := ui.rgb(pm.sequence_color(p, int(st.slot)))
	im.DrawList_AddRectFilled(dl, pos, {pos.x + bw, pos.y + 8}, ui.col(ui.PLOT_BG), 3)
	xa := pos.x + bw * f32(st.start / full)
	xb := pos.x + bw * f32((st.start + pm.step_period(p, st)) / full)
	im.DrawList_AddRectFilled(dl, {xa, pos.y + 1}, {xb, pos.y + 7}, ui.col(c), 3)
	// Muted; its own tempo.
	mute := st.mute
	if ui.toggle("Mute", &mute) {
		n = st
		n.mute = mute
		pm.set_step(m, i, n, "Mute Step")
		app.seal(&m.history)
	}
	im.SameLine(0, 12)
	own := st.bpm > 0
	if ui.toggle("Own tempo", &own) {
		n = st
		n.bpm = pm.step_tempo(p, i) if own else 0
		pm.set_step(m, i, n, "Step Tempo")
		app.seal(&m.history)
	}
	im.SameLine(0, 6)
	if own {
		bpm := st.bpm
		te := ui.number_drag("step tempo", &bpm, 40, 300, 1, 0.1, "%.1f BPM", max(im.GetContentRegionAvail().x, 60))
		n = st
		n.bpm = bpm
		edit(m, i, n, "Step Tempo", {changed = te.changed, ended = te.ended})
	} else {
		im.AlignTextToFramePadding()
		im.TextDisabled("%s", fmt.ctprintf("%.0f BPM", pm.step_tempo(p, i)))
	}
	beats := pm.step_period(p, st) * f64(max(st.repeats, 1))
	secs := beats * 60 / pm.step_tempo(p, i)
	if ui.icon_button(ui.ICON_COPY_PLUS, "Duplicate the step") do pm.song_add(m, int(st.slot), i, int(st.repeats))
	im.SameLine(0, 4)
	if ui.icon_button(ui.ICON_X, "Remove the step") {
		pm.song_remove(m, i)
		ss.step = min(i, p.song.count - 1)
	}
	im.SameLine(0, 10)
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", fmt.ctprintf("Plays %g beats, %s", beats, clock_text(secs)))
	_ = t
}
