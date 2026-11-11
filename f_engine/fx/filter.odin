package fx

import "core:math"

// A synth voice's filter: one of eight models, each with styles, a
// cutoff (as a key, so modulation moves it in semitones), resonance,
// drive and a blend between its responses.
Filter_Model :: enum u8 {
	Analog,  // a Sallen-Key: two resonant poles (12 dB) or four (24 dB), driven into tanh
	Dirty,   // the analog's poles saturating inside the loop
	Ladder,  // four saturating poles with global feedback
	Digital, // a clean state-variable filter
	Diode,   // a diode ladder: high-pass before, a nastier resonance
	Formant, // four band-passes on a vowel's formants, moved by X and Y
	Comb,    // a tuned delay: combs and flangers
	Phaser,  // all-pass stages with resonance: peaks or notches
}

// A style: how the model is wired. Not every model has every style; each
// says which it takes (see `filter_styles`).
Filter_Style :: enum u8 {
	Db12,            // 12 dB: low, band and high by the blend
	Db24,            // 24 dB
	Notch_Pass_Swap, // low-pass to notch to high-pass
	Dual_Notch_Band, // two notches, the blend moving them
	Band_Peak_Notch, // band-pass to peak to notch
	Shelving,        // low shelf, peak, high shelf (Digital)
}

// What a filter does for one render (modulated, in its working units).
Filter_Params :: struct {
	model:      Filter_Model,
	style:      Filter_Style,
	cutoff:     f32, // as a key (8..136; 60 is middle C)
	resonance:  f32, // 0..1
	drive_db:   f32, // 0..20
	blend:      f32, // 0..2: low (0), band (1), high (2) for most styles
	mix:        f32, // 0..1: the dry signal against the filtered
	gain_db:    f32, // shelving: the shelf's gain
	formant_x, formant_y: f32, // 0..1: the vowel (Formant)
	formant_transpose:     f32, // semitones
	formant_resonance:     f32, // 0.3..1
	formant_spread:        f32, // -1..1
	comb_offset:           f32, // semitones the second comb sits above (0..84)
}

// Default filter settings.
FILTER_DEFAULTS :: Filter_Params{model = .Analog, style = .Db12, cutoff = 60, resonance = 0.5, mix = 1, formant_x = 0.5, formant_y = 0.5, formant_resonance = 0.85, comb_offset = 42}

// One filter of one voice: its model's state, a side each, and the
// coefficients it glides from. Zero it to reset.
Filter_State :: struct {
	model:   Filter_Model, // the model the state is for (a new one resets it)
	set:     bool,
	// The analog family's poles (Analog, Dirty: two pre, two main; Ladder,
	// Diode: four; Digital: two integrators), a side each.
	poles:   [2][24]f32,
	extra:   [2][4]f32,
	last:    Filter_Coeffs,
	formant: Formant_State,
	comb:    Comb_State,
	phaser:  Phaser_State,
}

// Values a model works from, computed once a render and glided.
@(private)
Filter_Coeffs :: struct {
	resonance, drive, post, low, band, high: f32,
	extra: [4]f32,
}

// [rt] The coefficient of a one-pole stage at `ratio` of the sample rate
// (a bilinear-style tangent, its argument folded so it stays below π/2
// right up to and beyond Nyquist).
@(private)
pole_coefficient :: #force_inline proc "contextless" (ratio: f32) -> f32 {
	s := ratio * math.PI
	return math.tan(min(0.499 * math.PI, s / (s + 1)))
}

// [rt] A fast tanh (a rational fit: within 0.1% of it, and ±1 beyond).
@(private)
fast_tanh :: #force_inline proc "contextless" (x: f32) -> f32 {
	if x > 4.97 do return 1
	if x < -4.97 do return -1
	x2 := x * x
	return x * (135135 + x2 * (17325 + x2 * (378 + x2))) / (135135 + x2 * (62370 + x2 * (3150 + x2 * 28)))
}

