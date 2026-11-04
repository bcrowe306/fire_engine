package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Parameter id of the `One_Pole_Lowpass` cutoff, in Hz (10..20000, default 1000).
ONE_POLE_PARAM_CUTOFF_HZ :: core.Param_Id(1)

// Parameter table of the `One_Pole_Lowpass` node, as returned by `node_params`. Read-only.
one_pole_params := [?]core.Param_Info {
	{
		id = ONE_POLE_PARAM_CUTOFF_HZ, name = "Cutoff", unit = .Hertz,
		min = 10, max = 20000, default = 1000,
		smoothing = .Linear, smoothing_ms = 20,
		flags = {.Automatable},
	},
}

// One-pole lowpass, topology-preserving transform (Zavalishin, "The Art of VA
// Filter Design", ch. 3). Exactly -3.01 dB at cutoff thanks to prewarping.
One_Pole_Lowpass :: struct {
	cutoff:      Smoothed_Value, // Hz
	g:           f64,            // G = g / (1 + g), g = tan(pi fc / fs)
	state:       []f64,          // one per channel, allocated in prepare
	sample_rate: f64,
}

@(private)
one_pole_vtable := core.Node_VTable {
	prepare = one_pole_prepare,
	process = one_pole_process,
	reset   = one_pole_reset,
	release = one_pole_release,
	params  = proc(self: rawptr) -> []core.Param_Info { return one_pole_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^One_Pole_Lowpass)(self), allocator) },
}

// Control thread. Allocates a `One_Pole_Lowpass` node with `allocator`. Free it
// with `core.node_destroy`. Each output channel filters the matching input
// channel (silence for extra outputs).
one_pole_create :: proc(allocator := context.allocator) -> core.Node {
	f := new(One_Pole_Lowpass, allocator)
	return core.node_make(&one_pole_vtable, f, allocator)
}

@(private)
one_pole_coeff :: #force_inline proc "contextless" (cutoff_hz, sample_rate: f64) -> f64 {
	fc := clamp(cutoff_hz, 1, sample_rate * 0.49)
	g := math.tan(math.PI * fc / sample_rate)
	return g / (1 + g)
}

@(private)
one_pole_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	f := (^One_Pole_Lowpass)(self)
	err: mem.Allocator_Error
	f.state, err = make([]f64, cfg.out_channels, allocator)
	if err != nil do return .Out_Of_Memory
	f.sample_rate = cfg.sample_rate
	smoothed_init_from_param(&f.cutoff, one_pole_params[0], cfg.sample_rate)
	f.g = one_pole_coeff(f.cutoff.current, f.sample_rate)
	return .None
}

@(private)
one_pole_release :: proc(self: rawptr, allocator: mem.Allocator) {
	f := (^One_Pole_Lowpass)(self)
	delete(f.state, allocator)
	f.state = nil
}

@(private)
one_pole_reset :: proc(self: rawptr) {
	f := (^One_Pole_Lowpass)(self)
	for &s in f.state do s = 0
	smoothed_reset(&f.cutoff, f.cutoff.target)
	f.g = one_pole_coeff(f.cutoff.current, f.sample_rate)
}

// [rt]
@(private)
one_pole_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	f := (^One_Pole_Lowpass)(self)
	pos := 0
	for e in ctx.events_in {
		one_pole_render(f, ctx, pos, int(e.offset))
		pos = int(e.offset)
		if hz, frames, ok := core.param_event(e.payload, ONE_POLE_PARAM_CUTOFF_HZ); ok {
			smoothed_apply(&f.cutoff, clamp(hz, 10, 20000), frames)
		}
	}
	one_pole_render(f, ctx, pos, ctx.frames)
}

// [rt]
@(private)
one_pole_render :: proc(f: ^One_Pole_Lowpass, ctx: ^core.Process_Context, from, to: int) {
	channels := len(ctx.outputs)
	ins := min(len(ctx.inputs), channels)
	for i in from ..< to {
		if smoothed_is_smoothing(&f.cutoff) {
			f.g = one_pole_coeff(smoothed_next(&f.cutoff), f.sample_rate)
		}
		for c in 0 ..< channels {
			x := c < ins ? f64(ctx.inputs[c][i]) : 0
			v := (x - f.state[c]) * f.g
			y := v + f.state[c]
			f.state[c] = y + v
			ctx.outputs[c][i] = f32(y)
		}
	}
}
