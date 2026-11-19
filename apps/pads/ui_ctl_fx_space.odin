// Space: Delay, Reverb, Comb on a controller's display
// (docs/design/push2-devices.md, docs/design/push2-fx-space.md): each its
// picture (ui_fxpic_space.odin) over named banks of knobs, in an effect
// slot, as a Perform effect (Intensity first in every bank) and, the
// delay and reverb, on the synth's Effects tab (its picker first, On on
// the lower row's last) or in a slot as the synth's twin.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import pa "api"
import pm "model"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:synth"

// The delay's Sync, as its panel names it.
@(private) SP_SYNC_NAMES := []string{"Free", "Tempo", "Dotted", "Triplet"}

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_space :: proc(p: ^Fx_Panel) -> bool {
	#partial switch p.kind {
	case .Delay, .Reverb:
		// (A slot with the app's old delay or reverb settings: converted when
		// read, `pm.convert_slot`, so never here; the generic panel if it were.)
		if p.where_ == .Slot && (!p.twin || pm.slot_is_legacy(p.s)) do return false
		if p.kind == .Delay do sp_delay(p)
		else do sp_reverb(p)
		return true
	case .Comb:
		if p.where_ != .Slot do return false
		sp_comb(p)
		return true
	}
	return false
}

// A synth effect's settings as the panel's device has them now (a slot's
// over the defaults, a held Perform effect's as hard as it's pressed, the
// synth's), with automation where it plays: `fields` of effect `e`.
@(private)
sp_chain :: proc(p: ^Fx_Panel, e: fx.Effect, fields: int) -> (cp: fx.Chain_Params, on: bool) {
	a := p.ctx.a
	m := &a.m
	values := make([]f32, synth.PARAM_SLOTS, context.temp_allocator)
	for spec in synth.PARAMS do values[spec.id] = spec.default
	s := p.s
	perf_mix: f32 = 1
	if p.where_ == .Slot && p.t.kind == .Perf do s, perf_mix = pm.perf_effective(&m.project, p.t.index, m.engine.perf_live[p.t.index])
	for f in 0 ..< fields {
		id := synth.effect_param(e, synth.Delay_Field(f)) // (field f of the effect's own: their ids go in order)
		if int(id) >= synth.PARAM_SLOTS do continue
		if p.where_ == .Synth {
			values[id] = synth_now(m, p.pad, id)
		} else if v, ok := pm.automated_value(m, fx_auto_target(p.t, id)); ok {
			values[id] = v
		} else if spec := synth.param_spec(id); spec != nil {
			values[id] = pm.slot_value(s, id, spec.default)
		}
	}
	bpm := m.project.bpm if m.project.bpm > 0 else 120
	cp = synth.effect_chain_params(values, fx.CHAIN_ORDER, bpm)
	cp.delay.wet *= perf_mix
	cp.reverb.wet *= perf_mix
	if p.where_ == .Synth do on = pm.synth_value(m, p.pad, effect_on(e)) > 0.5
	else do on = p.s.on || p.t.kind == .Perf
	return
}

// The panel's colour (the pad's on the synth's tab), dim while it's off.
@(private)
sp_color :: proc(p: ^Fx_Panel, on: bool) -> ui.Color {
	c := ui.theme().accent
	if p.where_ == .Synth do c = ui.rgb(p.ctx.a.m.project.pads[p.pad].color)
	return c if on else ui.mix(ui.PLOT_BG, c, 0.45)
}

// The spectrum of what the device puts out now (a slot's, watched by
// `ctl_effect`; on the synth's tab, the pad's sound), or nil.
@(private)
sp_spec :: proc(p: ^Fx_Panel) -> []f32 {
	a := p.ctx.a
	if p.where_ == .Synth do pm.watch_sound(&a.m.engine, p.pad)
	return spectrum(a)
}

// Sets parameter `id` of the panel's device to `v` (a press: one step).
@(private)
sp_set :: proc(p: ^Fx_Panel, id: fc.Param_Id, v: f32, name: string) {
	a := p.ctx.a
	if p.where_ == .Synth {
		host_set(a, id, v, name)
		pa.history_gesture_end(&a.api)
		return
	}
	control_effect_param(a, p.t, i64(id), f64(v), true, true)
}

