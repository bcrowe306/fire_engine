package fx

import "core:math"

import "fire:core"

// EQ, the filter effect, the three-band compressor and the reverb.

// --- EQ ------------------------------------------------------------------------------------------

// What an EQ band is.
Eq_Mode :: enum u8 {
	Shelf, // the low and high bands: a shelf; the middle one: a bell
	Cut,   // the low band: a high-pass; the middle: a notch; the high: a low-pass
}

// An EQ band's settings.
Eq_Band :: struct {
	mode:      Eq_Mode,
	cutoff:    f32, // a key
	gain_db:   f32, // -15..15 (a shelf's or bell's)
	resonance: f32, // 0..1
}

// An EQ's settings: three bands, low to high.
Eq_Params :: struct {
	bands: [3]Eq_Band,
}

// Default EQ settings (flat).
EQ_DEFAULTS :: Eq_Params{bands = {{cutoff = 40, resonance = 0.3163}, {cutoff = 80, resonance = 0.4473}, {cutoff = 100, resonance = 0.3163}}}

// An EQ's state.
Eq :: struct {
	filters: [3]Filter_State,
}

// [rt] The filter an EQ band is.
eq_filter :: proc "contextless" (band: int, b: Eq_Band) -> Filter_Params {
	p := Filter_Params{model = .Digital, cutoff = b.cutoff, resonance = b.resonance, mix = 1, gain_db = b.gain_db}
	switch b.mode {
	case .Shelf:
		p.style = .Shelving
		p.blend = f32(band) // low shelf (0), bell (1), high shelf (2)
	case .Cut:
		switch band {
		case 0: p.style, p.blend = .Db12, 2 // high-pass
		case 1: p.style, p.blend = .Notch_Pass_Swap, 1 // notch
		case 2: p.style, p.blend = .Db12, 0 // low-pass
		}
	}
	return p
}

// [rt] Runs the EQ over `l` and `r` in place.
eq_render :: proc "contextless" (e: ^Eq, p: ^Eq_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	io := [2][]f32{l, r}
	for at := 0; at < n; at += 256 {
		m := min(256, n - at)
		part := [2][]f32{l[at:at + m], r[at:at + m]}
		for b in 0 ..< 3 {
			fp := eq_filter(b, p.bands[b])
			cut: [256]f32
			for &k in cut[:m] do k = fp.cutoff
			filter_render(&e.filters[b], &fp, cut[:m], &part, &part, sample_rate)
		}
	}
	_ = io
}

// --- Filter effect -------------------------------------------------------------------------------

// The filter effect's settings: any filter model, its mix included.
Filter_Fx_Params :: struct {
	filter: Filter_Params,
}

// The filter effect's state.
Filter_Fx :: struct {
	filter: Filter_State,
}

// [rt] Runs the filter effect over `l` and `r` in place.
filter_fx_render :: proc "contextless" (f: ^Filter_Fx, p: ^Filter_Fx_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	for at := 0; at < n; at += 256 {
		m := min(256, n - at)
		part := [2][]f32{l[at:at + m], r[at:at + m]}
		cut: [256]f32
		for &k in cut[:m] do k = p.filter.cutoff
		fp := p.filter
		filter_render(&f.filter, &fp, cut[:m], &part, &part, sample_rate)
	}
}

// --- Compressor ----------------------------------------------------------------------------------

// Which bands a compressor splits into.
Compressor_Bands :: enum u8 {
	Three,      // low (under 120 Hz), band, high (over 2.5 kHz)
	Low_Band,   // low and the rest
	Band_High,  // up to 2.5 kHz, and above
	One,        // all as one
}

// One band's settings: above the upper threshold it is pressed down by
// the upper ratio; below the lower threshold it is raised (a positive
// ratio) or pushed further down (negative); then its gain.
Compressor_Band :: struct {
	upper_db, lower_db: f32, // -80..0
	upper_ratio:        f32, // 0..1
	lower_ratio:        f32, // -1..1
	gain_db:            f32, // -30..30
}

// A compressor's settings.
Compressor_Params :: struct {
	bands:   Compressor_Bands,
	band:    [3]Compressor_Band, // low, band, high
	attack:  f32, // 0..1 (each band's own times, scaled by e^(8x-4))
	release: f32, // 0..1
	mix:     f32,
}

