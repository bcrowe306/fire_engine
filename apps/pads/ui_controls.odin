// Dialogs a controller's buttons open (Push 2's Fixed Length...), the
// window's too: they mirror on its display as every dialog does
// (ui_dialog.odin), their choices on its lower row.
package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import pf "fire:perform"
import im "deps:imgui"

// The dialogs' state.
Controls_Ui :: struct {
	length_open:   bool, // Sequence Length: the current sequence's bars
	quantize_open: bool, // Quantize: its settings, and input quantize's
	convert_open:  bool, // Convert: the selected pad's sample as another device, or resampled
	scale_open:    bool, // Scale: Keyboard mode's scale, root, octave and chord
	recording_open: bool, // Recording: the Sample control (recording into a pad)
	transport_open: bool, // Transport: loop, count-in, the click, the time signature
	repeat_open:    bool, // Note Repeat: on, its rate, its gate (a controller's Repeat held)
	sequence_open:  bool, // Sequence: the current sequence's colour, tempo, bars, the pad's loop, when one takes over
	lane_open:      bool, // Lane: a launcher lane's colour (its name: Rename)
	lane:           int,
	lane_rename:    bool, // the lane's name dialog
	lane_buf:       [32]u8,
}

// The lengths Sequence Length offers (bars).
LENGTH_BARS := [7]int{1, 2, 4, 8, 16, 32, 64}

// Sequence Length: the current sequence's bars, one press (a controller's
// Fixed Length).
draw_length_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.length_open do return
	im.OpenPopup("Sequence Length")
	if !modal_begin(a, "Sequence Length", &st.length_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	slot := a.m.project.slot
	ss, _ := pa.sequence_state(&a.api, i64(slot))
	modal_text(a, fmt.tprintf("%s is %d bar%s long now: how long should it be?", pa_name(a, slot), ss.bars, "" if ss.bars == 1 else "s"))
	for b, k in LENGTH_BARS {
		if k > 0 do im.SameLine()
		label := fmt.ctprintf("%s%d bar%s##len%d", "• " if i64(b) == ss.bars else "", b, "" if b == 1 else "s", b)
		if modal_button(a, label) {
			if toast_failed(a, pa.sequence_set_bars(&a.api, i64(slot), i64(b)), "Could not set its length") do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s: %d bar%s", pa_name(a, slot), b, "" if b == 1 else "s"))
			st.length_open = false
			im.CloseCurrentPopup()
		}
		ui.name(fmt.tprintf("length %d", b))
	}
	im.SameLine()
	if modal_button(a, "Cancel") || im.IsKeyPressed(.Escape) {
		st.length_open = false
		im.CloseCurrentPopup()
	}
}

// Sequence `slot`'s name. Temporary.
@(private = "file")
pa_name :: proc(a: ^App, slot: int) -> string {
	n, _ := pa.sequence_name(&a.api, i64(slot))
	return n
}

// Quantize: the selected notes in the sequencer, else the sequence, as
// the Quantize setting says (note repeat on: to its rate); a message says
// which. (The window's button, its menu's, a controller's.)
quantize_now :: proc(a: ^App) {
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	q := m.project.transport.quant
	grid := pm.quantize_grid(&m.engine, q.grid)
	if len(st.sel) > 0 {
		g := pm.grid_beats(grid)
		moved := make([]pm.Seq_Note, len(st.sel), context.temp_allocator)
		for x, i in st.sel {
			moved[i] = x
			moved[i].start += (math.round(x.start / g) * g - x.start) * f64(q.strength)
		}
		landed := pm.replace_notes(m, slot, st.sel[:], moved, false, .Notes, "Quantize") // api-lint: the selection is the window's
		app.seal(&m.history)
		clear(&st.sel)
		append(&st.sel, ..landed)
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Quantized %d note%s to %s (%.0f%%)", len(landed), "" if len(landed) == 1 else "s", pm.GRID_NAMES[grid], q.strength * 100))
		return
	}
	if toast_failed(a, pa.sequence_quantize_now(&a.api, i64(slot)), "Could not quantize") {
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Quantized %s to %s (%.0f%%)", pa_name(a, slot), pm.GRID_NAMES[grid], q.strength * 100))
	}
}

