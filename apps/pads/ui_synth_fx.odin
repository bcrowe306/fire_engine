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
import "fire:synth"

// The synth's Effects tab: the chain on the left (each effect's switch;
// drag one to move it), the chosen effect on the right: a picture of what
// it does (its response, a sine through it, its echoes, its tail, its
// meters, its sweep, moving as it plays) over its controls.

// The drag-and-drop payload an effect's row carries: an `fx.Effect`.
SYNTH_FX_PAYLOAD :: "SYNTH_FX"

SYNC_NAMES := []string{"Hz", "Tempo", "Dotted", "Triplet"}
DELAY_STYLE_NAMES := []string{"Mono", "Stereo", "Ping-pong", "Mid ping-pong"}
DISTORTION_NAMES := []string{"Soft clip", "Hard clip", "Linear fold", "Sine fold", "Bit crush", "Down sample"}
DISTORTION_FILTER_NAMES := []string{"No filter", "Filter before", "Filter after"}
COMPRESSOR_BAND_NAMES := []string{"Three bands", "Low + rest", "Rest + high", "One band"}
EQ_MODE_NAMES := [3][]string{{"Low shelf", "High-pass"}, {"Peak", "Notch"}, {"High shelf", "Low-pass"}}
BAND_NAMES := []string{"Low", "Band", "High"}

// An EQ's response, measured and kept until its settings change.
Eq_Curve :: struct {
	params: fx.Eq_Params,
	sr:     f64,
	db:     [RESPONSE_POINTS]f32,
	set:    bool,
}

// [control] The response of an EQ with `p` (an impulse through it).
measure_eq :: proc(c: ^Eq_Curve, p: fx.Eq_Params, sr: f64) {
	if c.set && c.params == p && c.sr == sr do return
	c.params, c.sr, c.set = p, sr, true
	N :: 4096
	e := new(fx.Eq, context.temp_allocator)
	l := make([]f32, N, context.temp_allocator)
	r := make([]f32, N, context.temp_allocator)
	l[0], r[0] = 0.25, 0.25
	pp := p
	for at := 0; at < N; at += 64 do fx.eq_render(e, &pp, l[at:at + 64], r[at:at + 64], sr)
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, N, allocator = context.temp_allocator)
	spec := make([]complex64, N / 2, context.temp_allocator)
	dsp.real_fft_forward(&fft, l, spec)
	for &v, k in c.db {
		hz := f64(ui.x_freq(f32(k) / (RESPONSE_POINTS - 1)))
		bin := clamp(int(hz / sr * N + 0.5), 1, N / 2 - 1)
		v = f32(20 * math.log10(max(f64(abs(spec[bin]) / 0.25), 1e-6)))
	}
}

// An effect's switch parameter (field 0 of each).
effect_on :: proc(e: fx.Effect) -> fc.Param_Id { return synth.effect_param(e, synth.Chorus_Field.On) }

