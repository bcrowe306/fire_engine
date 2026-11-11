package pads

import "core:fmt"
import "core:slice"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// The shortest a row of the sequence editor gets, in points.
ROW_MIN :: 17

// The sequence editor's view state.
Seq_State :: struct {
	view:     ui.Roll_View,
	grid:     pm.Grid, // snap and quantize
	lane:     int,     // 0 = velocity, 1 = chance, 2 = automation
	param:    pm.Lane_Param, // the automation lane shown (of the selected pad)
	selected: int,     // the note the lanes edit (an index into the sequence), or -1
	sel:      [dynamic]pm.Seq_Note, // the selected notes (by value: they survive edits that keep them)
	slot_was: int,
	bars_was: int,
	tool:     ui.Grid_Tool,
	quiet:    bool, // the headphones off: clicking a row's name doesn't play it
	piano:    bool, // one pad's notes on a keyboard, not a row per pad
	piano_pad: int, // ... that pad
	fold:     bool, // only the rows that have notes
	focused:  bool, // the editor has the keyboard (its tool keys work)
	free:     bool, // snap off: notes and points go anywhere (Cmd held: the same, for a moment)
	editing:  bool, // a paint, a sweep or a drag is under way (sealed when the mouse lets go)
	paste_at: f64,  // where a paste from the menu goes (-1: the selection's bar)
	menu_target: Target, // what the open note or point menu is for
}

// Whether note `n` is selected.
@(private)
is_selected :: proc(st: ^Seq_State, n: pm.Seq_Note) -> bool {
	for x in st.sel do if x == n do return true
	return false
}

// The tool buttons, the headphones, the view (drums or one pad's piano
// roll) and folding: a row over the editor. V, B, E, M pick the tools
// (Escape: Select) while the editor has the keyboard.
@(private)
draw_editor_tools :: proc(a: ^App) {
	st := &a.seq
	tools := [4]struct { tool: ui.Grid_Tool, icon: string, tip: cstring }{
		{.Select, ui.ICON_MOUSE_POINTER_2, "Select (V): click, Shift-click, drag a box; drag notes to move them, their ends to resize"},
		{.Draw, ui.ICON_PENCIL, "Draw (B): click to add, drag along a row to paint, click a note to remove it"},
		{.Erase, ui.ICON_ERASER, "Erase (E): click or sweep across notes to remove them"},
		{.Move, ui.ICON_MOVE, "Move (M): drag the selection (Alt: a copy)"},
	}
	for tl, k in tools {
		if k > 0 do im.SameLine(0, 2)
		if ui.icon_button(tl.icon, tl.tip, on = st.tool == tl.tool) do st.tool = tl.tool
	}
	im.SameLine(0, 10)
	if ui.icon_button(ui.ICON_MAGNET, "Snap: on (to the grid; hold " + ui.FREE_KEY + " to place freely)" if !st.free else "Snap: off (anywhere)", on = !st.free) do st.free = !st.free
	im.SameLine(0, 14)
	if ui.icon_button(ui.ICON_HEADPHONES, "Hear a row's pad when you click its name: on" if !st.quiet else "Hear a row's pad when you click its name: off", on = !st.quiet) do st.quiet = !st.quiet
	im.SameLine(0, 14)
	mode := 1 if st.piano else 0
	if ui.segmented("roll_mode", {"Drums", fmt.tprintf("Piano roll: %s", pm.pad_label(st.piano_pad))}, &mode) {
		st.piano = mode == 1
		if st.piano do st.piano_pad = a.selected
		st.view.key0 = -1 // placed again
	}
	im.SameLine(0, 6)
	if ui.icon_button(ui.ICON_FOLD_VERTICAL, "Fold: only the rows that have notes" if !st.fold else "Fold: on (only the rows that have notes)", on = st.fold) {
		st.fold = !st.fold
		st.view.key0 = -1
	}
	// The tool keys, while the editor has the keyboard.
	if st.focused && !im.GetIO().WantTextInput {
		if im.IsKeyPressed(.V, false) do st.tool = .Select
		if im.IsKeyPressed(.B, false) do st.tool = .Draw
		if im.IsKeyPressed(.E, false) do st.tool = .Erase
		if im.IsKeyPressed(.M, false) do st.tool = .Move
		if im.IsKeyPressed(.Escape, false) {
			st.tool = .Select
			clear(&st.sel)
		}
	}
}