// Quantize's settings (what Quantize does) and input quantize's (notes as
// they are recorded): a controller's encoders turn them (Quantize held).
draw_quantize_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.quantize_open do return
	im.OpenPopup("Quantize")
	if !modal_begin(a, "Quantize", &st.quantize_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	q, _ := pa.sequence_quantize_setting(&a.api)
	iq, _ := pa.sequence_input_quantize(&a.api)
	grids := len(pm.Grid)
	modal_text(a, "Quantize moves notes to the grid; input quantize, as they are recorded.", dim = true)
	// Quantize: its grid and strength.
	im.SeparatorText("Quantize")
	g := int(q.grid)
	im.SetNextItemWidth(160)
	if ui.combo("Grid##qgrid", pm.GRID_NAMES[pm.Grid(g)]) {
		for x in pm.Grid do if im.Selectable(pm.GRID_NAMES[x], int(x) == g) do g = int(x)
		im.EndCombo()
	}
	ui.name("quantize grid")
	g = clamp(g + modal_knob(a, "Grid", string(pm.GRID_NAMES[pm.Grid(g)])), 0, grids - 1)
	str := q.strength * 100
	im.SetNextItemWidth(160)
	im.SliderFloat("Strength##qstr", &str, 0, 100, "%.0f%%")
	ui.name("quantize strength")
	str = clamp(str + f32(modal_knob(a, "Strength", fmt.tprintf("%.0f%%", q.strength * 100), fine = true)), 0, 100)
	if g != int(q.grid) || abs(str / 100 - q.strength) > 1e-6 do pa.sequence_set_quantize_setting(&a.api, pa.Grid(g), str / 100)
	// Input quantize: on, its grid, strength and swing.
	im.SeparatorText("Input quantize")
	on := iq.on
	im.Checkbox("On##iqon", &on)
	ui.name("input quantize on")
	if v, ch := modal_switch(a, "Input", iq.on); ch do on = v
	ig := int(iq.grid)
	im.SetNextItemWidth(160)
	if ui.combo("Grid##iqgrid", pm.GRID_NAMES[pm.Grid(ig)]) {
		for x in pm.Grid do if im.Selectable(pm.GRID_NAMES[x], int(x) == ig) do ig = int(x)
		im.EndCombo()
	}
	ig = clamp(ig + modal_knob(a, "In Grid", string(pm.GRID_NAMES[pm.Grid(ig)])), 0, grids - 1)
	is := iq.strength * 100
	im.SetNextItemWidth(160)
	im.SliderFloat("Strength##iqstr", &is, 0, 100, "%.0f%%")
	is = clamp(is + f32(modal_knob(a, "In Strength", fmt.tprintf("%.0f%%", iq.strength * 100), fine = true)), 0, 100)
	sw := iq.swing * 100
	im.SetNextItemWidth(160)
	im.SliderFloat("Swing##iqsw", &sw, 0, 100, "%.0f%%")
	sw = clamp(sw + f32(modal_knob(a, "In Swing", fmt.tprintf("%.0f%%", iq.swing * 100), fine = true)), 0, 100)
	if on != iq.on || ig != int(iq.grid) || abs(is / 100 - iq.strength) > 1e-6 || abs(sw / 100 - iq.swing) > 1e-6 {
		pa.sequence_set_input_quantize(&a.api, on, pa.Grid(ig), is / 100, sw / 100)
	}
	im.Spacing()
	if modal_button(a, "Quantize Now") do quantize_now(a)
	ui.name("quantize now")
	im.SameLine()
	if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
		st.quantize_open = false
		im.CloseCurrentPopup()
	}
	ui.name("quantize close")
}

// What Convert offers.
Convert :: enum {
	Slicer,     // a sampler's sample sliced in place
	Slices,     // its slices, each onto an empty pad
	Synth,      // its sample a synth's oscillator
	Sampler,    // a slicer's or a synth's sample back on a sampler
	Resample_Sequence, // the sequence, rendered onto the next empty pad
	Resample_Pad,      // the selected pad's part of it, rendered onto the next empty pad
}

