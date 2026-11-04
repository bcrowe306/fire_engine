package dsp

import "core:math"
import "core:mem"

import "fire:core"

// The transfer curve of a `Saturation` node.
Saturation_Shape :: enum u8 {
	Soft,  // tanh: smooth, odd harmonics
	Hard,  // a clip at ±1: bright, buzzy
	Tube,  // tanh pushed harder on one side: even harmonics too
	Fold,  // a sine wavefolder: past full scale the wave folds back
	Cubic, // x − 4x³/27, then flat: the gentlest
}

// [rt] The curve `shape` at `x` (−1..1 out, unity slope at 0 for every
// shape but Fold).
saturate :: #force_inline proc "contextless" (shape: Saturation_Shape, x: f64) -> f64 {
	switch shape {
	case .Soft: return math.tanh(x)
	case .Hard: return clamp(x, -1, 1)
	case .Tube: return math.tanh(x) if x >= 0 else math.tanh(1.6 * x) / 1.6
	case .Fold: return math.sin(math.PI / 2 * x)
	case .Cubic: // unity slope at 0, flat at ±1 from ±1.5
		y := clamp(x, -1.5, 1.5)
		return y - 4.0 / 27 * y * y * y
	}
	return x
}

// Parameter id of the `Saturation`'s drive, in dB (0..36, default 6): gain into the curve.
SATURATION_PARAM_DRIVE_DB :: core.Param_Id(1)
// Parameter id of the `Saturation`'s curve: a `Saturation_Shape` as a number (default Soft).
SATURATION_PARAM_SHAPE :: core.Param_Id(2)
// Parameter id of the `Saturation`'s output level, in dB (−36..12, default 0).
SATURATION_PARAM_OUTPUT_DB :: core.Param_Id(3)
// Parameter id of the `Saturation`'s mix with the dry signal, in percent (0..100, default 100).
SATURATION_PARAM_MIX :: core.Param_Id(4)

// Parameter table of the `Saturation` node, as returned by `node_params`. Read-only.
saturation_params := [?]core.Param_Info {
	{id = SATURATION_PARAM_DRIVE_DB, name = "Drive", unit = .Decibels, min = 0, max = 36, default = 6, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = SATURATION_PARAM_SHAPE, name = "Shape", min = 0, max = f64(max(Saturation_Shape)), default = 0, flags = {.Automatable, .Stepped}},
	{id = SATURATION_PARAM_OUTPUT_DB, name = "Output", unit = .Decibels, min = -36, max = 12, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = SATURATION_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 100, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
}

// A saturation node: drive into a curve (`Saturation_Shape`), run 1, 2, 4
// or 8 times oversampled so the new harmonics don't fold back as
// aliasing, then a DC blocker (asymmetric curves add DC) and the output
// level, mixed with the dry signal. Oversampling is fixed at create and
// reported as the node's latency; the dry signal is delayed to match.
Saturation :: struct {
	factor:      int,
	shape:       Saturation_Shape,
	drive:       Smoothed_Value, // dB
	output:      Smoothed_Value, // dB
	mix:         Smoothed_Value, // percent
	channels:    []Saturation_Channel,
	gains:       []f64, // per high-rate frame of a block: the drive, as a gain
	wet:         []f32, // a block at the base rate
	dc_coeff:    f64,
	latency:     int,
}

@(private)
Saturation_Channel :: struct {
	over:     Oversampler,
	dry:      Delay_Line, // the dry signal, delayed by the latency
	dc_x, dc_y: f64, // the DC blocker
}

@(private)
saturation_vtable := core.Node_VTable {
	prepare = saturation_prepare,
	process = saturation_process,
	reset   = proc(self: rawptr) {
		s := (^Saturation)(self)
		for &c in s.channels {
			if s.factor > 1 do oversampler_reset(&c.over)
			delay_line_clear(&c.dry)
			c.dc_x, c.dc_y = 0, 0
		}
	},
	release = saturation_release,
	latency = proc(self: rawptr) -> int { return (^Saturation)(self).latency },
	params  = proc(self: rawptr) -> []core.Param_Info { return saturation_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Saturation)(self), allocator) },
}

// Control thread. A `Saturation` node, `oversample` 1, 2, 4 or 8 times
// (other values are rounded down to one of those). Free it with
// `core.node_destroy`.
saturation_create :: proc(oversample := 4, allocator := context.allocator) -> core.Node {
	s := new(Saturation, allocator)
	s.factor = 8 if oversample >= 8 else 4 if oversample >= 4 else 2 if oversample >= 2 else 1
	return core.node_make(&saturation_vtable, s, allocator)
}

