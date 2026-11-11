package fx

import "core:math"

// The pole-based filters that saturate inside: Dirty, Ladder and Diode.

// How a one-pole stage saturates its state.
@(private)
Sat :: enum u8 {None, Tanh, Quick, Algebraic, Clip}

// [rt] Saturates `x` the way `kind` does.
@(private)
saturate :: #force_inline proc "contextless" (x: f32, kind: Sat) -> f32 {
	switch kind {
	case .None:      return x
	case .Tanh:      return fast_tanh(x)
	case .Quick:     return quick_tanh(x)
	case .Algebraic: x2 := x * x; return x - x * x2 * 0.9 / (x2 + 3)
	case .Clip:      return clamp(x, -1, 1)
	}
	return x
}

// [rt] A one-pole stage that saturates its state: `st` holds its state,
// its output and its saturated state (what feedback reads).
@(private)
sat_tick :: #force_inline proc "contextless" (st: []f32, x, g: f32, kind: Sat) -> f32 #no_bounds_check {
	d := g * (x - st[2])
	st[0] += d
	st[1] = saturate(st[0], kind)
	st[0] += d
	st[2] = saturate(st[0], kind)
	return st[1]
}

// The low, band and high amounts (and how much the drive is eased) a
// style and blend give the analog family.
@(private)
pass_amounts :: proc "contextless" (style: Filter_Style, blend_in: f32) -> (low, band, high, drive_blend, drive_mult: f32) {
	blend := clamp(blend_in - 1, -1, 1)
	drive_blend, drive_mult = 1, 1
	#partial switch style {
	case .Dual_Notch_Band:
		t := blend * 0.5 + 0.5
		drive_blend = min(1 - blend, 1)
		drive_mult = 2 - t
		low, band, high = t, 0, 1
	case .Notch_Pass_Swap:
		drive_blend = abs(blend)
		low, band, high = min(1 - blend, 1), 0, min(blend + 1, 1)
	case .Band_Peak_Notch:
		drive_blend = min(1 - blend, 1)
		inv := 1 - drive_blend
		mult := math.sqrt(inv * inv * 0.5 + 0.5)
		peak := -max(-blend, 0)
		low = mult * (peak + 1)
		band = mult * (peak - blend + 1) * 2
		high = low
	case:
		band = math.sqrt(1 - blend * blend)
		low = -blend if blend < 0 else 0
		high = blend if blend > 0 else 0
	}
	return
}

// --- Dirty ---------------------------------------------------------------------------------------

@(private) DIRTY_MIN_RESONANCE :: 0.1
@(private) DIRTY_MAX_RESONANCE :: 2.15
@(private) DIRTY_SATURATION :: 1.4
@(private) DIRTY_DRIVE_BOOST :: 0.05
@(private) DIRTY_MIN_DRIVE :: 0.1