CONVERT_NAMES := [Convert]string{.Slicer = "Make a Slicer", .Slices = "Slice onto Pads", .Synth = "Into a Synth", .Sampler = "Back to a Sampler", .Resample_Sequence = "Resample Sequence", .Resample_Pad = "Resample Pad"}

// What Convert can do to pad `i` now.
convert_choices :: proc(a: ^App, i: int) -> []Convert {
	p := &a.m.project
	pad := p.pads[i]
	out := make([dynamic]Convert, context.temp_allocator)
	has_sample := pad.sample != 0
	switch pad.kind {
	case .Sampler:
		if has_sample do append(&out, Convert.Slicer, Convert.Slices, Convert.Synth)
	case .Slicer:
		if has_sample do append(&out, Convert.Slices, Convert.Sampler, Convert.Synth)
	case .Synth:
		if pad.synth.sample.sample != 0 || has_sample do append(&out, Convert.Sampler)
	case .Audio, .Plugin:
	}
	s := pm.current_sequence(&a.m)
	if len(s.notes) > 0 do append(&out, Convert.Resample_Sequence)
	if pm.pad_used(p, i) do for n in s.notes do if int(n.pad) == i {
		append(&out, Convert.Resample_Pad)
		break
	}
	return out[:]
}

// Converts pad `i` as `c` says; a message says what became of it.
convert_pad :: proc(a: ^App, i: int, c: Convert) {
	m := &a.m
	label := pm.pad_label(i)
	switch c {
	case .Slicer:
		if toast_failed(a, pa.pad_set_kind(&a.api, i64(i), .Slicer), "Could not make a slicer") {
			n := m.project.pads[i].slicer.count
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s is a Slicer: %d slice%s", label, n, "" if n == 1 else "s"))
		}
	case .Slices:
		pa.history_group_begin(&a.api, "Slice onto Pads")
		if m.project.pads[i].kind != .Slicer do pa.pad_set_kind(&a.api, i64(i), .Slicer)
		got := 0
		for k in 0 ..< m.project.pads[i].slicer.count do if pm.slice_to_pad(m, i, k) >= 0 do got += 1 // api-lint: as the Library's Slices → Pads
		pa.history_group_end(&a.api)
		ui.toast(&a.ws.toasts, .Success if got > 0 else .Warning, fmt.tprintf("%d slice%s of %s onto pads", got, "" if got == 1 else "s", label) if got > 0 else "No empty pad for the slices")
	case .Synth:
		sample := m.project.pads[i].sample
		pa.history_group_begin(&a.api, "Into a Synth")
		pa.pad_set_kind(&a.api, i64(i), .Synth)
		pm.set_synth_sample(m, i, {sample = sample}) // api-lint: as the Library's Synth Osc (the pad's own sample)
		pa.history_group_end(&a.api)
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s is a Synth: its sample the oscillator", label))
	case .Sampler:
		pad := m.project.pads[i]
		pa.history_group_begin(&a.api, "Back to a Sampler")
		pa.pad_set_kind(&a.api, i64(i), .Sampler)
		if m.project.pads[i].sample == 0 && pad.synth.sample.sample != 0 {
			x := m.project.pads[i]
			x.sample = pad.synth.sample.sample
			pm.set_pad(m, i, .Whole, "Back to a Sampler", x) // api-lint: the synth's sample onto the sampler
		}
		pa.history_group_end(&a.api)
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s is a Sampler", label))
	case .Resample_Sequence:
		ids := make([dynamic]i64, context.temp_allocator)
		for k in 0 ..< pm.PADS do if pm.pad_used(&m.project, k) do append(&ids, i64(k))
		if toast_failed(a, pa.export_bounce_pads(&a.api, ids[:]), "Could not resample") do ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Resampling %s onto the next empty pad…", pa_name(a, m.project.slot)))
	case .Resample_Pad:
		if toast_failed(a, pa.export_bounce_pads(&a.api, {i64(i)}), "Could not resample") do ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Resampling %s onto the next empty pad…", label))
	}
}

