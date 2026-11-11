package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:dsp"
import "fire:sampler"

// The sampler's device tabs: Env, Filter, Pitch, LFO and Global. Each draws
// what it does to the sound (an envelope to drag, the filter's response, an
// LFO's trace) live: the newest voice's levels, the filter as modulation
// and automation move it.

// What the device tabs keep between frames: the LFOs' recent levels.
Device_State :: struct {
	trace:      [sampler.LFOS][TRACE_LEN]f32,
	trace_head: int,
	trace_pad:  int,
}

// Frames of LFO trace kept (two seconds at 60 frames a second).
TRACE_LEN :: 120

// Keys of the voice's settings for undo merging (`pm.set_voice`).
@(private)
Voice_Key :: enum {
	Amp_Adsr = 1, Filter, Slope, Cutoff, Resonance, Key_Track, Vel_Cutoff, Filter_Env, Filter_Adsr,
	Pitch_Env, Pitch_Adsr, Vel_Pitch, Pitch_Track, Fine, Voices,
	Lfo = 100, // + LFO × 10 + its field
	Route = 200, // + route × 10 + its field
}

// The selected pad's sampler now, and the seconds since its newest note.
@(private)
live_of :: proc(a: ^App) -> (l: sampler.Sampler_Live, seconds: f32) {
	l, _ = pm.pad_live(&a.m.engine, a.selected)
	sr := a.host.graph.settings.sample_rate
	return l, f32(f64(l.age) / sr) if sr > 0 else 0
}

// A knob for one f32 of the selected pad's voice.
@(private)
voice_knob :: proc(a: ^App, label: cstring, value: ^f32, lo, hi, def: f32, format: cstring, key: int, step: string, log_scale := false) {
	m := &a.m
	i := a.selected
	x := value^
	e := ui.knob(label, &x, lo, hi, def, format, log_scale = log_scale)
	if e.changed {
		v := m.project.pads[i].voice
		// The same field of a copy: value points into a copy of the voice.
		off := uintptr(value) - uintptr(&a.voice_edit)
		(^f32)(uintptr(&v) + off)^ = x
		pm.set_voice(m, i, key, step, v)
	}
	if e.ended do app.seal(&m.history)
}

// Sets one setting of the selected pad's voice from `v`, sealing it (a
// click, not a drag).
@(private)
put_voice :: proc(a: ^App, key: Voice_Key, step: string, v: pm.Voice) {
	pm.set_voice(&a.m, a.selected, int(key), step, v)
	app.seal(&a.m.history)
}

// The height of a row of knobs.
@(private)
knob_row_h :: proc() -> f32 {
	return im.GetTextLineHeight() * 2 + ui.KNOB_SIZE + 6 + 3 * im.GetStyle().ItemSpacing.y + 8
}

// --- Env --------------------------------------------------------------------------------------

// The amp envelope: a curve to drag (attack, decay to the sustain,
// release), the newest note's level on it, knobs under.
draw_env :: proc(a: ^App) {
	m := &a.m
	pad := m.project.pads[a.selected]
	a.voice_edit = pad.voice
	live, secs := live_of(a)
	avail := im.GetContentRegionAvail()
	adsr := [4]f32{pad.attack, pad.voice.decay, pad.voice.sustain, pad.release}
	e := ui.adsr_plot("amp envelope", &adsr, {avail.x, max(avail.y - knob_row_h() - 8, 90)}, ui.rgb(pad.color), f32(live.amp) if live.sounding else -1, secs)
	if e.changed {
		p := pad
		p.attack, p.voice.decay, p.voice.sustain, p.release = adsr[0], adsr[1], adsr[2], adsr[3]
		pm.set_pad(m, a.selected, .Voice, "Shape Envelope", p)
	}
	if e.ended do app.seal(&m.history)
	im.Spacing()
	knob_f32(a, "Attack", &pad.attack, 0.0005, 10, 0.001, "%.3f s", .Attack, "Set Attack", log_scale = true)
	im.SameLine(0, 14)
	voice_knob(a, "Decay", &a.voice_edit.decay, 0.005, 10, 1, "%.2f s", int(Voice_Key.Amp_Adsr), "Set Decay", true)
	im.SameLine(0, 14)
	voice_knob(a, "Sustain", &a.voice_edit.sustain, 0, 1, 1, "%.2f", int(Voice_Key.Amp_Adsr) + 1, "Set Sustain")
	im.SameLine(0, 14)
	knob_f32(a, "Release", &pad.release, 0.005, 20, 0.05, "%.2f s", .Release, "Set Release", log_scale = true)
}

