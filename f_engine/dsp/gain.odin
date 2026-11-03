package dsp

import "core:math"
import "core:mem"

import "fire:core"

GAIN_PARAM_DB :: core.Param_Id(1)

gain_params := [?]core.Param_Info {
	{
		id = GAIN_PARAM_DB, name = "Gain", unit = .Decibels,
		min = -96, max = 24, default = 0,
		smoothing = .Linear, smoothing_ms = 20,
		flags = {.Automatable},
	},
}

// Gain stage with a sample-accurate, smoothed gain parameter (in dB).
// Channel i of the output is channel i of the input (silence for extra outputs).
Gain :: struct {
	gain: Smoothed_Value, // linear gain
}

@(private)
gain_vtable := core.Node_VTable {
	prepare = gain_prepare,
	process = gain_process,
	reset   = gain_reset,
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	params  = proc(self: rawptr) -> []core.Param_Info { return gain_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Gain)(self), allocator) },
}

gain_create :: proc(allocator := context.allocator) -> core.Node {
	g := new(Gain, allocator)
	return core.node_make(&gain_vtable, g, allocator)
}

db_to_gain :: #force_inline proc "contextless" (db: f64) -> f64 {
	return db <= -96 ? 0 : math.pow(10, db / 20)
}

@(private)
gain_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	g := (^Gain)(self)
	p := gain_params[0]
	smoothed_init(&g.gain, db_to_gain(p.default), p.smoothing, p.smoothing_ms, cfg.sample_rate)
	return .None
}

@(private)
gain_reset :: proc(self: rawptr) {
	g := (^Gain)(self)
	smoothed_reset(&g.gain, g.gain.target)
}

// [rt]
@(private)
gain_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	g := (^Gain)(self)
	pos := 0
	for e in ctx.events_in {
		gain_render(g, ctx, pos, int(e.offset))
		pos = int(e.offset)
		if pv, ok := e.payload.(core.Param_Value); ok && pv.param == GAIN_PARAM_DB {
			smoothed_set_target(&g.gain, db_to_gain(clamp(pv.value, -96, 24)))
		}
	}
	gain_render(g, ctx, pos, ctx.frames)
}

// [rt]
@(private)
gain_render :: proc(g: ^Gain, ctx: ^core.Process_Context, from, to: int) {
	channels := len(ctx.outputs)
	ins := min(len(ctx.inputs), channels)
	if !smoothed_is_smoothing(&g.gain) {
		k := f32(g.gain.current)
		for c in 0 ..< ins do for i in from ..< to do ctx.outputs[c][i] = ctx.inputs[c][i] * k
	} else {
		for i in from ..< to {
			k := f32(smoothed_next(&g.gain))
			for c in 0 ..< ins do ctx.outputs[c][i] = ctx.inputs[c][i] * k
		}
	}
	for c in ins ..< channels do for i in from ..< to do ctx.outputs[c][i] = 0
}