// Default compressor settings (squeezing and lifting all three bands).
COMPRESSOR_DEFAULTS :: Compressor_Params {
	bands = .Three,
	band  = {
		{upper_db = -28, lower_db = -35, upper_ratio = 0.9, lower_ratio = 0.8, gain_db = 16.3},
		{upper_db = -25, lower_db = -36, upper_ratio = 0.857, lower_ratio = 0.8, gain_db = 11.7},
		{upper_db = -30, lower_db = -35, upper_ratio = 1, lower_ratio = 0.8, gain_db = 16.3},
	},
	attack = 0.5, release = 0.5, mix = 1,
}

// The level (mean squared: -60 dB) below which a band is lifted no more
// (upward compression raises what is quiet, not what is silent).
@(private) LIFT_FLOOR :: 1e-6

// Each band's base attack and release (ms).
@(private) BAND_ATTACK_MS :: [3]f32{2.8, 1.4, 0.7}
@(private) BAND_RELEASE_MS :: [3]f32{40, 28, 15}

// A compressor's state: its crossovers, each band's levels, and the
// levels for a meter (`levels`: each band's input and output, mean
// squared).
Compressor :: struct {
	cross:   [2][2][4][2]f32, // [crossover][side][stage: low1, low2, high1, high2][state]
	key_cross: [2][2][4][2]f32, // the same, splitting a sidechain key
	upper, lower: [3][2]f32,  // each band's envelopes (mean squared), a side
	gain:    [3]f32,
	last_mix: f32,
	levels:  [3][2]f32, // [band][in, out]
	set:     bool,
}

// [rt] A 4th-order Linkwitz-Riley crossover at `g`: two Butterworth
// sections each way.
@(private)
crossover :: #force_inline proc "contextless" (st: ^[4][2]f32, x, g: f32) -> (low, high: f32) {
	l1, _ := butter(st[0][:], x, g)
	low, _ = butter(st[1][:], l1, g)
	_, h1 := butter(st[2][:], x, g)
	_, high = butter(st[3][:], h1, g)
	return
}