// --- Filter -----------------------------------------------------------------------------------

FILTER_NAMES := [sampler.Voice_Filter]cstring{.Off = "Off", .Lowpass = "Low-pass", .Highpass = "High-pass", .Bandpass = "Band-pass", .Notch = "Notch"}

// Points of a filter's response in dB at RESPONSE_POINTS log-spaced
// frequencies (temp memory).
@(private)
response_db :: proc(type: sampler.Voice_Filter, steep: bool, cutoff, res: f64, sr: f64) -> []f32 {
	out := make([]f32, RESPONSE_POINTS, context.temp_allocator)
	if type == .Off do return out
	c, n := sampler.voice_filter_design(type, steep, cutoff, res, sr)
	for &v, k in out {
		hz := f64(ui.x_freq(f32(k) / (RESPONSE_POINTS - 1)))
		g := 1.0
		for st in 0 ..< n {
			gs, _ := dsp.svf_response(&c[st], hz, sr)
			g *= gs
		}
		v = f32(20 * math.log10(max(g, 1e-6)))
	}
	return out
}

@(private)
RESPONSE_POINTS :: 160

// A small button with a filter type's curve on it.
@(private)
filter_type_button :: proc(a: ^App, type: sampler.Voice_Filter, on: bool) -> bool {
	t := ui.theme()
	size := im.Vec2{52, 30}
	pos := im.GetCursorScreenPos()
	pressed := im.InvisibleButton(fmt.ctprintf("##ft%d", int(type)), size)
	ui.name(string(FILTER_NAMES[type]))
	hovered := im.IsItemHovered()
	if hovered do im.SetTooltip("%s", FILTER_NAMES[type])
	dl := im.GetWindowDrawList()
	bg := t.accent if on else (t.hover if hovered else t.raised)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(bg), 4)
	fg := t.bg if on else t.text
	if type == .Off {
		ts := im.CalcTextSize("Off")
		im.DrawList_AddText(dl, {pos.x + (size.x - ts.x) / 2, pos.y + (size.y - ts.y) / 2}, ui.col(fg), "Off")
		return pressed
	}
	db := response_db(type, false, 1000, 0.45, 48_000)
	pts: [24]im.Vec2
	for k in 0 ..< len(pts) {
		v := db[k * (RESPONSE_POINTS - 1) / (len(pts) - 1)]
		pts[k] = {pos.x + 6 + (size.x - 12) * f32(k) / f32(len(pts) - 1), pos.y + size.y * 0.42 - clamp(v, -24, 9) / 24 * size.y * 0.45}
	}
	im.DrawList_AddPolyline(dl, &pts[0], len(pts), ui.col(fg), 1.6)
	return pressed
}

