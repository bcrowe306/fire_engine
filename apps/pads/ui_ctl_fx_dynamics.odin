// Dynamics: Compressor, Gate, Limiter on a controller's display
// (docs/design/push2-devices.md, docs/design/push2-fx-dynamics.md): each
// its picture (ui_fxpic_dynamics.odin) over its banks of knobs.
//
//	Compressor (the synth's three-band one; in a slot, Perform, or the
//	synth's Effects tab): Main (Bands, Attack, Release, Mix), Low, Band,
//	High (each band's Upper, Upper Ratio, Lower, Lower Ratio, Gain),
//	Sidechain (a pad's or a bus's slot: Source, Key HPF, Listen).
//	Gate: Main (Threshold, Range, Attack, Hold, Release, Hysteresis,
//	Ratio), Sidechain (as the compressor's).
//	Limiter: Main (Input, Ceiling, Release).
//
// The lower row is theirs and they have no choices of their own there: On
// is Mute + Device, Remove is Delete + Device (the synth's tab: its On).
package pads

import "core:fmt"
import "core:math"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:synth"

// The reduction history kept for the picture: a few seconds of it, sampled
// as the display draws, for the slot shown.
@(private = "file")
DYN_HISTORY :: 200 // (4 s at 50 a second)

@(private = "file")
Dyn_History :: struct {
	key:     pm.Fx_Target,
	gr, out: [DYN_HISTORY]f32, // a ring: `at` is the oldest
	at:      int,
	last:    time.Tick,
	set:     bool,
}

@(private = "file")
dyn_history: Dyn_History

// The history with now's reduction and output level put in (as many times
// as 20 ms steps have passed since the last), in order, oldest first.
@(private = "file")
dyn_history_push :: proc(t: pm.Fx_Target, gr, out: f32) -> (grs, outs: []f32) {
	h := &dyn_history
	if !h.set || h.key != t {
		h^ = {key = t, set = true, last = time.tick_now()}
		for k in 0 ..< DYN_HISTORY do h.gr[k], h.out[k] = 0, DYN_NONE
	}
	steps := int(time.duration_milliseconds(time.tick_since(h.last)) / 20)
	if steps > 0 {
		h.last = time.tick_now()
		for _ in 0 ..< min(steps, DYN_HISTORY) {
			h.gr[h.at], h.out[h.at] = gr, out
			h.at = (h.at + 1) % DYN_HISTORY
		}
	}
	grs = make([]f32, DYN_HISTORY, context.temp_allocator)
	outs = make([]f32, DYN_HISTORY, context.temp_allocator)
	for k in 0 ..< DYN_HISTORY {
		grs[k] = h.gr[(h.at + k) % DYN_HISTORY]
		outs[k] = h.out[(h.at + k) % DYN_HISTORY]
	}
	return
}

// Parameter `id`'s value now (automation playing: as it has it now): a
// slot's, or the synth's.
@(private = "file")
dyn_value :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> f32 {
	m := &p.ctx.a.m
	if p.where_ == .Synth do return synth_now(m, p.pad, id)
	if v, ok := pm.automated_value(m, fx_auto_target(p.t, id)); ok do return v
	if p.twin {
		spec := synth.param_spec(id)
		return pm.slot_value(p.s, id, spec.default if spec != nil else 0)
	}
	return fx_value(p, id)
}

// The slot's output level now (dB), from the watched slot's last frames
// (DYN_NONE: nothing heard, or not watched).
@(private = "file")
dyn_out_level :: proc(p: ^Fx_Panel) -> f32 {
	buf: [1024]f32
	if !pm.watch_read(&p.ctx.a.m.engine, buf[:]) do return DYN_NONE
	peak: f32 = 0
	for x in buf do peak = max(peak, abs(x))
	if peak < 1e-5 do return DYN_NONE
	return 20 * math.log10(peak)
}

// Whether the panel's slot has a sidechain (a pad's or a bus's compressor
// or gate: the synth's tab and Perform have none).
@(private = "file")
dyn_keyed :: proc(p: ^Fx_Panel) -> bool {
	return p.where_ == .Slot && pm.keyable(p.kind) && (p.t.kind == .Pad || p.t.kind == .Bus)
}

