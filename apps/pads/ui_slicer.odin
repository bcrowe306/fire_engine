package pads

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:stretch"

// The slicer page (a slicer pad's first tab): how it plays (mono or poly,
// thru, gate, its base note, fades, velocity), its warp, how it is sliced
// (and slicing again), the waveform with a marker a slice to drag (double-
// click adds one, right-click takes one away) and a level line a slice,
// and the selected slice's own settings.
Slicer_State :: struct {
	selected:  int, // the slice whose settings show
}

// Pad `i` as a slicer (empty: a place to drop a sample, or record).
draw_slicer :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	st := &a.slicer_ui
	t := ui.theme()
	s := pm.pad_sample(m, i)
	if s == nil {
		draw_empty_slicer(a, i)
		return
	}
	sl := pad.slicer
	if st.selected >= sl.count do st.selected = max(sl.count - 1, 0)
	w := &a.wave
	wave_peaks(a, i)

	// How it plays.
	mono := 0 if sl.mono else 1
	if ui.segmented("slice_voices", {"Mono", "Poly"}, &mono) {
		n := sl
		n.mono = mono == 0
		pm.set_slicer(m, i, n, "Mono" if n.mono else "Poly")
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("Mono: a slice cuts the one before off. Poly: they play together")
	im.SameLine(0, 14)
	thru := sl.thru
	if ui.toggle("Thru", &thru) {
		n := sl
		n.thru = thru
		pm.set_slicer(m, i, n, "Thru")
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("Thru: a slice plays on past its end, to the end of the sample")
	im.SameLine(0, 14)
	gate := sl.gate
	if ui.toggle("Gate", &gate) {
		n := sl
		n.gate = gate
		pm.set_slicer(m, i, n, "Gate")
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("Gate: a slice stops when its key is let go (else it plays to its end)")
	ui.flow(150, 14)
	base := f64(sl.base)
	if e := ui.number_drag("base note", &base, 0, 127, 1, 1, fmt.ctprintf("From %s (%%.0f)", ui.note_name(int(sl.base))), 150); e.changed {
		n := sl
		n.base = u8(base)
		pm.set_slicer(m, i, n, "Base Note")
	} else if e.ended do app.seal(&m.history)
	if im.IsItemHovered() do im.SetTooltip("The key of slice 1 (the next key plays slice 2...)")
	ui.flow(256, 14)
	fi := f64(sl.fade_in_ms)
	if e := ui.number_drag("fade in", &fi, 0, 200, 0.5, 0.1, "Fade in %.1f ms", 120); e.changed {
		n := sl
		n.fade_in_ms = f32(fi)
		pm.set_slicer(m, i, n, "Fade In")
	} else if e.ended do app.seal(&m.history)
	im.SameLine(0, 6)
	fo := f64(sl.fade_out_ms)
	if e := ui.number_drag("fade out", &fo, 0, 500, 0.5, 0.1, "Fade out %.1f ms", 130); e.changed {
		n := sl
		n.fade_out_ms = f32(fo)
		pm.set_slicer(m, i, n, "Fade Out")
	} else if e.ended do app.seal(&m.history)
	if im.IsItemHovered() do im.SetTooltip("Each slice fades in and out by these (no clicks where it is cut)")
	ui.flow(130, 14)
	vel := f64(pad.voice.velocity * 100)
	if e := ui.number_drag("velocity", &vel, 0, 100, 1, 0.1, "Velocity %.0f%%", 130); e.changed {
		p := pad
		p.voice.velocity = f32(vel / 100)
		pm.set_pad(m, i, .Voice, "Velocity", p)
	} else if e.ended do app.seal(&m.history)
	if im.IsItemHovered() do im.SetTooltip("Velocity sensitivity: 0% every hit as loud; 50% as hard as it is hit; more, softer hits softer still")

	draw_warp(a)

	// How it is sliced.
	by := int(sl.by)
	if ui.segmented("slice_by", {"Transients", "Beats", "Equal", "Manual"}, &by) && pm.Slice_By(by) != .Manual {
		pm.slice_pad(m, i, pm.Slice_By(by))
		ui.toast(&a.ws.toasts, .Info, fmt.tprintf("%d slices", m.project.pads[i].slicer.count))
	}
	if im.IsItemHovered() do im.SetTooltip("Slice again: at its hits, on a grid of its tempo, into equal parts (Manual: by hand)")
	im.SameLine(0, 10)
	sl = m.project.pads[i].slicer
	again := false
	#partial switch sl.by {
	case .Transients:
		sens := f64(sl.sensitivity * 100)
		if e := ui.number_drag("slice sensitivity", &sens, 0, 100, 1, 0.1, "Sensitivity %.0f%%", 150); e.changed {
			n := sl
			n.sensitivity = f32(sens / 100)
			pm.set_slicer(m, i, n, "Sensitivity")
		} else if e.ended do again = true
	case .Beats:
		names := [stretch.Warp_Grain]cstring{.Transients = "Bars", .Sixteenth = "1/16", .Eighth = "1/8", .Quarter = "1/4"}
		im.SetNextItemWidth(100)
		if ui.combo("##slicegrid", names[sl.grain]) {
			for g in stretch.Warp_Grain do if im.Selectable(names[g], g == sl.grain) {
				n := sl
				n.grain = g
				pm.set_slicer(m, i, n, "Grid")
				again = true
			}
			im.EndCombo()
		}
	case .Equal:
		parts := f64(sl.parts)
		if e := ui.number_drag("slice parts", &parts, 1, pm.MAX_SLICER_SLICES, 1, 1, "%.0f slices", 110); e.changed {
			n := sl
			n.parts = int(parts)
			pm.set_slicer(m, i, n, "Parts")
		} else if e.ended do again = true
	}
	if again do pm.slice_pad(m, i, sl.by)
	sl = m.project.pads[i].slicer
	im.SameLine(0, 14)
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", fmt.ctprintf("%d slice%s from %s", sl.count, "" if sl.count == 1 else "s", ui.note_name(int(sl.base))))
	im.SameLine(0, 14)
	if ui.icon_button(ui.ICON_LIST_MUSIC, "Slices to a sequence: a new one, playing each slice where it falls") {
		if slot := pm.slices_to_sequence(m, i); slot >= 0 {
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Sequence %d plays the slices", slot + 1))
		} else {
			ui.toast(&a.ws.toasts, .Warning, "No empty sequence")
		}
	}
	ui.name("slices to sequence")
	im.SameLine(0, 4)
	if ui.icon_button(ui.ICON_GRID_2X2_PLUS, "The selected slice onto the next empty pad") do slice_out(a, i, st.selected)
	ui.name("slice to pad")
	im.SameLine(0, 4)
	if ui.icon_button(ui.ICON_AUDIO_WAVEFORM, "Make it a sampler again (its slices kept)") do pm.make_sampler(m, i)
	ui.name("to sampler")
	draw_tools_record(a, i)
	im.Spacing()

	// The waveform: the region's S and E, a marker a slice, a level a slice.
	lo, hi := pm.pad_region(m, i)
	markers := make([dynamic]ui.Marker, context.temp_allocator)
	append(&markers, ui.Marker{frame = lo, color = t.ok, label = "S", drag = true}, ui.Marker{frame = hi, color = t.danger, label = "E", drag = true})
	gains := make([dynamic]ui.Wave_Gain, context.temp_allocator)
	for k in 0 ..< sl.count {
		x := sl.slices[k]
		c := t.accent if k == st.selected else ui.rgb(0xd0d4dc)
		append(&markers, ui.Marker{frame = x.start, color = c, label = fmt.tprintf("%d", k + 1), drag = k > 0})
		append(&gains, ui.Wave_Gain{from = x.start, to = pm.slice_end(m, i, k), db = x.gain_db})
	}
	avail := im.GetContentRegionAvail()
	head, playing := pm.pad_playhead(&m.engine, i)
	beat := 0.0
	if pad.warp.on || pad.warp.bpm > 0 do beat = s.rate * 60 / pm.pad_bpm(m, i)
	inspector_h: f32 = 34
	opts := ui.Wave_Options{rate = s.rate, beat_frames = beat, beats_per_bar = m.project.transport.time_sig.num, scale = true, overview = true, editable = true, gains = gains[:], pyramid = &w.pyramid}
	e := ui.waveform("slices", w.peaks, w.frames, &w.view, markers[:], nil, {avail.x, max(avail.y - inspector_h - 8, 120)}, ui.rgb(pad.color), head if playing else -1, opts)
	if e.moved {
		switch e.marker {
		case 0:
			p := pad
			p.start = min(e.marker_to, hi - 1)
			pm.set_pad(m, i, .Region, "Move Marker", p)
		case 1:
			p := pad
			p.end = max(e.marker_to, lo + 1)
			pm.set_pad(m, i, .Region, "Move Marker", p)
		case:
			pm.move_slice(m, i, e.marker - 2, e.marker_to)
			st.selected = e.marker - 2
		}
	}
	if e.released do app.seal(&m.history)
	if e.add_at >= 0 && pm.add_slice(m, i, e.add_at) {
		for k in 0 ..< m.project.pads[i].slicer.count do if m.project.pads[i].slicer.slices[k].start == e.add_at do st.selected = k
	}
	if e.remove >= 3 do pm.remove_slice(m, i, e.remove - 2) // (slice 1, S and E stay)
	if e.gain >= 0 {
		x := sl.slices[e.gain]
		x.gain_db = e.gain_db
		pm.set_slice(m, i, e.gain, x, "Slice Level")
		st.selected = e.gain
	}
	if e.gain_released do app.seal(&m.history)
	// A click: that slice selected, and heard while held.
	if e.clicked {
		for k in 0 ..< sl.count do if e.click_frame >= sl.slices[k].start && e.click_frame < pm.slice_end(m, i, k) do st.selected = k
	}

	// The selected slice's own settings.
	if sl.count > 0 {
		k := st.selected
		x := sl.slices[k]
		im.AlignTextToFramePadding()
		im.Text("%s", fmt.ctprintf("Slice %d", k + 1))
		im.SameLine()
		im.TextDisabled("%s", fmt.ctprintf("%s · %.3f s", ui.note_name(int(sl.base) + k), f64(pm.slice_end(m, i, k) - x.start) / s.rate))
		im.SameLine(0, 14)
		if ui.icon_button(ui.ICON_PLAY, "Hear it") do audition_slice(a, i, k)
		ui.name("play slice")
		im.SameLine(0, 10)
		db := f64(x.gain_db)
		if e := ui.number_drag("slice level", &db, -24, 6, 0.5, 0.1, "Level %+.1f dB", 112); e.changed {
			x.gain_db = f32(db)
			pm.set_slice(m, i, k, x, "Slice Level")
		} else if e.ended do app.seal(&m.history)
		im.SameLine(0, 6)
		pitch := f64(x.pitch)
		if e := ui.number_drag("slice pitch", &pitch, -24, 24, 1, 0.1, "Pitch %+.1f st", 108); e.changed {
			x.pitch = f32(pitch)
			pm.set_slice(m, i, k, x, "Slice Pitch")
		} else if e.ended do app.seal(&m.history)
		im.SameLine(0, 6)
		pan := f64(x.pan * 100)
		if e := ui.number_drag("slice pan", &pan, -100, 100, 1, 1, "Pan %+.0f", 76); e.changed {
			x.pan = f32(pan / 100)
			pm.set_slice(m, i, k, x, "Slice Pan")
		} else if e.ended do app.seal(&m.history)
		ui.flow(90, 10)
		rev := x.reverse
		if ui.toggle("Reverse##slice", &rev) {
			x.reverse = rev
			pm.set_slice(m, i, k, x, "Slice Reverse")
			app.seal(&m.history)
		}
	}
}

// An empty slicer: a place to drop a sample (or record one).
@(private)
draw_empty_slicer :: proc(a: ^App, i: int) {
	t := ui.theme()
	avail := im.GetContentRegionAvail()
	pos := im.GetCursorScreenPos()
	size := im.Vec2{avail.x - im.GetFrameHeight() - 14, max(avail.y - 8, 80)} // (the record button beside it)
	im.InvisibleButton("##slicerdrop", size)
	ui.name("slicer drop")
	over := im.GetDragDropPayload() != nil && im.IsItemHovered({.AllowWhenBlockedByActiveItem})
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.with_alpha(t.accent, 0.12) if over else ui.WAVE_BG), t.radius)
	im.DrawList_AddRect(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.with_alpha(t.accent if over else t.text, 0.5 if over else 0.2)), t.radius, 2)
	msg: cstring = "An empty slicer: drop a sample here (from the browser or a pad), or record one"
	ts := im.CalcTextSize(msg)
	im.DrawList_AddText(dl, {pos.x + (size.x - ts.x) / 2, pos.y + (size.y - ts.y) / 2}, ui.col(t.text_dim), msg)
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload("PADS_FILE"); pl != nil {
			path := strings.string_from_ptr((^u8)(pl.Data), int(pl.DataSize))
			load_into_slicer(a, i, path)
		}
		im.EndDragDropTarget()
	}
	draw_tools_record(a, i)
}

