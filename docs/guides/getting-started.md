---
title: Getting started
description: Build setup for Fire Engine and a first program that runs an audio graph.
---

## Requirements

- Odin `dev-2026-10` (the version CI pins).
- macOS 11+, Linux (ALSA; JACK optional) or Windows 10+.
- On Windows, the Visual Studio Build Tools (Odin needs the MSVC linker).

## Build setup

Fire Engine's packages live in one Odin *collection*. Point the `fire`
collection at the repository's `f_engine` directory when building:

```sh
odin build my_app -collection:fire=path/to/fire_engine/f_engine
```

and import packages by collection name:

```odin
import "fire:core"
import "fire:graph"
import "fire:dsp"
```

## A first program

This builds a two-node graph (a low-pass filter into a gain), feeds it a
sawtooth, and automates both parameters. It runs offline: no device needed.
The full program is `examples/graph_offline` in the repository.

```odin
settings := graph.default_settings(48_000, 256)
settings.input_channels, settings.output_channels = 1, 1
g, _ := graph.create(settings)
defer graph.destroy(g)

filter, _ := graph.add_node(g, dsp.one_pole_create(), 1, 1)
gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)
graph.connect(g, graph.INPUT, 0, filter, 0)
graph.connect(g, filter, 0, gain, 0)
graph.connect(g, gain, 0, graph.OUTPUT, 0)
graph.commit(g)

// Parameter changes at exact frames on the graph's clock.
graph.set_param(g, filter, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 300, at = 24_000)
graph.set_param(g, gain, dsp.GAIN_PARAM_DB, -12, at = 48_000)

// Process blocks, as an audio callback would.
ctx := core.Process_Context{inputs = ins, outputs = outs, frames = 256}
graph.process(g, &ctx)
```

Run it:

```sh
odin run examples/graph_offline -collection:fire=f_engine
```

## Next

- To hear it, open a device: [Audio devices](/guides/devices/), or run
  `examples/play_device`.
- To understand the graph: [The audio graph](/guides/graph/).
- To write your own DSP: [Writing a node](/guides/writing-a-node/).
