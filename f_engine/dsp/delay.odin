package dsp

import "core:mem"

import "fire:core"

// Parameter id of the `Delay`'s time in ms (1..4000, default 375), when not synced.
DELAY_PARAM_TIME_MS :: core.Param_Id(1)
// Parameter id of the `Delay`'s tempo sync: 1 = the time is `DELAY_PARAM_BEATS` (default 0).
DELAY_PARAM_SYNC :: core.Param_Id(2)
// Parameter id of the `Delay`'s synced time, in beats (0.0625..8, default
// 0.75: a dotted eighth).
DELAY_PARAM_BEATS :: core.Param_Id(3)
// Parameter id of the `Delay`'s feedback, in percent (0..95, default 40).
DELAY_PARAM_FEEDBACK :: core.Param_Id(4)
// Parameter id of the `Delay`'s mix of echoes with the dry signal, in
// percent (0..100, default 35).
DELAY_PARAM_MIX :: core.Param_Id(5)
// Parameter id of the `Delay`'s ping-pong: 1 = echoes alternate left and
// right (stereo only; default 0).
DELAY_PARAM_PING_PONG :: core.Param_Id(6)
// Parameter id of the `Delay`'s low cut in the feedback loop, in Hz
// (20..10000, default 20): each echo thinner.
DELAY_PARAM_LOW_CUT_HZ :: core.Param_Id(7)
// Parameter id of the `Delay`'s high cut in the feedback loop, in Hz
// (100..20000, default 12000): each echo darker.
DELAY_PARAM_HIGH_CUT_HZ :: core.Param_Id(8)

// Parameter table of the `Delay` node, as returned by `node_params`. Read-only.
delay_params := [?]core.Param_Info {
	{id = DELAY_PARAM_TIME_MS, name = "Time", unit = .Milliseconds, min = 1, max = 4000, default = 375, flags = {.Automatable}},
	{id = DELAY_PARAM_SYNC, name = "Sync", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = DELAY_PARAM_BEATS, name = "Beats", min = 0.0625, max = 8, default = 0.75, flags = {.Automatable}},
	{id = DELAY_PARAM_FEEDBACK, name = "Feedback", unit = .Percent, min = 0, max = 95, default = 40, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = DELAY_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 35, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = DELAY_PARAM_PING_PONG, name = "Ping-pong", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = DELAY_PARAM_LOW_CUT_HZ, name = "Low cut", unit = .Hertz, min = 20, max = 10_000, default = 20, flags = {.Automatable}},
	{id = DELAY_PARAM_HIGH_CUT_HZ, name = "High cut", unit = .Hertz, min = 100, max = 20000, default = 12000, flags = {.Automatable}},
}

// Longest delay, in seconds.
DELAY_MAX_SECONDS :: 4.0

// How long a delay time change takes to glide (like tape), in ms.
DELAY_GLIDE_MS :: 100.0

// An echo node: a delay with feedback, filtered in the loop, free or synced
// to the tempo (`ctx.transport`; 120 BPM without one). Changing the time
// glides there over about 100 ms, bending the echoes' pitch as tape does,
// instead of clicking. Ping-pong takes the mix of the inputs and bounces
// it between the first two outputs.
Delay :: struct {
	time_ms, beats:     f64,
	sync, ping_pong:    bool,
	primed:             bool, // has rendered: before that, time changes jump instead of gliding
	low_cut, high_cut:  f64,
	frames:             Smoothed_Value, // the delay in frames, gliding
	feedback, mix:      Smoothed_Value, // percent
	lines:              []Delay_Line,
	low, high:          Svf_Coeffs,
	low_state:          []Svf_State,
	high_state:         []Svf_State,
	sample_rate:        f64,
}

@(private)
delay_vtable := core.Node_VTable {
	prepare = delay_prepare,
	process = delay_process,
	reset   = proc(self: rawptr) {
		d := (^Delay)(self)
		for &l in d.lines do delay_line_clear(&l)
		for &s in d.low_state do s = {}
		for &s in d.high_state do s = {}
		smoothed_reset(&d.frames, d.frames.target)
		d.primed = false
	},
	release = delay_release,
	params  = proc(self: rawptr) -> []core.Param_Info { return delay_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Delay)(self), allocator) },
	type_id = DELAY_TYPE_ID,
	state_version = 1,
}

// Control thread. Allocates a `Delay` node at its defaults. Free it with
// `core.node_destroy`.
delay_create :: proc(allocator := context.allocator) -> core.Node {
	d := new(Delay, allocator)
	d.time_ms, d.beats, d.low_cut, d.high_cut = 375, 0.75, 20, 12000
	return core.node_make(&delay_vtable, d, allocator)
}

@(private)
delay_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	d := (^Delay)(self)
	d.sample_rate = cfg.sample_rate
	n := max(cfg.out_channels, 1)
	ae: mem.Allocator_Error
	d.lines, ae = make([]Delay_Line, n, allocator)
	if ae == nil do d.low_state, ae = make([]Svf_State, n, allocator)
	if ae == nil do d.high_state, ae = make([]Svf_State, n, allocator)
	if ae != nil {
		delay_release(d, allocator)
		return .Out_Of_Memory
	}
	for &l in d.lines {
		if delay_line_init(&l, int(DELAY_MAX_SECONDS * cfg.sample_rate) + 2, allocator) != .None {
			delay_release(d, allocator)
			return .Out_Of_Memory
		}
	}
	smoothed_init(&d.frames, delay_target(d, nil), .One_Pole, DELAY_GLIDE_MS / 3, cfg.sample_rate) // ~3 time constants
	smoothed_init_from_param(&d.feedback, delay_params[3], cfg.sample_rate)
	smoothed_init_from_param(&d.mix, delay_params[4], cfg.sample_rate)
	delay_filters(d)
	return .None
}

