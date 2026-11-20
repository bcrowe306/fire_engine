// Tone: the EQ, the Filter and the pad's EQ on a controller's display
// (docs/design/push2-devices.md, docs/design/push2-fx-tone.md): each its
// response (ui_fxpic_tone.odin) over the spectrum of what comes out, over
// named banks of knobs. The EQ and the Filter wherever they can be: an
// effect slot (the synth's twin), a Perform effect (Intensity first in
// every bank), the synth's Effects tab (its picker first, On on the lower
// row's last). Old projects' Low-, High- and Band-pass are Filters by the
// time they're shown (`pm.convert_slot`, `pm.new_effect`).
//
//	EQ: EQ (each band's frequency and gain), Low, Band, High (Freq, Gain,
//	Q, Mode); on the lower row its cuts (Low Cut, Notch, High Cut).
//	Filter: Filter (Cutoff, Res, Model, Style, Blend, Drive, Mix), Shape
//	(Gain, Comb Offset, the Formant model's vowel); on the lower row
//	its style's three responses (Low-pass, Band-pass, High-pass...).
//	The pad's EQ: EQ (Low, Mid, High); EQ On on the lower row (Mute +
//	Device turns effects off, and the pad's EQ is not one).
package pads

import "core:fmt"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:fx"
import "fire:synth"

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_tone :: proc(p: ^Fx_Panel) -> bool {
	if p.where_ == .Pad_Eq {
		tone_pad_eq(p)
		return true
	}
	#partial switch p.kind {
	case .Eq, .Filter:
		// (A slot with the app's old settings: converted when read, so
		// never here; the generic panel if it were.)
		if p.where_ == .Slot && (!p.twin || pm.slot_is_legacy(p.s)) do return false
		if p.kind == .Eq do tone_eq(p)
		else do tone_filter(p)
		return true
	}
	// (Low-, High-, Band-pass: Filters once read, `pm.convert_slot`; none
	// reaches a panel as its old kind.)
	return false
}

// The sample rate the pictures are measured at.
@(private = "file")
tone_sr :: proc(a: ^App) -> f64 {
	return a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
}

// A synth effect's settings as the panel's device has them now (a slot's
// over the defaults, a held Perform effect's as hard as it's pressed, the
// synth's), with automation where it plays: `fields` of effect `e`; the
// mix a Perform effect is heard at; whether it's on.
@(private = "file")
tone_chain :: proc(p: ^Fx_Panel, e: fx.Effect, fields: int) -> (cp: fx.Chain_Params, mix: f32, on: bool) {
	a := p.ctx.a
	m := &a.m
	values := make([]f32, synth.PARAM_SLOTS, context.temp_allocator)
	for spec in synth.PARAMS do values[spec.id] = spec.default
	s := p.s
	mix = 1
	if p.where_ == .Slot && p.t.kind == .Perf do s, mix = pm.perf_effective(&m.project, p.t.index, m.engine.perf_live[p.t.index])
	base := int(synth.effect_param(e, synth.Eq_Field.On)) // (field 0 of each: their ids go in order)
	for f in 0 ..< fields {
		id := fc.Param_Id(base + f)
		if int(id) >= synth.PARAM_SLOTS do continue
		if p.where_ == .Synth {
			values[id] = synth_now(m, p.pad, id)
		} else if v, ok := pm.automated_value(m, fx_auto_target(p.t, id)); ok {
			values[id] = v
		} else if spec := synth.param_spec(id); spec != nil {
			values[id] = pm.slot_value(s, id, spec.default)
		}
	}
	cp = synth.effect_chain_params(values, fx.CHAIN_ORDER, m.project.bpm if m.project.bpm > 0 else 120)
	if p.where_ == .Synth do on = pm.synth_value(m, p.pad, effect_on(e)) > 0.5
	else do on = p.s.on || p.t.kind == .Perf
	return
}