@(private)
saturation_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	s := (^Saturation)(self)
	ae: mem.Allocator_Error
	s.channels, ae = make([]Saturation_Channel, cfg.out_channels, allocator)
	if ae == nil do s.gains, ae = make([]f64, cfg.max_block * s.factor, allocator)
	if ae == nil do s.wet, ae = make([]f32, cfg.max_block, allocator)
	if ae != nil {
		saturation_release(s, allocator)
		return .Out_Of_Memory
	}
	s.latency = 0
	for &c in s.channels {
		if s.factor > 1 {
			if err := oversampler_init(&c.over, s.factor, cfg.max_block, allocator); err != .None {
				saturation_release(s, allocator)
				return err
			}
			s.latency = oversampler_latency(&c.over)
		}
	}
	for &c in s.channels {
		if delay_line_init(&c.dry, s.latency + 1, allocator) != .None {
			saturation_release(s, allocator)
			return .Out_Of_Memory
		}
	}
	smoothed_init_from_param(&s.drive, saturation_params[0], cfg.sample_rate)
	smoothed_init_from_param(&s.output, saturation_params[2], cfg.sample_rate)
	smoothed_init_from_param(&s.mix, saturation_params[3], cfg.sample_rate)
	s.dc_coeff = 1 - 2 * math.PI * 10 / cfg.sample_rate // a 10 Hz highpass
	return .None
}

@(private)
saturation_release :: proc(self: rawptr, allocator: mem.Allocator) {
	s := (^Saturation)(self)
	for &c in s.channels {
		if s.factor > 1 do oversampler_destroy(&c.over, allocator)
		delay_line_destroy(&c.dry, allocator)
	}
	delete(s.channels, allocator)
	delete(s.gains, allocator)
	delete(s.wet, allocator)
	s.channels, s.gains, s.wet = nil, nil, nil
}

// [rt]
@(private)
saturation_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Saturation)(self)
	pos := 0
	for e in ctx.events_in {
		saturation_render(s, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case SATURATION_PARAM_DRIVE_DB:  smoothed_apply(&s.drive, clamp(value, 0, 36), frames)
		case SATURATION_PARAM_SHAPE:     s.shape = Saturation_Shape(clamp(int(value + 0.5), 0, int(max(Saturation_Shape))))
		case SATURATION_PARAM_OUTPUT_DB: smoothed_apply(&s.output, clamp(value, -36, 12), frames)
		case SATURATION_PARAM_MIX:       smoothed_apply(&s.mix, clamp(value, 0, 100), frames)
		}
	}
	saturation_render(s, ctx, pos, ctx.frames)
}

// [rt]
@(private)
saturation_render :: proc(s: ^Saturation, ctx: ^core.Process_Context, from, to: int) {
	n := to - from
	if n <= 0 do return
	outs := min(len(ctx.outputs), len(s.channels))
	ins := min(len(ctx.inputs), outs)
	// The drive, a gain per high-rate frame (held across each base frame,
	// so every channel gets the same).
	// pow only when the dB value changes (a ramp's last step returns the
	// value before its target, so compare values, not "is smoothing").
	g_db := s.drive.current
	g := db_to_gain(g_db)
	for i in 0 ..< n {
		v := smoothed_next(&s.drive) if smoothed_is_smoothing(&s.drive) else s.drive.current
		if v != g_db do g, g_db = db_to_gain(v), v
		for k in 0 ..< s.factor do s.gains[i * s.factor + k] = g
	}
	out0, mix0 := s.output, s.mix
	for c in 0 ..< outs {
		ch := &s.channels[c]
		x := ctx.inputs[c][from:to] if c < ins else nil
		wet := s.wet[:n]
		if x == nil {
			for &v in wet do v = 0
		} else if s.factor == 1 {
			for v, i in x do wet[i] = f32(saturate(s.shape, f64(v) * s.gains[i]))
		} else {
			high := oversampler_up(&ch.over, x)
			for &v, i in high do v = f32(saturate(s.shape, f64(v) * s.gains[i]))
			oversampler_down(&ch.over, high, wet)
		}
		s.output, s.mix = out0, mix0
		out_db := s.output.current
		out_gain := db_to_gain(out_db)
		for i in 0 ..< n {
			// DC blocker: y = x − x₋₁ + R·y₋₁.
			y := f64(wet[i]) - ch.dc_x + s.dc_coeff * ch.dc_y
			ch.dc_x, ch.dc_y = f64(wet[i]), y
			dry_in := x[i] if x != nil else 0
			delay_line_write(&ch.dry, dry_in)
			dry := delay_line_read(&ch.dry, f64(s.latency), .None)
			mix := smoothed_next(&s.mix) * 0.01
			v := smoothed_next(&s.output) if smoothed_is_smoothing(&s.output) else s.output.current
			if v != out_db do out_gain, out_db = db_to_gain(v), v
			ctx.outputs[c][from + i] = f32((1 - mix) * f64(dry) + mix * y * out_gain)
		}
	}
	for c in outs ..< len(ctx.outputs) do for i in from ..< to do ctx.outputs[c][i] = 0
}
