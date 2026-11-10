package pads

import "core:fmt"
import "core:strings"

import "app:ui"
import pm "model"
import im "deps:imgui"

// Key shown on each pad of a bank, for the keyboard.
PAD_KEY_LABELS := [16]string{"1", "2", "3", "4", "Q", "W", "E", "R", "A", "S", "D", "F", "Z", "X", "C", "V"}

// The pad grid: bank tabs and tempo above, the bank's 16 pads in a 4×4
// grid that fills the panel.
draw_pads :: proc(user: rawptr) {
	a := (^App)(user)
	p := &a.m.project
	f := a.platform.fonts

	bank := a.bank
	if ui.segmented("banks", {"A", "B", "C", "D"}, &bank) do a.bank = bank
	im.SameLine(0, 18)
	im.AlignTextToFramePadding()
	letters := "ABCD"
	im.TextDisabled("%s", fmt.ctprintf("Bank %s", letters[a.bank:][:1]))
	im.SameLine()
	right: f32 = 150
	im.SetCursorPosX(im.GetWindowWidth() - right - im.GetStyle().WindowPadding.x)
	im.SetNextItemWidth(right)
	bpm := f32(p.bpm)
	if im.DragFloat("##bpm", &bpm, 0.1, 40, 300, "%.1f BPM") do p.bpm = f64(bpm)
	im.Spacing()

	avail := im.GetContentRegionAvail()
	gap: f32 = 10
	side := min((avail.x - 3 * gap) / 4, (avail.y - 3 * gap) / 4)
	side = max(side, 48)
	origin := im.GetCursorScreenPos()
	origin.x += (avail.x - (4 * side + 3 * gap)) / 2 // centred
	for row in 0 ..< 4 do for col in 0 ..< 4 {
		k := row * 4 + col
		index := a.bank * pm.PADS_PER_BANK + k
		pad := &p.pads[index]
		pos := im.Vec2{origin.x + f32(col) * (side + gap), origin.y + f32(row) * (side + gap)}
		a.pad_rects[k] = {pos, {pos.x + side, pos.y + side}}
		im.SetCursorScreenPos(pos)
		im.PushIDInt(i32(index))
		has := pad.sample != 0
		name := pm.pad_name(pad) if has else "Empty"
		detail := fmt.tprintf("%s · %s", pm.pad_label(index), PAD_KEY_LABELS[k])
		if has {
			modes := [pm.Pad_Mode]string{.One_Shot = "", .Gate = " · Gate", .Loop = " · Loop", .Hold = " · Hold"}
			detail = strings.concatenate({detail, modes[pad.mode]}, context.temp_allocator)
		}
		hit := ui.pad("pad", name, detail, ui.rgb(pad.color), has, a.lit[index] > 0 || a.held[index], a.selected == index, {side, side})
		if hit.pressed do press(a, index, hit.velocity)
		if hit.released do release(a, index)
		if hit.selected do a.selected = index
		// Drop a file from the browser on a pad.
		if im.BeginDragDropTarget() {
			if payload := im.AcceptDragDropPayload("PADS_FILE"); payload != nil {
				path := strings.string_from_ptr((^u8)(payload.Data), int(payload.DataSize))
				if pm.load_onto_pad(&a.m, index, path) == .None do a.selected = index
			}
			im.EndDragDropTarget()
		}
		im.PopID()
	}
	im.SetCursorScreenPos({origin.x, origin.y + 4 * side + 3 * gap})
	im.Dummy({1, 1})
	_ = f
}