// [rt] Runs the compressor over `l` and `r` in place. With a key
// (`key_l`, `key_r`, as long as `l`), each band's level is the key's band
// instead of its own (a sidechain), and it only presses down.
compressor_render :: proc "contextless" (c: ^Compressor, p: ^Compressor_Params, l, r: []f32, sample_rate: f64, key_l: []f32 = nil, key_r: []f32 = nil) #no_bounds_check {
	n := len(l)
	if n == 0 do return
	sr := f32(sample_rate)
	g1 := math.tan(math.PI * min(120 / sr, 0.49))
	g2 := math.tan(math.PI * min(2500 / sr, 0.49))
	spm := sr / 1000
	att_x := math.exp(clamp(p.attack, 0, 1) * 8 - 4)
	rel_x := math.exp(clamp(p.release, 0, 1) * 8 - 4)
	att_ms, rel_ms := BAND_ATTACK_MS, BAND_RELEASE_MS
	type :: struct { att_s, rel_s, att_k, rel_k, up_t, lo_t, up_r, lo_r: f32 }
	b: [3]type
	for k in 0 ..< 3 {
		a := max(att_x * att_ms[k] * spm, 5)
		rr := max(rel_x * rel_ms[k] * spm, 5)
		up := math.pow(10, clamp(p.band[k].upper_db, -100, 12) / 20)
		lo := math.pow(10, clamp(p.band[k].lower_db, -100, 12) / 20)
		b[k] = {a, rr, 1 / (a + 1), 1 / (rr + 1), up * up, lo * lo, clamp(p.band[k].upper_ratio, 0, 1) * 0.5, clamp(p.band[k].lower_ratio, -1, 1) * 0.5}
	}
	gains: [3]f32
	for k in 0 ..< 3 do gains[k] = math.pow(10, clamp(p.band[k].gain_db, -30, 30) / 20)
	if !c.set {
		c.gain, c.last_mix = gains, p.mix
	}
	use := [3]bool{true, true, true}
	switch p.bands {
	case .Three:
	case .Low_Band:  use[2] = false // (the band and high as one: through the band's settings)
	case .Band_High: use[0] = false
	case .One:       use[0], use[2] = false, false
	}
	rms_k := 1 / (0.025 * sr)
	x := [2][]f32{l, r}
	keyed := len(key_l) >= n && len(key_r) >= n
	kx := [2][]f32{key_l, key_r}
	for i in 0 ..< n {
		u := f32(i + 1) / f32(n)
		mix := c.last_mix + (clamp(p.mix, 0, 1) - c.last_mix) * u
		for ch in 0 ..< 2 {
			in_ := x[ch][i]
			lo, rest := crossover(&c.cross[0][ch], in_, g1)
			band, hi := crossover(&c.cross[1][ch], rest, g2)
			parts := [3]f32{lo, band, hi}
			// Bands not split off go with the one beside them.
			if !use[0] {
				parts[1] += parts[0]
				parts[0] = 0
			}
			if !use[2] {
				parts[1] += parts[2]
				parts[2] = 0
			}
			// What each band's level is read from: itself, or the key's band.
			sense := parts
			if keyed {
				klo, krest := crossover(&c.key_cross[0][ch], kx[ch][i], g1)
				kband, khi := crossover(&c.key_cross[1][ch], krest, g2)
				sense = {klo, kband, khi}
				if !use[0] {
					sense[1] += sense[0]
					sense[0] = 0
				}
				if !use[2] {
					sense[1] += sense[2]
					sense[2] = 0
				}
			}
			out: f32 = 0
			for k in 0 ..< 3 {
				s := parts[k]
				if (k == 0 && !use[0]) || (k == 2 && !use[2]) do continue
				s2 := sense[k] * sense[k]
				bk := b[k]
				// The upper envelope (held at least at the threshold): above it, pressed down.
				attack := s2 > c.upper[k][ch]
				c.upper[k][ch] = (s2 + c.upper[k][ch] * (bk.att_s if attack else bk.rel_s)) * (bk.att_k if attack else bk.rel_k)
				c.upper[k][ch] = max(c.upper[k][ch], bk.up_t)
				up_mult := math.pow(bk.up_t / c.upper[k][ch], bk.up_r)
				// The lower one (held at most at its threshold): below it, raised.
				attack = s2 > c.lower[k][ch]
				c.lower[k][ch] = (s2 + c.lower[k][ch] * (bk.att_s if attack else bk.rel_s)) * (bk.att_k if attack else bk.rel_k)
				c.lower[k][ch] = min(c.lower[k][ch], bk.lo_t)
				// (Nothing is lifted from below the floor: a band with
				// nothing in it, a sub bass's highs say, isn't raised 40 dB
				// and more, which made a pop of a note's first tiny edge.)
				lo_mult := math.pow(bk.lo_t / max(c.lower[k][ch], LIFT_FLOOR), bk.lo_r)
				if keyed do lo_mult = 1 // (keyed, it only presses down: a quiet key lifts nothing)
				g := clamp(up_mult * lo_mult, 0, 32) * (c.gain[k] + (gains[k] - c.gain[k]) * u)
				y := s * g
				c.levels[k][0] += (s * s - c.levels[k][0]) * rms_k
				c.levels[k][1] += (y * y - c.levels[k][1]) * rms_k
				out += y
			}
			x[ch][i] = in_ + (out - in_) * mix
		}
	}
	c.gain, c.last_mix, c.set = gains, clamp(p.mix, 0, 1), true
}

// --- Reverb --------------------------------------------------------------------------------------

// A reverb's settings.
Reverb_Params :: struct {
	wet:        f32, // 0..1
	decay:      f32, // seconds (0.1..100)
	size:       f32, // 0..1
	delay:      f32, // seconds of pre-delay (0..0.3)
	pre_low:    f32, // a key: the input's high-pass
	pre_high:   f32, // a key: the input's low-pass
	low_cutoff, low_gain_db:   f32, // the tail's low shelf (key, -6..0 dB)
	high_cutoff, high_gain_db: f32, // the tail's high shelf
	chorus:     f32, // 0..1: how much the tail's delays wander
	chorus_hz:  f32,
}