// The Effects tab.
draw_synth_effects :: proc(a: ^App) {
	m := &a.m
	st := &a.synth_ui
	i := a.selected
	sy := &m.project.pads[i].synth
	avail := im.GetContentRegionAvail()
	top := im.GetCursorScreenPos()
	list_w: f32 = 168
	row_h := im.GetFrameHeight()
	// The chain, in order (scrolling, if the panel is short).
	im.BeginChild("##fxchain", {list_w, avail.y})
	ctop := im.GetCursorScreenPos()
	for e, k in sy.fx_order {
		name := synth.EFFECT_NAMES[e]
		im.PushIDInt(i32(e))
		im.SetCursorScreenPos({ctop.x, ctop.y + f32(k) * (row_h + 3)})
		on := pm.synth_value(m, i, effect_on(e)) > 0.5
		if ui.icon_button(ui.ICON_POWER, fmt.ctprintf("%s on / off", name), on = on) {
			set_synth_param(a, i, i64(effect_on(e)), 0 if on else 1, name)
		}
		ui.name(fmt.tprintf("effect %s on", name))
		im.SameLine(0, 6)
		label := fmt.ctprintf("%d  %s%s###fxrow", k + 1, name, "" if on else "  (off)")
		if !on do im.PushStyleColorVec4(.Text, transmute(im.Vec4)ui.theme().text_dim)
		if im.Selectable(label, st.effect == e, {}, {list_w - row_h - 6 - im.GetStyle().ScrollbarSize, row_h}) do st.effect = e
		if !on do im.PopStyleColor()
		ui.name(fmt.tprintf("effect %s", name))
		if im.IsItemHovered() do im.SetTooltip("Drag up or down to move it in the chain")
		if im.BeginDragDropSource() {
			v := u8(e)
			im.SetDragDropPayload(SYNTH_FX_PAYLOAD, &v, 1)
			im.Text("%s", fmt.ctprintf("%s  %s", ui.ICON_GRIP_VERTICAL, name))
			im.EndDragDropSource()
		}
		if im.BeginDragDropTarget() {
			if pl := im.AcceptDragDropPayload(SYNTH_FX_PAYLOAD); pl != nil {
				pm.move_synth_effect(m, i, fx.Effect((^u8)(pl.Data)^), k)
			}
			im.EndDragDropTarget()
		}
		im.PopID()
	}
	im.EndChild()
	// The one chosen.
	x0 := top.x + list_w + 16
	w := avail.x - list_w - 16 - im.GetStyle().ScrollbarSize
	im.SetCursorScreenPos({x0, top.y})
	draw_synth_effect(a, st.effect, x0, w, top.y + avail.y - 4)
}

// The rate of a synced effect as a knob: its frequency when free, else
// its tempo division.
rate_knob :: proc(a: ^App, label: cstring, sync, hz, tempo: fc.Param_Id) -> Knob {
	free := int(math.round(host_value(a, sync))) == 0
	return {label, hz if free else tempo}
}

// Height a row of knobs takes.
knob_row_height :: proc() -> f32 { return im.GetTextLineHeight() * 2 + ui.KNOB_SIZE + 10 }

