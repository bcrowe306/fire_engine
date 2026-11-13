package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// Sequences as things to act on: renaming (double-click its name, or its
// menu), duplicating, its own tempo, copying bars to another sequence, and
// copying a marked part of the piano roll to paste anywhere.

// What the sequence actions keep between frames.
Seq_Ops :: struct {
	rename_slot: int, // the sequence being renamed (-1: none)
	rename_buf:  [24]u8,
	rename_open: bool, // open the rename popup next frame
	bars_open:   bool, // open the Copy bars dialog next frame
	bars:        struct {
		from, lo, hi, to, at: i32,
		pads:    int, // 0 = all, 1 = the selected pad, 2 = this bank
		replace: bool,
	},
	part:     pm.Seq_Part, // copied (Cmd+C), to paste (Cmd+V)
	has_part: bool,
	rename_pad: int, // the pad being renamed
	pad_buf:  [32]u8,
	pad_open: bool,
}

// Starts renaming sequence `slot` (a popup with its name, selected).
begin_rename_sequence :: proc(a: ^App, slot: int) {
	o := &a.seq_ops
	o.rename_slot = slot
	o.rename_buf = {}
	copy(o.rename_buf[:len(o.rename_buf) - 1], pm.sequence_name(&a.m.project, slot))
	o.rename_open = true
}

// Opens the Copy bars dialog from sequence `slot`.
begin_copy_bars :: proc(a: ^App, slot: int) {
	o := &a.seq_ops
	s := a.m.project.sequences[slot]
	to := pm.next_empty_slot(&a.m, slot)
	o.bars = {from = i32(slot), lo = 1, hi = i32(s.bars), to = i32(to if to >= 0 else (slot + 1) % pm.SLOTS), at = 1, replace = true}
	o.bars_open = true
}

// The items of a sequence's context menu (inside an open popup).
sequence_menu_items :: proc(a: ^App, slot: int) {
	command_items(a, seq_target(slot))
}

// Sequence `slot`'s colour: its slot's own, or one of the swatches.
seq_color_menu :: proc(a: ^App, slot: int) {
	m := &a.m
	cur := m.project.sequences[slot].color
	im.TextDisabled("%s", fmt.ctprintf("%s colour", pm.sequence_name(&m.project, slot)))
	swatch :: proc(c: u32, on: bool, name: string) -> bool {
		hit := im.ColorButton("##swatch", transmute(im.Vec4)ui.rgb(c), {.NoTooltip, .NoBorder}, {22, 22})
		ui.name(name)
		if on {
			mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
			im.DrawList_AddRect(im.GetWindowDrawList(), {mn.x - 2, mn.y - 2}, {mx.x + 2, mx.y + 2}, ui.col(ui.theme().text), 4, 1.5)
		}
		return hit
	}
	im.PushIDInt(-1)
	if swatch(pm.SEQ_PALETTE[slot % len(pm.SEQ_PALETTE)], cur == 0, "colour default") do pm.set_sequence_color(m, slot, 0)
	im.PopID()
	if im.IsItemHovered() do im.SetTooltip("Its slot's own colour")
	for c, k in PAD_PALETTE {
		if k % 6 != 5 do im.SameLine(0, 4)
		im.PushIDInt(i32(k))
		if swatch(c, cur == c, fmt.tprintf("colour %d", k + 1)) do pm.set_sequence_color(m, slot, c)
		im.PopID()
	}
}

