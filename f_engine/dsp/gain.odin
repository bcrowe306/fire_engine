package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Parameter id of the `Gain` node's gain, in dB (-96..24, default 0).
// -96 dB and below is silence.
GAIN_PARAM_DB :: core.Param_Id(1)

// Parameter table of the `Gain` node, as returned by `node_params`. Read-only.
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
// Its own smoothing moves in linear gain; automation ramps
// (`core.Param_Ramp`) move linearly in dB, so an automated fade is exact at
// any block size.
Gain :: struct {
	gain:    Smoothed_Value, // linear gain: values and their smoothing
	ramp:    Smoothed_Value, // dB: an automation ramp, while `ramping`
	ramping: bool,
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

// Control thread. Allocates a `Gain` node with `allocator`. Free it with
// `core.node_destroy`.
gain_create :: proc(allocator := context.allocator) -> core.Node {
	g := new(Gain, allocator)
	return core.node_make(&gain_vtable, g, allocator)
}

// [rt] Converts decibels to linear gain. Returns exactly 0 at -96 dB and below.
db_to_gain :: #force_inline proc "contextless" (db: f64) -> f64 {
	return db <= -96 ? 0 : math.pow(10, db / 20)
}

@(private)
gain_to_db :: #force_inline proc "contextless" (gain: f64) -> f64 {
	return -96 if gain <= 0 else max(20 * math.log10(gain), -96)
}

@(private)
gain_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	g := (^Gain)(self)
	p := gain_params[0]
	smoothed_init(&g.gain, db_to_gain(p.default), p.smoothing, p.smoothing_ms, cfg.sample_rate)
	smoothed_init(&g.ramp, p.default, .None, 0, cfg.sample_rate)
	g.ramping = false
	return .None
}

@(private)
gain_reset :: proc(self: rawptr) {
	g := (^Gain)(self)
	if g.ramping do smoothed_reset(&g.gain, db_to_gain(g.ramp.target))
	smoothed_reset(&g.gain, g.gain.target)
	g.ramping = false
}

// [rt]
@(private)
gain_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	g := (^Gain)(self)
	pos := 0
	for e in ctx.events_in {
		gain_render(g, ctx, pos, int(e.offset))
		pos = int(e.offset)
		if value, frames, ok := core.param_event(e.payload, GAIN_PARAM_DB); ok {
			db := clamp(value, -96, 24)
			if frames >= 0 { // a ramp, in dB from wherever the gain is
				if !g.ramping do smoothed_reset(&g.ramp, gain_to_db(g.gain.current))
				smoothed_ramp(&g.ramp, db, frames)
				g.ramping = true
			} else {
				if g.ramping do smoothed_reset(&g.gain, db_to_gain(g.ramp.current))
				g.ramping = false
				smoothed_set_target(&g.gain, db_to_gain(db))
			}
		}
	}
	gain_render(g, ctx, pos, ctx.frames)
}

// [rt]
@(private)
gain_render :: proc(g: ^Gain, ctx: ^core.Process_Context, from, to: int) {
	channels := len(ctx.outputs)
	ins := min(len(ctx.inputs), channels)
	if g.ramping && smoothed_is_smoothing(&g.ramp) {
		for i in from ..< to {
			k := f32(db_to_gain(smoothed_next(&g.ramp)))
			for c in 0 ..< ins do ctx.outputs[c][i] = ctx.inputs[c][i] * k
		}
	} else if g.ramping || !smoothed_is_smoothing(&g.gain) {
		k := f32(db_to_gain(g.ramp.current) if g.ramping else g.gain.current)
		for c in 0 ..< ins do for i in from ..< to do ctx.outputs[c][i] = ctx.inputs[c][i] * k
	} else {
		for i in from ..< to {
			k := f32(smoothed_next(&g.gain))
			for c in 0 ..< ins do ctx.outputs[c][i] = ctx.inputs[c][i] * k
		}
	}
	for c in ins ..< channels do for i in from ..< to do ctx.outputs[c][i] = 0
}
