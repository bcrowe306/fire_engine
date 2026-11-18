package pads

import "core:fmt"
import "core:math"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:rt"

// SuperFilter's device. One picture, the display, is drawn by the window's
// panel and by a controller's display alike: the response at the cutoff
// as modulated now (moving with the LFO and the envelope, each side), the
// knob's own response faint behind, the sound's spectrum, the LFO's wave
// with where it is now, the levels in and out at the edges. Around it each
// has its own layout of the same controls: the window's rows, the
// controller's four pages of encoders.

// Names of SuperFilter's types, circuits and LFO choices, as shown.
SF_TYPE_NAMES := []string{"Low-pass", "High-pass", "Band-pass", "Notch", "Peak", "Morph", "DJ", "Comb", "Vowel", "Phaser"}
SF_CIRCUIT_NAMES := []string{"Clean", "Analog", "Dirty", "Ladder", "Diode"}
SF_WAVE_NAMES := []string{"Sine", "Triangle", "Ramp Up", "Ramp Down", "Square", "Random", "Random Smooth"}
SF_MODE_NAMES := []string{"Hz", "Sync", "Dotted", "Triplet", "16ths"}
SF_RETRIGGER_NAMES := []string{"Off", "Beat", "Bar", "Play"}
SF_STEREO_NAMES := []string{"Phase", "Spin"}
// A tempo division's name (`fx.TEMPO_RATIOS`' index 1..12).
SF_DIVISION_NAMES := [13]string{"", "32 bars", "16 bars", "8 bars", "4 bars", "2 bars", "1 bar", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64"}

// Octaves either side of the anchor SuperFilter's measured response spans.
@(private) SF_REF_OCT :: 12
// Its points an octave.
@(private) SF_REF_PER_OCT :: 16
@(private) SF_REF_N :: 2 * SF_REF_OCT * SF_REF_PER_OCT + 1

// SuperFilter's response as measured (an impulse through its filter stage,
// read by an FFT), for the settings it was measured at: in dB along
// octaves from its anchor, so a modulated cutoff only moves it along.
Sf_Curve :: struct {
	values: fx.Super_Filter_Values,
	sr:     f64,
	set:    bool,
	base:   f32, // the unmodulated cutoff
	anchor: f32, // where the shape sits
	ref:    [SF_REF_N]f32,
}

// SuperFilter slot `t`'s settings (`s`), with automation where it plays now.
@(private)
sf_values :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) -> (v: fx.Super_Filter_Values) {
	for p in fx.super_filter_params {
		live, automated := pm.automated_value(&a.m, fx_auto_target(t, p.id))
		v[p.id] = live if automated else pm.slot_value(s, p.id, f32(p.default))
	}
	return
}

// A setting of SuperFilter slot `s` (its default when it has none).
@(private)
sf_get :: proc(s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
	return pm.slot_value(s, id, f32(fx.super_filter_params[id - 1].default))
}

// [control] Measures `c` again if the settings or the rate changed. The
// shape is rendered with the cutoff held between 200 Hz and 4 kHz, so
// the FFT sees it either side; outside what it can read (under 35 Hz, over
// 0.45 of the rate) each end goes on at its last octave's slope.
@(private)
sf_measure :: proc(c: ^Sf_Curve, v: fx.Super_Filter_Values, sr: f64) {
	if c.set && c.values == v && c.sr == sr do return
	c.values, c.sr, c.set = v, sr, true
	// (The impulse's tail decays into denormals: ten times slower on x86 without this.)
	fp := rt.enable_flush_to_zero()
	defer rt.restore_fp_state(fp)
	N :: 4096
	vv := v
	y := make([]f32, N, context.temp_allocator)
	base0, _ := fx.super_filter_impulse(&vv, y[:1], sr)
	c.base, c.anchor = fx.super_filter_impulse(&vv, y, sr, clamp(base0, 200, 4000))
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, N, allocator = context.temp_allocator)
	spec := make([]complex64, N / 2, context.temp_allocator)
	dsp.real_fft_forward(&fft, y, spec)
	lo, hi := -1, -1
	for &d, k in c.ref {
		hz := f64(c.anchor) * math.pow(2, f64(k) / SF_REF_PER_OCT - SF_REF_OCT)
		if hz < 35 || hz > 0.45 * sr do continue
		b := hz / sr * N
		b0 := clamp(int(b), 1, N / 2 - 2)
		f := f32(b - f64(b0))
		g := abs(spec[b0]) * (1 - f) + abs(spec[b0 + 1]) * f
		d = 20 * math.log10(max(g / 0.25, 1e-6))
		if lo < 0 do lo = k
		hi = k
	}
	if lo < 0 {
		for &d in c.ref do d = 0
		return
	}
	edge :: SF_REF_PER_OCT // (the slope over the octave inside each end)
	slo := (c.ref[min(lo + edge, hi)] - c.ref[lo]) / f32(max(min(edge, hi - lo), 1)) // dB a point
	shi := (c.ref[hi] - c.ref[max(hi - edge, lo)]) / f32(max(min(edge, hi - lo), 1))
	for k in 0 ..< lo do c.ref[k] = c.ref[lo] - slo * f32(lo - k)
	for k in hi + 1 ..< SF_REF_N do c.ref[k] = c.ref[hi] + shi * f32(k - hi)
}

