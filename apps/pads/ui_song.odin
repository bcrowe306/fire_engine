package pads

import "core:fmt"

import "app:ui"
import pm "model"
import im "deps:imgui"

// The song: its steps in order (drag to move one), how many times each
// plays; song mode, looping, and when a sequence picked while playing
// takes over.
draw_song :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	p := &m.project
	t := ui.theme()

	mode := 1 if p.song_mode else 0
	if ui.segmented("song_mode", {"Pattern", "Song"}, &mode) {
		p.song_mode = mode == 1
		m.engine.seq_dirty = true
	}
	im.SameLine(0, 16)
	loop := p.song.loop
	if ui.toggle("Loop the song", &loop) {
		s := p.song
		s.loop = loop
		pm.set_song(m, "Loop Song", s)
	}
	im.SameLine(0, 16)
	im.SetNextItemWidth(170)
	if ui.combo("##switch", pm.SWITCH_NAMES[p.switch_at]) {
		for sw in pm.Switch_At do if im.Selectable(pm.SWITCH_NAMES[sw], sw == p.switch_at) do p.switch_at = sw
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("When a sequence picked while playing takes over")
	im.SameLine(0, 16)
	add :: ui.ICON_PLUS + "  Add sequence"
	if im.Button(fmt.ctprintf("%s %d", add, p.slot + 1)) do pm.song_add(m, p.slot)
	im.SameLine()
	im.SetNextItemWidth(170)
	if ui.combo("##merge", "Merge into this…") {
		for k in 0 ..< pm.SLOTS do if k != p.slot && pm.slot_used(m, k) {
			if im.Selectable(fmt.ctprintf("Sequence %d", k + 1)) do pm.merge_sequences(m, k, p.slot)
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Lay another sequence's notes over this one")
	im.Spacing()

	// The steps.
	playing := pm.song_step(&m.engine)
	if p.song.count == 0 {
		im.TextDisabled("The song is empty: add the current sequence, pick another, add it, and so on.")
		return
	}
	w: f32 = 104
	h: f32 = 64
	for i in 0 ..< p.song.count {
		st := p.song.steps[i]
		if i > 0 do ui.flow(w, 8)
		im.PushIDInt(i32(i))
		im.BeginGroup()
		pos := im.GetCursorScreenPos()
		dl := im.GetWindowDrawList()
		clicked := im.InvisibleButton("##step", {w, h})
		ui.name(fmt.tprintf("song step %d", i + 1))
		on := i == playing
		bg := t.accent if on else (t.hover if im.IsItemHovered() else t.raised)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		fg := t.accent_text if on else t.text
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 8}, ui.col(fg), fmt.ctprintf("Sequence %d", st.slot + 1))
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 8 + im.GetTextLineHeightWithSpacing()}, ui.col(t.accent_text if on else t.text_dim),
			fmt.ctprintf("×%d · %d bar%s", st.repeats, p.sequences[st.slot].bars, "" if p.sequences[st.slot].bars == 1 else "s"))
		if clicked do pm.select_slot(m, int(st.slot))
		// Drag a step onto another to move it there.
		if im.BeginDragDropSource() {
			k := i32(i)
			im.SetDragDropPayload("SONG_STEP", &k, size_of(k))
			im.Text("%s", fmt.ctprintf("Sequence %d", st.slot + 1))
			im.EndDragDropSource()
		}
		if im.BeginDragDropTarget() {
			if pl := im.AcceptDragDropPayload("SONG_STEP"); pl != nil do pm.song_move(m, int((^i32)(pl.Data)^), i)
			im.EndDragDropTarget()
		}
		// Repeats and removing.
		im.SetNextItemWidth(w - im.GetFrameHeight() - 4)
		reps := i32(st.repeats)
		if im.DragInt("##reps", &reps, 0.05, 1, 16, "×%d", {.ClampOnInput}) do pm.song_repeats(m, i, int(reps))
		im.SameLine(0, 4)
		if ui.icon_button(ui.ICON_X, "Remove from the song") do pm.song_remove(m, i)
		im.EndGroup()
		im.PopID()
	}
}
