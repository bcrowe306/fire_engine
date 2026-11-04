package dsp

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"

// Parameter id of the `Limiter`'s ceiling, in dB (−30..0, default −0.3):
// no output sample exceeds it.
LIMITER_PARAM_CEILING_DB :: core.Param_Id(1)
// Parameter id of the `Limiter`'s input gain, in dB (0..30, default 0): to
// push the signal into it.
LIMITER_PARAM_INPUT_DB :: core.Param_Id(2)
// Parameter id of the `Limiter`'s release, in ms (1..2000, default 100).
LIMITER_PARAM_RELEASE_MS :: core.Param_Id(3)

// Parameter table of the `Limiter` node, as returned by `node_params`. Read-only.
limiter_params := [?]core.Param_Info {
	{id = LIMITER_PARAM_CEILING_DB, name = "Ceiling", unit = .Decibels, min = -30, max = 0, default = -0.3, flags = {.Automatable}},
	{id = LIMITER_PARAM_INPUT_DB, name = "Input", unit = .Decibels, min = 0, max = 30, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = LIMITER_PARAM_RELEASE_MS, name = "Release", unit = .Milliseconds, min = 1, max = 2000, default = 100, flags = {.Automatable}},
}

// A lookahead peak limiter: no output sample is above the ceiling, ever.
// It looks `lookahead_ms` ahead (reported as the node's latency, which the
// graph compensates), finds the smallest gain any sample in that window
// needs, and smooths it with a moving average of the same length, which
// can never rise above what a sample needs while it plays; a slower
// release then lets the gain recover. Stereo-linked.
//
// The ceiling holds for samples, not for the waveform between them: after
// a DAC or a sample-rate conversion, inter-sample peaks can be up to about
// 0.5 dB higher on dense material.
Limiter :: struct {
	ceiling_db, release_ms: f64,
	input:                  Smoothed_Value, // dB
	lookahead:              int,   // frames
	delay:                  []f32, // per channel ring of `lookahead`, flattened
	need:                   []f64, // ring of each frame's needed gain, `lookahead` long
	window:                 Min_Window,
	sum:                    f64, // of the window minimums in the box, `lookahead` long
	box:                    []f64, // ring of the window minimums
	gain:                   f64,   // after the release
	release:                f64,   // per-frame recovery coefficient
	at:                     int,   // ring position
	frames_since_sum:       int,
	channels:               int,
	lookahead_ms:           f64,
	sample_rate:            f64,
	meter:                  u64,   // atomic: f64 bits of the gain reduction in dB at the end of the last block
}

// A sliding-window minimum over the last `len(values)` values, in O(1)
// amortised per value (a monotonic deque).
@(private)
Min_Window :: struct {
	index: []int, // positions in the deque, oldest first, values increasing
	value: []f64,
	head, count: int,
	n:     int, // values pushed
}

@(private)
limiter_vtable := core.Node_VTable {
	prepare = limiter_prepare,
	process = limiter_process,
	reset   = limiter_reset,
	release = limiter_release,
	latency = proc(self: rawptr) -> int { return (^Limiter)(self).lookahead - 1 },
	params  = proc(self: rawptr) -> []core.Param_Info { return limiter_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Limiter)(self), allocator) },
}

// Control thread. Allocates a `Limiter` node looking `lookahead_ms` ahead
// (0.1..50; its latency, fixed for the node's life). Free it with
// `core.node_destroy`.
limiter_create :: proc(lookahead_ms := 5.0, allocator := context.allocator) -> core.Node {
	l := new(Limiter, allocator)
	l.ceiling_db, l.release_ms, l.lookahead_ms = -0.3, 100, clamp(lookahead_ms, 0.1, 50)
	return core.node_make(&limiter_vtable, l, allocator)
}

// [rt] The limiter's gain reduction in dB at the end of its last block. Any thread.
limiter_gain_reduction_db :: proc "contextless" (l: ^Limiter) -> f64 {
	return transmute(f64)intrinsics.atomic_load_explicit(&l.meter, .Relaxed)
}

@(private)
limiter_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	l := (^Limiter)(self)
	l.sample_rate, l.channels = cfg.sample_rate, cfg.out_channels
	l.lookahead = max(int(l.lookahead_ms * 0.001 * cfg.sample_rate + 0.5), 1)
	ae: mem.Allocator_Error
	l.delay, ae = make([]f32, l.lookahead * max(l.channels, 1), allocator)
	if ae == nil do l.need, ae = make([]f64, l.lookahead, allocator)
	if ae == nil do l.box, ae = make([]f64, l.lookahead, allocator)
	if ae == nil do l.window.index, ae = make([]int, l.lookahead, allocator)
	if ae == nil do l.window.value, ae = make([]f64, l.lookahead, allocator)
	if ae != nil {
		limiter_release(l, allocator)
		return .Out_Of_Memory
	}
	smoothed_init_from_param(&l.input, limiter_params[1], cfg.sample_rate)
	limiter_times(l)
	limiter_reset(l)
	return .None
}