// The response plot's points (`RESPONSE_POINTS`, dB) of `c` at cutoff `hz`.
@(private)
sf_curve_at :: proc(c: ^Sf_Curve, hz: f32) -> []f32 {
	out := make([]f32, RESPONSE_POINTS, context.temp_allocator)
	shift := hz / max(c.anchor, 1)
	for &d, k in out {
		f := ui.x_freq(f32(k) / (RESPONSE_POINTS - 1))
		x := (math.log2(f / max(shift * c.anchor, 1)) + SF_REF_OCT) * SF_REF_PER_OCT
		i := clamp(int(math.floor(x)), 0, SF_REF_N - 2)
		u := clamp(x - f32(i), 0, 1)
		d = c.ref[i] * (1 - u) + c.ref[i + 1] * u
	}
	return out
}

// SuperFilter slot `t`'s display, `size` big: drag its handle (`handle`)
// across for Freq, up and down for Res (Shift: fine).
@(private)
sf_display :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, size: im.Vec2, handle: bool) {
	th := ui.theme()
	color := th.accent
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	v := sf_values(a, t, s)
	c := &a.sf_curve
	sf_measure(c, v, sr)
	st, r := pa.effect_super_filter_state(&a.api, slot_ref(t))
	live := r == .Ok && s.on
	cl, cr := c.base, c.base
	if live do cl, cr = st.cutoff_l, st.cutoff_r
	curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
	if spec := spectrum(a); spec != nil do append(&curves, ui.Plot_Curve{db = spec, color = ui.with_alpha(th.text, 0.28), width = 1.2})
	dim := ui.mix(ui.PLOT_BG, color, 0.45)
	moved := abs(math.log2(cl / max(c.base, 1))) > 0.02 || abs(math.log2(cr / max(c.base, 1))) > 0.02
	if moved do append(&curves, ui.Plot_Curve{db = sf_curve_at(c, c.base), color = dim, width = 1.5})
	if abs(math.log2(cr / max(cl, 1))) > 0.02 do append(&curves, ui.Plot_Curve{db = sf_curve_at(c, cr), color = ui.mix(color, th.text, 0.45), width = 1.8})
	append(&curves, ui.Plot_Curve{db = sf_curve_at(c, cl), color = color if s.on else dim, fill = true, width = 2.5})
	h := [2]f32{ui.freq_x(v[fx.SF_PARAM_FREQ_HZ]), v[fx.SF_PARAM_RESONANCE] * 24}
	im.SetNextItemAllowOverlap() // (the buttons drawn over it take their clicks)
	e := ui.response_plot("superfilter display", curves[:], &h if handle else nil, size)
	r0, r1 := im.GetItemRectMin(), im.GetItemRectMax()
	if handle {
		if e.changed {
			control_effect_param(a, t, i64(fx.SF_PARAM_FREQ_HZ), f64(clamp(ui.x_freq(h[0]), 20, 20_000)), true, false)
			control_effect_param(a, t, i64(fx.SF_PARAM_RESONANCE), f64(clamp(h[1] / 24, 0, 1)), true, false)
		}
		if e.ended do pa.history_gesture_end(&a.api)
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s: drag sideways for Freq, up and down for Res (Shift: fine)", sf_hz(v[fx.SF_PARAM_FREQ_HZ])))
	}
	dl := im.GetWindowDrawList()
	// What it is and where its cutoff is now, top left.
	typ := int(v[fx.SF_PARAM_TYPE])
	circ := fx.Sf_Circuit(clamp(int(v[fx.SF_PARAM_CIRCUIT]), 0, len(fx.Sf_Circuit) - 1))
	what := SF_TYPE_NAMES[clamp(typ, 0, len(SF_TYPE_NAMES) - 1)]
	ty := fx.Sf_Type(clamp(typ, 0, len(fx.Sf_Type) - 1))
	if ty != .Comb && ty != .Vowel && ty != .Phaser {
		shown := circ if fx.super_filter_circuit_has(circ, ty) else .Analog
		what = fmt.tprintf("%s · %s", what, SF_CIRCUIT_NAMES[int(shown)])
	}
	ui.text_push(.Label)
	im.DrawList_AddText(dl, {r0.x + 14, r0.y + 6}, ui.col(ui.with_alpha(th.text, 0.75)), fmt.ctprintf("%s  %s", what, sf_hz(cl)))
	ui.text_pop()
	// The LFO's wave (one cycle), where it is now, top right.
	if v[fx.SF_PARAM_LFO_AMOUNT] != 0 || size.y > 80 {
		bw, bh := min(f32(64), size.x * 0.12), min(f32(26), size.y * 0.4)
		b0 := im.Vec2{r1.x - 14 - bw, r0.y + 6}
		lfo_v: f32 = st.lfo_l if live else 0
		sf_wave_picture(dl, b0, {bw, bh}, v, lfo_v if live else -2, color)
	}
	// The levels in and out, at the left and right edges.
	meter :: proc(dl: ^im.DrawList, x, top, bottom, peak: f32, c: ui.Color) {
		db := 20 * math.log10(max(peak, 1e-6))
		f := clamp((db + 48) / 48, 0, 1)
		im.DrawList_AddRectFilled(dl, {x, bottom - (bottom - top) * f}, {x + 3, bottom}, ui.col(c))
	}
	if live {
		meter(dl, r0.x + 2, r0.y + 8, r1.y - 8, st.in_peak, ui.with_alpha(th.text, 0.6))
		meter(dl, r1.x - 5, r0.y + 8, r1.y - 8, st.out_peak, color)
	}
}

