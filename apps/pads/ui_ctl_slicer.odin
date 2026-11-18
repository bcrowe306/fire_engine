package pads

import "core:fmt"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:stretch"

// A slicer on a controller: its Slicer tab (the whole sample: how it plays,
// how it is sliced, its sound) and its Slice tab (the selected slice: where
// it starts, its level, pitch, pan, direction). The selected slice is the
// window's (its page's) and the slice pads' (Keys): `a.slice`.

// The Slicer tab's knobs: three banks (the slicing, its sound, Warp).
SLICER_KNOBS :: 20

SLICE_BY_NAMES := []string{"Transients", "Beats", "Equal", "Manual"}
SLICE_GRID_NAMES := []string{"Bars", "1/16", "1/8", "1/4"} // (stretch.Warp_Grain's order)

// A knob over a value of the slicer's (not a pad field): its new value,
// whether it moved, whether it was let go.
@(private)
ctl_value :: proc(ctx: ^View_Ctx, n, total: int, label: cstring, value, lo, hi, def: f32, format: cstring, plot: im.Vec2, log_scale := false, snap: f32 = 0) -> (v: f32, changed, ended: bool) {
	v = value
	if !ctl_knob(ctx, n, total, label, plot) do return
	e := ui.knob(label, &v, lo, hi, def, format, log_scale = log_scale, step = snap)
	return v, e.changed, e.ended
}

// The waveform with the slices on it (the selected one lit, `zoom`: shown
// around it), the playhead, the sound's spectrum behind.
@(private)
ctl_slices_wave :: proc(a: ^App, i: int, plot: im.Vec2, zoom: bool) {
	m := &a.m
	pad := m.project.pads[i]
	s := pm.pad_sample(m, i)
	sl := pad.slicer
	w := &a.view_wave
	wave_load(a, w, i)
	start, end := pm.pad_region(m, i)
	t := ui.theme()
	sel := clamp(a.slice, 0, max(sl.count - 1, 0))
	markers := make([dynamic]ui.Marker, context.temp_allocator)
	append(&markers, ui.Marker{frame = start, color = t.ok, label = "S"}, ui.Marker{frame = end, color = t.danger, label = "E"})
	for k in 0 ..< sl.count {
		c := t.accent if k == sel else ui.mix(t.text, t.text_dim, 0.5)
		append(&markers, ui.Marker{frame = sl.slices[k].start, color = c, label = fmt.tprintf("%d", k + 1)})
	}
	selection: [2]i64
	if sl.count > 0 do selection = {sl.slices[sel].start, pm.slice_end(m, i, sel)}
	w.selection = selection
	// The view: the whole region, or the slice with a little either side.
	if zoom && sl.count > 0 {
		lo, hi := f64(selection[0]), f64(selection[1])
		pad_f := max((hi - lo) * 0.15, 64)
		w.view = {max(lo - pad_f, 0), min(hi + pad_f, f64(s.frames))}
	} else {
		w.view = {0, f64(s.frames)}
	}
	head, playing := pm.pad_playhead(&m.engine, i)
	spec: []f32
	pm.watch_sound(&m.engine, i)
	if playing do spec = spectrum(a)
	ui.waveform("ctl slices", w.peaks, w.frames, &w.view, markers[:], &w.selection, plot, ui.rgb(pad.color), head if playing else -1, {pyramid = &w.pyramid, backdrop = spec})
}

