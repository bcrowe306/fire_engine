package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Parameter id of the `Reverb`'s size, in percent (0..100, default 50):
// the delay lines scale from a quarter to twice their base lengths.
REVERB_PARAM_SIZE :: core.Param_Id(1)
// Parameter id of the `Reverb`'s decay time (RT60, the time to fall 60 dB),
// in seconds (0.1..30, default 2).
REVERB_PARAM_DECAY_S :: core.Param_Id(2)
// Parameter id of the `Reverb`'s high-frequency decay, in percent of the
// decay time (5..100, default 50): lower is darker.
REVERB_PARAM_HF_DECAY :: core.Param_Id(3)
// Parameter id of the `Reverb`'s predelay, in ms (0..250, default 10).
REVERB_PARAM_PREDELAY_MS :: core.Param_Id(4)
// Parameter id of the `Reverb`'s input diffusion, in percent (0..100,
// default 70): how quickly echoes become dense.
REVERB_PARAM_DIFFUSION :: core.Param_Id(5)
// Parameter id of the `Reverb`'s modulation, in percent (0..100, default
// 30): slow wobble of the lines, against metallic ringing.
REVERB_PARAM_MODULATION :: core.Param_Id(6)
// Parameter id of the `Reverb`'s mix, in percent (0..100, default 30).
REVERB_PARAM_MIX :: core.Param_Id(7)
// Parameter id of the `Reverb`'s stereo width, in percent (0..100,
// default 100; 0 is mono).
REVERB_PARAM_WIDTH :: core.Param_Id(8)

// Parameter table of the `Reverb` node, as returned by `node_params`. Read-only.
reverb_params := [?]core.Param_Info {
	{id = REVERB_PARAM_SIZE, name = "Size", unit = .Percent, min = 0, max = 100, default = 50, flags = {.Automatable}},
	{id = REVERB_PARAM_DECAY_S, name = "Decay", min = 0.1, max = 30, default = 2, flags = {.Automatable}},
	{id = REVERB_PARAM_HF_DECAY, name = "HF decay", unit = .Percent, min = 5, max = 100, default = 50, flags = {.Automatable}},
	{id = REVERB_PARAM_PREDELAY_MS, name = "Predelay", unit = .Milliseconds, min = 0, max = 250, default = 10, flags = {.Automatable}},
	{id = REVERB_PARAM_DIFFUSION, name = "Diffusion", unit = .Percent, min = 0, max = 100, default = 70, flags = {.Automatable}},
	{id = REVERB_PARAM_MODULATION, name = "Modulation", unit = .Percent, min = 0, max = 100, default = 30, flags = {.Automatable}},
	{id = REVERB_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 30, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = REVERB_PARAM_WIDTH, name = "Width", unit = .Percent, min = 0, max = 100, default = 100, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
}

@(private) FDN_N :: 8
// Base line lengths in ms: no two share a small common factor once in frames.
@(private) fdn_base_ms := [FDN_N]f64{31.7, 37.3, 41.9, 45.4, 53.7, 59.2, 67.1, 73.4}
// Input diffusers, in ms.
@(private) diffuser_ms := [4]f64{4.77, 3.59, 12.73, 9.31}
// Line modulation rates, in Hz (all different, slow).
@(private) fdn_mod_hz := [FDN_N]f64{0.31, 0.43, 0.27, 0.53, 0.37, 0.47, 0.23, 0.59}
// The deepest line modulation, in ms.
@(private) FDN_MOD_MS :: 0.5

// An algorithmic reverb node: an 8-line feedback delay network (Jot and
// Chaigne, "Digital Delay Networks for Designing Artificial Reverberators",
// AES 1991). The lines feed back through a Hadamard matrix, which mixes
// them losslessly, and each line's absorption filter sets the decay time
// at low and at high frequencies exactly. Input is summed to mono,
// delayed and diffused by allpass filters; output is stereo (every output
// channel past the second is silent), the reverb mixed with the dry input.
Reverb :: struct {
	size, decay_s, hf_ratio:  f64,
	predelay_ms, diffusion:   f64,
	modulation:               f64,
	mix, width:               Smoothed_Value, // percent
	lengths:                  [FDN_N]Smoothed_Value, // frames, gliding when the size changes
	gains:                    [FDN_N][2]f64, // absorption filter b, a
	absorb:                   [FDN_N]f64, // filter states
	interp:                   [FDN_N]f64, // allpass interpolator states
	primed:                   bool, // has rendered: before that, size changes jump instead of gliding
	lines:                    [FDN_N]Delay_Line,
	diffusers:                [4]Delay_Line,
	diffuser_frames:          [4]int,
	pre:                      Delay_Line,
	lfo_phase:                [FDN_N]f64,
	sample_rate:              f64,
}

@(private)
reverb_vtable := core.Node_VTable {
	prepare = reverb_prepare,
	process = reverb_process,
	reset   = proc(self: rawptr) {
		r := (^Reverb)(self)
		for &l in r.lines do delay_line_clear(&l)
		for &l in r.diffusers do delay_line_clear(&l)
		delay_line_clear(&r.pre)
		r.absorb, r.interp, r.lfo_phase = {}, {}, {}
		r.primed = false
	},
	release = reverb_release,
	params  = proc(self: rawptr) -> []core.Param_Info { return reverb_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Reverb)(self), allocator) },
	type_id = REVERB_TYPE_ID,
	state_version = 1,
}

