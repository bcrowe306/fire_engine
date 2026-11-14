package pads

import "core:fmt"
import "core:strings"
import "core:math"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:sampler"

// What the sample editor keeps between frames.
Wave_State :: struct {
	sample:    app.Id, // whose peaks these are
	peaks:     []ui.Peak,
	pyramid:   ui.Peak_Pyramid, // the same sound at every zoom
	frames:    i64,
	view:      ui.Wave_View,
	selection: [2]i64,
}

// Tool settings in the sample editor's toolbar.
Tool_State :: struct {
	chop_mode:   int, // 0 = transients, 1 = equal
	chop_parts:  i32,
	sensitivity: f32,
	beats:       i32,
}

// The selected pad's sample: its waveform with the region and loop as
// markers to drag, a selection for the edits, and the tools.
draw_sample :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	i := a.selected
	pad := m.project.pads[i]
	if pad.kind == .Audio {
		draw_take(a, i)
		return
	}
	if pad.kind == .Slicer {
		draw_slicer(a, i)
		return
	}
	s := pm.pad_sample(m, i)
	if s == nil {
		draw_empty_pad(a, i)
		return
	}
	w := &a.wave
	if w.sample != pad.sample {
		delete(w.peaks)
		w.peaks = nil
		ui.peak_pyramid_destroy(&w.pyramid)
		w.sample, w.frames = pad.sample, s.frames
		w.view, w.selection = {}, {}
		if audio, ok := pm.pad_audio(m, i); ok && len(audio.channels) > 0 {
			mono := make([]f32, len(audio.channels[0]), context.temp_allocator)
			for ch in audio.channels do for &v, k in mono do v += ch[k] / f32(len(audio.channels))
			w.peaks = ui.peaks_of(mono, 4096)
		w.pyramid = ui.peak_pyramid_make(mono) // (every zoom, at the pixels' resolution)
		}
	}
	// A toolbar on top, the waveform taking the room, the knobs at the foot.
	draw_sample_bar(a)

	start, end := pm.pad_region(m, i)
	markers := make([dynamic]ui.Marker, context.temp_allocator)
	t := ui.theme()
	append(&markers, ui.Marker{frame = start, color = t.ok, label = "S", drag = true}, ui.Marker{frame = end, color = t.danger, label = "E", drag = true})
	// The fades: a handle each, dragged in from the region's ends.
	fade_c := ui.mix(t.text, t.text_dim, 0.5)
	append(&markers, ui.Marker{frame = start + pad.fade_in, color = fade_c, drag = true, fade = true, from = start})
	append(&markers, ui.Marker{frame = end - pad.fade_out, color = fade_c, drag = true, fade = true, from = end})
	looping := pad.mode == .Loop || pad.mode == .Hold
	if looping {
		ls := pad.loop_start if pad.loop_end > 0 else start
		le := pad.loop_end if pad.loop_end > 0 else end
		append(&markers, ui.Marker{frame = ls, color = t.warn, label = "L", drag = true}, ui.Marker{frame = le, color = t.warn, label = "L", drag = true})
	}
	avail := im.GetContentRegionAvail()
	head, playing := pm.pad_playhead(&m.engine, i)
	wave_at := im.GetCursorScreenPos()
	knobs_h := sample_knobs_height()
	wave_size := im.Vec2{avail.x, max(avail.y - knobs_h - 8, 80)}
	// While it plays: its sound's spectrum, faint in its colour, behind.
	spec: []f32
	pm.watch_sound(&m.engine, i)
	if playing do spec = spectrum(a)
	e := ui.waveform("wave", w.peaks, w.frames, &w.view, markers[:], &w.selection, wave_size, ui.rgb(pad.color), head if playing else -1, {pyramid = &w.pyramid, backdrop = spec})
	// Warped: the sample's own beats over it (bars stronger), from its
	// start, so you see what the tempo will follow.
	if pad.warp.on && pad.warp.bpm > 0 && w.view.end > w.view.start {
		if smp := pm.pad_sample(m, i); smp != nil {
			dl := im.GetWindowDrawList()
			beat := smp.rate * 60 / pad.warp.bpm
			first := max(math.ceil((w.view.start - f64(start)) / beat), 0)
			im.DrawList_PushClipRect(dl, wave_at, {wave_at.x + wave_size.x, wave_at.y + wave_size.y}, true)
			for k := first; f64(start) + k * beat <= w.view.end; k += 1 {
				f := f64(start) + k * beat
				x := wave_at.x + f32((f - w.view.start) / (w.view.end - w.view.start)) * wave_size.x
				bar := int(k) % 4 == 0
				im.DrawList_AddLine(dl, {x, wave_at.y + (0 if bar else wave_size.y * 0.8)}, {x, wave_at.y + wave_size.y}, ui.col(ui.with_alpha(t.warn, 0.55 if bar else 0.35)), 1.5 if bar else 1)
				if bar do im.DrawList_AddText(dl, {x + 3, wave_at.y + wave_size.y - 18}, ui.col(ui.with_alpha(t.warn, 0.8)), fmt.ctprintf("%d", int(k) / 4 + 1))
			}
			im.DrawList_PopClipRect(dl)
		}
	}
	if e.moved {
		p := pad
		field := pm.Pad_Field.Region
		name := "Move Marker"
		switch e.marker {
		case 0: p.start = min(e.marker_to, end - 1)
		case 1: p.end = max(e.marker_to, start + 1)
		case 2: p.fade_in = clamp(e.marker_to - start, 0, end - start)
		case 3: p.fade_out = clamp(end - e.marker_to, 0, end - start)
		case 4: p.loop_start, p.loop_end = min(e.marker_to, end - 2), max(pad.loop_end if pad.loop_end > 0 else end, e.marker_to + 2)
		case 5: p.loop_end, p.loop_start = max(e.marker_to, start + 2), pad.loop_start if pad.loop_end > 0 else start
		}
		if e.marker == 2 || e.marker == 3 do field, name = .Fades, "Fade In" if e.marker == 2 else "Fade Out"
		if e.marker >= 4 do field, name = .Loop, "Move Loop"
		pm.set_pad(m, i, field, name, p)
	}
	if e.released do app.seal(&m.history)
	if e.clicked do w.selection = {}
	// The knobs: what you reach for most.
	im.SetCursorScreenPos({wave_at.x, wave_at.y + wave_size.y + 8})
	draw_sample_knobs(a)
}

