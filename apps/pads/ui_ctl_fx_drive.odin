// Drive: Distortion, Ring mod, Saturation, Bit-crusher on a controller's
// display (docs/design/push2-devices.md, docs/design/push2-fx-drive.md):
// each its picture (ui_fxpic_drive.odin) over its knobs.
//
//	Distortion (the synth's; in a slot, Perform, or the synth's Effects
//	tab): Main (Drive, Type, Mix, Filter, Cutoff, Resonance, Blend; the
//	filter's three in brackets while it has none).
//	Ring mod (a slot or Perform): Main (Frequency, Mix).
//	Saturation and Bit-crusher: old projects' effects, made distortions
//	when they load (`pm.convert_slot`: soft clip at their drive, or the
//	bit crush type at their bits), so they're shown as the Distortion.
//
// The lower row is theirs and they have no choices of their own there: On
// is Mute + Device, Remove is Delete + Device (the synth's tab: its On).
package pads

import "core:fmt"

import "app:ui"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:synth"

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_drive :: proc(p: ^Fx_Panel) -> bool {
	#partial switch p.kind {
	case .Distortion, .Saturation, .Bitcrush:
		// (Saturation and Bit-crusher slots are distortions once read; one
		// that somehow isn't keeps the generic panel.)
		if !p.twin || p.effect != .Distortion do return false
		drv_distortion(p)
	case .Ring_Mod:
		if p.where_ != .Slot do return false
		drv_ring(p)
	case:
		return false
	}
	return true
}

// The output's spectrum, kept apart from the window's (its own falling peaks).
@(private = "file")
drv_spec: Spectrum_State

// The panel's slot's output spectrum now (nil: the synth's tab, off, or
// nothing heard yet).
@(private = "file")
drv_spectrum :: proc(p: ^Fx_Panel, on: bool) -> []f32 {
	if p.where_ != .Slot || !on do return nil
	x: [SPECTRUM_SIZE]f32
	if !pm.watch_read(&p.ctx.a.m.engine, x[:]) do return nil
	return spectrum_of(&drv_spec, x[:], drv_rate(p))
}

// The engine's sample rate.
@(private = "file")
drv_rate :: proc(p: ^Fx_Panel) -> f64 {
	sr := p.ctx.a.host.graph.settings.sample_rate
	return sr if sr > 0 else 48_000
}

// A Perform effect's intensity now (held: where it's pressed; else its
// own): it scales the mix (`pm.perf_effective`); -1 elsewhere.
@(private = "file")
drv_intensity :: proc(p: ^Fx_Panel) -> f32 {
	if p.where_ != .Slot || p.t.kind != .Perf do return -1
	m := &p.ctx.a.m
	live := m.engine.perf_live[p.t.index]
	return clamp(live if live >= 0 else m.project.perf_intensity[p.t.index], 0, 1)
}

// Where the picture goes (the cursor put there).
@(private = "file")
drv_plot_cursor :: proc() {
	im.SetCursorPos({0, CTL_PLOT_Y})
}

// --- Distortion ---------------------------------------------------------------------------------

// The distortion's parameter `f`.
@(private = "file")
drv_d :: proc(f: synth.Distortion_Field) -> fc.Param_Id { return synth.effect_param(.Distortion, f) }

// The Distortion: its curve, a sine through it and its filter over Main.
@(private = "file")
drv_distortion :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	m := &a.m
	// Every synth parameter's plain value, the distortion's as they play now.
	values: []f32
	on: bool
	color := ui.theme().accent
	if p.where_ == .Slot {
		values = make([]f32, synth.PARAM_SLOTS, context.temp_allocator)
		for spec in synth.PARAMS do if int(spec.id) < synth.PARAM_SLOTS do values[spec.id] = spec.default
		s := p.s
		for x in s.params[:s.count] do if int(x.id) < synth.PARAM_SLOTS do values[x.id] = x.value
		for id in synth_effect_ids(.Distortion) do if v, ok := pm.automated_value(m, fx_auto_target(p.t, id)); ok do values[id] = v
		on = s.on || p.t.kind == .Perf
	} else {
		sy := &m.project.pads[p.pad].synth
		values = make([]f32, len(sy.values), context.temp_allocator)
		copy(values, sy.values[:])
		for id in synth_effect_ids(.Distortion) do values[id] = synth_now(m, p.pad, id)
		on = values[effect_on(.Distortion)] > 0.5
		color = ui.rgb(m.project.pads[p.pad].color)
	}
	bpm := m.project.bpm if m.project.bpm > 0 else 120
	dp := synth.effect_chain_params(values, fx.CHAIN_ORDER, bpm).distortion
	fx_banks(p, "Main")
	drv_plot_cursor()
	drv_distortion_picture({p = dp, intensity = drv_intensity(p), on = on, sr = drv_rate(p), spectrum = drv_spectrum(p, on), color = color}, p.plot)
	filtered := dp.order != .None
	label :: proc(s: string, used: bool) -> string { return s if used else fmt.tprintf("(%s)", s) }
	drv_synth_knob(p, 0, 0, drv_d(.Drive), "Drive", drv_drive_text(dp.type, fx_value(p, drv_d(.Drive)), drv_rate(p), short = true))
	fx_knob(p, 0, 1, drv_d(.Type), "Type", DISTORTION_NAMES)
	fx_knob(p, 0, 2, drv_d(.Mix), "Mix")
	fx_knob(p, 0, 3, drv_d(.Filter_Order), "Filter", DISTORTION_FILTER_NAMES)
	fx_knob(p, 0, 4, drv_d(.Cutoff), label("Cutoff", filtered))
	fx_knob(p, 0, 5, drv_d(.Resonance), label("Resonance", filtered))
	drv_synth_knob(p, 0, 6, drv_d(.Blend), label("Blend", filtered), drv_blend_text(fx_value(p, drv_d(.Blend))))
}