// Effect `e`'s page at `x0`, `w` wide, down to `bottom`: its switch and
// choices, its picture, its knobs.
draw_synth_effect :: proc(a: ^App, e: fx.Effect, x0, w, bottom: f32) {
	m := &a.m
	i := a.selected
	name := synth.EFFECT_NAMES[e]
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	bpm := m.project.bpm if m.project.bpm > 0 else 120
	cp: fx.Chain_Params
	chain: ^fx.Chain
	color: ui.Color
	if a.param_host.slot {
		// An effect slot: its values over the defaults; on as the slot is.
		values := make([]f32, synth.PARAM_SLOTS, context.temp_allocator)
		for spec in synth.PARAMS do values[spec.id] = spec.default
		s, _ := pm.target_slot(m, a.param_host.t)
		for p in s.params[:s.count] do if int(p.id) < synth.PARAM_SLOTS do values[p.id] = p.value
		for spec in synth.PARAMS do if v, ok := pm.automated_value(m, fx_auto_target(a.param_host.t, spec.id)); ok do values[spec.id] = v // (automation playing: as it has them now)
		cp = synth.effect_chain_params(values, fx.CHAIN_ORDER, bpm)
		cp.on = {e} if s.on || a.param_host.t.kind == .Perf else {}
		chain = pm.slot_chain(&m.engine, a.param_host.t)
		color = ui.theme().accent
	} else {
		sy := &m.project.pads[i].synth
		values := make([]f32, len(sy.values), context.temp_allocator)
		for &v, id in values do v = synth_now(m, i, fc.Param_Id(id)) // (automation playing: as it has them now)
		cp = synth.effect_chain_params(values, sy.fx_order, bpm)
		chain = pm.synth_chain(&m.engine, i)
		color = ui.rgb(m.project.pads[i].color)
	}
	on := e in cp.on
	if !on do color = ui.mix(ui.PLOT_BG, color, 0.45)
	if !a.param_host.slot do synth_toggle(a, fmt.ctprintf("%s##fxon", name), effect_on(e)) // (a slot's own switch is beside its name: its choices go on that line)
	knobs := make([dynamic]Knob, context.temp_allocator)
	knobs2 := make([dynamic]Knob, context.temp_allocator)
	p :: synth.effect_param
	switch e {
	case .Chorus:
		c :: proc(f: synth.Chorus_Field) -> fc.Param_Id { return synth.effect_param(.Chorus, f) }
		im.SameLine(0, 14)
		synth_choice(a, c(.Sync), SYNC_NAMES, 130, "##csync", "Rate: ")
		append(&knobs, Knob{"Voices", c(.Voices)}, rate_knob(a, "Rate", c(.Sync), c(.Hz), c(.Tempo)), Knob{"Depth", c(.Depth)}, Knob{"Feedback", c(.Feedback)},
			Knob{"Delay 1", c(.Delay_1)}, Knob{"Delay 2", c(.Delay_2)}, Knob{"Cutoff", c(.Cutoff)}, Knob{"Spread", c(.Spread)}, Knob{"Mix", c(.Wet)})
	case .Compressor:
		c :: proc(f: synth.Compressor_Field) -> fc.Param_Id { return synth.effect_param(.Compressor, f) }
		im.SameLine(0, 14)
		synth_choice(a, c(.Bands), COMPRESSOR_BAND_NAMES, 120, "##cbands")
		im.SameLine(0, 14)
		ui.segmented("comp_band", BAND_NAMES, &a.synth_ui.comp_band)
		b := clamp(a.synth_ui.comp_band, 0, 2)
		at := int(synth.Compressor_Field.Low_Upper) + b * 5
		append(&knobs, Knob{"Attack", c(.Attack)}, Knob{"Release", c(.Release)}, Knob{"Mix", c(.Mix)},
			Knob{"Upper", c(synth.Compressor_Field(at))}, Knob{"Upper Ratio", c(synth.Compressor_Field(at + 2))},
			Knob{"Lower", c(synth.Compressor_Field(at + 1))}, Knob{"Lower Ratio", c(synth.Compressor_Field(at + 3))}, Knob{"Gain", c(synth.Compressor_Field(at + 4))})
	case .Delay:
		d :: proc(f: synth.Delay_Field) -> fc.Param_Id { return synth.effect_param(.Delay, f) }
		im.SameLine(0, 14)
		synth_choice(a, d(.Style), DELAY_STYLE_NAMES, 120, "##dstyle")
		im.SameLine(0, 8)
		synth_choice(a, d(.Sync), SYNC_NAMES, 130, "##dsync", "Time: ")
		append(&knobs, rate_knob(a, "Time", d(.Sync), d(.Hz), d(.Tempo)))
		if cp.delay.style != .Mono do append(&knobs, rate_knob(a, "Time R", d(.Sync), d(.Hz_Right), d(.Tempo_Right)))
		append(&knobs, Knob{"Feedback", d(.Feedback)}, Knob{"Cutoff", d(.Cutoff)}, Knob{"Spread", d(.Spread)}, Knob{"Mix", d(.Wet)})
	case .Distortion:
		d :: proc(f: synth.Distortion_Field) -> fc.Param_Id { return synth.effect_param(.Distortion, f) }
		im.SameLine(0, 14)
		synth_choice(a, d(.Type), DISTORTION_NAMES, 120, "##dtype")
		im.SameLine(0, 8)
		synth_choice(a, d(.Filter_Order), DISTORTION_FILTER_NAMES, 120, "##dorder")
		append(&knobs, Knob{"Drive", d(.Drive)}, Knob{"Mix", d(.Mix)})
		if cp.distortion.order != .None do append(&knobs, Knob{"Cutoff", d(.Cutoff)}, Knob{"Resonance", d(.Resonance)}, Knob{"Blend", d(.Blend)})
	case .Eq:
		for b in 0 ..< 3 {
			at := int(synth.Eq_Field.Low_Mode) + b * 4
			q :: proc(at, k: int) -> fc.Param_Id { return synth.effect_param(.Eq, synth.Eq_Field(at + k)) }
			im.SameLine(0, 14 if b == 0 else 8)
			synth_choice(a, q(at, 0), EQ_MODE_NAMES[b], 100, fmt.ctprintf("##eqm%d", b))
			cut := cp.eq.bands[b].mode == .Cut
			append(&knobs, Knob{fmt.ctprintf("%s Hz", BAND_NAMES[b]), q(at, 1)})
			if !cut || b == 1 do append(&knobs, Knob{fmt.ctprintf("%s Gain", BAND_NAMES[b]), q(at, 2)})
			append(&knobs, Knob{fmt.ctprintf("%s Q", BAND_NAMES[b]), q(at, 3)})
		}
	case .Filter:
		f :: proc(x: synth.Fx_Filter_Field) -> fc.Param_Id { return synth.effect_param(.Filter, x) }
		im.SameLine(0, 14)
		synth_choice(a, f(.Model), FILTER_MODEL_NAMES, 84, "##fxmodel")
		model := cp.filter.filter.model
		im.SameLine(0, 6)
		synth_choice(a, f(.Style), filter_style_names(model), 110, "##fxstyle")
		append(&knobs, Knob{"Cutoff", f(.Cutoff)}, Knob{"Resonance", f(.Resonance)})
		#partial switch model {
		case .Formant:
			append(&knobs, Knob{"Vowel X", f(.Formant_X)}, Knob{"Vowel Y", f(.Formant_Y)}, Knob{"Formant", f(.Formant_Transpose)}, Knob{"Q", f(.Formant_Resonance)}, Knob{"Spread", f(.Formant_Spread)})
		case .Comb:
			append(&knobs, Knob{"Blend", f(.Blend)}, Knob{"Offset", f(.Comb_Offset)})
		case:
			append(&knobs, Knob{"Drive", f(.Drive)}, Knob{"Blend", f(.Blend)})
			if cp.filter.filter.style == .Shelving do append(&knobs, Knob{"Gain", f(.Gain)})
		}
		append(&knobs, Knob{"Mix", f(.Mix)})
	case .Flanger:
		f :: proc(x: synth.Flanger_Field) -> fc.Param_Id { return synth.effect_param(.Flanger, x) }
		im.SameLine(0, 14)
		synth_choice(a, f(.Sync), SYNC_NAMES, 130, "##fsync", "Rate: ")
		append(&knobs, rate_knob(a, "Rate", f(.Sync), f(.Hz), f(.Tempo)), Knob{"Center", f(.Center)}, Knob{"Depth", f(.Depth)}, Knob{"Feedback", f(.Feedback)}, Knob{"Offset", f(.Offset)}, Knob{"Mix", f(.Wet)})
	case .Phaser:
		f :: proc(x: synth.Phaser_Field) -> fc.Param_Id { return synth.effect_param(.Phaser, x) }
		im.SameLine(0, 14)
		synth_choice(a, f(.Sync), SYNC_NAMES, 130, "##psync", "Rate: ")
		append(&knobs, rate_knob(a, "Rate", f(.Sync), f(.Hz), f(.Tempo)), Knob{"Center", f(.Center)}, Knob{"Depth", f(.Depth)}, Knob{"Feedback", f(.Feedback)}, Knob{"Blend", f(.Blend)}, Knob{"Offset", f(.Offset)}, Knob{"Mix", f(.Wet)})
	case .Reverb:
		r :: proc(x: synth.Reverb_Field) -> fc.Param_Id { return synth.effect_param(.Reverb, x) }
		append(&knobs, Knob{"Decay", r(.Decay)}, Knob{"Size", r(.Size)}, Knob{"Pre", r(.Delay)}, Knob{"Chorus", r(.Chorus)}, Knob{"Rate", r(.Chorus_Hz)}, Knob{"Mix", r(.Wet)})
		append(&knobs2, Knob{"Lo Cut", r(.Pre_Low)}, Knob{"Hi Cut", r(.Pre_High)}, Knob{"Lo Shelf", r(.Low_Cutoff)}, Knob{"Lo Gain", r(.Low_Gain)}, Knob{"Hi Shelf", r(.High_Cutoff)}, Knob{"Hi Gain", r(.High_Gain)})
	}
	_ = p
	// The picture, then the knobs under it.
	// (two rows of knobs: the picture beside them, not over them)
	two := len(knobs2) > 0
	y := im.GetCursorScreenPos().y + 4
	h := max(bottom - y - knob_row_height() - 8, 70)
	pw := w
	if two {
		h = max(bottom - y - 4, 70)
		pw = w * 0.26
	}
	im.SetCursorScreenPos({x0, y})
	size := im.Vec2{pw, h}
	switch e {
	case .Eq:
		measure_eq(&a.synth_ui.eq_curve, cp.eq, sr)
		ui.response_plot("synth eq response", {{db = a.synth_ui.eq_curve.db[:], color = color, fill = true, width = 2.5}}, nil, size)
		eq_dots(&cp.eq, &a.synth_ui.eq_curve, {x0, y}, size, color)
	case .Filter:
		c := &a.synth_ui.fx_filter_curve
		measure_filter(c, cp.filter.filter, sr)
		handle := [2]f32{ui.freq_x(fx.key_to_hz(cp.filter.filter.cutoff)), cp.filter.filter.resonance * 24}
		ev := ui.response_plot("synth fx filter response", {{db = c.db[:], color = color, fill = true, width = 2.5}}, &handle, size)
		if ev.changed {
			hz := ui.x_freq(handle[0])
			host_set(a, synth.effect_param(.Filter, synth.Fx_Filter_Field.Cutoff), 69 + 12 * math.log2(hz / 440), "FX Filter Cutoff")
			host_set(a, synth.effect_param(.Filter, synth.Fx_Filter_Field.Resonance), clamp(handle[1] / 24, 0, 1), "FX Filter Cutoff")
		}
		if ev.ended do pa.history_gesture_end(&a.api)
	case .Distortion: draw_distortion_view(&cp.distortion, size, color, sr)
	case .Delay:      draw_delay_view(&cp.delay, size, color)
	case .Reverb:     draw_reverb_view(&cp.reverb, size, color)
	case .Compressor: draw_compressor_view(a, &cp.compressor, chain, size, color)
	case .Chorus, .Flanger, .Phaser: draw_sweep_view(e, &cp, chain, size, color)
	}
	if two {
		kx := x0 + pw + 12
		im.SetCursorScreenPos({kx, y})
		synth_knob_row(a, w - pw - 12, knobs[:])
		im.SetCursorScreenPos({kx, im.GetCursorScreenPos().y + 2})
		synth_knob_row(a, w - pw - 12, knobs2[:])
	} else {
		im.SetCursorScreenPos({x0, y + h + 8})
		synth_knob_row(a, w, knobs[:])
	}
}

