package test_synth

import "core:math"
import "core:testing"

import "fire:core"
import "fire:synth"
import tb "fire:timebase"
import kit "fire:testkit"

// A synth with a saw on oscillator 1 (and the tables it keeps).
Synth_Rig :: struct {
	node:  core.Node,
	s:     ^synth.Synth,
	patch: synth.Patch,
	saw, sine: ^synth.Wavetable,
}

rig_synth :: proc() -> ^Synth_Rig {
	r := new(Synth_Rig)
	r.node, r.s = synth.synth_create()
	r.saw, _ = synth.builtin_table(.Saw)
	r.sine, _ = synth.builtin_table(.Sine)
	r.patch = synth.patch_default()
	r.patch.tables = {r.saw, r.sine, r.saw}
	synth.synth_set_patch(r.s, &r.patch)
	// A plain sound: no filter, a quick release.
	set_param(r, synth.filter_param(1, .On), 0)
	set_param(r, synth.env_param(1, .Release), 0.3)
	set_param(r, synth.global_param(.Volume), 0)
	set_param(r, synth.osc_param(1, .Random_Phase), 0)
	return r
}

rig_synth_free :: proc(r: ^Synth_Rig) {
	core.node_destroy(&r.node)
	synth.wavetable_destroy(r.saw)
	synth.wavetable_destroy(r.sine)
	free(r)
}

// Sets a parameter straight (as if a block had already passed).
set_param :: proc(r: ^Synth_Rig, id: core.Param_Id, v: f32) {
	r.s.values[id] = v
}

on :: proc(at: int, key: u8, vel: f32 = 1) -> kit.Timed_Event {
	return {tb.Sample_Time(at), core.Note_On{id = core.NOTE_ID_ANY, key = key, velocity = vel}}
}
off :: proc(at: int, key: u8) -> kit.Timed_Event {
	return {tb.Sample_Time(at), core.Note_Off{id = core.NOTE_ID_ANY, key = key}}
}