// How tall the Sample page's knob row is.
sample_knobs_height :: proc() -> f32 {
	ui.text_push(.Label)
	defer ui.text_pop()
	return im.GetTextLineHeight() * 2 + ui.KNOB_SIZE + 8
}

// The Sample page's knobs: volume, pan, transpose, fine, attack, release
// (the same as the Global and Env tabs': they move together).
@(private)
draw_sample_knobs :: proc(a: ^App) {
	pad := &a.m.project.pads[a.selected]
	row := spread_begin(6, im.GetContentRegionAvail().x)
	spread_next(&row, "Volume")
	knob_f32(a, "Volume", &pad.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	spread_next(&row, "Pan")
	knob_f32(a, "Pan", &pad.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	spread_next(&row, "Transpose")
	knob_f32(a, "Transpose", &pad.pitch, -24, 24, 0, "%+.0f st", .Pitch, "Set Pitch", snap = 1)
	spread_next(&row, "Fine")
	a.voice_edit = pad.voice
	voice_knob(a, "Fine", &a.voice_edit.fine, -100, 100, 0, "%+.0f ct", int(Voice_Key.Fine), "Fine Tune")
	spread_next(&row, "Attack")
	knob_f32(a, "Attack", &pad.attack, 0.0005, 10, 0.001, "%.3f s", .Attack, "Set Attack", log_scale = true)
	spread_next(&row, "Release")
	knob_f32(a, "Release", &pad.release, 0.005, 20, 0.05, "%.2f s", .Release, "Set Release", log_scale = true)
}

// The Sample page's toolbar, one line: how it plays (a dropdown, with
// the loop's settings when it loops), Reverse, its choke group, Warp (its
// settings behind the arrow), Chop (into pads, behind its arrow), record
// onto it, and "…" for the edits and Stretch.
@(private)
draw_sample_bar :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	pad := m.project.pads[i]
	s := pm.pad_sample(m, i)
	if s == nil do return
	tools := &a.tools
	if tools.chop_parts == 0 do tools.chop_parts = 8
	if tools.sensitivity == 0 do tools.sensitivity = 0.5
	if tools.beats == 0 do tools.beats = 4
	// Narrow (a small window): the choke group and Chop shorter; past the
	// room, the line wraps rather than cut its end off.
	narrow := im.GetContentRegionAvail().x < 640
	gap: f32 = 4 if narrow else 8
	fh := im.GetFrameHeight()
	// How it plays.
	modes := [4]cstring{"One-shot", "Gate", "Loop", "Hold"}
	im.SetNextItemWidth(116 if narrow else 120)
	if ui.combo("##playmode", fmt.ctprintf("%s  %s", ui.ICON_PLAY, modes[int(pad.mode)])) {
		for name, k in modes {
			if im.Selectable(name, int(pad.mode) == k) do pa.pad_set_mode(&a.api, i64(i), pa.Pad_Mode(k))
		}
		if pad.mode == .Loop || pad.mode == .Hold {
			im.Separator()
			im.TextDisabled("The loop")
			lm := int(pad.loop_mode)
			if ui.segmented("loop_mode", {"Forward", "Ping-pong"}, &lm) {
				p := pad
				p.loop_mode = sampler.Loop_Mode(lm)
				pm.set_pad(m, i, .Loop_Mode, "Set Loop Mode", p)
				app.seal(&m.history)
			}
			xf := f64(pad.crossfade) / s.rate * 1000
			if e := ui.value_bar("crossfade", "Crossfade", &xf, 0, 500, 5, 1, "%.0f ms", 200); e.changed {
				p := pad
				p.crossfade = i64(xf * s.rate / 1000)
				pm.set_pad(m, i, .Crossfade, "Set Crossfade", p)
			} else if e.ended do app.seal(&m.history)
		}
		im.EndCombo()
	}
	ui.name("play mode")
	if im.IsItemHovered() do im.SetTooltip("How it plays: once through (One-shot), while held (Gate), round its loop while held (Loop), or until hit again (Hold)")
	ui.flow(ui.button_width("Reverse") + 20, gap)
	rev := pad.reverse
	if ui.toggle("Reverse", &rev) {
		p := pad
		p.reverse = rev
		pm.set_pad(m, i, .Reverse, "Reverse", p)
		app.seal(&m.history)
	}
	choke_w: f32 = 56 if narrow else 130
	ui.flow(choke_w, gap)
	im.SetNextItemWidth(choke_w)
	choke_text := ("" if pad.choke == 0 else fmt.tprintf("%d", pad.choke)) if narrow else ("No choke" if pad.choke == 0 else fmt.tprintf("Choke %d", pad.choke))
	if ui.combo("##choke", fmt.ctprintf("%s  %s", ui.ICON_SCISSORS, choke_text)) {
		for g in 0 ..= pm.CHOKE_GROUPS {
			if im.Selectable(fmt.ctprintf("%s###cg%d", "No choke group" if g == 0 else fmt.tprintf("Choke group %d", g), g), int(pad.choke) == g) do set_choke(a, selected_pads(a), g)
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Choke group: a pad's hit stops the others playing in its group (open and closed hi-hats)")
	// Warp: on or off here, its settings behind the arrow.
	ui.flow(ui.button_width("Warp") + 20 + (fh if pad.warp.on else 0), gap)
	w := pad.warp
	on := w.on
	if ui.toggle("Warp", &on) {
		w.on = on
		pm.set_warp(m, i, w, "Warp On" if on else "Warp Off")
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("Warp: the sample follows the tempo, at its own pitch (made longer or shorter)")
	if w.on {
		im.SameLine(0, 0)
		if ui.icon_button(ui.ICON_CHEVRON_DOWN, "Warp settings") do im.OpenPopup("##warpset")
		if im.BeginPopup("##warpset") {
			warp_settings(a)
			im.EndPopup()
		}
	}
	// Chop: how, behind its arrow.
	chop: cstring = ui.ICON_SLICE + "##Chop" if narrow else ui.ICON_SLICE + "  Chop"
	ui.flow(ui.button_width(chop), gap)
	if im.Button(chop) do im.OpenPopup("##chop")
	ui.name("Chop")
	if im.IsItemHovered() do im.SetTooltip("Chop it into pads: at its hits, or into equal parts")
	if im.BeginPopup("##chop") {
		ui.segmented("chop_mode", {"Transients", "Equal"}, &tools.chop_mode)
		if tools.chop_mode == 0 {
			sens := f64(tools.sensitivity)
			if ui.value_bar("chop sensitivity", "Sensitivity", &sens, 0.05, 1, 0.05, 0.01, "%.2f", 200).changed do tools.sensitivity = f32(sens)
		} else {
			parts := f64(tools.chop_parts)
			if ui.value_bar("chop parts", "Parts", &parts, 2, 32, 1, 1, "%.0f", 200).changed do tools.chop_parts = i32(parts)
		}
		if im.Button(ui.ICON_SLICE + "  Chop into pads") {
			how: pm.Chop = pm.Chop_Transients{f64(tools.sensitivity)} if tools.chop_mode == 0 else pm.Chop_Equal{int(tools.chop_parts)}
			n := pm.chop_to_pads(m, i, how)
			ui.toast(&a.ws.toasts, .Success if n > 0 else .Warning, fmt.tprintf("Chopped into %d pads", n))
			im.CloseCurrentPopup()
		}
		ui.name("chop into pads")
		im.EndPopup()
	}
	// Record onto it.
	ui.flow(fh, gap)
	recording := a.rec.active
	if ui.icon_button(ui.ICON_CIRCLE, "Record the input onto this pad", on = recording, color = ui.rgb(0xf0555a)) {
		if recording {
			pa.recording_sample_stop(&a.api)
		} else if pa.recording_sample_start(&a.api, i64(i), .Hold) != .Ok {
			ui.toast(&a.ws.toasts, .Warning, "No audio input to record from")
		}
	}
	// The rest: the edits and Stretch.
	ui.flow(fh, gap)
	if ui.icon_button(ui.ICON_ELLIPSIS, "More: the edits (crop, fades, normalize...) and Stretch") do im.OpenPopup("##sampletools")
	ui.name("more sample tools")
	if im.BeginPopup("##sampletools") {
		sel := a.wave.selection
		has_sel := sel[1] > sel[0]
		edit :: proc(a: ^App, e: pm.Audio_Edit, sel: [2]i64) {
			if pm.edit_audio(&a.m, a.selected, e, sel) != .None do ui.toast(&a.ws.toasts, .Error, "That edit could not be made")
		}
		item :: proc(icon, label: string, tip: cstring, enabled := true) -> bool {
			clicked := im.MenuItem(fmt.ctprintf("%s  %s###%s", icon, label, tip), nil, false, enabled)
			ui.name(label)
			if im.IsItemHovered({.AllowWhenDisabled}) do im.SetTooltip("%s", tip)
			return clicked
		}
		if item(ui.ICON_CROP, "Crop", "Crop to the selection (or region)") do edit(a, .Crop, sel)
		if item(ui.ICON_SCISSORS, "Delete", "Delete the selection", has_sel) do edit(a, .Delete, sel)
		if item(ui.ICON_VOLUME_X, "Silence", "Silence the selection", has_sel) do edit(a, .Silence, sel)
		if item(ui.ICON_TRENDING_UP, "Fade in", "Fade in over the selection") do edit(a, .Fade_In, sel)
		if item(ui.ICON_TRENDING_DOWN, "Fade out", "Fade out over the selection") do edit(a, .Fade_Out, sel)
		if item(ui.ICON_MAXIMIZE_2, "Normalize", "Normalize") do edit(a, .Normalize, sel)
		if item(ui.ICON_ARROW_LEFT_RIGHT, "Reverse audio", "Reverse the audio itself (a new file)") do edit(a, .Reverse, sel)
		if item(ui.ICON_SCAN_LINE, "Trim", "Trim silence from both ends") do edit(a, .Trim, sel)
		if item(ui.ICON_COPY_PLUS, "To a pad", "Put the selection on the next empty pad", has_sel) {
			if b := pm.bounce_to_pad(m, i, sel); b >= 0 do a.selected = b
		}
		im.Separator()
		beats := f64(tools.beats)
		if ui.value_bar("stretch beats", "Beats", &beats, 1, 64, 1, 1, "%.0f", 160).changed do tools.beats = i32(beats)
		im.SameLine()
		if im.Button(ui.ICON_MOVE_HORIZONTAL + "  Stretch to beats") {
			if pm.stretch_to_beats(m, i, f64(tools.beats)) == .None {
				ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Stretched to %d beats at %.0f BPM", tools.beats, m.project.bpm))
			} else {
				ui.toast(&a.ws.toasts, .Error, "Too short to stretch")
			}
		}
		ui.name("Stretch to beats")
		im.EndPopup()
	}
}

// An audio pad's take in the current sequence: its waveform, a sequence
// long, with the playhead while it plays.
@(private)
draw_take :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	c := pm.current_clip(m, i)
	s := app.store_get(&m.project.samples, c.sample)
	if s == nil {
		im.TextDisabled("%s", fmt.ctprintf("No take on %s in sequence %d: arm it (Pad tab or its strip), then record", pm.pad_label(i), m.project.slot + 1))
		return
	}
	if c.part != 0 {
		// An edited part: what plays (the Audio tab edits it).
		x := pm.part_of(&m.project, m.project.slot, i)
		im.AlignTextToFramePadding()
		im.TextDisabled("%s", fmt.ctprintf("%s · %d region%s of %d take%s at %.0f BPM", pm.sequence_name(&m.project, m.project.slot), x.count, "" if x.count == 1 else "s", x.take_count, "" if x.take_count == 1 else "s", c.bpm))
		im.SameLine()
		if im.Button(ui.ICON_AUDIO_LINES + "  Edit") {
			a.seq.mode = .Audio
			ui.panel_focus(&a.ws, "sequence")
		}
		ui.name("edit audio")
		if im.IsItemHovered() do im.SetTooltip("In the Sequence view's Audio tab")
		im.SameLine()
		if im.Button(ui.ICON_ERASER + "  Clear Take") do pa.audio_clear(&a.api, i64(i))
		im.Spacing()
		avail := im.GetContentRegionAvail()
		pos := im.GetCursorScreenPos()
		size := im.Vec2{avail.x, max(avail.y - 4, 80)}
		dl := im.GetWindowDrawList()
		im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.WAVE_BG), 4)
		length := pm.seq_beats(&m.project, pm.current_sequence(m))
		draw_part(a, dl, m.project.slot, i, pos, {pos.x + size.x, pos.y + size.y}, 0, length, ui.rgb(pad.color))
		if rel, playing := pm.position(&m.engine); playing {
			xx := pos.x + f32(rel / length) * size.x
			im.DrawList_AddLine(dl, {xx, pos.y}, {xx, pos.y + size.y}, ui.col(ui.theme().accent), 2)
		}
		im.InvisibleButton("##partwave", size)
		ui.name("wave")
		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			a.seq.mode = .Audio
			ui.panel_focus(&a.ws, "sequence")
		}
		item_menu(a, {kind = .Take, index = i}, "##takemenu")
		return
	}
	w := &a.wave
	if w.sample != c.sample {
		delete(w.peaks)
		w.peaks = nil
		ui.peak_pyramid_destroy(&w.pyramid)
		w.sample, w.frames = c.sample, s.frames
		w.view, w.selection = {}, {}
		if audio, ok := pm.sample_audio(m, c.sample); ok && len(audio.channels) > 0 {
			mono := make([]f32, len(audio.channels[0]), context.temp_allocator)
			for ch in audio.channels do for &v, k in mono do v += ch[k] / f32(len(audio.channels))
			w.peaks = ui.peaks_of(mono, 4096)
		w.pyramid = ui.peak_pyramid_make(mono) // (every zoom, at the pixels' resolution)
		}
	}
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", fmt.ctprintf("%s · %.2f s at %.0f BPM", pm.sequence_name(&m.project, m.project.slot), f64(s.frames) / s.rate, c.bpm))
	im.SameLine()
	if im.Button(ui.ICON_ERASER + "  Clear Take") do pa.audio_clear(&a.api, i64(i))
	im.Spacing()
	head: i64 = -1
	if rel, playing := pm.position(&m.engine); playing do head = i64(rel * s.rate * 60 / c.bpm) % max(s.frames, 1)
	avail := im.GetContentRegionAvail()
	ui.waveform("wave", w.peaks, w.frames, &w.view, nil, &w.selection, {avail.x, max(avail.y - 4, 80)}, ui.rgb(pad.color), head, {pyramid = &w.pyramid})
	item_menu(a, {kind = .Take, index = i}, "##takemenu")
}

