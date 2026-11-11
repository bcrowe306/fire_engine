package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Taps of each 2× stage of an `Oversampler`, the first (the steepest)
// first. Each is 4k + 3 long, a halfband filter whose ends are not zero.
@(private) halfband_taps := [3]int{63, 31, 19}

// Raises one channel to 2, 4 or 8 times its sample rate and back, so a
// nonlinear process (saturation, clipping) can run where its harmonics
// have room instead of folding back as aliasing. Each 2× stage is a
// linear-phase halfband FIR (Kaiser-windowed sinc, about 90 dB of image
// and alias rejection; the first stage passes up to 0.45 of the base
// rate). Run `oversampler_up`, process what it returns at the high rate,
// then `oversampler_down`. The round trip delays by `oversampler_latency`
// frames exactly. Fields are internal.
Oversampler :: struct {
	factor:  int,
	stages:  int,
	up:      [3]Halfband,
	down:    [3]Halfband,
	buffers: [3][]f32, // stage i's output at 2^(i+1)× the block size
	pad:     Delay_Line, // aligns the round trip to whole base frames
	pad_frames: int,
	latency: int,
}

@(private)
Halfband :: struct {
	taps:    []f64, // h, centre at len/2
	history: []f32, // the last len(taps) inputs at this filter's input rate, twice (reads never wrap)
	pos:     int,
	phase:   int, // down: which input sample of the pair this is
}

// Control thread. Prepares an oversampler of `factor` 2, 4 or 8 for
// blocks of up to `max_block` frames. Free with `oversampler_destroy`.
oversampler_init :: proc(o: ^Oversampler, factor, max_block: int, allocator := context.allocator) -> (err: core.Error) {
	o^ = {}
	switch factor {
	case 2: o.stages = 1
	case 4: o.stages = 2
	case 8: o.stages = 3
	case:   return .Invalid_Argument
	}
	o.factor = factor
	defer if err != .None do oversampler_destroy(o, allocator)
	// Delay through stage i and back, in frames at the top rate.
	top := 0.0
	for i in 0 ..< o.stages {
		n := halfband_taps[i]
		halfband_init(&o.up[i], n, allocator) or_return
		halfband_init(&o.down[i], n, allocator) or_return
		b, ae := make([]f32, max_block << uint(i + 1), allocator)
		if ae != nil do return .Out_Of_Memory
		o.buffers[i] = b
		top += f64(n - 1) / f64(int(1) << uint(i + 1)) * f64(factor) // both directions, in base frames, at the top rate
	}
	whole := int(math.ceil(top / f64(factor) - 1e-9))
	o.pad_frames = whole * factor - int(math.round(top))
	o.latency = whole
	delay_line_init(&o.pad, o.pad_frames + 1, allocator) or_return
	return .None
}

@(private)
halfband_init :: proc(h: ^Halfband, n: int, allocator: mem.Allocator) -> core.Error {
	ae: mem.Allocator_Error
	h.taps, ae = make([]f64, n, allocator)
	if ae == nil do h.history, ae = make([]f32, 2 * n, allocator)
	if ae != nil do return .Out_Of_Memory
	// A sinc at a quarter of the stage's high rate, under a Kaiser window
	// (β = 8: about 90 dB down outside the transition band).
	c := n / 2
	beta := 8.0
	sum := 0.0
	for &t, i in h.taps {
		x := f64(i - c)
		sinc := 0.5 if x == 0 else math.sin(math.PI * x / 2) / (math.PI * x)
		r := 2 * f64(i) / f64(n - 1) - 1
		t = sinc * bessel_i0(beta * math.sqrt(max(1 - r * r, 0))) / bessel_i0(beta)
		sum += t
	}
	for &t in h.taps do t /= sum // unity gain at DC
	return .None
}

// Control thread. Frees what `oversampler_init` allocated.
oversampler_destroy :: proc(o: ^Oversampler, allocator := context.allocator) {
	for i in 0 ..< 3 {
		delete(o.up[i].taps, allocator)
		delete(o.up[i].history, allocator)
		delete(o.down[i].taps, allocator)
		delete(o.down[i].history, allocator)
		delete(o.buffers[i], allocator)
	}
	delay_line_destroy(&o.pad, allocator)
	o^ = {}
}

// [rt] Clears the filters' memory.
oversampler_reset :: proc "contextless" (o: ^Oversampler) {
	for i in 0 ..< o.stages {
		for &x in o.up[i].history do x = 0
		for &x in o.down[i].history do x = 0
		o.up[i].pos, o.down[i].pos, o.down[i].phase = 0, 0, 0
	}
	delay_line_clear(&o.pad)
}

// [rt] The round trip's delay, in base-rate frames.
oversampler_latency :: proc "contextless" (o: ^Oversampler) -> int {
	return o.latency
}

// [rt] Pushes one sample into a halfband filter's history and returns the
// newest-first view of its last `len(taps)` inputs.
@(private)
halfband_push :: #force_inline proc "contextless" (h: ^Halfband, x: f32) -> []f32 #no_bounds_check {
	n := len(h.taps)
	h.pos = h.pos - 1 if h.pos > 0 else n - 1 // not %: a division per sample
	h.history[h.pos] = x
	h.history[h.pos + n] = x
	return h.history[h.pos:][:n]
}

// [rt] Upsamples `input` by `factor` into the oversampler's buffer, and
// returns it (factor × len(input) frames, valid until the next call).
oversampler_up :: proc "contextless" (o: ^Oversampler, input: []f32) -> []f32 #no_bounds_check {
	src := input
	for i in 0 ..< o.stages {
		h := &o.up[i]
		dst := o.buffers[i][:2 * len(src)]
		n := len(h.taps)
		for x, m in src {
			// Zero-stuffed: the even output sees the new sample at even taps
			// (all zero in a halfband but the centre), the odd one at odd taps.
			// The odd taps of a halfband are zero but the centre (n = 4k + 3
			// puts it at an odd index), so the odd output is one product.
			hist := halfband_push(h, x)
			even: f64
			for k := 0; k < n; k += 2 do even += h.taps[k] * f64(hist[k / 2])
			c := n / 2
			dst[2 * m] = f32(2 * even)
			dst[2 * m + 1] = f32(2 * h.taps[c] * f64(hist[c / 2]))
		}
		src = dst
	}
	return src
}

// [rt] Downsamples the high-rate `input` (factor × len(output) frames: what
// `oversampler_up` returned, or audio made at the high rate) into `output`.
oversampler_down :: proc "contextless" (o: ^Oversampler, input: []f32, output: []f32) #no_bounds_check {
	src := input
	// The alignment delay, at the top rate (into the top buffer: the
	// input may be it, as `oversampler_up` returned, or any other).
	if o.pad_frames > 0 {
		top := o.buffers[o.stages - 1][:len(src)]
		for x, i in src {
			delay_line_write(&o.pad, x)
			top[i] = delay_line_read(&o.pad, f64(o.pad_frames), .None)
		}
		src = top
	}
	for i := o.stages - 1; i >= 0; i -= 1 {
		h := &o.down[i]
		dst := output if i == 0 else o.buffers[i - 1][:len(src) / 2]
		n := len(h.taps)
		for x, j in src {
			hist := halfband_push(h, x)
			if j % 2 == 0 { // keep the even outputs: the delay is then (n − 1) / 2 exactly
				y := h.taps[n / 2] * f64(hist[n / 2]) // the one odd tap that isn't zero
				for k := 0; k < n; k += 2 do y += h.taps[k] * f64(hist[k])
				dst[j / 2] = f32(y)
			}
		}
		src = dst
	}
}
