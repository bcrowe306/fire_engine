package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:synth"

// The synth's editors that draw: its filters' responses, its envelopes
// and its LFO shapes.

// --- Filter --------------------------------------------------------------------------------------

// A filter's response, measured (an impulse through the real filter) and
// kept until its settings change.
Filter_Curve :: struct {
	params: fx.Filter_Params,
	sr:     f64,
	db:     [RESPONSE_POINTS]f32,
	set:    bool,
}

FILTER_MODEL_NAMES := []string{"Analog", "Dirty", "Ladder", "Digital", "Diode", "Formant", "Comb", "Phaser"}
FORMANT_STYLE_NAMES := []string{"A O I E", "A I U O"}
COMB_STYLE_NAMES := []string{"Low/high comb", "Low/high flange +", "Low/high flange −", "Band comb", "Band flange +", "Band flange −"}
PHASER_STYLE_NAMES := []string{"Peaks", "Notches"}
FILTER_STYLE_NAMES := []string{"12 dB", "24 dB", "Notch / pass swap", "Dual notch / band", "Band / peak / notch", "Shelving"}

// The styles a model has (their names).
filter_style_names :: proc(model: fx.Filter_Model) -> []string {
	#partial switch model {
	case .Formant: return FORMANT_STYLE_NAMES
	case .Comb:    return COMB_STYLE_NAMES
	case .Phaser:  return PHASER_STYLE_NAMES
	case .Digital: return FILTER_STYLE_NAMES
	case .Diode:   return FILTER_STYLE_NAMES[:2]
	}
	return FILTER_STYLE_NAMES[:5]
}

// [control] The response of a filter with `p` (an impulse, 4096 samples,
// its spectrum read at the plot's points).
measure_filter :: proc(c: ^Filter_Curve, p: fx.Filter_Params, sr: f64) {
	if c.set && c.params == p && c.sr == sr do return
	c.params, c.sr, c.set = p, sr, true
	N :: 4096
	f := new(fx.Filter_State, context.temp_allocator)
	x := make([]f32, N, context.temp_allocator)
	y := make([]f32, N, context.temp_allocator)
	r := make([]f32, N, context.temp_allocator)
	keys := make([]f32, 64, context.temp_allocator)
	for &k in keys do k = p.cutoff
	x[0] = 0.25 // (small: the nonlinear models stay near their linear selves)
	pp := p
	for at := 0; at < N; at += 64 {
		in_ := [2][]f32{x[at:at + 64], x[at:at + 64]}
		out := [2][]f32{y[at:at + 64], r[at:at + 64]}
		fx.filter_render(f, &pp, keys, &in_, &out, sr)
	}
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, N, allocator = context.temp_allocator)
	spec := make([]complex64, N / 2, context.temp_allocator)
	dsp.real_fft_forward(&fft, y, spec)
	for &v, k in c.db {
		hz := f64(ui.x_freq(f32(k) / (RESPONSE_POINTS - 1)))
		bin := clamp(int(hz / sr * N + 0.5), 1, N / 2 - 1)
		g := abs(spec[bin]) / 0.25
		v = f32(20 * math.log10(max(f64(g), 1e-6)))
	}
}

