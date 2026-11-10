package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Parameter id of the `Pan` node's position: -1 (left) .. 1 (right), default 0.
PAN_PARAM_POSITION :: core.Param_Id(1)

// Pan parameters. Read-only.
pan_params := [?]core.Param_Info{
	{id = PAN_PARAM_POSITION, name = "Pan", min = -1, max = 1, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
}

// A stereo balance: equal-power, so the centre keeps the level of both
// sides (each at -3 dB from hard left or right, at unity in the middle:
// centred, it passes the input unchanged). Two channels in, two out.
Pan :: struct {
	pos: Smoothed_Value,
}

@(private)
pan_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		p := (^Pan)(self)
		v := p.pos.target
		smoothed_init_from_param(&p.pos, pan_params[0], cfg.sample_rate)
		smoothed_reset(&p.pos, v)
		return .None
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		p := (^Pan)(self)
		pos := 0
		for e in ctx.events_in {
			pan_render(p, ctx, pos, int(e.offset))
			pos = int(e.offset)
			if v, r, ok := core.param_event(e.payload, PAN_PARAM_POSITION); ok do smoothed_apply(&p.pos, clamp(v, -1, 1), r)
		}
		pan_render(p, ctx, pos, ctx.frames)
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return pan_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Pan)(self), a) },
}

// Control thread. A stereo pan node.
pan_create :: proc(allocator := context.allocator) -> core.Node {
	return core.node_make(&pan_vtable, new(Pan, allocator), allocator)
}

// [rt] Balance gains for `pos`: unity at the centre, the far side at 0 and
// the near side at +3 dB at the ends.
pan_gains :: #force_inline proc "contextless" (pos: f64) -> (left, right: f32) {
	a := (pos + 1) * math.PI / 4 // 0 .. π/2
	return f32(math.cos(a) * math.SQRT_TWO), f32(math.sin(a) * math.SQRT_TWO)
}

@(private)
pan_render :: proc "contextless" (p: ^Pan, ctx: ^core.Process_Context, from, to: int) {
	if len(ctx.outputs) < 2 {
		for out, c in ctx.outputs do for i in from ..< to do out[i] = ctx.inputs[c][i] if c < len(ctx.inputs) else 0
		return
	}
	in_l := ctx.inputs[0] if len(ctx.inputs) > 0 else nil
	in_r := ctx.inputs[1] if len(ctx.inputs) > 1 else in_l
	for i in from ..< to {
		l, r := pan_gains(smoothed_next(&p.pos))
		ctx.outputs[0][i] = (in_l[i] if in_l != nil else 0) * l
		ctx.outputs[1][i] = (in_r[i] if in_r != nil else 0) * r
	}
	for c in 2 ..< len(ctx.outputs) do for i in from ..< to do ctx.outputs[c][i] = 0
}