// Transport and sequence settings above; the editor's tools; the current
// bank's pads as rows of notes (or one pad's piano roll; folded, only the
// rows that have notes), and a lane for the notes' velocity or chance.
draw_sequence :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	s := pm.current_sequence(m)
	if st.slot_was != slot || st.bars_was != s.bars {
		st.selected = -1
		clear(&st.sel)
		st.slot_was, st.bars_was = slot, s.bars
	}
	if st.selected >= len(s.notes) do st.selected = -1
	// Notes selected that are no longer there are let go.
	for k := len(st.sel) - 1; k >= 0; k -= 1 {
		found := false
		for n in s.notes do if n == st.sel[k] do found = true
		if !found do ordered_remove(&st.sel, k)
	}
	st.focused = im.IsWindowFocused({.RootWindow, .ChildWindows})
	draw_transport(a)
	im.Spacing()
	draw_editor_tools(a)
	t := ui.theme()

	// The rows: the bank's pads (the first at the bottom, as on the grid),
	// or, folded, every pad with notes; in the piano roll, the pad's pitches
	// (4 octaves each way; folded, the ones it plays).
	row_pad := make([dynamic]int, context.temp_allocator)
	row_pitch := make([dynamic]int, context.temp_allocator) // the piano roll's (else 0)
	if st.piano {
		pad := st.piano_pad
		used: [97]bool
		for n in s.notes do if int(n.pad) == pad && int(n.pitch) >= -48 && int(n.pitch) <= 48 do used[int(n.pitch) + 48] = true
		for p in -48 ..= 48 do if !st.fold || used[p + 48] {
			append(&row_pad, pad)
			append(&row_pitch, p)
		}
	} else if st.fold {
		used: [pm.PADS]bool
		for n in s.notes do used[n.pad] = true
		for i in 0 ..< pm.PADS do if used[i] {
			append(&row_pad, i)
			append(&row_pitch, 0)
		}
	} else {
		for k in 0 ..< pm.PADS_PER_BANK {
			append(&row_pad, a.bank * pm.PADS_PER_BANK + k)
			append(&row_pitch, 0)
		}
	}
	rows := make([]ui.Roll_Row, len(row_pad), context.temp_allocator)
	for r, k in row_pad {
		pad := &m.project.pads[r]
		if st.piano {
			p := row_pitch[k]
			key := 60 + p
			black := (key %% 12) in bit_set[0 ..< 12]{1, 3, 6, 8, 10}
			rows[k] = {name = fmt.tprintf("%s%s", ui.note_name(key), "  ·" if p == 0 else ""), color = ui.rgb(pad.color) if p == 0 else (ui.mix(t.raised, t.text, 0.15) if black else ui.mix(t.raised, t.text, 0.45))}
			continue
		}
		used := pm.pad_used(&m.project, r)
		rows[k] = {name = fmt.tprintf("%s  %s", pm.pad_label(r), pm.pad_name(pad) if used else "—"), color = ui.rgb(pad.color) if used else ui.mix(t.raised, t.text, 0.18)}
	}
	row_of :: proc(row_pad, row_pitch: []int, piano: bool, n: pm.Seq_Note) -> int {
		for r, k in row_pad do if r == int(n.pad) && (!piano || row_pitch[k] == int(n.pitch)) do return k
		return -1
	}
	// Notes on those rows, and which note of the sequence each is.
	notes := make([dynamic]ui.Roll_Note, context.temp_allocator)
	which := make([dynamic]int, context.temp_allocator)
	for n, i in s.notes {
		k := row_of(row_pad[:], row_pitch[:], st.piano, n)
		if k < 0 do continue
		append(&notes, ui.Roll_Note{start = n.start, length = n.length, key = k, velocity = n.velocity, selected = is_selected(st, n), color = ui.rgb(m.project.pads[n.pad].color)})
		append(&which, i)
	}
	length := pm.seq_beats(&m.project, s)
	beat, playing := pm.position(&m.engine)
	avail := im.GetContentRegionAvail()
	lane_h: f32 = 120 if st.lane == 2 else 56 // automation gets room to draw
	roll_h := max(avail.y - lane_h - im.GetStyle().ItemSpacing.y - 4, 4 * ROW_MIN)
	// As many rows as fit at ROW_MIN or taller; the wheel scrolls the rest.
	n_rows := max(len(rows), 1)
	keys := clamp(int(roll_h / ROW_MIN), min(4, n_rows), min(n_rows, 24 if st.piano else pm.PADS_PER_BANK))
	if st.view.keys != keys || st.view.key0 < 0 {
		st.view.keys = keys
		st.view.key0 = 0
		if st.piano && !st.fold do st.view.key0 = 48 - keys / 2 // the pad's own pitch in the middle
	}
	st.view.key0 = clamp(st.view.key0, 0, max(n_rows - keys, 0))
	roll_h = f32(keys) * (roll_h / f32(keys))
	st.view.beat0, st.view.beats = 0, length
	// Snap: off, or Cmd held while editing, notes go anywhere.
	snap := pm.grid_beats(st.grid) if !st.free && !ui.free_down() else 0
	if len(rows) == 0 {
		im.TextDisabled("No notes to fold to: draw some, or turn Fold off.")
		return
	}
	e := ui.note_grid("seq", notes[:], rows, &st.view, snap, {avail.x, roll_h}, st.tool, beat if playing else -1, pm.bar_beats(&m.project))
	before := raw_data(s.notes)
	editor_edits(a, e, notes[:], which[:], row_pad[:], row_pitch[:], length, snap)
	// Notes changed this frame: the lane waits for the next (its notes are
	// this frame's, gone stale).
	if raw_data(pm.current_sequence(m).notes) != before {
		im.Dummy({avail.x, lane_h})
		return
	}
	// The lane, lined up under the grid: velocity, chance, or the selected
	// pad's automation.
	if st.lane == 2 {
		draw_automation(a, s, length, snap, {avail.x, lane_h}, ui.roll_rows_width(rows))
		return
	}
	bars := make([]ui.Lane_Bar, len(notes), context.temp_allocator)
	for n, k in notes {
		sn := s.notes[which[k]]
		bars[k] = {beat = n.start, value = sn.velocity if st.lane == 0 else sn.probability, color = n.color, selected = n.selected}
	}
	le := ui.value_lane("lane", bars, 0, length, {avail.x, lane_h}, ui.roll_rows_width(rows))

	if le.index >= 0 && le.changed {
		i := which[le.index]
		n := s.notes[i]
		if st.lane == 0 {
			n.velocity = le.value
			pm.set_note(m, slot, i, n, .Velocity, "Set Velocity")
		} else {
			n.probability = max(le.value, 0.01)
			pm.set_note(m, slot, i, n, .Probability, "Set Chance")
		}
		st.selected = i
	}
	if le.ended do app.seal(&m.history)
}

