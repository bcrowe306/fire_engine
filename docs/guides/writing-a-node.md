---
title: Writing a node
description: Implementing your own DSP as a core.Node — lifecycle, parameters, events, latency — and testing it with testkit.
---

Everything the graph runs is a [`core.Node`](/reference/core/#node): a vtable
of procedures plus a pointer to your state. The full example is
`examples/custom_node` (a tremolo with a smoothed parameter).

## Lifecycle

| Procedure | Thread | Purpose |
|-----------|--------|---------|
| `prepare(self, cfg, allocator)` | control | Allocate and size everything `process` needs, for `cfg.sample_rate`, `cfg.max_block` and the channel counts |
| `process(self, ctx)` | **audio** | Fill `ctx.outputs` from `ctx.inputs` and `ctx.events_in` |
| `reset(self)` | audio | Clear state (delay lines, envelopes) without allocating |
| `release(self, allocator)` | control | Free what `prepare` allocated |
| `params(self)` | any | The node's parameter table (optional) |
| `latency(self)` | control | Frames of delay the node adds (optional) |
| `destroy(self, allocator)` | control | Free the node itself |

`process` cannot fail and must not allocate, lock or make system calls. Write
**every** output sample (outputs may hold garbage). `ctx.frames` can be
anything from 0 to `max_block`, and changes from block to block.

## A minimal node

```odin
Tremolo :: struct {
	phase, rate_hz, sample_rate: f64,
	depth: dsp.Smoothed_Value,
}

tremolo_vtable := core.Node_VTable {
	prepare = tremolo_prepare,
	process = tremolo_process,
	params  = proc(self: rawptr) -> []core.Param_Info { return tremolo_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
}

tremolo_create :: proc(rate_hz: f64, allocator := context.allocator) -> core.Node {
	t := new(Tremolo, allocator)
	t.rate_hz = rate_hz
	return core.node_make(&tremolo_vtable, t, allocator)
}
```

## Parameters, sample-accurately

Declare parameters with stable IDs: never renumber them once released.
`dsp.Smoothed_Value` ramps changes to avoid clicks:

```odin
TREMOLO_DEPTH :: core.Param_Id(1)
tremolo_params := [?]core.Param_Info {
	{id = TREMOLO_DEPTH, name = "Depth", unit = .Percent, min = 0, max = 100,
	 default = 50, smoothing = .Linear, smoothing_ms = 10, flags = {.Automatable}},
}
```

Events arrive sorted by `offset`. Render up to each event, apply it, and carry
on, so a change lands on its exact frame:

```odin
tremolo_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	t := (^Tremolo)(self)
	pos := 0
	for e in ctx.events_in {
		render(t, ctx, pos, int(e.offset))
		pos = int(e.offset)
		if pv, ok := e.payload.(core.Param_Value); ok && pv.param == TREMOLO_DEPTH {
			dsp.smoothed_set_target(&t.depth, pv.value)
		}
	}
	render(t, ctx, pos, ctx.frames)
}
```

## Latency

If the output lags the input (lookahead, FFT blocks), return the delay in
frames from the `latency` vtable entry. The graph compensates parallel paths
automatically.

## Testing it

[`fire:testkit`](/reference/testkit/) renders a node without a device and checks
what a real audio thread would punish:

- every `process` call runs inside a **trapping allocator**;
- outputs are **NaN-filled** first, so unwritten samples show up;
- **block sizes vary**, including 0 and 1;
- the report has allocation counts, non-finite samples and timing.

```odin
@(test)
tremolo_is_clean :: proc(t: ^testing.T) {
	node := tremolo_create(5)
	defer core.node_destroy(&node)
	input := kit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
	kit.sine(input.channels[0], 48_000, 440, 0.5)
	kit.buffer_mono_to_all(input)
	cfg := kit.default_render_config()
	cfg.blocks = kit.Random_Blocks{seed = 1, min = 0, max = cfg.max_block}
	_, report := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&report)
	kit.expect_clean_render(t, report) // no allocations, every sample finite
}
```

`kit.expect_block_invariant` checks that output does not depend on how blocks
are split, the usual sign of a node that isn't sample-accurate.
