package fx

import "core:math"

import "fire:core"

// Distortion, delay, chorus, flanger and phaser.

// --- Distortion ----------------------------------------------------------------------------------

// What a distortion does to the signal.
Distortion_Type :: enum u8 {
	Soft_Clip,   // tanh
	Hard_Clip,   // clipped at ±1
	Linear_Fold, // folded back in straight lines
	Sine_Fold,   // folded through a sine
	Bit_Crush,   // steps
	Down_Sample, // held for longer, the lower the drive
}

// Where a distortion's filter is.
Filter_Order :: enum u8 {None, Pre, Post}

// A distortion's settings.
Distortion_Params :: struct {
	type:      Distortion_Type,
	drive_db:  f32, // -30..30
	mix:       f32, // 0..1
	order:     Filter_Order,
	cutoff:    f32, // a key
	resonance: f32,
	blend:     f32, // 0 low .. 1 band .. 2 high
}

// Default distortion settings.
DISTORTION_DEFAULTS :: Distortion_Params{type = .Soft_Clip, mix = 1, cutoff = 80, resonance = 0.5}

// A distortion's state.
Distortion :: struct {
	held:     [2]f32,
	count:    [2]f32,
	filter:   Filter_State,
	last_mix: f32,
	set:      bool,
}

@(private) DIST_MAX :: 30.0
@(private) DIST_PERIOD :: 1.0 / 88200

// [rt] The drive a type works with, from its dB: a gain, or for the bit
// crusher a step, or for the down-sampler a period in seconds.
@(private)
distortion_drive :: proc "contextless" (t: Distortion_Type, db: f32) -> f32 {
	d := clamp(db, -DIST_MAX, DIST_MAX)
	#partial switch t {
	case .Bit_Crush:
		x := max(d + DIST_MAX, 0) / (2 * DIST_MAX)
		return clamp(x * x, 32.0 / 2147483647, 1)
	case .Down_Sample:
		x := max(d + DIST_MAX, 0) / (2 * DIST_MAX)
		inv := 1 / clamp(x * x, 32.0 / 2147483647, 1)
		return max(inv * 0.99, 1) * DIST_PERIOD
	}
	return math.pow(10, d / 20)
}

// [rt] Distorts `l` and `r` in place (the filter before or after, then
// mixed with the dry signal).
distortion_render :: proc "contextless" (d: ^Distortion, p: ^Distortion_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	if n == 0 do return
	dry: [2][256]f32
	chunked :: proc "contextless" (d: ^Distortion, p: ^Distortion_Params, l, r: []f32, sample_rate: f64, dry: ^[2][256]f32) #no_bounds_check {
		n := len(l)
		copy(dry[0][:n], l)
		copy(dry[1][:n], r)
		cut: [256]f32
		for &k in cut[:n] do k = p.cutoff
		fp := Filter_Params{model = .Digital, style = .Db12, cutoff = p.cutoff, resonance = p.resonance, blend = p.blend, mix = 1}
		io := [2][]f32{l, r}
		if p.order == .Pre do filter_render(&d.filter, &fp, cut[:n], &io, &io, sample_rate)
		drive := distortion_drive(p.type, p.drive_db)
		for ch in 0 ..< 2 {
			x := io[ch]
			for i in 0 ..< n {
				v := x[i]
				switch p.type {
				case .Soft_Clip: v = fast_tanh(v * drive)
				case .Hard_Clip: v = clamp(v * drive, -1, 1)
				case .Linear_Fold:
					a := v * drive * 0.25 + 0.75
					a -= math.floor(a)
					v = abs(a * -4 + 2) - 1
				case .Sine_Fold:
					a := v * drive * -0.25 + 0.5
					a -= math.floor(a)
					v = math.sin(a * math.TAU)
				case .Bit_Crush: v = math.round(v / drive) * drive
				case .Down_Sample:
					period := drive * f32(sample_rate)
					d.count[ch] += 1
					if d.count[ch] >= period {
						d.held[ch] = v
						d.count[ch] -= period
					}
					v = d.held[ch]
				}
				x[i] = v
			}
		}
		if p.order == .Post do filter_render(&d.filter, &fp, cut[:n], &io, &io, sample_rate)
		if !d.set do d.last_mix = p.mix
		for ch in 0 ..< 2 {
			x := io[ch]
			for i in 0 ..< n {
				m := d.last_mix + (clamp(p.mix, 0, 1) - d.last_mix) * f32(i + 1) / f32(n)
				x[i] = dry[ch][i] + (x[i] - dry[ch][i]) * m
			}
		}
		d.last_mix = clamp(p.mix, 0, 1)
		d.set = true
	}
	for at := 0; at < n; at += 256 {
		m := min(256, n - at)
		chunked(d, p, l[at:at + m], r[at:at + m], sample_rate, &dry)
	}
}

