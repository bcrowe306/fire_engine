package fx

import "core:math"

// The filters that aren't pole ladders: Formant, Comb and Phaser. Their
// `Filter_Params.style` is a number of their own (see each).

// --- Formant -------------------------------------------------------------------------------------

// A vowel's four formants: centre (Hz) and level (dB). From the commonly
// published bass-voice formant table (as in Csound's manual).
@(private)
Vowel :: struct {
	hz: [4]f32,
	db: [4]f32,
}

@(private) VOWEL_A :: Vowel{{600, 1040, 2250, 2450}, {0, -7, -9, -9}}
@(private) VOWEL_E :: Vowel{{400, 1620, 2400, 2800}, {0, -12, -9, -12}}
@(private) VOWEL_I :: Vowel{{250, 1750, 2600, 3050}, {0, -30, -16, -22}}
@(private) VOWEL_O :: Vowel{{400, 750, 2400, 2600}, {0, -11, -21, -20}}
@(private) VOWEL_U :: Vowel{{350, 600, 2400, 2675}, {0, -20, -32, -28}}

// How sharp each formant is (a share of the formant resonance).
@(private) FORMANT_Q :: [4]f32{0.7, 0.75, 0.9, 0.9}

// The key the formants spread toward (or away from).
@(private) FORMANT_CENTRE :: 80.0

// Formant styles: the vowels at the corners of the X/Y square (bottom
// left, bottom right, top left, top right).
FORMANT_STYLES :: [2][4]string{{"A", "O", "I", "E"}, {"A", "I", "U", "O"}}

@(private)
formant_corners :: proc "contextless" (style: int) -> [4]Vowel {
	if style == 1 do return {VOWEL_A, VOWEL_I, VOWEL_U, VOWEL_O}
	return {VOWEL_A, VOWEL_O, VOWEL_I, VOWEL_E}
}

// A formant filter's state: four state-variable filters a side, and the
// settings it glides from.
Formant_State :: struct {
	ic:   [2][4][2]f32,
	last: [4][3]f32, // each formant's key, damping, gain
}

// [rt] The formant filter: four band-passes, each on a formant of the
// vowel at X and Y (between four vowels), moved by the transpose and
// spread toward key 80, their sharpness from the formant resonance.
// `p.style` 0 has A O I E at the corners, 1 A I U O.
@(private)
formant_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	corners := formant_corners(int(p.style))
	x, y := clamp(p.formant_x, 0, 1), clamp(p.formant_y, 0, 1)
	bilerp :: proc "contextless" (bl, br, tl, tr, x, y: f32) -> f32 {
		bot := bl + (br - bl) * x
		top := tl + (tr - tl) * x
		return bot + (top - bot) * y
	}
	qs := FORMANT_Q
	now: [4][3]f32
	for k in 0 ..< 4 {
		key := bilerp(hz_key(corners[0].hz[k]), hz_key(corners[1].hz[k]), hz_key(corners[2].hz[k]), hz_key(corners[3].hz[k]), x, y)
		db := bilerp(corners[0].db[k], corners[1].db[k], corners[2].db[k], corners[3].db[k], x, y)
		key = key + (FORMANT_CENTRE - key) * clamp(p.formant_spread, -1, 1) + p.formant_transpose
		rp := clamp(qs[k] * clamp(p.formant_resonance, 0.3, 1), 0, 1)
		rp = rp * rp * rp
		now[k] = {key, 1 / (SVF_MIN_RESONANCE + (SVF_MAX_RESONANCE - SVF_MIN_RESONANCE) * rp), math.pow(10, db / 20)}
	}
	fs := &f.formant
	if !f.set do fs.last = now
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	g0, g1: [4]f32
	for k in 0 ..< 4 {
		g0[k] = math.tan(min(key_to_hz(fs.last[k][0]) / sr, 0.499) * math.PI)
		g1[k] = math.tan(min(key_to_hz(now[k][0]) / sr, 0.499) * math.PI)
	}
	for ch in 0 ..< sides(p) {
		src, dst := in_[ch], out[ch]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			acc: f32 = 0
			for k in 0 ..< 4 {
				damp := fs.last[k][1] + (now[k][1] - fs.last[k][1]) * u
				gain := fs.last[k][2] + (now[k][2] - fs.last[k][2]) * u
				g := g0[k] + (g1[k] - g0[k]) * u
				acc += hard_tanh(svf_step(fs.ic[ch][k][:], src[i], g, damp, {0, 1, 0})) * gain
			}
			dst[i] = acc
		}
	}
	fs.last = now
}

