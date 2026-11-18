package fx

import "core:math"

// Where a render sits on the transport: what an LFO synced to the tempo,
// a retrigger, or a sample-and-hold reckons from.
Beat_Clock :: struct {
	playing:         bool, // the transport plays
	beat:            f64,  // the timeline beat at the render's first frame
	beats_per_frame: f64,  // tempo / 60 / sample rate: how far a frame moves (also while stopped: the synced rates still run)
	bar_beats:       f64,  // beats a bar (4 in 4/4; 0 is taken as 4)
	started:         bool, // play started at the render's first frame
}

// An LFO's wave.
Lfo_Wave :: enum u8 {
	Sine,
	Triangle,
	Ramp_Up,
	Ramp_Down,
	Square,
	Random_Steps,  // a new random value each cycle
	Random_Smooth, // random values each cycle, eased from one to the next
}

// How an LFO's rate is set: in Hz; a tempo division, straight, dotted or
// triplet (`division`); or a whole number of sixteenths a cycle.
Lfo_Mode :: enum u8 {Hz, Sync, Dotted, Triplet, Sixteenths}

// What restarts an LFO's cycle: nothing; each beat; each bar; play
// starting. (Synced and playing, Off follows the timeline from beat 0.)
Lfo_Retrigger :: enum u8 {Off, Beat, Bar, Play}

// How an LFO's right side differs from its left: by a fixed phase, or by
// a faster rate (they drift apart and back).
Lfo_Stereo :: enum u8 {Phase, Spin}

// What an LFO does.
Lfo_Params :: struct {
	wave:       Lfo_Wave,
	morph:      f32,           // 0..1, 0.5 plain: the skew (Sine, Triangle), the curve (the ramps), the pulse width (Square), the glide (Random_Steps)
	mode:       Lfo_Mode,
	hz:         f32,           // the rate in Hz mode (0.01..40)
	division:   int,           // Sync, Dotted, Triplet: an index into `TEMPO_RATIOS` (1..12; 10 is 1/16)
	sixteenths: int,           // Sixteenths: a cycle's length (1..64)
	stereo:     Lfo_Stereo,
	phase_deg:  f32,           // Phase: the right side ahead of the left (0..360)
	spin_hz:    f32,           // Spin: the right side faster by this (0..2)
	offset_deg: f32,           // both sides' start in the cycle (0..360)
	retrigger:  Lfo_Retrigger,
	smooth:     f32,           // 0..1: a one-pole after the wave, up to a quarter cycle
}

// An LFO with the defaults: a sine at 1/4 (synced), no stereo, no retrigger.
LFO_DEFAULTS :: Lfo_Params{wave = .Sine, morph = 0.5, mode = .Sync, hz = 1, division = 8, sixteenths = 4}

// An LFO's state: where each side is in its cycle. Zero is ready to run.
// Fields are internal.
Lfo :: struct {
	phase:     f64,    // cycles (the left side, before the offsets)
	spin:      f64,    // the right side's extra, in Spin (cycles, 0..1)
	smoothed:  [2]f32,
	unit:      i64,    // the beat or bar the last frame was in (Hz retriggers)
	unit_ok:   bool,
	play_beat: f64,    // where play last started (Retrigger Play, synced)
	seed:      u64,    // the random waves' (0: a fixed default)
}

// [rt] Renders LFO `l` into `out` (its left and right sides, -1..1; the
// right may be the left's slice, then the left is written), for clock
// `clk`. Allocates nothing.
lfo_render :: proc "contextless" (l: ^Lfo, p: ^Lfo_Params, clk: Beat_Clock, out: [2][]f32, sample_rate: f64) #no_bounds_check {
	n := len(out[0])
	if n == 0 do return
	bpf := clk.beats_per_frame
	bar := clk.bar_beats if clk.bar_beats > 0 else 4
	cpb := lfo_cycles_per_beat(p) // (0: Hz)
	synced := p.mode != .Hz
	rate := cpb * bpf if synced else f64(clamp(p.hz, 0.001, 1000)) / sample_rate // cycles a frame
	if clk.started {
		l.play_beat = clk.beat
		if p.retrigger == .Play do l.phase = 0
		l.unit_ok = false
	}
	stereo := len(out[1]) == n && raw_data(out[1]) != raw_data(out[0])
	offset := f64(p.offset_deg) / 360
	right_by := f64(p.phase_deg) / 360
	spin := f64(clamp(p.spin_hz, 0, 100)) / sample_rate
	coef: f32 = 0
	if p.smooth > 0 && rate > 0 {
		tau := f64(clamp(p.smooth, 0, 1)) * 0.25 / rate // frames
		coef = f32(math.exp(-1 / max(tau, 1e-9)))
	}
	seed := l.seed if l.seed != 0 else 0x5EED_1F0_C0FFEE
	for k in 0 ..< n {
		b := clk.beat + f64(k) * bpf
		if clk.playing && synced {
			// On the timeline: the same place in the cycle wherever play starts or jumps.
			anchor := 0.0
			switch p.retrigger {
			case .Off:  anchor = 0
			case .Beat: anchor = math.floor(b + 1e-9)
			case .Bar:  anchor = math.floor(b / bar + 1e-9) * bar
			case .Play: anchor = l.play_beat
			}
			l.phase = (b - anchor) * cpb
		} else if clk.playing && (p.retrigger == .Beat || p.retrigger == .Bar) {
			unit_len := 1.0 if p.retrigger == .Beat else bar
			u := i64(math.floor(b / unit_len + 1e-9))
			if l.unit_ok && u != l.unit do l.phase = 0
			l.unit, l.unit_ok = u, true
		}
		x := l.phase + offset
		right := x + (right_by if p.stereo == .Phase else l.spin)
		vl := lfo_wave_at(p, x, seed)
		vr := lfo_wave_at(p, right, seed) if stereo else vl
		if coef > 0 {
			l.smoothed[0] = vl + (l.smoothed[0] - vl) * coef
			l.smoothed[1] = vr + (l.smoothed[1] - vr) * coef
			vl, vr = l.smoothed[0], l.smoothed[1]
		} else {
			l.smoothed = {vl, vr}
		}
		out[0][k] = vl
		if stereo do out[1][k] = vr
		if !(clk.playing && synced) {
			l.phase += rate
			if l.phase >= 1 << 40 do l.phase = math.mod(l.phase, 1) // (kept small; the waves only read the fraction and the cycle)
		}
		if p.stereo == .Spin {
			l.spin += spin
			if l.spin >= 1 do l.spin -= 1
		}
	}
}

