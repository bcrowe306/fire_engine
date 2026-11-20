// The devices' panels on a controller's display (Push 2), family by family
// (docs/design/push2-devices.md): what a panel is given (`Fx_Panel`), its
// knobs and choices whichever device it is (an effect slot, the synth's
// Effects tab, a Perform effect, the pad's EQ, its MIDI effects, a
// plug-in), and the dispatch to each family's file (ui_ctl_fx_*.odin). A
// family not built yet returns false: the generic panel (every parameter,
// eight a bank) draws instead.
package pads

import "core:fmt"
import "core:math"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:clap"
import fc "fire:core"
import "fire:fx"
import "fire:synth"

// Where a panel's device is.
Fx_Where :: enum {
	Slot,  // an effect slot (a pad's, a bus's, Perform's: `t`)
	Synth, // the selected pad's synth, its Effects tab (`effect`)
	Pad_Eq, // the pad's own EQ (`pad`)
	Midi,  // the pad's MIDI effects (`pad`)
	Plugin_Instrument, // a plug-in as the pad's instrument (`t`)
}

// What a family's panel is given. Its knobs go by bank and column
// (`fx_knob`, `fx_choice`): a bank holds at most 7 of the device's own,
// since column 0 of every bank can be the panel's lead (`lead`: Perform's
// Intensity, the synth tab's effect picker); with no lead, the device's
// start at column 0 all the same and column 7 stays free. Lower-row
// buttons 0..6 are the panel's; 7 is the synth tab's On.
Fx_Panel :: struct {
	ctx:    ^View_Ctx,
	where_: Fx_Where,
	kind:   pm.Effect_Kind, // the effect (Synth: the slot kind that is its twin; None for the pad's EQ, MIDI)
	t:      pm.Fx_Target,   // Slot, Plugin_Instrument
	s:      pm.Effect_Slot, // Slot: its settings
	effect: fx.Effect,      // Synth, or a slot holding a synth twin: the synth's effect
	twin:   bool,           // its parameters are the synth's (`synth_effect_ids(effect)`): Synth, or a twin slot
	pad:    int,            // Synth, Pad_Eq, Midi: the pad
	plugin: ^clap.Plugin,   // Slot (a plug-in), Plugin_Instrument
	plot:   im.Vec2,        // the picture's size (the knob row under it, the status line over it)
	full:   im.Vec2,        // the whole view
	lead:   int,            // 1: column 0 of each bank is the panel's (Intensity, the synth's picker); else 0
	banks:  int,            // how many banks the panel said it has (`fx_banks`)
}

// The knob index of `bank`'s column `col` (the device's own, after the lead).
@(private)
fx_index :: proc(p: ^Fx_Panel, bank, col: int) -> int {
	return bank * 8 + p.lead + col
}

// Names the panel's banks (◀ ▶ page them; the strip names them), and puts
// the lead on each (Intensity on a Perform effect, the synth tab's picker
// and On). Call before the knobs.
fx_banks :: proc(p: ^Fx_Panel, names: ..string) {
	p.banks = max(len(names), 1)
	ctx := p.ctx
	for name, b in names do if b < len(ctx.banks) do ctx.banks[b] = name
	ctx.pages = max(ctx.pages, p.banks)
	total := p.banks * 8
	if p.lead == 0 do return
	a := ctx.a
	m := &a.m
	for b in 0 ..< p.banks {
		switch {
		case p.where_ == .Slot && p.t.kind == .Perf:
			label := fmt.ctprintf("Intensity##fxi%d", b)
			if !ctl_knob(ctx, b * 8, total, label, p.plot) do continue
			x := m.project.perf_intensity[p.t.index]
			ke := ui.knob(label, &x, 0, 1, 1, "%.2f")
			if ke.changed {
				pa.history_gesture_begin(&a.api)
				pa.effect_set_intensity(&a.api, i64(p.t.index), clamp(x, 0, 1))
			}
			if ke.ended do pa.history_gesture_end(&a.api)
		case p.where_ == .Synth:
			sy := m.project.pads[p.pad].synth
			order := make([dynamic]string, context.temp_allocator)
			at := 0
			for x, k in sy.fx_order {
				xon := pm.synth_value(m, p.pad, effect_on(x)) > 0.5
				append(&order, fmt.tprintf("%d %s%s", k + 1, synth.EFFECT_NAMES[x], "" if xon else " (off)"))
				if x == p.effect do at = k
			}
			if k, _ := ctl_choice(ctx, b * 8, total, fmt.ctprintf("Effect##fxe%d", b), order[:], at, p.plot); k >= 0 do a.synth_ui.effect = sy.fx_order[k]
		}
	}
	// The synth tab's On: lower-row button 7.
	if p.where_ == .Synth {
		on := pm.synth_value(m, p.pad, effect_on(p.effect)) > 0.5
		if pr, _ := ctl_button(ctx, 7, "On", on, p.full); pr {
			host_set(a, effect_on(p.effect), 0 if on else 1, "Effect On" if !on else "Effect Off")
			pa.history_gesture_end(&a.api)
		}
	}
}