// [rt] The dirty filter: two clean poles (four at 24 dB) make the low,
// band and high, which feed a loop of two saturating poles driven
// through tanh: the resonance lives in that loop, so it growls.
@(private)
dirty_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	c: Filter_Coeffs
	drive_db := clamp(p.drive_db, 0, 36)
	c.resonance = math.sqrt(clamp(p.resonance, 0, 1))
	c.drive = (math.pow(10, drive_db / 20) - 1) * 2 + 1
	c.extra[0] = drive_db / 36 * DIRTY_DRIVE_BOOST
	c.low, c.band, c.high, c.extra[1], c.extra[2] = pass_amounts(p.style, p.blend)
	if !f.set do f.last = c
	l := f.last
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	nyq := sr * 0.45
	style := p.style
	cr := coef_ramp(cutoff, sr, 1, nyq)
	for ch in 0 ..< sides(p) {
		x, y := in_[ch], out[ch]
		st := f.poles[ch][:]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			lerp :: #force_inline proc "contextless" (a, b, u: f32) -> f32 { return a + (b - a) * u }
			g := cr.g0 + cr.dg * f32(i)
			g2 := g * g
			res_in := clamp(lerp(l.resonance, c.resonance, u) / max(1, 2 * g * 0.25 + 0.97), 0, 1)
			res := DIRTY_MIN_RESONANCE + (DIRTY_MAX_RESONANCE - DIRTY_MIN_RESONANCE) * res_in + lerp(l.extra[0], c.extra[0], u)
			r2 := res * res
			norm := DIRTY_SATURATION / (r2 + 1)
			drv := lerp(l.drive, c.drive, u)
			scaled := max(DIRTY_MIN_DRIVE, drv) / (r2 * 0.5 + 1)
			if style == .Dual_Notch_Band do scaled *= lerp(l.extra[2], c.extra[2], u)
			drive := drv + (scaled - drv) * lerp(l.extra[1], c.extra[1], u)
			lo, bd, hi := lerp(l.low, c.low, u), lerp(l.band, c.band, u), lerp(l.high, c.high, u)
			v := x[i]
			fb_mult: f32
			if style == .Db12 || style == .Shelving {
				fb_mult = 1 / ((1 - res * (g - g2)) * (g + 1))
			} else {
				// The clean pre-stage (no feedback of its own).
				fb_mult = 1 / ((res * (g2 - g) + 1) * (g + 1))
				pre_norm := 1 / ((g2 - g) + 1)
				s1in := v * pre_norm
				s1 := pole_tick(&st[0], &st[1], s1in, g)
				s2 := pole_tick(&st[2], &st[3], s1, g)
				band := s1 - s2
				high := s1in - s1 - band
				if style == .Dual_Notch_Band {
					v = lo * high + hi * s2
					bd = 0
				} else {
					v = bd * band + hi * high + lo * s2
				}
			}
			// The main poles, then the loop.
			s1in := norm * v
			s1 := pole_tick(&st[4], &st[5], s1in, g)
			s2 := pole_tick(&st[6], &st[7], s1, g)
			band := s1 - s2
			high := s1in - s1 - band
			pass := lo * s2 + bd * band + hi * high
			feedback := st[13] + pass + g * (pass - st[10])
			loop_in := fast_tanh(drive * pass + res * fb_mult * feedback)
			s3 := sat_tick(st[8:11], loop_in, g, .Quick)
			sat_tick(st[11:14], loop_in - s3, g, .Quick)
			y[i] = loop_in * (1 / DIRTY_SATURATION)
		}
	}
	f.last = c
}

// --- Ladder --------------------------------------------------------------------------------------

@(private) LADDER_TUNING :: 1.66
@(private) LADDER_MIN_RESONANCE :: 0.001
@(private) LADDER_MAX_RESONANCE :: 4.1
@(private) LADDER_DRIVE_BOOST :: 5.0

