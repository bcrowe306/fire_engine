package dsp

import "core:mem"

import "fire:core"

// Parameter id of the `Strip` node's fader, in dB (-96..24, default 0):
// the same id as `GAIN_PARAM_DB`, so a strip stands in for a fader `Gain`.
STRIP_PARAM_FADER_DB :: core.Param_Id(1)
// Parameter id of the `Strip` node's trim, before its pre-fader tap, in dB
// (-96..24, default 0): a mute or solo (-96).
STRIP_PARAM_TRIM_DB :: core.Param_Id(2)
// Parameter id of the `Strip` node's output gain, after its post-fader
// tap and meter, in dB (-96..24, default 0).
STRIP_PARAM_OUT_DB :: core.Param_Id(3)

// The `Strip` node's first output pair: after the output gain, where the
// strip goes.
STRIP_OUT :: 0
// The `Strip` node's pair after the trim: pre-fader sends.
STRIP_PRE :: 2
// The `Strip` node's pair after the fader (what its meter measures):
// post-fader sends.
STRIP_POST :: 4
// Outputs a `Strip` node is made with for all three pairs.
STRIP_OUTPUTS :: 6

// Parameter table of the `Strip` node, as returned by `node_params`. Read-only.
strip_params := [?]core.Param_Info {
	{
		id = STRIP_PARAM_FADER_DB, name = "Volume", unit = .Decibels,
		min = -96, max = 24, default = 0,
		smoothing = .Linear, smoothing_ms = 20,
		flags = {.Automatable},
	},
	{
		id = STRIP_PARAM_TRIM_DB, name = "Trim", unit = .Decibels,
		min = -96, max = 24, default = 0,
		smoothing = .Linear, smoothing_ms = 20,
	},
	{
		id = STRIP_PARAM_OUT_DB, name = "Output", unit = .Decibels,
		min = -96, max = 24, default = 0,
		smoothing = .Linear, smoothing_ms = 20,
	},
}

// A console's channel strip in one node, after its inserts: trim (mute,
// solo), fader, meter and output gain, each gain as a `Gain` (smoothed,
// automation ramps in dB). Two inputs; its outputs are three stereo pairs,
// `STRIP_OUT`, `STRIP_PRE` and `STRIP_POST`. Made with fewer outputs, the
// pairs it has are its out (and its pre-fader tap).
//
//	in → trim ─┬→ fader ─┬→ meter → output gain → OUT
//	           └→ PRE    └→ POST
//
// Read its meter with `meter_read(&strip.meter)`.
Strip :: struct {
	trim, fader, out: Gain,
	meter: Meter, // after the fader
}

@(private)
strip_vtable := core.Node_VTable {
	name    = "fire.strip",
	prepare = strip_prepare,
	process = strip_process,
	reset   = strip_reset,
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	params  = proc(self: rawptr) -> []core.Param_Info { return strip_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Strip)(self), allocator) },
}

// Control thread. A `Strip` node (give it 2 inputs and `STRIP_OUTPUTS`
// outputs) and its handle, valid until the node is destroyed. Free it with
// `core.node_destroy`.
strip_create :: proc(allocator := context.allocator) -> (core.Node, ^Strip) {
	s := new(Strip, allocator)
	return core.node_make(&strip_vtable, s, allocator), s
}

@(private)
strip_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	s := (^Strip)(self)
	gain_init(&s.fader, strip_params[0], cfg.sample_rate)
	gain_init(&s.trim, strip_params[1], cfg.sample_rate)
	gain_init(&s.out, strip_params[2], cfg.sample_rate)
	return .None
}

@(private)
strip_reset :: proc(self: rawptr) {
	s := (^Strip)(self)
	gain_settle(&s.trim)
	gain_settle(&s.fader)
	gain_settle(&s.out)
}

// [rt]
@(private)
strip_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Strip)(self)
	outs := ctx.outputs
	// The pairs it has: with fewer outputs, a later stage works in place on
	// the one before.
	out := outs[:min(len(outs), 2)]
	pre := outs[STRIP_PRE:STRIP_PRE + 2] if len(outs) >= STRIP_PRE + 2 else out
	post := outs[STRIP_POST:STRIP_POST + 2] if len(outs) >= STRIP_POST + 2 else out
	written := STRIP_OUTPUTS if len(outs) >= STRIP_OUTPUTS else STRIP_PRE + 2 if len(outs) >= STRIP_PRE + 2 else len(out)
	pos := 0
	for e in ctx.events_in {
		strip_render(s, ctx.inputs, pre, post, out, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case STRIP_PARAM_FADER_DB: gain_event(&s.fader, value, frames)
		case STRIP_PARAM_TRIM_DB:  gain_event(&s.trim, value, frames)
		case STRIP_PARAM_OUT_DB:   gain_event(&s.out, value, frames)
		}
	}
	strip_render(s, ctx.inputs, pre, post, out, pos, ctx.frames)
	meter_measure(&s.meter, post, ctx.frames)
	for c in written ..< len(outs) do for &v in outs[c][:ctx.frames] do v = 0
}

// [rt]
@(private)
strip_render :: proc "contextless" (s: ^Strip, ins, pre, post, out: [][]f32, from, to: int) {
	if from >= to do return
	gain_apply(&s.trim, ins, pre, from, to)
	gain_apply(&s.fader, pre, post, from, to)
	gain_apply(&s.out, post, out, from, to)
}
