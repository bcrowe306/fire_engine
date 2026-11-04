package dsp

import "core:mem"

import "fire:core"

// Taps of the impulse response convolved directly (no latency).
CONVOLVER_HEAD :: 64
// Where the large partitions start, and their size: taps from
// CONVOLVER_SPLIT on use CONVOLVER_SPLIT / 2-frame partitions.
CONVOLVER_SPLIT :: 2048

// Zero-latency convolution with one impulse response, for one channel.
// The first `CONVOLVER_HEAD` taps are a direct FIR; taps up to
// `CONVOLVER_SPLIT` use 64-frame FFT partitions; the rest use 1024-frame
// partitions whose work is spread over the 1024 frames after each block
// arrives, so a long response costs the same every frame instead of in
// spikes (uniformly partitioned overlap-save at two sizes, after
// Gardner, "Efficient Convolution without Input-Output Delay", JAES 1995).
// Set up with `convolver_init`. Fields are internal.
Convolver :: struct {
	head:      []f32, // the first taps
	history:   []f32, // the last CONVOLVER_HEAD inputs, twice (so reads never wrap)
	hpos:      int,
	levels:    [2]Conv_Level,
	n_levels:  int,
	out:       []f32, // ring of future output from the partitions, by frame
	mask:      int,
	frame:     i64,
}

@(private)
Conv_Level :: struct {
	size:     int, // partition size P
	start:    int, // first tap
	parts:    int,
	spread:   bool, // work spread over the next P frames
	fft:      Real_Fft, // 2P
	kernel:   []complex64, // parts × P bins
	fdl:      []complex64, // parts × P bins: the input spectra, newest at `fdl_head`
	fdl_head: int,
	input:    []f32, // 2P: the previous block, then the one filling
	fill:     int,
	acc:      []complex64, // P bins being summed
	time:     []f32, // 2P
	done:     int, // spread: partitions summed for the last block
	since:    int, // spread: frames since the last block arrived; -1 = no work
	block_at: i64, // the frame the last block started at
	scale:    f32,
}

// Control thread. Prepares a convolver for impulse response `ir` (any
// length ≥ 1; copied). Free with `convolver_destroy`.
convolver_init :: proc(c: ^Convolver, ir: []f32, allocator := context.allocator) -> (err: core.Error) {
	c^ = {}
	if len(ir) == 0 do return .Invalid_Argument
	defer if err != .None do convolver_destroy(c, allocator)
	ae: mem.Allocator_Error
	c.head, ae = make([]f32, CONVOLVER_HEAD, allocator)
	if ae == nil do c.history, ae = make([]f32, 2 * CONVOLVER_HEAD, allocator)
	if ae != nil do return .Out_Of_Memory
	copy(c.head, ir[:min(len(ir), CONVOLVER_HEAD)])
	// The partitions: 64 frames for taps 64..2048, 1024 for the rest.
	horizon := 0
	if len(ir) > CONVOLVER_HEAD {
		end := min(len(ir), CONVOLVER_SPLIT)
		level_init(&c.levels[0], ir[CONVOLVER_HEAD:end], CONVOLVER_HEAD, CONVOLVER_HEAD, false, allocator) or_return
		c.n_levels = 1
		horizon = CONVOLVER_SPLIT + 2 * CONVOLVER_HEAD
	}
	if len(ir) > CONVOLVER_SPLIT {
		level_init(&c.levels[1], ir[CONVOLVER_SPLIT:], CONVOLVER_SPLIT / 2, CONVOLVER_SPLIT, true, allocator) or_return
		c.n_levels = 2
		horizon = CONVOLVER_SPLIT + CONVOLVER_SPLIT
	}
	n := 2
	for n < horizon + 2 do n *= 2
	c.out, ae = make([]f32, n, allocator)
	if ae != nil do return .Out_Of_Memory
	c.mask = n - 1
	return .None
}

@(private)
level_init :: proc(l: ^Conv_Level, taps: []f32, size, start: int, spread: bool, allocator: mem.Allocator) -> core.Error {
	l^ = {size = size, start = start, spread = spread, since = -1}
	l.parts = (len(taps) + size - 1) / size
	real_fft_init(&l.fft, 2 * size, allocator = allocator) or_return
	ae: mem.Allocator_Error
	l.kernel, ae = make([]complex64, l.parts * size, allocator)
	if ae == nil do l.fdl, ae = make([]complex64, l.parts * size, allocator)
	if ae == nil do l.input, ae = make([]f32, 2 * size, allocator)
	if ae == nil do l.acc, ae = make([]complex64, size, allocator)
	if ae == nil do l.time, ae = make([]f32, 2 * size, allocator)
	if ae != nil do return .Out_Of_Memory
	// The forward-then-inverse gain of this transform, measured, so the
	// kernel can carry its inverse.
	for &x in l.time do x = 0
	l.time[0] = 1
	real_fft_forward(&l.fft, l.time, l.acc)
	real_fft_inverse(&l.fft, l.acc, l.time)
	l.scale = 1 / l.time[0]
	for j in 0 ..< l.parts {
		for &x in l.time do x = 0
		seg := taps[j * size:][:min(size, len(taps) - j * size)]
		for x, i in seg do l.time[i] = x * l.scale
		real_fft_forward(&l.fft, l.time, l.kernel[j * size:][:size])
	}
	for &x in l.time do x = 0
	return .None
}