// The Filter tab: both filters side by side, each its model, style,
// response (measured, the cutoff handle to drag) and knobs.
draw_synth_filter :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	avail := im.GetContentRegionAvail()
	w := (avail.x - 16) / 2
	top := im.GetCursorScreenPos()
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	for k in 0 ..< synth.FILTERS {
		n := k + 1
		f :: synth.filter_param
		im.SetCursorScreenPos({top.x + f32(k) * (w + 16), top.y})
		im.PushIDInt(i32(k))
		synth_toggle(a, fmt.ctprintf("Filter %d", n), f(n, .On))
		im.SameLine(0, 10)
		synth_choice(a, f(n, .Model), FILTER_MODEL_NAMES, 84, "##model")
		model := fx.Filter_Model(int(pm.synth_value(m, i, f(n, .Model))))
		im.SameLine(0, 6)
		synth_choice(a, f(n, .Style), filter_style_names(model), 110, "##style")
		if n == 2 {
			im.SameLine(0, 8)
			serial := pm.synth_value(m, i, f(n, .From_Filter)) > 0.5
			if ui.icon_button(ui.ICON_LINK, "In series: filter 1's output into filter 2 (off: side by side)", on = serial) {
				pm.set_synth_value(m, i, f(n, .From_Filter), 0 if serial else 1, "Filters in Series")
				app.seal(&m.history)
			}
			ui.name("filters in series")
		}
		// The response, and its cutoff (and resonance) handle.
		im.SetCursorScreenPos({top.x + f32(k) * (w + 16), im.GetCursorScreenPos().y + 4})
		p := filter_ui_params(a, n)
		c := &a.synth_ui.response[k]
		measure_filter(c, p, sr)
		on := pm.synth_value(m, i, f(n, .On)) > 0.5
		color := ui.rgb(m.project.pads[i].color)
		if !on do color = ui.mix(ui.PLOT_BG, color, 0.4)
		curves := []ui.Plot_Curve{{db = c.db[:], color = color, fill = true, width = 2.5}}
		h := max(avail.y - im.GetTextLineHeight() * 2 - ui.KNOB_SIZE - 60, 80)
		handle := [2]f32{ui.freq_x(fx.key_to_hz(p.cutoff)), p.resonance * 24}
		e := ui.response_plot("synth filter response", curves, &handle, {w, h})
		if e.changed {
			hz := ui.x_freq(handle[0])
			pm.set_synth_value(m, i, f(n, .Cutoff), 69 + 12 * math.log2(hz / 440), "Filter Cutoff")
			pm.set_synth_value(m, i, f(n, .Resonance), clamp(handle[1] / 24, 0, 1), "Filter Cutoff")
		}
		if e.ended do app.seal(&m.history)
		// Its knobs (the model's own as well).
		im.SetCursorScreenPos({top.x + f32(k) * (w + 16), im.GetCursorScreenPos().y + 4})
		knobs := make([dynamic]Knob, context.temp_allocator)
		append(&knobs, Knob{"Cutoff", f(n, .Cutoff)}, Knob{"Resonance", f(n, .Resonance)})
		#partial switch model {
		case .Formant:
			append(&knobs, Knob{"Vowel X", f(n, .Formant_X)}, Knob{"Vowel Y", f(n, .Formant_Y)}, Knob{"Formant", f(n, .Formant_Transpose)}, Knob{"Q", f(n, .Formant_Resonance)}, Knob{"Spread", f(n, .Formant_Spread)})
		case .Comb:
			append(&knobs, Knob{"Blend", f(n, .Blend)}, Knob{"Offset", f(n, .Comb_Offset)})
		case:
			append(&knobs, Knob{"Drive", f(n, .Drive)}, Knob{"Blend", f(n, .Blend)})
			if p.style == .Shelving do append(&knobs, Knob{"Gain", f(n, .Gain)})
		}
		append(&knobs, Knob{"Key", f(n, .Keytrack)}, Knob{"Mix", f(n, .Mix)})
		synth_knob_row(a, w, knobs[:])
		im.PopID()
	}
}

// Filter `n`'s settings as they stand (no modulation), for its picture.
filter_ui_params :: proc(a: ^App, n: int) -> fx.Filter_Params {
	m := &a.m
	i := a.selected
	f :: synth.filter_param
	v :: proc(m: ^pm.Model, i: int, id: fc.Param_Id) -> f32 { return synth.param_curve(synth.param_spec(id), pm.synth_value(m, i, id)) }
	return {
		model = fx.Filter_Model(int(v(m, i, f(n, .Model)))), style = fx.Filter_Style(int(v(m, i, f(n, .Style)))),
		cutoff = v(m, i, f(n, .Cutoff)), resonance = v(m, i, f(n, .Resonance)), drive_db = v(m, i, f(n, .Drive)),
		blend = v(m, i, f(n, .Blend)), mix = v(m, i, f(n, .Mix)), gain_db = v(m, i, f(n, .Gain)),
		formant_x = v(m, i, f(n, .Formant_X)), formant_y = v(m, i, f(n, .Formant_Y)),
		formant_transpose = v(m, i, f(n, .Formant_Transpose)), formant_resonance = v(m, i, f(n, .Formant_Resonance)),
		formant_spread = v(m, i, f(n, .Formant_Spread)), comb_offset = v(m, i, f(n, .Comb_Offset)),
	}
}

// --- Env -----------------------------------------------------------------------------------------

// The curve a power puts on t (as the synth's envelopes do).
@(private)
curve :: proc(t, power: f32) -> f32 {
	if abs(power) < 0.01 do return t
	return (math.exp(power * t) - 1) / (math.exp(power) - 1)
}

