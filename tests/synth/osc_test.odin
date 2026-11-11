package test_synth

import "core:math"
import "core:testing"

import "fire:synth"
import kit "fire:testkit"

SR :: 48_000.0

// An oscillator playing a table, rendered in blocks of `block`.
Osc_Rig :: struct {
	sh:    synth.Osc_Shared,
	s:     synth.Osc_State,
	p:     synth.Osc_Params,
	table: ^synth.Wavetable,
}

rig_osc :: proc(which: synth.Builtin_Table = .Saw) -> ^Osc_Rig {
	r := new(Osc_Rig)
	synth.osc_shared_init(&r.sh)
	r.table, _ = synth.builtin_table(which)
	r.p = synth.OSC_DEFAULTS
	r.p.table = r.table
	r.p.level = 1
	r.p.random_phase = 0
	return r
}

rig_osc_free :: proc(r: ^Osc_Rig) {
	synth.osc_shared_destroy(&r.sh)
	synth.wavetable_destroy(r.table)
	free(r)
}

// Renders `frames` at `hz`: left and right (temporary allocator).
play :: proc(r: ^Osc_Rig, hz: f64, frames: int, block := 128, start := true, mod: ^[2][]f32 = nil) -> (l, rr: []f32) {
	if start do synth.osc_start(&r.s, &r.p, 1)
	l = make([]f32, frames, context.temp_allocator)
	rr = make([]f32, frames, context.temp_allocator)
	inc := make([]f32, block, context.temp_allocator)
	for &v in inc do v = f32(hz / SR)
	for at := 0; at < frames; at += block {
		n := min(block, frames - at)
		m: ^[2][]f32
		mm: [2][]f32
		if mod != nil {
			mm = {mod[0][at:at + n], mod[1][at:at + n]}
			m = &mm
		}
		synth.osc_render(&r.sh, &r.s, &r.p, inc[:n], m, l[at:at + n], rr[at:at + n], nil, SR)
	}
	return
}

// A saw plays its pitch, its harmonics falling as 1/n, and none of its
// harmonics above Nyquist fold back down.
@(test)
a_saw_plays_its_pitch_without_aliasing :: proc(t: ^testing.T) {
	r := rig_osc()
	defer rig_osc_free(r)
	l, _ := play(r, 440, 48_000)
	a1, a2, a3 := kit.tone_amplitude(l[4800:], SR, 440), kit.tone_amplitude(l[4800:], SR, 880), kit.tone_amplitude(l[4800:], SR, 1320)
	testing.expectf(t, a1 > 0.4, "440 Hz is there (%v)", a1)
	testing.expectf(t, abs(a2 / a1 - 0.5) < 0.03 && abs(a3 / a1 - 1.0 / 3) < 0.03, "harmonics at 1/2, 1/3 (%v, %v)", a2 / a1, a3 / a1)
	testing.expectf(t, kit.tone_amplitude(l[4800:], SR, 450) < 0.02 * a1, "nothing off the pitch")

	// 5 kHz: harmonics 1..4 under Nyquist; the 5th (25 kHz) would fold to 23 kHz.
	l2, _ := play(r, 5000, 48_000)
	h4 := kit.tone_amplitude(l2[4800:], SR, 20_000)
	fold := kit.tone_amplitude(l2[4800:], SR, 23_000)
	testing.expectf(t, h4 > 0.05, "the 4th harmonic is there (%v)", h4)
	testing.expectf(t, fold < 1e-3, "nothing folds back (%v at 23 kHz)", fold)
	n, _ := kit.count_non_finite(l2)
	testing.expect_value(t, n, 0)
}

// Two unison voices at 40 cents: one sharp on the left, one flat on the
// right; with no stereo spread, both sides the same.
@(test)
unison_detunes_and_spreads :: proc(t: ^testing.T) {
	r := rig_osc(.Sine)
	defer rig_osc_free(r)
	r.p.unison = 2
	r.p.detune_cents = 40
	l, rr := play(r, 440, 48_000)
	up := 440 * math.pow(2, 40.0 / 1200)
	down := 440 / math.pow(2, 40.0 / 1200)
	testing.expectf(t, kit.tone_amplitude(l[4800:], SR, up) > 0.5 && kit.tone_amplitude(l[4800:], SR, down) < 0.05, "left is sharp")
	testing.expectf(t, kit.tone_amplitude(rr[4800:], SR, down) > 0.5 && kit.tone_amplitude(rr[4800:], SR, up) < 0.05, "right is flat")

	r.p.stereo_spread = 0
	l, rr = play(r, 440, 4800)
	worst: f32 = 0
	for i in 0 ..< len(l) do worst = max(worst, abs(l[i] - rr[i]))
	testing.expectf(t, worst < 1e-6, "no spread: mono (%v)", worst)

	// Seven voices, a chord stack: the fifth and the third are heard.
	r.p.unison = 7
	r.p.stack = .Major_Chord
	r.p.detune_cents = 0
	r.p.stereo_spread = 1
	l, rr = play(r, 220, 48_000)
	for hz in ([]f64{220, 220 * 1.25992104989, 220 * 1.49830707688, 440}) {
		a := kit.tone_amplitude(l[4800:], SR, hz) + kit.tone_amplitude(rr[4800:], SR, hz)
		testing.expectf(t, a > 0.05, "%v Hz in the chord (%v)", hz, a)
	}
}