// The selected pad's automation lane for `a.seq.param`, edited with the
// editor's tool: Select clicks a point in and drags one, Draw draws
// freehand (Shift: a straight line), Erase sweeps; Ctrl-drag bends a
// segment. A dot rides it where it plays.
draw_automation :: proc(a: ^App, s: pm.Sequence, length, snap: f64, size: im.Vec2, left: f32) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	pad := a.selected
	points, first := pm.lane_points(s, pad, st.param)
	lo, hi := pm.lane_range(st.param)
	norm :: proc(v, lo, hi: f32) -> f32 { return (v - lo) / (hi - lo) }
	value_of :: proc(n, lo, hi: f32) -> f32 { return lo + clamp(n, 0, 1) * (hi - lo) }
	view := make([]ui.Auto_Lane_Point, len(points), context.temp_allocator)
	for p, i in points do view[i] = {beat = p.beat, value = norm(p.value, lo, hi), curve = p.curve}
	// The lane's label (and its value now) where the editor's row names are.
	pos := im.GetCursorScreenPos()
	beat, playing := pm.position(&m.engine)
	dl := im.GetWindowDrawList()
	im.DrawList_AddText(dl, {pos.x + 4, pos.y + 4}, ui.col(ui.theme().text_dim), fmt.ctprintf("%s %s", pm.pad_label(pad), pm.LANE_NAMES[st.param]))
	if len(view) > 0 && playing {
		v := value_of(ui.auto_lane_value(view, beat), lo, hi)
		im.DrawList_AddText(dl, {pos.x + 4, pos.y + 4 + im.GetTextLineHeightWithSpacing()}, ui.col(ui.theme().text), fmt.ctprintf("%.1f", v))
	}
	im.SetCursorScreenPos({pos.x + left, pos.y})
	e := ui.auto_lane("auto", view, 0, length, snap, {size.x - left, size.y}, st.tool, ui.rgb(m.project.pads[pad].color), beat if playing else -1)
	if e.add && e.at.beat <= length {
		pm.add_point(m, slot, {pad = u8(pad), param = st.param, beat = e.at.beat, value = value_of(e.at.value, lo, hi)})
		app.seal(&m.history)
	}
	if e.moving >= 0 && e.moving < len(points) {
		p := points[e.moving]
		p.beat, p.value = clamp(e.to.beat, 0, length), value_of(e.to.value, lo, hi)
		pm.set_point(m, slot, first + e.moving, p)
	}
	if e.bend >= 0 && e.bend < len(points) {
		p := points[e.bend]
		p.curve = e.curve
		pm.set_point(m, slot, first + e.bend, p)
	}
	if len(e.stroke) > 0 {
		pts := make([dynamic]pm.Auto_Point, 0, len(e.stroke), context.temp_allocator)
		b0, b1 := e.stroke[0].beat, e.stroke[len(e.stroke) - 1].beat
		for sp in e.stroke do if sp.beat <= length do append(&pts, pm.Auto_Point{pad = u8(pad), param = st.param, beat = sp.beat, value = value_of(sp.value, lo, hi)})
		pm.replace_lane_range(m, slot, pad, st.param, min(b0, b1), max(b0, b1), pts[:])
	}
	if e.swept do pm.replace_lane_range(m, slot, pad, st.param, e.swept_lo, e.swept_hi, nil)
	if e.released do app.seal(&m.history)
	if e.menu >= 0 && e.menu < len(points) {
		st.menu_target = {kind = .Point, slot = slot, index = first + e.menu}
		im.OpenPopup("##pointmenu")
	}
	if im.BeginPopup("##pointmenu") {
		command_items(a, st.menu_target)
		im.EndPopup()
	}
}