// One cycle of the LFO's wave at settings `v` in a box at `pos`, `size`
// big, with a dot at `now` (-1..1; under -1: none).
@(private)
sf_wave_picture :: proc(dl: ^im.DrawList, pos, size: im.Vec2, v: fx.Super_Filter_Values, now: f32, color: ui.Color) {
	N :: 48
	l: fx.Lfo
	p := fx.LFO_DEFAULTS
	p.wave = fx.Lfo_Wave(clamp(int(v[fx.SF_PARAM_LFO_WAVE]), 0, len(fx.Lfo_Wave) - 1))
	p.morph = v[fx.SF_PARAM_LFO_MORPH]
	p.mode, p.hz = .Hz, 1
	ys: [N]f32
	fx.lfo_render(&l, &p, {}, {ys[:], ys[:]}, N) // (a cycle a second at N a second: one cycle)
	th := ui.theme()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.8)), 3)
	im.DrawList_AddRect(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.2)), 3)
	pts: [N]im.Vec2
	for y, k in ys do pts[k] = {pos.x + 3 + (size.x - 6) * f32(k) / (N - 1), pos.y + size.y / 2 - y * (size.y / 2 - 3)}
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.mix(ui.PLOT_BG, color, 0.8)), 1.5)
	if now >= -1 {
		y := pos.y + size.y / 2 - clamp(now, -1, 1) * (size.y / 2 - 3)
		im.DrawList_AddCircleFilled(dl, {pos.x + size.x - 3, y}, 3, ui.col(ui.lighten(color, 0.4)), 12)
	}
}

// A frequency, as shown: "850 Hz", "1.2 kHz".
@(private)
sf_hz :: proc(hz: f32) -> string {
	if hz >= 1000 do return fmt.tprintf("%.1f kHz", hz / 1000)
	return fmt.tprintf("%.0f Hz", hz)
}