// Parameter `id`'s plain value (a slot's, or the synth's: the panel's own).
fx_value :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> f32 {
	if p.twin {
		a := p.ctx.a
		host := a.param_host
		if p.where_ == .Slot do a.param_host = {slot = true, t = p.t} // (a twin slot: its own values, not the pad's synth)
		defer a.param_host = host
		return host_value(a, id)
	}
	switch p.where_ {
	case .Slot, .Plugin_Instrument:
		v := pm.slot_value(p.s, id, max(f32))
		if v != max(f32) do return v
		if info, ok := fx_param_info(p, id); ok {
			if p.plugin != nil do if x, ok2 := clap.plugin_param_value(p.plugin, id); ok2 do return f32(x)
			return f32(info.default)
		}
		return 0
	case .Synth:
		return host_value(p.ctx.a, id)
	case .Pad_Eq, .Midi:
	}
	return 0
}

// Parameter `id`'s description (a slot's effect's or plug-in's).
fx_param_info :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> (fc.Param_Info, bool) {
	for info in pm.target_params(&p.ctx.a.m.engine, p.t) do if info.id == id do return info, true
	return {}, false
}

// Parameter `id` on `bank`'s column `col`, labelled `label`: a knob (undo,
// automation and modulation as the window's knobs), or a choice when it is
// stepped (Off and On, or its steps; `names`: the steps' names, `short`
// theirs in the box where they're too long for it). `shown`: a knob's value
// as read instead of its number (a plug-in's own text).
fx_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string, names: []string = nil, short: []string = nil, shown: cstring = nil) {
	ctx := p.ctx
	a := ctx.a
	n := fx_index(p, bank, col)
	total := p.banks * 8
	tag := fmt.ctprintf("%s##fx%d", label, int(id))
	if p.twin || p.where_ == .Synth {
		host := a.param_host
		if p.where_ == .Slot do a.param_host = {slot = true, t = p.t}
		defer a.param_host = host
		if names != nil {
			spec := synth.param_spec(id)
			lo: f32 = spec.min if spec != nil else 0
			if k, ended := ctl_choice(ctx, n, total, tag, names, int(host_value(a, id) + 0.5) - int(lo), p.plot, short); k >= 0 || ended {
				if k >= 0 do host_set(a, id, lo + f32(k), label)
				pa.history_gesture_end(&a.api)
			}
			return
		}
		ctl_synth_param(ctx, n, total, tag, id, p.plot)
		return
	}
	info, ok := fx_param_info(p, id)
	if !ok do return
	if .Stepped in info.flags && info.max - info.min <= 64 {
		steps := names
		if steps == nil {
			list := make([dynamic]string, context.temp_allocator)
			if info.min == 0 && info.max == 1 do append(&list, ..OFF_ON)
			else do for x := int(info.min); x <= int(info.max); x += 1 do append(&list, fmt.tprintf("%d", x))
			steps = list[:]
		}
		if j, _ := ctl_choice(ctx, n, total, tag, steps, int(fx_value(p, id)) - int(info.min), p.plot, short); j >= 0 {
			control_effect_param(a, p.t, i64(id), info.min + f64(j), true, true)
		}
		return
	}
	info.name = label
	if ctl_knob(ctx, n, total, tag, p.plot) do param_knob(a, p.t, p.s, info, p.plugin, as_knob = true, shown = shown)
}

// Parameter `id` of the panel's device as an automation target: the
// synth's tab's, the pad's sound's; a slot's, its insert's ({} for
// Perform's effects, which are played, not automated).
fx_target :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> pm.Auto_Target {
	if p.where_ == .Synth do return sound_param_target(p.pad, id)
	return fx_auto_target(p.t, id)
}