@(private)
limiter_release :: proc(self: rawptr, allocator: mem.Allocator) {
	l := (^Limiter)(self)
	delete(l.delay, allocator)
	delete(l.need, allocator)
	delete(l.box, allocator)
	delete(l.window.index, allocator)
	delete(l.window.value, allocator)
	l.delay, l.need, l.box, l.window.index, l.window.value = nil, nil, nil, nil, nil
}

@(private)
limiter_reset :: proc(self: rawptr) {
	l := (^Limiter)(self)
	for &x in l.delay do x = 0
	for &x in l.need do x = 1
	for &x in l.box do x = 1
	l.sum, l.gain, l.at, l.frames_since_sum = f64(l.lookahead), 1, 0, 0
	l.window.head, l.window.count, l.window.n = 0, 0, 0
	smoothed_reset(&l.input, l.input.target)
}

@(private)
limiter_times :: proc "contextless" (l: ^Limiter) {
	l.release = 1 - time_coeff(l.release_ms, l.sample_rate)
}

// [rt]
@(private)
limiter_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	l := (^Limiter)(self)
	pos := 0
	for e in ctx.events_in {
		limiter_render(l, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case LIMITER_PARAM_CEILING_DB: l.ceiling_db = clamp(value, -30, 0)
		case LIMITER_PARAM_INPUT_DB:   smoothed_apply(&l.input, clamp(value, 0, 30), frames)
		case LIMITER_PARAM_RELEASE_MS: l.release_ms = clamp(value, 1, 2000); limiter_times(l)
		}
	}
	limiter_render(l, ctx, pos, ctx.frames)
	intrinsics.atomic_store_explicit(&l.meter, transmute(u64)(-20 * math.log10(max(l.gain, 1e-10))), .Relaxed)
}

// [rt] Pushes `v` and returns the minimum of the last `len` values.
@(private)
min_window_push :: #force_inline proc "contextless" (w: ^Min_Window, v: f64) -> f64 {
	size := len(w.value)
	for w.count > 0 && w.value[(w.head + w.count - 1) % size] >= v do w.count -= 1 // dominated
	if w.count > 0 && w.index[w.head] <= w.n - size { // fell out of the window
		w.head = (w.head + 1) % size
		w.count -= 1
	}
	slot := (w.head + w.count) % size
	w.index[slot], w.value[slot] = w.n, v
	w.count += 1
	w.n += 1
	return w.value[w.head]
}

// [rt]
@(private)
limiter_render :: proc(l: ^Limiter, ctx: ^core.Process_Context, from, to: int) {
	outs := len(ctx.outputs)
	ins := min(len(ctx.inputs), outs, l.channels)
	n := l.lookahead
	ceiling := db_to_gain(l.ceiling_db)
	for i in from ..< to {
		k := db_to_gain(smoothed_next(&l.input))
		peak := 0.0
		for ch in 0 ..< ins do peak = max(peak, abs(f64(ctx.inputs[ch][i]) * k))
		need := ceiling / peak if peak > ceiling else 1
		// The smallest gain needed by any of the last n frames, then its
		// average over the last n: every term of that average is a minimum
		// over a window containing the frame about to play, so the average
		// is never above what that frame needs.
		m := min_window_push(&l.window, need)
		l.sum += m - l.box[l.at]
		l.box[l.at] = m
		l.frames_since_sum += 1
		if l.frames_since_sum >= 1 << 16 { // keep the running sum exact
			l.sum, l.frames_since_sum = 0, 0
			for x in l.box do l.sum += x
		}
		smooth := min(l.sum / f64(n), 1)
		// Release: rise slowly towards the smoothed gain, fall to it at once,
		// so it is never above it.
		l.gain = min(smooth, l.gain + (smooth - l.gain) * l.release) if smooth > l.gain else smooth
		// Delay by n - 1: the frame pushed n - 1 frames ago is the oldest in
		// every window just averaged.
		g := f32(l.gain)
		for ch in 0 ..< ins {
			ring := l.delay[ch * n:][:n]
			out := ring[(l.at + 1) % n] if n > 1 else f32(f64(ctx.inputs[ch][i]) * k)
			ring[l.at] = f32(f64(ctx.inputs[ch][i]) * k)
			ctx.outputs[ch][i] = out * g
		}
		l.at = (l.at + 1) % n
	}
	for ch in ins ..< outs do for i in from ..< to do ctx.outputs[ch][i] = 0
}