// The ladder's mix of its input and four poles a style and blend make
// (low, band, high as sums of the stages), and its drive and level.
@(private)
ladder_scales :: proc "contextless" (p: ^Filter_Params) -> (scales: [5]f32, drive, post, resonance: f32) {
	LOW24 :: [5]f32{0, 0, 0, 0, 1}
	BAND24 :: [5]f32{0, 0, -1, 2, -1}
	HIGH24 :: [5]f32{1, -4, 6, -4, 1}
	LOW12 :: [5]f32{0, 0, 1, 0, 0}
	BAND12 :: [5]f32{0, 1, -1, 0, 0}
	HIGH12 :: [5]f32{1, -2, 1, 0, 0}
	res_pct := clamp(p.resonance, 0, 1)
	smooth := p.style != .Db12 // (every style but 12 dB eases the resonance in)
	adj := math.sin(res_pct * math.PI / 2) if smooth else res_pct
	drive_db := clamp(p.drive_db, 0, 36)
	drv := math.pow(10, drive_db / 20)
	resonance = LADDER_MIN_RESONANCE + (LADDER_MAX_RESONANCE - LADDER_MIN_RESONANCE) * adj + drive_db / 36 * res_pct * LADDER_DRIVE_BOOST
	blend := clamp(p.blend - 1, -1, 1)
	band := math.sqrt(1 - blend * blend)
	low := -blend if blend < 0 else 0
	high := blend if blend > 0 else 0
	drive_mult := (math.sin(res_pct) if smooth else res_pct) + 1
	drive = drv * (drive_mult + (1 - drive_mult) * high)
	post = 1 / math.sqrt((drv - 1) * 0.5 + 1)
	#partial switch p.style {
	case .Db24:
		band = 1 - abs(blend)
		post = 1 / math.sqrt((drv - 1) * 0.25 + 1)
		scales = low * LOW24 + band * BAND24 + high * HIGH24
	case .Dual_Notch_Band:
		drive = drv
		lf, hf := min(blend + 1, 1), min(1 - blend, 1)
		scales = {lf, lf * -4, hf * 4 + lf * 8, hf * -8 - lf * 8, hf * 4 + lf * 4}
	case .Notch_Pass_Swap:
		lf, hf := min(blend + 1, 1), min(1 - blend, 1)
		lf2, hf2, lh := lf * lf, hf * hf, lf * hf
		scales = {lf2, lf2 * -4, lf2 * 6 + lh * 2, lf2 * -4 - lh * 4, lf2 + hf2 + lh * 2}
	case .Band_Peak_Notch:
		dt := min(1 - blend, 1)
		drive = drv + (drive - drv) * dt
		inv := 1 - dt
		mult := math.sqrt(inv * inv * 0.5 + 0.5)
		peak := -max(-blend, 0)
		lh := mult * (peak + 1)
		bd := mult * (peak - blend + 1) * 2
		scales = lh * LOW12 + bd * BAND12 + lh * HIGH12
	case:
		scales = low * LOW12 + band * BAND12 + high * HIGH12
	}
	return
}

// [rt] The ladder: four saturating poles with feedback from all of them
// (weighted so it rings at the cutoff), the input through tanh; its
// output a mix of the input and the poles (low, band, high and notches
// are sums of them).
@(private)
ladder_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	sc, drive, post, res := ladder_scales(p)
	c := Filter_Coeffs{resonance = res, drive = drive, post = post, low = sc[0], band = sc[1], high = sc[2], extra = {sc[3], sc[4], 0, 0}}
	if !f.set do f.last = c
	l := f.last
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	top := min(20_000, sr * 0.45)
	cr := coef_ramp(cutoff, sr, 1, top)
	for ch in 0 ..< sides(p) {
		x, y := in_[ch], out[ch]
		st := f.poles[ch][:]
		input := &f.extra[ch][0]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			lerp :: #force_inline proc "contextless" (a, b, u: f32) -> f32 { return a + (b - a) * u }
			g := cr.g0 + cr.dg * f32(i)
			g1 := g * LADDER_TUNING
			g2 := g1 * g1
			g3 := g1 * g2
			state := st[11] + g1 * st[8] + g2 * st[5] + g3 * st[2]
			input^ = fast_tanh(x[i] * lerp(l.drive, c.drive, u) - lerp(l.resonance, c.resonance, u) * state)
			o := sat_tick(st[0:3], input^, g, .Algebraic)
			o1 := o
			o = sat_tick(st[3:6], o, g, .Algebraic)
			o2 := o
			o = sat_tick(st[6:9], o, g, .Algebraic)
			o3 := o
			o4 := sat_tick(st[9:12], o, g, .Algebraic)
			total := lerp(l.low, c.low, u) * input^ + lerp(l.band, c.band, u) * o1 + lerp(l.high, c.high, u) * o2 + lerp(l.extra[0], c.extra[0], u) * o3 + lerp(l.extra[1], c.extra[1], u) * o4
			y[i] = total * lerp(l.post, c.post, u)
		}
	}
	f.last = c
}

// --- Diode ---------------------------------------------------------------------------------------

@(private) DIODE_MIN_RESONANCE :: 0.7
@(private) DIODE_MAX_RESONANCE :: 17.0
@(private) DIODE_HIGH_PASS_HZ :: 20.0