// How SuperFilter parameter `id` at `v` reads under its knob.
@(private)
sf_shown :: proc(s: pm.Effect_Slot, id: fc.Param_Id, v: f32) -> cstring {
	p := fx.super_filter_params[id - 1]
	switch id {
	case fx.SF_PARAM_FREQ_HZ, fx.SF_PARAM_LFO_RATE_HZ, fx.SF_PARAM_LFO_SPIN_HZ:
		if v < 10 do return fmt.ctprintf("%.2f Hz", v)
		return fmt.ctprintf("%s", sf_hz(v))
	case fx.SF_PARAM_LFO_DIVISION:
		mode := fx.Lfo_Mode(clamp(int(sf_get(s, fx.SF_PARAM_LFO_MODE)), 0, len(fx.Lfo_Mode) - 1))
		suffix := " D" if mode == .Dotted else (" T" if mode == .Triplet else "")
		return fmt.ctprintf("%s%s", SF_DIVISION_NAMES[clamp(int(v + 0.5), 1, 12)], suffix)
	case fx.SF_PARAM_ENV_SH_DIVISION:
		return fmt.ctprintf("%s", SF_DIVISION_NAMES[clamp(int(v + 0.5), 1, 12)])
	case fx.SF_PARAM_LFO_SIXTEENTHS:
		return fmt.ctprintf("%d/16", int(v + 0.5))
	case fx.SF_PARAM_LFO_PHASE_DEG, fx.SF_PARAM_LFO_OFFSET_DEG:
		return fmt.ctprintf("%.0f°", v)
	}
	#partial switch p.unit {
	case .Percent:      return fmt.ctprintf("%+.0f%%" if p.min < 0 else "%.0f%%", v * 100)
	case .Decibels:     return fmt.ctprintf("%+.1f dB" if p.min < 0 else "%.1f dB", v)
	case .Milliseconds: return fmt.ctprintf("%.1f ms" if v < 10 else "%.0f ms", v)
	}
	return fmt.ctprintf("%.2f", v)
}

// SuperFilter parameter `id` of slot `t` (`s`) as a knob at the cursor
// (`label`: its name, else the parameter's): automatable, undoable.
@(private)
sf_knob :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label := "", size: f32 = ui.KNOB_SIZE) {
	p := fx.super_filter_params[id - 1]
	v := sf_get(s, id)
	name := label if label != "" else p.name
	log_scale := p.unit == .Hertz && p.min > 0 && p.max / p.min >= 50
	step: f32 = 1 if .Stepped in p.flags else 0
	knob_target(a, fx_auto_target(t, id))
	e := ui.knob(fmt.ctprintf("%s##sf%d", name, int(id)), &v, f32(p.min), f32(p.max), f32(p.default), "%.2f", size = size, log_scale = log_scale, shown_value = sf_shown(s, id, v), step = step)
	knob_target(a, {})
	if .Stepped in p.flags do v = f32(math.round(v))
	control_effect_param(a, t, i64(id), clamp(f64(v), p.min, p.max), e.changed, e.ended)
}

// SuperFilter's LFO rate as a knob, as its mode sets it: Hz, a division
// (straight, dotted or triplet) or sixteenths.
@(private)
sf_rate_id :: proc(s: pm.Effect_Slot) -> fc.Param_Id {
	#partial switch fx.Lfo_Mode(clamp(int(sf_get(s, fx.SF_PARAM_LFO_MODE)), 0, len(fx.Lfo_Mode) - 1)) {
	case .Hz:         return fx.SF_PARAM_LFO_RATE_HZ
	case .Sixteenths: return fx.SF_PARAM_LFO_SIXTEENTHS
	}
	return fx.SF_PARAM_LFO_DIVISION
}

// Sets SuperFilter choice `id` of slot `t` to `v` (one undo step).
@(private)
sf_choose :: proc(a: ^App, t: pm.Fx_Target, id: fc.Param_Id, v: int) {
	control_effect_param(a, t, i64(id), f64(v), true, true)
}

// --- the window ---------------------------------------------------------------------------------

