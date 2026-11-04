/*
Writes a node from scratch (a tremolo with a smoothed depth parameter), then
checks it the way Fire Engine's own nodes are checked: rendered through
testkit with a trapping allocator, at every block-size pattern.

	odin run examples/custom_node -collection:fire=f_engine
*/
package custom_node

import "core:fmt"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

// --- the node -------------------------------------------------------------------

// Stable parameter IDs: never renumber once released.
TREMOLO_DEPTH :: core.Param_Id(1)

tremolo_params := [?]core.Param_Info {
	{
		id = TREMOLO_DEPTH, name = "Depth", unit = .Percent,
		min = 0, max = 100, default = 50,
		smoothing = .Linear, smoothing_ms = 10,
		flags = {.Automatable},
	},
}

// The node's state. Everything `process` needs is allocated in `prepare`.
Tremolo :: struct {
	rate_hz:     f64,
	phase:       f64,
	sample_rate: f64,
	depth:       dsp.Smoothed_Value, // percent
}

tremolo_vtable := core.Node_VTable {
	prepare = tremolo_prepare,
	process = tremolo_process,
	reset   = proc(self: rawptr) { (^Tremolo)(self).phase = 0 },
	params  = proc(self: rawptr) -> []core.Param_Info { return tremolo_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
}

// Creates the node; the graph (or test) prepares it.
tremolo_create :: proc(rate_hz: f64, allocator := context.allocator) -> core.Node {
	t := new(Tremolo, allocator)
	t.rate_hz = rate_hz
	return core.node_make(&tremolo_vtable, t, allocator)
}

tremolo_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
	t := (^Tremolo)(self)
	t.sample_rate = cfg.sample_rate
	dsp.smoothed_init_from_param(&t.depth, tremolo_params[0], cfg.sample_rate)
	return .None
}

// [rt] Splits the block at each event so parameter changes land on their
// exact frame; no allocation, no locks.
tremolo_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	t := (^Tremolo)(self)
	pos := 0
	for e in ctx.events_in {
		render(t, ctx, pos, int(e.offset))
		pos = int(e.offset)
		// A Param_Value (smoothed) or an automation ramp (followed exactly).
		if depth, frames, ok := core.param_event(e.payload, TREMOLO_DEPTH); ok {
			dsp.smoothed_apply(&t.depth, clamp(depth, 0, 100), frames)
		}
	}
	render(t, ctx, pos, ctx.frames)
}

render :: proc(t: ^Tremolo, ctx: ^core.Process_Context, from, to: int) {
	for i in from ..< to {
		depth := dsp.smoothed_next(&t.depth) / 100
		lfo := 0.5 + 0.5 * math.sin(2 * math.PI * t.phase)
		g := f32(1 - depth * lfo)
		t.phase = math.mod(t.phase + t.rate_hz / t.sample_rate, 1)
		for out, c in ctx.outputs {
			out[i] = ctx.inputs[c][i] * g if c < len(ctx.inputs) else 0
		}
	}
}

// --- checking it -----------------------------------------------------------------------

main :: proc() {
	// One second of a stereo 440 Hz tone, with the depth changed at 0.5 s.
	input := kit.buffer_make(2, 48_000, 48_000)
	defer kit.buffer_destroy(&input)
	kit.sine(input.channels[0], 48_000, 440, 0.5)
	kit.buffer_mono_to_all(input)
	cfg := kit.default_render_config()
	cfg.events = []kit.Timed_Event{{24_000, core.Param_Value{TREMOLO_DEPTH, 100}}}

	// The node runs inside a trapping allocator with NaN-filled outputs at
	// random block sizes: any allocation, unwritten sample or NaN shows up
	// in the report.
	node := tremolo_create(5)
	defer core.node_destroy(&node)
	cfg.blocks = kit.Random_Blocks{seed = 1, min = 0, max = cfg.max_block}
	out, report := kit.render(&node, input, cfg)
	defer kit.buffer_destroy(&out)
	defer kit.render_report_destroy(&report)
	fmt.printfln("allocations on the audio thread: %d, non-finite samples: %d", report.rt_allocations, report.non_finite)
	fmt.printfln("rms first half %.3f, second half %.3f (deeper tremolo)", kit.rms(out.channels[0][:24_000]), kit.rms(out.channels[0][24_000:]))

	// Same output whatever the block sizes (the parameter lands on frame
	// 24000 every time).
	reference: kit.Audio_Buffer
	worst := 0.0
	for pattern, i in kit.standard_block_patterns(cfg.max_block) {
		n := tremolo_create(5)
		c := cfg
		c.blocks = pattern
		o, r := kit.render(&n, input, c)
		kit.render_report_destroy(&r)
		core.node_destroy(&n)
		if i == 0 {
			reference = o
			continue
		}
		worst = max(worst, kit.compare_buffers(reference, o).max_abs_error)
		kit.buffer_destroy(&o)
	}
	kit.buffer_destroy(&reference)
	fmt.printfln("largest difference between block patterns: %v", worst)
}