// What the slot listens to, as the picture says it ("" none: no sidechain).
@(private = "file")
dyn_key_name :: proc(p: ^Fx_Panel) -> string {
	if !dyn_keyed(p) do return ""
	pr := &p.ctx.a.m.project
	switch p.s.key.kind {
	case .None: return ""
	case .Pad:  return fmt.tprintf("Key: Pad %s", pm.pad_label(p.s.key.index))
	case .Bus:  return fmt.tprintf("Key: %s", pm.bus_index_name(pr, p.s.key.index))
	}
	return ""
}

// The Sidechain bank (`b`): what it listens to (itself, a pad, a bus it
// doesn't feed), the key's high-pass, Listen; the last two in brackets
// while it listens to itself (as the window shows them only when keyed).
@(private = "file")
dyn_sidechain :: proc(p: ^Fx_Panel, b: int) {
	ctx := p.ctx
	a := ctx.a
	pr := &a.m.project
	t, s := p.t, p.s
	total := p.banks * 8
	keys := make([dynamic]pm.Key_Source, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	append(&keys, pm.Key_Source{})
	append(&names, "Itself")
	for i in 0 ..< pm.PADS do if pm.pad_used(pr, i) && pm.key_allowed(pr, t, {.Pad, i}) {
		append(&keys, pm.Key_Source{.Pad, i})
		append(&names, fmt.tprintf("Pad %s", pm.pad_label(i)))
	}
	for k in 0 ..< pr.bus_count do if pm.key_allowed(pr, t, {.Bus, k}) {
		append(&keys, pm.Key_Source{.Bus, k})
		append(&names, pm.bus_index_name(pr, k))
	}
	cur := 0
	for k, i in keys do if k == s.key do cur = i
	if k, _ := ctl_choice(ctx, fx_index(p, b, 0), total, "Source##dynkey", names[:], cur, p.plot); k >= 0 {
		pa.effect_set_key(&a.api, slot_ref(t), pa.Key_Kind(keys[k].kind), i64(keys[k].index))
	}
	keyed := s.key.kind != .None
	hpf: cstring = "Key HPF##dynhpf" if keyed else "(Key HPF)##dynhpf"
	if ctl_knob(ctx, fx_index(p, b, 1), total, hpf, p.plot) {
		v := s.key_hpf
		shown := fmt.ctprintf("%.0f Hz", v) if v >= 1 else "Off"
		e := ui.knob(hpf, &v, 0, 2000, 0, "%.0f", shown_value = shown)
		if e.changed {
			pa.history_gesture_begin(&a.api)
			pa.effect_set_key_filter(&a.api, slot_ref(t), clamp(v, 0, 2000))
		}
		if e.ended do pa.history_gesture_end(&a.api)
	}
	listen: cstring = "Listen##dynlisten" if keyed else "(Listen)##dynlisten"
	if k, _ := ctl_choice(ctx, fx_index(p, b, 2), total, listen, OFF_ON, 1 if s.listen else 0, p.plot); k >= 0 {
		pa.effect_set_key_listen(&a.api, slot_ref(t), k == 1)
	}
}

// A Gate's or Limiter's parameter `id` on `bank`'s column `col`: as
// `fx_knob`'s (undo, automation), but its times and ratio turning in
// ratios (0.05 ms to 3 s on one encoder) and reading as they're set.
@(private = "file")
dyn_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string) {
	info, ok := fx_param_info(p, id)
	if !ok do return
	tag := fmt.ctprintf("%s##dyn%d", label, int(id))
	if !ctl_knob(p.ctx, fx_index(p, bank, col), p.banks * 8, tag, p.plot) do return
	a := p.ctx.a
	v := fx_value(p, id)
	shown: cstring
	#partial switch info.unit {
	case .Milliseconds: shown = fmt.ctprintf("%s", dyn_ms(v))
	case .Decibels:     shown = fmt.ctprintf("%.1f dB", v)
	case .Ratio:        shown = fmt.ctprintf("%.1f : 1" if v < 10 else "%.0f : 1", v)
	}
	knob_target(a, fx_auto_target(p.t, id))
	e := ui.knob(tag, &v, f32(info.min), f32(info.max), f32(info.default), "%.2f", log_scale = info.min > 0 && info.max / info.min >= 50, shown_value = shown)
	knob_target(a, {})
	control_effect_param(a, p.t, i64(id), clamp(f64(v), info.min, info.max), e.changed, e.ended)
}