// Convert: the selected pad's sample as another device, or resampled (a
// controller's Convert); only what fits it is offered.
draw_convert_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.convert_open do return
	im.OpenPopup("Convert")
	if !modal_begin(a, "Convert", &st.convert_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	i := a.selected
	choices := convert_choices(a, i)
	kinds := [pm.Pad_Kind]string{.Sampler = "a Sampler", .Audio = "an audio track", .Slicer = "a Slicer", .Synth = "a Synth", .Plugin = "a plug-in"}
	modal_text(a, fmt.tprintf("%s is %s." if pm.pad_used(&a.m.project, i) else "%s is empty.", pm.pad_label(i), kinds[a.m.project.pads[i].kind]))
	if len(choices) == 0 do modal_text(a, "Nothing to convert: load a sample onto it, or play it in the sequence to resample it.", dim = true)
	for c, k in choices {
		if k > 0 do im.SameLine()
		if modal_button(a, fmt.ctprintf("%s", CONVERT_NAMES[c])) {
			convert_pad(a, i, c)
			st.convert_open = false
			im.CloseCurrentPopup()
		}
		ui.name(fmt.tprintf("convert %s", CONVERT_NAMES[c]))
	}
	if len(choices) > 0 do im.SameLine()
	if modal_button(a, "Cancel") || im.IsKeyPressed(.Escape) {
		st.convert_open = false
		im.CloseCurrentPopup()
	}
}

// The notes' names, from C.
KEY_NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

// Scale: Keyboard mode's scale, root, octave and chord (a controller's
// Scale: its encoders turn them), and Keyboard mode itself. (The scales,
// chords and progressions grid mode replaces it later.)
draw_scale_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.scale_open do return
	im.OpenPopup("Scale")
	if !modal_begin(a, "Scale", &st.scale_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	ps, _ := pa.perform_state(&a.api)
	modal_text(a, "Keyboard mode's notes: the pads play this scale from this root.", dim = true)
	sc, root, oct, ch := int(ps.scale), int(ps.root), int(ps.octave), int(ps.chord)
	im.SetNextItemWidth(200)
	if ui.combo("Scale##sc", pm.SCALE_NAMES[pm.Scale(sc)]) {
		for x in pm.Scale do if im.Selectable(pm.SCALE_NAMES[x], int(x) == sc) do sc = int(x)
		im.EndCombo()
	}
	sc = clamp(sc + modal_knob(a, "Scale", string(pm.SCALE_NAMES[pm.Scale(sc)])), 0, len(pm.Scale) - 1)
	im.SetNextItemWidth(200)
	if ui.combo("Root##root", fmt.ctprintf("%s", KEY_NAMES[root])) {
		for k in 0 ..< 12 do if im.Selectable(fmt.ctprintf("%s", KEY_NAMES[k]), k == root) do root = k
		im.EndCombo()
	}
	root = ((root + modal_knob(a, "Root", KEY_NAMES[root])) % 12 + 12) % 12
	im.SetNextItemWidth(200)
	o := i32(oct)
	im.SliderInt("Octave##oct", &o, -3, 3, "%+d")
	oct = clamp(int(o) + modal_knob(a, "Octave", fmt.tprintf("%+d", oct)), -3, 3)
	im.SetNextItemWidth(200)
	if ui.combo("Chords##ch", pm.CHORD_NAMES[pm.Chord(ch)]) {
		for x in pm.Chord do if im.Selectable(pm.CHORD_NAMES[x], int(x) == ch) do ch = int(x)
		im.EndCombo()
	}
	ch = clamp(ch + modal_knob(a, "Chords", string(pm.CHORD_NAMES[pm.Chord(ch)])), 0, len(pm.Chord) - 1)
	if sc != int(ps.scale) || root != int(ps.root) || oct != int(ps.octave) || ch != int(ps.chord) {
		pa.perform_set_keys(&a.api, pa.Scale(sc), i64(root), i64(oct), pa.Chord(ch))
	}
	im.Spacing()
	keyboard := ps.play_mode == .Keyboard
	if modal_button(a, "Pads Mode" if keyboard else "Keyboard Mode") do pa.perform_set_play_mode(&a.api, .Pads if keyboard else .Keyboard)
	im.SameLine()
	if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
		st.scale_open = false
		im.CloseCurrentPopup()
	}
}

