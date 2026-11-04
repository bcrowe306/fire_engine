package dsp

import "core:fmt"
import "core:math"
import "core:mem"

import "fire:core"

// Most bands an `Eq` may have.
EQ_MAX_BANDS :: 8

// Parameter id of the `Eq` node's output gain, in dB (−30..30, default 0).
EQ_PARAM_OUTPUT_DB :: core.Param_Id(1)

// What each `Eq` band parameter controls (see `eq_band_param`).
Eq_Band_Field :: enum u8 {
	On,      // 0 or 1
	Mode,    // a `Filter_Mode`, as a number
	Freq_Hz, // 20..20000
	Q,       // 0.1..40
	Gain_Db, // −30..30
}

// [rt] The stable parameter id of band `band`'s (0-based) `field`:
// 100 + 10 × band + field.
eq_band_param :: proc "contextless" (band: int, field: Eq_Band_Field) -> core.Param_Id {
	return core.Param_Id(100 + 10 * band + int(field))
}

// A parametric EQ node: up to `EQ_MAX_BANDS` state-variable filter bands in
// series, each with its own mode, frequency, Q and gain, and an output
// gain. All smoothed and automatable. Each output channel filters the
// matching input.
Eq :: struct {
	bands:       []Eq_Band,
	output:      Smoothed_Value, // dB
	params:      []core.Param_Info,
	names:       []string,
	sample_rate: f64,
	allocator:   mem.Allocator,
}

@(private)
Eq_Band :: struct {
	on:      bool,
	mode:    Filter_Mode,
	freq:    Smoothed_Value,
	q:       Smoothed_Value,
	gain_db: Smoothed_Value,
	coeffs:   Svf_Coeffs,
	designed: [3]f64, // the frequency, Q and gain `coeffs` are for
	state:    []Svf_State, // one per channel
}

@(private)
eq_vtable := core.Node_VTable {
	prepare = eq_prepare,
	process = eq_process,
	reset   = proc(self: rawptr) {
		q := (^Eq)(self)
		for &b in q.bands {
			for &s in b.state do s = {}
			smoothed_reset(&b.freq, b.freq.target)
			smoothed_reset(&b.q, b.q.target)
			smoothed_reset(&b.gain_db, b.gain_db.target)
			eq_design(q, &b)
		}
		smoothed_reset(&q.output, q.output.target)
	},
	release = proc(self: rawptr, allocator: mem.Allocator) {
		q := (^Eq)(self)
		for &b in q.bands {
			delete(b.state, allocator)
			b.state = nil
		}
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return (^Eq)(self).params },
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		q := (^Eq)(self)
		delete(q.bands, q.allocator)
		delete(q.params, q.allocator)
		for n in q.names do delete(n, q.allocator)
		delete(q.names, q.allocator)
		free(q, q.allocator)
	},
}

