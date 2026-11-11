package test_synth

import "core:testing"

import "fire:core"
import "fire:fx"
import "fire:synth"
import kit "fire:testkit"

// The reverb on: a tail rings after the note's release. Sent Direct, the
// oscillator goes around the effects: no tail.
@(test)
effects_and_direct :: proc(t: ^testing.T) {
	tail :: proc(t: ^testing.T, direct: bool) -> f64 {
		r := rig_synth()
		defer rig_synth_free(r)
		set_param(r, synth.effect_param(.Reverb, synth.Reverb_Field.On), 1)
		set_param(r, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.5)
		set_param(r, synth.effect_param(.Reverb, synth.Reverb_Field.Decay), 1) // 2 s
		if direct do set_param(r, synth.osc_param(1, .Destination), f32(synth.Destination.Direct))
		out := play_synth(t, r, {on(0, 57), off(12_000, 57)}, 48_000)
		return kit.rms(out.channels[0][36_000:]) // half a second after the release ends
	}
	wet, dry := tail(t, false), tail(t, true)
	testing.expectf(t, wet > 1e-3, "a reverb tail (%v)", wet)
	testing.expectf(t, dry < 1e-6, "none for a source sent Direct (%v)", dry)
}

// Effects in any blocks: the same (chorus, delay, flanger, reverb on).
@(test)
effects_in_any_blocks :: proc(t: ^testing.T) {
	events := []kit.Timed_Event{on(100, 60), on(5_000, 64, 0.6), off(9_000, 60), off(14_000, 64)}
	ref: []f32
	for pattern, i in kit.standard_block_patterns(512) {
		r := rig_synth()
		for e in ([]fx.Effect{.Chorus, .Delay, .Flanger, .Reverb}) do set_param(r, synth.effect_param(e, synth.Chorus_Field.On), 1)
		out := play_synth(t, r, events, 24_000, pattern)
		if i == 0 do ref = out.channels[1]
		else {
			worst: f32 = 0
			for k in 0 ..< len(ref) do worst = max(worst, abs(ref[k] - out.channels[1][k]))
			testing.expectf(t, worst < 1e-4, "pattern %d against fixed 512 blocks: off by %v", i, worst)
		}
		rig_synth_free(r)
	}
}

// Routes into an effect: a macro opens the filter effect; so does the
// newest voice's envelope.
@(test)
effects_are_modulated :: proc(t: ^testing.T) {
	bright :: proc(t: ^testing.T, source: synth.Mod_Source, macro: f32) -> f64 {
		r := rig_synth()
		defer rig_synth_free(r)
		f :: proc(x: synth.Fx_Filter_Field) -> core.Param_Id { return synth.effect_param(.Filter, x) }
		set_param(r, f(.On), 1)
		set_param(r, f(.Cutoff), 30)
		set_param(r, f(.Resonance), 0)
		set_param(r, synth.global_param(.Macro_1), macro)
		set_param(r, synth.env_param(2, .Sustain), 1)
		synth.patch_add_route(&r.patch, {source = source, dest = f(.Cutoff), amount = 0.7})
		synth.synth_set_patch(r.s, &r.patch)
		out := play_synth(t, r, {on(0, 57)}, 24_000)
		return kit.tone_amplitude(out.channels[0][12_000:], SR, 220 * 8)
	}
	closed := bright(t, .Macro_1, 0)
	opened := bright(t, .Macro_1, 1)
	testing.expectf(t, opened > 10 * closed, "the macro opens it (8th harmonic %v to %v)", closed, opened)
	by_env := bright(t, .Env_2, 0)
	testing.expectf(t, by_env > 10 * closed, "so does the voice's envelope (%v)", by_env)
}