// The picture's colour (the pad's on the synth's tab and for its EQ), dim
// while it's off.
@(private = "file")
tone_color :: proc(p: ^Fx_Panel, on: bool) -> ui.Color {
	c := ui.theme().accent
	if p.where_ == .Synth || p.where_ == .Pad_Eq do c = ui.rgb(p.ctx.a.m.project.pads[p.pad].color)
	return c if on else ui.mix(ui.PLOT_BG, c, 0.45)
}

// The spectrum of what the device puts out now (a slot's, watched by
// `ctl_effect`; on the synth's tab, the pad's sound), or nil.
@(private = "file")
tone_spec :: proc(p: ^Fx_Panel) -> []f32 {
	a := p.ctx.a
	if p.where_ == .Synth || p.where_ == .Pad_Eq do pm.watch_sound(&a.m.engine, p.pad)
	return spectrum(a)
}

// A synth effect parameter's plain value as the panel's device has it set.
@(private = "file")
tone_plain :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> f32 {
	if p.where_ == .Synth do return pm.synth_value(&p.ctx.a.m, p.pad, id)
	return fx_value(p, id)
}

// Sets parameter `id` of the panel's device to `v` (a press: one step).
@(private = "file")
tone_set :: proc(p: ^Fx_Panel, id: fc.Param_Id, v: f32, name: string) {
	a := p.ctx.a
	if p.where_ == .Synth {
		host_set(a, id, v, name)
		pa.history_gesture_end(&a.api)
		return
	}
	control_effect_param(a, p.t, i64(id), f64(v), true, true)
}

// How a knob of `tone_knob`'s reads.
@(private = "file")
Tone_Unit :: enum {
	Hz,        // a cutoff (a key): Hz, kHz
	Semitones, // a signed number of semitones
}

// A synth effect's parameter `id` on `bank`'s column `col`: as
// `fx_knob`'s (undo, automation), reading as `unit` says (a cutoff in
// Hz and kHz: it turns in semitones, a log frequency).
@(private = "file")
tone_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string, unit: Tone_Unit) {
	ctx := p.ctx
	tag := fmt.ctprintf("%s##tn%d", label, int(id))
	if !ctl_knob(ctx, fx_index(p, bank, col), p.banks * 8, tag, p.plot) do return
	spec := synth.param_spec(id)
	if spec == nil do return
	v := tone_plain(p, id)
	shown: cstring
	switch unit {
	case .Hz:        shown = fmt.ctprintf("%s", tone_hz(fx.key_to_hz(v)))
	case .Semitones: shown = fmt.ctprintf("%+.0f st", v)
	}
	e := fx_ring_knob(p, tag, id, &v, {lo = spec.min, hi = spec.max}, spec.default, "%.3f", shown)
	fx_ring_set(p, id, f64(clamp(v, spec.min, spec.max)), spec.name, e)
}

// The column (0..7) of the knob held now in the bank shown, or -1.
@(private = "file")
tone_held :: proc() -> int {
	ki := ui.knob_input
	if ki == nil do return -1
	for h, k in ki.held do if h do return k
	return -1
}

// --- EQ -----------------------------------------------------------------------------------------