// An empty pad's page: what to put on it. Browse (the Library, to drop a
// sound on it), Record (an audio track), Synth, Slicer (empty: a sound
// dropped on it is sliced), or a plug-in instrument.
draw_empty_pad :: proc(a: ^App, i: int) {
	ui.text_push(.Heading)
	im.Text("%s", fmt.ctprintf("%s is empty", pm.pad_label(i)))
	ui.text_pop()
	im.TextDisabled("Drop a sound on it, or start one:")
	im.Spacing()
	choice :: proc(label: cstring, tip: cstring) -> bool {
		clicked := im.Button(label, {0, im.GetFrameHeight() * 1.6})
		ui.name(string(label)[strings.index(string(label), "  ") + 2:] if strings.contains(string(label), "  ") else string(label))
		if im.IsItemHovered() do im.SetTooltip("%s", tip)
		return clicked
	}
	row_x := im.GetCursorScreenPos().x
	if choice(ui.ICON_FOLDER_OPEN + "  Browse", "Show the Library's Browser: drag a sound onto the pad, or select it and press Enter") do library_show(a, 0)
	im.SameLine()
	if choice(ui.ICON_MIC + "  Record", "Make it an audio track, to record into") do put_device(a, i, "inst audio")
	im.SameLine()
	if choice(ui.ICON_AUDIO_WAVEFORM + "  Synth", "Make it a synth") do put_device(a, i, "inst synth")
	im.SameLine()
	if choice(ui.ICON_SCISSORS + "  Slicer", "Make it an empty slicer: a sound dropped on it is sliced, one slice a key") do put_device(a, i, "inst slicer")
	im.SameLine()
	if choice(ui.ICON_PLUG + "  Plug-in", "A plug-in instrument on it") do im.OpenPopup("##emptyplugins")
	if im.BeginPopup("##emptyplugins") {
		insts := plugin_instruments(a)
		for e, k in insts do if im.MenuItem(fmt.ctprintf("%s###pi%d", e.name, k)) do put_device(a, i, fmt.tprintf("clapi %d", k))
		if len(insts) == 0 {
			im.TextDisabled("No plug-in instruments found yet")
			if im.MenuItem("Find plug-ins… (Settings)") do a.settings.open, a.settings.page = true, .Plugins
		}
		im.EndPopup()
	}
	// Hold to record: a sample into the pad while it is held (as an
	// Option-press of the pad), from the pad's input.
	row_w := im.GetItemRectMax().x - row_x
	im.Spacing()
	recording := a.rec.active && a.rec.pad == i
	t := ui.theme()
	if recording {
		im.PushStyleColorVec4(.Button, transmute(im.Vec4)ui.mix(t.raised, t.danger, 0.6))
		im.PushStyleColorVec4(.ButtonHovered, transmute(im.Vec4)ui.mix(t.raised, t.danger, 0.7))
		im.PushStyleColorVec4(.ButtonActive, transmute(im.Vec4)t.danger)
	}
	hold_label: cstring = ui.ICON_CIRCLE_DOT + "  Recording… (let go to stop)###holdrec" if recording else ui.ICON_CIRCLE_DOT + "  Hold to Record###holdrec" // (one id: the press is kept)
	im.Button(hold_label, {max(row_w, 200), im.GetFrameHeight() * 1.6})
	if recording do im.PopStyleColor(3)
	ui.name("Hold to Record")
	if im.IsItemActivated() do sample_press(a, i, true)
	if im.IsItemDeactivated() do sample_release(a, i)
	if im.IsItemHovered() && !recording do im.SetTooltip("Hold it: a sample is recorded into the pad from its input while you hold (as Option-pressing the pad)")
}