// The Env tab: which envelope (1 is the amp's), its curve to drag (the
// attack's, decay's and release's ends; the segments up and down for
// their curves), a dot where the newest note has it, and knobs.
draw_synth_env :: proc(a: ^App) {
	st := &a.synth_ui
	names := []string{"Env 1 (amp)", "Env 2", "Env 3", "Env 4", "Env 5", "Env 6"}
	ui.segmented("synth_env", names, &st.env)
	n := st.env + 1
	im.SameLine(0, 14)
	mod_chip(a, synth.Mod_Source(int(synth.Mod_Source.Env_1) + st.env))
	im.Spacing()
	avail := im.GetContentRegionAvail()
	h := max(avail.y - im.GetTextLineHeight() * 2 - ui.KNOB_SIZE - 30, 80)
	env_editor(a, n, {avail.x, h})
	im.Spacing()
	e :: synth.env_param
	synth_knob_row(a, avail.x, {{"Delay", e(n, .Delay)}, {"Attack", e(n, .Attack)}, {"Hold", e(n, .Hold)}, {"Decay", e(n, .Decay)}, {"Sustain", e(n, .Sustain)}, {"Release", e(n, .Release)}, {"A Curve", e(n, .Attack_Power)}, {"D Curve", e(n, .Decay_Power)}, {"R Curve", e(n, .Release_Power)}})
}