// Recording: the toolbar's Sample control (recording into a pad: how,
// the level, the bars, latched), armed from here (a controller's Record
// held).
draw_recording_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.recording_open do return
	im.OpenPopup("Recording")
	if !modal_begin(a, "Recording", &st.recording_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	s := &a.settings
	HINTS := [pm.Sampling]string{
		.Hold      = "Hold: a pad held with Option (Alt) in the window records while held (on a controller: Record on an empty pad's page).",
		.Arm       = "Arm: then the next pad pressed records while it is held.",
		.Threshold = "Threshold: then the next pad pressed records while held, starting where the sound passes the level.",
		.Bars      = "Bars: then the next pad pressed records the next bars in time (playing starts if stopped).",
	}
	modal_text(a, "Record a sample into a pad.")
	modal_text(a, HINTS[s.sample_method], dim = true)
	method := int(s.sample_method)
	ui.segmented("rec method", {"Hold", "Arm", "Threshold", "Bars"}, &method)
	METHODS := [pm.Sampling]string{.Hold = "Hold", .Arm = "Arm", .Threshold = "Threshold", .Bars = "Bars"}
	method = clamp(method + modal_knob(a, "Method", METHODS[pm.Sampling(method)]), 0, len(pm.Sampling) - 1)
	if pm.Sampling(method) != s.sample_method {
		s.sample_method = pm.Sampling(method)
		a.sample_armed = false
		settings_save(a)
	}
	db := f64(s.sample_threshold_db)
	if ui.number_drag("rec threshold", &db, -80, 0, 1, 0.1, "Threshold %.0f dB", 200).changed do s.sample_threshold_db = f32(db)
	if n := modal_knob(a, "Threshold", fmt.tprintf("%.0f dB", s.sample_threshold_db), fine = true); n != 0 {
		s.sample_threshold_db = clamp(s.sample_threshold_db + f32(n), -80, 0)
		settings_save(a)
	}
	bars := f64(s.sample_bars)
	if ui.number_drag("rec bars", &bars, 1, 16, 1, 1, "%.0f bars", 200).changed do s.sample_bars = int(bars)
	if n := modal_knob(a, "Bars", fmt.tprintf("%d", s.sample_bars)); n != 0 {
		s.sample_bars = clamp(s.sample_bars + n, 1, 16)
		settings_save(a)
	}
	if ui.toggle("Latch##reclatch", &a.sample_latched) do a.sample_armed = a.sample_latched
	if v, ch := modal_switch(a, "Latch", a.sample_latched); ch {
		a.sample_latched = v
		a.sample_armed = v
	}
	im.Spacing()
	if a.rec.active {
		if modal_button(a, "Stop Recording") do pa.recording_sample_stop(&a.api)
	} else if s.sample_method != .Hold {
		if modal_button(a, "Disarm" if a.sample_armed else "Arm") {
			a.sample_armed = !a.sample_armed
			if a.sample_armed {
				ui.toast(&a.ws.toasts, .Info, "Sample armed: press a pad to record into it")
				st.recording_open = false
				im.CloseCurrentPopup()
			}
		}
	}
	im.SameLine()
	if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
		st.recording_open = false
		im.CloseCurrentPopup()
	}
}

