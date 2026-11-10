package dsp

import "core:mem"

import "fire:core"

// Parameter id of the `Filter` node's mode: a `Filter_Mode`, as a number
// (default Lowpass).
FILTER_PARAM_MODE :: core.Param_Id(1)
// Parameter id of the `Filter` node's cutoff, in Hz (20..20000, default 1000).
FILTER_PARAM_CUTOFF_HZ :: core.Param_Id(2)
// Parameter id of the `Filter` node's Q (0.1..40, default 0.707).
FILTER_PARAM_Q :: core.Param_Id(3)
// Parameter id of the `Filter` node's gain in dB, for Bell and the shelves
// (−30..30, default 0).
FILTER_PARAM_GAIN_DB :: core.Param_Id(4)

// Parameter table of the `Filter` node, as returned by `node_params`. Read-only.
filter_params := [?]core.Param_Info {
	{id = FILTER_PARAM_MODE, name = "Mode", min = 0, max = f64(max(Filter_Mode)), default = 0, flags = {.Automatable, .Stepped}},
	{id = FILTER_PARAM_CUTOFF_HZ, name = "Cutoff", unit = .Hertz, min = 20, max = 20000, default = 1000, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = FILTER_PARAM_Q, name = "Q", min = 0.1, max = 40, default = 0.707, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = FILTER_PARAM_GAIN_DB, name = "Gain", unit = .Decibels, min = -30, max = 30, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
}

// A state-variable filter node (see `svf_design`), stable under any
// modulation: cutoff, Q and gain can be automated or ramped at audio rate.
// Each output channel filters the matching input (silence for extra
// outputs).
Filter :: struct {
	mode:        Filter_Mode,
	cutoff:      Smoothed_Value,
	q:           Smoothed_Value,
	gain_db:     Smoothed_Value,
	coeffs:      Svf_Coeffs,
	designed:    [3]f64, // the cutoff, Q and gain `coeffs` are for
	state:       []Svf_State, // one per channel
	sample_rate: f64,
}

@(private)
filter_vtable := core.Node_VTable {
	prepare = filter_prepare,
	process = filter_process,
	reset   = proc(self: rawptr) {
		f := (^Filter)(self)
		for &s in f.state do s = {}
		smoothed_reset(&f.cutoff, f.cutoff.target)
		smoothed_reset(&f.q, f.q.target)
		smoothed_reset(&f.gain_db, f.gain_db.target)
		filter_design(f)
	},
	release = proc(self: rawptr, allocator: mem.Allocator) {
		f := (^Filter)(self)
		delete(f.state, allocator)
		f.state = nil
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return filter_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Filter)(self), allocator) },
	type_id = FILTER_TYPE_ID,
	state_version = 1,
	save = save_filter,
}

// Control thread. Allocates a `Filter` node starting in `mode`. Free it with
// `core.node_destroy`.
filter_create :: proc(mode := Filter_Mode.Lowpass, allocator := context.allocator) -> core.Node {
	f := new(Filter, allocator)
	f.mode = mode
	return core.node_make(&filter_vtable, f, allocator)
}

@(private)
filter_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	f := (^Filter)(self)
	err: mem.Allocator_Error
	f.state, err = make([]Svf_State, cfg.out_channels, allocator)
	if err != nil do return .Out_Of_Memory
	f.sample_rate = cfg.sample_rate
	smoothed_init_from_param(&f.cutoff, filter_params[1], cfg.sample_rate)
	smoothed_init_from_param(&f.q, filter_params[2], cfg.sample_rate)
	smoothed_init_from_param(&f.gain_db, filter_params[3], cfg.sample_rate)
	filter_design(f)
	return .None
}

// [rt]
@(private)
filter_design :: proc "contextless" (f: ^Filter) {
	f.designed = {f.cutoff.current, f.q.current, f.gain_db.current}
	f.coeffs = svf_design(f.mode, f.designed[0], f.designed[1], f.designed[2], f.sample_rate)
}

// [rt]
@(private)
filter_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	f := (^Filter)(self)
	pos := 0
	for e in ctx.events_in {
		filter_render(f, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case FILTER_PARAM_MODE:
			f.mode = Filter_Mode(clamp(int(value + 0.5), 0, int(max(Filter_Mode))))
			filter_design(f)
		case FILTER_PARAM_CUTOFF_HZ: smoothed_apply(&f.cutoff, clamp(value, 20, 20000), frames)
		case FILTER_PARAM_Q:         smoothed_apply(&f.q, clamp(value, 0.1, 40), frames)
		case FILTER_PARAM_GAIN_DB:   smoothed_apply(&f.gain_db, clamp(value, -30, 30), frames)
		}
	}
	filter_render(f, ctx, pos, ctx.frames)
}

// [rt]
@(private)
filter_render :: proc(f: ^Filter, ctx: ^core.Process_Context, from, to: int) {
	channels := len(ctx.outputs)
	ins := min(len(ctx.inputs), channels)
	moving := smoothed_is_smoothing(&f.cutoff) || smoothed_is_smoothing(&f.q) || smoothed_is_smoothing(&f.gain_db)
	if !moving {
		if f.designed != {f.cutoff.current, f.q.current, f.gain_db.current} do filter_design(f) // an exact set, or a ramp just ended
		for c in 0 ..< ins do for i in from ..< to do ctx.outputs[c][i] = f32(svf_tick(&f.coeffs, &f.state[c], f64(ctx.inputs[c][i])))
	} else {
		for i in from ..< to {
			f.coeffs = svf_design(f.mode, smoothed_next(&f.cutoff), smoothed_next(&f.q), smoothed_next(&f.gain_db), f.sample_rate)
			for c in 0 ..< ins do ctx.outputs[c][i] = f32(svf_tick(&f.coeffs, &f.state[c], f64(ctx.inputs[c][i])))
		}
		filter_design(f) // at the values reached: a ramp's last call returns the value before its target
	}
	for c in ins ..< channels do for i in from ..< to do ctx.outputs[c][i] = 0
}

// [rt] Any parameter event: its id, value and ramp length (−1 for a plain
// value, as `core.param_event`).
@(private)
any_param :: proc "contextless" (p: core.Event_Payload) -> (id: core.Param_Id, value: f64, ramp_frames: int, ok: bool) {
	#partial switch v in p {
	case core.Param_Value: return v.param, v.value, -1, true
	case core.Param_Ramp:  return v.param, v.target, int(v.frames), true
	}
	return
}