// A picture's frame: its background, and the rect inside its padding.
@(private = "file")
view_begin :: proc(id: string, size: im.Vec2) -> (dl: ^im.DrawList, x0, y0, x1, y1: f32) {
	t := ui.theme()
	dl = im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name(id)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	pad: f32 = 10
	return dl, pos.x + pad, pos.y + pad, pos.x + size.x - pad, pos.y + size.y - pad
}

// Each EQ band's place on its response: a dot at its frequency.
@(private = "file")
eq_dots :: proc(p: ^fx.Eq_Params, c: ^Eq_Curve, pos: im.Vec2, size: im.Vec2, color: ui.Color) {
	dl := im.GetWindowDrawList()
	pad: f32 = 8
	x0, x1 := pos.x + pad, pos.x + size.x - pad
	top, bottom := pos.y + pad, pos.y + size.y - pad
	for b in 0 ..< 3 {
		hz := fx.key_to_hz(p.bands[b].cutoff)
		fx_ := ui.freq_x(hz)
		k := clamp(int(fx_ * (RESPONSE_POINTS - 1) + 0.5), 0, RESPONSE_POINTS - 1)
		db := clamp(c.db[k], -36, 24)
		x := x0 + (x1 - x0) * fx_
		y := bottom - (db + 36) / 60 * (bottom - top)
		im.DrawList_AddCircleFilled(dl, {x, y}, 5, ui.col(ui.mix(color, ui.theme().text, 0.4)))
		im.DrawList_AddText(dl, {x - 8, y - 22}, ui.col(ui.theme().text_dim), fmt.ctprintf("%s", BAND_NAMES[b]))
	}
}