// Default reverb settings.
REVERB_DEFAULTS :: Reverb_Params{wet = 0.25, decay = 1, size = 0.5, pre_low = 0, pre_high = 110, low_cutoff = 0, high_cutoff = 90, high_gain_db = -1, chorus = 0.05, chorus_hz = 0.25}

// The tail's sixteen delays (samples at 44.1 kHz), and the sixteen
// diffusers before them: lengths with no common factor, spread so the
// echoes don't line up.
@(private) REVERB_FEEDBACK :: [16]f32{3119, 3433, 3623, 4523, 5273, 5519, 5639, 6521, 6761, 7717, 7703, 8483, 9277, 9697, 11329, 4637}
@(private) REVERB_ALLPASS :: [16]int{1009, 797, 937, 877, 887, 811, 907, 853, 953, 1013, 709, 571, 829, 773, 661, 997}

@(private) REVERB_ALLPASS_FEEDBACK :: 0.6
@(private) REVERB_MAX_CHORUS :: 2500.0

// A reverb's state.
Reverb :: struct {
	feedback: [16]Line,
	allpass:  [16]Line,
	pre:      Line, // the pre-delay (stereo, interleaved as two lines)
	pre_r:    Line,
	pre_filters: [2][4]f32, // a side: the high-pass's and low-pass's poles
	shelves:  [16][4]f32,
	decays:   [16]f32,
	chorus_phase: f32,
	last:     [8]f32, // wet, dry, chorus, pre delay, low amp, high amp, low g, high g
	set:      bool,
	scale:    f32, // its delays' lengths against 44.1 kHz
}

// Control thread. A reverb for sample rates up to `max_rate`.
reverb_make :: proc(rv: ^Reverb, max_rate: f64, allocator := context.allocator) -> core.Error {
	scale := f32(max(max_rate / 44_100, 1))
	fb := REVERB_FEEDBACK
	ap := REVERB_ALLPASS
	for k in 0 ..< 16 {
		rv.feedback[k] = line_make(int(fb[k] * 2 * scale + REVERB_MAX_CHORUS * scale + 16), allocator) or_return
		rv.allpass[k] = line_make(int(f32(ap[k]) * scale + 16), allocator) or_return
	}
	rv.pre = line_make(int(0.3 * max_rate) + 16, allocator) or_return
	rv.pre_r = line_make(int(0.3 * max_rate) + 16, allocator) or_return
	return .None
}

// Control thread. Frees a reverb's lines.
reverb_destroy :: proc(rv: ^Reverb, allocator := context.allocator) {
	for &l in rv.feedback do line_destroy(&l, allocator)
	for &l in rv.allpass do line_destroy(&l, allocator)
	line_destroy(&rv.pre, allocator)
	line_destroy(&rv.pre_r, allocator)
}