// Slicer: the sample's slices; how it is sliced, the selected slice, the
// slicing's setting, its first key, the fades, the region; its sound
// (volume, pan, pitch, attack, release, velocity, choke); its Warp. Mono or
// poly, Thru, Gate, Warp, the slices to a sequence, back to a sampler,
// record.
@(private)
ctl_slicer :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	pad := m.project.pads[i]
	s := pm.pad_sample(m, i)
	if s == nil {
		ctl_message("An empty slicer: load a sample (Browse), or record one", plot)
		if p, _ := ctl_button(ctx, 6, "Record", a.rec.active, full); p do slicer_record(a, i)
		return
	}
	sl := pad.slicer
	ctl_slices_wave(a, i, plot, false)
	ctl_caption(fmt.tprintf("%s · %.2f s · %d slice%s · %s", s.name, f64(s.frames) / s.rate, sl.count, "" if sl.count == 1 else "s", SLICE_BY_NAMES[int(sl.by)]), 24)
	N :: SLICER_KNOBS
	// How it is sliced: a change slices it again (Manual: by hand, as it is).
	if k, _ := ctl_choice(ctx, 0, N, "Slice By", SLICE_BY_NAMES, int(sl.by), plot); k >= 0 {
		if pm.Slice_By(k) == .Manual {
			n := sl
			n.by = .Manual
			pm.set_slicer(m, i, n, "Slice by Hand")
		} else {
			pm.slice_pad(m, i, pm.Slice_By(k))
			ui.toast(&a.ws.toasts, .Info, fmt.tprintf("%d slices", m.project.pads[i].slicer.count))
		}
		app.seal(&m.history)
	}
	sl = m.project.pads[i].slicer
	// Which slice (encoder 2), as the Slice tab's and the slice pads select it.
	if sl.count > 0 {
		names := make([]string, sl.count, context.temp_allocator)
		for &n, j in names do n = fmt.tprintf("Slice %d", j + 1)
		if c, _ := ctl_choice(ctx, 1, N, "Slice", names, clamp(a.slice, 0, sl.count - 1), plot); c >= 0 do a.slice = c
	}
	// How it is sliced: its setting (Manual: none).
	#partial switch sl.by {
	case .Transients:
		if v, ch, en := ctl_value(ctx, 2, N, "Sensitivity", sl.sensitivity * 100, 0, 100, 50, "%.0f%%", plot); ch || en {
			n := sl
			n.sensitivity = v / 100
			if ch do pm.set_slicer(m, i, n, "Sensitivity")
			if en do pm.slice_pad(m, i, .Transients) // (let go: sliced again)
		}
	case .Beats:
		if k, _ := ctl_choice(ctx, 2, N, "Grid", SLICE_GRID_NAMES, int(sl.grain), plot); k >= 0 {
			n := sl
			n.grain = stretch.Warp_Grain(k)
			pm.set_slicer(m, i, n, "Grid")
			pm.slice_pad(m, i, .Beats)
		}
	case .Equal:
		if v, ch, en := ctl_value(ctx, 2, N, "Slices", f32(sl.parts), 1, pm.MAX_SLICER_SLICES, 16, "%.0f", plot, snap = 1); ch || en {
			n := sl
			n.parts = int(v)
			if ch do pm.set_slicer(m, i, n, "Parts")
			if en do pm.slice_pad(m, i, .Equal)
		}
	}
	sl = m.project.pads[i].slicer
	if v, ch, en := ctl_value(ctx, 3, N, "First Key", f32(sl.base), 0, 127, 60, fmt.ctprintf("%s (%%.0f)", ui.note_name(int(sl.base))), plot, snap = 1); ch || en {
		n := sl
		n.base = u8(v)
		if ch do pm.set_slicer(m, i, n, "Base Note")
		if en do app.seal(&m.history)
	}
	if v, ch, en := ctl_value(ctx, 4, N, "Fade In", sl.fade_in_ms, 0, 200, 0.5, "%.1f ms", plot); ch || en {
		n := sl
		n.fade_in_ms = v
		if ch do pm.set_slicer(m, i, n, "Fade In")
		if en do app.seal(&m.history)
	}
	if v, ch, en := ctl_value(ctx, 5, N, "Fade Out", sl.fade_out_ms, 0, 500, 3, "%.1f ms", plot); ch || en {
		n := sl
		n.fade_out_ms = v
		if ch do pm.set_slicer(m, i, n, "Fade Out")
		if en do app.seal(&m.history)
	}
	if v, ch, en := ctl_value(ctx, 14, N, "Velocity", pad.voice.velocity * 100, 0, 100, 50, "%.0f%%", plot); ch || en {
		p := pad
		p.voice.velocity = v / 100
		if ch do pm.set_pad(m, i, .Voice, "Velocity", p)
		if en do app.seal(&m.history)
	}
	start, end := pm.pad_region(m, i)
	secs := f32(f64(s.frames) / s.rate)
	for k in 0 ..< 2 {
		label := cstring("Start") if k == 0 else cstring("End")
		v, ch, en := ctl_value(ctx, 6 + k, N, label, f32(f64(start if k == 0 else end) / s.rate), 0, secs, 0 if k == 0 else secs, "%.3f s", plot)
		if ch {
			f := i64(f64(v) * s.rate)
			p := pad
			if k == 0 do p.start = clamp(f, 0, end - 1)
			else do p.end = clamp(f, start + 1, s.frames)
			pm.set_pad(m, i, .Region, "Move Marker", p) // api-lint: the region (pad_set_region)
		}
		if en do app.seal(&m.history)
	}
	// Its sound (the second bank).
	pd := m.project.pads[i]
	if ctl_knob(ctx, 8, N, "Volume", plot) do knob_f32(a, "Volume", &pd.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	if ctl_knob(ctx, 9, N, "Pan", plot) do knob_f32(a, "Pan", &pd.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	if ctl_knob(ctx, 10, N, "Transpose", plot) do knob_f32(a, "Transpose", &pd.pitch, -24, 24, 0, "%+.0f st", .Pitch, "Set Pitch", snap = 1)
	if ctl_knob(ctx, 11, N, "Fine", plot) do voice_knob(a, "Fine", &a.voice_edit.fine, -100, 100, 0, "%+.0f ct", int(Voice_Key.Fine), "Fine Tune")
	if ctl_knob(ctx, 12, N, "Attack", plot) do knob_f32(a, "Attack", &pd.attack, 0.0005, 10, 0.001, "%.3f s", .Attack, "Set Attack", log_scale = true)
	if ctl_knob(ctx, 13, N, "Release", plot) do knob_f32(a, "Release", &pd.release, 0.005, 20, 0.05, "%.2f s", .Release, "Set Release", log_scale = true)
	chokes := []string{"No choke", "Choke 1", "Choke 2", "Choke 3", "Choke 4", "Choke 5", "Choke 6"}
	if k, _ := ctl_choice(ctx, 15, N, "Choke", chokes, int(pd.choke), plot); k >= 0 do pa.pad_set_choke(&a.api, i64(i), i64(k))
	ctl_warp(ctx, i, 16, N, plot)
	// The buttons.
	if p, _ := ctl_button(ctx, 0, "Mono" if sl.mono else "Poly", sl.mono, full); p {
		n := sl
		n.mono = !sl.mono
		pm.set_slicer(m, i, n, "Mono" if n.mono else "Poly")
		app.seal(&m.history)
	}
	if p, _ := ctl_button(ctx, 1, "Thru", sl.thru, full); p {
		n := sl
		n.thru = !sl.thru
		pm.set_slicer(m, i, n, "Thru")
		app.seal(&m.history)
	}
	if p, _ := ctl_button(ctx, 2, "Gate", sl.gate, full); p {
		n := sl
		n.gate = !sl.gate
		pm.set_slicer(m, i, n, "Gate")
		app.seal(&m.history)
	}
	if p, _ := ctl_button(ctx, 3, "Warp", pd.warp.on, full); p {
		w := pd.warp
		w.on = !w.on
		pm.set_warp(m, i, w, "Warp On" if w.on else "Warp Off")
		app.seal(&m.history)
		if w.on do a.ctl.page = 2 // (its settings)
	}
	if p, _ := ctl_button(ctx, 4, "To Sequence", false, full); p {
		if slot := pm.slices_to_sequence(m, i); slot >= 0 {
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Sequence %d plays the slices", slot + 1))
		} else {
			ui.toast(&a.ws.toasts, .Warning, "No empty sequence")
		}
	}
	if p, _ := ctl_button(ctx, 5, "To Sampler", false, full); p do pa.pad_set_kind(&a.api, i64(i), .Sampler)
	if p, _ := ctl_button(ctx, 6, "Record", a.rec.active, full); p do slicer_record(a, i)
}

// Slice: the selected slice, shown close; which one, where it starts,
// its level, pitch and pan; Reverse, hear it, split it in two, take it
// away, onto the next empty pad.
@(private)
ctl_slice :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	s := pm.pad_sample(m, i)
	sl := m.project.pads[i].slicer
	if s == nil || sl.count == 0 {
		ctl_message("No slices yet: slice it on the Slicer tab", plot)
		return
	}
	a.slice = clamp(a.slice, 0, sl.count - 1)
	k := a.slice
	x := sl.slices[k]
	ctl_slices_wave(a, i, plot, true)
	slice_end := pm.slice_end(m, i, k)
	ctl_caption(fmt.tprintf("Slice %d of %d · %s · %.3f s", k + 1, sl.count, ui.note_name(int(sl.base) + k), f64(slice_end - x.start) / s.rate), 24)
	N :: 8
	// Which slice (encoder 1), as the slice pads select it.
	names := make([]string, sl.count, context.temp_allocator)
	for &n, j in names do n = fmt.tprintf("Slice %d", j + 1)
	if c, _ := ctl_choice(ctx, 0, N, "Slice", names, k, plot); c >= 0 do a.slice = c
	k = a.slice
	x = sl.slices[k]
	// Where it starts (the first: the region's start, not moved here).
	if k > 0 {
		lo := f32(f64(sl.slices[k - 1].start + 1) / s.rate)
		hi := f32(f64(pm.slice_end(m, i, k) - 1) / s.rate)
		if v, ch, en := ctl_value(ctx, 1, N, "Position", f32(f64(x.start) / s.rate), lo, hi, f32(f64(x.start) / s.rate), "%.3f s", plot); ch || en {
			if ch do pm.move_slice(m, i, k, i64(f64(v) * s.rate))
			if en do app.seal(&m.history)
		}
	}
	if v, ch, en := ctl_value(ctx, 2, N, "Level", x.gain_db, -24, 6, 0, "%+.1f dB", plot); ch || en {
		n := x
		n.gain_db = v
		if ch do pm.set_slice(m, i, k, n, "Slice Level")
		if en do app.seal(&m.history)
	}
	if v, ch, en := ctl_value(ctx, 3, N, "Pitch", x.pitch, -24, 24, 0, "%+.1f st", plot); ch || en {
		n := x
		n.pitch = v
		if ch do pm.set_slice(m, i, k, n, "Slice Pitch")
		if en do app.seal(&m.history)
	}
	if v, ch, en := ctl_value(ctx, 4, N, "Pan", x.pan, -1, 1, 0, "%+.2f", plot); ch || en {
		n := x
		n.pan = v
		if ch do pm.set_slice(m, i, k, n, "Slice Pan")
		if en do app.seal(&m.history)
	}
	// The buttons.
	if p, _ := ctl_button(ctx, 0, "Reverse", x.reverse, full); p {
		n := x
		n.reverse = !x.reverse
		pm.set_slice(m, i, k, n, "Slice Reverse")
		app.seal(&m.history)
	}
	if p, _ := ctl_button(ctx, 1, "Hear", false, full); p do audition_slice(a, i, k)
	if p, _ := ctl_button(ctx, 2, "Split", false, full); p {
		mid := (x.start + slice_end) / 2
		if pm.add_slice(m, i, mid) {
			app.seal(&m.history)
			ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Slice %d split in two", k + 1))
		}
	}
	if k > 0 { // (slice 1 starts the region: it stays)
		if p, _ := ctl_button(ctx, 3, "Remove", false, full); p {
			pm.remove_slice(m, i, k)
			app.seal(&m.history)
			a.slice = k - 1
		}
	}
	if p, _ := ctl_button(ctx, 4, "To Pad", false, full); p do slice_out(a, i, k)
}