// A choice of SuperFilter slot `t` as a dropdown, `width` wide; names
// `dim` says (when given) are shown as playing as another.
@(private)
sf_combo :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, names: []string, width: f32, note: proc(s: pm.Effect_Slot, k: int) -> string = nil) {
	cur := clamp(int(sf_get(s, id)), 0, len(names) - 1)
	im.SetNextItemWidth(width)
	if ui.combo(fmt.ctprintf("##sf%d", int(id)), fmt.ctprintf("%s", names[cur])) {
		for n, k in names {
			extra := note(s, k) if note != nil else ""
			if im.Selectable(fmt.ctprintf("%s%s##sfc%d", n, extra, k), k == cur) && k != cur do sf_choose(a, t, id, k)
			ui.name(fmt.tprintf("sf %s %s", fx.super_filter_params[id - 1].name, n))
		}
		im.EndCombo()
	}
	ui.name(fmt.tprintf("sf %s", fx.super_filter_params[id - 1].name))
}

// A row of SuperFilter's controls in cells across the width: a knob each,
// a toggle for an on/off, a dropdown for a choice (with its names).
@(private)
Sf_Cell :: struct {
	id:    fc.Param_Id,
	label: string,
	names: []string,
	off:   bool, // greyed (it does nothing now)
}

// The window's rows' knobs (smaller than the theme's: two rows fit under the display).
@(private) SF_ROW_KNOB :: 36

@(private)
sf_row :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, cells: []Sf_Cell) {
	avail := im.GetContentRegionAvail().x
	x0 := im.GetCursorPosX()
	cell := max(avail / f32(max(len(cells), 1)), ui.KNOB_SIZE + 30)
	for c, k in cells {
		if c.id == 0 do continue // (a gap)
		if k > 0 do im.SameLine()
		p := fx.super_filter_params[c.id - 1]
		toggle := p.min == 0 && p.max == 1 && .Stepped in p.flags
		w: f32 = cell - 10 if c.names != nil else (90 if toggle else SF_ROW_KNOB + 24)
		im.SetCursorPosX(x0 + f32(k) * cell + max((cell - w) / 2, 0))
		im.BeginDisabled(c.off)
		switch {
		case c.names != nil:
			im.BeginGroup()
			ui.text_push(.Label)
			im.TextDisabled("%s", fmt.ctprintf("%s", c.label if c.label != "" else p.name))
			ui.text_pop()
			sf_combo(a, t, s, c.id, c.names, w)
			im.EndGroup()
		case toggle:
			im.BeginGroup()
			im.Dummy({1, im.GetTextLineHeight() + 4})
			on := sf_get(s, c.id) >= 0.5
			if ui.toggle(fmt.ctprintf("%s##sf%d", c.label if c.label != "" else p.name, int(c.id)), &on) do sf_choose(a, t, c.id, 1 if on else 0)
			im.EndGroup()
		case:
			sf_knob(a, t, s, c.id, c.label, SF_ROW_KNOB)
		}
		im.EndDisabled()
	}
}

// SuperFilter's choices on its slot's header line: its type, circuit,
// slope, clip, and the LFO's extras shown or not.
sf_header :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	typ := fx.Sf_Type(clamp(int(sf_get(s, fx.SF_PARAM_TYPE)), 0, len(fx.Sf_Type) - 1))
	circ := fx.Sf_Circuit(clamp(int(sf_get(s, fx.SF_PARAM_CIRCUIT)), 0, len(fx.Sf_Circuit) - 1))
	has_circuit := typ != .Comb && typ != .Vowel && typ != .Phaser
	sf_combo(a, t, s, fx.SF_PARAM_TYPE, SF_TYPE_NAMES, 112)
	if im.IsItemHovered() do im.SetTooltip("The type of filter")
	im.SameLine(0, 6)
	im.BeginDisabled(!has_circuit)
	sf_combo(a, t, s, fx.SF_PARAM_CIRCUIT, SF_CIRCUIT_NAMES, 92, proc(s: pm.Effect_Slot, k: int) -> string {
		typ := fx.Sf_Type(clamp(int(sf_get(s, fx.SF_PARAM_TYPE)), 0, len(fx.Sf_Type) - 1))
		return "" if fx.super_filter_circuit_has(fx.Sf_Circuit(k), typ) else "  (plays as Analog)"
	})
	im.EndDisabled()
	if im.IsItemHovered({.AllowWhenDisabled}) {
		switch {
		case !has_circuit:                          im.SetTooltip("Comb, Vowel and Phaser have no circuit")
		case !fx.super_filter_circuit_has(circ, typ): im.SetTooltip("Diode makes Low-pass only: this plays as Analog")
		case:                                       im.SetTooltip("The circuit: how it colours and drives")
		}
	}
	im.SameLine(0, 6)
	im.BeginDisabled(!fx.super_filter_has_slope(circ, typ))
	steep := sf_get(s, fx.SF_PARAM_SLOPE) >= 0.5
	if ui.toggle("24 dB##sfslope", &steep) do sf_choose(a, t, fx.SF_PARAM_SLOPE, 1 if steep else 0)
	im.EndDisabled()
	if im.IsItemHovered({.AllowWhenDisabled}) do im.SetTooltip("The slope: 24 dB an octave, else 12")
	im.SameLine(0, 6)
	clip := sf_get(s, fx.SF_PARAM_CLIP) >= 0.5
	if ui.toggle("Clip##sfclip", &clip) do sf_choose(a, t, fx.SF_PARAM_CLIP, 1 if clip else 0)
	if im.IsItemHovered() do im.SetTooltip("A soft clip after the filter: never over full scale")
}

