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
			middle    = (ui.ICON_CIRCLE_DOT + " armed" if pm.track_armed(&a.m, index) else ui.ICON_MIC + " audio") if audio else pm.pad_note_name(index),
			tint      = ui.rgb(pad.color),
			has_sound = has,
			lit       = a.lit[index] > 0 || a.held[index],
			selected  = index in selected_pads(a),
			mute      = pad.mute,
			solo      = pad.solo,
			buttons   = has,
			drop_type = "PADS_FILE",
			badge     = fmt.tprintf("C%d", pad.choke) if pad.choke > 0 && has else "",
			armed     = pm.track_armed(&a.m, index),
			drop_zones = !has,
		}
		if has && a.pad_waves && !audio do face.peaks = pad_peaks(a, index)
		if pad.kind == .Synth do face.middle = ui.ICON_AUDIO_WAVEFORM + " synth"
		if pad.kind == .Slicer do face.middle = fmt.tprintf("%s %d slices", ui.ICON_SCISSORS, pad.slicer.count) if pad.sample != 0 else ui.ICON_SCISSORS + " slicer"

		switch a.play_mode {
		case .Pads:
		case .Keyboard: // the notes of the scale, on the selected pad
			target := &p.pads[a.selected]
			pitches: [4]int
			ps := pm.keyboard_pitches(a.keys, k, &pitches)
			face.name = ui.note_name(60 + ps[0])
			if len(ps) > 1 do face.name = fmt.tprintf("%s %s", face.name, CHORD_SUFFIX[a.keys.chord])
			face.middle = fmt.tprintf("%+d st", ps[0])
			face.tint, face.has_sound, face.selected, face.buttons, face.peaks = ui.rgb(target.color), target.sample != 0 || target.kind == .Synth, false, false, nil
			if (ps[0] - a.keys.root) %% 12 == 0 do face.selected = true // the roots stand out
			if target.kind == .Slicer { // its slices, a pad each
				face.name = fmt.tprintf("Slice %d", k + 1)
				face.middle = ui.note_name(int(target.slicer.base) + k)
				face.has_sound = k < int(target.slicer.count)
				face.selected = false
			}
		case .Velocity:
			target := &p.pads[a.selected]
			face.name = fmt.tprintf("%d", int(pm.velocity_of_pad(k) * 127 + 0.5))
			face.middle = "velocity"
			face.tint, face.has_sound, face.selected, face.buttons, face.peaks = ui.rgb(target.color), target.sample != 0 || target.kind == .Synth, false, false, nil
		}
		hit := ui.pad("pad", face, {side, side})
		if hit.pressed do press(a, index, hit.velocity)
		if hit.pressed && a.play_mode == .Pads do a.pad_sel, a.pad_anchor = {index}, index
		if (hit.pressed || hit.selected) && a.play_mode == .Pads do show_pad_chain(a, index)
		if hit.released do release(a, index)
		if hit.selected && a.play_mode == .Pads do select_pad(a, index, hit.menu)
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
		// A file from the browser dropped on it: into a slicer (with Alt, on
		// an empty pad's lower half, or onto a slicer), else a sampler.
		if hit.dropped != "" {
			if hit.drop_slicer || pad.kind == .Slicer {
				load_into_slicer(a, index, hit.dropped)
			} else if pm.load_onto_pad(&a.m, index, hit.dropped) == .None {
				a.selected = index
			}
		}
		if im.BeginPopup("##padmenu") {
			if card(selected_pads(a)) > 1 {
				pads_menu_items(a)
			} else {
				command_items(a, pad_target(index))
				im.Separator()
				choke_menu(a, {index})
				if im.BeginMenu(ui.ICON_PALETTE + "  Colour") {
					pad_color_menu(a, index)
					im.EndMenu()
				}
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

// A set of pads (their indices).
Pad_Set :: bit_set[0 ..< pm.PADS; u128]

// The pads a pad command acts on: those selected together, when the
// selected pad is one of them; else the selected pad alone.
selected_pads :: proc(a: ^App) -> Pad_Set {
	if a.selected in a.pad_sel && card(a.pad_sel) > 1 do return a.pad_sel
	return {a.selected}
}

// Selects pad `index` by a click with Shift (the pads from the last one
// clicked to it), Cmd or Ctrl (one more, or one less), or the right button
// (it alone, unless it is already selected: the menu acts on them all).
@(private)
select_pad :: proc(a: ^App, index: int, menu: bool) {
	io := im.GetIO()
	sel := selected_pads(a)
	switch {
	case menu:
		if index not_in sel do a.pad_sel, a.pad_anchor = {index}, index
		else do a.pad_sel = sel
	case io.KeyShift:
		from := a.pad_anchor if a.pad_anchor >= 0 && a.pad_anchor < pm.PADS else a.selected
		a.pad_sel = {}
		for k in min(from, index) ..= max(from, index) do a.pad_sel += {k}
	case:
		a.pad_sel = sel ~ {index}
		if card(a.pad_sel) == 0 do a.pad_sel = {index}
		a.pad_anchor = index
	}
	if index in a.pad_sel || card(a.pad_sel) == 0 do a.selected = index
	else do for k in 0 ..< pm.PADS do if k in a.pad_sel { a.selected = k; break }
	show_pad_chain(a, a.selected)
}

// The menu for several pads at once: clear, mute, solo, their choke group
// and colour. One undo step each.
@(private)
pads_menu_items :: proc(a: ^App) {
	sel := selected_pads(a)
	im.TextDisabled("%s", fmt.ctprintf("%d pads", card(sel)))
	im.Separator()
	all_muted, all_solo := true, true
	for i in 0 ..< pm.PADS do if i in sel {
		all_muted &&= a.m.project.pads[i].mute
		all_solo &&= a.m.project.pads[i].solo
	}
	if im.MenuItem(ui.ICON_VOLUME_X + "  Unmute" if all_muted else ui.ICON_VOLUME_X + "  Mute") do set_pads_flag(a, sel, .Mute, !all_muted)
	ui.name("Mute Pads")
	if im.MenuItem(ui.ICON_HEADPHONES + "  Unsolo" if all_solo else ui.ICON_HEADPHONES + "  Solo") do set_pads_flag(a, sel, .Solo, !all_solo)
	ui.name("Solo Pads")
	choke_menu(a, sel)
	if im.MenuItem(ui.ICON_ERASER + "  Clear Pads", "Delete") do clear_pads(a, sel)
	ui.name("Clear Pads")
}

// Mutes or solos pads `sel` (`on`): one undo step.
@(private)
set_pads_flag :: proc(a: ^App, sel: Pad_Set, field: pm.Pad_Field, on: bool) {
	m := &a.m
	name := "Mute Pads" if field == .Mute else "Solo Pads"
	app.begin(&m.history, name)
	defer app.end(&m.history)
	for i in 0 ..< pm.PADS do if i in sel {
		p := m.project.pads[i]
		if field == .Mute do p.mute = on
		else do p.solo = on
		pm.set_pad(m, i, field, name, p)
	}
}

// Clears pads `sel`: one undo step.
clear_pads :: proc(a: ^App, sel: Pad_Set) {
	app.begin(&a.m.history, "Clear Pads")
	defer app.end(&a.m.history)
	for i in 0 ..< pm.PADS do if i in sel do pm.clear_pad(&a.m, i)
}

// A "Choke Group" submenu for pads `sel`: none, or one of the groups (a
// pad hit stops the others playing in its group).
@(private)
choke_menu :: proc(a: ^App, sel: Pad_Set) {
	if !im.BeginMenu(ui.ICON_SCISSORS + "  Choke Group") do return
	defer im.EndMenu()
	cur := -1
	for i in 0 ..< pm.PADS do if i in sel {
		g := int(a.m.project.pads[i].choke)
		cur = g if cur == -1 || cur == g else -2 // -2: mixed
	}
	for g in 0 ..= pm.CHOKE_GROUPS {
		label := fmt.ctprintf("None###choke0") if g == 0 else fmt.ctprintf("Group %d###choke%d", g, g)
		if im.MenuItem(label, nil, cur == g) do set_choke(a, sel, g)
		ui.name(fmt.tprintf("choke %d", g))
	}
}

// Puts pads `sel` in choke group `g` (0: none): one undo step.
set_choke :: proc(a: ^App, sel: Pad_Set, g: int) {
	m := &a.m
	app.begin(&m.history, "Set Choke Group")
	defer app.end(&m.history)
	for i in 0 ..< pm.PADS do if i in sel {
		p := m.project.pads[i]
		p.choke = u8(clamp(g, 0, pm.CHOKE_GROUPS))
		pm.set_pad(m, i, .Choke, "Set Choke Group", p)
	}
	app.seal(&m.history)
}