// A distortion parameter `id` (the synth's: a twin slot's own, or the
// pad's synth's) on `bank`'s column `col`: as `fx_knob`'s (undo,
// automation; the synth's tab: its automation lane), but reading as
// `shown` says (Drive by its type: "+6.0 dB", "4.3 bits", "held 12
// samples"; Blend: "Low-pass", "Low 40% · Band").
@(private = "file")
drv_synth_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label, shown: string) {
	spec := synth.param_spec(id)
	if spec == nil do return
	tag := fmt.ctprintf("%s##fx%d", label, int(id)) // (fx_knob's: the same knob whichever draws it)
	if !ctl_knob(p.ctx, fx_index(p, bank, col), p.banks * 8, tag, p.plot) do return
	a := p.ctx.a
	v := fx_value(p, id)
	sv := fmt.ctprintf("%s", shown)
	if p.where_ == .Slot {
		knob_target(a, fx_auto_target(p.t, id))
		e := ui.knob(tag, &v, spec.min, spec.max, spec.default, "%.3f", shown_value = sv)
		knob_target(a, {})
		control_effect_param(a, p.t, i64(id), f64(clamp(v, spec.min, spec.max)), e.changed, e.ended)
		return
	}
	knob_target(a, sound_param_target(p.pad, id))
	e := ui.knob(tag, &v, spec.min, spec.max, spec.default, "%.3f", shown_value = sv)
	knob_target(a, {})
	control_param(a, {track = .Pad, index = i64(p.pad), device = .Sound, param = i64(id)}, f64(v), spec.name, e.changed, e.ended)
}

// --- Ring mod -----------------------------------------------------------------------------------

// A ring mod's parameter `id` as it plays now (automation playing: where
// it has it now).
@(private = "file")
drv_now :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> f32 {
	if v, ok := pm.automated_value(&p.ctx.a.m, fx_auto_target(p.t, id)); ok do return v
	return fx_value(p, id)
}

// A ring mod's parameter `id` on `bank`'s column `col`: as `fx_knob`'s
// (undo, automation), but its frequency turning in ratios (1 Hz to 5 kHz
// on one encoder) and both reading as they're set ("2.50 Hz", "1.20 kHz",
// "100 %").
@(private = "file")
drv_ring_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string) {
	info, ok := fx_param_info(p, id)
	if !ok do return
	tag := fmt.ctprintf("%s##drv%d", label, int(id))
	if !ctl_knob(p.ctx, fx_index(p, bank, col), p.banks * 8, tag, p.plot) do return
	a := p.ctx.a
	v := fx_value(p, id)
	shown := fmt.ctprintf("%s", drv_hz_text(v)) if info.unit == .Hertz else fmt.ctprintf("%.0f %%", v * 100)
	knob_target(a, fx_auto_target(p.t, id))
	e := ui.knob(tag, &v, f32(info.min), f32(info.max), f32(info.default), "%.2f", log_scale = info.unit == .Hertz, shown_value = shown)
	knob_target(a, {})
	control_effect_param(a, p.t, i64(id), clamp(f64(v), info.min, info.max), e.changed, e.ended)
}

// The Ring mod: a tone times its carrier, and the sidebands, over Main.
@(private = "file")
drv_ring :: proc(p: ^Fx_Panel) {
	on := p.s.on || p.t.kind == .Perf
	fx_banks(p, "Main")
	drv_plot_cursor()
	pic := Drv_Ring_Picture {
		hz = drv_now(p, dsp.RING_PARAM_HZ), mix = drv_now(p, dsp.RING_PARAM_MIX), intensity = drv_intensity(p),
		on = on, spectrum = drv_spectrum(p, on), color = ui.theme().accent,
	}
	drv_ring_picture(pic, p.plot)
	drv_ring_knob(p, 0, 0, dsp.RING_PARAM_HZ, "Frequency")
	drv_ring_knob(p, 0, 1, dsp.RING_PARAM_MIX, "Mix")
}