// Records the input into slicer `i` (or stops), as its page's button.
@(private)
slicer_record :: proc(a: ^App, i: int) {
	if a.rec.active {
		pa.recording_sample_stop(&a.api)
	} else if pa.recording_sample_start(&a.api, i64(i), .Hold) != .Ok {
		ui.toast(&a.ws.toasts, .Warning, "No audio input to record from")
	}
}

// Warp's knobs (from knob `n0` of `total`): its mode (Off: not warped), the
// sample's tempo (its guess until set), and in Beats where it cuts and
// whether the gaps are filled.
@(private)
ctl_warp :: proc(ctx: ^View_Ctx, i, n0, total: int, plot: im.Vec2) {
	a := ctx.a
	m := &a.m
	w := m.project.pads[i].warp
	modes := make([]string, len(stretch.Warp_Mode) + 1, context.temp_allocator)
	modes[0] = "Off"
	for mode in stretch.Warp_Mode do modes[int(mode) + 1] = string(pm.WARP_MODE_NAMES[mode])
	if k, _ := ctl_choice(ctx, n0, total, "Warp", modes, int(w.mode) + 1 if w.on else 0, plot); k >= 0 {
		n := w
		n.on = k > 0
		if k > 0 do n.mode = stretch.Warp_Mode(k - 1)
		pm.set_warp(m, i, n, "Warp Mode" if w.on && n.on else "Warp On" if n.on else "Warp Off")
		app.seal(&m.history)
	}
	w = m.project.pads[i].warp
	bpm := f32(pm.pad_bpm(m, i))
	if v, ch, en := ctl_value(ctx, n0 + 1, total, "Sample BPM", bpm, 20, 400, bpm, "%.2f", plot); ch || en {
		n := w
		n.bpm = f64(v)
		if ch do pm.set_warp(m, i, n, "Sample Tempo")
		if en do app.seal(&m.history)
	}
	if w.mode != .Beats do return
	grains := make([]string, len(stretch.Warp_Grain), context.temp_allocator)
	for g in stretch.Warp_Grain do grains[int(g)] = string(pm.WARP_GRAIN_NAMES[g])
	if k, _ := ctl_choice(ctx, n0 + 2, total, "Cut", grains, int(w.grain), plot); k >= 0 {
		n := w
		n.grain = stretch.Warp_Grain(k)
		pm.set_warp(m, i, n, "Warp Cuts")
		app.seal(&m.history)
	}
	if k, _ := ctl_choice(ctx, n0 + 3, total, "Fill Gaps", {"Off", "On"}, int(w.fill_gaps), plot); k >= 0 {
		n := w
		n.fill_gaps = k == 1
		pm.set_warp(m, i, n, "Fill Gaps")
		app.seal(&m.history)
	}
}