@(private)
delay_release :: proc(self: rawptr, allocator: mem.Allocator) {
	d := (^Delay)(self)
	for &l in d.lines do delay_line_destroy(&l, allocator)
	delete(d.lines, allocator)
	delete(d.low_state, allocator)
	delete(d.high_state, allocator)
	d.lines, d.low_state, d.high_state = nil, nil, nil
}

// [rt] The delay in frames that the settings ask for now.
@(private)
delay_target :: proc "contextless" (d: ^Delay, t: ^core.Transport) -> f64 {
	seconds := d.time_ms * 0.001
	if d.sync {
		bpm := t.tempo_bpm if t != nil && t.tempo_bpm > 0 else 120
		seconds = d.beats * 60 / bpm
	}
	return clamp(seconds * d.sample_rate, 1, DELAY_MAX_SECONDS * d.sample_rate)
}

// [rt]
@(private)
delay_filters :: proc "contextless" (d: ^Delay) {
	d.low = svf_design(.Highpass, d.low_cut, 0.707, 0, d.sample_rate)
	d.high = svf_design(.Lowpass, d.high_cut, 0.707, 0, d.sample_rate)
}

// [rt]
@(private)
delay_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	d := (^Delay)(self)
	pos := 0
	retarget :: proc "contextless" (d: ^Delay, ctx: ^core.Process_Context) {
		target := delay_target(d, ctx.transport)
		if !d.primed {
			smoothed_reset(&d.frames, target)
		} else if target != d.frames.target {
			smoothed_set_target(&d.frames, target)
		}
	}
	retarget(d, ctx) // the tempo may have changed
	for e in ctx.events_in {
		delay_render(d, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case DELAY_PARAM_TIME_MS:     d.time_ms = clamp(value, 1, 4000)
		case DELAY_PARAM_SYNC:        d.sync = value >= 0.5
		case DELAY_PARAM_BEATS:       d.beats = clamp(value, 0.0625, 8)
		case DELAY_PARAM_FEEDBACK:    smoothed_apply(&d.feedback, clamp(value, 0, 95), frames)
		case DELAY_PARAM_MIX:         smoothed_apply(&d.mix, clamp(value, 0, 100), frames)
		case DELAY_PARAM_PING_PONG:   d.ping_pong = value >= 0.5
		case DELAY_PARAM_LOW_CUT_HZ:  d.low_cut = clamp(value, 20, 10_000); delay_filters(d)
		case DELAY_PARAM_HIGH_CUT_HZ: d.high_cut = clamp(value, 100, 20000); delay_filters(d)
		}
		retarget(d, ctx)
	}
	delay_render(d, ctx, pos, ctx.frames)
}

// [rt]
@(private)
delay_render :: proc(d: ^Delay, ctx: ^core.Process_Context, from, to: int) {
	outs := min(len(ctx.outputs), len(d.lines))
	ins := min(len(ctx.inputs), outs)
	pong := d.ping_pong && outs >= 2
	if to > from do d.primed = true
	for i in from ..< to {
		dl := smoothed_next(&d.frames)
		fb := smoothed_next(&d.feedback) * 0.01
		mix := smoothed_next(&d.mix) * 0.01
		if pong {
			in_sum: f32
			for c in 0 ..< ins do in_sum += ctx.inputs[c][i]
			in_sum /= f32(max(ins, 1))
			l := delay_line_read(&d.lines[0], dl - 1, .Cubic)
			r := delay_line_read(&d.lines[1], dl - 1, .Cubic)
			delay_line_write(&d.lines[0], in_sum + loop_filter(d, 0, r, fb))
			delay_line_write(&d.lines[1], loop_filter(d, 1, l, fb))
			echoes := [2]f32{l, r}
			for c in 0 ..< 2 {
				x := ctx.inputs[c][i] if c < ins else 0
				ctx.outputs[c][i] = f32(1 - mix) * x + f32(mix) * echoes[c]
			}
			for c in 2 ..< outs do ctx.outputs[c][i] = 0
			continue
		}
		for c in 0 ..< outs {
			x := ctx.inputs[c][i] if c < ins else 0
			wet := delay_line_read(&d.lines[c], dl - 1, .Cubic)
			delay_line_write(&d.lines[c], x + loop_filter(d, c, wet, fb))
			ctx.outputs[c][i] = f32(1 - mix) * x + f32(mix) * wet
		}
	}
	for c in outs ..< len(ctx.outputs) do for i in from ..< to do ctx.outputs[c][i] = 0
}

// [rt] An echo on its way back into the line: scaled and filtered.
@(private)
loop_filter :: #force_inline proc "contextless" (d: ^Delay, c: int, x: f32, fb: f64) -> f32 {
	y := svf_tick(&d.low, &d.low_state[c], f64(x) * fb)
	return f32(svf_tick(&d.high, &d.high_state[c], y))
}