// The record button (record the input onto the pad: a slicer slices it).
@(private)
draw_tools_record :: proc(a: ^App, i: int) {
	im.SameLine(0, 10)
	recording := a.rec.active
	if ui.icon_button(ui.ICON_CIRCLE, "Record the input into this slicer", on = recording, color = ui.rgb(0xf0555a)) {
		if recording {
			pm.record_stop(&a.rec)
		} else if pm.record_start(&a.m, &a.rec, i) != .None {
			ui.toast(&a.ws.toasts, .Warning, "No audio input to record from")
		}
	}
}

// Loads `path` into a slicer on pad `i` (and says so).
load_into_slicer :: proc(a: ^App, i: int, path: string) -> bool {
	if pm.load_slicer(&a.m, i, path) != .None {
		ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", filepath.base(path)))
		return false
	}
	a.selected = i
	show_pad_chain(a, i)
	ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Sliced %s onto %s: %d slices", filepath.base(path), pm.pad_label(i), a.m.project.pads[i].slicer.count))
	return true
}

// Loads `path` into a slicer on the selected pad if it is empty, else the
// next empty one after it (or the first). False if none is empty.
slice_onto_next :: proc(a: ^App, path: string) -> bool {
	to := next_empty_target(a)
	if to < 0 {
		ui.toast(&a.ws.toasts, .Warning, "No empty pad")
		return false
	}
	return load_into_slicer(a, to, path)
}

// Slice `k` of pad `i` onto the next empty pad.
slice_out :: proc(a: ^App, i, k: int) {
	if to := pm.slice_to_pad(&a.m, i, k); to >= 0 {
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Slice %d onto %s", k + 1, pm.pad_label(to)))
	} else {
		ui.toast(&a.ws.toasts, .Warning, "No empty pad")
	}
}

// Plays slice `k` of pad `i` (a short hit: let go at once, so a gated
// slice plays a moment).
audition_slice :: proc(a: ^App, i, k: int) {
	pm.hit(&a.m.engine, i, true, 0.9, i8(k), keyboard = true)
	pm.hit(&a.m.engine, i, false, 0, i8(k), keyboard = true)
}

// The peaks of pad `i`'s sample in the waveform's cache (read again when
// the sample changed).
wave_peaks :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	s := pm.pad_sample(m, i)
	w := &a.wave
	if s == nil || w.sample == pad.sample do return
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

_ :: math.PI