// --- Delay ---------------------------------------------------------------------------------------

// How a delay's two sides play.
Delay_Style :: enum u8 {
	Mono,          // the same time both sides
	Stereo,        // a time each side
	Ping_Pong,     // the input summed, bouncing side to side
	Mid_Ping_Pong, // each side's own, bouncing
}

// A delay's settings.
Delay_Params :: struct {
	style:    Delay_Style,
	wet:      f32, // 0..1
	feedback: f32, // -1..1
	hz:       [2]f32, // repeats a second, left and right (from its time or the tempo)
	cutoff:   f32, // a key: the centre of the feedback's band
	spread:   f32, // 0..1: how wide that band is (0: a narrow band, 1: eight octaves)
}

// Default delay settings: a repeat every quarter second.
DELAY_DEFAULTS :: Delay_Params{style = .Stereo, wet = 0.3334, feedback = 0.5, hz = {4, 4}, cutoff = 60, spread = 1}

// The longest delay (seconds) a `Delay` made with `delay_make` holds.
DELAY_MAX_SECONDS :: 4.5

// A delay's state: its lines and filters, and its settings at the last
// two control points (`FX_GRID` samples apart), glided between.
Delay :: struct {
	lines:    [2]Line,
	period:   [2]f32,
	freq:     [2]f32, // the rate it is moving to the set one, smoothed
	poles:    [2][4]f32,
	from, to: [9]f32, // wet, dry, feedback L, feedback R, low g, high g, gain, period L, period R
	tick:     int,    // where it is between control points
	set:      bool,
}

// Samples between the control points of the effects that sweep (delay,
// chorus, flanger): on a grid of their own, so a block's size never
// moves one.
FX_GRID :: 32

// Control thread. A delay for rates up to `max_rate` Hz.
delay_make :: proc(d: ^Delay, max_rate: f64, allocator := context.allocator) -> core.Error {
	for &l in d.lines do l = line_make(int(DELAY_MAX_SECONDS * max_rate) + 8, allocator) or_return
	return .None
}

// Control thread. Frees a delay's lines.
delay_destroy :: proc(d: ^Delay, allocator := context.allocator) {
	for &l in d.lines do line_destroy(&l, allocator)
}

// [rt] Runs the delay over `l` and `r` in place.
delay_render :: proc "contextless" (d: ^Delay, p: ^Delay_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	if n == 0 || len(d.lines[0].buf) == 0 do return
	sr := f32(sample_rate)
	x := [2][]f32{l, r}
	for i in 0 ..< n {
		if d.tick == 0 do delay_control(d, p, sr)
		u := f32(d.tick + 1) * (1.0 / FX_GRID)
		d.tick = (d.tick + 1) % FX_GRID
		v: [9]f32
		for k in 0 ..< 9 do v[k] = d.from[k] + (d.to[k] - d.from[k]) * u
		in_ := [2]f32{x[0][i], x[1][i]}
		read: [2]f32
		for ch in 0 ..< 2 do read[ch] = line_read(&d.lines[ch], v[7 + ch])
		w: [2]f32
		switch p.style {
		case .Mono, .Stereo:
			for ch in 0 ..< 2 do w[ch] = clip_large(in_[ch] + read[ch] * v[2 + ch])
		case .Mid_Ping_Pong:
			for ch in 0 ..< 2 do w[1 - ch] = clip_large(in_[ch] + read[ch] * v[2 + ch]) // each side into the other
		case .Ping_Pong:
			mono := (in_[0] + in_[1]) * (1 / math.SQRT_TWO)
			w[1] = clip_large(mono + read[0] * v[2]) // the left's into the right
			w[0] = clip_large(read[1] * v[3])        // the right's back into the left
		}
		for ch in 0 ..< 2 {
			st := &d.poles[ch]
			lp := pole_tick(&st[0], &st[1], w[ch] * v[6], v[4])
			hp := pole_tick(&st[2], &st[3], lp, v[5])
			line_push(&d.lines[ch], lp - hp)
			x[ch][i] = v[1] * in_[ch] + v[0] * read[ch]
		}
	}
}