// Note Repeat, the toolbar's: on, its rate, its gate (a controller's
// Repeat held a while).
draw_repeat_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.repeat_open do return
	im.OpenPopup("Note Repeat")
	if !modal_begin(a, "Note Repeat", &st.repeat_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	s := &a.settings
	modal_text(a, "Every pad held repeats at this rate (hold Repeat, or Shift + Repeat to latch it).", dim = true)
	on, _ := pa.perform_note_repeat(&a.api)
	if ui.toggle("On##nrpon", &on) do pa.perform_set_note_repeat(&a.api, on)
	if v, ch := modal_switch(a, "Repeat", on); ch do pa.perform_set_note_repeat(&a.api, v)
	rate := int(s.repeat_rate)
	im.SetNextItemWidth(110)
	if rate_combo("##nrprate", &s.repeat_rate) do pa.settings_set_number(&a.api, "note_repeat.rate", f64(s.repeat_rate))
	rate = clamp(rate + modal_knob(a, "Rate", string(RATE_NAMES[s.repeat_rate])), 0, len(pf.Rate) - 1)
	if rate != int(s.repeat_rate) do pa.settings_set_number(&a.api, "note_repeat.rate", f64(rate))
	g := f64(s.repeat_gate * 100)
	if ui.number_drag("note repeat gate", &g, 5, 100, 5, 1, "Gate %.0f%%", 140).ended do pa.settings_set_number(&a.api, "note_repeat.gate", g / 100)
	if n := modal_knob(a, "Gate", fmt.tprintf("%.0f%%", s.repeat_gate * 100)); n != 0 do pa.settings_set_number(&a.api, "note_repeat.gate", f64(clamp(s.repeat_gate + f32(n) * 0.05, 0.05, 1)))
	a.m.engine.repeat_all_settings = {rate = s.repeat_rate, gate = s.repeat_gate}
	im.Spacing()
	if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
		st.repeat_open = false
		im.CloseCurrentPopup()
	}
}

// Transport: loop, the count-in, the click (on, its level, sound, accent,
// only while recording), the time signature (a controller's Metronome
// held, or with Shift).
draw_transport_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.transport_open do return
	im.OpenPopup("Transport")
	if !modal_begin(a, "Transport", &st.transport_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	tr, _ := pa.transport_state(&a.api)
	modal_text(a, "Loop, the count-in, the click and the time signature.", dim = true)
	loop := tr.loop
	if ui.toggle("Loop##trloop", &loop) do pa.transport_set_loop(&a.api, loop)
	if v, ch := modal_switch(a, "Loop", tr.loop); ch do pa.transport_set_loop(&a.api, v)
	ci := int(tr.count_in)
	ui.segmented("count in", {"No count-in", "1 bar", "2 bars"}, &ci)
	ci = clamp(ci + modal_knob(a, "Count-in", "None" if tr.count_in == 0 else fmt.tprintf("%d bar%s", tr.count_in, "" if tr.count_in == 1 else "s")), 0, 2)
	if i64(ci) != tr.count_in do pa.transport_set_count_in(&a.api, i64(ci))
	db := f64(tr.metronome_db)
	if ui.number_drag("click level", &db, -60, 6, 0.5, 0.1, "Click %.1f dB", 200).changed do pa.transport_set_metronome_level(&a.api, f32(db))
	if n := modal_knob(a, "Click Level", fmt.tprintf("%.1f dB", tr.metronome_db), fine = true); n != 0 do pa.transport_set_metronome_level(&a.api, clamp(tr.metronome_db + f32(n) * 0.5, -60, 6))
	SOUNDS := [pa.Metronome_Sound]string{.Beep = "Beep", .Wood = "Wood", .Stick = "Stick", .Cowbell = "Cowbell"}
	snd := int(tr.metronome_sound)
	ui.segmented("click sound", {"Beep", "Wood", "Stick", "Cowbell"}, &snd)
	snd = clamp(snd + modal_knob(a, "Sound", SOUNDS[pa.Metronome_Sound(snd)]), 0, len(pa.Metronome_Sound) - 1)
	if snd != int(tr.metronome_sound) do pa.transport_set_metronome_sound(&a.api, pa.Metronome_Sound(snd))
	acc := tr.metronome_accent
	if ui.toggle("Accent the bar's first beat##tracc", &acc) do pa.transport_set_metronome_accent(&a.api, acc)
	if v, ch := modal_switch(a, "Accent", tr.metronome_accent); ch do pa.transport_set_metronome_accent(&a.api, v)
	ro := tr.metronome_recording_only
	if ui.toggle("Only while recording##trro", &ro) do pa.transport_set_metronome_recording_only(&a.api, ro)
	if v, ch := modal_switch(a, "Rec Only", tr.metronome_recording_only); ch do pa.transport_set_metronome_recording_only(&a.api, v)
	num, den := tr.time_sig_num, tr.time_sig_den
	im.Text("%s", fmt.ctprintf("Time signature %d/%d", num, den))
	num = clamp(num + i64(modal_knob(a, "Beats", fmt.tprintf("%d", num))), 1, 16)
	DENS := []i64{2, 4, 8, 16}
	di := 1
	for d, k in DENS do if d == den do di = k
	di = clamp(di + modal_knob(a, "Beat Is", fmt.tprintf("1/%d", den)), 0, len(DENS) - 1)
	if num != tr.time_sig_num || DENS[di] != tr.time_sig_den do pa.transport_set_time_signature(&a.api, num, DENS[di])
	im.Spacing()
	if modal_button(a, "Click Off" if tr.metronome else "Click On") do pa.transport_set_metronome(&a.api, !tr.metronome)
	im.SameLine()
	if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
		st.transport_open = false
		im.CloseCurrentPopup()
	}
}

