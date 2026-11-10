package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:sampler"


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
	im.SameLine(0, 12)
	kind := int(pad.kind)
	if ui.segmented("kind", {"Sampler", "Audio"}, &kind) do pm.set_pad_kind(m, i, pm.Pad_Kind(kind))
	if im.IsItemHovered() do im.SetTooltip("A sampler plays its sample when hit; an audio pad records takes from an input and plays them with the sequence")
	im.SameLine(0, 12)
	im.AlignTextToFramePadding()
	if pad.kind == .Audio {
		draw_audio_inspector(a, i)
		return
	}
	if pad.sample == 0 {
		im.TextDisabled("Empty: drop a sample here, or use File > Import")
		return
	}
	s := pm.pad_sample(m, i)
	im.TextDisabled("%s", fmt.ctprintf("%s · %.2f s · %.0f Hz · %s", s.name, f64(s.frames) / s.rate, s.rate, "stereo" if s.channels > 1 else "mono"))

	// Wide (the bottom panel): three columns, as a device would lay out;
	// narrow: one after another.
	wide := im.GetContentRegionAvail().x >= 720
	if wide && !im.BeginTable("##inspector", 3, {.BordersInnerV}) do wide = false
	defer if wide do im.EndTable()
	if wide {
		im.TableSetupColumn("a", {.WidthStretch}, 1)
		im.TableSetupColumn("b", {.WidthFixed}, 5 * (ui.KNOB_SIZE + 14) + 20)
		im.TableSetupColumn("c", {.WidthFixed}, 3 * (ui.KNOB_SIZE + 14) + 20)
		im.TableNextColumn()
		section(a, "Pad", false)
	}

	pad_name_colour(a, i)

	section(a, "Playback", !wide)
	mode := int(pad.mode)
	if ui.segmented("mode", {"One-shot", "Gate", "Loop", "Hold"}, &mode) {
		p := pad
		p.mode = pm.Pad_Mode(mode)
		pm.set_pad(m, i, .Mode, "Set Mode", p)
		app.seal(&m.history)
	}
	rev := pad.reverse
	if ui.toggle("Reverse", &rev) {
		p := pad
		p.reverse = rev
		pm.set_pad(m, i, .Reverse, "Reverse", p)
		app.seal(&m.history)
	}
	choke := i32(pad.choke)
	groups := [pm.CHOKE_GROUPS + 1]cstring{"No choke group", "Choke group 1", "Choke group 2", "Choke group 3", "Choke group 4", "Choke group 5", "Choke group 6"}
	im.SameLine(0, 16)
	im.SetNextItemWidth(min(180, im.GetContentRegionAvail().x))
	if ui.combo_char("##choke", &choke, &groups[0], len(groups)) {
		p := pad
		p.choke = u8(choke)
		pm.set_pad(m, i, .Choke, "Set Choke Group", p)
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
	if wide do im.TableNextColumn()
	section(a, "Sound", !wide)
	knob_f32(a, "Volume", &pad.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	im.SameLine(0, 14)
	knob_f32(a, "Pan", &pad.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	im.SameLine(0, 14)
	knob_f32(a, "Pitch", &pad.pitch, -24, 24, 0, "%+.1f st", .Pitch, "Set Pitch")
	im.SameLine(0, 14)
	knob_f32(a, "Attack", &pad.attack, 0, 2, 0.001, "%.3f s", .Attack, "Set Attack")
	im.SameLine(0, 14)
	knob_f32(a, "Release", &pad.release, 0.005, 5, 0.05, "%.2f s", .Release, "Set Release")

	if wide do im.TableNextColumn()
	section(a, "EQ", !wide)
	knob_f32(a, "Low", &pad.eq[0], -15, 15, 0, "%+.1f dB", .Eq_Low, "Set EQ Low")
	im.SameLine(0, 14)
	knob_f32(a, "Mid", &pad.eq[1], -15, 15, 0, "%+.1f dB", .Eq_Mid, "Set EQ Mid")
	im.SameLine(0, 14)
	knob_f32(a, "High", &pad.eq[2], -15, 15, 0, "%+.1f dB", .Eq_High, "Set EQ High")

	im.Spacing()
	im.Spacing()
	if im.Button(ui.ICON_ERASER + "  Clear Pad") do pm.clear_pad(m, i)
}

// Pad `i`'s name and colour (click the swatch for a palette and a picker).
@(private)
pad_name_colour :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
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
	// Its colour: click for the swatches and a picker.
	if im.ColorButton("##color", transmute(im.Vec4)ui.rgb(pad.color), {.NoTooltip, .NoBorder}, {44, 22}) do im.OpenPopup("##colormenu")
	ui.name("colour")
	im.SameLine(0, 8)
	im.AlignTextToFramePadding()
	im.TextDisabled("Colour")
	if im.BeginPopup("##colormenu") {
		pad_color_menu(a, i)
		im.EndPopup()
	}

}

// An audio pad's settings: its take in the current sequence, its input,
// arming and monitoring, its level and EQ.
@(private)
draw_audio_inspector :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	c := pm.current_clip(m, i)
	seq := m.project.slot + 1
	if s := app.store_get(&m.project.samples, c.sample); s != nil {
		im.TextDisabled("%s", fmt.ctprintf("Sequence %d: a take of %.2f s at %.0f BPM", seq, f64(s.frames) / s.rate, c.bpm))
	} else {
		im.TextDisabled("%s", fmt.ctprintf("Sequence %d: no take yet (arm it, then record)", seq))
	}
	wide := im.GetContentRegionAvail().x >= 720
	if wide && !im.BeginTable("##audio_inspector", 3, {.BordersInnerV}) do wide = false
	defer if wide do im.EndTable()
	if wide {
		im.TableSetupColumn("a", {.WidthStretch}, 1)
		im.TableSetupColumn("b", {.WidthFixed}, 2 * (ui.KNOB_SIZE + 14) + 20)
		im.TableSetupColumn("c", {.WidthFixed}, 3 * (ui.KNOB_SIZE + 14) + 20)
		im.TableNextColumn()
		section(a, "Track", false)
	}
	pad_name_colour(a, i)

	section(a, "Input", !wide)
	input := i32(pad.input)
	inputs := [3]cstring{"Inputs 1 + 2", "Input 1", "Input 2"}
	im.SetNextItemWidth(min(180, im.GetContentRegionAvail().x))
	if ui.combo_char("##input", &input, &inputs[0], len(inputs)) {
		p := pad
		p.input = pm.Audio_Input(input)
		pm.set_pad(m, i, .Input, "Set Input", p)
		app.seal(&m.history)
	}
	im.SameLine(0, 16)
	armed := pm.audio_armed(m, i)
	if ui.toggle("Arm", &armed) do pm.arm_audio(m, i, armed)
	if im.IsItemHovered() do im.SetTooltip("Armed, it records while you record (Cmd+R)")
	im.SameLine(0, 16)
	mon := pad.monitor
	if ui.toggle("Monitor", &mon) {
		p := pad
		p.monitor = mon
		pm.set_pad(m, i, .Monitor, "Monitor", p)
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("Armed, it plays its input through its strip (use headphones)")
	if a.host.graph.settings.input_channels == 0 do im.TextColored(transmute(im.Vec4)ui.theme().warn, "No audio input: the device was opened without one")

	if wide do im.TableNextColumn()
	section(a, "Sound", !wide)
	knob_f32(a, "Volume", &pad.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	im.SameLine(0, 14)
	knob_f32(a, "Pan", &pad.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	if wide do im.TableNextColumn()
	section(a, "EQ", !wide)
	knob_f32(a, "Low", &pad.eq[0], -15, 15, 0, "%+.1f dB", .Eq_Low, "Set EQ Low")
	im.SameLine(0, 14)
	knob_f32(a, "Mid", &pad.eq[1], -15, 15, 0, "%+.1f dB", .Eq_Mid, "Set EQ Mid")
	im.SameLine(0, 14)
	knob_f32(a, "High", &pad.eq[2], -15, 15, 0, "%+.1f dB", .Eq_High, "Set EQ High")
	im.Spacing()
	im.Spacing()
	im.BeginDisabled(c.sample == 0)
	if im.Button(ui.ICON_ERASER + "  Clear Take") do pm.clear_clip(m, i)
	im.EndDisabled()
	im.SameLine()
	if im.Button(ui.ICON_TRASH + "  Clear Pad") do pm.clear_pad(m, i)
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

// A small heading (`gap`: space above it, when it follows another).
section :: proc(a: ^App, title: cstring, gap := true) {
	if gap {
		im.Spacing()
		im.Spacing()
	}
	// Drawn rather than laid out as text: in a table's row, text would sit
	// on the row's baseline (lower, beside framed controls).
	im.PushFontFloat(a.platform.fonts.semibold, 13)
	pos := im.GetCursorScreenPos()
	im.DrawList_AddText(im.GetWindowDrawList(), pos, ui.col(ui.theme().text_dim), title)
	im.Dummy({1, im.GetTextLineHeight()})
	im.PopFont()
	im.Separator()
	im.Spacing()
}

_ :: fmt.tprint
_ :: strings.clone
