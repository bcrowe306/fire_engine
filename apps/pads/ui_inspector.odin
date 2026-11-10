package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:sampler"

// Pad colours to choose from.
PAD_COLORS := [8]u32{0xff7a59, 0xffc14d, 0x5ad1a5, 0x58a6ff, 0x9b8cff, 0xff6fae, 0x7ad3ff, 0xb5c0cf}

// The selected pad's settings.
draw_inspector :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	i := a.selected
	pad := m.project.pads[i]
	f := a.platform.fonts

	im.PushFontFloat(f.bold, 18)
	im.Text("%s", fmt.ctprintf("%s", pm.pad_label(i)))
	im.PopFont()
	im.SameLine()
	im.AlignTextToFramePadding()
	if pad.sample == 0 {
		im.TextDisabled("Empty: drop a sample here, or use File > Import")
		return
	}
	s := pm.pad_sample(m, i)
	im.TextDisabled("%s", fmt.ctprintf("%s · %.2f s · %.0f Hz · %s", s.name, f64(s.frames) / s.rate, s.rate, "stereo" if s.channels > 1 else "mono"))

	// Name and colour.
	@(static) name_buf: [32]u8
	@(static) name_for := -1
	if name_for != i || !im.IsItemActive() {
		if name_for != i do name_buf = pad.name
		name_for = i
	}
	im.SetNextItemWidth(-1)
	if im.InputText("##name", cstring(&name_buf[0]), len(name_buf)) {
		p := pad
		p.name = name_buf
		pm.set_pad(m, i, .Name, "Rename Pad", p)
	}
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	for c, k in PAD_COLORS {
		if k > 0 do im.SameLine(0, 6)
		im.PushIDInt(i32(k))
		col := ui.rgb(c)
		if im.ColorButton("##c", transmute(im.Vec4)col, {.NoTooltip, .NoBorder}, {22, 22}) && pad.color != c {
			p := pad
			p.color = c
			pm.set_pad(m, i, .Color, "Set Color", p)
			app.seal(&m.history)
		}
		im.PopID()
	}

	section(a, "Playback")
	mode := int(pad.mode)
	if ui.segmented("mode", {"One-shot", "Gate", "Loop", "Hold"}, &mode) {
		p := pad
		p.mode = pm.Pad_Mode(mode)
		pm.set_pad(m, i, .Mode, "Set Mode", p)
		app.seal(&m.history)
	}
	im.SameLine(0, 16)
	rev := pad.reverse
	if ui.toggle("Reverse", &rev) {
		p := pad
		p.reverse = rev
		pm.set_pad(m, i, .Reverse, "Reverse", p)
		app.seal(&m.history)
	}
	if pad.mode == .Loop || pad.mode == .Hold {
		lm := int(pad.loop_mode)
		if ui.segmented("loop_mode", {"Forward", "Ping-pong"}, &lm) {
			p := pad
			p.loop_mode = sampler.Loop_Mode(lm)
			pm.set_pad(m, i, .Loop_Mode, "Set Loop Mode", p)
			app.seal(&m.history)
		}
		im.SameLine(0, 16)
		xf := f32(pad.crossfade) / f32(s.rate) * 1000
		im.SetNextItemWidth(140)
		if im.SliderFloat("Crossfade", &xf, 0, 500, "%.0f ms") {
			p := pad
			p.crossfade = i64(xf * f32(s.rate) / 1000)
			pm.set_pad(m, i, .Crossfade, "Set Crossfade", p)
		}
		if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	}
	choke := i32(pad.choke)
	groups := [pm.CHOKE_GROUPS + 1]cstring{"No choke group", "Choke group 1", "Choke group 2", "Choke group 3", "Choke group 4", "Choke group 5", "Choke group 6"}
	im.SetNextItemWidth(180)
	if im.ComboChar("##choke", &choke, &groups[0], len(groups)) {
		p := pad
		p.choke = u8(choke)
		pm.set_pad(m, i, .Choke, "Set Choke Group", p)
		app.seal(&m.history)
	}

	section(a, "Sound")
	knob_f32(a, "Volume", &pad.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	im.SameLine(0, 14)
	knob_f32(a, "Pan", &pad.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	im.SameLine(0, 14)
	knob_f32(a, "Pitch", &pad.pitch, -24, 24, 0, "%+.1f st", .Pitch, "Set Pitch")
	im.SameLine(0, 14)
	knob_f32(a, "Attack", &pad.attack, 0, 2, 0.001, "%.3f s", .Attack, "Set Attack")
	im.SameLine(0, 14)
	knob_f32(a, "Release", &pad.release, 0.005, 5, 0.05, "%.2f s", .Release, "Set Release")

	section(a, "EQ")
	knob_f32(a, "Low", &pad.eq[0], -15, 15, 0, "%+.1f dB", .Eq_Low, "Set EQ Low")
	im.SameLine(0, 14)
	knob_f32(a, "Mid", &pad.eq[1], -15, 15, 0, "%+.1f dB", .Eq_Mid, "Set EQ Mid")
	im.SameLine(0, 14)
	knob_f32(a, "High", &pad.eq[2], -15, 15, 0, "%+.1f dB", .Eq_High, "Set EQ High")

	im.Spacing()
	im.Spacing()
	if im.Button(ui.ICON_ERASER + "  Clear Pad") do pm.clear_pad(m, i)
}

// A knob for one f32 field of the selected pad, as an undoable edit.
@(private)
knob_f32 :: proc(a: ^App, label: cstring, value: ^f32, lo, hi, default: f32, format: cstring, field: pm.Pad_Field, step: string) {
	m := &a.m
	v := value^
	e := ui.knob(label, &v, lo, hi, default, format)
	if e.changed {
		p := m.project.pads[a.selected]
		set_field(&p, field, v)
		pm.set_pad(m, a.selected, field, step, p)
	}
	if e.ended do app.seal(&m.history)
}

@(private)
set_field :: proc(p: ^pm.Pad, field: pm.Pad_Field, v: f32) {
	#partial switch field {
	case .Volume:  p.volume = v
	case .Pan:     p.pan = v
	case .Pitch:   p.pitch = v
	case .Attack:  p.attack = v
	case .Release: p.release = v
	case .Eq_Low:  p.eq[0] = v
	case .Eq_Mid:  p.eq[1] = v
	case .Eq_High: p.eq[2] = v
	}
}

// A small heading.
section :: proc(a: ^App, title: cstring) {
	im.Spacing()
	im.Spacing()
	im.PushFontFloat(a.platform.fonts.semibold, 13)
	im.TextDisabled("%s", title)
	im.PopFont()
	im.Separator()
	im.Spacing()
}

_ :: fmt.tprint
_ :: strings.clone