// A sine through the distortion (as it is set), over the sine itself.
@(private = "file")
draw_distortion_view :: proc(p: ^fx.Distortion_Params, size: im.Vec2, color: ui.Color, sr: f64) {
	dl, x0, y0, x1, y1 := view_begin("synth distortion view", size)
	t := ui.theme()
	N :: 480 // two cycles of 200 Hz at 48 kHz, after one to settle
	d := new(fx.Distortion, context.temp_allocator)
	l := make([]f32, N * 3 / 2, context.temp_allocator)
	r := make([]f32, len(l), context.temp_allocator)
	for &v, k in l do v = 0.8 * math.sin(math.TAU * f32(k) / 240)
	copy(r, l)
	pp := p^
	fx.distortion_render(d, &pp, l, r, 48_000)
	mid := (y0 + y1) / 2
	amp := (y1 - y0) / 2 / 1.25
	im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.12)), 1)
	P :: 240
	dry, wet: [P]im.Vec2
	for k in 0 ..< P {
		s := k * N / P
		x := x0 + (x1 - x0) * f32(k) / (P - 1)
		dry[k] = {x, mid - 0.8 * math.sin(math.TAU * f32(s + N / 2) / 240) * amp}
		wet[k] = {x, mid - clamp(l[s + N / 2], -1.25, 1.25) * amp}
	}
	im.DrawList_AddPolyline(dl, &dry[0], P, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.3)), 1.2)
	im.DrawList_AddPolyline(dl, &wet[0], P, ui.col(color), 2.4)
	_ = sr
}