// The colours a sequence or lane can have: its own (0: its slot's), the
// pads' swatches.
@(private = "file")
swatch_step :: proc(cur: u32, n: int) -> u32 {
	k := 0 // (0: none of its own)
	for c, i in PAD_PALETTE do if c == cur do k = i + 1
	k = clamp(k + n, 0, len(PAD_PALETTE))
	return 0 if k == 0 else PAD_PALETTE[k - 1]
}

// Sequence: the current sequence's colour, its own tempo, bars, the
// selected pad's own loop in it, when a sequence picked takes over;
// Rename, Duplicate, Clear (a controller's Fixed Length held, or Shift).
draw_sequence_dialog :: proc(a: ^App) {
	st := &a.controls
	if !st.sequence_open do return
	im.OpenPopup("Sequence")
	if !modal_begin(a, "Sequence", &st.sequence_open, {.AlwaysAutoResize}) do return
	defer im.EndPopup()
	m := &a.m
	slot := m.project.slot
	ss, _ := pa.sequence_state(&a.api, i64(slot))
	ls, _ := pa.launcher_state(&a.api)
	modal_text(a, fmt.tprintf("%s: %d bar%s, %s", pa_name(a, slot), ss.bars, "" if ss.bars == 1 else "s", "its own tempo" if ss.bpm > 0 else "the project's tempo"))
	// Its colour.
	own := u32(m.project.sequences[slot].color)
	if n := modal_knob(a, "Colour", "Its slot's" if own == 0 else fmt.tprintf("#%06X", own)); n != 0 do pa.sequence_set_color(&a.api, i64(slot), i64(swatch_step(own, n)))
	// Its tempo (0: the project's), a BPM a step.
	if n := modal_knob(a, "Tempo", "Project's" if ss.bpm <= 0 else fmt.tprintf("%.1f BPM", ss.bpm), fine = true); n != 0 {
		tr, _ := pa.transport_state(&a.api)
		now := ss.bpm if ss.bpm > 0 else tr.bpm
		to := clamp(now + f64(n), 0, 300)
		pa.sequence_set_tempo(&a.api, i64(slot), 0 if to < 40 else to)
	}
	if n := modal_knob(a, "Bars", fmt.tprintf("%d", ss.bars)); n != 0 do pa.sequence_set_bars(&a.api, i64(slot), clamp(ss.bars + i64(n), 1, pa.MAX_BARS))
	// The selected pad's own loop (none, or bars of it).
	bar := pm.bar_beats(&m.project)
	loop := f64(m.project.sequences[slot].loops[a.selected])
	loops := []f64{0, 0.25, 0.5, 1, 2, 4, 8, 16}
	cur := 0
	for x, k in loops do if abs(x * bar - loop) < 1e-6 do cur = k
	names := []string{"None", "1/4 bar", "1/2 bar", "1 bar", "2 bars", "4 bars", "8 bars", "16 bars"}
	if n := modal_knob(a, fmt.tprintf("%s Loop", pm.pad_label(a.selected)), names[cur]); n != 0 {
		k := clamp(cur + n, 0, len(loops) - 1)
		pa.sequence_set_track_loop(&a.api, i64(slot), i64(a.selected), loops[k] * bar)
	}
	// When a sequence picked takes over (the launcher's).
	TAKES := [pa.Launch_Quantize]string{.End = "Its end", .Bar = "Next bar", .Beat = "Next beat", .Now = "At once"}
	if n := modal_knob(a, "Takes Over", TAKES[ls.quantize]); n != 0 do pa.launcher_set_quantize(&a.api, pa.Launch_Quantize(clamp(int(ls.quantize) + n, 0, len(pa.Launch_Quantize) - 1)))
	im.Text("%s", fmt.ctprintf("Tempo %s · %d bars · %s's loop %s · takes over: %s", "the project's" if ss.bpm <= 0 else fmt.tprintf("%.1f", ss.bpm), ss.bars, pm.pad_label(a.selected), names[cur], TAKES[ls.quantize]))
	im.Spacing()
	if modal_button(a, "Rename…") {
		begin_rename_sequence(a, slot)
		st.sequence_open = false
		im.CloseCurrentPopup()
	}
	im.SameLine()
	if modal_button(a, "Duplicate") {
		if to, r := pa.sequence_duplicate(&a.api, i64(slot)); r == .Ok do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("A copy: %s", pa_name(a, int(to))))
		st.sequence_open = false
		im.CloseCurrentPopup()
	}
	im.SameLine()
	if modal_button(a, "Clear") {
		pa.sequence_clear(&a.api, i64(slot))
		ui.toast(&a.ws.toasts, .Info, fmt.tprintf("%s cleared", pa_name(a, slot)))
	}
	im.SameLine()
	if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
		st.sequence_open = false
		im.CloseCurrentPopup()
	}
}