// How a knob shows a parameter's plain value: as `value / scale + offset`
// (a time whose parameter is a rate, turned the other way) over `lo..hi`,
// in ratios with `log_scale`.
Knob_Map :: struct {
	lo, hi:        f32,
	scale, offset: f32,
	log_scale:     bool,
}

// Where plain value `v` is along a knob mapped by `km` (0..1).
knob_map_frac :: proc(km: Knob_Map, v: f32) -> f32 {
	x := v / (km.scale if km.scale != 0 else 1) + km.offset
	if km.hi <= km.lo do return 0
	if km.log_scale && km.lo > 0 do return clamp(math.ln(clamp(x, km.lo, km.hi) / km.lo) / math.ln(km.hi / km.lo), 0, 1)
	return clamp((x - km.lo) / (km.hi - km.lo), 0, 1)
}

// A knob of a panel's own drawing (its range, reading or turning its own)
// for parameter `id`, at the cursor `ctl_knob` put: `ui.knob` with what
// moves the parameter besides the encoder shown on it as on `fx_knob`'s:
// automation playing (its live mark) and, on the synth's tab, its
// modulation routes (`ctl_route_marks`). `v` is in the knob's units
// (`km`: its plain value / scale + offset).
fx_ring_knob :: proc(p: ^Fx_Panel, tag: cstring, id: fc.Param_Id, v: ^f32, km: Knob_Map, default: f32, format: cstring = "%.2f", shown: cstring = nil, step: f32 = 0) -> ui.Edit {
	a := p.ctx.a
	pos := im.GetCursorScreenPos()
	col := ui.knob_input.drawn if ui.knob_input != nil else -1
	knob_target(a, fx_target(p, id), km.scale if km.scale != 0 else 1, km.offset)
	e := ui.knob(tag, v, km.lo, km.hi, default, format, log_scale = km.log_scale, shown_value = shown, step = step)
	knob_target(a, {})
	if p.where_ == .Synth do ctl_route_marks(a, p.pad, id, pos, col, km)
	return e
}

// Sets parameter `id` of the panel's device to plain value `v` from a
// knob's edit `e` (`name`: the undo step's, on the synth's tab).
fx_ring_set :: proc(p: ^Fx_Panel, id: fc.Param_Id, v: f64, name: string, e: ui.Edit) {
	a := p.ctx.a
	if p.where_ == .Synth {
		control_param(a, {track = .Pad, index = i64(p.pad), device = .Sound, param = i64(id)}, v, name, e.changed, e.ended)
		return
	}
	control_effect_param(a, p.t, i64(id), v, e.changed, e.ended)
}

// A choice of the panel's own (not a parameter: a view, a band shown) on
// `bank`'s column `col`: the one chosen (-1: none).
fx_choice :: proc(p: ^Fx_Panel, bank, col: int, label: string, names: []string, current: int) -> int {
	k, _ := ctl_choice(p.ctx, fx_index(p, bank, col), p.banks * 8, fmt.ctprintf("%s##fxc%d", label, fx_index(p, bank, col)), names, current, p.plot)
	return k
}

// The devices' families (docs/design/push2-devices.md).
Fx_Family :: enum {
	None,
	Dynamics,   // Compressor, Gate, Limiter
	Modulation, // Chorus, Flanger, Phaser
	Space,      // Delay, Reverb, Comb
	Drive,      // Distortion, Ring mod, Saturation, Bit-crusher
	Rhythm,     // Cutter, Stutter, Pitch shift
	Tone,       // EQ, Filter, Low-, High-, Band-pass, the pad's EQ
	Midi_Plugin, // the pad's MIDI effects, plug-ins
}

// Which family draws a panel.
fx_family :: proc(p: ^Fx_Panel) -> Fx_Family {
	switch p.where_ {
	case .Pad_Eq:                  return .Tone
	case .Midi, .Plugin_Instrument: return .Midi_Plugin
	case .Slot, .Synth:
	}
	#partial switch p.kind {
	case .Compressor, .Gate, .Limiter:                   return .Dynamics
	case .Chorus, .Flanger, .Phaser:                     return .Modulation
	case .Delay, .Reverb, .Comb:                         return .Space
	case .Distortion, .Ring_Mod, .Saturation, .Bitcrush: return .Drive
	case .Cutter, .Stutter, .Pitch:                      return .Rhythm
	case .Eq, .Filter, .Low_Pass, .High_Pass, .Band_Pass: return .Tone
	case .Plugin:                                        return .Midi_Plugin
	}
	return .None
}