// Level scales it, pan moves it (equal power: both sides at 1 in the
// middle), and a single voice is the same on both sides.
@(test)
level_and_pan :: proc(t: ^testing.T) {
	r := rig_osc(.Sine)
	defer rig_osc_free(r)
	l, rr := play(r, 440, 9600)
	p := kit.peak(l[2400:])
	testing.expectf(t, abs(p - 1) < 0.02, "full level, centre: peak 1 (%v)", p)
	testing.expectf(t, abs(kit.peak(rr[2400:]) - p) < 1e-6, "both sides alike")
	r.p.level = 0.25
	r.p.pan = -1
	l, rr = play(r, 440, 9600)
	testing.expectf(t, abs(kit.peak(l[2400:]) - 0.25 * math.SQRT_TWO) < 0.01, "hard left: √2 louder there (%v)", kit.peak(l[2400:]))
	testing.expectf(t, kit.peak(rr[2400:]) < 1e-6, "nothing right")
}

// The same sound whatever the render size.
@(test)
any_block_size_sounds_the_same :: proc(t: ^testing.T) {
	r := rig_osc(.Basic_Shapes)
	defer rig_osc_free(r)
	r.p.unison = 5
	r.p.frame = 0.6
	r.p.warp = .Bend
	r.p.warp_amount = 0.8
	a, _ := play(r, 330, 9000, 512)
	b, _ := play(r, 330, 9000, 37)
	worst: f32 = 0
	for i in 0 ..< len(a) do worst = max(worst, abs(a[i] - b[i]))
	testing.expectf(t, worst < 1e-4, "512 and 37 at a time (off by %v)", worst)
}

// Every warp: finite and in range; sync and formant brighten it; pulse
// width leaves part of each cycle silent; quantize steps it; RM and FM
// follow their source.
@(test)
the_warps :: proc(t: ^testing.T) {
	r := rig_osc(.Sine)
	defer rig_osc_free(r)
	src := make([]f32, 48_000, context.temp_allocator)
	for &v, i in src do v = f32(math.sin(math.TAU * 330 * f64(i) / SR))
	mod := [2][]f32{src, src}
	plain, _ := play(r, 220, 48_000)
	base_bright := kit.tone_amplitude(plain[4800:], SR, 220 * 4)
	for w in synth.Osc_Warp {
		r.p.warp = w
		r.p.warp_amount = 0.8
		l, _ := play(r, 220, 48_000, mod = &mod)
		n, _ := kit.count_non_finite(l)
		testing.expectf(t, n == 0 && kit.peak(l) < 4, "%v: finite, in range (peak %v)", w, kit.peak(l))
		#partial switch w {
		case .None:
			testing.expectf(t, abs(kit.peak(l[4800:]) - 1) < 0.02, "none: the sine (%v)", kit.peak(l[4800:]))
		case .Sync, .Formant:
			sum := 0.0
			for h in 2 ..= 8 do sum += kit.tone_amplitude(l[4800:], SR, 220 * f64(h))
			testing.expectf(t, sum > 0.2 && sum > 10 * base_bright, "%v brightens it (%v)", w, sum)
		case .Pulse_Width:
			quiet := 0
			for v in l[4800:9600] do if abs(v) < 1e-6 do quiet += 1
			testing.expectf(t, quiet > 4800 / 2, "pulse width 0.8: most of each cycle silent (%d of 4800)", quiet)
		case .Rm_A:
			testing.expectf(t, kit.tone_amplitude(l[4800:], SR, 330 + 220) > 0.2 && kit.tone_amplitude(l[4800:], SR, 330 - 220) > 0.2, "ring: sum and difference")
		case .Fm_A:
			testing.expectf(t, kit.tone_amplitude(l[4800:], SR, 220) < 0.8, "FM moves energy off the carrier (%v)", kit.tone_amplitude(l[4800:], SR, 220))
		}
	}
	// Quantize at full: two steps a cycle, so a sine becomes a square-ish
	// wave of two levels.
	r.p.warp = .Quantize
	r.p.warp_amount = 1
	l, _ := play(r, 110, 9600)
	changes := 0
	last := f32(100)
	for v in l[2400:] do if abs(v - last) > 0.05 {
		changes += 1
		last = v
	}
	testing.expectf(t, changes < 9600 / 50, "quantized: it holds steps (%d changes)", changes)
}

// A frame moved while playing crossfades: no click, and the new frame is
// heard after a fade.
@(test)
a_frame_change_crossfades :: proc(t: ^testing.T) {
	r := rig_osc(.Basic_Shapes)
	defer rig_osc_free(r)
	r.p.frame = 0
	a, _ := play(r, 110, 4800)
	r.p.frame = 1 // the pulse
	b, _ := play(r, 110, 4800, start = false)
	whole := make([]f32, 9600, context.temp_allocator)
	copy(whole, a)
	copy(whole[4800:], b)
	// (Steps as steep as either wave has, at most: the pulse has steep
	// edges of its own.)
	steady_a, _ := kit.max_step(a[2400:4790])
	steady_b, _ := kit.max_step(b[2400:])
	step, at := kit.max_step(whole[4795:4805])
	testing.expectf(t, step <= max(steady_a, steady_b) + 0.01, "no jump where it changes (%v at %d; the waves' own %v, %v)", step, at, steady_a, steady_b)
	testing.expectf(t, kit.tone_amplitude(b[1000:], SR, 330) > 0.1, "the pulse's harmonics after the fade")
}