// [rt] The diode ladder: a two-pole high-pass first (its cutoff a ratio
// of the main one, set by the blend; at 12 dB fixed and blended in), then
// four poles that average their neighbours, a resonant feedback through
// tanh, and a 20 Hz high-pass in the loop to keep it centred.
@(private)
diode_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	HP_START :: -9.0
	HP_END :: -1.0
	c: Filter_Coeffs
	rp := clamp(p.resonance, 0, 1)
	rp = rp * rp * rp
	drv := math.pow(10, clamp(p.drive_db, 0, 36) / 20)
	c.resonance = DIODE_MIN_RESONANCE + (DIODE_MAX_RESONANCE - DIODE_MIN_RESONANCE) * rp
	c.drive = (c.resonance * 0.5 + 1) * drv
	c.post = 1 / math.sqrt(drv)
	b := p.blend * 0.5
	if p.style == .Db12 {
		c.extra[0] = math.pow(2, f32(HP_END))
		c.extra[1] = b * b
	} else {
		c.extra[0] = math.pow(2, b * (HP_END - HP_START) + HP_START)
		c.extra[1] = 1
	}
	if !f.set do f.last = c
	l := f.last
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	nyq := sr * 0.45
	hp_fb_g := pole_coefficient(DIODE_HIGH_PASS_HZ / sr)
	cr := coef_ramp(cutoff, sr, 1, nyq)
	for ch in 0 ..< sides(p) {
		x, y := in_[ch], out[ch]
		st := f.poles[ch][:]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			lerp :: #force_inline proc "contextless" (a, b, u: f32) -> f32 { return a + (b - a) * u }
			g := cr.g0 + cr.dg * f32(i)
			// The high-pass before it.
			hg := g * lerp(l.extra[0], c.extra[0], u)
			hfb_mult := 2 * hg - hg * hg - 1
			hnorm := 1 / (hg * hg - hg + 1)
			hfb := hfb_mult * st[0] + (1 - hg) * st[2]
			hin := (x[i] - hfb) * hnorm
			h1 := pole_tick(&st[0], &st[1], hin, hg)
			h2 := pole_tick(&st[2], &st[3], h1, hg)
			hp := hin - h1 * 2 + h2
			hp = x[i] + (hp - x[i]) * lerp(l.extra[1], c.extra[1], u)
			// The ladder.
			sat_in := fast_tanh((lerp(l.drive, c.drive, u) * hp - lerp(l.resonance, c.resonance, u) * st[17]) * 0.5)
			fb_in := sat_in + st[11]
			fb := pole_tick(&st[4], &st[5], fb_in, hp_fb_g)
			sat_tick(st[6:9], fb_in - fb, g, .Tanh)
			sat_tick(st[9:12], (st[7] + st[14]) * 0.5, g, .None)
			sat_tick(st[12:15], (st[10] + st[17]) * 0.5, g, .None)
			o := sat_tick(st[15:18], st[13], g, .Clip)
			y[i] = o * lerp(l.post, c.post, u)
		}
	}
	f.last = c
}

// --- Digital -------------------------------------------------------------------------------------

@(private) SVF_MIN_RESONANCE :: 0.5
@(private) SVF_MAX_RESONANCE :: 16.0

// [rt] A soft clip: straight to ±0.66, tanh beyond.
@(private)
hard_tanh :: #force_inline proc "contextless" (x: f32) -> f32 {
	K :: 0.66
	c := clamp(x, -K, K)
	return c + fast_tanh((x - c) / (1 - K)) * (1 - K)
}

// [rt] A quick tanh-like curve (x / (x²/(3 + 0.2x²) + 1)).
@(private)
quick_tanh :: #force_inline proc "contextless" (x: f32) -> f32 {
	x2 := x * x
	return x / (x2 / (3 + x2 * 0.2) + 1)
}

// [rt] One step of a trapezoidal state-variable filter (two integrator
// states in `ic`), its output the mix `b` (input, band, low).
@(private)
svf_step :: #force_inline proc "contextless" (ic: []f32, x, g, k: f32, b: [3]f32) -> f32 #no_bounds_check {
	g2 := g * g
	c0 := 1 / (g2 + g * k + 1)
	c1 := c0 * g
	c2 := c0 * g2
	v3 := x - ic[1]
	v1 := c0 * ic[0] + c1 * v3
	v2 := ic[1] + c1 * ic[0] + c2 * v3
	ic[0] = v1 * 2 - ic[0]
	ic[1] = v2 * 2 - ic[1]
	return b[0] * x + b[1] * v1 + b[2] * v2
}