// The key a frequency is.
@(private)
hz_key :: proc "contextless" (hz: f32) -> f32 {
	return 69 + 12 * math.log2(hz / 440)
}

// --- Comb ----------------------------------------------------------------------------------------

// Samples of delay a comb can hold (a side): enough for the lowest
// cutoff (key 8, 13.75 Hz) at 48 kHz.
COMB_SIZE :: 4096

// Comb styles (`Filter_Params.style` for the Comb model): feedback (comb,
// a positive flange, a negative flange) by filter (a low/high blend, or a
// band whose width the blend sets).
COMB_STYLES :: [6]string{"Low High Comb", "Low High Flange+", "Low High Flange-", "Band Spread Comb", "Band Spread Flange+", "Band Spread Flange-"}

// A comb's state: its delay lines, its two filters a side, and the
// settings it glides from.
Comb_State :: struct {
	memory: [2][COMB_SIZE]f32,
	at:     int,
	poles:  [2][4]f32,
	last:   [6]f32, // feedback, scale, coefficient 1, coefficient 2, low gain, high gain
}

// [rt] The comb filter: a delay tuned to the cutoff (its period), fed back
// through a low-pass and a high-pass (blended low to high, or a band
// spread around the offset above the cutoff), the feedback soft-clipped.
// A flange reads half a period back, adding (+) or taking away (-).
@(private)
comb_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	FLANGE_SCALE :: 0.70710678119
	style := clamp(int(p.style), 0, 5)
	feedback_style := style % 3
	band := style / 3 == 1
	res := clamp(p.resonance, 0, 1)
	fb, scale: f32
	if feedback_style == 0 {
		fb = -1 + 2 * res
		fb /= math.sqrt(abs(fb) + 0.00001)
		scale = 1 - fb * fb * 0.5
	} else {
		fb = res
		scale = 1 / (fb + 1)
	}
	sr := f32(sample_rate)
	nyq := sr * 0.45
	n := len(cutoff)
	key := cutoff[n - 1] if n > 0 else 60
	min_key := key - 48
	g1, g2, low_gain, high_gain: f32
	if band {
		centre := key + p.comb_offset
		width := p.blend * 0.5 * 8 * 12
		f1 := clamp(key_to_hz(centre + width), 1, sr / 2.1)
		f2 := clamp(key_to_hz(max(min_key, centre - width)), 1, sr / 2.1)
		low_gain, high_gain = f2 / f1 + 1, 0
		g1, g2 = pole_coefficient(f1 / sr), pole_coefficient(f2 / sr)
	} else {
		low_gain = clamp(2 - p.blend, 0, 1)
		high_gain = clamp(p.blend, 0, 1)
		g1 = pole_coefficient(clamp(key_to_hz(key + p.comb_offset), 1, nyq) / sr)
		g2 = pole_coefficient(clamp(key_to_hz(min_key), 1, nyq) / sr)
	}
	now := [6]f32{fb, scale, g1, g2, low_gain, high_gain}
	cs := &f.comb
	if !f.set do cs.last = now
	l := cs.last
	inv := 1 / f32(max(n, 1))
	min_period: f32 = 4 if feedback_style == 2 else 2
	max_period := f32(COMB_SIZE - 5)
	at := cs.at
	period0 := clamp(sr / key_to_hz(cutoff[0]), min_period, max_period) if n > 0 else min_period
	period1 := clamp(sr / key_to_hz(cutoff[n - 1]), min_period, max_period) if n > 0 else min_period
	for ch in 0 ..< sides(p) {
		mem := &cs.memory[ch]
		st := &cs.poles[ch]
		src, dst := in_[ch], out[ch]
		at = cs.at
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			v: [6]f32
			for k in 0 ..< 6 do v[k] = l[k] + (now[k] - l[k]) * u
			period := period0 + (period1 - period0) * f32(i) / f32(max(n - 1, 1))
			if feedback_style == 2 do period *= 0.5
			if feedback_style == 1 do period *= 0.5
			read := comb_read(mem, at, period)
			x := src[i]
			r: f32
			filt :: proc "contextless" (st: ^[4]f32, x: f32, v: [6]f32) -> f32 {
				lo := pole_tick(&st[0], &st[1], x, v[2])
				hi := x - lo
				s1 := v[4] * lo + v[5] * hi
				s2 := pole_tick(&st[2], &st[3], s1, v[3])
				return s1 - s2
			}
			switch feedback_style {
			case 0:
				o := filt(st, v[1] * x + read * v[0], v)
				mem[at] = hard_tanh(o)
				r = o
			case 1:
				fo := filt(st, read, v)
				sx := x * FLANGE_SCALE
				mem[at] = sx + hard_tanh(fo * v[0])
				r = sx * v[1] + fo
			case:
				fo := filt(st, read, v)
				sx := x * FLANGE_SCALE
				mem[at] = sx - hard_tanh(fo * v[0])
				r = sx * v[1] - fo
			}
			dst[i] = r
			at = (at + 1) & (COMB_SIZE - 1)
		}
	}
	cs.at = at
	cs.last = now
}