// The filter: its type and slope, its response (the setting faint, what
// plays now bright: modulation and automation move it) with a handle
// (cutoff sideways, resonance up), its envelope, and knobs.
draw_filter :: proc(a: ^App) {
	m := &a.m
	pad := m.project.pads[a.selected]
	v := pad.voice
	a.voice_edit = v
	live, secs := live_of(a)
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	color := ui.rgb(pad.color)

	for type in sampler.Voice_Filter {
		if type != .Off do im.SameLine(0, 4)
		if filter_type_button(a, type, v.filter == type) {
			nv := v
			nv.filter = type
			put_voice(a, .Filter, "Filter Type", nv)
		}
	}
	im.SameLine(0, 16)
	slope := 1 if v.steep else 0
	if ui.segmented("slope", {"12 dB", "24 dB"}, &slope) {
		nv := v
		nv.steep = slope == 1
		put_voice(a, .Slope, "Filter Slope", nv)
	}
	im.Spacing()

	avail := im.GetContentRegionAvail()
	plot_h := max(avail.y - knob_row_h() - 8, 90)
	resp_w := avail.x * 0.6
	curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
	setting := response_db(v.filter, v.steep, f64(v.cutoff), f64(v.resonance), sr)
	dim := ui.mix(ui.PLOT_BG, color, 0.55)
	if v.filter == .Off {
		append(&curves, ui.Plot_Curve{db = setting, color = dim, width = 1.5})
	} else if live.sounding || abs(live.cutoff - f64(v.cutoff)) > 0.5 {
		// What plays (or automation has it at), bright over the setting.
		append(&curves, ui.Plot_Curve{db = setting, color = dim, width = 1.5})
		append(&curves, ui.Plot_Curve{db = response_db(v.filter, v.steep, live.cutoff, live.resonance, sr), color = color, fill = true, width = 2.5})
	} else {
		append(&curves, ui.Plot_Curve{db = setting, color = color, fill = true, width = 2.5})
	}
	handle := [2]f32{ui.freq_x(v.cutoff), v.resonance * 24}
	e := ui.response_plot("filter response", curves[:], &handle, {resp_w, plot_h})
	if e.changed {
		nv := v
		nv.cutoff = ui.x_freq(handle[0])
		nv.resonance = clamp(handle[1] / 24, 0, 1)
		if nv.filter == .Off do nv.filter = .Lowpass // dragging it turns it on
		pm.set_voice(m, a.selected, int(Voice_Key.Cutoff), "Set Cutoff", nv)
	}
	if e.ended do app.seal(&m.history)
	if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%.0f Hz, resonance %.0f%%: drag sideways for the cutoff, up for resonance (Shift: fine)", v.cutoff, v.resonance * 100))
	im.SameLine(0, 8)
	fa := v.filter_adsr
	fe := ui.adsr_plot("filter envelope", &fa, {avail.x - resp_w - 8, plot_h}, color, f32(live.filter_env) if live.sounding else -1, secs, v.filter_env)
	if fe.changed {
		nv := v
		nv.filter_adsr = fa
		pm.set_voice(m, a.selected, int(Voice_Key.Filter_Adsr), "Shape Filter Envelope", nv)
	}
	if fe.ended do app.seal(&m.history)

	im.Spacing()
	voice_knob(a, "Cutoff", &a.voice_edit.cutoff, 20, 20_000, 20_000, "%.0f Hz", int(Voice_Key.Cutoff), "Set Cutoff", true)
	im.SameLine(0, 14)
	voice_knob(a, "Resonance", &a.voice_edit.resonance, 0, 1, 0, "%.2f", int(Voice_Key.Resonance), "Set Resonance")
	im.SameLine(0, 14)
	voice_knob(a, "Key", &a.voice_edit.key_track, 0, 1, 0, "%.2f", int(Voice_Key.Key_Track), "Set Key Tracking")
	im.SameLine(0, 14)
	voice_knob(a, "Velocity", &a.voice_edit.vel_cutoff, -1, 1, 0, "%+.2f", int(Voice_Key.Vel_Cutoff), "Set Filter Velocity")
	im.SameLine(0, 14)
	voice_knob(a, "Env", &a.voice_edit.filter_env, -1, 1, 0, "%+.2f", int(Voice_Key.Filter_Env), "Set Filter Envelope")
	im.SameLine(0, 28)
	adsr_knobs(a, &a.voice_edit.filter_adsr, int(Voice_Key.Filter_Adsr), "Filter")
}