play_synth :: proc(t: ^testing.T, r: ^Synth_Rig, events: []kit.Timed_Event, frames: int, blocks: kit.Block_Pattern = nil) -> kit.Audio_Buffer {
	cfg := kit.default_render_config()
	cfg.events = events
	if blocks != nil do cfg.blocks = blocks
	out, rep := kit.render(&r.node, kit.buffer_length_only(frames, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&rep)
	kit.expect_clean_render(t, rep)
	return out
}

// A note: its pitch, cleanly rendered (finite, nothing allocated on the
// audio thread); let go, it ends after its release and frees its voice.
@(test)
a_note_plays_and_ends :: proc(t: ^testing.T) {
	r := rig_synth()
	defer rig_synth_free(r)
	out := play_synth(t, r, {on(0, 69), off(24_000, 69)}, 48_000)
	l := out.channels[0]
	a := kit.tone_amplitude(l[4800:20_000], SR, 440)
	testing.expectf(t, a > 0.1, "A4: 440 Hz (%v)", a)
	testing.expectf(t, kit.tone_amplitude(l[4800:20_000], SR, 880) / a > 0.4, "a saw: its second harmonic at half")
	testing.expectf(t, kit.peak(l[40_000:]) < 1e-4, "silent after its release (%v)", kit.peak(l[40_000:]))
	live := synth.synth_live(r.s)
	testing.expectf(t, live.voices == 0, "no voice left (%d)", live.voices)
}

// The same notes, whatever the blocks (block-size invariance).
@(test)
any_blocks_sound_the_same :: proc(t: ^testing.T) {
	events := []kit.Timed_Event{on(100, 60), on(5_000, 64, 0.6), off(9_000, 60), on(12_345, 67), off(20_000, 64), off(22_000, 67)}
	setup :: proc(r: ^Synth_Rig) {
		set_param(r, synth.osc_param(1, .Unison), 4)
		set_param(r, synth.filter_param(1, .On), 1)
		set_param(r, synth.filter_param(1, .Cutoff), 80)
		set_param(r, synth.lfo_param(1, .Rate), 0)
		set_param(r, synth.lfo_param(1, .Hz), 2) // 4 Hz
		synth.patch_add_route(&r.patch, {source = .Lfo_1, dest = synth.filter_param(1, .Cutoff), amount = 0.2})
		synth.patch_add_route(&r.patch, {source = .Env_2, dest = synth.osc_param(1, .Frame), amount = 1})
		synth.synth_set_patch(r.s, &r.patch)
	}
	ref: []f32
	for pattern, i in kit.standard_block_patterns(512) {
		r := rig_synth()
		setup(r)
		out := play_synth(t, r, events, 26_000, pattern)
		if i == 0 do ref = out.channels[0]
		else {
			worst: f32 = 0
			for k in 0 ..< len(ref) do worst = max(worst, abs(ref[k] - out.channels[0][k]))
			testing.expectf(t, worst < 1e-4, "pattern %d against fixed 512 blocks: off by %v", i, worst)
		}
		rig_synth_free(r)
	}
}

// Polyphony 2: a third note steals one (only two keep sounding); mono
// glides from one note to the next.
@(test)
polyphony_and_glide :: proc(t: ^testing.T) {
	r := rig_synth()
	defer rig_synth_free(r)
	set_param(r, synth.global_param(.Polyphony), 2)
	play_synth(t, r, {on(0, 60), on(100, 64), on(200, 67)}, 9_600)
	live := synth.synth_live(r.s)
	testing.expectf(t, live.voices == 2, "two voices sound (%d)", live.voices)

	m := rig_synth()
	defer rig_synth_free(m)
	set_param(m, synth.global_param(.Mono), 2) // legato
	set_param(m, synth.global_param(.Glide), math.pow(f32(0.2), 0.25)) // 0.2 s
	out := play_synth(t, m, {on(0, 57), on(24_000, 69)}, 48_000)
	l := out.channels[0]
	early := kit.tone_amplitude(l[24_000 + 480:24_000 + 2400], SR, 440)
	late := kit.tone_amplitude(l[40_000:], SR, 440)
	testing.expectf(t, late > 0.1 && early < late * 0.5, "it glides up to 440 Hz (%v early, %v after)", early, late)
}

// Routes: an LFO on the level makes it rise and fall; an envelope on a
// low-pass cutoff opens it as the note starts.
@(test)
routes_modulate :: proc(t: ^testing.T) {
	r := rig_synth()
	defer rig_synth_free(r)
	set_param(r, synth.lfo_param(1, .Rate), 0) // seconds
	set_param(r, synth.lfo_param(1, .Hz), 2)   // 4 Hz
	synth.patch_add_route(&r.patch, {source = .Lfo_1, dest = synth.osc_param(1, .Level), amount = -0.7})
	synth.synth_set_patch(r.s, &r.patch)
	out := play_synth(t, r, {on(0, 69)}, 48_000)
	l := out.channels[0]
	lo, hi: f64 = 1e9, 0
	for k in 0 ..< 16 {
		a := kit.rms(l[4800 + k * 2400:4800 + (k + 1) * 2400])
		lo, hi = min(lo, a), max(hi, a)
	}
	testing.expectf(t, hi > 3 * lo, "the LFO moves the level (rms %v to %v)", lo, hi)

	f := rig_synth()
	defer rig_synth_free(f)
	set_param(f, synth.filter_param(1, .On), 1)
	set_param(f, synth.filter_param(1, .Cutoff), 30) // closed
	set_param(f, synth.filter_param(1, .Resonance), 0)
	set_param(f, synth.env_param(2, .Attack), math.pow(f32(0.25), 0.25))
	set_param(f, synth.env_param(2, .Sustain), 1)
	synth.patch_add_route(&f.patch, {source = .Env_2, dest = synth.filter_param(1, .Cutoff), amount = 0.7})
	synth.synth_set_patch(f.s, &f.patch)
	out = play_synth(t, f, {on(0, 57)}, 48_000)
	l = out.channels[0]
	dark := kit.tone_amplitude(l[480:2400], SR, 220 * 8)
	bright := kit.tone_amplitude(l[24_000:], SR, 220 * 8)
	testing.expectf(t, bright > 10 * dark, "the envelope opens the filter (8th harmonic %v to %v)", dark, bright)
}

// Oversampling 4×: the same pitch, still clean.
@(test)
oversampled :: proc(t: ^testing.T) {
	r := rig_synth()
	defer rig_synth_free(r)
	set_param(r, synth.global_param(.Oversampling), 2)
	out := play_synth(t, r, {on(0, 69)}, 24_000)
	a := kit.tone_amplitude(out.channels[0][4800:], SR, 440)
	testing.expectf(t, a > 0.1, "440 Hz at 4× (%v)", a)
}