// Lane: a launcher lane's colour; Rename (its name dialog) (a
// controller's Select + the lane's upper button).
draw_lane_dialog :: proc(a: ^App) {
	st := &a.controls
	if st.lane_open {
		im.OpenPopup("Lane")
		if modal_begin(a, "Lane", &st.lane_open, {.AlwaysAutoResize}) {
			defer im.EndPopup()
			name, _ := pa.launcher_lane_name(&a.api, i64(st.lane))
			l, _ := pa.launcher_lane(&a.api, i64(st.lane))
			modal_text(a, fmt.tprintf("Lane %d: %s", st.lane + 1, name))
			own := u32(l.color)
			if n := modal_knob(a, "Colour", "None" if own == 0 else fmt.tprintf("#%06X", own)); n != 0 do pa.launcher_color_lane(&a.api, i64(st.lane), i64(swatch_step(own, n)))
			if modal_button(a, "Rename…") {
				st.lane_buf = {}
				copy(st.lane_buf[:len(st.lane_buf) - 1], name)
				st.lane_rename = true
				st.lane_open = false
				im.CloseCurrentPopup()
			}
			im.SameLine()
			if modal_button(a, "Close") || im.IsKeyPressed(.Escape) {
				st.lane_open = false
				im.CloseCurrentPopup()
			}
		}
		return
	}
	if !st.lane_rename do return
	im.OpenPopup("Rename Lane")
	if modal_begin(a, "Rename Lane", &st.lane_rename, {.AlwaysAutoResize}) {
		defer im.EndPopup()
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(260)
		done := modal_input(a, "##lane_rename", st.lane_buf[:], {.EnterReturnsTrue, .AutoSelectAll})
		if done || modal_button(a, "Rename") {
			pa.launcher_rename_lane(&a.api, i64(st.lane), strings.truncate_to_byte(string(st.lane_buf[:]), 0))
			st.lane_rename = false
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if modal_button(a, "Cancel") || im.IsKeyPressed(.Escape) {
			st.lane_rename = false
			im.CloseCurrentPopup()
		}
	}
}