// Control thread. Frees what `convolver_init` allocated.
convolver_destroy :: proc(c: ^Convolver, allocator := context.allocator) {
	delete(c.head, allocator)
	delete(c.history, allocator)
	delete(c.out, allocator)
	for &l in c.levels {
		real_fft_destroy(&l.fft, allocator)
		delete(l.kernel, allocator)
		delete(l.fdl, allocator)
		delete(l.input, allocator)
		delete(l.acc, allocator)
		delete(l.time, allocator)
	}
	c^ = {}
}

// [rt] Silences the convolver's memory of past input.
convolver_reset :: proc "contextless" (c: ^Convolver) {
	for &x in c.history do x = 0
	for &x in c.out do x = 0
	c.hpos, c.frame = 0, 0
	for &l in c.levels[:c.n_levels] {
		for &x in l.fdl do x = 0
		for &x in l.input do x = 0
		l.fill, l.fdl_head, l.done, l.since = 0, 0, 0, -1
	}
}

// [rt] Convolves `input` into `output` (the same length; they may be the
// same slice). Any length per call: the result never depends on how the
// signal is split into calls.
convolver_process :: proc "contextless" (c: ^Convolver, input, output: []f32) {
	for x, i in input {
		y := head_tick(c, x)
		for &l in c.levels[:c.n_levels] do level_tick(c, &l, x)
		slot := int(c.frame) & c.mask
		output[i] = y + c.out[slot]
		c.out[slot] = 0
		c.frame += 1
	}
}

// [rt] The direct part: the first taps against the last inputs.
@(private)
head_tick :: #force_inline proc "contextless" (c: ^Convolver, x: f32) -> f32 #no_bounds_check {
	c.hpos = (c.hpos + CONVOLVER_HEAD - 1) % CONVOLVER_HEAD
	c.history[c.hpos] = x
	c.history[c.hpos + CONVOLVER_HEAD] = x
	h := c.history[c.hpos:][:CONVOLVER_HEAD] // newest first
	y: f32
	for k in 0 ..< CONVOLVER_HEAD do y += c.head[k] * h[k]
	return y
}

// [rt] One frame of a partitioned level: collect it; when a block is full,
// transform it and sum (or start summing) the partitions.
@(private)
level_tick :: proc "contextless" (c: ^Convolver, l: ^Conv_Level, x: f32) {
	p := l.size
	l.input[p + l.fill] = x
	l.fill += 1
	if l.fill == p {
		l.block_at = c.frame - i64(p - 1)
		l.fdl_head = (l.fdl_head + l.parts - 1) % l.parts
		real_fft_forward(&l.fft, l.input, l.fdl[l.fdl_head * p:][:p])
		copy(l.input[:p], l.input[p:])
		l.fill = 0
		for &v in l.acc do v = 0
		l.done = 0
		if !l.spread {
			sum_parts(l, l.parts)
			finish_block(c, l)
			return
		}
		l.since = 0
		return
	}
	if l.since >= 0 { // spread: a share of the partitions each frame, done in p − 1 frames
		l.since += 1
		sum_parts(l, (l.parts * l.since + p - 2) / (p - 1))
		if l.since == p - 1 {
			finish_block(c, l)
			l.since = -1
		}
	}
}

// [rt] Sums partitions up to `upto` (in order, so the result is the same
// however the work is spread).
@(private)
sum_parts :: proc "contextless" (l: ^Conv_Level, upto: int) #no_bounds_check {
	p := l.size
	for ; l.done < min(upto, l.parts); l.done += 1 {
		j := l.done
		x := l.fdl[((l.fdl_head + j) % l.parts) * p:][:p]
		h := l.kernel[j * p:][:p]
		// Bin 0 holds DC and Nyquist, both real: multiply them apart.
		l.acc[0] += complex(real(x[0]) * real(h[0]), imag(x[0]) * imag(h[0]))
		for k in 1 ..< p do l.acc[k] += x[k] * h[k]
	}
}

// [rt] Transforms the summed spectrum back and adds its valid half to the
// output, `start` frames after the block.
@(private)
finish_block :: proc "contextless" (c: ^Convolver, l: ^Conv_Level) #no_bounds_check {
	p := l.size
	real_fft_inverse(&l.fft, l.acc, l.time)
	at := l.block_at + i64(l.start)
	for i in 0 ..< p do c.out[int(at + i64(i)) & c.mask] += l.time[p + i]
}