// Control thread. Allocates a `Reverb` node at its defaults. Free it with
// `core.node_destroy`.
reverb_create :: proc(allocator := context.allocator) -> core.Node {
	r := new(Reverb, allocator)
	r.size, r.decay_s, r.hf_ratio, r.predelay_ms, r.diffusion, r.modulation = 50, 2, 0.5, 10, 70, 30
	return core.node_make(&reverb_vtable, r, allocator)
}

// [rt] The line length scale at a size in percent: 0.25 to 2.
@(private)
size_scale :: proc "contextless" (size: f64) -> f64 {
	return 0.25 * math.pow(8, size / 100)
}

@(private)
reverb_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	r := (^Reverb)(self)
	r.sample_rate = cfg.sample_rate
	ms := cfg.sample_rate * 0.001
	err: core.Error
	for &l, i in r.lines do if err == .None do err = delay_line_init(&l, int((fdn_base_ms[i] * 2 + FDN_MOD_MS + 1) * ms), allocator)
	for &l, i in r.diffusers do if err == .None do err = delay_line_init(&l, int(diffuser_ms[i] * ms) + 2, allocator)
	if err == .None do err = delay_line_init(&r.pre, int(250 * ms) + 2, allocator)
	if err != .None {
		reverb_release(r, allocator)
		return err
	}
	for i in 0 ..< 4 do r.diffuser_frames[i] = int(diffuser_ms[i] * ms)
	for &l, i in r.lengths do smoothed_init(&l, line_frames(r, i), .One_Pole, 100, cfg.sample_rate)
	smoothed_init_from_param(&r.mix, reverb_params[6], cfg.sample_rate)
	smoothed_init_from_param(&r.width, reverb_params[7], cfg.sample_rate)
	for i in 0 ..< FDN_N do r.lfo_phase[i] = f64(i) / FDN_N
	reverb_decay(r)
	return .None
}

@(private)
reverb_release :: proc(self: rawptr, allocator: mem.Allocator) {
	r := (^Reverb)(self)
	for &l in r.lines do delay_line_destroy(&l, allocator)
	for &l in r.diffusers do delay_line_destroy(&l, allocator)
	delay_line_destroy(&r.pre, allocator)
}

// [rt] Line `i`'s length at the current size, in whole frames: reads at
// whole frames need no interpolation, which would dull every pass.
@(private)
line_frames :: proc "contextless" (r: ^Reverb, i: int) -> f64 {
	return math.round(fdn_base_ms[i] * size_scale(r.size) * r.sample_rate * 0.001)
}

// [rt] Each line's absorption filter, from its target length: a one-pole
// whose gain at DC loses 60 dB per `decay_s` and at Nyquist per
// `decay_s × hf_ratio` (Jot's first-order absorbent filter).
@(private)
reverb_decay :: proc "contextless" (r: ^Reverb) {
	for i in 0 ..< FDN_N {
		n := r.lengths[i].target
		dc := math.pow(10, -3 * n / (r.decay_s * r.sample_rate))
		hf := math.pow(10, -3 * n / (r.decay_s * r.hf_ratio * r.sample_rate))
		a := (dc - hf) / (dc + hf)
		r.gains[i] = {dc * (1 - a), a}
	}
}

// [rt]
@(private)
reverb_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	r := (^Reverb)(self)
	pos := 0
	for e in ctx.events_in {
		reverb_render(r, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case REVERB_PARAM_SIZE:
			r.size = clamp(value, 0, 100)
			for &l, i in r.lengths {
				if r.primed {
					smoothed_set_target(&l, line_frames(r, i))
				} else {
					smoothed_reset(&l, line_frames(r, i))
				}
			}
			reverb_decay(r)
		case REVERB_PARAM_DECAY_S:     r.decay_s = clamp(value, 0.1, 30); reverb_decay(r)
		case REVERB_PARAM_HF_DECAY:    r.hf_ratio = clamp(value, 5, 100) * 0.01; reverb_decay(r)
		case REVERB_PARAM_PREDELAY_MS: r.predelay_ms = clamp(value, 0, 250)
		case REVERB_PARAM_DIFFUSION:   r.diffusion = clamp(value, 0, 100)
		case REVERB_PARAM_MODULATION:  r.modulation = clamp(value, 0, 100)
		case REVERB_PARAM_MIX:         smoothed_apply(&r.mix, clamp(value, 0, 100), frames)
		case REVERB_PARAM_WIDTH:       smoothed_apply(&r.width, clamp(value, 0, 100), frames)
		}
	}
	reverb_render(r, ctx, pos, ctx.frames)
}

