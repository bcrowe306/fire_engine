package dsp

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"

// Loudness as EBU R128 measures it (ITU-R BS.1770): the signal K-weighted
// (a high shelf and a high-pass), its power in 100 ms blocks; momentary
// loudness over the last 400 ms, short-term over the last 3 s, integrated
// over everything since the last reset (gated: blocks under -70 LUFS left
// out, then those more than 10 LU under the rest's mean); and the true
// peak, the largest |sample| of the signal oversampled four times.

// The level a `Loudness_Meter` reports for nothing (no signal yet, or
// silence): far under any real level.
LOUDNESS_SILENT :: -144

// Bins of the integrated loudness's histogram: 0.1 LU each, from -70 to
// +10 LUFS.
@(private)
LOUDNESS_BINS :: 800

// Short-term loudness's blocks (3 s of 100 ms).
@(private)
LOUDNESS_SHORT :: 30

// Taps of each phase of the true peak's 4× interpolator.
@(private)
TP_TAPS :: 12

// A biquad's coefficients (a0 = 1) and, per channel, its state.
@(private)
K_Stage :: struct {
	b0, b1, b2, a1, a2: f64,
	z1, z2:             [METER_CHANNELS]f64,
}

// Passes audio through unchanged and measures its loudness (EBU R128) and
// true peak. Read from any thread (`loudness_read`); reset the integrated
// loudness and the true peak's maximum with `loudness_reset`.
Loudness_Meter :: struct {
	// Set by prepare.
	shelf, highpass: K_Stage,
	block_len:       int, // frames in 100 ms
	tp:              [4][TP_TAPS]f64, // the interpolator's taps, a phase each
	// The audio thread's.
	sum:         [METER_CHANNELS]f64, // the K-weighted Σ x² of this block so far
	frames:      int,
	blocks:      [LOUDNESS_SHORT]f64, // each block's mean power (channels summed), newest at `at`
	at:          int,
	filled:      int,
	hist_power:  [LOUDNESS_BINS]f64, // the gated blocks' power, by loudness
	hist_count:  [LOUDNESS_BINS]u32,
	history:     [METER_CHANNELS][TP_TAPS]f32, // the last samples, for the interpolator
	hist_at:     int,
	tp_max:      f32,
	reset_seen:  u32,
	// Atomic: f32 bits, what the reader reads.
	momentary:   u32,
	short_term:  u32,
	integrated:  u32,
	true_peak:   u32, // linear, the largest since the last reset
	reset:       u32, // raised by `loudness_reset`
}

@(private)
loudness_vtable := core.Node_VTable {
	prepare = loudness_prepare,
	process = loudness_process,
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Loudness_Meter)(self), a) },
}

// Control thread. A loudness meter node (give it as many inputs as
// outputs; the first two channels are measured) and its handle, valid
// until the graph destroys the node.
loudness_create :: proc(allocator := context.allocator) -> (core.Node, ^Loudness_Meter) {
	m := new(Loudness_Meter, allocator)
	silent := transmute(u32)f32(LOUDNESS_SILENT)
	m.momentary, m.short_term, m.integrated = silent, silent, silent
	return core.node_make(&loudness_vtable, m, allocator), m
}

// Any thread. The momentary (400 ms), short-term (3 s) and integrated
// loudness in LUFS (`LOUDNESS_SILENT` for none), and the true peak since
// the last reset (linear: 1 = 0 dBTP).
loudness_read :: proc "contextless" (m: ^Loudness_Meter) -> (momentary, short_term, integrated, true_peak: f32) {
	momentary = transmute(f32)intrinsics.atomic_load(&m.momentary)
	short_term = transmute(f32)intrinsics.atomic_load(&m.short_term)
	integrated = transmute(f32)intrinsics.atomic_load(&m.integrated)
	true_peak = transmute(f32)intrinsics.atomic_load(&m.true_peak)
	return
}

// Any thread. Starts the integrated loudness and the true peak's maximum
// again (from the audio thread's next block).
loudness_reset :: proc "contextless" (m: ^Loudness_Meter) {
	intrinsics.atomic_add(&m.reset, 1)
}

// The loudness, in LUFS, of a mean power `p` (channels summed).
@(private)
lufs_of :: proc "contextless" (p: f64) -> f64 {
	if p <= 1e-20 do return LOUDNESS_SILENT
	return -0.691 + 10 * math.log10(p)
}