// [rt] Runs the reverb over `l` and `r` in place: the input band-passed,
// diffused through an all-pass per line, into sixteen delays that feed
// each other (an orthogonal mix: a quarter of all, less half the line's
// row and column of the 4 × 4), shelved and decayed so the tail falls 60 dB in
// the decay time; their lengths scaled by the size and wandering with
// the chorus; out through a pre-delay, the lines alternating sides.
reverb_render :: proc "contextless" (rv: ^Reverb, p: ^Reverb_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	if n == 0 || len(rv.feedback[0].buf) == 0 do return
	sr := f32(sample_rate)
	ratio := sr / 44_100
	size_mult := math.pow(f32(2), clamp(p.size, 0, 1) * 4 - 3)
	decay_samples := clamp(p.decay, 0.1, 100) * 44_100
	fb := REVERB_FEEDBACK
	ap := REVERB_ALLPASS
	decays: [16]f32 // a loop's trip is its line and its diffuser
	for k in 0 ..< 16 do decays[k] = math.pow(f32(0.001), (size_mult * fb[k] + f32(ap[k])) / decay_samples)
	wet, dry := equal_power(p.wet)
	chorus := clamp(p.chorus, 0, 1) * REVERB_MAX_CHORUS * ratio
	lengths: [16]f32
	for k in 0 ..< 16 {
		lengths[k] = size_mult * fb[k] * ratio
		chorus = min(chorus, lengths[k] - 32)
	}
	chorus = max(chorus, 0)
	pre_delay := clamp(p.delay * sr, 3, line_max(&rv.pre))
	plo := pole_coefficient(clamp(key_to_hz(clamp(p.pre_low, 0, 130)), 1, sr * 0.45) / sr)
	phi := pole_coefficient(clamp(key_to_hz(clamp(p.pre_high, 0, 130)), 1, sr * 0.45) / sr)
	low_amp := 1 - math.pow(10, clamp(p.low_gain_db, -24, 0) / 20)
	high_amp := math.pow(10, clamp(p.high_gain_db, -24, 0) / 20)
	glo := pole_coefficient(clamp(key_to_hz(clamp(p.low_cutoff, 0, 130)), 1, sr * 0.45) / sr)
	ghi := pole_coefficient(clamp(key_to_hz(clamp(p.high_cutoff, 0, 130)), 1, sr * 0.45) / sr)
	now := [8]f32{wet, dry, chorus, pre_delay, low_amp, high_amp, glo, ghi}
	if !rv.set {
		rv.last = now
		rv.decays = decays
	}
	chorus_inc := clamp(p.chorus_hz, 0, 16) / sr
	x := [2][]f32{l, r}
	for i in 0 ..< n {
		u := f32(i + 1) / f32(n)
		v: [8]f32
		for k in 0 ..< 8 do v[k] = rv.last[k] + (now[k] - rv.last[k]) * u
		rv.chorus_phase += chorus_inc
		rv.chorus_phase -= math.floor(rv.chorus_phase)
		// The input, a side each: band-passed, a quarter of it into every
		// other line (the even lines the left's, the odd the right's).
		inputs: [2]f32
		for ch in 0 ..< 2 {
			pf := &rv.pre_filters[ch]
			below := pole_tick(&pf[0], &pf[1], x[ch][i], plo) // (what the high-pass takes away)
			lp := pole_tick(&pf[2], &pf[3], x[ch][i], phi)
			inputs[ch] = (lp - below) * 0.25
		}
		// Each line's delay out, through its diffuser.
		outs: [16]f32
		for k in 0 ..< 16 {
			ph := rv.chorus_phase * math.TAU + f32(k % 4) * math.TAU / 16
			wander := (math.cos(ph) if k / 4 < 2 else math.sin(ph)) * v[2] * (1 if k / 4 % 2 == 0 else -1)
			read := line_read(&rv.feedback[k], lengths[k] + wander)
			a := line_read(&rv.allpass[k], f32(ap[k]) * ratio)
			d := read - a * REVERB_ALLPASS_FEEDBACK
			line_push(&rv.allpass[k], inputs[k % 2] + d)
			outs[k] = a + d * REVERB_ALLPASS_FEEDBACK
		}
		// The mix between lines (sixteen as a 4 × 4 grid): each takes a
		// quarter of the total less half its row and half its column, an
		// orthogonal mix, so the tail neither grows nor dies but by its decay.
		total: f32 = 0
		rows, cols: [4]f32
		for k in 0 ..< 16 {
			total += outs[k]
			rows[k / 4] += outs[k]
			cols[k % 4] += outs[k]
		}
		sum_l, sum_r: f32
		for k in 0 ..< 16 {
			w := outs[k] + total * 0.25 - rows[k / 4] * 0.5 - cols[k % 4] * 0.5
			// The shelves: the high one turned down, the low one taken away.
			st := &rv.shelves[k]
			hf := pole_tick(&st[0], &st[1], w, v[7])
			w = hf + v[5] * (w - hf)
			lf := pole_tick(&st[2], &st[3], w, v[6])
			w -= lf * v[4]
			dk := rv.decays[k] + (decays[k] - rv.decays[k]) * u
			line_push(&rv.feedback[k], dk * w)
			if k % 2 == 0 do sum_l += w
			else do sum_r += w
		}
		line_push(&rv.pre, sum_l * 0.5)
		line_push(&rv.pre_r, sum_r * 0.5)
		x[0][i] = v[1] * x[0][i] + v[0] * line_read(&rv.pre, v[3])
		x[1][i] = v[1] * x[1][i] + v[0] * line_read(&rv.pre_r, v[3])
	}
	rv.last, rv.decays, rv.set = now, decays, true
}