// A synth effect parameter's plain value as the panel's device has it set.
@(private)
sp_plain :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> f32 {
	if p.where_ == .Synth do return pm.synth_value(&p.ctx.a.m, p.pad, id)
	spec := synth.param_spec(id)
	return pm.slot_value(p.s, id, spec.default if spec != nil else 0)
}

// The delay's free time (`id`: a rate, log2 of Hz) on `bank`'s column
// `col` as a time: milliseconds shown, turned up for longer.
@(private)
sp_time_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string) {
	ctx := p.ctx
	a := ctx.a
	tag := fmt.ctprintf("%s##fx%d", label, int(id))
	if !ctl_knob(ctx, fx_index(p, bank, col), p.banks * 8, tag, p.plot) do return
	spec := synth.param_spec(id)
	if spec == nil do return
	v := sp_plain(p, id)
	span := spec.max - spec.min
	x := (spec.max - v) / span // (0: the shortest)
	shown := fmt.ctprintf("%s", sp_secs(1 / math.pow(2, v)))
	e := ui.knob(tag, &x, 0, 1, (spec.max - spec.default) / span, "%.3f", shown_value = shown)
	nv := clamp(spec.max - x * span, spec.min, spec.max)
	if p.where_ == .Synth {
		control_param(a, {track = .Pad, index = i64(p.pad), device = .Sound, param = i64(id)}, f64(nv), spec.name, e.changed, e.ended)
	} else {
		control_effect_param(a, p.t, i64(id), f64(nv), e.changed, e.ended)
	}
}

// --- Delay --------------------------------------------------------------------------------------

// The delay: its echoes and tone; Echoes (Time, Feedback, Mix, Sync,
// Style, Time R) and Tone (Cutoff, Spread); its four styles on the lower row.
@(private)
sp_delay :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	d :: proc(f: synth.Delay_Field) -> fc.Param_Id { return synth.effect_param(.Delay, f) }
	cp, on := sp_chain(p, .Delay, len(synth.Delay_Field))
	sync := int(sp_plain(p, d(.Sync)) + 0.5)
	style := int(sp_plain(p, d(.Style)) + 0.5)
	// The picture's caption: the time (each side's when they differ).
	tempo := TEMPO_NAMES
	time_of :: proc(p: ^Fx_Panel, sync: int, hz, tempo: fc.Param_Id, names: [13]string) -> string {
		if sync == 0 do return sp_secs(1 / math.pow(2, sp_plain(p, hz)))
		mark := [4]string{"", "", " dotted", " triplet"}
		return fmt.tprintf("%s%s", names[clamp(int(sp_plain(p, tempo) + 0.5), 0, 12)], mark[clamp(sync, 0, 3)])
	}
	left := time_of(p, sync, d(.Hz), d(.Tempo), tempo)
	right := time_of(p, sync, d(.Hz_Right), d(.Tempo_Right), tempo)
	caption := fmt.tprintf("%s  %s", left, DELAY_STYLE_NAMES[clamp(style, 0, 3)])
	if style != int(fx.Delay_Style.Mono) && right != left do caption = fmt.tprintf("L %s  R %s  %s", left, right, DELAY_STYLE_NAMES[clamp(style, 0, 3)])
	if p.where_ == .Synth && !on do caption = fmt.tprintf("%s (off)", caption)
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	sp_delay_picture(cp.delay, a.m.project.bpm, sr, sp_spec(p), caption, p.plot, sp_color(p, on))
	fx_banks(p, "Echoes", "Tone")
	// Echoes.
	if sync == 0 do sp_time_knob(p, 0, 0, d(.Hz), "Time")
	else do fx_knob(p, 0, 0, d(.Tempo), "Time", TEMPO_NAMES[:])
	fx_knob(p, 0, 1, d(.Feedback), "Feedback")
	fx_knob(p, 0, 2, d(.Wet), "Mix")
	fx_knob(p, 0, 3, d(.Sync), "Sync", SP_SYNC_NAMES)
	fx_knob(p, 0, 4, d(.Style), "Style")
	right_label := "Time R" if style != int(fx.Delay_Style.Mono) else "(Time R)"
	if sync == 0 do sp_time_knob(p, 0, 5, d(.Hz_Right), right_label)
	else do fx_knob(p, 0, 5, d(.Tempo_Right), right_label, TEMPO_NAMES[:]) // (its name isn't " Tempo"'s: named here)
	// Tone.
	fx_knob(p, 1, 0, d(.Cutoff), "Cutoff")
	fx_knob(p, 1, 1, d(.Spread), "Spread")
	// The lower row: its styles.
	for name, k in DELAY_STYLE_NAMES {
		if pr, _ := ctl_button(p.ctx, k, fmt.ctprintf("%s", name), style == k, p.full); pr && style != k do sp_set(p, d(.Style), f32(k), "Delay Style")
	}
}