// [rt] A one-pole low-pass step, trapezoidal: `s` is (its state, its
// output); returns the output.
@(private)
pole_tick :: #force_inline proc "contextless" (state, out: ^f32, x, g: f32) -> f32 {
	d := g * (x - state^)
	state^ += d
	out^ = state^
	state^ += d
	return out^
}

// [rt] A one-pole coefficient across a render: its value at the first
// and last cutoffs (clamped to lo..hi Hz), the rest glided between (the
// cutoffs ramp straight within a render, so this is as good as working
// each out, at a fraction of the cost).
@(private)
Coef_Ramp :: struct {g0, dg: f32}

@(private)
coef_ramp :: #force_inline proc "contextless" (cutoff: []f32, sr, lo, hi: f32, svf := false, shift: f32 = 0) -> Coef_Ramp {
	n := len(cutoff)
	if n == 0 do return {}
	at :: #force_inline proc "contextless" (key, sr, lo, hi: f32, svf: bool) -> f32 {
		hz := clamp(key_to_hz(key), lo, hi)
		return math.tan(min(hz / sr, 0.499) * math.PI) if svf else pole_coefficient(hz / sr)
	}
	a := at(cutoff[0] + shift, sr, lo, hi, svf)
	b := at(cutoff[n - 1] + shift, sr, lo, hi, svf)
	return {a, (b - a) / f32(max(n - 1, 1))}
}

// [rt] The key a frequency is (key 69 is 440 Hz).
key_to_hz :: #force_inline proc "contextless" (key: f32) -> f32 {
	return 440 * math.pow(2, (key - 69) / 12)
}

// [rt] Filters `in_` (a channel each) into `out` with `p`, per sample at
// the cutoffs in `cutoff` (keys, one a sample: modulation is in them).
// `out` may be `in_`. Settings glide from the last render's across this
// one.
filter_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	if f.model != p.model || !f.set {
		m := p.model
		f^ = {}
		f.model = m
	}
	n := len(cutoff)
	switch p.model {
	case .Analog:         analog_render(f, p, cutoff, in_, out, sample_rate)
	case .Dirty:          dirty_render(f, p, cutoff, in_, out, sample_rate)
	case .Ladder:         ladder_render(f, p, cutoff, in_, out, sample_rate)
	case .Digital:        digital_render(f, p, cutoff, in_, out, sample_rate)
	case .Diode:          diode_render(f, p, cutoff, in_, out, sample_rate)
	case .Formant:        formant_render(f, p, cutoff, in_, out, sample_rate)
	case .Comb:           comb_render(f, p, cutoff, in_, out, sample_rate)
	case .Phaser:         phaser_render(f, p, cutoff, in_, out, sample_rate)
	}
	f.set = true
	// The mix: dry against filtered.
	if p.mix < 1 {
		m := clamp(p.mix, 0, 1)
		for ch in 0 ..< 2 do for i in 0 ..< n do out[ch][i] = in_[ch][i] + (out[ch][i] - in_[ch][i]) * m
	}
}

// --- Analog (and Dirty) --------------------------------------------------------------------------

@(private) ANALOG_MAX_RESONANCE :: 2.15
@(private) ANALOG_DRIVE_BOOST :: 1.1

