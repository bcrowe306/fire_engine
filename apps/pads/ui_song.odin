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

	mode := 1 if p.song_mode else 0
	if ui.segmented("song_mode", {"Pattern", "Song"}, &mode) {
		p.song_mode = mode == 1
		m.engine.seq_dirty = true
	}
	im.SameLine(0, 16)
	im.SetNextItemWidth(170)
	if ui.combo("##switch", pm.SWITCH_NAMES[p.switch_at]) {
		for sw in pm.Switch_At do if im.Selectable(pm.SWITCH_NAMES[sw], sw == p.switch_at) do p.switch_at = sw
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("When a sequence picked while playing takes over")
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
	im.Spacing()

	// The steps on the left, the sequences to add on the right.
	avail := im.GetContentRegionAvail()
	side_w: f32 = 240
	if im.BeginChild("##songsteps", {max(avail.x - side_w - 8, 160), avail.y}) do draw_song_steps(a)
	im.EndChild()
	im.SameLine(0, 8)
	if im.BeginChild("##songside", {side_w, avail.y}) do draw_song_side(a)
	im.EndChild()
}

// The song's steps in order: drag one to move it, a sequence from the
// sidebar onto one to put it before, or onto the end to add it.
@(private)
draw_song_steps :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	t := ui.theme()
	// The steps.
	playing := pm.song_step(&m.engine)
	if p.song.count == 0 {
		im.TextDisabled("The song is empty: click or drag sequences from the right, or add the current one.")
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
		item_menu(a, {kind = .Song_Step, index = i}, "##stepmenu")
		on := i == playing
		bg := t.accent if on else (t.hover if im.IsItemHovered() else t.raised)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		fg := t.accent_text if on else t.text
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 8}, ui.col(fg), fmt.ctprintf("%s", pm.sequence_name(p, int(st.slot))))
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 8 + im.GetTextLineHeightWithSpacing()}, ui.col(t.accent_text if on else t.text_dim),
			fmt.ctprintf("×%d · %d bar%s", st.repeats, p.sequences[st.slot].bars, "" if p.sequences[st.slot].bars == 1 else "s"))
		if clicked do pm.select_slot(m, int(st.slot))
		// Drag a step onto another to move it there.
		if im.BeginDragDropSource() {
			k := i32(i)
			im.SetDragDropPayload("SONG_STEP", &k, size_of(k))
			im.Text("%s", fmt.ctprintf("%s", pm.sequence_name(p, int(st.slot))))
			im.EndDragDropSource()
		}
		if im.BeginDragDropTarget() {
			if pl := im.AcceptDragDropPayload("SONG_STEP"); pl != nil do pm.song_move(m, int((^i32)(pl.Data)^), i)
			if pl := im.AcceptDragDropPayload("SEQUENCE"); pl != nil do pm.song_insert(m, int((^i32)(pl.Data)^), i) // before this step
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
		im.EndDragDropTarget()
	}
}

// The sequences in use, to build the song from: each with its length, its
// own tempo and how many times the song plays it (the playing one lit).
// Click to edit it, double-click or + to add it to the song's end, drag it
// onto a step to put it there; right-click for its commands.
@(private)
draw_song_side :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	t := ui.theme()
	im.TextDisabled("Sequences")
	im.Separator()
	playing := -1
	if st := pm.song_step(&m.engine); st >= 0 do playing = int(p.song.steps[st].slot)
	dl := im.GetWindowDrawList()
	any := false
	for k in 0 ..< pm.SLOTS {
		if !pm.slot_used(m, k) do continue
		any = true
		im.PushIDInt(i32(k))
		s := p.sequences[k]
		uses := 0
		for st in p.song.steps[:p.song.count] do if int(st.slot) == k do uses += int(st.repeats)
		w := im.GetContentRegionAvail().x
		h: f32 = 46
		pos := im.GetCursorScreenPos()
		btn := im.GetFrameHeight()
		clicked := im.InvisibleButton("##seq", {w - btn - 4, h})
		ui.name(fmt.tprintf("song seq %d", k + 1))
		hovered := im.IsItemHovered()
		if hovered && im.IsMouseDoubleClicked(.Left) do pm.song_add(m, k)
		else if clicked do pm.select_slot(m, k)
		item_menu(a, seq_target(k), "##sidemenu")
		if im.BeginDragDropSource() {
			slot := i32(k)
			im.SetDragDropPayload("SEQUENCE", &slot, size_of(slot))
			im.Text("%s", fmt.ctprintf("%s", pm.sequence_name(p, k)))
			im.EndDragDropSource()
		}
		bg := t.raised
		if k == playing do bg = ui.mix(t.raised, t.accent, 0.55)
		else if k == p.slot do bg = ui.mix(t.raised, t.accent, 0.18)
		if hovered do bg = ui.lighten(bg, 0.06)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		fg := t.accent_text if k == playing else t.text
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 6}, ui.col(fg), fmt.ctprintf("%s", pm.sequence_name(p, k)))
		info := fmt.tprintf("%d bar%s%s", s.bars, "" if s.bars == 1 else "s", fmt.tprintf(" · %.0f BPM", s.bpm) if s.bpm > 0 else "")
		if uses > 0 do info = fmt.tprintf("%s · ×%d in the song", info, uses)
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 6 + im.GetTextLineHeightWithSpacing()}, ui.col(t.accent_text if k == playing else t.text_dim), fmt.ctprintf("%s", info))
		im.SameLine(0, 4)
		im.SetCursorScreenPos({pos.x + w - btn, pos.y + (h - btn) / 2})
		if ui.icon_button(ui.ICON_PLUS, fmt.ctprintf("Add %s to the song's end", pm.sequence_name(p, k))) do pm.song_add(m, k)
		im.SetCursorScreenPos({pos.x, pos.y + h + 4})
		im.Dummy({1, 0})
		im.PopID()
	}
	if !any do im.TextDisabled("No sequences yet: make one in the Sequence tab.")
}
