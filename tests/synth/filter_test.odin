package test_synth

import "core:math"
import "core:testing"

import "fire:synth"
import kit "fire:testkit"

// Runs `x` (mono, both sides) through a filter at a steady cutoff key,
// in blocks of `block`; returns the left side (temporary allocator).
run_filter :: proc(p: synth.Filter_Params, x: []f32, key: f32, block := 128) -> []f32 {
	f := new(synth.Filter_State, context.temp_allocator)
	pp := p
	l := make([]f32, len(x), context.temp_allocator)
	r := make([]f32, len(x), context.temp_allocator)
	keys := make([]f32, block, context.temp_allocator)
	for &k in keys do k = key
	for at := 0; at < len(x); at += block {
		n := min(block, len(x) - at)
		in_ := [2][]f32{x[at:at + n], x[at:at + n]}
		out := [2][]f32{l[at:at + n], r[at:at + n]}
		synth.filter_render(f, &pp, keys[:n], &in_, &out, SR)
	}
	return l
}

sine :: proc(hz: f64, frames: int, amp: f32 = 0.5) -> []f32 {
	x := make([]f32, frames, context.temp_allocator)
	for &v, i in x do v = amp * f32(math.sin(math.TAU * hz * f64(i) / SR))
	return x
}

noise :: proc(frames: int) -> []f32 {
	x := make([]f32, frames, context.temp_allocator)
	s: u32 = 12345
	for &v in x {
		s = s * 1664525 + 1013904223
		v = f32(s >> 8) / f32(1 << 24) - 0.5
	}
	return x
}

// The level a sine at `hz` comes out at (its amplitude in, 0.5).
gain_at :: proc(p: synth.Filter_Params, hz: f64, key: f32) -> f64 {
	y := run_filter(p, sine(hz, 24_000, 0.25), key)
	return kit.tone_amplitude(y[12_000:], SR, hz) / 0.25
}

// The key for a frequency (69: 440 Hz).
key_of :: proc(hz: f64) -> f32 { return f32(69 + 12 * math.log2(hz / 440)) }

POLE_MODELS :: [?]synth.Filter_Model{.Analog, .Dirty, .Ladder, .Digital, .Diode}

// Every model, every style, at full resonance and drive on loud noise:
// finite and bounded.
@(test)
every_filter_stays_finite :: proc(t: ^testing.T) {
	x := noise(24_000)
	for &v in x do v *= 3
	for model in synth.Filter_Model {
		for style in 0 ..< 6 {
			p := synth.FILTER_DEFAULTS
			p.model = model
			p.style = synth.Filter_Style(style)
			p.resonance = 1
			p.drive_db = 20
			p.blend = 1
			p.gain_db = 15
			for key in ([]f32{20, 60, 100, 136}) {
				y := run_filter(p, x, key)
				n, _ := kit.count_non_finite(y)
				testing.expectf(t, n == 0 && kit.peak(y) < 50, "%v style %d at key %v: finite, bounded (peak %v)", model, style, key, kit.peak(y))
			}
		}
	}
}

// The pole models as low-passes (blend 0) keep what is below the cutoff
// and take away what is above; as high-passes (blend 2), the reverse.
@(test)
low_and_high_pass :: proc(t: ^testing.T) {
	for model in POLE_MODELS {
		for style in ([]synth.Filter_Style{.Db12, .Db24}) {
			p := synth.FILTER_DEFAULTS
			p.model, p.style, p.resonance = model, style, 0
			key := key_of(1000)
			if model != .Diode { // (the diode's blend moves its high-pass, not low to high)
				p.blend = 0
				lo, hi := gain_at(p, 100, key), gain_at(p, 8000, key)
				testing.expectf(t, lo > 0.5 && hi < lo * 0.2, "%v %v low-pass: 100 Hz %v, 8 kHz %v", model, style, lo, hi)
				p.blend = 2
				lo, hi = gain_at(p, 100, key), gain_at(p, 8000, key)
				testing.expectf(t, hi > 0.5 && lo < hi * 0.2, "%v %v high-pass: 100 Hz %v, 8 kHz %v", model, style, lo, hi)
			} else {
				lo, hi := gain_at(p, 200, key), gain_at(p, 8000, key)
				testing.expectf(t, hi < lo * 0.2, "diode %v: highs taken away (%v vs %v)", style, hi, lo)
			}
		}
	}
}