@(private)
loudness_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
	m := (^Loudness_Meter)(self)
	fs := cfg.sample_rate if cfg.sample_rate > 0 else 48_000
	// BS.1770's stage 1, the shelf (as designed for any rate).
	{
		f0, g, q := 1681.974450955533, 3.999843853973347, 0.7071752369554196
		k := math.tan(math.PI * f0 / fs)
		vh := math.pow(10, g / 20)
		vb := math.pow(vh, 0.4996667741545416)
		a0 := 1 + k / q + k * k
		m.shelf = {b0 = (vh + vb * k / q + k * k) / a0, b1 = 2 * (k * k - vh) / a0, b2 = (vh - vb * k / q + k * k) / a0, a1 = 2 * (k * k - 1) / a0, a2 = (1 - k / q + k * k) / a0}
	}
	// Stage 2, the high-pass.
	{
		f0, q := 38.13547087602444, 0.5003270373238773
		k := math.tan(math.PI * f0 / fs)
		a0 := 1 + k / q + k * k
		m.highpass = {b0 = 1, b1 = -2, b2 = 1, a1 = 2 * (k * k - 1) / a0, a2 = (1 - k / q + k * k) / a0}
	}
	m.block_len = max(int(math.round(fs * 0.1)), 1)
	// The true peak's interpolator: a windowed sinc, 4 phases of 12 taps.
	n := 4 * TP_TAPS
	c := f64(n - 1) / 2
	for k in 0 ..< n {
		x := (f64(k) - c) / 4
		s := 1.0 if abs(x) < 1e-12 else math.sin(math.PI * x) / (math.PI * x)
		w := 0.42 - 0.5 * math.cos(2 * math.PI * f64(k) / f64(n - 1)) + 0.08 * math.cos(4 * math.PI * f64(k) / f64(n - 1)) // Blackman
		m.tp[k % 4][k / 4] = s * w
	}
	// Each phase sums to one (the interpolated signal keeps its level).
	for &ph in m.tp {
		sum := 0.0
		for v in ph do sum += v
		if sum != 0 do for &v in ph do v /= sum
	}
	loudness_clear(m)
	return .None
}

// [rt] Everything measured so far forgotten.
@(private)
loudness_clear :: proc "contextless" (m: ^Loudness_Meter) {
	m.sum, m.frames, m.blocks, m.at, m.filled = {}, 0, {}, 0, 0
	m.hist_power, m.hist_count = {}, {}
	m.history, m.hist_at, m.tp_max = {}, 0, 0
	m.shelf.z1, m.shelf.z2, m.highpass.z1, m.highpass.z2 = {}, {}, {}, {}
	silent := transmute(u32)f32(LOUDNESS_SILENT)
	intrinsics.atomic_store(&m.momentary, silent)
	intrinsics.atomic_store(&m.short_term, silent)
	intrinsics.atomic_store(&m.integrated, silent)
	intrinsics.atomic_store(&m.true_peak, 0)
}

// [rt]
@(private)
loudness_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Loudness_Meter)(self)
	if r := intrinsics.atomic_load(&m.reset); r != m.reset_seen {
		m.reset_seen = r
		// The integrated loudness and the true peak start again (the short
		// windows carry on).
		m.hist_power, m.hist_count, m.tp_max = {}, {}, 0
		intrinsics.atomic_store(&m.integrated, transmute(u32)f32(LOUDNESS_SILENT))
		intrinsics.atomic_store(&m.true_peak, 0)
	}
	for out, c in ctx.outputs {
		if c < len(ctx.inputs) do copy(out[:ctx.frames], ctx.inputs[c][:ctx.frames])
		else do for &v in out[:ctx.frames] do v = 0
	}
	chans := min(len(ctx.outputs), METER_CHANNELS)
	for i in 0 ..< ctx.frames {
		for c in 0 ..< chans {
			x := f64(ctx.outputs[c][i])
			// K-weighted.
			y := k_stage(&m.shelf, c, x)
			y = k_stage(&m.highpass, c, y)
			m.sum[c] += y * y
			// True peak: the sample's four interpolated points.
			m.history[c][m.hist_at] = f32(x)
		}
		for c in 0 ..< chans {
			for ph in 0 ..< 4 {
				acc := 0.0
				for j in 0 ..< TP_TAPS do acc += m.tp[ph][j] * f64(m.history[c][(m.hist_at - j + TP_TAPS) % TP_TAPS])
				m.tp_max = max(m.tp_max, f32(abs(acc)))
			}
		}
		m.hist_at = (m.hist_at + 1) % TP_TAPS
		m.frames += 1
		if m.frames >= m.block_len do loudness_block(m, chans)
	}
	intrinsics.atomic_store(&m.true_peak, transmute(u32)m.tp_max)
}

// [rt] One biquad stage on channel `c` (direct form II transposed).
@(private)
k_stage :: #force_inline proc "contextless" (s: ^K_Stage, c: int, x: f64) -> f64 {
	y := s.b0 * x + s.z1[c]
	s.z1[c] = s.b1 * x - s.a1 * y + s.z2[c]
	s.z2[c] = s.b2 * x - s.a2 * y
	return y
}