// The current sequence's name (double-click to rename, right-click for its
// menu), its own tempo, duplicate: the head of the Sequence panel.
sequence_head :: proc(a: ^App) {
	m := &a.m
	slot := m.project.slot
	name := pm.sequence_name(&m.project, slot)
	// The sequence before and after it (as the toolbar's arrows).
	if ui.icon_button(ui.ICON_CHEVRON_LEFT, "Previous sequence", disabled = slot == 0) do pm.select_slot(m, slot - 1)
	ui.name("sequence before")
	im.SameLine(0, 0)
	im.PushFontFloat(a.platform.fonts.semibold, 15)
	label := fmt.ctprintf("%s###seqname", name)
	w := im.CalcTextSize(label).x + 16
	im.Selectable(label, false, {.AllowDoubleClick}, {w, im.GetFrameHeight()})
	im.PopFont()
	ui.name("sequence name")
	{
		mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
		im.DrawList_AddRectFilled(im.GetWindowDrawList(), {mn.x + 4, mx.y - 3}, {mx.x - 4, mx.y - 1}, ui.col(ui.rgb(pm.sequence_color(&m.project, slot))), 1)
	}
	if im.IsItemHovered() {
		im.SetTooltip("Double-click to rename; right-click for more")
		if im.IsMouseDoubleClicked(.Left) do begin_rename_sequence(a, slot)
	}
	if im.BeginPopupContextItem("##seqmenu") {
		sequence_menu_items(a, slot)
		im.EndPopup()
	}
	im.SameLine(0, 0)
	if ui.icon_button(ui.ICON_CHEVRON_RIGHT, "Next sequence", disabled = slot >= pm.SLOTS - 1) do pm.select_slot(m, slot + 1)
	ui.name("sequence after")
	im.SameLine(0, 4)
	if ui.icon_button(ui.ICON_COPY_PLUS, "Duplicate to the next empty sequence (Cmd+D)") do pm.duplicate_sequence(m, slot)
	// Its own tempo: on, and how fast.
	im.SameLine(0, 4)
	s := m.project.sequences[slot]
	own := s.bpm > 0
	if ui.icon_button(ui.ICON_GAUGE, "Own tempo: on (it plays at its tempo, from where it takes over)" if own else "Own tempo: off (the project's)", on = own) {
		pm.set_sequence_tempo(m, slot, 0 if own else m.project.bpm)
		app.seal(&m.history)
	}
	if own {
		im.SameLine(0, 2)
		bpm := s.bpm
		e := ui.number_drag("seq tempo", &bpm, 40, 300, 1, 0.1, "%.1f BPM", 96)
		if e.changed do pm.set_sequence_tempo(m, slot, bpm)
		if e.ended do app.seal(&m.history)
	}
}