// Knobs for an envelope of the voice (attack, decay, sustain, release).
@(private)
adsr_knobs :: proc(a: ^App, adsr: ^[4]f32, key: int, what: string) {
	voice_knob(a, "A", &adsr[0], 0.0005, 10, 0.001, "%.3f s", key, fmt.tprintf("Set %s Attack", what), true)
	im.SameLine(0, 10)
	voice_knob(a, "D", &adsr[1], 0.005, 10, 0.5, "%.2f s", key, fmt.tprintf("Set %s Decay", what), true)
	im.SameLine(0, 10)
	voice_knob(a, "S", &adsr[2], 0, 1, 0, "%.2f", key, fmt.tprintf("Set %s Sustain", what))
	im.SameLine(0, 10)
	voice_knob(a, "R", &adsr[3], 0.005, 20, 0.2, "%.2f s", key, fmt.tprintf("Set %s Release", what), true)
}

// --- Pitch ------------------------------------------------------------------------------------

// The pitch envelope (drawn as deep as its amount, upside down for a
// negative one), what it does to the newest note now, and knobs.
draw_pitch :: proc(a: ^App) {
	m := &a.m
	pad := m.project.pads[a.selected]
	v := pad.voice
	a.voice_edit = v
	live, secs := live_of(a)
	color := ui.rgb(pad.color)
	avail := im.GetContentRegionAvail()
	plot_h := max(avail.y - knob_row_h() - 8, 90)
	readout_w: f32 = 150
	pa := v.pitch_adsr
	e := ui.adsr_plot("pitch envelope", &pa, {avail.x - readout_w - 8, plot_h}, color, f32(live.pitch_env) if live.sounding else -1, secs, v.pitch_env / 48)
	if e.changed {
		nv := v
		nv.pitch_adsr = pa
		pm.set_voice(m, a.selected, int(Voice_Key.Pitch_Adsr), "Shape Pitch Envelope", nv)
	}
	if e.ended do app.seal(&m.history)
	// Now: how far the envelope has the note.
	im.SameLine(0, 8)
	pos := im.GetCursorScreenPos()
	im.Dummy({readout_w, plot_h})
	ui.name("pitch now")
	dl := im.GetWindowDrawList()
	t := ui.theme()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + readout_w, pos.y + plot_h}, ui.col(ui.PLOT_BG), t.radius)
	now := f64(v.pitch_env) * live.pitch_env if live.sounding else 0
	im.PushFontFloat(a.platform.fonts.semibold, 26)
	txt := fmt.ctprintf("%+.1f", now + f64(pad.pitch) + f64(v.fine) / 100)
	ts := im.CalcTextSize(txt)
	im.DrawList_AddText(dl, {pos.x + (readout_w - ts.x) / 2, pos.y + plot_h / 2 - ts.y}, ui.col(color if live.sounding else t.text_dim), txt)
	im.PopFont()
	sub := cstring("semitones")
	ss := im.CalcTextSize(sub)
	im.DrawList_AddText(dl, {pos.x + (readout_w - ss.x) / 2, pos.y + plot_h / 2 + 4}, ui.col(t.text_dim), sub)
	// A bar from the middle: up or down by what the envelope adds.
	bar := f32(clamp(now / 24, -1, 1)) * (plot_h / 2 - 16)
	mid := pos.y + plot_h / 2
	im.DrawList_AddRectFilled(dl, {pos.x + readout_w - 14, min(mid, mid - bar)}, {pos.x + readout_w - 8, max(mid, mid - bar)}, ui.col(color), 2)

	im.Spacing()
	voice_knob(a, "Amount", &a.voice_edit.pitch_env, -48, 48, 0, "%+.1f st", int(Voice_Key.Pitch_Env), "Set Pitch Envelope")
	im.SameLine(0, 14)
	voice_knob(a, "Velocity", &a.voice_edit.vel_pitch, -24, 24, 0, "%+.1f st", int(Voice_Key.Vel_Pitch), "Set Pitch Velocity")
	im.SameLine(0, 14)
	voice_knob(a, "Key", &a.voice_edit.pitch_track, 0, 1, 1, "%.2f", int(Voice_Key.Pitch_Track), "Set Pitch Key Tracking")
	im.SameLine(0, 28)
	adsr_knobs(a, &a.voice_edit.pitch_adsr, int(Voice_Key.Pitch_Adsr), "Pitch")
}