// Envelope `n`'s curve, `size` big: delay, attack, hold, decay, a stretch
// of sustain, release, each time on a log width. Handles: the attack's
// peak (sideways), the decay's end (sideways, and up and down: the
// sustain), the release's end (sideways); a segment dragged up and down
// bends its curve.
env_editor :: proc(a: ^App, n: int, size: im.Vec2) {
	m := &a.m
	i := a.selected
	t := ui.theme()
	e :: synth.env_param
	sec :: proc(m: ^pm.Model, i: int, id: fc.Param_Id) -> f32 { return synth.param_curve(synth.param_spec(id), pm.synth_value(m, i, id)) }
	delay, attack, hold := sec(m, i, e(n, .Delay)), sec(m, i, e(n, .Attack)), sec(m, i, e(n, .Hold))
	decay, sustain, release := sec(m, i, e(n, .Decay)), sec(m, i, e(n, .Sustain)), sec(m, i, e(n, .Release))
	ap, dp, rp := sec(m, i, e(n, .Attack_Power)), sec(m, i, e(n, .Decay_Power)), sec(m, i, e(n, .Release_Power))
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##envplot", size, {.MouseButtonLeft})
	ui.name("synth envelope")
	hovered := im.IsItemHovered()
	active := im.IsItemActive()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	pad: f32 = 10
	x0, x1 := pos.x + pad, pos.x + size.x - pad
	top, bot := pos.y + pad, pos.y + size.y - pad
	iw := x1 - x0
	// Each time's width: log, up to a sixth of the plot.
	MAX_T :: f32(32.0)
	width :: proc(t: f32, iw: f32) -> f32 { return iw / 6 * math.log10(1 + max(t, 0) * 100) / math.log10(1 + MAX_T * 100) }
	time_of :: proc(w: f32, iw: f32) -> f32 {
		x := clamp(w / (iw / 6), 0, 1) * math.log10(1 + MAX_T * 100)
		return (math.pow(f32(10), x) - 1) / 100
	}
	xd := x0 + width(delay, iw)
	xa := xd + width(attack, iw)
	xh := xa + width(hold, iw)
	xdc := xh + width(decay, iw)
	xs := xdc + iw * 0.12
	xr := xs + width(release, iw)
	ys := bot - sustain * (bot - top)
	grid := ui.mix(ui.PLOT_BG, t.text, 0.08)
	for k in 1 ..< 4 do im.DrawList_AddLine(dl, {x0, top + (bot - top) * f32(k) / 4}, {x1, top + (bot - top) * f32(k) / 4}, ui.col(grid), 1)
	color := mod_color(synth.Mod_Source(int(synth.Mod_Source.Env_1) + n - 1))
	// The curve, segment by segment.
	pts := make([dynamic]im.Vec2, context.temp_allocator)
	seg :: proc(pts: ^[dynamic]im.Vec2, xa, xb, ya, yb, power: f32, rising: bool) {
		N :: 32
		for k in 0 ..= N {
			u := f32(k) / N
			c := curve(u, power)
			append(pts, im.Vec2{xa + (xb - xa) * u, ya + (yb - ya) * c})
		}
	}
	append(&pts, im.Vec2{x0, bot}, im.Vec2{xd, bot})
	seg(&pts, xd, xa, bot, top, -ap, true)
	append(&pts, im.Vec2{xh, top})
	seg(&pts, xh, xdc, top, ys, dp, false)
	append(&pts, im.Vec2{xs, ys})
	seg(&pts, xs, xr, ys, bot, rp, false)
	for k in 1 ..< len(pts) do im.DrawList_AddLine(dl, pts[k - 1], pts[k], ui.col(color), 2)
	// Handles.
	Handle :: enum {None, Attack, Decay, Release, A_Curve, D_Curve, R_Curve}
	@(static) dragging: Handle
	hp := [3]im.Vec2{{xa, top}, {xdc, ys}, {xr, bot}}
	mp := im.GetIO().MousePos
	near := Handle.None
	if hovered || active {
		for p, k in hp do if abs(mp.x - p.x) < 8 && abs(mp.y - p.y) < 8 do near = Handle(k + 1)
		if near == .None {
			switch {
			case mp.x > xd && mp.x < xa: near = .A_Curve
			case mp.x > xh && mp.x < xdc: near = .D_Curve
			case mp.x > xs && mp.x < xr: near = .R_Curve
			}
		}
	}
	if im.IsItemActivated() do dragging = near
	for p, k in hp do im.DrawList_AddCircleFilled(dl, p, 5 if near == Handle(k + 1) || dragging == Handle(k + 1) else 4, ui.col(color))
	set :: proc(m: ^pm.Model, i: int, id: fc.Param_Id, seconds: f32, name: string) {
		pm.set_synth_value(m, i, id, math.pow(max(seconds, 0), 0.25), name) // (times are kept as their fourth root)
	}
	if active && dragging != .None {
		io := im.GetIO()
		switch dragging {
		case .None:
		case .Attack:  set(m, i, e(n, .Attack), time_of(mp.x - xd, iw), "Shape Envelope")
		case .Decay:
			set(m, i, e(n, .Decay), time_of(mp.x - xh, iw), "Shape Envelope")
			pm.set_synth_value(m, i, e(n, .Sustain), clamp((bot - mp.y) / (bot - top), 0, 1), "Shape Envelope")
		case .Release: set(m, i, e(n, .Release), time_of(mp.x - xs, iw), "Shape Envelope")
		case .A_Curve: pm.set_synth_value(m, i, e(n, .Attack_Power), clamp(ap - io.MouseDelta.y * 0.1, -20, 20), "Shape Envelope")
		case .D_Curve: pm.set_synth_value(m, i, e(n, .Decay_Power), clamp(dp + io.MouseDelta.y * 0.1, -20, 20), "Shape Envelope")
		case .R_Curve: pm.set_synth_value(m, i, e(n, .Release_Power), clamp(rp + io.MouseDelta.y * 0.1, -20, 20), "Shape Envelope")
		}
	}
	if im.IsItemDeactivated() {
		dragging = .None
		app.seal(&m.history)
	}
	if near == .A_Curve || near == .D_Curve || near == .R_Curve do im.SetMouseCursor(.ResizeNS)
	else if near != .None do im.SetMouseCursor(.ResizeEW)
	// Where the newest note has it.
	if live, ok := pm.synth_live(&m.engine, i); ok && live.sounding {
		v := live.envs[n - 1]
		im.DrawList_AddLine(dl, {x0, bot - v * (bot - top)}, {x1, bot - v * (bot - top)}, ui.col(ui.with_alpha(color, 0.35)), 1)
		im.DrawList_AddCircleFilled(dl, {x0 + 6, bot - v * (bot - top)}, 4, ui.col(t.text))
	}
}

// --- LFO -----------------------------------------------------------------------------------------

LFO_MODE_NAMES := []string{"Trigger", "Sync", "Envelope", "Sustain env", "Loop point", "Loop hold"}
LFO_RATE_NAMES := []string{"Seconds", "Tempo", "Dotted", "Triplet", "Key"}