// The rename popups and the Copy bars dialog, when open. Once a frame.
draw_seq_dialogs :: proc(a: ^App) {
	draw_pad_rename(a)
	m := &a.m
	o := &a.seq_ops
	if o.rename_open {
		im.OpenPopup("Rename Sequence")
		o.rename_open = false
	}
	if im.BeginPopupModal("Rename Sequence", nil, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(260)
		done := im.InputText("##seq_rename", cstring(&o.rename_buf[0]), len(o.rename_buf), {.EnterReturnsTrue, .AutoSelectAll})
		ui.name("sequence rename")
		if done || im.Button("Rename") {
			pm.rename_sequence(m, o.rename_slot, strings.truncate_to_byte(string(o.rename_buf[:]), 0))
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
	if o.bars_open {
		im.OpenPopup("Copy Bars")
		o.bars_open = false
	}
	if im.BeginPopupModal("Copy Bars", nil, {.AlwaysAutoResize}) {
		b := &o.bars
		from := m.project.sequences[b.from]
		im.Text("%s", fmt.ctprintf("From %s", pm.sequence_name(&m.project, int(b.from))))
		im.SetNextItemWidth(110)
		im.DragInt("##lo", &b.lo, 0.1, 1, i32(from.bars), "bar %d", {.ClampOnInput})
		im.SameLine()
		im.SetNextItemWidth(110)
		im.DragInt("##hi", &b.hi, 0.1, b.lo, i32(from.bars), "to bar %d", {.ClampOnInput})
		b.hi = max(b.hi, b.lo)
		ui.segmented("pads", {"Every pad", fmt.tprintf("%s only", pm.pad_label(a.selected)), fmt.tprintf("Bank %c", rune('A' + a.bank))}, &b.pads)
		im.Spacing()
		im.SetNextItemWidth(200)
		if ui.combo("##to", fmt.ctprintf("Into %s", pm.sequence_name(&m.project, int(b.to)))) {
			for k in 0 ..< pm.SLOTS {
				if k == int(b.from) do continue
				label := fmt.ctprintf("%s %s", ui.ICON_CIRCLE_DOT if pm.slot_used(m, k) else "   ", pm.sequence_name(&m.project, k))
				if im.Selectable(label, k == int(b.to)) do b.to = i32(k)
			}
			im.EndCombo()
		}
		im.SameLine()
		im.SetNextItemWidth(110)
		im.DragInt("##at", &b.at, 0.1, 1, pm.MAX_BARS, "at bar %d", {.ClampOnInput})
		ui.toggle("Replace what is there", &b.replace)
		im.Spacing()
		if im.Button("Copy") {
			pads: [pm.PADS]bool
			mask: ^[pm.PADS]bool
			switch b.pads {
			case 1:
				pads[a.selected] = true
				mask = &pads
			case 2:
				for k in 0 ..< pm.PADS_PER_BANK do pads[a.bank * pm.PADS_PER_BANK + k] = true
				mask = &pads
			}
			pm.copy_bars(m, int(b.from), int(b.lo), int(b.hi), mask, int(b.to), int(b.at), b.replace)
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Bars %d-%d copied into %s", b.lo, b.hi, pm.sequence_name(&m.project, int(b.to))))
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
}

// The selected notes' first bar (in beats), and the length in whole bars
// from there to their last end.
@(private)
selection_span :: proc(a: ^App) -> (lo, beats: f64) {
	bar := pm.bar_beats(&a.m.project)
	first, last := max(f64), f64(0)
	for n in a.seq.sel {
		first = min(first, n.start)
		last = max(last, n.start + n.length)
	}
	lo = math.floor(first / bar + 1e-9) * bar
	return lo, max(math.ceil((last - lo) / bar - 1e-9), 1) * bar
}

// Copies the selected notes (Cmd+C), from their first bar. False if none
// are selected.
copy_marked :: proc(a: ^App) -> bool {
	if len(a.seq.sel) == 0 do return false
	part := &a.seq_ops.part
	pm.part_destroy(part)
	lo, beats := selection_span(a)
	part.beats = beats
	for n in a.seq.sel {
		x := n
		x.start -= lo
		append(&part.notes, x)
		part.pads[n.pad] = true
	}
	a.seq_ops.has_part = true
	ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Copied %d note%s", len(part.notes), "" if len(part.notes) == 1 else "s"))
	return true
}

// Pastes what was copied into the current sequence (Cmd+V), laid over what
// is there: where the menu was opened, else at the selection's first bar,
// else at the first bar. What it pasted is selected.
paste_marked :: proc(a: ^App) -> bool {
	if !a.seq_ops.has_part do return false
	at := 0.0
	if a.seq.paste_at >= 0 {
		bar := pm.bar_beats(&a.m.project)
		at = math.floor(a.seq.paste_at / pm.grid_beats(a.seq.grid) + 1e-9) * pm.grid_beats(a.seq.grid) if a.seq.paste_at > 0 else 0
		_ = bar
	} else if len(a.seq.sel) > 0 {
		at, _ = selection_span(a)
	}
	pm.paste_part(&a.m, a.m.project.slot, &a.seq_ops.part, at, replace = false)
	clear(&a.seq.sel)
	for n in a.seq_ops.part.notes {
		x := n
		x.start += at
		append(&a.seq.sel, x)
	}
	return true
}

// Duplicates the selected notes after themselves (from the bar after
// their last).
duplicate_selection :: proc(a: ^App) {
	if !copy_marked(a) do return
	lo, beats := selection_span(a)
	a.seq.paste_at = -1
	clear(&a.seq.sel)
	pm.paste_part(&a.m, a.m.project.slot, &a.seq_ops.part, lo + beats, replace = false)
	for n in a.seq_ops.part.notes {
		x := n
		x.start += lo + beats
		append(&a.seq.sel, x)
	}
}

// Removes the selected notes.
delete_selection :: proc(a: ^App) {
	pm.remove_note_values(&a.m, a.m.project.slot, a.seq.sel[:])
	app.seal(&a.m.history)
	clear(&a.seq.sel)
}

// Whether the editor's keys act on notes: it has the keyboard, with notes selected.
editing_notes :: proc(a: ^App) -> bool {
	return a.seq.focused && len(a.seq.sel) > 0
}

// Starts renaming pad `i` (a popup with its name).
begin_rename_pad :: proc(a: ^App, i: int) {
	o := &a.seq_ops
	o.rename_pad = i
	o.pad_buf = {}
	copy(o.pad_buf[:len(o.pad_buf) - 1], pm.pad_name(&a.m.project.pads[i]))
	o.pad_open = true
}

// The pad rename popup, when open. Once a frame.
draw_pad_rename :: proc(a: ^App) {
	o := &a.seq_ops
	if o.pad_open {
		im.OpenPopup("Rename Pad")
		o.pad_open = false
	}
	if im.BeginPopupModal("Rename Pad", nil, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(260)
		done := im.InputText("##pad_rename", cstring(&o.pad_buf[0]), len(o.pad_buf), {.EnterReturnsTrue, .AutoSelectAll})
		ui.name("pad rename")
		if done || im.Button("Rename") {
			p := a.m.project.pads[o.rename_pad]
			pm.set_pad_name(&p, strings.truncate_to_byte(string(o.pad_buf[:]), 0))
			pm.set_pad(&a.m, o.rename_pad, .Name, "Rename Pad", p)
			app.seal(&a.m.history)
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
}

// Mutes the selected notes (0), or unmutes them when all are muted: they
// stay where they are, silent.
mute_selection :: proc(a: ^App) {
	if len(a.seq.sel) == 0 do return
	all := true
	for n in a.seq.sel do all &&= n.muted
	new := make([]pm.Seq_Note, len(a.seq.sel), context.temp_allocator)
	for n, i in a.seq.sel {
		new[i] = n
		new[i].muted = !all
	}
	landed := pm.replace_notes(&a.m, a.m.project.slot, a.seq.sel[:], new, false, .Mute, "Unmute Notes" if all else "Mute Notes")
	app.seal(&a.m.history)
	clear(&a.seq.sel)
	append(&a.seq.sel, ..landed)
}

// Moves the selected notes `beats` later and `rows` up (the editor's rows:
// pads, or pitches in the piano roll); none move if one would leave the
// sequence or the rows.
nudge_selection :: proc(a: ^App, beats: f64, rows: int, row_pad, row_pitch: []int) {
	st := &a.seq
	length := pm.seq_beats(&a.m.project, pm.current_sequence(&a.m))
	moved := make([]pm.Seq_Note, len(st.sel), context.temp_allocator)
	for n, i in st.sel {
		x := n
		x.start += beats
		if x.start < -1e-9 || x.start >= length - 1e-9 do return
		if rows != 0 {
			k := row_of_note(row_pad, row_pitch, st.piano, n) + rows
			if k < 0 || k >= len(row_pad) do return
			x.pad = u8(row_pad[k])
			if st.piano do x.pitch = i8(row_pitch[k])
		}
		moved[i] = x
	}
	landed := pm.replace_notes(&a.m, a.m.project.slot, st.sel[:], moved, false, .Notes, "Nudge Notes")
	app.seal(&a.m.history)
	clear(&st.sel)
	append(&st.sel, ..landed)
}
