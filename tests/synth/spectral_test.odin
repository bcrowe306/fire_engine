package test_synth

import "core:testing"

import "fire:synth"

// Every morph: each does what it says to a saw's harmonics; the two-way
// ones do nothing at 0.5, the rest nothing at 0; none gives a NaN.
@(test)
spectral_morphs :: proc(t: ^testing.T) {
	saw, _ := synth.builtin_table(.Saw)
	defer synth.wavetable_destroy(saw)
	shapes, _ := synth.builtin_table(.Basic_Shapes)
	defer synth.wavetable_destroy(shapes)
	H :: 200
	out := make([]complex64, synth.WAVE_BINS, context.temp_allocator)
	ref := make([]complex64, synth.WAVE_BINS, context.temp_allocator)
	synth.spectral_build(saw, 0, H, .None, 0, ref)
	same :: proc(a, b: []complex64) -> f32 {
		d: f32 = 0
		for k in 0 ..< len(a) do d = max(d, abs(a[k] - b[k]))
		return d
	}
	for m in synth.Spectral_Morph {
		for amount in ([]f32{0, 0.25, 0.5, 0.75, 1}) {
			synth.spectral_build(saw, 0, H, m, amount, out)
			ok := true
			for c in out do ok &&= abs(c) == abs(c) && abs(c) < 10
			testing.expectf(t, ok, "%v at %v: finite", m, amount)
			for k in H + 1 ..< synth.WAVE_BINS do ok &&= out[k] == 0
			testing.expectf(t, ok, "%v at %v: nothing above harmonic %d", m, amount, H)
		}
		neutral: f32 = 0.5 if m == .Formant_Scale || m == .Harmonic_Stretch || m == .Inharmonic_Stretch || m == .Skew else 0
		if m == .Vocode || m == .Smear do neutral = 0
		synth.spectral_build(saw, 0, H, m, neutral, out)
		testing.expectf(t, same(out, ref) < 1e-6, "%v at %v: as it was (%v)", m, neutral, same(out, ref))
	}
	synth.spectral_build(saw, 0, H, .Low_Pass, 0.5, out) // cut at 32
	testing.expectf(t, abs(out[20]) > 0 && out[40] == 0, "low-pass: 20 kept (%v), 40 gone (%v)", abs(out[20]), abs(out[40]))
	synth.spectral_build(saw, 0, H, .High_Pass, 0.5, out)
	testing.expectf(t, out[20] == 0 && abs(out[40]) > 0, "high-pass: 20 gone, 40 kept")
	synth.spectral_build(saw, 0, H, .Shepard_Tone, 1, out)
	testing.expectf(t, abs(out[3]) < 1e-9 && abs(out[4]) > 0, "Shepard at 1: the octave up, odd harmonics gone")
	synth.spectral_build(saw, 0, H, .Phase_Disperse, 1, out)
	dm: f32 = 0
	for k in 1 ..= H do dm = max(dm, abs(abs(out[k]) - abs(ref[k])))
	testing.expectf(t, dm < 1e-6 && same(out, ref) > 1e-4, "dispersed: the levels kept, the phases turned")
	synth.spectral_build(saw, 0, H, .Harmonic_Stretch, 1, out)
	testing.expectf(t, abs(out[3]) > 0 && out[2] == 0, "stretched: harmonic 2 moved up to 3 (k^1.52)")
	synth.spectral_build(saw, 0, H, .Formant_Scale, 1, out) // drawn out ×4: harmonic 8 has the 2nd's level
	testing.expectf(t, abs(abs(out[8]) - abs(ref[2])) < 1e-4, "formant ×4: 8 as 2 was (%v, %v)", abs(out[8]), abs(ref[2]))
	synth.spectral_build(saw, 0, H, .Smear, 1, out)
	testing.expectf(t, abs(out[50]) > abs(ref[50]) * 2, "smeared: the highs lifted")
	a := make([]complex64, synth.WAVE_BINS, context.temp_allocator)
	synth.spectral_build(saw, 0, H, .Random_Amplitudes, 1, out)
	synth.spectral_build(saw, 0, H, .Random_Amplitudes, 1, a)
	testing.expectf(t, same(out, a) == 0 && same(out, ref) > 1e-4, "random amplitudes: scattered, the same each time")
	// Skew on a table of many frames: the highs read from later frames.
	synth.spectral_build(shapes, 0, H, .Skew, 0.5, a)
	synth.spectral_build(shapes, 0, H, .Skew, 1, out)
	testing.expectf(t, abs(out[1] - a[1]) < 0.01 * abs(a[1]) + 1e-6 && same(out, a) > 1e-4, "skewed: the fundamental where it was, the highs from further on")
}