// The LFO tab: which LFO, its shape to draw (drag points; double-click
// adds one, right-click takes one away; drag a segment up and down to
// bend it), presets, its mode and rate, and knobs.
draw_synth_lfo :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	st := &a.synth_ui
	names := []string{"1", "2", "3", "4", "5", "6", "7", "8", "R1", "R2", "R3", "R4"}
	im.AlignTextToFramePadding()
	im.TextDisabled("LFO")
	im.SameLine()
	ui.segmented("synth_lfo", names, &st.lfo)
	if st.lfo >= synth.LFOS {
		draw_synth_random(a, st.lfo - synth.LFOS + 1)
		return
	}
	n := st.lfo + 1
	l :: synth.lfo_param
	im.SameLine(0, 14)
	mod_chip(a, synth.Mod_Source(int(synth.Mod_Source.Lfo_1) + st.lfo))
	im.SameLine(0, 14)
	synth_choice(a, l(n, .Mode), LFO_MODE_NAMES, 110, "##lfomode")
	im.SameLine(0, 6)
	synth_choice(a, l(n, .Rate), LFO_RATE_NAMES, 90, "##lforate")
	im.SameLine(0, 10)
	im.SetNextItemWidth(100)
	if ui.combo("##lfopreset", "Shape…") {
		for p in synth.Lfo_Preset do if im.Selectable(fmt.ctprintf("%v", p)) {
			pm.set_synth_shape(m, i, st.lfo, synth.lfo_preset(p), "LFO Shape")
			app.seal(&m.history)
		}
		im.EndCombo()
	}
	im.SameLine(0, 10)
	synth_toggle(a, "Smooth", l(n, .Smooth))
	im.Spacing()
	avail := im.GetContentRegionAvail()
	h := max(avail.y - im.GetTextLineHeight() * 2 - ui.KNOB_SIZE - 30, 80)
	lfo_editor(a, st.lfo, {avail.x, h})
	im.Spacing()
	rate := synth.Lfo_Rate(int(pm.synth_value(m, i, l(n, .Rate))))
	speed := synth.lfo_param(n, .Hz) if rate == .Seconds else (l(n, .Key_Transpose) if rate == .Keytrack else l(n, .Tempo))
	speed_label: cstring = "Rate" if rate != .Keytrack else "Transpose"
	synth_knob_row(a, avail.x, {{speed_label, speed}, {"Phase", l(n, .Phase)}, {"Fade In", l(n, .Fade)}, {"Delay", l(n, .Delay)}, {"Stereo", l(n, .Stereo)}, {"Smooth Time", l(n, .Smooth_Time)}})
}

RANDOM_STYLE_NAMES := []string{"Perlin", "Sample & hold", "Sine glide", "Lorenz"}