// The EQ (the synth's three bands): its response, each band's mark;
// EQ (every band's frequency and gain), Low, Band, High (each band's).
@(private = "file")
tone_eq :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	q :: proc(b, k: int) -> fc.Param_Id { return synth.effect_param(.Eq, synth.Eq_Field(int(synth.Eq_Field.Low_Mode) + b * 4 + k)) }
	cp, mix, on := tone_chain(p, .Eq, len(synth.Eq_Field))
	fx_banks(p, "EQ", "Low", "Band", "High")
	page := a.ctl.page
	// The band in focus: the bank's, or on the first the one whose knob is held.
	focus := page - 1 if page >= 1 && page <= 3 else -1
	if page == 0 do if h := tone_held() - p.lead; h >= 0 && h < 6 do focus = h / 2
	// The picture.
	sr := tone_sr(a)
	total, own := tone_eq_db(cp.eq, sr)
	tone_blend(total, mix)
	for b in 0 ..< 3 do tone_blend(own[b], mix)
	marks: [3]Tone_Mark
	gains: [3]f32
	short := [3]string{"L", "B", "H"}
	for b in 0 ..< 3 {
		band := cp.eq.bands[b]
		marks[b] = {hz = fx.key_to_hz(band.cutoff), label = short[b], color = ui.rgb(TONE_BAND_COLORS[b]), own = own[b]}
		gains[b] = band.gain_db // (a cut's too: its level, the digital filter's gain)
	}
	caption := ""
	if focus >= 0 {
		band := cp.eq.bands[focus]
		mode := EQ_MODE_NAMES[focus][int(band.mode)]
		caption = fmt.tprintf("%s  %s  %s  %+.1f dB", BAND_NAMES[focus], mode, tone_hz(fx.key_to_hz(band.cutoff)), band.gain_db)
	} else {
		caption = fmt.tprintf("%s · %s · %s", EQ_MODE_NAMES[0][int(cp.eq.bands[0].mode)], EQ_MODE_NAMES[1][int(cp.eq.bands[1].mode)], EQ_MODE_NAMES[2][int(cp.eq.bands[2].mode)])
	}
	if !on do caption = fmt.tprintf("%s  (off)", caption)
	r := tone_range(gains[:], total)
	im.SetCursorPos({0, CTL_PLOT_Y})
	tone_picture(total, marks[:], focus, tone_spec(p), caption, "EQ", -r, r, true, p.plot, tone_color(p, on))
	// EQ: each band's frequency and gain.
	for b in 0 ..< 3 {
		tone_knob(p, 0, b * 2, q(b, 1), fmt.tprintf("%s Freq", BAND_NAMES[b]), .Hz)
		fx_knob(p, 0, b * 2 + 1, q(b, 2), fmt.tprintf("%s Gain", BAND_NAMES[b]))
	}
	// Low, Band, High: each band's own.
	for b in 0 ..< 3 {
		tone_knob(p, b + 1, 0, q(b, 1), "Freq", .Hz)
		fx_knob(p, b + 1, 1, q(b, 2), "Gain")
		fx_knob(p, b + 1, 2, q(b, 3), "Q")
		fx_knob(p, b + 1, 3, q(b, 0), "Mode", EQ_MODE_NAMES[b])
	}
	// The lower row: its cuts (each band's mode, Cut or not).
	cuts := [3]cstring{"Low Cut", "Notch", "High Cut"}
	for b in 0 ..< 3 {
		cut := int(tone_plain(p, q(b, 0)) + 0.5) == int(fx.Eq_Mode.Cut)
		if pr, _ := ctl_button(p.ctx, b, cuts[b], cut, p.full); pr do tone_set(p, q(b, 0), f32(fx.Eq_Mode.Shelf if cut else fx.Eq_Mode.Cut), "EQ Mode")
	}
}

// --- Filter -------------------------------------------------------------------------------------

// What a style's blend goes through (0, 1, 2), by style.
@(private = "file") TONE_PASS_NAMES := []string{"Low-pass", "Band-pass", "High-pass"}
@(private = "file") TONE_NOTCH_NAMES := []string{"Low-pass", "Notch", "High-pass"}
@(private = "file") TONE_BAND_PEAK_NAMES := []string{"Band-pass", "Peak", "Notch"}
@(private = "file") TONE_SHELF_NAMES := []string{"Low shelf", "Peak", "High shelf"}

// The three responses a style's blend goes through (0, 1, 2), or nil
// where the blend is no choice of three (the dual notch, the formant,
// comb and phaser models).
@(private = "file")
tone_blend_names :: proc(model: fx.Filter_Model, style: fx.Filter_Style) -> []string {
	#partial switch model {
	case .Formant, .Comb, .Phaser: return nil
	}
	switch style {
	case .Db12, .Db24:     return TONE_PASS_NAMES
	case .Notch_Pass_Swap: return TONE_NOTCH_NAMES
	case .Band_Peak_Notch: return TONE_BAND_PEAK_NAMES
	case .Shelving:        return TONE_SHELF_NAMES
	case .Dual_Notch_Band:
	}
	return nil
}