// The delay's echoes: each a tap at its time (the left above, the right
// below), fading by its feedback.
@(private = "file")
draw_delay_view :: proc(p: ^fx.Delay_Params, size: im.Vec2, color: ui.Color) {
	dl, x0, y0, x1, y1 := view_begin("synth delay view", size)
	t := ui.theme()
	mid := (y0 + y1) / 2
	period := [2]f32{1 / max(p.hz[0], 0.01), 1 / max(p.hz[1], 0.01)}
	span := clamp(max(period[0], period[1]) * 8, 0.2, 4.5)
	xt :: proc(x0, x1, span, s: f32) -> f32 { return x0 + (x1 - x0) * s / span }
	im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.15)), 1)
	for s := f32(0.5); s < span; s += 0.5 {
		x := xt(x0, x1, span, s)
		im.DrawList_AddLine(dl, {x, y0}, {x, y1}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.08)), 1)
	}
	half := (y1 - y0) / 2 - 4
	im.DrawList_AddLine(dl, {x0, mid - half}, {x0, mid + half}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.4)), 3)
	fb := abs(clamp(p.feedback, -1, 1))
	wet := clamp(p.wet, 0, 1)
	tap :: proc(dl: ^im.DrawList, x, mid, h: f32, up: bool, c: ui.Color) {
		y := mid - h if up else mid + h
		im.DrawList_AddLine(dl, {x, mid}, {x, y}, ui.col(c), 3)
		im.DrawList_AddCircleFilled(dl, {x, y}, 3.5, ui.col(c))
	}
	g := wet
	switch p.style {
	case .Mono, .Stereo:
		for side in 0 ..< 2 {
			g = wet
			for k := 1; f32(k) * period[side] < span && g > 0.01; k += 1 {
				tap(dl, xt(x0, x1, span, f32(k) * period[side]), mid, half * g, side == 0, color)
				g *= fb
			}
		}
	case .Ping_Pong, .Mid_Ping_Pong:
		step := period[0] if p.style == .Ping_Pong else (period[0] + period[1]) / 2
		for k := 1; f32(k) * step < span && g > 0.01; k += 1 {
			tap(dl, xt(x0, x1, span, f32(k) * step), mid, half * g, k % 2 == 0, color)
			g *= fb
		}
	}
	im.DrawList_AddText(dl, {x0 + 4, y0}, ui.col(t.text_dim), "L")
	im.DrawList_AddText(dl, {x0 + 4, y1 - im.GetTextLineHeight()}, ui.col(t.text_dim), "R")
	im.DrawList_AddText(dl, {x1 - 60, y0}, ui.col(t.text_dim), fmt.ctprintf("%.2f s", span))
}

