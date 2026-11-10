package test_dsp

import "core:math"
import "core:testing"

import "fire:dsp"
import kit "fire:testkit"

// Decaying noise hits at `at` (frames), with `levels`.
hits :: proc(frames: int, at: []int, levels: []f32) -> []f32 {
	x := make([]f32, frames, context.temp_allocator)
	noise := make([]f32, frames, context.temp_allocator)
	kit.white_noise(noise, 3, 1)
	for a, h in at {
		for i in a ..< frames {
			x[i] += levels[h] * noise[i] * math.exp(-f32(i - a) / 2400)
		}
	}
	return x
}

@(test)
onsets_find_hits :: proc(t: ^testing.T) {
	at := []int{0, 12_000, 24_000, 30_000, 40_000}
	x := hits(48_000, at, {0.8, 0.6, 0.9, 0.4, 0.7})
	got, err := dsp.detect_onsets(x, 48_000, {}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, len(got) == len(at), "found %d onsets (want %d): %v", len(got), len(at), got)
	for a, i in at do if i < len(got) {
		testing.expectf(t, got[i] <= i64(a) + 64 && got[i] >= i64(a) - 768, "onset %d at %d (hit at %d): starts before, never after, the attack", i, got[i], a)
	}
}

@(test)
onsets_sensitivity_and_silence :: proc(t: ^testing.T) {
	silent := make([]f32, 48_000, context.temp_allocator)
	none, _ := dsp.detect_onsets(silent, 48_000, {}, context.temp_allocator)
	testing.expect_value(t, len(none), 0)

	// A loud hit and one 15 dB quieter: low sensitivity finds only the loud one.
	x := hits(48_000, {0, 24_000}, {0.9, 0.16})
	low, _ := dsp.detect_onsets(x, 48_000, {sensitivity = 0.1}, context.temp_allocator)
	high, _ := dsp.detect_onsets(x, 48_000, {sensitivity = 0.9}, context.temp_allocator)
	testing.expectf(t, len(low) == 1, "low sensitivity: the loud hit only (%v)", low)
	testing.expectf(t, len(high) == 2, "high sensitivity: both (%v)", high)

	// A steady tone has one onset (its start), however long it lasts.
	tone := make([]f32, 96_000, context.temp_allocator)
	kit.sine(tone, 48_000, 220, 0.5)
	one, _ := dsp.detect_onsets(tone, 48_000, {}, context.temp_allocator)
	testing.expectf(t, len(one) == 1 && one[0] == 0, "a tone: one onset at 0 (%v)", one)
}
