package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:sampler"
import "fire:stretch"


// How the selected pad plays its sample: one-shot, gate, loop or hold;
// reversed; its choke group; a loop's mode and crossfade. One row over the
// Sample tab.
draw_playback :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	pad := m.project.pads[i]
	s := pm.pad_sample(m, i)
	if s == nil do return
	mode := int(pad.mode)
	if ui.segmented("mode", {"One-shot", "Gate", "Loop", "Hold"}, &mode) do pa.pad_set_mode(&a.api, i64(i), pa.Pad_Mode(mode))
	im.SameLine(0, 16)
	rev := pad.reverse
	if ui.toggle("Reverse", &rev) {
		p := pad
		p.reverse = rev
		pm.set_pad(m, i, .Reverse, "Reverse", p)
		app.seal(&m.history)
	}
	// Its choke group (every selected pad's): a hit stops the others
	// playing in its group (open and closed hats).
	im.SameLine(0, 16)
	im.SetNextItemWidth(150)
	if ui.combo("##choke", fmt.ctprintf("%s  %s", ui.ICON_SCISSORS, "No choke" if pad.choke == 0 else fmt.tprintf("Choke group %d", pad.choke))) {
		for g in 0 ..= pm.CHOKE_GROUPS {
			if im.Selectable(fmt.ctprintf("%s###cg%d", "No choke group" if g == 0 else fmt.tprintf("Choke group %d", g), g), int(pad.choke) == g) do set_choke(a, selected_pads(a), g)
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Choke group: a pad's hit stops the others playing in its group (open and closed hi-hats)")
	if pad.mode == .Loop || pad.mode == .Hold {
		im.SameLine(0, 16)
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
}

// The selected pad's warp: on, it follows the tempo (made longer or
// shorter, not faster or slower): how (Beats, Tones, Complex, Re-pitch),
// its sample's own tempo (guessed; drag or type it), Beats' cuts and gaps;
// what it does now, or that it is rendering. One row under the playback.
draw_warp :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	pad := m.project.pads[i]
	if pm.pad_sample(m, i) == nil do return
	w := pad.warp
	on := w.on
	if ui.toggle("Warp", &on) {
		w.on = on
		pm.set_warp(m, i, w, "Warp On" if on else "Warp Off")
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("Warp: the sample follows the tempo, at its own pitch (made longer or shorter)")
	if !w.on {
		im.SameLine(0, 12)
		im.AlignTextToFramePadding()
		im.TextDisabled("Off: it plays as it is, whatever the tempo")
		return
	}
	im.SameLine(0, 16)
	warp_settings(a)
}

// The selected pad's warp settings (when it is on): how, its sample's
// tempo (guessed, or dragged or typed), Beats' cuts and gaps, and what it
// does now. In a row.
warp_settings :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	pad := m.project.pads[i]
	t := ui.theme()
	w := pad.warp
	im.SetNextItemWidth(130)
	if ui.combo("##warpmode", fmt.ctprintf("%s  %s", ui.ICON_AUDIO_WAVEFORM, pm.WARP_MODE_NAMES[w.mode])) {
		tips := [stretch.Warp_Mode]cstring{
			.Beats   = "Drums and loops: cut at its hits, each played as it was (attacks exact)",
			.Tones   = "Voices, bass, pads: a spectral stretch of the whole (pitch kept)",
			.Complex = "Full mixes: the spectral stretch, started again at each hit (attacks crisp)",
			.Repitch = "Faster or slower, the pitch with it (a turntable)",
		}
		for mode in stretch.Warp_Mode {
			if im.Selectable(pm.WARP_MODE_NAMES[mode], mode == w.mode) {
				w.mode = mode
				pm.set_warp(m, i, w, "Warp Mode")
				app.seal(&m.history)
			}
			if im.IsItemHovered() do im.SetTooltip("%s", tips[mode])
		}
		im.EndCombo()
	}
	im.SameLine(0, 8)
	bpm := w.bpm
	e := ui.number_drag("sample bpm", &bpm, 20, 400, 1, 0.01, "Sample %.2f BPM", 160)
	if e.changed {
		w.bpm = bpm
		pm.set_warp(m, i, w, "Sample Tempo")
	}
	if e.ended do app.seal(&m.history)
	im.SameLine(0, 4)
	if ui.icon_button(ui.ICON_WAND_SPARKLES, "Guess the sample's tempo from its length") {
		w.bpm = 0
		pm.set_warp(m, i, w, "Sample Tempo")
		app.seal(&m.history)
	}
	if w.mode == .Beats {
		im.SameLine(0, 12)
		im.SetNextItemWidth(130)
		if ui.combo("##warpgrain", fmt.ctprintf("Cut: %s", pm.WARP_GRAIN_NAMES[w.grain])) {
			for g in stretch.Warp_Grain do if im.Selectable(pm.WARP_GRAIN_NAMES[g], g == w.grain) {
				w.grain = g
				pm.set_warp(m, i, w, "Warp Cuts")
				app.seal(&m.history)
			}
			im.EndCombo()
		}
		if im.IsItemHovered() do im.SetTooltip("Where Beats cuts it: at its hits, or on a grid of its own beats")
		im.SameLine(0, 12)
		fill := w.fill_gaps
		if ui.toggle("Fill gaps", &fill) {
			w.fill_gaps = fill
			pm.set_warp(m, i, w, "Fill Gaps")
			app.seal(&m.history)
		}
		if im.IsItemHovered() do im.SetTooltip("Slower: a gap after each piece, filled by looping its tail (off: silence)")
	}
	// What it does now: how much longer, at which tempo; or rendering.
	im.SameLine(0, 14)
	im.AlignTextToFramePadding()
	tempo := m.engine.warp_bpm if m.engine.warp_bpm > 0 else m.project.bpm
	r := pm.warp_ratio(pad, tempo)
	if pm.warp_rendering(&m.engine, i) {
		dots := [4]string{"", ".", "..", "..."}
		im.TextColored(transmute(im.Vec4)t.warn, "%s", fmt.ctprintf("Rendering%s", dots[(a.frame / 15) % 4]))
	} else {
		im.TextDisabled("%s", fmt.ctprintf("%.2f×", r))
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s at %.1f BPM", "As it is" if r == 1 else fmt.tprintf("%.0f%% as long", r * 100), tempo))
	}
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
		pa.history_gesture_begin(&a.api) // (the keys typed: one step)
		pa.pad_set_name(&a.api, i64(i), strings.truncate_to_byte(string(name_buf[:]), 0))
	}
	if im.IsItemDeactivatedAfterEdit() do pa.history_gesture_end(&a.api)
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
		im.TextDisabled("%s", fmt.ctprintf("%s: a take of %.2f s at %.0f BPM", pm.sequence_name(&m.project, seq - 1), f64(s.frames) / s.rate, c.bpm))
	} else {
		im.TextDisabled("%s", fmt.ctprintf("%s: no take yet (arm it, then record)", pm.sequence_name(&m.project, seq - 1)))
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
	track_io_section(a, i) // armed, its input channels and their level
	im.SameLine(0, 16)
	if pad.input.from == .Interface {
		mon := int(pad.monitor)
		if ui.segmented("monitor", {"Auto", "In", "Off"}, &mon) do pa.pad_set_monitor(&a.api, i64(i), pa.Monitor(mon))
		if im.IsItemHovered() do im.SetTooltip("Monitoring, its input through its strip and effects: Auto while it is armed, In always, Off never (you hear it on the interface). Use headphones.")
	} else {
		im.TextDisabled("%s", cstring("No input: nothing to monitor") if pad.input.from == .None else cstring("Resampling: not monitored"))
		if im.IsItemHovered() do im.SetTooltip("It records what plays inside (lined up after its source's effects). You hear the source itself, so its input isn't played through it again.")
	}
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
	if im.Button(ui.ICON_TRASH + "  Clear Pad") do pa.pad_clear(&a.api, i64(i))
}

// A knob for one f32 field of the selected pad, as an undoable edit.
@(private)
knob_f32 :: proc(a: ^App, label: cstring, value: ^f32, lo, hi, default: f32, format: cstring, field: pm.Pad_Field, step: string, log_scale := false, snap: f32 = 0) {
	m := &a.m
	v := value^
	knob_target(a, pad_field_target(a, a.selected, field))
	e := ui.knob(label, &v, lo, hi, default, format, log_scale = log_scale, step = snap)
	knob_target(a, {})
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