// [rt] Cycles a beat LFO settings `p` run at (0 in Hz mode).
lfo_cycles_per_beat :: proc "contextless" (p: ^Lfo_Params) -> f64 {
	ratios := TEMPO_RATIOS
	r := f64(ratios[clamp(p.division, 1, 12)])
	switch p.mode {
	case .Hz:         return 0
	case .Sync:       return r
	case .Dotted:     return r * 2.0 / 3
	case .Triplet:    return r * 1.5
	case .Sixteenths: return 4 / f64(clamp(p.sixteenths, 1, 64))
	}
	return 0
}

// [rt] Where wave `p.wave` is at `x` cycles (-1..1).
@(private)
lfo_wave_at :: proc "contextless" (p: ^Lfo_Params, x: f64, seed: u64) -> f32 {
	// (A hair under a whole cycle is that cycle: a synced wrap falls right
	// on a frame, and the beat a block starts at differs in its last bit.)
	cycle := math.floor(x + 1e-9)
	w := max(x - cycle, 0) // 0..1
	m := f64(clamp(p.morph, 0, 1))
	switch p.wave {
	case .Sine:      return f32(math.sin(math.TAU * lfo_skew(w, m)))
	case .Triangle:  return f32(lfo_triangle(lfo_skew(w, m)))
	case .Ramp_Up:   return f32(2 * lfo_curve(w, m) - 1)
	case .Ramp_Down: return f32(1 - 2 * lfo_curve(w, m))
	case .Square:    return 1 if w < clamp(m, 0.05, 0.95) else -1
	case .Random_Steps, .Random_Smooth:
		c := i64(cycle)
		now, before := lfo_random(seed, c), lfo_random(seed, c - 1)
		if p.wave == .Random_Smooth do return before + (now - before) * f32(0.5 - 0.5 * math.cos(math.PI * w))
		glide := m
		if glide <= 0 || w >= glide do return now
		return before + (now - before) * f32(w / glide)
	}
	return 0
}

// The phase `w` (0..1) warped so the first half of the wave takes `m` of
// the cycle (0.5: as it is).
@(private)
lfo_skew :: #force_inline proc "contextless" (w, m: f64) -> f64 {
	b := clamp(m, 0.02, 0.98)
	return 0.5 * w / b if w < b else 0.5 + 0.5 * (w - b) / (1 - b)
}

// A triangle starting at 0 and rising (as a sine does).
@(private)
lfo_triangle :: #force_inline proc "contextless" (w: f64) -> f64 {
	switch {
	case w < 0.25: return 4 * w
	case w < 0.75: return 2 - 4 * w
	}
	return 4 * w - 4
}

// `w` (0..1) bent by `m`: 0.5 straight, below it slow then fast, above it
// fast then slow.
@(private)
lfo_curve :: #force_inline proc "contextless" (w, m: f64) -> f64 {
	return math.pow(w, math.pow(2, (0.5 - m) * 4))
}

// A random value (-1..1) for cycle `n`: the same for the same seed and
// cycle, whatever the block sizes (splitmix64).
@(private)
lfo_random :: #force_inline proc "contextless" (seed: u64, n: i64) -> f32 {
	z := seed + u64(n) * 0x9E3779B97F4A7C15
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	z ~= z >> 31
	return f32(z >> 40) / f32(1 << 24) * 2 - 1
}