// The Filter (the synth's): its response measured from its settings, its
// cutoff's mark; Filter (Cutoff, Res, Model, Style, Blend, Drive, Mix),
// Shape (Gain, Comb Offset, the vowel); the blend's three on the
// lower row.
@(private = "file")
tone_filter :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	f :: proc(x: synth.Fx_Filter_Field) -> fc.Param_Id { return synth.effect_param(.Filter, x) }
	cp, mix, on := tone_chain(p, .Filter, len(synth.Fx_Filter_Field))
	fp := cp.filter.filter
	fx_banks(p, "Filter", "Shape")
	// The picture.
	total := tone_filter_db(fp, tone_sr(a))
	tone_blend(total, mix)
	model, style := fp.model, fp.style
	styles := filter_style_names(model)
	type_name := ""
	if names := tone_blend_names(model, style); names != nil {
		k := int(fp.blend + 0.5)
		type_name = names[clamp(k, 0, 2)] if abs(fp.blend - f32(k)) < 0.05 else fmt.tprintf("Blend %.2f", fp.blend)
	}
	caption := fmt.tprintf("%s%s%s", type_name, " · " if type_name != "" else "", tone_hz(fx.key_to_hz(fp.cutoff)))
	if fp.resonance > 0.005 do caption = fmt.tprintf("%s  Res %.0f%%", caption, fp.resonance * 100)
	if !on do caption = fmt.tprintf("%s  (off)", caption)
	right := fmt.tprintf("%s %s", FILTER_MODEL_NAMES[int(model)], styles[clamp(int(style), 0, len(styles) - 1)])
	marks := [1]Tone_Mark{{hz = fx.key_to_hz(fp.cutoff), label = "", color = ui.mix(tone_color(p, on), ui.theme().text, 0.35)}}
	im.SetCursorPos({0, CTL_PLOT_Y})
	tone_picture(total, marks[:], -1, tone_spec(p), caption, right, -30, 18, false, p.plot, tone_color(p, on))
	// Filter.
	formant, comb := model == .Formant, model == .Comb
	tone_knob(p, 0, 0, f(.Cutoff), "Cutoff", .Hz)
	fx_knob(p, 0, 1, f(.Resonance), "Res")
	fx_knob(p, 0, 2, f(.Model), "Model", FILTER_MODEL_NAMES)
	fx_knob(p, 0, 3, f(.Style), "Style", styles, filter_style_names(model, short = true))
	fx_knob(p, 0, 4, f(.Blend), "(Blend)" if formant else "Blend")
	fx_knob(p, 0, 5, f(.Drive), "(Drive)" if formant || comb else "Drive")
	fx_knob(p, 0, 6, f(.Mix), "Mix")
	// Shape: what only some models and styles use (in brackets otherwise).
	fx_knob(p, 1, 0, f(.Gain), ("Shelf Gain" if style == .Shelving else "Gain") if model == .Digital else "(Gain)") // (the Digital model's: its shelf's, or its level)
	tone_knob(p, 1, 1, f(.Comb_Offset), "Comb Offset" if comb else "(Comb Offset)", .Semitones)
	vowel :: proc(on: bool, name: string) -> string { return name if on else fmt.tprintf("(%s)", name) }
	fx_knob(p, 1, 2, f(.Formant_X), vowel(formant, "Vowel X"))
	fx_knob(p, 1, 3, f(.Formant_Y), vowel(formant, "Vowel Y"))
	tone_knob(p, 1, 4, f(.Formant_Transpose), vowel(formant, "Formant"), .Semitones)
	fx_knob(p, 1, 5, f(.Formant_Resonance), vowel(formant, "Formant Q"))
	fx_knob(p, 1, 6, f(.Formant_Spread), vowel(formant, "Spread"))
	// The lower row: the blend's three (as the style names them).
	set_model := fx.Filter_Model(clamp(int(tone_plain(p, f(.Model)) + 0.5), 0, len(fx.Filter_Model) - 1))
	set_style := fx.Filter_Style(clamp(int(tone_plain(p, f(.Style)) + 0.5), 0, len(fx.Filter_Style) - 1))
	if names := tone_blend_names(set_model, set_style); names != nil {
		blend := tone_plain(p, f(.Blend))
		for name, k in names {
			now := abs(blend - f32(k)) < 0.05
			if pr, _ := ctl_button(p.ctx, k, fmt.ctprintf("%s", name), now, p.full); pr && !now do tone_set(p, f(.Blend), f32(k), "FX Filter Blend")
		}
	}
}

