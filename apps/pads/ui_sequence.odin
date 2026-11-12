package pads

import "core:fmt"
import "core:path/filepath"
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
	mode:     pm.Seq_Mode, // the tab: Notes (the default) or Automation (kept as you move around, saved with the project)
	lane:     int,     // the Notes tab's lane: 0 = velocity, 1 = chance, 2 = the selected pad's CC `cc`
	cc:       int,     // ... which controller (0..127)
	lane_hs:  [2]f32,  // the lane's height (dragged; [0] the Notes tab's, 0: its default)
	param:    pm.Lane_Param, // the automation the Automation tab shows ...
	auto_pad: int,     // ... of this pad (-1: the selected pad's)
	target:   pm.Auto_Target, // ... or this target (any parameter; track .None: the pad lane above)
	auto_tool: ui.Auto_Tool, // the Automation tab's tool
	hide_notes: bool,  // the Automation tab draws no notes under the curve
	learning: bool,    // Touch a control: the next knob or fader touched becomes the automation shown
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
	draw_mode_bar(a)
	t := ui.theme()

	// The rows: the bank's pads (the first at the bottom, as on the grid),
	// or, folded, every pad with notes; in the piano roll, the pad's pitches
	// (4 octaves each way; folded, the ones it plays).
	row_pad := make([dynamic]int, context.temp_allocator)
	row_pitch := make([dynamic]int, context.temp_allocator) // the piano roll's (else 0)
	slicer := st.piano && m.project.pads[st.piano_pad].kind == .Slicer // (its rows: its slices)
	if slicer {
		pad := st.piano_pad
		n := max(int(m.project.pads[pad].slicer.count), 1)
		for x in s.notes do if int(x.pad) == pad && int(x.pitch) >= n do n = min(int(x.pitch) + 1, pm.MAX_SLICER_SLICES) // (notes past the last slice: their rows too)
		for p in 0 ..< n {
			append(&row_pad, pad)
			append(&row_pitch, p)
		}
	} else if st.piano {
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
		if slicer {
			p := row_pitch[k]
			there := p < int(pad.slicer.count) || (p == 0 && pad.slicer.count == 0)
			rows[k] = {name = fmt.tprintf("Slice %d  %s", p + 1, ui.note_name(int(pad.slicer.base) + p)), color = ui.rgb(pad.color) if there else ui.mix(t.raised, t.text, 0.18)}
			continue
		}
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
		append(&notes, ui.Roll_Note{start = n.start, length = n.length, key = k, velocity = n.velocity, selected = is_selected(st, n), color = ui.rgb(m.project.pads[n.pad].color), muted = n.muted})
		append(&which, i)
	}
	length := pm.seq_beats(&m.project, s)
	beat, playing := pm.position(&m.engine)
	avail := im.GetContentRegionAvail()
	if st.mode == .Automation {
		snap := pm.grid_beats(st.grid) if !st.free && !ui.free_down() else 0
		draw_automation_view(a, s, notes[:], len(rows), ui.roll_rows_width(rows), length, snap)
		return
	}
	// The lane's height: dragged by the bar between it and the grid (each
	// kind keeps its own; automation starts with room to draw).
	li := 0
	if st.lane_hs[li] <= 0 do st.lane_hs[li] = 44 // (slim: drag its top for more)
	SPLIT :: 8
	lane_h := clamp(st.lane_hs[li], 32, max(avail.y * 0.6, 40))
	roll_h := max(avail.y - lane_h - SPLIT - im.GetStyle().ItemSpacing.y - 4, 4 * ROW_MIN)
	// As many rows as fit at ROW_MIN or taller; the wheel scrolls the rest.
	n_rows := max(len(rows), 1)
	keys := clamp(int(roll_h / ROW_MIN), min(4, n_rows), min(n_rows, 24 if st.piano else pm.PADS_PER_BANK))
	if st.view.keys != keys || st.view.key0 < 0 {
		st.view.keys = keys
		st.view.key0 = 0
		if st.piano && !st.fold && !slicer do st.view.key0 = 48 - keys / 2 // the pad's own pitch in the middle
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
	top := im.GetCursorScreenPos()
	e := ui.note_grid("seq", notes[:], rows, &st.view, snap, {avail.x, roll_h}, st.tool, beat if playing else -1, pm.bar_beats(&m.project), drop_type = "PADS_FILE")
	// The bar between the grid and the lane: drag it to give the lane more
	// room (or less).
	im.SetCursorScreenPos({top.x, top.y + roll_h})
	im.InvisibleButton("##lanesplit", {avail.x, SPLIT})
	ui.name("lane splitter")
	{
		hot := im.IsItemHovered() || im.IsItemActive()
		if hot do im.SetMouseCursor(.ResizeNS)
		if im.IsItemActive() do st.lane_hs[li] = clamp(lane_h - im.GetIO().MouseDelta.y, 32, max(avail.y * 0.6, 40))
		cy := top.y + roll_h + SPLIT / 2
		cx := top.x + ui.roll_rows_width(rows) + (avail.x - ui.roll_rows_width(rows)) / 2
		im.DrawList_AddLine(im.GetWindowDrawList(), {cx - 18, cy}, {cx + 18, cy}, ui.col(t.accent if hot else ui.with_alpha(t.text, 0.25)), 3)
		if im.IsItemHovered() && !im.IsItemActive() do im.SetTooltip("Drag: the lane's height")
	}
	before := raw_data(s.notes)
	editor_edits(a, e, notes[:], which[:], row_pad[:], row_pitch[:], length, snap)
	// A sample dropped on a row: onto that row's pad.
	if e.row_drop >= 0 && e.row_drop < len(row_pad) {
		pad := row_pad[e.row_drop]
		if pm.load_onto_pad(m, pad, e.dropped) == .None {
			a.selected = pad
			show_pad_chain(a, pad)
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Loaded %s onto %s", filepath.base(e.dropped), pm.pad_label(pad)))
		} else {
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", filepath.base(e.dropped)))
		}
	}
	note_keys(a, which[:], row_pad[:], row_pitch[:])
	// Notes changed this frame: the lane waits for the next (its notes are
	// this frame's, gone stale).
	if raw_data(pm.current_sequence(m).notes) != before {
		im.Dummy({avail.x, lane_h})
		return
	}
	// The lane, lined up under the grid: the notes' velocity or chance (its
	// name, where the rows' names are, picks which).
	bars := make([]ui.Lane_Bar, len(notes), context.temp_allocator)
	for n, k in notes {
		sn := s.notes[which[k]]
		bars[k] = {beat = n.start, value = sn.velocity if st.lane == 0 else sn.probability, color = ui.with_alpha(n.color, 0.3) if n.muted else n.color, selected = n.selected}
	}
	left := ui.roll_rows_width(rows)
	lane_at := im.GetCursorScreenPos()
	im.SetCursorScreenPos({lane_at.x + 2, lane_at.y + 2})
	ui.text_push(.Label)
	kind := "Velocity" if st.lane == 0 else ("Chance" if st.lane == 1 else fmt.tprintf("CC %d", st.cc))
	if im.Button(fmt.ctprintf("%s %s###lanekind", kind, ui.ICON_CHEVRON_DOWN), {left - 6, 0}) do im.OpenPopup("##lanekinds")
	ui.text_pop()
	ui.name("lane kind")
	if im.IsItemHovered() do im.SetTooltip("What the lane shows: the notes' velocity, their chance, or a MIDI CC of the selected pad")
	if im.BeginPopup("##lanekinds") {
		if im.Selectable("Velocity", st.lane == 0) do st.lane = 0
		if im.Selectable("Chance", st.lane == 1) do st.lane = 1
		im.Separator()
		// The selected pad's CC lanes in this sequence, then a new one.
		used: [128]bool
		for c in s.ccs do if int(c.pad) == a.selected do used[c.cc] = true
		for on, k in used do if on {
			if im.Selectable(fmt.ctprintf("CC %d%s###cc%d", k, cc_suffix(k), k), st.lane == 2 && st.cc == k) do st.lane, st.cc = 2, k
		}
		new_cc := im.BeginMenu(ui.ICON_PLUS + "  CC…")
		ui.name("new cc")
		if new_cc {
			for k in ([]int{1, 2, 7, 10, 11, 64, 71, 74}) {
				if im.MenuItem(fmt.ctprintf("CC %d%s###ncc%d", k, cc_suffix(k), k)) do st.lane, st.cc = 2, k
			}
			im.Separator()
			for hi in 0 ..< 8 do if im.BeginMenu(fmt.ctprintf("%d–%d###ccr%d", hi * 16, hi * 16 + 15, hi)) {
				for k in hi * 16 ..< hi * 16 + 16 do if im.MenuItem(fmt.ctprintf("CC %d%s###nccx%d", k, cc_suffix(k), k)) do st.lane, st.cc = 2, k
				im.EndMenu()
			}
			im.EndMenu()
		}
		im.EndPopup()
	}
	im.SetCursorScreenPos({lane_at.x + left, lane_at.y})
	if st.lane == 2 {
		draw_cc_lane(a, s, length, snap, {avail.x - left, lane_h})
		return
	}
	le := ui.value_lane("lane", bars, 0, length, {avail.x - left, lane_h}, 0)

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

// A controller's usual name after its number (" · Cutoff"; "" for most).
cc_suffix :: proc(cc: int) -> string {
	switch cc {
	case 1:  return " · Mod wheel"
	case 2:  return " · Breath"
	case 7:  return " · Volume"
	case 10: return " · Pan"
	case 11: return " · Expression"
	case 64: return " · Sustain"
	case 71: return " · Resonance"
	case 74: return " · Cutoff"
	}
	return ""
}

// The Notes tab's CC lane: the selected pad's controller `a.seq.cc`, in
// steps (0..127; each holds until the next), drawn and edited with the
// note tools (Select clicks one in and drags it, Draw draws, Erase
// sweeps). It goes to the pad's MIDI out and, on a plug-in pad, to its
// instrument.
draw_cc_lane :: proc(a: ^App, s: pm.Sequence, length, snap: f64, size: im.Vec2) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	pad, cc := a.selected, st.cc
	events, first := pm.cc_points(s, pad, cc)
	view := make([]ui.Auto_Lane_Point, len(events), context.temp_allocator)
	for c, i in events do view[i] = {beat = c.beat, value = f32(c.value) / 127}
	tool: ui.Auto_Tool
	switch st.tool {
	case .Select, .Move: tool = .Select
	case .Draw:          tool = .Draw
	case .Erase:         tool = .Erase
	}
	beat, playing := pm.position(&m.engine)
	t := ui.theme()
	color := ui.rgb(m.project.pads[pad].color) if pm.pad_used(&m.project, pad) else t.accent
	e := ui.auto_lane("cclane", view, 0, length, snap, size, tool, color, beat if playing else -1)
	value_of :: proc(n: f32) -> u8 { return u8(clamp(n * 127 + 0.5, 0, 127)) }
	if e.hover >= 0 && e.hover < len(events) do im.SetTooltip("%s", fmt.ctprintf("CC %d: %d", cc, events[e.hover].value))
	if e.add && e.at.beat <= length {
		pm.add_cc(m, slot, {beat = e.at.beat, pad = u8(pad), cc = u8(cc), value = value_of(e.at.value)})
		app.seal(&m.history)
	}
	if e.moving >= 0 && e.moving < len(events) {
		c := events[e.moving]
		c.beat, c.value = clamp(e.to.beat, 0, length), value_of(e.to.value)
		pm.set_cc(m, slot, first + e.moving, c)
	}
	if len(e.stroke) > 0 {
		out := make([dynamic]pm.Seq_Cc, 0, len(e.stroke), context.temp_allocator)
		b0, b1 := e.stroke[0].beat, e.stroke[len(e.stroke) - 1].beat
		for sp in e.stroke do if sp.beat <= length do append(&out, pm.Seq_Cc{beat = sp.beat, pad = u8(pad), cc = u8(cc), value = value_of(sp.value)})
		pm.replace_cc_range(m, slot, pad, cc, min(b0, b1), max(b0, b1), out[:])
	}
	if e.swept do pm.replace_cc_range(m, slot, pad, cc, e.swept_lo, e.swept_hi, nil)
	if e.released do app.seal(&m.history)
}

