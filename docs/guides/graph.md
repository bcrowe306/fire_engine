---
title: The audio graph
description: Connecting nodes into a graph, changing it while it plays, parameters, events, latency and threads.
---

[`fire:graph`](/reference/graph/) runs a set of nodes connected into a directed
acyclic graph, once per audio block, on the audio thread and (when it pays off)
a pool of worker threads.

## Nodes and connections

A graph starts with two built-in endpoints: `graph.INPUT` (the device's
inputs, and incoming events) and `graph.OUTPUT` (the device's outputs, and
outgoing events). Add nodes and connect channels:

```odin
g, _ := graph.create(graph.default_settings(sample_rate, 512))
defer graph.destroy(g)

eq, _  := graph.add_node(g, dsp.one_pole_create(), 2, 2) // 2 in, 2 out
vol, _ := graph.add_node(g, dsp.gain_create(), 2, 2)
for ch in 0 ..< 2 {
	graph.connect(g, graph.INPUT, ch, eq, ch)
	graph.connect(g, eq, ch, vol, ch)
	graph.connect(g, vol, ch, graph.OUTPUT, ch)
}
graph.commit(g)
```

- `add_node` takes ownership of the node and prepares it for the graph's
  sample rate and block size.
- **Fan-out** is free: connect one output to many inputs.
- **Fan-in sums**: connections into the same input channel are added.
- `connect` refuses a connection that would create a cycle
  (`.Invalid_State`), and unknown nodes or channels (`.Invalid_Argument`).
- `Node_Id`s are generational: after `remove_node`, the old ID is rejected
  instead of reaching another node.

## Running it

Call `graph.process` from your audio callback with that block's buffers:

```odin
process :: proc(user: rawptr, block: ^backend.Io_Block) {
	ctx := core.Process_Context{inputs = block.inputs, outputs = block.outputs, frames = block.frames}
	graph.process((^graph.Graph)(user), &ctx)
}
```

`process` never allocates or blocks. Everything else in the package is for the
control thread.

## Changing the graph while it plays

Edits (`add_node`, `remove_node`, `connect`, `disconnect`, ...) are collected
on the control thread and take effect together at `commit`, which compiles a
new *plan* and hands it to the audio thread. The audio thread switches at the
start of its next block: never mid-block, never with a glitch from a
half-finished edit.

- **Nodes persist across commits.** A filter keeps its state when you add an
  unrelated node elsewhere. Nothing is reset or rebuilt.
- **Removed nodes are destroyed later**, once the audio thread has finished
  with the plan that used them. `commit` cleans up; so does `graph.collect`.

## Parameters

```odin
graph.set_param(g, vol, dsp.GAIN_PARAM_DB, -6)                  // next block
graph.set_param(g, vol, dsp.GAIN_PARAM_DB, -20, at = t + 4800)  // at a frame
graph.set_param_ramp(g, vol, dsp.GAIN_PARAM_DB, -96, frames = 96_000) // a 2 s fade
```

The node receives a `core.Param_Value` event at the exact frame, which it
smooths its own way; a ramp arrives as a `core.Param_Ramp`, which it follows
exactly. Times are on the graph's clock, frames since it started processing
(`graph.time(g)`). Both are lock-free; call them from one control thread.

## Events and MIDI

Event connections carry notes, MIDI and parameter values between nodes:

```odin
synth, _ := graph.add_node(g, my_synth_create(), 0, 2)
graph.connect_events(g, graph.INPUT, synth) // MIDI from process() → synth
```

Events passed to `process` in `ctx.events_in` come out of `INPUT`; events
connected into `OUTPUT` are written to `ctx.events_out`. Several event sources
into one node are merged in time order. See [MIDI](/guides/midi/) for feeding
device MIDI in.

## Latency compensation

A node that delays its output (lookahead, linear-phase EQ, a plugin) reports
it through its `latency` vtable entry. When paths meet, the graph delays the
earlier ones to match, audio and events alike, so a dry/wet mix stays
aligned. `graph.latency(g)` is the total delay from INPUT to OUTPUT.
Compensation can be turned off with `Settings.latency_compensation = false`.

## Threads

- `Settings.workers` sets the number of worker threads besides the audio
  thread. The default is one per core minus one; 0 keeps everything on the
  audio thread.
- A block runs in parallel only if the graph has parallel paths **and** its
  nodes use enough CPU to be worth it (`Settings.parallel_min_us`, 50 µs by
  default, measured as it runs). Small graphs run serially even with workers
  available, because waking threads would cost more than the work.
- Output is **bit-identical** whatever the thread count: sums and event
  merges happen in a fixed order.

## Graphs inside graphs

`graph.as_node(inner)` turns a graph into a node. Add it to another graph (a
channel strip, a rack, a sub-mix), or render it with `testkit.render` to test
it like any node.

## See also

- [`fire:graph` reference](/reference/graph/)
- [Design: the audio graph](/design/graph/), for how plans, scheduling and
  memory work.
