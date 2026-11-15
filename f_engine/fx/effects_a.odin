package fx

import "core:math"
import "core:simd"

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

// What a delay's control points take from its settings alone (not from
// its time): worked out once a render, and once for all of a chorus's
// delays, which share them.
@(private)
Delay_Shared :: struct {
	glide:    f32,    // how much of the way the rate is left to go after a control point
	wet, dry: f32,
	fbs:      [2]f32, // feedback, a side
	glo, ghi: f32,    // the filter's poles
	gain:     f32,
}

// [rt] `Delay_Shared` for settings `p` at `sr`.
@(private)
delay_shared :: proc "contextless" (p: ^Delay_Params, sr: f32) -> (sh: Delay_Shared) {
	sh.glide = math.pow(f32(0.5), FX_GRID / (0.02 * sr))
	sh.wet, sh.dry = equal_power(p.wet)
	fb := clamp(p.feedback, -1, 1)
	sh.fbs = {fb, fb}
	if p.style == .Ping_Pong do sh.fbs[1] = 1 // (the right side's feedback is the left's echo)
	radius := max(p.spread * 8 * 12, 0)
	lo_hz := clamp(key_to_hz(p.cutoff + radius), 1, sr * 0.45)
	hi_hz := clamp(key_to_hz(p.cutoff - radius), 1, sr * 0.45)
	sh.glo, sh.ghi = pole_coefficient(lo_hz / sr), pole_coefficient(hi_hz / sr)
	sh.gain = hi_hz / lo_hz + 1
	return
}

// [rt] Runs the delay over `l` and `r` in place.
delay_render :: proc "contextless" (d: ^Delay, p: ^Delay_Params, l, r: []f32, sample_rate: f64) {
	delay_run(d, p, l, r, sample_rate, nil)
}