// The reverb's tail: its early reflections (denser the larger it is),
// then its fall of 60 dB in the decay time, after the pre-delay.
@(private = "file")
draw_reverb_view :: proc(p: ^fx.Reverb_Params, size: im.Vec2, color: ui.Color) {
	dl, x0, y0, x1, y1 := view_begin("synth reverb view", size)
	t := ui.theme()
	decay := clamp(p.decay, 0.1, 100)
	span := clamp(p.delay + decay * 1.2, 0.5, 30)
	xt :: proc(x0, x1, span, s: f32) -> f32 { return x0 + (x1 - x0) * clamp(s / span, 0, 1) }
	yd :: proc(y0, y1, db: f32) -> f32 { return y1 - (clamp(db, -60, 0) + 60) / 60 * (y1 - y0) }
	for db := f32(-48); db < 0; db += 12 do im.DrawList_AddLine(dl, {x0, yd(y0, y1, db)}, {x1, yd(y0, y1, db)}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.08)), 1)
	start := p.delay
	wet := clamp(p.wet, 0, 1)
	top_db := 20 * math.log10(max(wet, 0.001))
	N :: 64
	pts: [N + 2]im.Vec2
	for k in 0 ..< N {
		s := start + (span - start) * f32(k) / (N - 1)
		pts[k] = {xt(x0, x1, span, s), yd(y0, y1, top_db - 60 * (s - start) / decay)}
	}
	pts[N] = {x1, y1}
	pts[N + 1] = {xt(x0, x1, span, start), y1}
	im.DrawList_AddConvexPolyFilled(dl, &pts[0], N + 2, ui.col(ui.with_alpha(color, 0.25)))
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(color), 2.4)
	// Early reflections: lines in the first 80 ms × size.
	count := 6 + int(clamp(p.size, 0, 1) * 18)
	early := 0.08 * (0.25 + clamp(p.size, 0, 1))
	for k in 0 ..< count {
		f := f32(k) / f32(count)
		s := start + early * (f + 0.37 * math.sin(f32(k) * 2.4) / f32(count))
		h := top_db - 6 - 10 * f
		im.DrawList_AddLine(dl, {xt(x0, x1, span, s), y1}, {xt(x0, x1, span, s), yd(y0, y1, h)}, ui.col(ui.mix(color, t.text, 0.35)), 1.5)
	}
	im.DrawList_AddText(dl, {x1 - 70, y0}, ui.col(t.text_dim), fmt.ctprintf("%.1f s", span))
}

// The compressor's bands as meters: what comes in (faint) and goes out,
// against each band's thresholds (lower and upper).
@(private = "file")
draw_compressor_view :: proc(a: ^App, p: ^fx.Compressor_Params, chain: ^fx.Chain, size: im.Vec2, color: ui.Color) {
	dl, x0, y0, x1, y1 := view_begin("synth compressor view", size)
	t := ui.theme()
	yd :: proc(y0, y1, db: f32) -> f32 { return y1 - (clamp(db, -80, 0) + 80) / 80 * (y1 - y0) }
	for db := f32(-72); db < 0; db += 12 do im.DrawList_AddLine(dl, {x0, yd(y0, y1, db)}, {x1, yd(y0, y1, db)}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.07)), 1)
	use := [3]bool{true, true, true}
	switch p.bands {
	case .Three:
	case .Low_Band:  use[2] = false
	case .Band_High: use[0] = false
	case .One:       use[0], use[2] = false, false
	}
	col_w := (x1 - x0) / 3
	for b in 0 ..< 3 {
		cx := x0 + col_w * (f32(b) + 0.5)
		bw := col_w * 0.32
		c := color if use[b] else ui.mix(ui.PLOT_BG, color, 0.3)
		if b == a.synth_ui.comp_band do im.DrawList_AddRect(dl, {cx - col_w * 0.45, y0}, {cx + col_w * 0.45, y1}, ui.col(ui.with_alpha(t.text, 0.2)), 4)
		levels: [2]f32 = {-80, -80}
		if chain != nil do for k in 0 ..< 2 do levels[k] = 10 * math.log10(max(chain.compressor.levels[b][k], 1e-9))
		im.DrawList_AddRectFilled(dl, {cx - bw, yd(y0, y1, levels[0])}, {cx - 2, y1}, ui.col(ui.with_alpha(c, 0.35)))
		im.DrawList_AddRectFilled(dl, {cx + 2, yd(y0, y1, levels[1])}, {cx + bw, y1}, ui.col(c))
		up := yd(y0, y1, p.band[b].upper_db)
		lo := yd(y0, y1, p.band[b].lower_db)
		im.DrawList_AddLine(dl, {cx - col_w * 0.42, up}, {cx + col_w * 0.42, up}, ui.col(ui.mix(c, t.text, 0.5)), 2)
		im.DrawList_AddLine(dl, {cx - col_w * 0.42, lo}, {cx + col_w * 0.42, lo}, ui.col(ui.with_alpha(ui.mix(c, t.text, 0.5), 0.6)), 1.5)
		im.DrawList_AddText(dl, {cx - 14, y1 - im.GetTextLineHeight()}, ui.col(t.text_dim), fmt.ctprintf("%s", BAND_NAMES[b]))
	}
}

