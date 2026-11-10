package pads

import "core:fmt"
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

// The current sequence's name (double-click to rename, right-click for its
// menu), its own tempo, duplicate: the head of the Sequence panel.
sequence_head :: proc(a: ^App) {
	m := &a.m
	slot := m.project.slot
	name := pm.sequence_name(&m.project, slot)
	im.PushFontFloat(a.platform.fonts.semibold, 15)
	label := fmt.ctprintf("%s###seqname", name)
	w := im.CalcTextSize(label).x + 16
	im.Selectable(label, false, {.AllowDoubleClick}, {w, im.GetFrameHeight()})
	im.PopFont()
	ui.name("sequence name")
	if im.IsItemHovered() {
		im.SetTooltip("Double-click to rename; right-click for more")
		if im.IsMouseDoubleClicked(.Left) do begin_rename_sequence(a, slot)
	}
	if im.BeginPopupContextItem("##seqmenu") {
		sequence_menu_items(a, slot)
		im.EndPopup()
	}
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

// The rename popup and the Copy bars dialog, when open. Once a frame.
draw_seq_dialogs :: proc(a: ^App) {
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

// Copies the marked part of the piano roll (Cmd+C): its bars, and the rows
// marked. False if nothing is marked.
copy_marked :: proc(a: ^App) -> bool {
	r := a.seq.range
	if !r.on do return false
	pads: [pm.PADS]bool
	for k in r.key0 ..= r.key1 do if k >= 0 && k < pm.PADS_PER_BANK do pads[a.bank * pm.PADS_PER_BANK + k] = true
	pm.copy_part(&a.m.project, a.m.project.slot, r.beat0, r.beat1, &pads, &a.seq_ops.part)
	a.seq_ops.has_part = true
	ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Copied %d note%s", len(a.seq_ops.part.notes), "" if len(a.seq_ops.part.notes) == 1 else "s"))
	return true
}

// Pastes what was copied into the current sequence (Cmd+V): at the marked
// part's start, else at its first bar. Its rows replace what they had there.
paste_marked :: proc(a: ^App) -> bool {
	if !a.seq_ops.has_part do return false
	at := a.seq.range.beat0 if a.seq.range.on else 0
	pm.paste_part(&a.m, a.m.project.slot, &a.seq_ops.part, at)
	return true
}