// Play, stop, record and the click; the slot; its length, grid and swing.
draw_transport :: proc(a: ^App) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	s := pm.current_sequence(m)
	t := ui.theme()
	// (Play, record, the metronome and the sequence picked are on the
	// transport toolbar.)
	sequence_head(a)
	if next, in_beats, ok := pm.pending_switch(&m.engine); ok {
		ui.flow(150)
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)t.warn, "%s", fmt.ctprintf("→ %s in %.1f beats", pm.sequence_name(&m.project, next), max(in_beats, 0)))
	}
	if m.project.song_mode {
		ui.flow(80)
		im.AlignTextToFramePadding()
		im.TextDisabled("Song mode")
	}
	ui.flow(96)
	im.SetNextItemWidth(96)
	bars := i32(s.bars)
	if im.DragInt("##bars", &bars, 0.1, 1, pm.MAX_BARS, "%d bars" if bars > 1 else "%d bar", {.ClampOnInput}) do pm.set_bars(m, slot, int(bars))
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	ui.flow(ui.button_width("×2"))
	if im.Button("×2") do pm.double_sequence(m, slot)
	if im.IsItemHovered() do im.SetTooltip("Double the sequence (its notes repeat)")

	// Grid (snap), quantize, swing.
	ui.flow(84, 20)
	im.SetNextItemWidth(84)
	if ui.combo("##grid", pm.GRID_NAMES[st.grid]) {
		for g in pm.Grid do if im.Selectable(pm.GRID_NAMES[g], g == st.grid) {
			st.grid = g
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Grid: where notes snap, and what Quantize uses")
	q :: ui.ICON_MAGNET + "  Quantize"
	ui.flow(ui.button_width(q))
	if im.Button(q) do pm.quantize_sequence(m, slot, st.grid)
	ui.flow(120, 20)
	im.SetNextItemWidth(120)
	sw := s.swing * 100
	if im.DragFloat("##swing", &sw, 0.5, 0, 100, "Swing %.0f%%", {.ClampOnInput}) do pm.set_swing(m, slot, sw / 100, s.swing_grid)
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	ui.flow(ui.button_width("1/16") * 2)
	sg := 0 if s.swing_grid == .Eighth else 1
	if ui.segmented("swing_grid", {"1/8", "1/16"}, &sg) {
		pm.set_swing(m, slot, s.swing, .Eighth if sg == 0 else .Sixteenth)
		app.seal(&m.history)
	}

	// The lane's value, and clearing.
	ui.flow(ui.button_width("Velocity") + ui.button_width("Chance") + ui.button_width("Automation"), 20)
	ui.segmented("lane", {"Velocity", "Chance", "Automation"}, &st.lane)
	if st.lane == 2 {
		ui.flow(110)
		im.SetNextItemWidth(110)
		if ui.combo("##param", pm.LANE_NAMES[st.param]) {
			for lp in pm.Lane_Param do if im.Selectable(pm.LANE_NAMES[lp], lp == st.param) do st.param = lp
			im.EndCombo()
		}
	}
	ui.flow(im.GetFrameHeight())
	if ui.icon_button(ui.ICON_TRASH_2, "Clear the sequence") do pm.clear_sequence(m, slot)
	_ = t
}

// Starts or stops the sequencer (stopping also stops recording).
toggle_play :: proc(a: ^App) {
	if _, playing := pm.position(&a.m.engine); playing {
		pm.stop(&a.m.engine)
		pm.capture_arm(&a.m, &a.capture, false)
	} else {
		pm.play(&a.m.engine)
	}
}

// Arms or disarms recording; arming while stopped starts playing (after
// the count-in).
toggle_record :: proc(a: ^App) {
	on := !a.capture.armed
	pm.capture_arm(&a.m, &a.capture, on)
	// From a stop: the count-in first (if the transport has one).
	if _, playing := pm.position(&a.m.engine); on && !playing do pm.play(&a.m.engine, count_in = true)
}

_ :: slice.contains

// What the editor's tools did, as edits: rows clicked (the pad selected,
// its notes, heard), notes added, painted, erased, selected, moved, copied,
// resized; right-clicks open menus. A paint or a sweep is one undo step.
@(private)
editor_edits :: proc(a: ^App, e: ui.Grid_Edit, notes: []ui.Roll_Note, which: []int, row_pad, row_pitch: []int, length, snap: f64) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	s := pm.current_sequence(m)
	note_at :: proc(s: pm.Sequence, which: []int, k: int) -> pm.Seq_Note { return s.notes[which[k]] }
	pick_pad :: proc(a: ^App, pad: int) {
		if a.selected != pad do a.selected = pad
		show_pad_chain(a, pad)
	}
	// A row's name: its pad selected, its notes, heard.
	if e.row_click >= 0 && e.row_click < len(row_pad) {
		pad, pitch := row_pad[e.row_click], row_pitch[e.row_click]
		pick_pad(a, pad)
		clear(&st.sel)
		for n in s.notes do if int(n.pad) == pad && (!st.piano || int(n.pitch) == pitch) do append(&st.sel, n)
		if !st.quiet && pm.pad_used(&m.project, pad) do audition(a, pad, pitch if st.piano else 0)
		if e.row_double && !st.piano {
			st.piano, st.piano_pad = true, pad
			st.view.key0 = -1
		}
	}
	if e.row_menu >= 0 && e.row_menu < len(row_pad) {
		st.menu_target = pad_target(row_pad[e.row_menu])
		im.OpenPopup("##rowmenu")
	}
	if im.BeginPopup("##rowmenu") {
		command_items(a, st.menu_target)
		im.EndPopup()
	}
	// Adding (a click, or painting along a row).
	if e.add && e.at_row >= 0 && e.at_row < len(row_pad) && e.at_beat < length {
		n := pm.Seq_Note{start = e.at_beat, length = snap, pad = u8(row_pad[e.at_row]), pitch = i8(row_pitch[e.at_row]), velocity = 0.8, probability = 1}
		pm.replace_notes(m, slot, nil, {n}, true, .Paint, "Add Note") // a paint's notes: one step
		clear(&st.sel)
		append(&st.sel, n)
		pick_pad(a, int(n.pad))
		st.editing = true
	}
	if e.erase >= 0 && e.erase < len(which) {
		pm.remove_note_values(m, slot, {note_at(s, which, e.erase)}, .Erase, "Erase Notes")
		st.editing = true
	}
	// Selecting.
	if e.select >= 0 && e.select < len(which) {
		n := note_at(s, which, e.select)
		if e.select_add {
			if is_selected(st, n) {
				for x, k in st.sel do if x == n {
					ordered_remove(&st.sel, k)
					break
				}
			} else do append(&st.sel, n)
		} else {
			clear(&st.sel)
			append(&st.sel, n)
		}
		st.selected = which[e.select]
		pick_pad(a, int(n.pad))
	}
	if e.select_none do clear(&st.sel)
	if e.box {
		if !e.box_add do clear(&st.sel)
		for rn, k in notes {
			n := note_at(s, which, k)
			if rn.key < e.box_row0 || rn.key > e.box_row1 || rn.start + rn.length <= e.box_beat0 || rn.start >= e.box_beat1 do continue
			if !is_selected(st, n) do append(&st.sel, n)
		}
	}
	// Moving, copying, resizing: when the drag ends.
	if e.released && len(st.sel) > 0 {
		moved := make([dynamic]pm.Seq_Note, 0, len(st.sel), context.temp_allocator)
		for n in st.sel {
			x := n
			if e.moving {
				x.start += e.move_beats
				k := row_of_note(row_pad, row_pitch, st.piano, n) + e.move_rows
				if k < 0 || k >= len(row_pad) do continue
				x.pad = u8(row_pad[k])
				if st.piano do x.pitch = i8(row_pitch[k])
			}
			if e.resizing do x.length = max(x.length + e.resize_beats, snap if snap > 0 else 1.0 / 64)
			append(&moved, x)
		}
		if e.moving && (e.move_beats != 0 || e.move_rows != 0) || e.resizing && e.resize_beats != 0 {
			name := "Resize Notes" if e.resizing else ("Copy Notes" if e.copy else "Move Notes")
			landed := pm.replace_notes(m, slot, st.sel[:], moved[:], e.moving && e.copy, .Notes, name)
			clear(&st.sel)
			append(&st.sel, ..landed)
			app.seal(&m.history)
		}
	}
	// A paint or a sweep ends: one undo step.
	if st.editing && !im.IsMouseDown(.Left) {
		app.seal(&m.history)
		st.editing = false
	}
	// Right-click: a note's menu (its own commands, and the selection's), or
	// the empty grid's (paste here).
	if e.menu >= 0 && e.menu < len(which) {
		n := note_at(s, which, e.menu)
		if !is_selected(st, n) {
			clear(&st.sel)
			append(&st.sel, n)
		}
		st.menu_target = note_target(slot, which[e.menu])
		im.OpenPopup("##notemenu")
	} else if e.menu_empty {
		st.paste_at = e.at_beat
		st.menu_target = {kind = .Part}
		im.OpenPopup("##notemenu")
	}
	if im.BeginPopup("##notemenu") {
		t := st.menu_target
		if t.kind == .Note && t.index < len(m.project.sequences[t.slot].notes) {
			command_items(a, t)
			if len(st.sel) > 1 {
				im.Separator()
				command_items(a, {kind = .Part})
			}
		} else if t.kind == .Part {
			command_items(a, t)
		}
		im.EndPopup()
	} else {
		st.paste_at = -1
	}
}

// Which row note `n` is on.
@(private)
row_of_note :: proc(row_pad, row_pitch: []int, piano: bool, n: pm.Seq_Note) -> int {
	for r, k in row_pad do if r == int(n.pad) && (!piano || row_pitch[k] == int(n.pitch)) do return k
	return -1
}

// Plays pad `pad` (at `pitch` semitones from its own) for a moment.
audition :: proc(a: ^App, pad, pitch: int) {
	if pitch == 0 {
		pm.hit(&a.m.engine, pad, true)
		a.release_at[pad] = 12
	} else {
		pm.hit(&a.m.engine, pad, true, pitch = i8(pitch), keyboard = true)
		a.audition_off = {pad, pitch, 12}
	}
}