// The analog family's coefficients from `p`: resonance (on a square-root
// curve, boosted by drive), drive (eased as resonance rises, so it stays
// in level), the low, band and high amounts the style and blend make,
// and the output gain that keeps the level even.
@(private)
analog_coeffs :: proc "contextless" (p: ^Filter_Params) -> (c: Filter_Coeffs) {
	res_pct := math.sqrt(clamp(p.resonance, 0, 1))
	drive_pct := clamp(p.drive_db, 0, 36) / 36
	drive := math.pow(10, clamp(p.drive_db, 0, 36) / 20)
	c.resonance = res_pct * ANALOG_MAX_RESONANCE + drive_pct * clamp(p.resonance, 0, 1) * ANALOG_DRIVE_BOOST
	blend := clamp(p.blend - 1, -1, 1)
	res_scale := res_pct * res_pct * 2 + 1
	c.drive = drive / res_scale
	#partial switch p.style {
	case .Dual_Notch_Band:
		t := blend * 0.5 + 0.5
		dt := min(1 - blend, 1)
		c.drive = drive + (c.drive * (2 - t) - drive) * dt
		c.low, c.band, c.high = t, 0, 1
	case .Notch_Pass_Swap:
		dt := abs(blend)
		c.drive = drive + (c.drive - drive) * dt
		c.low, c.band, c.high = min(1 - blend, 1), 0, min(blend + 1, 1)
	case .Band_Peak_Notch:
		dt := min(1 - blend, 1)
		c.drive = drive + (c.drive - drive) * dt
		inv := 1 - dt
		mult := math.sqrt(inv * inv * 0.5 + 0.5)
		peak := -max(-blend, 0)
		c.low = mult * (peak + 1)
		c.band = mult * (peak - blend + 1) * 2
		c.high = c.low
	case:
		c.band = math.sqrt(1 - blend * blend)
		c.low = -blend if blend < 0 else 0
		c.high = blend if blend > 0 else 0
	}
	c.post = 1 / math.sqrt(res_scale * c.drive)
	return
}

// [rt] The analog (Sallen-Key) filter: two one-pole stages in a
// resonant loop, its input driven through tanh. 24 dB runs a clean pair
// first, its low, band and high mixed, into it.
@(private)
analog_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	c := analog_coeffs(p)
	if !f.set do f.last = c
	l := f.last
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	nyq := f32(sample_rate) * 0.45
	style := p.style
	if style == .Shelving do style = .Db12
	cr := coef_ramp(cutoff, sr, 1, nyq)
	for ch in 0 ..< 2 {
		x := in_[ch]
		y := out[ch]
		st := &f.poles[ch]
		stage_in := &f.extra[ch][0]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			res := l.resonance + (c.resonance - l.resonance) * u
			drv := l.drive + (c.drive - l.drive) * u
			post := l.post + (c.post - l.post) * u
			lo := l.low + (c.low - l.low) * u
			bd := l.band + (c.band - l.band) * u
			hi := l.high + (c.high - l.high) * u
			g := cr.g0 + cr.dg * f32(i)
			g2 := 2 * g
			res = res / max(1, g2 * 0.09 + 0.97) // (tuned so it peaks alike at every cutoff)
			fb_mult := g2 - g * g - 1
			norm := 1 / (res * (g * g - g) + 1)
			v := x[i]
			if style != .Db12 {
				// The clean pre-stage, without resonance.
				pre_norm := 1 / ((g * g - g) + 1)
				fb := fb_mult * st[0] + (1 - g) * st[2]
				s1in := (v - fb) * pre_norm
				s1 := pole_tick(&st[0], &st[1], s1in, g)
				s2 := pole_tick(&st[2], &st[3], s1, g)
				band := s1 - s2
				high := s1in - s1 - band
				if style == .Dual_Notch_Band do v = lo * s2 + hi * high
				else do v = lo * s2 + bd * band + hi * high
			}
			// The resonant stage.
			fb := fb_mult * st[4] + (1 - g) * st[6]
			stage_in^ = fast_tanh((drv * v - res * fb) * norm)
			s1 := pole_tick(&st[4], &st[5], stage_in^, g)
			pole_tick(&st[6], &st[7], s1, g)
			low := st[7]
			band := s1 - low
			high := stage_in^ - s1 - band
			if style == .Dual_Notch_Band {
				high = stage_in^ - s1 - s1 + low
				y[i] = (hi * low + lo * high) * post
			} else {
				y[i] = (lo * low + bd * band + hi * high) * post
			}
		}
	}
	f.last = c
}