// [rt] The delay line `past` samples back from `at` (the next write),
// read with a Catmull-Rom cubic.
@(private)
comb_read :: #force_inline proc "contextless" (mem: ^[COMB_SIZE]f32, at: int, past: f32) -> f32 #no_bounds_check {
	whole := int(past)
	t := f32(whole) - past + 1
	MASK :: COMB_SIZE - 1
	i := at - whole - 2
	p0 := mem[(i) & MASK]
	p1 := mem[(i + 1) & MASK]
	p2 := mem[(i + 2) & MASK]
	p3 := mem[(i + 3) & MASK]
	return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
}

// --- Phaser --------------------------------------------------------------------------------------

// Phaser styles (`Filter_Params.style` for the Phaser model).
PHASER_STYLES :: [2]string{"Positive", "Negative"}

// A phaser's state: twelve all-pass stages a side, two filters that
// keep its feedback in a band, and its last output.
Phaser_State :: struct {
	stages:   [2][12][2]f32,
	clean:    [2][4]f32,
	feedback: [2]f32,
	last:     [5]f32, // resonance, drive, peak 1, peak 3, peak 5
}

// [rt] The phaser: twelve first-order all-passes at the cutoff in three
// groups of four; the blend picks the output after four, eight or twelve
// (one, three or five peaks), which feeds back with the resonance
// (band-passed around the cutoff). Mixed with the input: peaks, or with
// style 1 (negative) notches.
@(private)
phaser_filter_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	CLEAR :: 20.0
	res := clamp(p.resonance, 0, 1)
	drv := math.pow(10, clamp(p.drive_db, 0, 36) / 20)
	p1 := clamp(1 - p.blend, 0, 1)
	p5 := clamp(p.blend - 1, 0, 1)
	now := [5]f32{res, (res * 0.5 + 1) * drv, p1, 1 - p1 - p5, p5}
	invert: f32 = -1 if p.style != .Db12 else 1
	ps := &f.phaser
	if !f.set do ps.last = now
	l := ps.last
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	nyq := sr * 0.45
	cr := coef_ramp(cutoff, sr, 1, nyq)
	for ch in 0 ..< sides(p) {
		src, dst := in_[ch], out[ch]
		st := &ps.stages[ch]
		cl := &ps.clean[ch]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			v: [5]f32
			for k in 0 ..< 5 do v[k] = l[k] + (now[k] - l[k]) * u
			g := cr.g0 + cr.dg * f32(i)
			lows := pole_tick(&cl[0], &cl[1], ps.feedback[ch], min(g * CLEAR, 0.9))
			highs := pole_tick(&cl[2], &cl[3], lows, g * (1 / CLEAR))
			state := v[0] * (lows - highs)
			x: f32
			if p.clean { // (the phaser effect's: resonance saturated, the input not)
				state = fast_tanh(state)
				x = v[1] * src[i] + invert * state
			} else {
				x = hard_tanh(v[1] * src[i] + invert * state)
			}
			outs: [3]f32
			for grp in 0 ..< 3 {
				for k in 0 ..< 4 {
					s := &st[grp * 4 + k]
					lp := pole_tick(&s[0], &s[1], x, g)
					x = x - 2 * lp
				}
				outs[grp] = x
			}
			ps.feedback[ch] = v[2] * outs[0] + v[3] * outs[1] + v[4] * outs[2]
			dst[i] = (src[i] + invert * ps.feedback[ch]) * 0.5
		}
	}
	ps.last = now
}