// --- LFO --------------------------------------------------------------------------------------

LFO_SHAPE_NAMES := [sampler.Lfo_Shape]cstring{.Sine = "Sine", .Triangle = "Triangle", .Saw_Up = "Saw up", .Saw_Down = "Saw down", .Square = "Square", .Sample_Hold = "Sample & hold"}
MOD_DEST_NAMES := [sampler.Mod_Dest]cstring{.None = "—", .Volume = "Volume", .Pan = "Pan", .Pitch = "Pitch", .Cutoff = "Cutoff", .Resonance = "Resonance"}

// One cycle of an LFO shape, `n` points (temp memory).
@(private)
shape_points :: proc(shape: sampler.Lfo_Shape, n: int) -> []f32 {
	out := make([]f32, n, context.temp_allocator)
	for &v, k in out {
		f := f64(k) / f64(n)
		switch shape {
		case .Sine:     v = f32(math.sin(math.TAU * f))
		case .Triangle: v = f32(1 - 4 * abs(f - 0.5))
		case .Saw_Up:   v = f32(2 * f - 1)
		case .Saw_Down: v = f32(1 - 2 * f)
		case .Square:   v = 1 if f < 0.5 else -1
		case .Sample_Hold:
			steps := [8]f32{0.6, -0.3, 0.9, -0.8, 0.2, -0.5, 0.7, -0.1}
			v = steps[int(f * 8)]
		}
	}
	return out
}

// A small button with a waveform on it.
@(private)
shape_button :: proc(k: int, shape: sampler.Lfo_Shape, on: bool) -> bool {
	t := ui.theme()
	size := im.Vec2{36, 26}
	pos := im.GetCursorScreenPos()
	pressed := im.InvisibleButton(fmt.ctprintf("##lfo%d_%d", k, int(shape)), size)
	ui.name(fmt.tprintf("LFO %d %s", k + 1, LFO_SHAPE_NAMES[shape]))
	hovered := im.IsItemHovered()
	if hovered do im.SetTooltip("%s", LFO_SHAPE_NAMES[shape])
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(t.accent if on else (t.hover if hovered else t.raised)), 4)
	pts := shape_points(shape, 16)
	line: [17]im.Vec2
	for k2 in 0 ..= 16 do line[k2] = {pos.x + 5 + (size.x - 10) * f32(k2) / 16, pos.y + size.y / 2 - pts[k2 % 16] * (size.y / 2 - 6)}
	im.DrawList_AddPolyline(dl, &line[0], 17, ui.col(t.bg if on else t.text), 1.5)
	return pressed
}