// [rt] The digital filter: a clean state-variable filter (two at 24 dB,
// the first without resonance), soft-clipped; shelving has a low shelf,
// a bell and a high shelf by the blend, at the gain.
@(private)
digital_render :: proc "contextless" (f: ^Filter_State, p: ^Filter_Params, cutoff: []f32, in_, out: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	c: Filter_Coeffs
	rp := clamp(p.resonance, 0, 1)
	rp = rp * rp * rp
	drv := math.pow(10, clamp(p.drive_db, 0, 36) / 20)
	gain := math.pow(10, clamp(p.gain_db, -15, 15) / 20)
	c.resonance = 1 / (SVF_MIN_RESONANCE + (SVF_MAX_RESONANCE - SVF_MIN_RESONANCE) * rp) // (as damping)
	c.drive = drv / (rp * 2 + 1)
	c.post = gain / math.sqrt(drv)
	shift: f32 = 0 // semitones the cutoff moves (shelving)
	blend := clamp(p.blend - 1, -1, 1)
	if p.style == .Shelving {
		c.drive, c.post = 1, 1
		low_bell := clamp(blend + 1, 0, 1)
		bell_high := clamp(blend, 0, 1)
		band_t := 1 - blend * blend
		a_sqrt := math.sqrt(gain)
		a_quart := math.sqrt(a_sqrt)
		c.low = gain + (1 - gain) * low_bell
		c.high = 1 + (gain - 1) * bell_high
		c.band = c.resonance * a_sqrt * (1 + (a_sqrt - 1) * band_t)
		shift = 12 * math.log2(math.pow(a_quart, blend))
	} else {
		dblend, dmult: f32
		c.low, c.band, c.high, dblend, dmult = pass_amounts(p.style, p.blend)
		scaled := c.drive
		if p.style == .Dual_Notch_Band do scaled *= dmult
		if p.style != .Db12 && p.style != .Db24 do c.drive = drv + (scaled - drv) * dblend
	}
	if !f.set do f.last = c
	l := f.last
	n := len(cutoff)
	inv := 1 / f32(max(n, 1))
	sr := f32(sample_rate)
	cr := coef_ramp(cutoff, sr, 0.001, sr, svf = true, shift = shift)
	for ch in 0 ..< sides(p) {
		x, y := in_[ch], out[ch]
		ic := f.poles[ch][:]
		for i in 0 ..< n {
			u := f32(i + 1) * inv
			lerp :: #force_inline proc "contextless" (a, b, u: f32) -> f32 { return a + (b - a) * u }
			g := cr.g0 + cr.dg * f32(i)
			k := lerp(l.resonance, c.resonance, u)
			lo, bd, hi := lerp(l.low, c.low, u), lerp(l.band, c.band, u), lerp(l.high, c.high, u)
			b1 := [3]f32{hi, bd - k * hi, lo - hi} // the low, band and high as a mix of input, band, low
			b2 := [3]f32{lo, bd - k * lo, hi - lo}
			v := lerp(l.drive, c.drive, u) * x[i]
			r: f32
			#partial switch p.style {
			case .Shelving:
				r = svf_step(ic[0:2], x[i], g, k, b1)
			case .Db12:
				r = hard_tanh(svf_step(ic[0:2], v, g, k, b1))
			case .Dual_Notch_Band:
				pre := hard_tanh(svf_step(ic[2:4], v, g, 1, b1))
				r = hard_tanh(svf_step(ic[0:2], pre, g, k, b2))
			case:
				pre := hard_tanh(svf_step(ic[2:4], v, g, 1, b1))
				r = hard_tanh(svf_step(ic[0:2], pre, g, k, b1))
			}
			y[i] = r * lerp(l.post, c.post, u)
		}
	}
	f.last = c
}