// [rt] A delay's next control point: its time moved toward the set one
// (a 20 ms half-life, then halfway again, so it never jumps), its mix,
// feedback and filter.
@(private)
delay_control :: proc "contextless" (d: ^Delay, p: ^Delay_Params, sr: f32) {
	target := p.hz
	if p.style == .Mono do target[1] = target[0]
	if !d.set {
		d.freq = target
	} else {
		k := math.pow(f32(0.5), FX_GRID / (0.02 * sr))
		for ch in 0 ..< 2 do d.freq[ch] = target[ch] + (d.freq[ch] - target[ch]) * k
	}
	wet, dry := equal_power(p.wet)
	fb := clamp(p.feedback, -1, 1)
	fbs := [2]f32{fb, fb}
	if p.style == .Ping_Pong do fbs[1] = 1 // (the right side's feedback is the left's echo)
	samples: [2]f32
	for ch in 0 ..< 2 do samples[ch] = sr / max(d.freq[ch], 0.01)
	if p.style == .Mid_Ping_Pong do samples[0] += samples[1]
	periods: [2]f32
	for ch in 0 ..< 2 {
		periods[ch] = clamp(samples[ch], 3, line_max(&d.lines[ch]))
		if d.set do periods[ch] = d.period[ch] + (periods[ch] - d.period[ch]) * 0.5
	}
	radius := max(p.spread * 8 * 12, 0)
	lo_hz := clamp(key_to_hz(p.cutoff + radius), 1, sr * 0.45)
	hi_hz := clamp(key_to_hz(p.cutoff - radius), 1, sr * 0.45)
	glo, ghi := pole_coefficient(lo_hz / sr), pole_coefficient(hi_hz / sr)
	now := [9]f32{wet, dry, fbs[0], fbs[1], glo, ghi, hi_hz / lo_hz + 1, periods[0], periods[1]}
	d.from = d.to if d.set else now
	d.to = now
	d.period = periods
	d.set = true
}

// --- Chorus --------------------------------------------------------------------------------------

// A chorus's settings.
Chorus_Params :: struct {
	voices:   int,  // pairs of delays: 1..4
	hz:       f32,  // the modulation's rate
	feedback: f32,  // -0.95..0.95
	wet:      f32,
	cutoff:   f32,  // a key
	spread:   f32,  // 0..1
	depth:    f32,  // 0..1 (up to 30 ms of sweep)
	delay:    [2]f32, // seconds: the two delays each pair is spread between
}

// Default chorus settings.
CHORUS_DEFAULTS :: Chorus_Params{voices = 4, hz = 0.125, feedback = 0.4, wet = 0.5, cutoff = 60, spread = 1, depth = 0.5, delay = {1.0 / 512, 1.0 / 128}}

@(private) CHORUS_PAIRS :: 4
@(private) CHORUS_MAX_SWEEP :: 0.03
@(private) CHORUS_MAX_SECONDS :: 0.08

// A chorus's state: a delay a side for each of its voices (two a pair).
Chorus :: struct {
	delays:   [CHORUS_PAIRS * 2]Delay,
	phase:    f32,
	hz:       [CHORUS_PAIRS * 2][2]f32, // each delay's rate since the last control point
	from, to: [2]f32,                   // wet, dry
	tick:     int,
	scratch:  [2][FX_GRID]f32,
	set:      bool,
}

// Control thread. A chorus for sample rates up to `max_rate`.
chorus_make :: proc(c: ^Chorus, max_rate: f64, allocator := context.allocator) -> core.Error {
	for &d in c.delays do for &l in d.lines do l = line_make(int((CHORUS_MAX_SECONDS + CHORUS_MAX_SWEEP * 1.5) * max_rate) + 8, allocator) or_return
	return .None
}