// Where the picture goes on the display (its top left, on the screen),
// the cursor put there.
@(private = "file")
dyn_plot_pos :: proc() -> im.Vec2 {
	o := im.GetWindowPos()
	im.SetCursorPos({0, CTL_PLOT_Y})
	return {o.x, o.y + CTL_PLOT_Y}
}

// Whether the panel's effect is on (Perform's always are, while held).
@(private = "file")
dyn_on :: proc(p: ^Fx_Panel) -> bool {
	if p.where_ == .Synth do return pm.synth_value(&p.ctx.a.m, p.pad, effect_on(p.effect)) > 0.5
	return p.s.on || p.t.kind == .Perf
}

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_dynamics :: proc(p: ^Fx_Panel) -> bool {
	#partial switch p.kind {
	case .Compressor: dyn_compressor(p)
	case .Gate:       dyn_gate(p)
	case .Limiter:    dyn_limiter(p)
	case:             return false
	}
	return true
}

// The Compressor (the synth's): its three bands' curves and levels over
// Main, Low, Band, High (and Sidechain).
@(private = "file")
dyn_compressor :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	m := &a.m
	c :: proc(f: synth.Compressor_Field) -> fc.Param_Id { return synth.effect_param(.Compressor, f) }
	keyed := dyn_keyed(p)
	if keyed do fx_banks(p, "Main", "Low", "Band", "High", "Sidechain")
	else do fx_banks(p, "Main", "Low", "Band", "High")
	// The picture.
	pic := Dyn_Comp_Picture{on = dyn_on(p), focus = -1, key = dyn_key_name(p)}
	pic.params.bands = fx.Compressor_Bands(clamp(int(dyn_value(p, c(.Bands)) + 0.5), 0, len(fx.Compressor_Bands) - 1))
	pic.params.attack, pic.params.release, pic.params.mix = dyn_value(p, c(.Attack)), dyn_value(p, c(.Release)), dyn_value(p, c(.Mix))
	for b in 0 ..< 3 {
		at := int(synth.Compressor_Field.Low_Upper) + b * 5
		f :: proc(at, k: int) -> fc.Param_Id { return synth.effect_param(.Compressor, synth.Compressor_Field(at + k)) }
		pic.params.band[b] = {
			upper_db = dyn_value(p, f(at, 0)), lower_db = dyn_value(p, f(at, 1)),
			upper_ratio = dyn_value(p, f(at, 2)), lower_ratio = dyn_value(p, f(at, 3)), gain_db = dyn_value(p, f(at, 4)),
		}
	}
	page := a.ctl.page
	if page >= 1 && page <= 3 do pic.focus = page - 1
	chain := pm.synth_chain(&m.engine, p.pad) if p.where_ == .Synth else pm.slot_chain(&m.engine, p.t)
	for b in 0 ..< 3 do for k in 0 ..< 2 {
		pic.levels[b][k] = DYN_NONE
		if chain != nil && pic.on {
			x := chain.compressor.levels[b][k]
			if x > 1e-10 do pic.levels[b][k] = 10 * math.log10(x)
		}
	}
	draw_dyn_compressor(dyn_plot_pos(), p.plot, pic)
	// Main.
	fx_knob(p, 0, 0, c(.Bands), "Bands", COMPRESSOR_BAND_NAMES)
	fx_knob(p, 0, 1, c(.Attack), "Attack")
	fx_knob(p, 0, 2, c(.Release), "Release")
	fx_knob(p, 0, 3, c(.Mix), "Mix")
	// Each band: where it starts pressing down and by how much, where it
	// starts lifting and by how much, its gain.
	for b in 0 ..< 3 {
		at := int(synth.Compressor_Field.Low_Upper) + b * 5
		f :: proc(at, k: int) -> fc.Param_Id { return synth.effect_param(.Compressor, synth.Compressor_Field(at + k)) }
		used := dyn_band_used(pic.params.bands, b)
		label :: proc(s: string, used: bool) -> string { return s if used else fmt.tprintf("(%s)", s) }
		fx_knob(p, 1 + b, 0, f(at, 0), label("Upper", used))
		fx_knob(p, 1 + b, 1, f(at, 2), label("Upper Ratio", used))
		fx_knob(p, 1 + b, 2, f(at, 1), label("Lower", used))
		fx_knob(p, 1 + b, 3, f(at, 3), label("Lower Ratio", used))
		fx_knob(p, 1 + b, 4, f(at, 4), label("Gain", used))
	}
	if keyed do dyn_sidechain(p, 4)
}

