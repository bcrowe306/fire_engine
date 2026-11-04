package dsp

import "base:intrinsics"
import "core:mem"

import "fire:core"

// Parameter id of the `Gate`'s threshold, in dB (−90..0, default −40): it opens above it.
GATE_PARAM_THRESHOLD_DB :: core.Param_Id(1)
// Parameter id of the `Gate`'s range, in dB (0..96, default 96): how far it turns down.
GATE_PARAM_RANGE_DB :: core.Param_Id(2)
// Parameter id of the `Gate`'s ratio below the threshold (1..100, default
// 100): 2..4 is a gentle expander, 100 a gate.
GATE_PARAM_RATIO :: core.Param_Id(3)
// Parameter id of the `Gate`'s attack (opening time), in ms (0.05..100, default 0.5).
GATE_PARAM_ATTACK_MS :: core.Param_Id(4)
// Parameter id of the `Gate`'s hold after the level falls, in ms (0..2000, default 20).
GATE_PARAM_HOLD_MS :: core.Param_Id(5)
// Parameter id of the `Gate`'s release (closing time), in ms (5..3000, default 100).
GATE_PARAM_RELEASE_MS :: core.Param_Id(6)
// Parameter id of the `Gate`'s hysteresis, in dB (0..20, default 4): it
// closes only this far below the threshold, so it doesn't chatter.
GATE_PARAM_HYSTERESIS_DB :: core.Param_Id(7)

// Parameter table of the `Gate` node, as returned by `node_params`. Read-only.
gate_params := [?]core.Param_Info {
	{id = GATE_PARAM_THRESHOLD_DB, name = "Threshold", unit = .Decibels, min = -90, max = 0, default = -40, flags = {.Automatable}},
	{id = GATE_PARAM_RANGE_DB, name = "Range", unit = .Decibels, min = 0, max = 96, default = 96, flags = {.Automatable}},
	{id = GATE_PARAM_RATIO, name = "Ratio", unit = .Ratio, min = 1, max = 100, default = 100, flags = {.Automatable}},
	{id = GATE_PARAM_ATTACK_MS, name = "Attack", unit = .Milliseconds, min = 0.05, max = 100, default = 0.5, flags = {.Automatable}},
	{id = GATE_PARAM_HOLD_MS, name = "Hold", unit = .Milliseconds, min = 0, max = 2000, default = 20, flags = {.Automatable}},
	{id = GATE_PARAM_RELEASE_MS, name = "Release", unit = .Milliseconds, min = 5, max = 3000, default = 100, flags = {.Automatable}},
	{id = GATE_PARAM_HYSTERESIS_DB, name = "Hysteresis", unit = .Decibels, min = 0, max = 20, default = 4, flags = {.Automatable}},
}

// A noise gate or downward expander node, stereo-linked. It opens when the
// peak level rises above the threshold, and once it falls `hysteresis`
// below it, closes after the hold time, turning down by up to `range` (by
// `ratio` dB per dB under the threshold). Input channels beyond the
// outputs are the sidechain, as for `Compressor`.
Gate :: struct {
	threshold_db, range_db, ratio, hysteresis_db: f64,
	attack_ms, hold_ms, release_ms:               f64,
	open:                                         bool,
	hold_left:                                    int, // frames
	detector:                                     Level_Detector,
	gain:                                         Gain_Smoother,
	sample_rate:                                  f64,
	meter:                                        u64, // atomic: f64 bits of the reduction in dB at the end of the last block
}

@(private)
gate_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
		g := (^Gate)(self)
		g.sample_rate = cfg.sample_rate
		g.open, g.hold_left = false, 0
		g.gain.reduction_db = g.range_db // starts closed
		gate_times(g)
		return .None
	},
	process = gate_process,
	reset   = proc(self: rawptr) {
		g := (^Gate)(self)
		g.open, g.hold_left, g.gain.reduction_db = false, 0, g.range_db
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return gate_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Gate)(self), allocator) },
}

// Control thread. Allocates a `Gate` node at its defaults. Free it with
// `core.node_destroy`.
gate_create :: proc(allocator := context.allocator) -> core.Node {
	g := new(Gate, allocator)
	g.threshold_db, g.range_db, g.ratio, g.hysteresis_db = -40, 96, 100, 4
	g.attack_ms, g.hold_ms, g.release_ms = 0.5, 20, 100
	return core.node_make(&gate_vtable, g, allocator)
}

// [rt] The gate's gain reduction in dB at the end of its last block. Any thread.
gate_reduction_db :: proc "contextless" (g: ^Gate) -> f64 {
	return transmute(f64)intrinsics.atomic_load_explicit(&g.meter, .Relaxed)
}

@(private)
gate_times :: proc "contextless" (g: ^Gate) {
	// The smoother "attacks" when the reduction grows: for a gate, closing.
	g.gain.attack = time_coeff(g.release_ms, g.sample_rate)
	g.gain.release = time_coeff(g.attack_ms, g.sample_rate)
}

// [rt]
@(private)
gate_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	g := (^Gate)(self)
	pos := 0
	for e in ctx.events_in {
		gate_render(g, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, _, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case GATE_PARAM_THRESHOLD_DB:  g.threshold_db = clamp(value, -90, 0)
		case GATE_PARAM_RANGE_DB:      g.range_db = clamp(value, 0, 96)
		case GATE_PARAM_RATIO:         g.ratio = clamp(value, 1, 100)
		case GATE_PARAM_ATTACK_MS:     g.attack_ms = clamp(value, 0.05, 100); gate_times(g)
		case GATE_PARAM_HOLD_MS:       g.hold_ms = clamp(value, 0, 2000)
		case GATE_PARAM_RELEASE_MS:    g.release_ms = clamp(value, 5, 3000); gate_times(g)
		case GATE_PARAM_HYSTERESIS_DB: g.hysteresis_db = clamp(value, 0, 20)
		}
	}
	gate_render(g, ctx, pos, ctx.frames)
	intrinsics.atomic_store_explicit(&g.meter, transmute(u64)g.gain.reduction_db, .Relaxed)
}

// [rt]
@(private)
gate_render :: proc(g: ^Gate, ctx: ^core.Process_Context, from, to: int) {
	outs := len(ctx.outputs)
	ins := min(len(ctx.inputs), outs)
	detect := ctx.inputs[outs:] if len(ctx.inputs) > outs else ctx.inputs[:ins]
	nd := min(len(detect), MAX_DETECT)
	frame: [MAX_DETECT]f64
	hold := int(g.hold_ms * 0.001 * g.sample_rate)
	for i in from ..< to {
		for d in 0 ..< nd do frame[d] = f64(detect[d][i])
		level := level_detector_next(&g.detector, frame[:nd])
		if level > g.threshold_db {
			g.open, g.hold_left = true, hold
		} else if g.open && level < g.threshold_db - g.hysteresis_db {
			if g.hold_left > 0 {
				g.hold_left -= 1
			} else {
				g.open = false
			}
		}
		// Closed, it turns down by the expander curve below the closing level.
		target := 0.0 if g.open else expander_curve(level, g.threshold_db - g.hysteresis_db, g.ratio, 0, g.range_db)
		reduction := gain_smoother_next(&g.gain, target)
		k := f32(db_to_gain(-reduction))
		for ch in 0 ..< ins do ctx.outputs[ch][i] = ctx.inputs[ch][i] * k
	}
	for ch in ins ..< outs do for i in from ..< to do ctx.outputs[ch][i] = 0
}