// [rt] `delay_render`, given what its settings make it at its control
// points if the caller has it already (`delay_shared`; nil: worked out here).
@(private)
delay_run :: proc "contextless" (d: ^Delay, p: ^Delay_Params, l, r: []f32, sample_rate: f64, shared: ^Delay_Shared) #no_bounds_check {
	n := len(l)
	if n == 0 || len(d.lines[0].buf) == 0 do return
	sr := f32(sample_rate)
	own: Delay_Shared
	sh := shared
	if sh == nil {
		own = delay_shared(p, sr)
		sh = &own
	}
	x := [2][]f32{l, r}
	for i in 0 ..< n {
		if d.tick == 0 do delay_control(d, p, sr, sh)
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
delay_control :: proc "contextless" (d: ^Delay, p: ^Delay_Params, sr: f32, sh: ^Delay_Shared) {
	delay_control_in(d, p, sr, sh, {line_max(&d.lines[0]), line_max(&d.lines[1])})
}

// [rt] `delay_control` for a delay whose lines are elsewhere (a chorus's):
// `longest` its sides' `line_max`.
@(private)
delay_control_in :: proc "contextless" (d: ^Delay, p: ^Delay_Params, sr: f32, sh: ^Delay_Shared, longest: [2]f32) {
	target := p.hz
	if p.style == .Mono do target[1] = target[0]
	if !d.set {
		d.freq = target
	} else {
		for ch in 0 ..< 2 do d.freq[ch] = target[ch] + (d.freq[ch] - target[ch]) * sh.glide
	}
	samples: [2]f32
	for ch in 0 ..< 2 do samples[ch] = sr / max(d.freq[ch], 0.01)
	if p.style == .Mid_Ping_Pong do samples[0] += samples[1]
	periods: [2]f32
	for ch in 0 ..< 2 {
		periods[ch] = clamp(samples[ch], 3, longest[ch])
		if d.set do periods[ch] = d.period[ch] + (periods[ch] - d.period[ch]) * 0.5
	}
	now := [9]f32{sh.wet, sh.dry, sh.fbs[0], sh.fbs[1], sh.glo, sh.ghi, sh.gain, periods[0], periods[1]}
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
	delays:   [CHORUS_PAIRS * 2]Delay, // their state (not their lines)
	lines:    [CHORUS_PAIRS / 2][2]Line4, // the delays' lines, four delays a group, a side each (delay 4g + j: lane j)
	active:   int, // delays that ran last (a delay switched on starts clean)
	phase:    f32,
	hz:       [CHORUS_PAIRS * 2][2]f32, // each delay's rate since the last control point
	from, to: [2]f32,                   // wet, dry
	tick:     int,
	set:      bool,
}

// Control thread. A chorus for sample rates up to `max_rate`.
chorus_make :: proc(c: ^Chorus, max_rate: f64, allocator := context.allocator) -> core.Error {
	f := int((CHORUS_MAX_SECONDS + CHORUS_MAX_SWEEP * 1.5) * max_rate) + 8
	for &g in c.lines do for &l in g do l = line4_make({f, f, f, f}, allocator) or_return
	return .None
}

// Control thread. Frees a chorus's lines.
chorus_destroy :: proc(c: ^Chorus, allocator := context.allocator) {
	for &g in c.lines do for &l in g do line4_destroy(&l, allocator)
}

// [rt] Runs the chorus over `l` and `r` in place: each voice a pair of
// delays swept by a sine (the sides a quarter cycle apart, the pairs
// spread across it), their times spread between the two set, summed.
chorus_render :: proc "contextless" (c: ^Chorus, p: ^Chorus_Params, l, r: []f32, sample_rate: f64) #no_bounds_check {
	n := len(l)
	if n == 0 || len(c.lines[0][0].buf) == 0 do return
	sr := f32(sample_rate)
	pairs := clamp(p.voices, 1, CHORUS_PAIRS)
	count := pairs * 2
	// (Its delays differ only in their rates: the rest is worked out once.)
	shared_p := Delay_Params{style = .Stereo, wet = 1, feedback = p.feedback, cutoff = p.cutoff, spread = p.spread}
	shared := delay_shared(&shared_p, sr)
	for at := 0; at < n; {
		if c.tick == 0 do chorus_control(c, p, sr)
		// A delay switched on (more voices) starts clean, on the chorus's
		// grid, at its control point now.
		if count > c.active {
			for k in c.active ..< count {
				d := &c.delays[k]
				d^ = {tick = c.tick}
				if c.active > 0 do for ch in 0 ..< 2 do line4_clear_lane(&c.lines[k / 4][ch], k % 4) // (none ran yet: new or reset, already clear)
				dp := Delay_Params{style = .Stereo, wet = 1, feedback = p.feedback, hz = c.hz[k], cutoff = p.cutoff, spread = p.spread}
				delay_control_in(d, &dp, sr, &shared, chorus_longest(c, k))
			}
		}
		c.active = count
		m := min(FX_GRID - c.tick, n - at)
		pl, pr := l[at:at + m], r[at:at + m]
		out: [2][FX_GRID]f32
		for g in 0 ..< (count + 3) / 4 do chorus_four(c, p, g, count, &shared, pl, pr, &out, m, sr)
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

@(private) V4 :: #simd[4]f32

// [rt] Chorus delay `k`'s sides' `line_max`.
@(private)
chorus_longest :: #force_inline proc "contextless" (c: ^Chorus, k: int) -> [2]f32 {
	return {simd.to_array(c.lines[k / 4][0].max)[k % 4], simd.to_array(c.lines[k / 4][1].max)[k % 4]}
}

// [rt] Delays 4g .. 4g + 3 of a chorus (those under `count`) over `m`
// samples of `pl` and `pr`, a delay a lane (their lines a `Line4`): what
// `delay_render` does for each (a Stereo delay, all wet), added at half
// into `out`. Its control point, when one is due, is each delay's own
// (`delay_control`). The lanes past `count` are silent (written with 0).
@(private)
chorus_four :: proc "contextless" (c: ^Chorus, p: ^Chorus_Params, g, count: int, shared: ^Delay_Shared, pl, pr: []f32, out: ^[2][FX_GRID]f32, m: int, sr: f32) #no_bounds_check {
	k0 := g * 4
	lanes := min(count - k0, 4)
	if c.delays[k0].tick == 0 {
		for j in 0 ..< lanes {
			k := k0 + j
			dp := Delay_Params{style = .Stereo, wet = 1, feedback = p.feedback, hz = c.hz[k], cutoff = p.cutoff, spread = p.spread}
			delay_control_in(&c.delays[k], &dp, sr, shared, chorus_longest(c, k))
		}
	}
	// Each field of the delays' last two control points, a lane a delay
	// (lanes past `count`: none of them, at no level).
	from, to: [9]V4
	half: V4
	for j in 0 ..< lanes {
		d := &c.delays[k0 + j]
		for f in 0 ..< 9 {
			(^[4]f32)(&from[f])[j] = d.from[f]
			(^[4]f32)(&to[f])[j] = d.to[f]
		}
		(^[4]f32)(&half)[j] = 0.5
	}
	tick := c.delays[k0].tick
	src := [2][]f32{pl, pr}
	for ch in 0 ..< 2 {
		poles: [4]V4
		for j in 0 ..< lanes do for q in 0 ..< 4 do (^[4]f32)(&poles[q])[j] = c.delays[k0 + j].poles[ch][q]
		line := &c.lines[g][ch]
		for i in 0 ..< m {
			u := f32(tick + i + 1) * (1.0 / FX_GRID)
			uv := V4{u, u, u, u}
			lerp :: #force_inline proc "contextless" (a, b, u: V4) -> V4 { return a + (b - a) * u }
			wet, dry := lerp(from[0], to[0], uv), lerp(from[1], to[1], uv)
			fb := lerp(from[2 + ch], to[2 + ch], uv)
			glo, ghi := lerp(from[4], to[4], uv), lerp(from[5], to[5], uv)
			gain := lerp(from[6], to[6], uv)
			read := line4_read(line, lerp(from[7 + ch], to[7 + ch], uv))
			x := src[ch][i]
			in_ := V4{x, x, x, x}
			w := clip_large4(in_ + read * fb)
			lp := pole_tick4(&poles[0], &poles[1], w * gain, glo)
			hp := pole_tick4(&poles[2], &poles[3], lp, ghi)
			line4_push(line, lp - hp)
			y := dry * in_ + wet * read
			out[ch][i] += simd.reduce_add_ordered(y * half)
		}
		for j in 0 ..< lanes do for q in 0 ..< 4 do c.delays[k0 + j].poles[ch][q] = (^[4]f32)(&poles[q])[j]
	}
	for j in 0 ..< lanes do c.delays[k0 + j].tick = (tick + m) % FX_GRID
}