// A chorus, flanger or phaser's sweep: one cycle of what moves it, each
// side's (and voice's) place on it now.
@(private = "file")
draw_sweep_view :: proc(e: fx.Effect, cp: ^fx.Chain_Params, chain: ^fx.Chain, size: im.Vec2, color: ui.Color) {
	dl, x0, y0, x1, y1 := view_begin("synth sweep view", size)
	t := ui.theme()
	mid := (y0 + y1) / 2
	amp := (y1 - y0) / 2 - 6
	tri :: proc(x: f32) -> f32 { f := x - math.floor(x); return 1 - abs(f * 2 - 1) }
	shape :: proc(e: fx.Effect, x: f32) -> f32 {
		if e == .Chorus do return math.sin(x * math.TAU)
		f := x - math.floor(x)
		return (1 - abs(f * 2 - 1)) * 2 - 1
	}
	depth: f32 = 1
	phase: f32 = 0
	#partial switch e {
	case .Chorus:
		depth = clamp(cp.chorus.depth, 0.05, 1)
		if chain != nil do phase = chain.chorus.phase
	case .Flanger:
		depth = clamp(cp.flanger.depth, 0.05, 1)
		if chain != nil do phase = chain.flanger.phase
	case .Phaser:
		depth = clamp(cp.phaser.depth / 48, 0.05, 1)
		if chain != nil do phase = chain.phaser.phase
	}
	_ = tri
	N :: 96
	pts: [N]im.Vec2
	for k in 0 ..< N {
		x := f32(k) / (N - 1)
		pts[k] = {x0 + (x1 - x0) * x, mid - shape(e, x) * amp * depth}
	}
	im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.12)), 1)
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.with_alpha(color, 0.7)), 2)
	dot :: proc(dl: ^im.DrawList, e: fx.Effect, x0, x1, mid, amp, depth, ph: f32, c: ui.Color) {
		f := ph - math.floor(ph)
		im.DrawList_AddCircleFilled(dl, {x0 + (x1 - x0) * f, mid - shape(e, f) * amp * depth}, 5, ui.col(c))
	}
	left := ui.mix(color, t.text, 0.5)
	right := ui.mix(color, ui.rgb(0x40a0ff), 0.5)
	#partial switch e {
	case .Chorus:
		pairs := clamp(cp.chorus.voices, 1, 4)
		for k in 0 ..< pairs do for side in 0 ..< 2 {
			off := f32(k) * 0.25 / f32(pairs) + (0.5 if side == 1 else 0)
			dot(dl, e, x0, x1, mid, amp, depth, phase + off, left)
			dot(dl, e, x0, x1, mid, amp, depth, phase + off + 0.25, right)
		}
	case .Flanger:
		off := cp.flanger.offset
		dot(dl, e, x0, x1, mid, amp, depth, phase - off / 2, left)
		dot(dl, e, x0, x1, mid, amp, depth, phase + off / 2, right)
	case .Phaser:
		off := cp.phaser.offset
		dot(dl, e, x0, x1, mid, amp, depth, phase + off / 2, left)
		dot(dl, e, x0, x1, mid, amp, depth, phase - off / 2, right)
	}
	im.DrawList_AddText(dl, {x0 + 4, y0}, ui.col(left), "L")
	im.DrawList_AddText(dl, {x0 + 18, y0}, ui.col(right), "R")
}
