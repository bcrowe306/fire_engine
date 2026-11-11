package test_synth

import "core:math"
import "core:testing"

import "fire:synth"

// Each source makes its cycle: harmonics a sine and a saw, lines a
// triangle-like wave through their points, a drawing as drawn, audio a
// slice from where it is set.
@(test)
table_keys_render :: proc(t: ^testing.T) {
	out := make([]f32, synth.WAVE_SIZE, context.temp_allocator)
	k := synth.table_key_default(.Harmonics)
	synth.table_key_render(&k, nil, out)
	worst: f32 = 0
	for v, i in out do worst = max(worst, abs(v - math.sin(math.TAU * f32(i) / synth.WAVE_SIZE)))
	testing.expectf(t, worst < 1e-4, "harmonic 1: a sine (%v)", worst)
	k.source = .Lines
	synth.table_key_render(&k, nil, out)
	testing.expectf(t, abs(out[synth.WAVE_SIZE / 4] - 1) < 1e-4 && abs(out[synth.WAVE_SIZE * 3 / 4] + 1) < 1e-4 && abs(out[0]) < 1e-4, "lines: through their points (%v %v %v)", out[0], out[512], out[1536])
	k.source = .Draw
	for &v, i in k.draw do v = 1 if i < synth.DRAW_POINTS / 2 else -1
	synth.table_key_render(&k, nil, out)
	testing.expectf(t, out[100] == 1 && out[1500] == -1, "drawn: as drawn")
	audio := make([]f32, 10_000, context.temp_allocator)
	for &v, i in audio do v = f32(i) / 10_000
	k.source = .Audio
	k.audio_at = 0.5
	synth.table_key_render(&k, audio, out)
	at := int(0.5 * f32(10_000 - synth.WAVE_SIZE))
	testing.expectf(t, out[0] == audio[at] && out[synth.WAVE_SIZE - 1] == audio[at + synth.WAVE_SIZE - 1], "audio: the cycle from halfway")
}

// A table of two keyframes: one frame for one keyframe; with two, the
// first and last frames are theirs; between, a crossfade is the mix of
// the waves, a spectral blend the mix of the harmonics' levels.
@(test)
table_docs_build :: proc(t: ^testing.T) {
	d := synth.table_doc_default()
	one := d
	one.count = 1
	single, _ := synth.table_doc_build("one", &one, nil)
	defer synth.wavetable_destroy(single)
	testing.expect_value(t, single.frames, 1)
	for blend in synth.Table_Blend {
		d.blend = blend
		tab, err := synth.table_doc_build("two", &d, nil)
		testing.expect_value(t, err, nil)
		defer synth.wavetable_destroy(tab)
		testing.expect_value(t, tab.frames, synth.WAVE_FRAMES)
		h := func_level
		testing.expectf(t, h(tab, 0, 2) < 1e-4, "%v: frame 0 a sine (no 2nd harmonic: %v)", blend, h(tab, 0, 2))
		testing.expectf(t, abs(h(tab, 255, 2) / h(tab, 255, 1) - 0.5) < 0.05, "%v: the last a saw (%v)", blend, h(tab, 255, 2) / h(tab, 255, 1))
		mid := h(tab, 128, 2) / h(tab, 255, 2)
		testing.expectf(t, mid > 0.3 && mid < 0.7, "%v: halfway, half the 2nd harmonic (%v)", blend, mid)
	}
	// Keyframes out of order are put in order; one in the middle is met there.
	d.keys[2] = synth.table_key_default(.Harmonics, 64)
	d.keys[2].levels[0], d.keys[2].levels[4] = 0, 1 // the 5th alone
	d.count = 3
	tab, _ := synth.table_doc_build("three", &d, nil)
	defer synth.wavetable_destroy(tab)
	testing.expectf(t, func_level(tab, 64, 5) > 0.3 && func_level(tab, 64, 1) < 0.01, "a keyframe at frame 64: its sound there")
}

// The level of harmonic `k` in frame `f`.
@(private = "file")
func_level :: proc(tab: ^synth.Wavetable, f, k: int) -> f32 {
	return abs(tab.spectra[f][k]) * 2
}