// [rt] A 100 ms block is done: its power into the windows, the momentary
// and short-term loudness published, the 400 ms block it ends gated into
// the integrated loudness.
@(private)
loudness_block :: proc "contextless" (m: ^Loudness_Meter, chans: int) {
	p := 0.0
	for c in 0 ..< chans do p += m.sum[c] / f64(m.frames)
	m.sum, m.frames = {}, 0
	m.at = (m.at + 1) % LOUDNESS_SHORT
	m.blocks[m.at] = p
	m.filled = min(m.filled + 1, LOUDNESS_SHORT)
	mean :: proc "contextless" (m: ^Loudness_Meter, n: int) -> f64 {
		k := min(n, m.filled)
		if k == 0 do return 0
		s := 0.0
		for i in 0 ..< k do s += m.blocks[(m.at - i + LOUDNESS_SHORT) % LOUDNESS_SHORT]
		return s / f64(k)
	}
	mp := mean(m, 4)
	intrinsics.atomic_store(&m.momentary, transmute(u32)f32(lufs_of(mp)))
	intrinsics.atomic_store(&m.short_term, transmute(u32)f32(lufs_of(mean(m, LOUDNESS_SHORT))))
	// Gating: a whole 400 ms block over -70 LUFS counts.
	if m.filled < 4 do return
	l := lufs_of(mp)
	if l <= -70 do return
	bin := clamp(int((l + 70) * 10), 0, LOUDNESS_BINS - 1)
	m.hist_power[bin] += mp
	m.hist_count[bin] += 1
	// The integrated loudness: the mean of the gated blocks, then of those
	// within 10 LU of it.
	total, n := 0.0, u32(0)
	for b in 0 ..< LOUDNESS_BINS {
		total += m.hist_power[b]
		n += m.hist_count[b]
	}
	if n == 0 do return
	rel := lufs_of(total / f64(n)) - 10
	from := clamp(int(math.ceil((rel + 70) * 10)), 0, LOUDNESS_BINS)
	total, n = 0, 0
	for b in from ..< LOUDNESS_BINS {
		total += m.hist_power[b]
		n += m.hist_count[b]
	}
	if n > 0 do intrinsics.atomic_store(&m.integrated, transmute(u32)f32(lufs_of(total / f64(n))))
}

// --- the stereo analyser -------------------------------------------------------------------

// Points the stereo analyser keeps for a goniometer.
STEREO_POINTS :: 1024

// Passes audio through unchanged and measures its first two channels'
// stereo image: their phase correlation (+1: the same, 0: unrelated, -1:
// one the other inverted), averaged over about 300 ms, and the latest
// `STEREO_POINTS` (left, right) pairs (every 4th frame) for a goniometer.
// Read from any thread.
Stereo_Analyser :: struct {
	decay:  f64, // per frame, set by prepare
	lr, ll, rr: f64, // the audio thread's running averages
	skip:   int,
	corr:   u32, // atomic: f32 bits
	points: [STEREO_POINTS][2]f32, // written by the audio thread (a torn read only shows a point late)
	at:     u32, // atomic: where the next point goes
}

@(private)
stereo_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		s := (^Stereo_Analyser)(self)
		fs := cfg.sample_rate if cfg.sample_rate > 0 else 48_000
		s.decay = math.exp(-1 / (0.3 * fs))
		s.lr, s.ll, s.rr, s.skip = 0, 0, 0, 0
		return .None
	},
	process = stereo_process,
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Stereo_Analyser)(self), a) },
}

// Control thread. A stereo analyser node (give it as many inputs as
// outputs) and its handle, valid until the graph destroys the node.
stereo_create :: proc(allocator := context.allocator) -> (core.Node, ^Stereo_Analyser) {
	s := new(Stereo_Analyser, allocator)
	return core.node_make(&stereo_vtable, s, allocator), s
}

// Any thread. The phase correlation (-1..+1; 0 for silence).
stereo_correlation :: proc "contextless" (s: ^Stereo_Analyser) -> f32 {
	return transmute(f32)intrinsics.atomic_load(&s.corr)
}

// Any thread. The latest points, oldest first, into `out` (as many as fit;
// `out` up to `STEREO_POINTS` long). Returns how many.
stereo_points :: proc "contextless" (s: ^Stereo_Analyser, out: [][2]f32) -> int {
	at := int(intrinsics.atomic_load(&s.at))
	n := min(len(out), STEREO_POINTS)
	for i in 0 ..< n do out[i] = s.points[(at - n + i + 2 * STEREO_POINTS) % STEREO_POINTS]
	return n
}

// [rt]
@(private)
stereo_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Stereo_Analyser)(self)
	for out, c in ctx.outputs {
		if c < len(ctx.inputs) do copy(out[:ctx.frames], ctx.inputs[c][:ctx.frames])
		else do for &v in out[:ctx.frames] do v = 0
	}
	if len(ctx.outputs) == 0 do return
	left := ctx.outputs[0]
	right := ctx.outputs[1] if len(ctx.outputs) > 1 else ctx.outputs[0]
	at := intrinsics.atomic_load(&s.at)
	k := 1 - s.decay
	for i in 0 ..< ctx.frames {
		l, r := f64(left[i]), f64(right[i])
		s.lr += k * (l * r - s.lr)
		s.ll += k * (l * l - s.ll)
		s.rr += k * (r * r - s.rr)
		s.skip += 1
		if s.skip >= 4 {
			s.skip = 0
			s.points[at % STEREO_POINTS] = {f32(l), f32(r)}
			at = (at + 1) % STEREO_POINTS
		}
	}
	intrinsics.atomic_store(&s.at, at)
	d := math.sqrt(s.ll * s.rr)
	corr: f32 = 0
	if d > 1e-12 do corr = f32(clamp(s.lr / d, -1, 1))
	intrinsics.atomic_store(&s.corr, transmute(u32)corr)
}