// Control thread. Frees a chorus's lines.
chorus_destroy :: proc(c: ^Chorus, allocator := context.allocator) {
	for &d in c.delays do delay_destroy(&d, allocator)
}

// [rt] Runs the chorus over `l` and `r` in place: each voice a pair of
// delays swept by a sine (the sides a quarter cycle apart, the pairs
// spread across it), their times spread between the two set, summed.
chorus_render :: proc "contextless" (c: ^Chorus, p: ^Chorus_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	if n == 0 || len(c.delays[0].lines[0].buf) == 0 do return
	sr := f32(sample_rate)
	pairs := clamp(p.voices, 1, CHORUS_PAIRS)
	for at := 0; at < n; {
		if c.tick == 0 do chorus_control(c, p, sr)
		m := min(FX_GRID - c.tick, n - at)
		pl, pr := l[at:at + m], r[at:at + m]
		out: [2][FX_GRID]f32
		for k in 0 ..< pairs * 2 {
			dp := Delay_Params{style = .Stereo, wet = 1, feedback = p.feedback, hz = c.hz[k], cutoff = p.cutoff, spread = p.spread}
			a, b := c.scratch[0][:m], c.scratch[1][:m]
			copy(a, pl)
			copy(b, pr)
			delay_render(&c.delays[k], &dp, a, b, sample_rate)
			for i in 0 ..< m {
				out[0][i] += a[i] * 0.5
				out[1][i] += b[i] * 0.5
			}
		}
		for i in 0 ..< m {
			u := f32(c.tick + i + 1) * (1.0 / FX_GRID)
			w := c.from[0] + (c.to[0] - c.from[0]) * u
			dd := c.from[1] + (c.to[1] - c.from[1]) * u
			pl[i] = dd * pl[i] + w * out[0][i]
			pr[i] = dd * pr[i] + w * out[1][i]
		}
		c.tick = (c.tick + m) % FX_GRID
		at += m
	}
}

// [rt] A chorus's next control point: its sweep moved on, each delay's
// time from it, the mix.
@(private)
chorus_control :: proc "contextless" (c: ^Chorus, p: ^Chorus_Params, sr: f32) {
	c.phase += p.hz * FX_GRID / sr
	c.phase -= math.floor(c.phase)
	pairs := clamp(p.voices, 1, CHORUS_PAIRS)
	avg := (p.delay[0] + p.delay[1]) * 0.5
	for k in 0 ..< pairs {
		offset := f32(k) * 0.25 / f32(pairs)
		t: f32 = f32(k) / f32(pairs - 1) if pairs > 1 else 0
		for side in 0 ..< 2 { // the pair's two delays (the first and second times)
			base := p.delay[side] + (avg - p.delay[side]) * t
			for ch in 0 ..< 2 {
				ph := c.phase + offset + (0.25 if ch == 1 else 0) + (0.5 if side == 1 else 0)
				m := math.sin(ph * math.TAU) * 0.5 + 1
				c.hz[k * 2 + side][ch] = 1 / max(m * p.depth * CHORUS_MAX_SWEEP + base, 0.00001)
			}
		}
	}
	wet, dry := equal_power(p.wet)
	now := [2]f32{wet, dry}
	c.from = c.to if c.set else now
	c.to = now
	c.set = true
}

// --- Flanger -------------------------------------------------------------------------------------

// A flanger's settings.
Flanger_Params :: struct {
	hz:       f32, // its sweep's rate
	center:   f32, // a key: the comb's centre (its delay's pitch)
	feedback: f32, // -1..1
	wet:      f32, // 0..0.5 (0.5: as much flanged as dry)
	depth:    f32, // 0..1
	offset:   f32, // 0..1: the right side's sweep ahead of the left's
}

// Default flanger settings.
FLANGER_DEFAULTS :: Flanger_Params{hz = 4, center = 64, feedback = 0.5, wet = 0.5, depth = 0.5, offset = 0.3333}

// A flanger's state.
Flanger :: struct {
	delay: Delay,
	phase: f32,
	hz:    [2]f32, // its delay's rate since the last control point
	tick:  int,
}

// Control thread. A flanger for sample rates up to `max_rate`.
flanger_make :: proc(f: ^Flanger, max_rate: f64, allocator := context.allocator) -> core.Error {
	for &l in f.delay.lines do l = line_make(int(0.05 * max_rate), allocator) or_return
	return .None
}