// The pad the Automation tab shows (the one chosen in its menu, else the
// selected pad).
auto_target_pad :: proc(a: ^App) -> int {
	return a.seq.auto_pad if a.seq.auto_pad >= 0 && a.seq.auto_pad < pm.PADS else a.selected
}

// The Automation tab's view: one automation (`auto_target_pad`'s
// `a.seq.param`) across the whole view, its value scale where the rows'
// names are, the notes grey beneath it for timing (unless hidden).
// Edited with the tab's tool: Select clicks a point in and drags one,
// Draw draws freehand (Shift: a straight line), Line drags a straight
// line, Curve bends a segment (Ctrl does with any tool), Erase sweeps.
// The point under the mouse says its time and value; a dot rides the
// curve where it plays.
draw_automation_view :: proc(a: ^App, s: pm.Sequence, notes: []ui.Roll_Note, n_rows: int, left: f32, length, snap: f64) {
	m := &a.m
	st := &a.seq
	t := ui.theme()
	slot := m.project.slot
	l := current_lane(a)
	pad := int(l.pad)
	points, first := pm.lane_points_of(s, l)
	view := make([]ui.Auto_Lane_Point, len(points), context.temp_allocator)
	for p, i in points do view[i] = {beat = p.beat, value = lane_norm(l, p.value), curve = p.curve}
	// The notes beneath: only the rows that have some, each a band of the
	// height (the first at the bottom, as in the grid).
	ghosts := make([dynamic]ui.Ghost_Note, 0, len(notes), context.temp_allocator)
	if !st.hide_notes && len(notes) > 0 {
		used := make([]int, max(n_rows, 1), context.temp_allocator) // each row's band (+1), 0: none
		for n in notes do if n.key >= 0 && n.key < len(used) do used[n.key] = 1
		bands := 0
		for &u in used do if u > 0 { bands += 1; u = bands }
		for n in notes {
			if n.key < 0 || n.key >= len(used) do continue
			k := f32(used[n.key] - 1)
			band := 1 / f32(bands)
			append(&ghosts, ui.Ghost_Note{beat = n.start, length = n.length, y0 = 1 - (k + 0.7) * band, y1 = 1 - (k + 0.3) * band})
		}
	}
	avail := im.GetContentRegionAvail()
	pos := im.GetCursorScreenPos()
	beat, playing := pm.position(&m.engine)
	dl := im.GetWindowDrawList()
	// The scale, where the rows' names are: the top, the middle and the
	// bottom of the range, in the parameter's units; the value now.
	ui.text_push(.Caption)
	h := avail.y
	for k in 0 ..= 2 {
		v := lane_denorm(l, 1 - f32(k) / 2)
		text := fmt.ctprintf("%s", lane_text(a, l, v))
		ts := im.CalcTextSize(text)
		y := pos.y + 4 + (h - 8) * f32(k) / 2 - ts.y / 2
		y = clamp(y, pos.y, pos.y + h - ts.y)
		im.DrawList_AddText(dl, {pos.x + left - ts.x - 8, y}, ui.col(t.text_dim), text)
	}
	ui.text_pop()
	if len(view) > 0 && playing {
		v := lane_denorm(l, ui.auto_lane_value(view, beat))
		im.DrawList_AddText(dl, {pos.x + 4, pos.y + h / 2 + 12}, ui.col(t.text), fmt.ctprintf("%s", lane_text(a, l, v)))
	}
	im.SetCursorScreenPos({pos.x + left, pos.y})
	color := t.accent
	if (l.target.track == .None || l.target.track == .Pad) && pm.pad_used(&m.project, pad) do color = ui.rgb(m.project.pads[pad].color)
	e := ui.auto_lane("auto", view, 0, length, snap, {avail.x - left, h}, st.auto_tool, color, beat if playing else -1, ghosts[:])
	if e.hover >= 0 && e.hover < len(points) && e.moving < 0 {
		p := points[e.hover]
		bar, bt, six := pm.position_of(&m.project, p.beat)
		im.SetTooltip("%s", fmt.ctprintf("bar %d.%d.%d · %s", bar, bt, six, lane_text(a, l, p.value)))
	}
	if e.add && e.at.beat <= length {
		pm.add_point(m, slot, {lane = l, beat = e.at.beat, value = lane_denorm(l, e.at.value)})
		app.seal(&m.history)
	}
	if e.moving >= 0 && e.moving < len(points) {
		p := points[e.moving]
		p.beat, p.value = clamp(e.to.beat, 0, length), lane_denorm(l, e.to.value)
		pm.set_point(m, slot, first + e.moving, p)
		bar, bt, six := pm.position_of(&m.project, p.beat)
		im.SetTooltip("%s", fmt.ctprintf("bar %d.%d.%d · %s", bar, bt, six, lane_text(a, l, p.value)))
	}
	if e.bend >= 0 && e.bend < len(points) {
		p := points[e.bend]
		p.curve = e.curve
		pm.set_point(m, slot, first + e.bend, p)
	}
	if len(e.stroke) > 0 {
		pts := make([dynamic]pm.Auto_Point, 0, len(e.stroke), context.temp_allocator)
		b0, b1 := e.stroke[0].beat, e.stroke[len(e.stroke) - 1].beat
		for sp in e.stroke do if sp.beat <= length do append(&pts, pm.Auto_Point{lane = l, beat = sp.beat, value = lane_denorm(l, sp.value)})
		pm.replace_lane_range_of(m, slot, l, min(b0, b1), max(b0, b1), pts[:])
	}
	if e.swept do pm.replace_lane_range_of(m, slot, l, e.swept_lo, e.swept_hi, nil)
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

// A value of lane parameter `p` as the scale and the tooltips show it, in
// its units.
lane_value_text :: proc(p: pm.Lane_Param, v: f32) -> string {
	#partial switch p {
	case .Volume, .Eq_Low, .Eq_Mid, .Eq_High: return fmt.tprintf("%+.1f dB", v)
	case .Pitch:     return fmt.tprintf("%+.0f st", v)
	case .Cutoff:    return fmt.tprintf("%.1f kHz", v / 1000) if v >= 1000 else fmt.tprintf("%.0f Hz", v)
	}
	return fmt.tprintf("%.0f%%", v)
}