// Resonance makes the cutoff ring: a sine on the cutoff comes out louder
// with resonance high than with none.
@(test)
resonance_peaks_at_the_cutoff :: proc(t: ^testing.T) {
	for model in POLE_MODELS {
		p := synth.FILTER_DEFAULTS
		p.model, p.blend = model, 0
		key := key_of(800)
		p.resonance = 0
		flat := gain_at(p, 800, key)
		p.resonance = 0.9
		peak := gain_at(p, 800, key)
		testing.expectf(t, peak > flat * 1.5, "%v: resonance lifts the cutoff (%v to %v)", model, flat, peak)
	}
}

// The formant filter at the A corner passes A's first formant (600 Hz)
// far more than a frequency between formants; at the I corner, I's
// first formant (250 Hz) is the loudest of the two.
@(test)
formants_follow_the_vowel :: proc(t: ^testing.T) {
	p := synth.FILTER_DEFAULTS
	p.model = .Formant
	p.formant_x, p.formant_y = 0, 0 // A
	a600, a1500 := gain_at(p, 600, 60), gain_at(p, 1500, 60)
	testing.expectf(t, a600 > 3 * a1500, "A: 600 Hz over 1.5 kHz (%v, %v)", a600, a1500)
	p.formant_x, p.formant_y = 0, 1 // I (style 0: top left)
	i250, i600 := gain_at(p, 250, 60), gain_at(p, 600, 60)
	testing.expectf(t, i250 > 2 * i600, "I: 250 Hz over 600 (%v, %v)", i250, i600)
}

// A comb at 200 Hz with high resonance: its teeth on 200 Hz and its
// harmonics, gaps between.
@(test)
the_comb_rings_on_its_harmonics :: proc(t: ^testing.T) {
	p := synth.FILTER_DEFAULTS
	p.model, p.style, p.resonance, p.blend = .Comb, synth.Filter_Style(0), 0.95, 1
	key := key_of(200)
	tooth, gap := gain_at(p, 400, key), gain_at(p, 500, key)
	testing.expectf(t, tooth > 3 * gap, "a tooth at 400 Hz, a gap at 500 (%v, %v)", tooth, gap)
}

// The phaser with no resonance notches out its cutoff region against
// the input's level elsewhere (positive: the all-passes' half-cycle
// points cancel).
@(test)
the_phaser_notches :: proc(t: ^testing.T) {
	p := synth.FILTER_DEFAULTS
	p.model, p.resonance, p.blend = .Phaser, 0, 0
	key := key_of(1000)
	lows, mid := gain_at(p, 50, key), gain_at(p, 1000, key)
	testing.expectf(t, lows > 0.8, "far below, the input passes (%v)", lows)
	// Four all-passes at 1 kHz shift it a full cycle there: it adds; the
	// notch falls between.
	notch := 1.0
	for hz in ([]f64{300, 400, 500, 2000, 2500, 3000}) do notch = min(notch, gain_at(p, hz, key))
	testing.expectf(t, notch < 0.2, "somewhere around it, a notch (%v; at 1 kHz %v)", notch, mid)
}

// Shelving (Digital): the blend low lifts the lows by the gain.
@(test)
the_digital_shelf :: proc(t: ^testing.T) {
	p := synth.FILTER_DEFAULTS
	p.model, p.style, p.blend, p.gain_db = .Digital, .Shelving, 0, 12
	key := key_of(1000)
	lo, hi := gain_at(p, 80, key), gain_at(p, 10_000, key)
	testing.expectf(t, abs(20 * math.log10(lo) - 12) < 2 && abs(20 * math.log10(hi)) < 2, "low shelf +12 dB: lows %v dB, highs %v dB", 20 * math.log10(lo), 20 * math.log10(hi))
}

// Any block size, the same output, for every model.
@(test)
filters_are_block_size_invariant :: proc(t: ^testing.T) {
	x := noise(8000)
	for model in synth.Filter_Model {
		p := synth.FILTER_DEFAULTS
		p.model = model
		p.resonance = 0.7
		a := run_filter(p, x, 70, 256)
		b := run_filter(p, x, 70, 256) // (steady settings: block size can't matter)
		c := run_filter(p, x, 70, 31)
		worst: f32 = 0
		for i in 0 ..< len(a) do worst = max(worst, abs(a[i] - c[i]))
		testing.expectf(t, worst < 1e-4, "%v: 256 vs 31 at a time (off by %v)", model, worst)
		_ = b
	}
}
