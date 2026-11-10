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
	selected: int,     // a note of the current sequence, or -1
	slot_was: int,
	bars_was: int,
}

// Transport and sequence settings above, the current bank's pads as rows of
// a note editor, and a lane for the notes' velocity or chance.
draw_sequence :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	s := pm.current_sequence(m)
	if st.slot_was != slot || st.bars_was != s.bars {
		st.selected = -1
		st.slot_was, st.bars_was = slot, s.bars
	}
	if st.selected >= len(s.notes) do st.selected = -1
	draw_transport(a)
	im.Spacing()

	// The editor: 16 rows (the bank's pads, the first at the top).
	rows := make([]ui.Roll_Row, pm.PADS_PER_BANK, context.temp_allocator)
	for k in 0 ..< pm.PADS_PER_BANK {
		index := a.bank * pm.PADS_PER_BANK + (pm.PADS_PER_BANK - 1 - k)
		pad := &m.project.pads[index]
		name := pm.pad_name(pad) if pad.sample != 0 else "—"
		t := ui.theme()
		rows[k] = {name = fmt.tprintf("%s  %s", pm.pad_label(index), name), color = ui.rgb(pad.color) if pad.sample != 0 else ui.mix(t.raised, t.text, 0.18)}
	}
	// Notes of this bank, and which note of the sequence each is.
	notes := make([dynamic]ui.Roll_Note, context.temp_allocator)
	which := make([dynamic]int, context.temp_allocator)
	for n, i in s.notes {
		if int(n.pad) / pm.PADS_PER_BANK != a.bank do continue
		k := pm.PADS_PER_BANK - 1 - int(n.pad) % pm.PADS_PER_BANK
		append(&notes, ui.Roll_Note{start = n.start, length = n.length, key = k, velocity = n.velocity, selected = i == st.selected,
			color = ui.rgb(m.project.pads[n.pad].color)})
		append(&which, i)
	}
	length := pm.seq_beats(s)
	beat, playing := pm.position(&m.engine)
	avail := im.GetContentRegionAvail()
	lane_h: f32 = 56
	roll_h := max(avail.y - lane_h - im.GetStyle().ItemSpacing.y - 4, 4 * ROW_MIN)
	// As many rows as fit at ROW_MIN or taller; the wheel scrolls the rest
	// (the bank's first pad at the top to begin with).
	keys := clamp(int(roll_h / ROW_MIN), 4, pm.PADS_PER_BANK)
	if st.view.keys != keys {
		st.view.keys = keys
		st.view.key0 = pm.PADS_PER_BANK - keys
	}
	st.view.key0 = clamp(st.view.key0, 0, pm.PADS_PER_BANK - keys)
	roll_h = f32(keys) * (roll_h / f32(keys))
	st.view.beat0, st.view.beats = 0, length
	snap := pm.grid_beats(st.grid)
	e := ui.piano_roll("seq", notes[:], &st.view, snap, {avail.x, roll_h}, beat if playing else -1, rows)
	bank_pad :: proc(a: ^App, key: int) -> u8 { return u8(a.bank * pm.PADS_PER_BANK + (pm.PADS_PER_BANK - 1 - key)) }
	if e.add && e.at_key >= 0 && e.at_key < pm.PADS_PER_BANK && e.at_beat < length {
		pad := bank_pad(a, e.at_key)
		pm.add_note(m, slot, {start = e.at_beat, length = snap, pad = pad, velocity = 0.8, probability = 1})
		// The note just added is selected (the sequence is sorted).
		for n, i in pm.current_sequence(m).notes do if n.start == e.at_beat && n.pad == pad do st.selected = i
		a.selected = int(pad)
	}
	if e.select >= 0 do st.selected = which[e.select]
	if e.delete >= 0 {
		pm.remove_notes(m, slot, {which[e.delete]})
		st.selected = -1
	}
	if (e.moving >= 0 || e.resizing >= 0) && e.released {
		i := which[e.moving if e.moving >= 0 else e.resizing]
		n := s.notes[i]
		n.start = clamp(e.to_start, 0, length - 1.0 / 64)
		n.length = e.to_length
		if e.to_key >= 0 && e.to_key < pm.PADS_PER_BANK do n.pad = bank_pad(a, e.to_key)
		pm.set_note(m, slot, i, n, .Notes, "Move Note" if e.moving >= 0 else "Resize Note")
		for x, k in pm.current_sequence(m).notes do if x == n do st.selected = k
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

// The selected pad's automation lane for `a.seq.param`: click to add a
// point, drag to move, right-click to delete.
draw_automation :: proc(a: ^App, s: pm.Sequence, length, snap: f64, size: im.Vec2, left: f32) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	pad := a.selected
	points, first := pm.lane_points(s, pad, st.param)
	lo, hi := pm.lane_range(st.param)
	norm :: proc(v, lo, hi: f32) -> f32 { return (v - lo) / (hi - lo) }
	view := make([]ui.Lane_Point, len(points), context.temp_allocator)
	for p, i in points do view[i] = {beat = p.beat, value = norm(p.value, lo, hi)}
	// The lane's label sits where the editor's row names are.
	pos := im.GetCursorScreenPos()
	im.DrawList_AddText(im.GetWindowDrawList(), {pos.x + 4, pos.y + 4}, ui.col(ui.theme().text_dim),
		fmt.ctprintf("%s %s", pm.pad_label(pad), pm.LANE_NAMES[st.param]))
	im.SetCursorScreenPos({pos.x + left, pos.y})
	e := ui.automation_lane("auto", view, 0, length, snap, {size.x - left, size.y}, ui.rgb(m.project.pads[pad].color))
	value_of :: proc(n, lo, hi: f32) -> f32 { return lo + clamp(n, 0, 1) * (hi - lo) }
	if e.add && e.at.beat <= length {
		pm.add_point(m, slot, {pad = u8(pad), param = st.param, beat = e.at.beat, value = value_of(e.at.value, lo, hi)})
	}
	if e.moving >= 0 && e.moving < len(points) {
		p := points[e.moving]
		p.beat, p.value = clamp(e.to.beat, 0, length), value_of(e.to.value, lo, hi)
		pm.set_point(m, slot, first + e.moving, p)
		if e.released do app.seal(&m.history)
	}
	if e.delete >= 0 && e.delete < len(points) do pm.remove_point(m, slot, first + e.delete)
}