// --- the pad's EQ -------------------------------------------------------------------------------

// The pad's own EQ: its three bands' response (a low shelf, a bell, a high
// shelf at fixed frequencies), each band's mark; EQ (Low, Mid, High); EQ
// On on the lower row.
@(private = "file")
tone_pad_eq :: proc(p: ^Fx_Panel) {
	ctx := p.ctx
	a := ctx.a
	m := &a.m
	i := p.pad
	pad := m.project.pads[i]
	ctl_tabs(ctx, {"EQ" if pad.eq_on else "EQ (off)"}, 0)
	fx_banks(p, "EQ")
	// Its gains as they play (automation moving them), flat while it's off.
	fields := [3]pm.Pad_Field{.Eq_Low, .Eq_Mid, .Eq_High}
	gains := pad.eq
	for b in 0 ..< 3 do if v, ok := pm.automated_value(m, pad_field_target(a, i, fields[b])); ok do gains[b] = v
	heard := gains if pad.eq_on else {}
	total, own := tone_pad_eq_db(heard, tone_sr(a))
	// The spectrum: the pad's sound (before its EQ) through the EQ.
	spec := tone_spec(p)
	if spec != nil do for &v, k in spec do v += total[clamp(k * (RESPONSE_POINTS - 1) / max(len(spec) - 1, 1), 0, RESPONSE_POINTS - 1)]
	names := [3]string{"Low", "Mid", "High"}
	short := [3]string{"L", "M", "H"}
	marks: [3]Tone_Mark
	for b in 0 ..< 3 do marks[b] = {hz = tone_pad_eq_hz(b), label = short[b], color = ui.rgb(TONE_BAND_COLORS[b]), own = own[b], dim = !pad.eq_on}
	focus := -1
	if h := tone_held(); h >= 0 && h < 3 do focus = h
	caption := fmt.tprintf("Low %+.1f · Mid %+.1f · High %+.1f dB%s", gains[0], gains[1], gains[2], "" if pad.eq_on else "  (off)")
	if focus >= 0 do caption = fmt.tprintf("%s  %s  %+.1f dB", names[focus], tone_hz(tone_pad_eq_hz(focus)), gains[focus])
	r := tone_range(gains[:], total)
	im.SetCursorPos({0, CTL_PLOT_Y})
	tone_picture(total, marks[:], focus, spec, caption, "", -r, r, true, p.plot, tone_color(p, pad.eq_on))
	pd := pad
	labels := [3]cstring{"Low", "Mid", "High"}
	steps := [3]string{"Set EQ Low", "Set EQ Mid", "Set EQ High"}
	for b in 0 ..< 3 {
		if ctl_knob(ctx, fx_index(p, 0, b), p.banks * 8, labels[b], p.plot) do knob_f32(a, labels[b], &pd.eq[b], -15, 15, 0, "%+.1f dB", fields[b], steps[b])
	}
	// EQ On (Mute + Device turns effects off: the pad's EQ is not one).
	if pr, _ := ctl_button(ctx, 0, "EQ On", pad.eq_on, p.full); pr {
		np := pad
		np.eq_on = !pad.eq_on
		pm.set_pad(m, i, .Eq_Low, "EQ On" if np.eq_on else "EQ Off", np)
		app.seal(&m.history)
	}
}
