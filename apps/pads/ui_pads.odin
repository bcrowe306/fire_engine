package pads

import "core:fmt"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// How a chord shows on a pad in keyboard mode.
CHORD_SUFFIX := [pm.Chord]string{.Off = "", .Triad = "chord", .Seventh = "7th", .Power = "5"}

// Key shown on each pad of a bank, for the keyboard.
PAD_KEY_LABELS := [16]string{"Z", "X", "C", "V", "A", "S", "D", "F", "Q", "W", "E", "R", "1", "2", "3", "4"}

// The pad grid: bank tabs above, the bank's 16 pads in a 4×4
// grid that fills the panel.
draw_pads :: proc(user: rawptr) {
	a := (^App)(user)
	p := &a.m.project
	f := a.platform.fonts

	bank := a.bank
	if ui.segmented("banks", {"A", "B", "C", "D", "E", "F", "G", "H"}, &bank) do a.bank = bank
	im.Spacing()

	avail := im.GetContentRegionAvail()
	gap: f32 = 10
	side := min((avail.x - 3 * gap) / 4, (avail.y - 3 * gap) / 4)
	side = max(side, 48)
	origin := im.GetCursorScreenPos()
	origin.x += (avail.x - (4 * side + 3 * gap)) / 2 // centred
	for row in 0 ..< 4 do for col in 0 ..< 4 {
		k := (3 - row) * 4 + col // pad 1 at the bottom left
		index := a.bank * pm.PADS_PER_BANK + k
		pad := &p.pads[index]
		pos := im.Vec2{origin.x + f32(col) * (side + gap), origin.y + f32(row) * (side + gap)}
		a.pad_rects[k] = {pos, {pos.x + side, pos.y + side}}
		im.SetCursorScreenPos(pos)
		im.PushIDInt(i32(index))
		has := pm.pad_used(p, index)
		audio := pad.kind == .Audio
		label := pm.pad_label(index)
		face := ui.Pad_Face{
			label     = fmt.tprintf("pad %s", label),
			name      = pm.pad_name(pad) if has else label,
			middle    = (ui.ICON_CIRCLE_DOT + " armed" if pm.audio_armed(&a.m, index) else ui.ICON_MIC + " audio") if audio else pm.pad_note_name(index),
			tint      = ui.rgb(pad.color),
			has_sound = has,
			lit       = a.lit[index] > 0 || a.held[index],
			selected  = a.selected == index,
			mute      = pad.mute,
			solo      = pad.solo,
			buttons   = has,
			drop_type = "PADS_FILE",
		}
		if has && a.pad_waves && !audio do face.peaks = pad_peaks(a, index)
		switch a.play_mode {
		case .Pads:
		case .Keyboard: // the notes of the scale, on the selected pad
			target := &p.pads[a.selected]
			pitches: [4]int
			ps := pm.keyboard_pitches(a.keys, k, &pitches)
			face.name = ui.note_name(60 + ps[0])
			if len(ps) > 1 do face.name = fmt.tprintf("%s %s", face.name, CHORD_SUFFIX[a.keys.chord])
			face.middle = fmt.tprintf("%+d st", ps[0])
			face.tint, face.has_sound, face.selected, face.buttons, face.peaks = ui.rgb(target.color), target.sample != 0, false, false, nil
			if (ps[0] - a.keys.root) %% 12 == 0 do face.selected = true // the roots stand out
		case .Velocity:
			target := &p.pads[a.selected]
			face.name = fmt.tprintf("%d", int(pm.velocity_of_pad(k) * 127 + 0.5))
			face.middle = "velocity"
			face.tint, face.has_sound, face.selected, face.buttons, face.peaks = ui.rgb(target.color), target.sample != 0, false, false, nil
		}
		hit := ui.pad("pad", face, {side, side})
		if hit.pressed do press(a, index, hit.velocity)
		if hit.released do release(a, index)
		if hit.selected && a.play_mode == .Pads do a.selected = index
		if hit.menu && a.play_mode == .Pads do im.OpenPopup("##padmenu")
		if im.IsItemHovered({.DelayNormal}) || (im.IsMouseHoveringRect(pos, {pos.x + side, pos.y + side}) && im.IsKeyDown(.LeftAlt)) {
			modes := [pm.Pad_Mode]string{.One_Shot = "one-shot", .Gate = "gate", .Loop = "loop", .Hold = "hold"}
			im.SetTooltip("%s", fmt.ctprintf("%s · key %s%s", label, PAD_KEY_LABELS[k], fmt.tprintf(" · %s", modes[pad.mode]) if has else ""))
		}
		if hit.mute || hit.solo {
			np := pad^
			if hit.mute do np.mute = !np.mute
			if hit.solo do np.solo = !np.solo
			pm.set_pad(&a.m, index, .Mute if hit.mute else .Solo, "Mute" if hit.mute else "Solo", np)
			app.seal(&a.m.history)
		}
		// A file from the browser dropped on it.
		if hit.dropped != "" && pm.load_onto_pad(&a.m, index, hit.dropped) == .None do a.selected = index
		if im.BeginPopup("##padmenu") {
			command_items(a, pad_target(index))
			im.Separator()
			if im.BeginMenu(ui.ICON_PALETTE + "  Colour") {
				pad_color_menu(a, index)
				im.EndMenu()
			}
			im.EndPopup()
		}
		im.PopID()
	}
	im.SetCursorScreenPos({origin.x, origin.y + 4 * side + 3 * gap})
	im.Dummy({1, 1})
	_ = f
}

