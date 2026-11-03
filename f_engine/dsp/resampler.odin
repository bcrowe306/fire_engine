package dsp

import "base:runtime"
import "core:math"
import "core:mem"
import "core:sync"

import "fire:core"

// Interpolation quality: how much of the band is kept flat and how far
// aliases are pushed down, at the cost of taps (multiply-adds) per output
// sample and channel. Above speed 1 the filter widens by the speed, so the
// taps grow with it. Medium suits clip playback; High suits offline work.
//
// | Quality | Taps (speed ≤ 1) | Flat to (× Nyquist) | Aliases and images |
// |---------|------------------|---------------------|--------------------|
// | Low     | 32               | 0.75                | below −60 dB       |
// | Medium  | 80               | 0.85                | below −90 dB       |
// | High    | 160              | 0.90                | below −120 dB      |
Resampler_Quality :: enum u8 {
	Low,
	Medium,
	High,
}

// Converts a stream between sample rates, or plays it faster or slower
// (varispeed), with bandlimited interpolation: each output sample is a
// Kaiser-windowed sinc evaluated at its exact position between input
// samples (Julius O. Smith's method). The speed may change on every call.
//
// Output frame k is the input at time `k × speed` (summed over calls), with
// no added delay; the resampler only needs to see a little input ahead
// (`resampler_input_needed` says how much). Planar f32. Set up with
// `resampler_init`, free with `resampler_destroy`. Fields are internal.
Resampler :: struct {
	channels:  int,
	max_speed: f64,
	quality:   Resampler_Quality,
	table:     ^Sinc_Table,
	history:   int,     // input frames kept behind the read position
	buf:       [][]f32, // per channel: input frames waiting or kept as history
	filled:    int,     // frames in buf
	index:     int,     // read position in buf: whole frames ...
	frac:      f64,     // ... and the fraction, kept apart so that how the
	                    // input is split never changes the arithmetic
}

// One quality's filter, shared by every resampler: the right half of the
// kernel sampled TABLE_STEPS times per zero crossing, plus the differences
// for linear interpolation between entries.
@(private)
Sinc_Table :: struct {
	zero_crossings: int,
	h:              []f32,
	dh:             []f32,
}

@(private)
TABLE_STEPS :: 512

@(private)
tables: [Resampler_Quality]Sinc_Table
@(private)
tables_once: sync.Once

// Control thread. Prepares `r` for `channels` channels, speeds up to
// `max_speed` (input frames per output frame; ≥ 1) and input given in pieces
// of up to `max_input` frames. Free with `resampler_destroy`.
resampler_init :: proc(r: ^Resampler, channels: int, quality := Resampler_Quality.High, max_speed: f64 = 4, max_input := 4096, allocator := context.allocator) -> core.Error {
	if channels < 1 || channels > core.MAX_CHANNELS || !(max_speed >= 1) || max_input < 1 do return .Invalid_Argument
	sync.once_do(&tables_once, build_tables)
	r^ = {channels = channels, max_speed = max_speed, quality = quality, table = &tables[quality]}
	// Both wings span zero_crossings / scale input frames; scale ≥ 1 / max_speed.
	r.history = int(math.ceil(f64(r.table.zero_crossings) * max_speed)) + 2
	ae: mem.Allocator_Error
	r.buf, ae = make([][]f32, channels, allocator)
	if ae != nil do return .Out_Of_Memory
	for &b in r.buf {
		b, ae = make([]f32, 2 * r.history + max_input + 2, allocator)
		if ae != nil {
			resampler_destroy(r, allocator)
			return .Out_Of_Memory
		}
	}
	resampler_reset(r)
	return .None
}

// Control thread. Frees what `resampler_init` allocated.
resampler_destroy :: proc(r: ^Resampler, allocator := context.allocator) {
	for b in r.buf do delete(b, allocator)
	delete(r.buf, allocator)
	r^ = {}
}

// [rt] Forgets all input: the next output frame is the next input frame,
// preceded by silence.
resampler_reset :: proc "contextless" (r: ^Resampler) {
	for b in r.buf do for &s in b[:r.history] do s = 0
	r.filled = r.history
	r.index, r.frac = r.history, 0
}

// [rt] Input frames to add before `out_frames` more output frames can be
// produced at `speed` (0 if enough is buffered). For pull-style playback:
// read this many frames, then call `resampler_process` once.
resampler_input_needed :: proc "contextless" (r: ^Resampler, out_frames: int, speed: f64) -> int {
	if out_frames <= 0 do return 0
	last := r.frac + f64(out_frames - 1) * clamp(speed, 1e-6, r.max_speed)
	need := r.index + int(math.floor(last)) + reach(r, speed) + 1
	return max(need - r.filled, 0)
}