// [rt] The fast Walsh-Hadamard transform of 8 values, scaled to keep
// energy (1/√8): an orthogonal matrix with every entry ±1/√8.
@(private)
hadamard8 :: #force_inline proc "contextless" (v: ^[FDN_N]f64) {
	for h := 1; h < FDN_N; h *= 2 {
		for i := 0; i < FDN_N; i += 2 * h {
			for j in i ..< i + h {
				a, b := v[j], v[j + h]
				v[j], v[j + h] = a + b, a - b
			}
		}
	}
	for &x in v do x *= 1 / math.SQRT_TWO / 2 // 1/√8
}

// [rt]
@(private)
reverb_render :: proc(r: ^Reverb, ctx: ^core.Process_Context, from, to: int) {
	outs := len(ctx.outputs)
	ins := min(len(ctx.inputs), outs)
	ms := r.sample_rate * 0.001
	pre := r.predelay_ms * ms
	g := 0.6 * r.diffusion * 0.01 // allpass coefficient
	depth := FDN_MOD_MS * ms * r.modulation * 0.01
	if to > from do r.primed = true
	for i in from ..< to {
		// Mono in, predelayed and diffused.
		x: f64
		for c in 0 ..< ins do x += f64(ctx.inputs[c][i])
		x /= f64(max(ins, 1))
		delay_line_write(&r.pre, f32(x))
		x = f64(delay_line_read(&r.pre, pre, .None))
		for &d, k in r.diffusers { // Schroeder allpass: y = −g·u + delayed, into the line u = x + g·delayed
			delayed := f64(delay_line_read(&d, f64(r.diffuser_frames[k] - 1), .None))
			u := x + g * delayed
			delay_line_write(&d, f32(u))
			x = delayed - g * u
		}
		// The network: read every line, absorb, mix through the matrix, feed back.
		y: [FDN_N]f64
		for k in 0 ..< FDN_N {
			n := smoothed_next(&r.lengths[k])
			if depth > 0 {
				n += depth * math.sin(math.TAU * r.lfo_phase[k])
				r.lfo_phase[k] += fdn_mod_hz[k] / r.sample_rate
				if r.lfo_phase[k] >= 1 do r.lfo_phase[k] -= 1
			}
			// First-order allpass interpolation: gain 1 at every frequency, so
			// modulating the lines doesn't shorten the decay (Hermite reads
			// lose a little treble on every pass). The fraction stays within
			// 0.5..1.5, where the allpass is well behaved; whole lengths read
			// exactly.
			m := int(n - 0.5)
			f := n - f64(m)
			eta := (1 - f) / (1 + f)
			u0 := f64(delay_line_read(&r.lines[k], f64(m - 1), .None))
			u1 := f64(delay_line_read(&r.lines[k], f64(m), .None))
			v := eta * u0 + u1 - eta * r.interp[k]
			r.interp[k] = v
			r.absorb[k] = r.gains[k][0] * v + r.gains[k][1] * r.absorb[k]
			y[k] = r.absorb[k]
		}
		fb := y
		hadamard8(&fb)
		for k in 0 ..< FDN_N do delay_line_write(&r.lines[k], f32(fb[k] + x * (0.5 if k % 2 == 0 else -0.5)))
		// Two orthogonal mixes of the lines for left and right.
		left := (y[0] + y[1] + y[2] + y[3] + y[4] + y[5] + y[6] + y[7]) * 0.35
		right := (y[0] - y[1] + y[2] - y[3] + y[4] - y[5] + y[6] - y[7]) * 0.35
		w := smoothed_next(&r.width) * 0.01
		mid, side := (left + right) * 0.5, (left - right) * 0.5 * w
		wet := [2]f64{mid + side, mid - side}
		mix := smoothed_next(&r.mix) * 0.01
		for c in 0 ..< outs {
			dry := f64(ctx.inputs[c][i]) if c < ins else 0
			ctx.outputs[c][i] = f32((1 - mix) * dry + mix * wet[c]) if c < 2 else 0
		}
	}
}