// The effects' parameters: each named once, in its range at its default.
@(test)
effect_parameters :: proc(t: ^testing.T) {
	names := make(map[string]bool, context.temp_allocator)
	count := 0
	for p in synth.PARAMS {
		testing.expectf(t, !names[p.name], "%s: named once", p.name)
		names[p.name] = true
		testing.expectf(t, p.default >= p.min && p.default <= p.max, "%s: its default in range", p.name)
		if synth.is_effect_param(p.id) do count += 1
	}
	testing.expectf(t, count > 100, "the effects' parameters (%d)", count)
	d := synth.param_spec(synth.effect_param(.Reverb, synth.Reverb_Field.Decay))
	testing.expectf(t, abs(synth.param_curve(d, d.default) - 1) < 1e-6, "the reverb decays in 1 s by default")
}

// A random modulator on a voice: it moves the level; retriggered, two
// notes move alike, else each its own way.
@(test)
randoms_on_a_voice :: proc(t: ^testing.T) {
	levels :: proc(t: ^testing.T, retrigger: bool) -> (a, b: [12]f64) {
		r := rig_synth()
		defer rig_synth_free(r)
		set_param(r, synth.random_param(1, .Style), f32(synth.Random_Style.Sample_Hold))
		set_param(r, synth.random_param(1, .Rate), 0) // Hz
		set_param(r, synth.random_param(1, .Hz), 3)   // 8 steps a second
		set_param(r, synth.random_param(1, .Retrigger), 1 if retrigger else 0)
		synth.patch_add_route(&r.patch, {source = .Random_1, dest = synth.osc_param(1, .Level), amount = -0.8})
		synth.synth_set_patch(r.s, &r.patch)
		out := play_synth(t, r, {on(0, 69), off(24_000, 69), on(48_000, 69)}, 72_000)
		l := out.channels[0]
		for k in 0 ..< 12 {
			a[k] = kit.rms(l[2400 + k * 1600:2400 + (k + 1) * 1600])
			b[k] = kit.rms(l[50_400 + k * 1600:50_400 + (k + 1) * 1600])
		}
		return
	}
	a, b := levels(t, true)
	lo, hi: f64 = 1e9, 0
	alike := 0.0
	for k in 0 ..< 12 {
		lo, hi = min(lo, a[k]), max(hi, a[k])
		alike = max(alike, abs(a[k] - b[k]))
	}
	testing.expectf(t, hi > 1.5 * lo, "it moves the level (%v..%v)", lo, hi)
	testing.expectf(t, alike < 0.02 * hi, "retriggered: both notes alike (%v)", alike)
	c, d := levels(t, false)
	apart := 0.0
	for k in 0 ..< 12 do apart = max(apart, abs(c[k] - d[k]))
	testing.expectf(t, apart > 0.1 * hi, "free: each its own (%v)", apart)
}

// A morph in the voice: the low-pass morph at full leaves a saw its
// fundamental only; the Shepard morph at full plays it an octave up.
@(test)
morphs_in_a_voice :: proc(t: ^testing.T) {
	play :: proc(t: ^testing.T, m: synth.Spectral_Morph, amount: f32) -> []f32 {
		r := rig_synth()
		defer rig_synth_free(r)
		set_param(r, synth.osc_param(1, .Spectral_Morph), f32(m))
		set_param(r, synth.osc_param(1, .Spectral_Amount), amount)
		out := play_synth(t, r, {on(0, 57)}, 24_000)
		return out.channels[0][4800:]
	}
	lp := play(t, .Low_Pass, 1)
	testing.expectf(t, kit.tone_amplitude(lp, SR, 220) > 0.05 && kit.tone_amplitude(lp, SR, 440) < 0.01 * kit.tone_amplitude(lp, SR, 220), "low-pass: 220 Hz alone (%v, %v)", kit.tone_amplitude(lp, SR, 220), kit.tone_amplitude(lp, SR, 440))
	sh := play(t, .Shepard_Tone, 1)
	testing.expectf(t, kit.tone_amplitude(sh, SR, 220) < 0.01 && kit.tone_amplitude(sh, SR, 440) > 0.05, "Shepard: an octave up (%v at 220, %v at 440)", kit.tone_amplitude(sh, SR, 220), kit.tone_amplitude(sh, SR, 440))
}