// The slot kind whose twin is the synth's effect `e` (None: none).
fx_kind_of_synth :: proc(e: fx.Effect) -> pm.Effect_Kind {
	for k in pm.Effect_Kind do if x, ok := pm.synth_twin(k); ok && x == e do return k
	return .None
}

// Draws panel `p` with its family's own drawing: whether it did (false: the
// caller draws the generic panel). Its drawing time is kept for the probe
// (`Ctl_State.fx_draw_us`).
fx_panel :: proc(p: ^Fx_Panel) -> bool {
	start := time.tick_now()
	drawn := false
	switch fx_family(p) {
	case .None:
	case .Dynamics:    drawn = fx_panel_dynamics(p)
	case .Modulation:  drawn = fx_panel_modulation(p)
	case .Space:       drawn = fx_panel_space(p)
	case .Drive:       drawn = fx_panel_drive(p)
	case .Rhythm:      drawn = fx_panel_rhythm(p)
	case .Tone:        drawn = fx_panel_tone(p)
	case .Midi_Plugin: drawn = fx_panel_midi_plugin(p)
	}
	if drawn {
		us := f64(time.tick_since(start)) / 1e3
		c := &p.ctx.a.ctl
		c.fx_draw_us = us
		c.fx_draw_max_us = max(c.fx_draw_max_us, us)
	}
	return drawn
}

// The modulation routes into synth parameter `id` of pad `pad`, marked on
// the value bar of the knob drawn at `pos` (a controller's: `knob_bar_rect`)
// as the window's knobs ring them: each route a line under the bar in its
// source's colour, from the value as far as its amount takes it (either
// way when bipolar), and where the newest note's envelope or LFO has it
// now a dot on it. `col`: the knob's encoder (its `Knob_Shown.marks`).
ctl_route_marks :: proc(a: ^App, pad: int, id: fc.Param_Id, pos: im.Vec2, col: int, km: Knob_Map) {
	m := &a.m
	routes := pm.synth_routes_to(m, pad, id)
	spec := synth.param_spec(id)
	if len(routes) == 0 || spec == nil || spec.max <= spec.min || ui.knob_input == nil do return
	t := ui.theme()
	dl := im.GetWindowDrawList()
	r0, r1 := ui.knob_bar_rect(pos)
	span := spec.max - spec.min
	v := pm.synth_value(m, pad, id)
	f0 := (v - spec.min) / span
	x :: proc(km: Knob_Map, spec: ^synth.Param_Spec, r0, r1: im.Vec2, f: f32) -> f32 {
		return r0.x + (r1.x - r0.x) * knob_map_frac(km, spec.min + clamp(f, 0, 1) * (spec.max - spec.min))
	}
	live, playing := pm.synth_live(&m.engine, pad)
	sy := &m.project.pads[pad].synth
	for k, n in routes {
		rt := sy.routes[k]
		c := mod_color(rt.source)
		if rt.bypass do c = ui.with_alpha(c, 0.3)
		lo := f0 - (rt.amount if rt.bipolar else 0)
		hi := f0 + rt.amount
		y := r1.y + 3 + f32(n) * 3
		xa, xb := x(km, spec, r0, r1, min(lo, hi)), x(km, spec, r0, r1, max(lo, hi))
		im.DrawList_AddLine(dl, {xa, y}, {max(xb, xa + 2), y}, ui.col(c), 2)
		// Where the newest note has it (envelopes and LFOs from the voice).
		if playing && live.sounding {
			sv: f32 = -1
			#partial switch rt.source {
			case .Env_1 ..= .Env_6: sv = live.envs[int(rt.source) - int(synth.Mod_Source.Env_1)]
			case .Lfo_1 ..= .Lfo_8: sv = live.lfos[int(rt.source) - int(synth.Mod_Source.Lfo_1)]
			}
			if sv >= 0 {
				d := sv * 2 - 1 if rt.bipolar else sv
				im.DrawList_AddCircleFilled(dl, {x(km, spec, r0, r1, f0 + d * rt.amount), y}, 2.5, ui.col(t.text), 8)
			}
		}
	}
	if col >= 0 && col < len(ui.knob_input.shown) do ui.knob_input.shown[col].marks = len(routes)
}