// [rt] Resamples at `speed` input frames per output frame (> 0, at most
// `max_speed`): takes frames from `input` (one slice per channel, all the
// same length) and writes frames to `output` (likewise) until the input is
// used up or the output is full. Returns how many frames were consumed and
// produced. Never allocates.
resampler_process :: proc "contextless" (r: ^Resampler, input, output: [][]f32, speed: f64) -> (consumed, produced: int) {
	step := clamp(speed, 1e-6, r.max_speed)
	in_frames := len(input[0]) if len(input) > 0 else 0
	out_frames := len(output[0]) if len(output) > 0 else 0
	scale := min(1, 1 / step)
	wing := reach(r, step)
	for {
		// Take as much input as fits.
		take := min(in_frames - consumed, len(r.buf[0]) - r.filled)
		for c in 0 ..< r.channels do copy(r.buf[c][r.filled:r.filled + take], input[c][consumed:consumed + take])
		r.filled += take
		consumed += take
		// Produce while the right wing of the next output is buffered.
		start := produced
		for produced < out_frames && r.index + wing < r.filled {
			for c in 0 ..< r.channels do output[c][produced] = interpolate(r.table, r.buf[c], r.index, r.frac, scale)
			r.frac += step
			whole := math.floor(r.frac)
			r.index += int(whole)
			r.frac -= whole
			produced += 1
		}
		// Drop input that has fallen out of the history.
		drop := r.index - r.history
		if drop > 0 {
			for c in 0 ..< r.channels do copy(r.buf[c][:r.filled - drop], r.buf[c][drop:r.filled])
			r.filled -= drop
			r.index -= drop
		}
		if produced == start && take == 0 do return
	}
}

// Input frames each wing of the filter spans at `speed`.
@(private)
reach :: #force_inline proc "contextless" (r: ^Resampler, speed: f64) -> int {
	return int(math.ceil(f64(r.table.zero_crossings) * max(1, speed))) + 1
}

// One output sample at position `n + frac` in `x`: the sum of both
// wings of the kernel, stretched by 1/scale when reading faster than real
// time so it also low-passes below the output Nyquist.
@(private)
interpolate :: #force_inline proc "contextless" (t: ^Sinc_Table, x: []f32, n: int, frac, scale: f64) -> f32 {
	steps := f64(TABLE_STEPS) * scale
	limit := f64(len(t.h) - 1)
	sum: f64
	// Left wing: x[n], x[n-1], ... at distances frac, frac+1, ...
	for k, at := 0, frac * steps; at < limit; k, at = k + 1, at + steps {
		i := int(at)
		sum += f64(x[n - k]) * (f64(t.h[i]) + (at - f64(i)) * f64(t.dh[i]))
	}
	// Right wing: x[n+1], x[n+2], ... at distances 1-frac, 2-frac, ...
	for k, at := 1, (1 - frac) * steps; at < limit; k, at = k + 1, at + steps {
		i := int(at)
		sum += f64(x[n + k]) * (f64(t.h[i]) + (at - f64(i)) * f64(t.dh[i]))
	}
	return f32(sum * scale)
}

@(private)
build_tables :: proc() {
	// Sized from each quality's spec with Kaiser's formulas: passband edge p
	// and attenuation A reached at Nyquist, so the transition band is
	// Δω = π(1 − p); taps N = (A − 8) / (2.285 Δω), β = 0.1102 (A − 8.7), and
	// the cutoff (rolloff) sits mid-transition at (1 + p) / 2.
	params := [Resampler_Quality]struct {
		nz:      int, // zero crossings per wing (N / 2, rounded up)
		beta:    f64,
		rolloff: f64,
	} {
		.Low    = {16, 5.65, 0.875}, // p 0.75, A 60 dB
		.Medium = {40, 8.96, 0.925}, // p 0.85, A 90 dB
		.High   = {80, 12.26, 0.95}, // p 0.90, A 120 dB
	}
	for &t, q in tables {
		p := params[q]
		n := p.nz * TABLE_STEPS
		t.zero_crossings = p.nz
		// Allocated once for the life of the program and never freed, from
		// the heap rather than the first caller's context.allocator, which
		// may be temporary (a test's tracking allocator frees everything when
		// the test ends).
		t.h = make([]f32, n + 1, runtime.heap_allocator())
		t.dh = make([]f32, n + 1, runtime.heap_allocator())
		i0_beta := bessel_i0(p.beta)
		for i in 0 ..= n {
			x := f64(i) / f64(TABLE_STEPS) // distance in input frames
			sinc := 1.0 if i == 0 else math.sin(math.PI * p.rolloff * x) / (math.PI * p.rolloff * x)
			w := x / f64(p.nz)
			window := bessel_i0(p.beta * math.sqrt(max(0, 1 - w * w))) / i0_beta
			t.h[i] = f32(p.rolloff * sinc * window)
		}
		for i in 0 ..< n do t.dh[i] = t.h[i + 1] - t.h[i]
	}
}

// Modified Bessel function of the first kind, order 0 (for the Kaiser window).
@(private)
bessel_i0 :: proc(x: f64) -> f64 {
	sum, term := 1.0, 1.0
	for k in 1 ..< 200 {
		term *= (x / (2 * f64(k))) * (x / (2 * f64(k)))
		sum += term
		if term < sum * 1e-17 do break
	}
	return sum
}