// The two LFOs side by side: shape, mode, rate (or a synced rate), fade-in
// and phase; their traces scrolling; three routes each.
draw_lfo :: proc(a: ^App) {
	m := &a.m
	pad := m.project.pads[a.selected]
	v := pad.voice
	a.voice_edit = v
	live, _ := live_of(a)
	st := &a.device
	if st.trace_pad != a.selected {
		st^ = {trace_pad = a.selected}
	}
	for k in 0 ..< sampler.LFOS do st.trace[k][st.trace_head] = f32(live.lfo[k])
	st.trace_head = (st.trace_head + 1) % TRACE_LEN
	colors := [2]ui.Color{ui.rgb(pad.color), ui.rgb(0xf5a623)}
	avail := im.GetContentRegionAvail()
	col_w := (avail.x - 12) / 2
	for k in 0 ..< sampler.LFOS {
		if k > 0 do im.SameLine(0, 12)
		im.BeginGroup()
		im.PushClipRect(im.GetCursorScreenPos(), {im.GetCursorScreenPos().x + col_w, im.GetCursorScreenPos().y + avail.y}, true)
		defer im.PopClipRect()
		im.PushIDInt(i32(k))
		l := v.lfos[k]
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)colors[k], "%s", fmt.ctprintf("LFO %d", k + 1))
		im.SameLine(0, 12)
		for shape in sampler.Lfo_Shape {
			if shape != .Sine do im.SameLine(0, 3)
			if shape_button(k, shape, l.shape == shape) {
				nv := v
				nv.lfos[k].shape = shape
				put_voice(a, Voice_Key(int(Voice_Key.Lfo) + k * 10), "LFO Shape", nv)
			}
		}
		trace_h := max(avail.y - knob_row_h() - 2 * im.GetFrameHeightWithSpacing() - 24 - 3 * (im.GetFrameHeight() + 4), 50)
		ui.trace_plot(fmt.ctprintf("lfo %d trace", k + 1), st.trace[k][:], st.trace_head, shape_points(l.shape, 64), {col_w, trace_h}, colors[k])
		lk := &a.voice_edit.lfos[k]
		key := int(Voice_Key.Lfo) + k * 10
		// How it runs, then its rate (Hz, or synced), fade-in and phase.
		im.BeginGroup()
		im.TextDisabled("Mode")
		mode := int(l.mode)
		if ui.segmented("mode", {"Auto", "Trigger", "Sync"}, &mode) {
			nv := v
			nv.lfos[k].mode = sampler.Lfo_Mode(mode)
			put_voice(a, Voice_Key(key + 1), "LFO Mode", nv)
		}
		im.EndGroup()
		im.SameLine(0, 14)
		if l.mode == .Sync {
			im.BeginGroup()
			im.TextDisabled("Rate")
			sync := i32(l.sync)
			names := [len(sampler.LFO_SYNC_NAMES)]cstring{}
			for n, j in sampler.LFO_SYNC_NAMES do names[j] = fmt.ctprintf("%s", n)
			im.SetNextItemWidth(90)
			if ui.combo_char("##sync", &sync, &names[0], i32(len(names))) {
				nv := v
				nv.lfos[k].sync = u8(sync)
				put_voice(a, Voice_Key(key + 2), "LFO Rate", nv)
			}
			im.EndGroup()
		} else {
			voice_knob(a, "Rate", &lk.rate, 0.01, 40, 2, "%.2f Hz", key + 2, "LFO Rate", true)
		}
		im.SameLine(0, 14)
		voice_knob(a, "Fade in", &lk.fade, 0, 10, 0, "%.2f s", key + 3, "LFO Fade In")
		im.SameLine(0, 14)
		voice_knob(a, "Phase", &lk.phase, 0, 360, 0, "%.0f°", key + 4, "LFO Phase")
		// Its routes: where it goes, and how far.
		for r in k * 3 ..< k * 3 + 3 {
			route := v.routes[r]
			im.PushIDInt(i32(r))
			im.SetNextItemWidth(120)
			dest := i32(route.dest)
			names := [len(MOD_DEST_NAMES)]cstring{}
			for n, j in MOD_DEST_NAMES do names[j] = n
			if ui.combo_char(fmt.ctprintf("##dest%d", r), &dest, &names[0], i32(len(names))) {
				nv := v
				nv.routes[r] = {source = sampler.Mod_Source(k + 1), dest = sampler.Mod_Dest(dest), amount = route.amount if route.amount != 0 else 0.5}
				put_voice(a, Voice_Key(int(Voice_Key.Route) + r * 10), "Route LFO", nv)
			}
			ui.name(fmt.tprintf("LFO %d route %d", k + 1, r % 3 + 1))
			im.SameLine(0, 8)
			amt := route.amount * 100
			im.SetNextItemWidth(col_w - 128)
			im.BeginDisabled(route.dest == .None)
			if im.SliderFloat(fmt.ctprintf("##amt%d", r), &amt, -100, 100, "%+.0f%%") {
				nv := v
				nv.routes[r].amount = amt / 100
				pm.set_voice(m, a.selected, int(Voice_Key.Route) + r * 10 + 1, "Route Amount", nv)
			}
			if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
			im.EndDisabled()
			im.PopID()
		}
		im.PopID()
		im.EndGroup()
	}
}