// Random modulator `n` (1..4): its style and rate, a picture of how it
// wanders at that rate (four seconds of it), the newest note's value now
// at its right edge, and its knobs.
draw_synth_random :: proc(a: ^App, n: int) {
	m := &a.m
	i := a.selected
	r :: synth.random_param
	im.SameLine(0, 14)
	mod_chip(a, synth.Mod_Source(int(synth.Mod_Source.Random_1) + n - 1))
	im.SameLine(0, 14)
	synth_choice(a, r(n, .Style), RANDOM_STYLE_NAMES, 120, "##rstyle")
	ui.name("random style")
	im.SameLine(0, 6)
	synth_choice(a, r(n, .Rate), LFO_RATE_NAMES, 90, "##rrate")
	im.SameLine(0, 10)
	synth_toggle(a, "Stereo##rnd", r(n, .Stereo))
	im.SameLine(0, 10)
	synth_toggle(a, "Retrigger##rnd", r(n, .Retrigger))
	im.Spacing()
	avail := im.GetContentRegionAvail()
	h := max(avail.y - im.GetTextLineHeight() * 2 - ui.KNOB_SIZE - 30, 80)
	// The picture: its wander over four seconds, as set.
	sy := &m.project.pads[i].synth
	p := synth.Random_Params {
		style = synth.Random_Style(int(math.round(curved(sy, r(n, .Style))))), stereo = curved(sy, r(n, .Stereo)) > 0.5,
		timing = {rate = synth.Lfo_Rate(int(math.round(curved(sy, r(n, .Rate))))), hz = curved(sy, r(n, .Hz)), tempo = int(math.round(curved(sy, r(n, .Tempo)))), key_transpose = curved(sy, r(n, .Key_Transpose))},
	}
	bpm := m.project.bpm if m.project.bpm > 0 else 120
	hz := synth.lfo_hz(&p.timing, bpm, 60)
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.Dummy({avail.x, h})
	ui.name("synth random view")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + avail.x, pos.y + h}, ui.col(ui.PLOT_BG), t.radius)
	x0, x1, y0, y1 := pos.x + 10, pos.x + avail.x - 40, pos.y + 10, pos.y + h - 10
	state: synth.Random_State
	synth.random_start(&state, &p, u32(n) * 7919)
	N :: 240
	pts: [2][N]im.Vec2
	for k in 0 ..< N {
		val := synth.random_step(&state, &p, hz, 4.0 / N)
		for side in 0 ..< 2 do pts[side][k] = {x0 + (x1 - x0) * f32(k) / (N - 1), y1 - val[side] * (y1 - y0)}
	}
	color := mod_color(synth.Mod_Source(int(synth.Mod_Source.Random_1) + n - 1))
	if p.stereo do im.DrawList_AddPolyline(dl, &pts[1][0], N, ui.col(ui.with_alpha(color, 0.45)), 1.6)
	im.DrawList_AddPolyline(dl, &pts[0][0], N, ui.col(color), 2.4)
	im.DrawList_AddText(dl, {x0 + 4, y0}, ui.col(t.text_dim), "4 s")
	src := synth.Mod_Source(int(synth.Mod_Source.Random_1) + n - 1)
	routed := false
	for rt in sy.routes[:sy.route_count] do routed ||= rt.source == src && !rt.bypass
	if live, ok := pm.synth_live(&m.engine, i); ok && live.sounding && routed {
		y := y1 - clamp(live.randoms[n - 1], 0, 1) * (y1 - y0)
		im.DrawList_AddLine(dl, {x1 + 6, y}, {x1 + 30, y}, ui.col(t.text), 2)
		im.DrawList_AddCircleFilled(dl, {x1 + 30, y}, 4.5, ui.col(color))
	}
	im.Spacing()
	rate := p.timing.rate
	speed := r(n, .Hz) if rate == .Seconds else (r(n, .Key_Transpose) if rate == .Keytrack else r(n, .Tempo))
	speed_label: cstring = "Rate" if rate != .Keytrack else "Transpose"
	knobs := make([dynamic]Knob, context.temp_allocator)
	append(&knobs, Knob{speed_label, speed})
	if rate == .Keytrack do append(&knobs, Knob{"Tune", r(n, .Key_Tune)})
	synth_knob_row(a, avail.x, knobs[:])
}

// A patch's parameter `id`, through its curve.
@(private = "file")
curved :: proc(sy: ^pm.Synth_Patch, id: fc.Param_Id) -> f32 {
	spec := synth.param_spec(id)
	if spec == nil do return 0
	return synth.param_curve(spec, sy.values[id])
}