// The Gate: its curve, its reduction now and its envelope over Main (and
// Sidechain).
@(private = "file")
dyn_gate :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	keyed := dyn_keyed(p)
	if keyed do fx_banks(p, "Main", "Sidechain")
	else do fx_banks(p, "Main")
	pic := Dyn_Gate_Picture {
		threshold = dyn_value(p, dsp.GATE_PARAM_THRESHOLD_DB), range_db = dyn_value(p, dsp.GATE_PARAM_RANGE_DB),
		ratio = dyn_value(p, dsp.GATE_PARAM_RATIO), hysteresis = dyn_value(p, dsp.GATE_PARAM_HYSTERESIS_DB),
		attack = dyn_value(p, dsp.GATE_PARAM_ATTACK_MS), hold = dyn_value(p, dsp.GATE_PARAM_HOLD_MS), release = dyn_value(p, dsp.GATE_PARAM_RELEASE_MS),
		on = dyn_on(p), key = dyn_key_name(p), level_db = DYN_NONE,
	}
	if gr, ok := pm.slot_reduction(&a.m.engine, p.t); ok && pic.on {
		pic.live, pic.reduction = true, abs(f32(gr))
		// (Its input: what comes out and what it took off; keyed, what it hears isn't that.)
		if out := dyn_out_level(p); out > DYN_NONE && !(keyed && p.s.key.kind != .None) do pic.level_db = out + pic.reduction
	}
	draw_dyn_gate(dyn_plot_pos(), p.plot, pic)
	dyn_knob(p, 0, 0, dsp.GATE_PARAM_THRESHOLD_DB, "Threshold")
	dyn_knob(p, 0, 1, dsp.GATE_PARAM_RANGE_DB, "Range")
	dyn_knob(p, 0, 2, dsp.GATE_PARAM_ATTACK_MS, "Attack")
	dyn_knob(p, 0, 3, dsp.GATE_PARAM_HOLD_MS, "Hold")
	dyn_knob(p, 0, 4, dsp.GATE_PARAM_RELEASE_MS, "Release")
	dyn_knob(p, 0, 5, dsp.GATE_PARAM_HYSTERESIS_DB, "Hysteresis")
	dyn_knob(p, 0, 6, dsp.GATE_PARAM_RATIO, "Ratio")
	if keyed do dyn_sidechain(p, 1)
}

// The Limiter: its curve, its reduction now and over the last seconds, on
// one bank.
@(private = "file")
dyn_limiter :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	fx_banks(p, "Main")
	pic := Dyn_Limiter_Picture {
		ceiling = dyn_value(p, dsp.LIMITER_PARAM_CEILING_DB), input = dyn_value(p, dsp.LIMITER_PARAM_INPUT_DB), release = dyn_value(p, dsp.LIMITER_PARAM_RELEASE_MS),
		on = dyn_on(p), level_db = DYN_NONE,
	}
	out := DYN_NONE
	if gr, ok := pm.slot_reduction(&a.m.engine, p.t); ok && pic.on {
		pic.live, pic.reduction = true, abs(f32(gr))
		out = dyn_out_level(p)
		if out > DYN_NONE do pic.level_db = out + pic.reduction - pic.input
	}
	pic.history, pic.outs = dyn_history_push(p.t, pic.reduction, out)
	draw_dyn_limiter(dyn_plot_pos(), p.plot, pic)
	dyn_knob(p, 0, 0, dsp.LIMITER_PARAM_INPUT_DB, "Input")
	dyn_knob(p, 0, 1, dsp.LIMITER_PARAM_CEILING_DB, "Ceiling")
	dyn_knob(p, 0, 2, dsp.LIMITER_PARAM_RELEASE_MS, "Release")
}
