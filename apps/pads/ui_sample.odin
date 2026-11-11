package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

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
		im.TextDisabled("%s", fmt.ctprintf("No sample on %s", pm.pad_label(i)))
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
	draw_playback(a)
	draw_warp(a)
	draw_tools(a)
	im.Spacing()

	start, end := pm.pad_region(m, i)
	markers := make([dynamic]ui.Marker, context.temp_allocator)
	t := ui.theme()
	append(&markers, ui.Marker{frame = start, color = t.ok, label = "S", drag = true}, ui.Marker{frame = end, color = t.danger, label = "E", drag = true})
	// The fades: a handle each, dragged in from the region's ends.
	fade_c := ui.rgb(0xd0d4dc)
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
	wave_size := im.Vec2{avail.x, max(avail.y - 4, 80)}
	e := ui.waveform("wave", w.peaks, w.frames, &w.view, markers[:], &w.selection, wave_size, ui.rgb(pad.color), head if playing else -1, {pyramid = &w.pyramid})
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
}

draw_tools :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	tools := &a.tools
	if tools.chop_parts == 0 do tools.chop_parts = 8
	if tools.sensitivity == 0 do tools.sensitivity = 0.5
	if tools.beats == 0 do tools.beats = 4
	sel := a.wave.selection
	has_sel := sel[1] > sel[0]
	edit :: proc(a: ^App, e: pm.Audio_Edit, sel: [2]i64) {
		if pm.edit_audio(&a.m, a.selected, e, sel) != .None do ui.toast(&a.ws.toasts, .Error, "That edit could not be made")
	}
	if ui.icon_button(ui.ICON_CROP, "Crop to the selection (or region)") do edit(a, .Crop, sel)
	im.SameLine()
	if !has_sel do im.BeginDisabled()
	if ui.icon_button(ui.ICON_SCISSORS, "Delete the selection") do edit(a, .Delete, sel)
	im.SameLine()
	if ui.icon_button(ui.ICON_VOLUME_X, "Silence the selection") do edit(a, .Silence, sel)
	if !has_sel do im.EndDisabled()
	im.SameLine()
	if ui.icon_button(ui.ICON_TRENDING_UP, "Fade in over the selection") do edit(a, .Fade_In, sel)
	im.SameLine()
	if ui.icon_button(ui.ICON_TRENDING_DOWN, "Fade out over the selection") do edit(a, .Fade_Out, sel)
	im.SameLine()
	if ui.icon_button(ui.ICON_MAXIMIZE_2, "Normalize") do edit(a, .Normalize, sel)
	im.SameLine()
	if ui.icon_button(ui.ICON_ARROW_LEFT_RIGHT, "Reverse the audio") do edit(a, .Reverse, sel)
	im.SameLine()
	if ui.icon_button(ui.ICON_SCAN_LINE, "Trim silence from both ends") do edit(a, .Trim, sel)
	im.SameLine()
	if !has_sel do im.BeginDisabled()
	if ui.icon_button(ui.ICON_COPY_PLUS, "Put the selection on the next empty pad") {
		if b := pm.bounce_to_pad(m, i, sel); b >= 0 do a.selected = b
	}
	if !has_sel do im.EndDisabled()

	// Chop.
	segw := ui.button_width("Transients") + ui.button_width("Equal") + 8
	ui.flow(segw, 24)
	ui.segmented("chop_mode", {"Transients", "Equal"}, &tools.chop_mode)
	ui.flow(130)
	im.SetNextItemWidth(130)
	if tools.chop_mode == 0 {
		im.DragFloat("##sens", &tools.sensitivity, 0.005, 0.05, 1, "Sensitivity %.2f", {.ClampOnInput})
	} else {
		im.DragInt("##parts", &tools.chop_parts, 0.1, 2, 32, "%d parts", {.ClampOnInput})
	}
	chop_label :: ui.ICON_SLICE + "  Chop"
	ui.flow(ui.button_width(chop_label))
	if im.Button(chop_label) {
		how: pm.Chop = pm.Chop_Transients{f64(tools.sensitivity)} if tools.chop_mode == 0 else pm.Chop_Equal{int(tools.chop_parts)}
		n := pm.chop_to_pads(m, i, how)
		ui.toast(&a.ws.toasts, .Success if n > 0 else .Warning, fmt.tprintf("Chopped into %d pads", n))
	}

	// Stretch.
	stretch_label :: ui.ICON_MOVE_HORIZONTAL + "  Stretch to beats"
	ui.flow(100 + im.GetStyle().ItemSpacing.x + ui.button_width(stretch_label), 24)
	im.SetNextItemWidth(100)
	im.DragInt("##beats", &tools.beats, 0.1, 1, 64, "%d beats", {.ClampOnInput})
	im.SameLine()
	if im.Button(stretch_label) {
		if pm.stretch_to_beats(m, i, f64(tools.beats)) == .None {
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Stretched to %d beats at %.0f BPM", tools.beats, m.project.bpm))
		} else {
			ui.toast(&a.ws.toasts, .Error, "Too short to stretch")
		}
	}

	// Record onto the pad.
	ui.flow(im.GetFrameHeight(), 24)
	recording := a.rec.active
	if ui.icon_button(ui.ICON_CIRCLE, "Record the input onto this pad", on = recording, color = ui.rgb(0xf0555a)) {
		if recording {
			pm.record_stop(&a.rec)
		} else if pm.record_start(m, &a.rec, i) != .None {
			ui.toast(&a.ws.toasts, .Warning, "No audio input to record from")
		}
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
	if im.Button(ui.ICON_ERASER + "  Clear Take") do pm.clear_clip(m, i)
	im.Spacing()
	head: i64 = -1
	if rel, playing := pm.position(&m.engine); playing do head = i64(rel * s.rate * 60 / c.bpm) % max(s.frames, 1)
	avail := im.GetContentRegionAvail()
	ui.waveform("wave", w.peaks, w.frames, &w.view, nil, &w.selection, {avail.x, max(avail.y - 4, 80)}, ui.rgb(pad.color), head, {pyramid = &w.pyramid})
	item_menu(a, {kind = .Take, index = i}, "##takemenu")
}