// LFO `k`'s (0-based) shape, `size` big, to draw on; the newest note's
// phase on it.
lfo_editor :: proc(a: ^App, k: int, size: im.Vec2) {
	m := &a.m
	i := a.selected
	st := &a.synth_ui
	t := ui.theme()
	shape := m.project.pads[i].synth.shapes[k]
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##lfoplot", size, {.MouseButtonLeft, .MouseButtonRight})
	ui.name("synth lfo shape")
	hovered, active := im.IsItemHovered(), im.IsItemActive()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	pad: f32 = 10
	x0, x1 := pos.x + pad, pos.x + size.x - pad
	top, bot := pos.y + pad, pos.y + size.y - pad
	to_screen :: proc(p: [2]f32, x0, x1, top, bot: f32) -> im.Vec2 { return {x0 + (x1 - x0) * p[0], bot - (bot - top) * p[1]} }
	from_screen :: proc(v: im.Vec2, x0, x1, top, bot: f32) -> [2]f32 { return {clamp((v.x - x0) / (x1 - x0), 0, 1), clamp((bot - v.y) / (bot - top), 0, 1)} }
	grid := ui.mix(ui.PLOT_BG, t.text, 0.08)
	for g in 1 ..< 4 do im.DrawList_AddLine(dl, {x0, top + (bot - top) * f32(g) / 4}, {x1, top + (bot - top) * f32(g) / 4}, ui.col(grid), 1)
	for g in 1 ..< 8 do im.DrawList_AddLine(dl, {x0 + (x1 - x0) * f32(g) / 8, top}, {x0 + (x1 - x0) * f32(g) / 8, bot}, ui.col(grid), 1)
	color := mod_color(synth.Mod_Source(int(synth.Mod_Source.Lfo_1) + k))
	// The rendered shape.
	table: [256]f32
	sh := shape
	synth.lfo_shape_render(&sh, table[:])
	for x in 1 ..< len(table) {
		a0 := to_screen({f32(x - 1) / 255, table[x - 1]}, x0, x1, top, bot)
		b0 := to_screen({f32(x) / 255, table[x]}, x0, x1, top, bot)
		im.DrawList_AddLine(dl, a0, b0, ui.col(color), 2)
	}
	// Points.
	mp := im.GetIO().MousePos
	near := -1
	for p, n in shape.points[:shape.count] {
		sp := to_screen(p, x0, x1, top, bot)
		if abs(mp.x - sp.x) < 7 && abs(mp.y - sp.y) < 7 do near = n
	}
	if !active do st.point = -1
	if im.IsItemActivated() && im.IsMouseClicked(.Left) do st.point = near if near >= 0 else -2 - nearest_segment(shape, from_screen(mp, x0, x1, top, bot)[0])
	for p, n in shape.points[:shape.count] {
		sp := to_screen(p, x0, x1, top, bot)
		hot := n == near || n == st.point
		im.DrawList_AddCircleFilled(dl, sp, 5 if hot else 3.5, ui.col(color if hot else ui.mix(color, t.text, 0.4)))
	}
	if active && im.IsMouseDragging(.Left, 0) {
		s := shape
		switch {
		case st.point >= 0:
			p := from_screen(mp, x0, x1, top, bot)
			lo := s.points[st.point - 1][0] if st.point > 0 else 0
			hi := s.points[st.point + 1][0] if st.point + 1 < s.count else 1
			if st.point == 0 do p[0] = 0 // (the ends stay at the cycle's ends)
			if st.point == s.count - 1 do p[0] = 1
			s.points[st.point] = {clamp(p[0], lo, hi), p[1]}
		case st.point <= -2: // a segment: up and down bends it
			sg := -2 - st.point
			s.powers[sg] = clamp(s.powers[sg] - im.GetIO().MouseDelta.y * 0.08, -20, 20)
		}
		pm.set_synth_shape(m, i, k, s, "Draw LFO")
	}
	if im.IsItemDeactivated() do app.seal(&m.history)
	// Double-click: a point there; right-click a point: it goes.
	if hovered && im.IsMouseDoubleClicked(.Left) && near < 0 && shape.count < synth.LFO_MAX_POINTS {
		p := from_screen(mp, x0, x1, top, bot)
		s := shape
		at := s.count
		for q, n in s.points[:s.count] do if q[0] > p[0] {
			at = n
			break
		}
		copy(s.points[at + 1:s.count + 1], s.points[at:s.count])
		copy(s.powers[at + 1:s.count + 1], s.powers[at:s.count])
		s.points[at], s.powers[at] = p, 0
		s.count += 1
		pm.set_synth_shape(m, i, k, s, "Add LFO Point")
		app.seal(&m.history)
	}
	if hovered && im.IsMouseClicked(.Right) && near > 0 && near < shape.count - 1 {
		s := shape
		copy(s.points[near:s.count - 1], s.points[near + 1:s.count])
		copy(s.powers[near:s.count - 1], s.powers[near + 1:s.count])
		s.count -= 1
		pm.set_synth_shape(m, i, k, s, "Remove LFO Point")
		app.seal(&m.history)
	}
	// The newest note's phase.
	if live, ok := pm.synth_live(&m.engine, i); ok && live.sounding {
		ph := live.lfo_phase[k]
		x := x0 + (x1 - x0) * ph
		im.DrawList_AddLine(dl, {x, top}, {x, bot}, ui.col(ui.with_alpha(t.text, 0.35)), 1)
		im.DrawList_AddCircleFilled(dl, to_screen({ph, live.lfos[k]}, x0, x1, top, bot), 4.5, ui.col(t.text))
	}
}

// The segment (from point k to k+1) under x.
@(private)
nearest_segment :: proc(s: synth.Lfo_Shape, x: f32) -> int {
	for k in 0 ..< s.count - 1 do if x >= s.points[k][0] && x <= s.points[k + 1][0] do return k
	return max(s.count - 2, 0)
}
