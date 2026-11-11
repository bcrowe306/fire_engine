package test_synth

import "core:math"
import "core:testing"

import "fire:synth"
import kit "fire:testkit"

// A second of a 440 Hz sine at 48 kHz, as a sample.
sine_sample :: proc() -> ^synth.Sample {
	x := make([]f32, 48_000, context.temp_allocator)
	for &v, i in x do v = f32(0.5 * math.sin(math.TAU * 440 * f64(i) / SR))
	s, _ := synth.sample_make("sine", {x}, SR)
	return s
}

play_sample :: proc(o: ^synth.Sample_Osc, p: ^synth.Sample_Params, note: f32, frames: int) -> (l, r: []f32) {
	l = make([]f32, frames, context.temp_allocator)
	r = make([]f32, frames, context.temp_allocator)
	for at := 0; at < frames; at += 128 {
		n := min(128, frames - at)
		synth.sample_osc_render(o, p, note, l[at:at + n], r[at:at + n], nil, SR)
	}
	return
}

// Key tracked, C3 plays it as recorded and C4 an octave up; untracked,
// every note plays it as recorded, and transpose moves it.
@(test)
the_sample_follows_the_note :: proc(t: ^testing.T) {
	s := sine_sample()
	defer synth.sample_destroy(s)
	p := synth.Sample_Params{sample = s, keytrack = true, level = 1}
	o: synth.Sample_Osc
	synth.sample_osc_start(&o, &p, 1)
	l, _ := play_sample(&o, &p, 60, 9600)
	testing.expectf(t, kit.tone_amplitude(l, SR, 440) > 0.45, "C3: 440 Hz")
	synth.sample_osc_start(&o, &p, 1)
	l, _ = play_sample(&o, &p, 72, 9600)
	testing.expectf(t, kit.tone_amplitude(l, SR, 880) > 0.45, "C4: 880 Hz (%v)", kit.tone_amplitude(l, SR, 880))
	p.keytrack = false
	p.transpose = -12
	synth.sample_osc_start(&o, &p, 1)
	l, _ = play_sample(&o, &p, 90, 9600)
	testing.expectf(t, kit.tone_amplitude(l, SR, 220) > 0.45, "untracked, down an octave: 220 Hz")
}

// Not looping, it stops at its end; looping, it goes on; bouncing, it
// comes back (so at the end it is playing the sample backwards).
@(test)
loop_bounce_and_end :: proc(t: ^testing.T) {
	x := make([]f32, 1000, context.temp_allocator)
	for &v, i in x do v = f32(i) / 1000 // a ramp up
	s, _ := synth.sample_make("ramp", {x}, SR)
	defer synth.sample_destroy(s)
	p := synth.Sample_Params{sample = s, keytrack = false, level = 1}
	o: synth.Sample_Osc
	synth.sample_osc_start(&o, &p, 1)
	l, _ := play_sample(&o, &p, 60, 3000)
	testing.expectf(t, kit.peak(l[1100:]) == 0, "one-shot: silent after its end")
	p.loop = true
	synth.sample_osc_start(&o, &p, 1)
	l, _ = play_sample(&o, &p, 60, 3000)
	testing.expectf(t, l[1500] > l[1400] && l[1400] > 0.3, "looping: it ramps up again (%v, %v)", l[1400], l[1500])
	p.bounce = true
	synth.sample_osc_start(&o, &p, 1)
	l, _ = play_sample(&o, &p, 60, 3000)
	testing.expectf(t, l[1500] < l[1400], "bouncing: on the way back it ramps down (%v, %v)", l[1400], l[1500])
}

// Played four octaves up, white noise is no louder above the new
// Nyquist's fold than below (it reads a halved copy), and every built-in
// noise is finite with the tilt its colour has.
@(test)
noise_colours_and_fast_playing :: proc(t: ^testing.T) {
	white, _ := synth.builtin_noise(.White)
	pink, _ := synth.builtin_noise(.Pink)
	brown, _ := synth.builtin_noise(.Brown)
	defer synth.sample_destroy(white)
	defer synth.sample_destroy(pink)
	defer synth.sample_destroy(brown)
	tilt :: proc(s: ^synth.Sample) -> f64 {
		x := s.levels[0][0]
		lo, hi: f64
		for hz in ([]f64{100, 150, 200}) do lo += kit.tone_amplitude(x[:44_100], 44_100, hz)
		for hz in ([]f64{8000, 9000, 10_000}) do hi += kit.tone_amplitude(x[:44_100], 44_100, hz)
		return hi / lo
	}
	w, pk, br := tilt(white), tilt(pink), tilt(brown)
	testing.expectf(t, w > pk && pk > br, "white brighter than pink, pink than brown (%v, %v, %v)", w, pk, br)
	p := synth.Sample_Params{sample = white, keytrack = true, level = 1, loop = true}
	o: synth.Sample_Osc
	synth.sample_osc_start(&o, &p, 1)
	l, r := play_sample(&o, &p, 60 + 48, 24_000)
	n1, _ := kit.count_non_finite(l)
	n2, _ := kit.count_non_finite(r)
	testing.expect(t, n1 == 0 && n2 == 0, "finite played fast")
	testing.expectf(t, kit.peak(l) < 1.5, "in range (%v)", kit.peak(l))
}