// The tab bar of the Sequence view, and the tab's tools: Notes (the note
// tools, the view, snap and the grid, Quantize, input quantize) or
// Automation (which automation, its tools, snap and the grid, the notes
// beneath shown or not).
draw_mode_bar :: proc(a: ^App) {
	st := &a.seq
	mode := int(st.mode)
	if ui.segmented("seq mode", {"Notes", "Automation"}, &mode) do st.mode = pm.Seq_Mode(mode)
	ui.name("sequence mode")
	im.SameLine(0, 16)
	if st.mode == .Notes {
		draw_editor_tools(a)
		draw_grid_controls(a, quantize = true)
	} else {
		draw_automation_tools(a)
		draw_grid_controls(a, quantize = false)
		ui.flow(ui.button_width("Notes") + 24, 16)
		show := !st.hide_notes
		if ui.toggle("Notes##shownotes", &show) do st.hide_notes = !show
		ui.name("show notes")
		if im.IsItemHovered() do im.SetTooltip("The notes, grey under the curve, for timing")
	}
}

// The grid (where notes and points snap), and with `quantize` the
// sequence's Quantize and input quantize.
@(private)
draw_grid_controls :: proc(a: ^App, quantize: bool) {
	m := &a.m
	st := &a.seq
	ui.flow(84, 14)
	im.SetNextItemWidth(84)
	if ui.combo("##grid", pm.GRID_NAMES[st.grid]) {
		for g in pm.Grid do if im.Selectable(pm.GRID_NAMES[g], g == st.grid) {
			st.grid = g
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Grid: where notes and points snap, and what Quantize uses")
	if !quantize do return
	q :: ui.ICON_MAGNET + "  Quantize"
	ui.flow(ui.button_width(q))
	if im.Button(q) do pm.quantize_sequence(m, m.project.slot, st.grid)
	if im.IsItemHovered() do im.SetTooltip("Move the sequence's notes to the grid")
	// Input quantize: notes recorded from now on, moved as they come in.
	ui.flow(im.GetFrameHeight() * 2 + im.CalcTextSize("1/16T").x)
	draw_input_quantize(a)
}

// The Automation tab's tools: which automation (the menu: those in this
// sequence, then a new one), Select, Draw, Line, Curve, Erase, and snap.
// V, B, L, C and E pick the tools while the editor has the keyboard.
@(private)
draw_automation_tools :: proc(a: ^App) {
	m := &a.m
	st := &a.seq
	s := pm.current_sequence(m)
	cur := current_lane(a)
	im.SetNextItemWidth(260)
	if ui.combo("##autotarget", fmt.ctprintf("%s", lane_name(a, cur))) {
		// The automations this sequence has.
		lanes := make([dynamic]pm.Lane, context.temp_allocator)
		for pt in s.points {
			seen := false
			for x in lanes do if pm.lane_equal(x, pt.lane) do seen = true
			if !seen do append(&lanes, pt.lane)
		}
		for x, k in lanes {
			if im.Selectable(fmt.ctprintf("%s###at%d", lane_name(a, x), k), pm.lane_equal(x, cur)) {
				if x.target.track != .None do st.target = x.target
				else do st.target, st.auto_pad, st.param = {}, int(x.pad), x.param
			}
		}
		if len(lanes) == 0 do im.TextDisabled("No automation in this sequence yet")
		im.Separator()
		new_open := im.BeginMenu(ui.ICON_PLUS + "  New automation")
		ui.name("new automation")
		if new_open {
			new_automation_items(a)
			im.EndMenu()
		}
		if im.MenuItem(ui.ICON_POINTER + "  Touch a control…###learn") do st.learning = true
		ui.name("touch a control")
		im.EndCombo()
	}
	if st.learning {
		im.SameLine(0, 10)
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)ui.theme().warn, "Touch a knob or fader to automate it (Esc: cancel)")
		if im.IsKeyPressed(.Escape, false) do st.learning = false
	}
	ui.name("automation")
	tools := [5]struct { tool: ui.Auto_Tool, icon: string, tip: cstring }{
		{.Select, ui.ICON_MOUSE_POINTER_2, "Select (V): click to add a point, drag one to move it"},
		{.Draw, ui.ICON_PENCIL, "Draw (B): draw freehand (Shift: a straight line)"},
		{.Line, ui.ICON_SLASH, "Line (L): drag a straight line"},
		{.Curve, ui.ICON_SPLINE, "Curve (C): drag a segment up or down to bend it (Ctrl does with any tool)"},
		{.Erase, ui.ICON_ERASER, "Erase (E): sweep across points to remove them"},
	}
	im.SameLine(0, 14)
	for tl, k in tools {
		if k > 0 do im.SameLine(0, 2)
		if ui.icon_button(tl.icon, tl.tip, on = st.auto_tool == tl.tool) do st.auto_tool = tl.tool
	}
	im.SameLine(0, 10)
	if ui.icon_button(ui.ICON_MAGNET, "Snap: on (to the grid; hold " + ui.FREE_KEY + " to place freely)" if !st.free else "Snap: off (anywhere)", on = !st.free) do st.free = !st.free
	if st.focused && !im.GetIO().WantTextInput {
		if im.IsKeyPressed(.V, false) do st.auto_tool = .Select
		if im.IsKeyPressed(.B, false) do st.auto_tool = .Draw
		if im.IsKeyPressed(.L, false) do st.auto_tool = .Line
		if im.IsKeyPressed(.C, false) do st.auto_tool = .Curve
		if im.IsKeyPressed(.E, false) do st.auto_tool = .Erase
		if im.IsKeyPressed(.Escape, false) do st.auto_tool = .Select
	}
}