// Control thread. Allocates an `Eq` node of `bands` bands (1..EQ_MAX_BANDS),
// all on and flat (0 dB) at first: a low shelf, bells spread over the
// spectrum, and a high shelf. Free it with `core.node_destroy`.
eq_create :: proc(bands := 4, allocator := context.allocator) -> core.Node {
	q := new(Eq, allocator)
	q.allocator = allocator
	n := clamp(bands, 1, EQ_MAX_BANDS)
	q.bands = make([]Eq_Band, n, allocator)
	q.params = make([]core.Param_Info, 1 + 5 * n, allocator)
	q.names = make([]string, 5 * n, allocator)
	q.params[0] = {id = EQ_PARAM_OUTPUT_DB, name = "Output", unit = .Decibels, min = -30, max = 30, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}}
	for &b, i in q.bands {
		b.on = true
		b.mode = .Bell
		if n > 1 && i == 0 do b.mode = .Low_Shelf
		if n > 1 && i == n - 1 do b.mode = .High_Shelf
		freq := 100 * math.pow(80, f64(i) / f64(max(n - 1, 1))) // 100 Hz to 8 kHz, evenly in octaves
		info := [5]core.Param_Info {
			{name = "On", min = 0, max = 1, default = 1, flags = {.Automatable, .Stepped}},
			{name = "Mode", min = 0, max = f64(max(Filter_Mode)), default = f64(b.mode), flags = {.Automatable, .Stepped}},
			{name = "Freq", unit = .Hertz, min = 20, max = 20000, default = freq, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
			{name = "Q", min = 0.1, max = 40, default = 0.707, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
			{name = "Gain", unit = .Decibels, min = -30, max = 30, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
		}
		for &p, f in info {
			q.names[5 * i + f] = fmt.aprintf("Band %d %s", i + 1, p.name, allocator = allocator)
			p.name = q.names[5 * i + f]
			p.id = eq_band_param(i, Eq_Band_Field(f))
			q.params[1 + 5 * i + f] = p
		}
	}
	return core.node_make(&eq_vtable, q, allocator)
}

// [rt] The EQ's combined gain (linear) at `freq_hz`, with its current
// settings: for drawing its curve. Reads node state the audio thread
// writes, so call it from the audio thread or accept a torn read.
eq_response :: proc "contextless" (q: ^Eq, freq_hz: f64) -> f64 {
	gain := db_to_gain(q.output.current)
	for &b in q.bands do if b.on {
		g, _ := svf_response(&b.coeffs, freq_hz, q.sample_rate)
		gain *= g
	}
	return gain
}

@(private)
eq_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	q := (^Eq)(self)
	q.sample_rate = cfg.sample_rate
	smoothed_init_from_param(&q.output, q.params[0], cfg.sample_rate)
	for &b, i in q.bands {
		err: mem.Allocator_Error
		b.state, err = make([]Svf_State, cfg.out_channels, allocator)
		if err != nil do return .Out_Of_Memory
		smoothed_init_from_param(&b.freq, q.params[1 + 5 * i + 2], cfg.sample_rate)
		smoothed_init_from_param(&b.q, q.params[1 + 5 * i + 3], cfg.sample_rate)
		smoothed_init_from_param(&b.gain_db, q.params[1 + 5 * i + 4], cfg.sample_rate)
		eq_design(q, &b)
	}
	return .None
}

// [rt]
@(private)
eq_design :: proc "contextless" (q: ^Eq, b: ^Eq_Band) {
	b.designed = {b.freq.current, b.q.current, b.gain_db.current}
	b.coeffs = svf_design(b.mode, b.designed[0], b.designed[1], b.designed[2], q.sample_rate)
}

// [rt]
@(private)
eq_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	q := (^Eq)(self)
	pos := 0
	for e in ctx.events_in {
		eq_render(q, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		if id == EQ_PARAM_OUTPUT_DB {
			smoothed_apply(&q.output, clamp(value, -30, 30), frames)
			continue
		}
		band, field := (int(id) - 100) / 10, (int(id) - 100) % 10
		if int(id) < 100 || band >= len(q.bands) || field > int(max(Eq_Band_Field)) do continue
		b := &q.bands[band]
		switch Eq_Band_Field(field) {
		case .On:
			on := value >= 0.5
			if on && !b.on do for &s in b.state do s = {} // a band coming back starts clean
			b.on = on
		case .Mode:
			b.mode = Filter_Mode(clamp(int(value + 0.5), 0, int(max(Filter_Mode))))
			eq_design(q, b)
		case .Freq_Hz: smoothed_apply(&b.freq, clamp(value, 20, 20000), frames)
		case .Q:       smoothed_apply(&b.q, clamp(value, 0.1, 40), frames)
		case .Gain_Db: smoothed_apply(&b.gain_db, clamp(value, -30, 30), frames)
		}
	}
	eq_render(q, ctx, pos, ctx.frames)
}

// [rt]
@(private)
eq_render :: proc(q: ^Eq, ctx: ^core.Process_Context, from, to: int) {
	channels := len(ctx.outputs)
	ins := min(len(ctx.inputs), channels)
	for c in 0 ..< ins do copy(ctx.outputs[c][from:to], ctx.inputs[c][from:to])
	for c in ins ..< channels do for i in from ..< to do ctx.outputs[c][i] = 0
	for &b in q.bands {
		if !b.on do continue
		if !(smoothed_is_smoothing(&b.freq) || smoothed_is_smoothing(&b.q) || smoothed_is_smoothing(&b.gain_db)) {
			if b.designed != {b.freq.current, b.q.current, b.gain_db.current} do eq_design(q, &b) // an exact set
			for c in 0 ..< ins do svf_process(&b.coeffs, &b.state[c], ctx.outputs[c][from:to])
			continue
		}
		for i in from ..< to {
			b.coeffs = svf_design(b.mode, smoothed_next(&b.freq), smoothed_next(&b.q), smoothed_next(&b.gain_db), q.sample_rate)
			for c in 0 ..< ins do ctx.outputs[c][i] = f32(svf_tick(&b.coeffs, &b.state[c], f64(ctx.outputs[c][i])))
		}
		eq_design(q, &b) // at the values reached: a ramp's last call returns the value before its target
	}
	if !smoothed_is_smoothing(&q.output) {
		k := f32(db_to_gain(q.output.current))
		if k != 1 do for c in 0 ..< ins do for i in from ..< to do ctx.outputs[c][i] *= k
	} else {
		for i in from ..< to {
			k := f32(db_to_gain(smoothed_next(&q.output)))
			for c in 0 ..< ins do ctx.outputs[c][i] *= k
		}
	}
}