// --- Reverb -------------------------------------------------------------------------------------

// The reverb: its tail and how long it rings by frequency; Room (Decay,
// Size, Pre-Delay, Mix, Chorus, Rate) and Tone (the input's cuts, the
// tail's shelves).
@(private)
sp_reverb :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	r :: proc(f: synth.Reverb_Field) -> fc.Param_Id { return synth.effect_param(.Reverb, f) }
	cp, on := sp_chain(p, .Reverb, len(synth.Reverb_Field))
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	sp_reverb_picture(cp.reverb, sr, sp_spec(p), a.transport.clock, p.plot, sp_color(p, on))
	fx_banks(p, "Room", "Tone")
	// Room.
	fx_knob(p, 0, 0, r(.Decay), "Decay")
	fx_knob(p, 0, 1, r(.Size), "Size")
	fx_knob(p, 0, 2, r(.Delay), "Pre-Delay")
	fx_knob(p, 0, 3, r(.Wet), "Mix")
	fx_knob(p, 0, 4, r(.Chorus), "Chorus")
	fx_knob(p, 0, 5, r(.Chorus_Hz), "Rate")
	// Tone.
	fx_knob(p, 1, 0, r(.Pre_Low), "Lo Cut")
	fx_knob(p, 1, 1, r(.Pre_High), "Hi Cut")
	fx_knob(p, 1, 2, r(.Low_Cutoff), "Lo Shelf")
	fx_knob(p, 1, 3, r(.Low_Gain), "Lo Gain")
	fx_knob(p, 1, 4, r(.High_Cutoff), "Hi Shelf")
	fx_knob(p, 1, 5, r(.High_Gain), "Hi Gain")
}

// --- Comb ---------------------------------------------------------------------------------------

// The comb: its teeth on a spectrum; Comb (Frequency, Feedback, Mix); on
// the lower row, its feedback's sign (every harmonic, or the odd ones an
// octave down).
@(private)
sp_comb :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	m := &a.m
	get :: proc(m: ^pm.Model, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
		if v, ok := pm.automated_value(m, fx_auto_target(t, id)); ok do return v
		return pm.slot_value(s, id, f32(dsp.comb_params[int(id) - 1].default))
	}
	s := p.s
	mix: f32 = 1
	if p.t.kind == .Perf do s, mix = pm.perf_effective(&m.project, p.t.index, m.engine.perf_live[p.t.index])
	hz, fb := get(m, p.t, s, dsp.COMB_PARAM_HZ), get(m, p.t, s, dsp.COMB_PARAM_FEEDBACK)
	mix *= clamp(get(m, p.t, s, dsp.COMB_PARAM_MIX), 0, 1)
	on := p.s.on || p.t.kind == .Perf
	sp_comb_picture(hz, fb, mix, spectrum(a), p.plot, sp_color(p, on))
	fx_banks(p, "Comb")
	fx_knob(p, 0, 0, dsp.COMB_PARAM_HZ, "Frequency")
	fx_knob(p, 0, 1, dsp.COMB_PARAM_FEEDBACK, "Feedback")
	fx_knob(p, 0, 2, dsp.COMB_PARAM_MIX, "Mix")
	// The lower row: the feedback's sign.
	set_fb := pm.slot_value(p.s, dsp.COMB_PARAM_FEEDBACK, f32(dsp.comb_params[1].default))
	for name, k in ([2]cstring{"All Harmonics", "Odd Harmonics"}) {
		now := (set_fb < 0) == (k == 1)
		if pr, _ := ctl_button(p.ctx, k, name, now, p.full); pr && !now do sp_set(p, dsp.COMB_PARAM_FEEDBACK, -set_fb, "Comb Feedback")
	}
}