// The sequence's own settings, the same in both tabs: its name, length
// and ×2, swing, and clearing it.
draw_transport :: proc(a: ^App) {
	m := &a.m
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

	// Swing.
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

	// Clearing.
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

// The editor's note keys, while it has the keyboard: Backspace (and
// Delete) remove the selected notes, 0 mutes or unmutes them, Cmd+A
// selects every note shown, the arrows nudge the selection a grid step
// (Shift: a bar) or a row.
@(private)
note_keys :: proc(a: ^App, which, row_pad, row_pitch: []int) {
	st := &a.seq
	io := im.GetIO()
	if !st.focused || io.WantTextInput do return
	cmd := io.KeyCtrl // (Cmd on macOS: ImGui swaps them)
	if cmd && im.IsKeyPressed(.A, false) {
		s := pm.current_sequence(&a.m)
		clear(&st.sel)
		for i in which do append(&st.sel, s.notes[i])
		return
	}
	if len(st.sel) == 0 || cmd || io.KeyAlt do return
	if im.IsKeyPressed(.Backspace, false) {
		delete_selection(a)
		return
	}
	if im.IsKeyPressed(._0, false) || im.IsKeyPressed(.Keypad0, false) {
		mute_selection(a)
		return
	}
	beats, rows := 0.0, 0
	step := pm.bar_beats(&a.m.project) if io.KeyShift else pm.grid_beats(st.grid)
	if im.IsKeyPressed(.LeftArrow) do beats = -step
	if im.IsKeyPressed(.RightArrow) do beats = step
	if im.IsKeyPressed(.UpArrow) do rows = 1 // (rows count from the bottom)
	if im.IsKeyPressed(.DownArrow) do rows = -1
	if beats != 0 || rows != 0 do nudge_selection(a, beats, rows, row_pad, row_pitch)
}