// SuperFilter's panel in the window (under its slot's header and
// sidechain row): the display; the filter, output stage and envelope in a
// row of knobs, the LFO and the envelope's steps in another; the LFO's
// extras under them while shown (the display's ▾).
draw_super_filter :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	typ := fx.Sf_Type(clamp(int(sf_get(s, fx.SF_PARAM_TYPE)), 0, len(fx.Sf_Type) - 1))
	avail := im.GetContentRegionAvail().x
	sf_display(a, t, s, {avail, 84}, true)
	// The sidechain's row and the LFO's extras, from the display's top.
	r0, r1 := im.GetItemRectMin(), im.GetItemRectMax()
	keep := im.GetCursorScreenPos()
	ui.text_push(.Label)
	chev :: proc(open: bool) -> string { return ui.ICON_CHEVRON_UP if open else ui.ICON_CHEVRON_DOWN }
	label := fmt.ctprintf("%s  LFO extras##sfmore", chev(a.sf_more))
	w := im.CalcTextSize(label).x + 10
	im.SetCursorScreenPos({r1.x - 92 - w, r0.y + 5})
	if im.SmallButton(label) do a.sf_more = !a.sf_more
	ui.name("sf lfo extras")
	keyed := s.key.kind != .None || s.listen || s.key_hpf > 0 || s.key_lpf > 0
	if !keyed {
		klabel := fmt.ctprintf("%s  Sidechain##sfkey", chev(a.sf_key))
		im.SetCursorScreenPos({r1.x - 92 - w - 8 - im.CalcTextSize(klabel).x - 10, r0.y + 5})
		if im.SmallButton(klabel) do a.sf_key = !a.sf_key
		ui.name("sf key row")
	}
	ui.text_pop()
	im.SetCursorScreenPos(keep)
	morph := typ == .Morph || typ == .Comb || typ == .Vowel || typ == .Phaser
	sh := sf_get(s, fx.SF_PARAM_ENV_SH) >= 0.5
	sf_row(a, t, s, {
		{id = fx.SF_PARAM_FREQ_HZ}, {id = fx.SF_PARAM_RESONANCE, label = "Formant Q" if typ == .Vowel else ""},
		{id = fx.SF_PARAM_MORPH, label = "Vowel" if typ == .Vowel else ("Feedback" if typ == .Comb else ""), off = !morph},
		{id = fx.SF_PARAM_DRIVE_DB}, {id = fx.SF_PARAM_OUTPUT_DB}, {id = fx.SF_PARAM_MIX},
		{id = fx.SF_PARAM_ENV_AMOUNT}, {id = fx.SF_PARAM_ENV_ATTACK_MS}, {id = fx.SF_PARAM_ENV_RELEASE_MS},
	})
	sf_row(a, t, s, {
		{id = fx.SF_PARAM_LFO_AMOUNT, label = "LFO"}, {id = sf_rate_id(s), label = "Rate"},
		{id = fx.SF_PARAM_LFO_WAVE, label = "Wave", names = SF_WAVE_NAMES}, {id = fx.SF_PARAM_LFO_MORPH, label = "Shape"},
		{id = fx.SF_PARAM_LFO_MODE, label = "Mode", names = SF_MODE_NAMES}, {id = fx.SF_PARAM_KEY_GAIN_DB},
		{id = fx.SF_PARAM_ENV_HOLD}, {id = fx.SF_PARAM_ENV_SH}, {id = fx.SF_PARAM_ENV_SH_DIVISION, off = !sh},
	})
	if a.sf_more {
		spin := sf_get(s, fx.SF_PARAM_LFO_STEREO) >= 0.5
		sf_row(a, t, s, {
			{id = fx.SF_PARAM_LFO_STEREO, label = "Stereo", names = SF_STEREO_NAMES},
			{id = fx.SF_PARAM_LFO_SPIN_HZ if spin else fx.SF_PARAM_LFO_PHASE_DEG, label = "Spin" if spin else "Phase"},
			{id = fx.SF_PARAM_LFO_OFFSET_DEG, label = "Offset"},
			{id = fx.SF_PARAM_LFO_RETRIGGER, label = "Retrigger", names = SF_RETRIGGER_NAMES},
			{id = fx.SF_PARAM_LFO_SMOOTH, label = "Smooth"},
			{}, {}, {}, {},
		})
	}
}