// Play, stop, record and the click; the slot; its length, grid and swing.
draw_transport :: proc(a: ^App) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	s := pm.current_sequence(m)
	_, playing := pm.position(&m.engine)
	t := ui.theme()

	if ui.icon_button(ui.ICON_SQUARE if playing else ui.ICON_PLAY, "Stop (Space)" if playing else "Play (Space)", on = playing, color = ui.theme().ok) do toggle_play(a)
	im.SameLine()
	if ui.icon_button(ui.ICON_CIRCLE_DOT, "Record into the sequence (Cmd+R)", on = a.capture.armed, color = ui.rgb(0xf0555a)) do toggle_record(a)
	im.SameLine()
	if ui.icon_button(ui.ICON_METRONOME, "Metronome", on = m.engine.metronome) do m.engine.metronome = !m.engine.metronome

	// The slot, with the slots that hold notes marked.
	ui.flow(120, 20)
	im.SetNextItemWidth(120)
	if im.BeginCombo("##slot", fmt.ctprintf("Sequence %d", slot + 1)) {
		for k in 0 ..< pm.SLOTS {
			label := fmt.ctprintf("%s Sequence %d", ui.ICON_CIRCLE_DOT if pm.slot_used(m, k) else "   ", k + 1)
			if im.Selectable(label, k == slot) do pm.select_slot(m, k)
		}
		im.EndCombo()
	}
	if next, in_beats, ok := pm.pending_switch(&m.engine); ok {
		ui.flow(150)
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)t.warn, "%s", fmt.ctprintf("→ %d in %.1f beats", next + 1, max(in_beats, 0)))
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
	if im.BeginCombo("##grid", pm.GRID_NAMES[st.grid]) {
		for g in pm.Grid do if im.Selectable(pm.GRID_NAMES[g], g == st.grid) {
			st.grid = g
			a.capture.grid = g
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Grid: where notes snap, and what Quantize uses")
	q :: ui.ICON_MAGNET + "  Quantize"
	ui.flow(ui.button_width(q))
	if im.Button(q) do pm.quantize_sequence(m, slot, st.grid)
	ui.flow(ui.button_width("Live"))
	lq := a.capture.live_quantize
	if ui.toggle("Live", &lq) do a.capture.live_quantize = lq
	if im.IsItemHovered() do im.SetTooltip("Quantize while recording")
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
		if im.BeginCombo("##param", pm.LANE_NAMES[st.param]) {
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

// Arms or disarms recording; arming while stopped starts playing.
toggle_record :: proc(a: ^App) {
	on := !a.capture.armed
	pm.capture_arm(&a.m, &a.capture, on)
	if _, playing := pm.position(&a.m.engine); on && !playing do pm.play(&a.m.engine)
}

_ :: slice.contains
