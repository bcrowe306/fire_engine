package dsp

import "base:intrinsics"
import "core:mem"

import "fire:core"

// Parameter id of the `Compressor`'s threshold, in dB (−60..0, default −20).
COMPRESSOR_PARAM_THRESHOLD_DB :: core.Param_Id(1)
// Parameter id of the `Compressor`'s ratio (1..20, default 4).
COMPRESSOR_PARAM_RATIO :: core.Param_Id(2)
// Parameter id of the `Compressor`'s knee width, in dB (0..24, default 6).
COMPRESSOR_PARAM_KNEE_DB :: core.Param_Id(3)
// Parameter id of the `Compressor`'s attack, in ms (0.05..200, default 10).
COMPRESSOR_PARAM_ATTACK_MS :: core.Param_Id(4)
// Parameter id of the `Compressor`'s release, in ms (5..3000, default 100).
COMPRESSOR_PARAM_RELEASE_MS :: core.Param_Id(5)
// Parameter id of the `Compressor`'s makeup gain, in dB (0..30, default 0).
COMPRESSOR_PARAM_MAKEUP_DB :: core.Param_Id(6)
// Parameter id of the `Compressor`'s mix of compressed with dry signal, in
// percent (0..100, default 100): below 100 is parallel compression.
COMPRESSOR_PARAM_MIX :: core.Param_Id(7)
// Parameter id of the `Compressor`'s detector: a `Detector` as a number
// (default Peak).
COMPRESSOR_PARAM_DETECTOR :: core.Param_Id(8)

// Parameter table of the `Compressor` node, as returned by `node_params`. Read-only.
compressor_params := [?]core.Param_Info {
	{id = COMPRESSOR_PARAM_THRESHOLD_DB, name = "Threshold", unit = .Decibels, min = -60, max = 0, default = -20, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_RATIO, name = "Ratio", unit = .Ratio, min = 1, max = 20, default = 4, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_KNEE_DB, name = "Knee", unit = .Decibels, min = 0, max = 24, default = 6, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_ATTACK_MS, name = "Attack", unit = .Milliseconds, min = 0.05, max = 200, default = 10, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_RELEASE_MS, name = "Release", unit = .Milliseconds, min = 5, max = 3000, default = 100, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_MAKEUP_DB, name = "Makeup", unit = .Decibels, min = 0, max = 30, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 100, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = COMPRESSOR_PARAM_DETECTOR, name = "Detector", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
}

// RMS window of the detectors, in ms.
RMS_MS :: 10.0

// A feed-forward compressor node, stereo-linked: one gain for all
// channels, from the loudest. Input channels beyond the outputs are the
// sidechain (add it with 4 inputs and 2 outputs for a stereo sidechain):
// when there are any, they are detected instead of the main inputs.
Compressor :: struct {
	threshold_db, ratio, knee_db: f64,
	attack_ms, release_ms:        f64,
	makeup:                       Smoothed_Value, // dB
	mix:                          Smoothed_Value, // percent
	detector:                     Level_Detector,
	gain:                         Gain_Smoother,
	sample_rate:                  f64,
	meter:                        u64, // atomic: f64 bits of the gain reduction in dB at the end of the last block
}

@(private)
compressor_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
		c := (^Compressor)(self)
		c.sample_rate = cfg.sample_rate
		smoothed_init_from_param(&c.makeup, compressor_params[5], cfg.sample_rate)
		smoothed_init_from_param(&c.mix, compressor_params[6], cfg.sample_rate)
		c.detector.coeff = time_coeff(RMS_MS, cfg.sample_rate)
		compressor_times(c)
		return .None
	},
	process = compressor_process,
	reset   = proc(self: rawptr) {
		c := (^Compressor)(self)
		c.gain.reduction_db, c.detector.power = 0, 0
		smoothed_reset(&c.makeup, c.makeup.target)
		smoothed_reset(&c.mix, c.mix.target)
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return compressor_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Compressor)(self), allocator) },
}

// Control thread. Allocates a `Compressor` node at its defaults. Free it
// with `core.node_destroy`.
compressor_create :: proc(allocator := context.allocator) -> core.Node {
	c := new(Compressor, allocator)
	c.threshold_db, c.ratio, c.knee_db, c.attack_ms, c.release_ms = -20, 4, 6, 10, 100
	return core.node_make(&compressor_vtable, c, allocator)
}

// [rt] The compressor's gain reduction in dB at the end of its last block,
// for a meter. Any thread.
compressor_gain_reduction_db :: proc "contextless" (c: ^Compressor) -> f64 {
	return transmute(f64)intrinsics.atomic_load_explicit(&c.meter, .Relaxed)
}

@(private)
compressor_times :: proc "contextless" (c: ^Compressor) {
	c.gain.attack = time_coeff(c.attack_ms, c.sample_rate)
	c.gain.release = time_coeff(c.release_ms, c.sample_rate)
}

// [rt]
@(private)
compressor_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	c := (^Compressor)(self)
	pos := 0
	for e in ctx.events_in {
		compressor_render(c, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case COMPRESSOR_PARAM_THRESHOLD_DB: c.threshold_db = clamp(value, -60, 0)
		case COMPRESSOR_PARAM_RATIO:        c.ratio = clamp(value, 1, 20)
		case COMPRESSOR_PARAM_KNEE_DB:      c.knee_db = clamp(value, 0, 24)
		case COMPRESSOR_PARAM_ATTACK_MS:    c.attack_ms = clamp(value, 0.05, 200); compressor_times(c)
		case COMPRESSOR_PARAM_RELEASE_MS:   c.release_ms = clamp(value, 5, 3000); compressor_times(c)
		case COMPRESSOR_PARAM_MAKEUP_DB:    smoothed_apply(&c.makeup, clamp(value, 0, 30), frames)
		case COMPRESSOR_PARAM_MIX:          smoothed_apply(&c.mix, clamp(value, 0, 100), frames)
		case COMPRESSOR_PARAM_DETECTOR:     c.detector.mode = .Rms if value >= 0.5 else .Peak
		}
	}
	compressor_render(c, ctx, pos, ctx.frames)
	intrinsics.atomic_store_explicit(&c.meter, transmute(u64)c.gain.reduction_db, .Relaxed)
}

// Most channels a dynamics node detects at once.
@(private)
MAX_DETECT :: 16

// [rt]
@(private)
compressor_render :: proc(c: ^Compressor, ctx: ^core.Process_Context, from, to: int) {
	outs := len(ctx.outputs)
	ins := min(len(ctx.inputs), outs)
	detect := ctx.inputs[outs:] if len(ctx.inputs) > outs else ctx.inputs[:ins]
	nd := min(len(detect), MAX_DETECT)
	frame: [MAX_DETECT]f64
	for i in from ..< to {
		for d in 0 ..< nd do frame[d] = f64(detect[d][i])
		level := level_detector_next(&c.detector, frame[:nd])
		reduction := gain_smoother_next(&c.gain, compressor_curve(level, c.threshold_db, c.ratio, c.knee_db))
		wet := db_to_gain(smoothed_next(&c.makeup) - reduction)
		mix := smoothed_next(&c.mix) * 0.01
		k := f32(mix * wet + (1 - mix))
		for ch in 0 ..< ins do ctx.outputs[ch][i] = ctx.inputs[ch][i] * k
	}
	for ch in ins ..< outs do for i in from ..< to do ctx.outputs[ch][i] = 0
}