// --- a controller's display ---------------------------------------------------------------------

// SuperFilter on a controller's display: the display over its encoders,
// four pages of them (Filter, Circuit, Envelope, LFO; the lower row's
// buttons pick them), On and Remove at its ends.
@(private)
ctl_super_filter :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, s: pm.Effect_Slot, plot, full: im.Vec2) {
	a := ctx.a
	p := &a.m.project
	sf_display(a, t, s, plot, false)
	ctx.banks[0], ctx.banks[1], ctx.banks[2], ctx.banks[3] = "Filter", "Circuit", "Envelope", "LFO"
	N :: 31
	knob :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, plot: im.Vec2) {
		if ctl_knob(ctx, n, N, fmt.ctprintf("%s##sf%d", label, int(id)), plot) do sf_knob(ctx.a, t, s, id, label)
	}
	choice :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, names: []string, plot: im.Vec2) {
		cur := int(sf_get(s, id))
		if k, _ := ctl_choice(ctx, n, N, fmt.ctprintf("%s##sf%d", label, int(id)), names, cur, plot); k >= 0 do sf_choose(ctx.a, t, id, k)
	}
	typ := fx.Sf_Type(clamp(int(sf_get(s, fx.SF_PARAM_TYPE)), 0, len(fx.Sf_Type) - 1))
	// Filter.
	knob(ctx, 0, t, s, fx.SF_PARAM_FREQ_HZ, "Freq", plot)
	knob(ctx, 1, t, s, fx.SF_PARAM_RESONANCE, "Formant Q" if typ == .Vowel else "Res", plot)
	knob(ctx, 2, t, s, fx.SF_PARAM_MORPH, "Vowel" if typ == .Vowel else ("Feedback" if typ == .Comb else "Morph"), plot)
	choice(ctx, 3, t, s, fx.SF_PARAM_TYPE, "Type", SF_TYPE_NAMES, plot)
	knob(ctx, 4, t, s, fx.SF_PARAM_LFO_AMOUNT, "LFO", plot)
	knob(ctx, 5, t, s, sf_rate_id(s), "Rate", plot)
	knob(ctx, 6, t, s, fx.SF_PARAM_ENV_AMOUNT, "Envelope", plot)
	knob(ctx, 7, t, s, fx.SF_PARAM_MIX, "Dry/Wet", plot)
	// Circuit.
	knob(ctx, 8, t, s, fx.SF_PARAM_DRIVE_DB, "Drive", plot)
	choice(ctx, 9, t, s, fx.SF_PARAM_CIRCUIT, "Circuit", SF_CIRCUIT_NAMES, plot)
	choice(ctx, 10, t, s, fx.SF_PARAM_SLOPE, "Slope", {"12 dB", "24 dB"}, plot)
	choice(ctx, 11, t, s, fx.SF_PARAM_CLIP, "Clip", OFF_ON, plot)
	knob(ctx, 12, t, s, fx.SF_PARAM_OUTPUT_DB, "Output", plot)
	choice(ctx, 13, t, s, fx.SF_PARAM_LFO_WAVE, "Wave", SF_WAVE_NAMES, plot)
	knob(ctx, 14, t, s, fx.SF_PARAM_LFO_MORPH, "Shape", plot)
	choice(ctx, 15, t, s, fx.SF_PARAM_LFO_MODE, "Mode", SF_MODE_NAMES, plot)
	// Envelope (and the key).
	knob(ctx, 16, t, s, fx.SF_PARAM_ENV_ATTACK_MS, "Attack", plot)
	knob(ctx, 17, t, s, fx.SF_PARAM_ENV_RELEASE_MS, "Release", plot)
	choice(ctx, 18, t, s, fx.SF_PARAM_ENV_HOLD, "Hold", OFF_ON, plot)
	choice(ctx, 19, t, s, fx.SF_PARAM_ENV_SH, "S&H", OFF_ON, plot)
	knob(ctx, 20, t, s, fx.SF_PARAM_ENV_SH_DIVISION, "S&H Rate", plot)
	// Its key: itself, a pad or a bus.
	if t.kind == .Pad || t.kind == .Bus {
		keys := make([dynamic]pm.Key_Source, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		append(&keys, pm.Key_Source{})
		append(&names, "Itself")
		for i in 0 ..< pm.PADS do if pm.pad_used(p, i) && pm.key_allowed(p, t, {.Pad, i}) {
			append(&keys, pm.Key_Source{.Pad, i})
			append(&names, fmt.tprintf("Pad %s", pm.pad_label(i)))
		}
		for b in 0 ..< p.bus_count do if pm.key_allowed(p, t, {.Bus, b}) {
			append(&keys, pm.Key_Source{.Bus, b})
			append(&names, pm.bus_index_name(p, b))
		}
		cur := 0
		for k, i in keys do if k == s.key do cur = i
		if k, _ := ctl_choice(ctx, 21, N, "Source##sfkey", names[:], cur, plot); k >= 0 {
			pa.effect_set_key(&a.api, slot_ref(t), pa.Key_Kind(keys[k].kind), i64(keys[k].index))
		}
		if ctl_knob(ctx, 22, N, "Key Low", plot) {
			hz := s.key_hpf
			e := ui.knob("Key Low##sfkl", &hz, 0, 2000, 0, "%.0f Hz", shown_value = "Off" if hz < 1 else fmt.ctprintf("%.0f Hz", hz))
			if e.changed {
				pa.history_gesture_begin(&a.api)
				pa.effect_set_key_filter(&a.api, slot_ref(t), clamp(hz, 0, 2000))
			}
			if e.ended do pa.history_gesture_end(&a.api)
		}
		if ctl_knob(ctx, 23, N, "Key High", plot) {
			hz := s.key_lpf if s.key_lpf > 0 else 20_000
			e := ui.knob("Key High##sfkh", &hz, 200, 20_000, 20_000, "%.0f Hz", log_scale = true, shown_value = "Off" if hz >= 19_999 else fmt.ctprintf("%s", sf_hz(hz)))
			if e.changed {
				pa.history_gesture_begin(&a.api)
				pa.effect_set_key_high_cut(&a.api, slot_ref(t), 0 if hz >= 19_999 else clamp(hz, 200, 20_000))
			}
			if e.ended do pa.history_gesture_end(&a.api)
		}
	}
	// LFO's extras.
	choice(ctx, 24, t, s, fx.SF_PARAM_LFO_STEREO, "Stereo", SF_STEREO_NAMES, plot)
	spin := sf_get(s, fx.SF_PARAM_LFO_STEREO) >= 0.5
	knob(ctx, 25, t, s, fx.SF_PARAM_LFO_SPIN_HZ if spin else fx.SF_PARAM_LFO_PHASE_DEG, "Spin" if spin else "Phase", plot)
	knob(ctx, 26, t, s, fx.SF_PARAM_LFO_OFFSET_DEG, "Offset", plot)
	choice(ctx, 27, t, s, fx.SF_PARAM_LFO_RETRIGGER, "Retrigger", SF_RETRIGGER_NAMES, plot)
	knob(ctx, 28, t, s, fx.SF_PARAM_LFO_SMOOTH, "Smooth", plot)
	knob(ctx, 29, t, s, fx.SF_PARAM_KEY_GAIN_DB, "Key Gain", plot)
	if t.kind == .Pad || t.kind == .Bus {
		if k, _ := ctl_choice(ctx, 30, N, "Listen##sflisten", OFF_ON, 1 if s.listen else 0, plot); k >= 0 do pa.effect_set_key_listen(&a.api, slot_ref(t), k == 1)
	}
	_ = full
}