// Control thread. Frees a flanger's lines.
flanger_destroy :: proc(f: ^Flanger, allocator := context.allocator) {
	delay_destroy(&f.delay, allocator)
}

// [rt] Runs the flanger over `l` and `r` in place: a short delay (its
// pitch the centre) swept by a triangle, fed back.
flanger_render :: proc "contextless" (f: ^Flanger, p: ^Flanger_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	if n == 0 || len(f.delay.lines[0].buf) == 0 do return
	BUFFER :: 0.0005
	for at := 0; at < n; {
		if f.tick == 0 {
			f.phase += p.hz * FX_GRID / f32(sample_rate)
			f.phase -= math.floor(f.phase)
			for ch in 0 ..< 2 {
				ph := f.phase - p.offset / 2 + (p.offset if ch == 1 else 0)
				ph -= math.floor(ph)
				tri := 1 - abs(ph * 2 - 1) // 0..1..0
				mod := p.depth * (tri * 2 - 1) + 1
				delay := 1 / key_to_hz(p.center)
				delay = (delay - BUFFER) * mod + BUFFER
				f.hz[ch] = 1 / max(delay, 1.0 / 20_000)
			}
		}
		m := min(FX_GRID - f.tick, n - at)
		dp := Delay_Params{style = .Stereo, wet = p.wet, feedback = p.feedback, hz = f.hz, cutoff = 68, spread = 1}
		delay_render(&f.delay, &dp, l[at:at + m], r[at:at + m], sample_rate)
		f.tick = (f.tick + m) % FX_GRID
		at += m
	}
}

// --- Phaser --------------------------------------------------------------------------------------

// A phaser's settings.
Phaser_Params :: struct {
	hz:       f32, // its sweep's rate
	feedback: f32, // 0..1
	wet:      f32, // 0..1
	center:   f32, // a key
	blend:    f32, // 0..2: one, three or five peaks
	depth:    f32, // semitones the sweep reaches either way (0..48)
	offset:   f32, // 0..1: the sides' sweeps apart
}

// Default phaser settings.
PHASER_DEFAULTS :: Phaser_Params{hz = 0.125, feedback = 0.5, wet = 1, center = 80, blend = 1, depth = 24, offset = 0.3333}

// A phaser's state.
Phaser :: struct {
	filters: [2]Filter_State,
	phase:   f32,
	last_mix: f32,
	set:     bool,
}

// [rt] Runs the phaser over `l` and `r` in place: the phaser filter, its
// centre swept by a triangle (the sides apart by the offset), mixed.
phaser_render :: proc "contextless" (ph: ^Phaser, p: ^Phaser_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	for at := 0; at < n; at += 64 {
		m := min(64, n - at)
		start := ph.phase
		ph.phase += p.hz * f32(m) / f32(sample_rate)
		ph.phase -= math.floor(ph.phase)
		for ch in 0 ..< 2 {
			cut: [64]f32
			for i in 0 ..< m {
				x := start + p.hz * f32(i) / f32(sample_rate) + (p.offset * 0.5 if ch == 0 else -p.offset * 0.5)
				x -= math.floor(x)
				tri := 1 - abs(x * 2 - 1) // 0..1..0
				cut[i] = p.center + (tri * 2 - 1) * p.depth
			}
			fp := Filter_Params{model = .Phaser, style = .Db12, resonance = p.feedback, blend = p.blend, mix = 1, clean = true}
			src := l[at:at + m] if ch == 0 else r[at:at + m]
			dry: [64]f32
			copy(dry[:m], src)
			io := [2][]f32{src, src} // (one side through its own filter)
			filter_render_side(&ph.filters[ch], &fp, cut[:m], src, sample_rate)
			if !ph.set do ph.last_mix = p.wet
			for i in 0 ..< m {
				w := ph.last_mix + (clamp(p.wet, 0, 1) - ph.last_mix) * f32(i + 1) / f32(m)
				src[i] = dry[i] + (src[i] - dry[i]) * w
			}
			_ = io
		}
		ph.last_mix = clamp(p.wet, 0, 1)
		ph.set = true
	}
}
