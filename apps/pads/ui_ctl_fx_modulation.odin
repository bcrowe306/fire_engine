// Modulation: Chorus, Flanger, Phaser on a controller's display
// (docs/design/push2-devices.md, docs/design/push2-fx-modulation.md). All
// three are the synth's effects (`pm.synth_twin`): an effect slot, a
// Perform effect and the synth's Effects tab hold the same parameters, so
// one panel each serves every place. The pictures (ui_fxpic_modulation.odin)
// draw from plain values; here they're given the settings as they play now
// (automation included) and the sweep's phase.
package pads

import "core:fmt"
import "core:time"

import "app:ui"
import pm "model"
import fc "fire:core"
import "fire:fx"
import "fire:synth"

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_modulation :: proc(p: ^Fx_Panel) -> bool {
	if !p.twin do return false // (its parameters are always the synth's: an old slot's are converted when it loads)
	now := mod_now(p)
	switch p.effect {
	case .Chorus:  mod_chorus_panel(p, &now)
	case .Flanger: mod_flanger_panel(p, &now)
	case .Phaser:  mod_phaser_panel(p, &now)
	case .Compressor, .Delay, .Distortion, .Eq, .Filter, .Reverb:
		return false
	}
	return true
}

// A modulation effect's settings as it plays now, and how it's drawn.
@(private)
Mod_Now :: struct {
	values: []f32,           // every synth parameter's plain value (the effect's as they play now)
	cp:     fx.Chain_Params, // the effect's settings, from them
	chain:  ^fx.Chain,       // the effect as it runs (its sweep's phase), or nil
	on:     bool,
	color:  ui.Color,
}

// Panel `p`'s effect's settings now: a slot's over the defaults, or the
// pad's synth's, automation playing as it has them now.
@(private)
mod_now :: proc(p: ^Fx_Panel) -> (n: Mod_Now) {
	a := p.ctx.a
	m := &a.m
	bpm := m.project.bpm if m.project.bpm > 0 else 120
	ids := synth_effect_ids(p.effect)
	if p.where_ == .Slot {
		n.values = make([]f32, synth.PARAM_SLOTS, context.temp_allocator)
		for spec in synth.PARAMS do n.values[spec.id] = spec.default
		s := p.s
		for x in s.params[:s.count] do if int(x.id) < synth.PARAM_SLOTS do n.values[x.id] = x.value
		for id in ids do if v, ok := pm.automated_value(m, fx_auto_target(p.t, id)); ok do n.values[id] = v
		n.on = s.on || p.t.kind == .Perf
		n.chain = pm.slot_chain(&m.engine, p.t)
		n.color = ui.theme().accent
	} else {
		sy := &m.project.pads[p.pad].synth
		n.values = make([]f32, len(sy.values), context.temp_allocator)
		copy(n.values, sy.values[:])
		for id in ids do n.values[id] = synth_now(m, p.pad, id)
		n.on = n.values[effect_on(p.effect)] > 0.5
		n.chain = pm.synth_chain(&m.engine, p.pad)
		n.color = ui.rgb(m.project.pads[p.pad].color)
	}
	n.cp = synth.effect_chain_params(n.values, fx.CHAIN_ORDER, bpm)
	if !n.on do n.color = ui.mix(ui.PLOT_BG, n.color, 0.45)
	return
}

// The sweeps' phases as last drawn, to tell an effect that runs (its
// chain's phase moves) from one that doesn't (the picture's clock moves it).
@(private = "file")
mod_anim: struct {
	last:  [3]f32,
	still: [3]int,
	start: time.Tick,
}

// Effect `k`'s (0 chorus, 1 flanger, 2 phaser) sweep's phase now (0..1):
// its chain's while that moves, else the clock's at `hz`, so the picture
// shows the sweep whether or not sound goes through it.
@(private)
mod_phase :: proc(k: int, chain: ^fx.Chain, hz: f32) -> f32 {
	A := &mod_anim
	if A.start == {} do A.start = time.tick_now()
	if chain != nil {
		ph: f32
		switch k {
		case 0: ph = chain.chorus.phase
		case 1: ph = chain.flanger.phase
		case:   ph = chain.phaser.phase
		}
		if ph != A.last[k] do A.still[k] = 0
		else do A.still[k] += 1
		A.last[k] = ph
		if A.still[k] < 4 do return ph
	}
	s := f32(time.duration_seconds(time.tick_since(A.start)))
	x := s * hz
	return x - f32(int(x))
}

// A synced rate's knob: its frequency when free, else its tempo division.
@(private)
mod_rate_id :: proc(n: ^Mod_Now, sync, hz, tempo: fc.Param_Id) -> fc.Param_Id {
	return hz if int(n.values[sync] + 0.5) == 0 else tempo
}