// Parameter id of the `Convolution` node's mix, in percent (0..100, default 100).
CONVOLUTION_PARAM_MIX :: core.Param_Id(1)
// Parameter id of the `Convolution` node's wet level, in dB (−60..12, default 0).
CONVOLUTION_PARAM_WET_DB :: core.Param_Id(2)

// Parameter table of the `Convolution` node, as returned by `node_params`. Read-only.
convolution_params := [?]core.Param_Info {
	{id = CONVOLUTION_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 100, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = CONVOLUTION_PARAM_WET_DB, name = "Wet", unit = .Decibels, min = -60, max = 12, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
}

// A convolution node (reverb from a recorded space, cabinet and speaker
// simulation, any long FIR) with no latency. Its impulse response has one
// channel for every output, or one per output channel. The response is
// used as given: at the graph's sample rate (convert it with `Resampler`).
Convolution :: struct {
	ir:          [][]f32, // copied at create
	convolvers:  []Convolver,
	wet:         []f32, // a block of one channel's convolution
	mix, wet_db: Smoothed_Value,
	allocator:   mem.Allocator,
}

@(private)
convolution_vtable := core.Node_VTable {
	prepare = convolution_prepare,
	process = convolution_process,
	reset   = proc(self: rawptr) {
		v := (^Convolution)(self)
		for &c in v.convolvers do convolver_reset(&c)
	},
	release = convolution_release,
	params  = proc(self: rawptr) -> []core.Param_Info { return convolution_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		v := (^Convolution)(self)
		for ch in v.ir do delete(ch, v.allocator)
		delete(v.ir, v.allocator)
		free(v, v.allocator)
	},
}

// Control thread. A `Convolution` node with impulse response `ir` (planar,
// copied). The FFTs of the response are made when the node is prepared.
// Free it with `core.node_destroy`.
convolution_create :: proc(ir: [][]f32, allocator := context.allocator) -> core.Node {
	v := new(Convolution, allocator)
	v.allocator = allocator
	v.ir = make([][]f32, len(ir), allocator)
	for ch, i in ir {
		v.ir[i] = make([]f32, len(ch), allocator)
		copy(v.ir[i], ch)
	}
	return core.node_make(&convolution_vtable, v, allocator)
}

@(private)
convolution_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	v := (^Convolution)(self)
	if len(v.ir) == 0 do return .Invalid_Argument
	ae: mem.Allocator_Error
	v.convolvers, ae = make([]Convolver, cfg.out_channels, allocator)
	if ae == nil do v.wet, ae = make([]f32, cfg.max_block, allocator)
	if ae != nil {
		convolution_release(v, allocator)
		return .Out_Of_Memory
	}
	for &c, i in v.convolvers {
		if err := convolver_init(&c, v.ir[min(i, len(v.ir) - 1)], allocator); err != .None {
			convolution_release(v, allocator)
			return err
		}
	}
	smoothed_init_from_param(&v.mix, convolution_params[0], cfg.sample_rate)
	smoothed_init_from_param(&v.wet_db, convolution_params[1], cfg.sample_rate)
	return .None
}

@(private)
convolution_release :: proc(self: rawptr, allocator: mem.Allocator) {
	v := (^Convolution)(self)
	for &c in v.convolvers do convolver_destroy(&c, allocator)
	delete(v.convolvers, allocator)
	delete(v.wet, allocator)
	v.convolvers, v.wet = nil, nil
}

// [rt]
@(private)
convolution_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	v := (^Convolution)(self)
	pos := 0
	for e in ctx.events_in {
		convolution_render(v, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case CONVOLUTION_PARAM_MIX:    smoothed_apply(&v.mix, clamp(value, 0, 100), frames)
		case CONVOLUTION_PARAM_WET_DB: smoothed_apply(&v.wet_db, clamp(value, -60, 12), frames)
		}
	}
	convolution_render(v, ctx, pos, ctx.frames)
}

// [rt]
@(private)
convolution_render :: proc(v: ^Convolution, ctx: ^core.Process_Context, from, to: int) {
	if to <= from do return
	outs := min(len(ctx.outputs), len(v.convolvers))
	ins := min(len(ctx.inputs), outs)
	// The mix is smoothed per frame, the same for every channel.
	mix_s, wet_s := v.mix, v.wet_db
	for c in 0 ..< outs {
		v.mix, v.wet_db = mix_s, wet_s
		x := ctx.inputs[c][from:to] if c < ins else nil
		wet := v.wet[:to - from]
		if x != nil {
			convolver_process(&v.convolvers[c], x, wet)
		} else {
			for &s in wet do s = 0
		}
		for i in 0 ..< to - from {
			mix := smoothed_next(&v.mix) * 0.01
			k := mix * db_to_gain(smoothed_next(&v.wet_db))
			dry := x[i] if x != nil else 0
			ctx.outputs[c][from + i] = f32(1 - mix) * dry + f32(k) * wet[i]
		}
	}
	for c in outs ..< len(ctx.outputs) do for i in from ..< to do ctx.outputs[c][i] = 0
}