// Colours a pad can have: 24 swatches (and any, from the picker).
PAD_PALETTE := [24]u32{
	0xff5f57, 0xff7a59, 0xff9f43, 0xffc14d, 0xffe066, 0xc6e05a,
	0x7bd88f, 0x5ad1a5, 0x3fc7c4, 0x4fc3f7, 0x58a6ff, 0x5b7cff,
	0x7c6cff, 0x9b8cff, 0xc77dff, 0xe879f9, 0xff6fae, 0xff8fa3,
	0xd4a373, 0xa98467, 0xb5c0cf, 0x8d99ae, 0x6c757d, 0xe9ecef,
}

// Pad `index`'s colour: the swatches, then a picker. (In the pads'
// right-click menu and the Pad tab.)
pad_color_menu :: proc(a: ^App, index: int) {
	m := &a.m
	pad := m.project.pads[index]
	set :: proc(m: ^pm.Model, index: int, c: u32) {
		p := m.project.pads[index]
		if p.color == c do return
		p.color = c
		pm.set_pad(m, index, .Color, "Set Color", p)
	}
	im.TextDisabled("%s", fmt.ctprintf("%s colour", pm.pad_label(index)))
	for c, k in PAD_PALETTE {
		if k % 6 != 0 do im.SameLine(0, 4)
		im.PushIDInt(i32(k))
		cv := ui.rgb(c)
		if im.ColorButton("##swatch", transmute(im.Vec4)cv, {.NoTooltip, .NoBorder}, {22, 22}) {
			set(m, index, c)
			app.seal(&m.history)
		}
		ui.name(fmt.tprintf("colour %d", k + 1))
		if pad.color == c {
			mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
			im.DrawList_AddRect(im.GetWindowDrawList(), {mn.x - 2, mn.y - 2}, {mx.x + 2, mx.y + 2}, ui.col(ui.theme().text), 4, 1.5)
		}
		im.PopID()
	}
	im.Spacing()
	rgb := [3]f32{f32((pad.color >> 16) & 0xff) / 255, f32((pad.color >> 8) & 0xff) / 255, f32(pad.color & 0xff) / 255}
	im.SetNextItemWidth(6 * 26)
	if im.ColorPicker3("##picker", &rgb, {.NoSidePreview, .NoSmallPreview, .NoAlpha, .PickerHueBar}) {
		c := u32(clamp(rgb[0], 0, 1) * 255 + 0.5) << 16 | u32(clamp(rgb[1], 0, 1) * 255 + 0.5) << 8 | u32(clamp(rgb[2], 0, 1) * 255 + 0.5)
		set(m, index, c)
	}
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
}

// Pad `index`'s sound as a waveform for its face: the region it plays, from
// peaks of the whole sample kept per sample (read once).
pad_peaks :: proc(a: ^App, index: int) -> []ui.Peak {
	pad := &a.m.project.pads[index]
	all, ok := a.peaks[pad.sample]
	if !ok {
		all = nil
		if au, ok2 := pm.pad_audio(&a.m, index); ok2 && len(au.channels) > 0 {
			mono := au.channels[0]
			if len(au.channels) > 1 {
				mono = make([]f32, len(au.channels[0]), context.temp_allocator)
				for ch in au.channels do for v, i in ch do mono[i] += v / f32(len(au.channels))
			}
			all = ui.peaks_of(mono, PEAK_COLUMNS)
		}
		a.peaks[pad.sample] = all
	}
	if len(all) == 0 do return nil
	s := pm.pad_sample(&a.m, index)
	if s == nil || s.frames <= 0 do return all
	lo := int(f64(pad.start) / f64(s.frames) * f64(len(all)))
	end := pad.end if pad.end > 0 else s.frames
	hi := int(f64(end) / f64(s.frames) * f64(len(all)))
	lo, hi = clamp(lo, 0, len(all) - 1), clamp(hi, lo + 1, len(all))
	return all[lo:hi]
}

// Columns of a sample's peaks kept for the pads' faces.
PEAK_COLUMNS :: 512