// [rt] `clip_large` four at once.
@(private)
clip_large4 :: #force_inline proc "contextless" (x: V4) -> V4 {
	K :: 0.66
	// Below 8K the curve is x itself, exactly: the rest is skipped.
	if simd.reduce_max(simd.abs(x)) <= 8 * K do return x
	y := x * (1.0 / 8)
	cl := simd.clamp(y, -K, K)
	z := (y - cl) * (1 / (1 - K))
	z2 := z * z
	t := z * (135135 + z2 * (17325 + z2 * (378 + z2))) / (135135 + z2 * (62370 + z2 * (3150 + z2 * 28)))
	t = simd.select(simd.lanes_gt(z, 4.97), V4(1), t)
	t = simd.select(simd.lanes_lt(z, -4.97), V4(-1), t)
	return (cl + t * (1 - K)) * 8
}

// [rt] `pole_tick` four at once.
@(private)
pole_tick4 :: #force_inline proc "contextless" (state, out: ^V4, x, g: V4) -> V4 {
	d := g * (x - state^)
	state^ += d
	out^ = state^
	state^ += d
	return out^
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
		cut: [2][64]f32
		dry: [2][64]f32
		io := [2][]f32{l[at:at + m], r[at:at + m]}
		for ch in 0 ..< 2 {
			for i in 0 ..< m {
				x := start + p.hz * f32(i) / f32(sample_rate) + (p.offset * 0.5 if ch == 0 else -p.offset * 0.5)
				x -= math.floor(x)
				tri := 1 - abs(x * 2 - 1) // 0..1..0
				cut[ch][i] = p.center + (tri * 2 - 1) * p.depth
			}
			copy(dry[ch][:m], io[ch])
		}
		fp := Filter_Params{model = .Phaser, style = .Db12, resonance = p.feedback, blend = p.blend, mix = 1, clean = true, mono = true}
		phaser_filter_pair(&ph.filters, &fp, {cut[0][:m], cut[1][:m]}, io, sample_rate)
		if !ph.set do ph.last_mix = p.wet
		for ch in 0 ..< 2 {
			src := io[ch]
			for i in 0 ..< m {
				w := ph.last_mix + (clamp(p.wet, 0, 1) - ph.last_mix) * f32(i + 1) / f32(m)
				src[i] = dry[ch][i] + (src[i] - dry[ch][i]) * w
			}
		}
		ph.last_mix = clamp(p.wet, 0, 1)
		ph.set = true
	}
}