// A synced rate as read: "0.13 Hz", "1/4", "1/8 D".
@(private)
mod_rate_text :: proc(n: ^Mod_Now, sync, tempo: fc.Param_Id, hz: f32) -> string {
	s := int(n.values[sync] + 0.5)
	if s == 0 do return mod_hz_text(hz)
	name := TEMPO_NAMES[clamp(int(n.values[tempo] + 0.5), 0, len(TEMPO_NAMES) - 1)]
	suffix := [4]string{"", "", " D", " T"}
	return fmt.tprintf("%s%s", name, suffix[clamp(s, 0, 3)])
}

// Chorus: Main (Rate, Depth, Voices, Feedback, Mix, Sync) and Delays
// (Delay 1, Delay 2, and the feedback's band: Cutoff, Spread).
@(private)
mod_chorus_panel :: proc(p: ^Fx_Panel, n: ^Mod_Now) {
	c :: proc(f: synth.Chorus_Field) -> fc.Param_Id { return synth.effect_param(.Chorus, f) }
	cp := n.cp.chorus
	phase := mod_phase(0, n.chain, cp.hz)
	mod_chorus_picture(cp, phase, mod_rate_text(n, c(.Sync), c(.Tempo), cp.hz), n.on, p.plot, n.color)
	fx_banks(p, "Main", "Delays")
	fx_knob(p, 0, 0, mod_rate_id(n, c(.Sync), c(.Hz), c(.Tempo)), "Rate")
	fx_knob(p, 0, 1, c(.Depth), "Depth")
	fx_knob(p, 0, 2, c(.Voices), "Voices", MOD_VOICE_NAMES)
	fx_knob(p, 0, 3, c(.Feedback), "Feedback")
	fx_knob(p, 0, 4, c(.Wet), "Mix")
	fx_knob(p, 0, 5, c(.Sync), "Sync")
	fx_knob(p, 1, 0, c(.Delay_1), "Delay 1")
	fx_knob(p, 1, 1, c(.Delay_2), "Delay 2")
	fx_knob(p, 1, 2, c(.Cutoff), "Cutoff")
	fx_knob(p, 1, 3, c(.Spread), "Spread")
}

// Flanger: one bank (Rate, Depth, Center, Feedback, Mix, Sync, Offset).
@(private)
mod_flanger_panel :: proc(p: ^Fx_Panel, n: ^Mod_Now) {
	f :: proc(x: synth.Flanger_Field) -> fc.Param_Id { return synth.effect_param(.Flanger, x) }
	fp := n.cp.flanger
	phase := mod_phase(1, n.chain, fp.hz)
	mod_flanger_picture(fp, phase, mod_rate_text(n, f(.Sync), f(.Tempo), fp.hz), n.on, p.plot, n.color)
	fx_banks(p, "Main")
	fx_knob(p, 0, 0, mod_rate_id(n, f(.Sync), f(.Hz), f(.Tempo)), "Rate")
	fx_knob(p, 0, 1, f(.Depth), "Depth")
	fx_knob(p, 0, 2, f(.Center), "Center")
	fx_knob(p, 0, 3, f(.Feedback), "Feedback")
	fx_knob(p, 0, 4, f(.Wet), "Mix")
	fx_knob(p, 0, 5, f(.Sync), "Sync")
	fx_knob(p, 0, 6, f(.Offset), "Offset")
}

// Phaser: Main (Rate, Depth, Center, Feedback, Blend, Mix) and LFO (Sync,
// Rate again beside it, Offset: the sides apart).
@(private)
mod_phaser_panel :: proc(p: ^Fx_Panel, n: ^Mod_Now) {
	f :: proc(x: synth.Phaser_Field) -> fc.Param_Id { return synth.effect_param(.Phaser, x) }
	pp := n.cp.phaser
	sr := p.ctx.a.host.graph.settings.sample_rate if p.ctx.a.host.graph.settings.sample_rate > 0 else 48_000
	phase := mod_phase(2, n.chain, pp.hz)
	mod_phaser_picture(pp, phase, mod_rate_text(n, f(.Sync), f(.Tempo), pp.hz), n.on, f32(sr), p.plot, n.color)
	fx_banks(p, "Main", "LFO")
	rate := mod_rate_id(n, f(.Sync), f(.Hz), f(.Tempo))
	fx_knob(p, 0, 0, rate, "Rate")
	fx_knob(p, 0, 1, f(.Depth), "Depth")
	fx_knob(p, 0, 2, f(.Center), "Center")
	fx_knob(p, 0, 3, f(.Feedback), "Feedback")
	fx_knob(p, 0, 4, f(.Blend), "Blend")
	fx_knob(p, 0, 5, f(.Wet), "Mix")
	fx_knob(p, 1, 0, f(.Sync), "Sync")
	fx_knob(p, 1, 1, rate, "Rate")
	fx_knob(p, 1, 2, f(.Offset), "Offset")
}

// The chorus's voices (each a pair of delays a side), as its dropdown names them.
@(private)
MOD_VOICE_NAMES := []string{"1", "2", "3", "4"}
