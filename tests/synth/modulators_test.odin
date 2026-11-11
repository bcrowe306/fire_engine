package test_synth

import "core:math"
import "core:testing"

import "fire:synth"

// Steps an envelope `seconds` in 1 ms steps; returns its value.
env_for :: proc(e: ^synth.Env_State, p: ^synth.Env_Params, seconds: f32) -> f32 {
	v := e.value
	for _ in 0 ..< int(seconds * 1000 + 0.5) do v = synth.env_step(e, p, 0.001)
	return v
}

// Delay, attack, hold, decay to the sustain, release to nothing: each
// stage takes its time; the powers bend the curves.
@(test)
an_envelope_takes_its_times :: proc(t: ^testing.T) {
	p := synth.Env_Params{delay = 0.1, attack = 0.2, hold = 0.1, decay = 0.3, sustain = 0.5, release = 0.4}
	e: synth.Env_State
	synth.env_gate_on(&e, &p)
	testing.expectf(t, env_for(&e, &p, 0.09) == 0, "still in its delay")
	v := env_for(&e, &p, 0.11) // 0.2 s: half way up (straight attack)
	testing.expectf(t, abs(v - 0.5) < 0.02, "half way up its attack (%v)", v)
	v = env_for(&e, &p, 0.15) // 0.35 s: in the hold
	testing.expectf(t, v == 1, "holds at the top (%v)", v)
	v = env_for(&e, &p, 0.5) // well past the decay
	testing.expectf(t, abs(v - 0.5) < 1e-4, "sustains (%v)", v)
	synth.env_gate_off(&e)
	v = env_for(&e, &p, 0.2)
	testing.expectf(t, abs(v - 0.25) < 0.02, "half way down its release (%v)", v)
	env_for(&e, &p, 0.25)
	testing.expect(t, synth.env_done(&e), "done after its release")

	// A negative decay power falls fast first (below half by the middle,
	// as a natural decay does); a positive one slowly.
	for power in ([]f32{-4, 4}) {
		q := synth.Env_Params{attack = 0.001, decay = 1, sustain = 0, release = 0.1, decay_power = power}
		e = {}
		synth.env_gate_on(&e, &q)
		v = env_for(&e, &q, 0.501)
		if power < 0 do testing.expectf(t, v < 0.5, "power %v: already low mid-decay (%v)", power, v)
		else do testing.expectf(t, v > 0.5, "power %v: still high mid-decay (%v)", power, v)
	}
	// Killed, it falls to nothing in 50 ms.
	synth.env_gate_on(&e, &p)
	env_for(&e, &p, 0.3)
	synth.env_kill(&e)
	env_for(&e, &p, 0.06)
	testing.expect(t, synth.env_done(&e), "a kill ends it")
}

// A triangle LFO at 2 Hz: up at a quarter second, down again at a half;
// the stereo offset puts the sides apart; fade starts from its start
// value; envelope mode holds at the end.
@(test)
an_lfo_runs_its_shape :: proc(t: ^testing.T) {
	shape := synth.lfo_preset(.Triangle)
	table := make([]f32, synth.LFO_RESOLUTION, context.temp_allocator)
	synth.lfo_shape_render(&shape, table)
	p := synth.LFO_DEFAULTS
	p.rate = .Seconds
	p.hz = 2
	l: synth.Lfo_State
	synth.lfo_note_on(&l, &p, 2, 0)
	run :: proc(l: ^synth.Lfo_State, p: ^synth.Lfo_Params, table: []f32, seconds: f32) -> [2]f32 {
		v: [2]f32
		for _ in 0 ..< int(seconds * 1000 + 0.5) do v = synth.lfo_step(l, p, table, synth.lfo_hz(p, 120, 60), 0.001)
		return v
	}
	v := run(&l, &p, table, 0.25)
	testing.expectf(t, abs(v[0] - 1) < 0.02, "a quarter second: the top (%v)", v[0])
	v = run(&l, &p, table, 0.25)
	testing.expectf(t, v[0] < 0.02, "half a second: down again (%v)", v[0])
	p.stereo = 0.25
	synth.lfo_note_on(&l, &p, 2, 0)
	v = run(&l, &p, table, 0.125)
	testing.expectf(t, abs(v[0] - v[1]) > 0.4, "stereo: the sides apart (%v)", v)
	p.stereo = 0
	p.mode = .Envelope
	synth.lfo_note_on(&l, &p, 2, 0)
	v = run(&l, &p, table, 2)
	testing.expectf(t, v[0] < 0.02, "envelope: once through, then held at the end (%v)", v[0])
	// Tempo: at 120 BPM, 1/4 is a cycle a beat (2 Hz); dotted is 2/3 of it.
	p.rate = .Tempo
	p.tempo = 8
	testing.expectf(t, abs(synth.lfo_hz(&p, 120, 60) - 2) < 1e-5, "1/4 at 120 BPM: 2 Hz")
	p.rate = .Dotted
	testing.expectf(t, abs(synth.lfo_hz(&p, 120, 60) - 4.0 / 3) < 1e-5, "dotted: 2/3 of it")
	p.rate = .Keytrack
	p.key_transpose, p.key_tune = 0, 0
	testing.expectf(t, abs(synth.lfo_hz(&p, 120, 69) - 440) < 0.01, "key tracked: the note's pitch")
	// Fade: from the start value up to the shape over its time.
	p = synth.LFO_DEFAULTS
	p.rate, p.hz, p.fade = .Seconds, 2, 1
	synth.lfo_note_on(&l, &p, 2, 0)
	v = run(&l, &p, table, 0.25)
	testing.expectf(t, v[0] > 0.15 && v[0] < 0.4, "a quarter into its fade, a quarter of the way (%v)", v[0])
	_ = math.PI
}