// --- Global -----------------------------------------------------------------------------------

// What the whole pad is: a sampler or an audio track, its name and colour,
// level, pan, choke group, transposition, fine tuning, how many notes at
// once; an audio pad's input and arming.
draw_global :: proc(a: ^App) {
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
	if s := pm.pad_sample(m, i); s != nil {
		im.TextDisabled("%s", fmt.ctprintf("%s · %.2f s · %.0f Hz · %s", s.name, f64(s.frames) / s.rate, s.rate, "stereo" if s.channels > 1 else "mono"))
	} else {
		im.TextDisabled("Empty: drop a sample here, or use File > Import")
	}
	wide := im.GetContentRegionAvail().x >= 560
	if wide && !im.BeginTable("##global", 3, {.BordersInnerV}) do wide = false
	defer if wide do im.EndTable()
	if wide {
		im.TableSetupColumn("a", {.WidthStretch}, 1)
		im.TableSetupColumn("b", {.WidthFixed}, 4 * (ui.KNOB_SIZE + 14) + 20)
		im.TableSetupColumn("c", {.WidthStretch}, 1)
		im.TableNextColumn()
		section(a, "Pad", false)
	}
	pad_name_colour(a, i)

	if wide do im.TableNextColumn()
	section(a, "Sound", !wide)
	a.voice_edit = pad.voice
	knob_f32(a, "Volume", &pad.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	im.SameLine(0, 14)
	knob_f32(a, "Pan", &pad.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	im.SameLine(0, 14)
	knob_f32(a, "Transpose", &pad.pitch, -24, 24, 0, "%+.1f st", .Pitch, "Set Pitch")
	im.SameLine(0, 14)
	voice_knob(a, "Fine", &a.voice_edit.fine, -100, 100, 0, "%+.0f ct", int(Voice_Key.Fine), "Fine Tune")

	if wide do im.TableNextColumn()
	section(a, "Voices", !wide)
	voices := i32(pad.voice.voices)
	im.SetNextItemWidth(140)
	if im.SliderInt("##voices", &voices, 1, 32, "%d at once") {
		nv := pad.voice
		nv.voices = int(voices)
		pm.set_voice(m, i, int(Voice_Key.Voices), "Set Voices", nv)
	}
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	if im.IsItemHovered() do im.SetTooltip("How many notes it plays at once (more steal the oldest)")
	im.Spacing()
	im.Spacing()
	if im.Button(ui.ICON_ERASER + "  Clear Pad") do pm.clear_pad(m, i)
}

// The selected pad's EQ, over the effect being edited.
draw_pad_eq :: proc(a: ^App) {
	pad := a.m.project.pads[a.selected]
	section(a, fmt.ctprintf("%s EQ", pm.pad_label(a.selected)), false)
	knob_f32(a, "Low", &pad.eq[0], -15, 15, 0, "%+.1f dB", .Eq_Low, "Set EQ Low")
	im.SameLine(0, 14)
	knob_f32(a, "Mid", &pad.eq[1], -15, 15, 0, "%+.1f dB", .Eq_Mid, "Set EQ Mid")
	im.SameLine(0, 14)
	knob_f32(a, "High", &pad.eq[2], -15, 15, 0, "%+.1f dB", .Eq_High, "Set EQ High")
	im.Spacing()
}
