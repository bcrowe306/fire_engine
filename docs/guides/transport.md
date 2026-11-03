---
title: Tempo and timelines
description: Run the engine's clock, play and loop an arrangement, launch clips on the beat, write nodes that follow time, and sync with MIDI clock or Ableton Link.
---

`fire:transport` gives the whole engine one sense of musical time. It is not
tied to a linear timeline: an arrangement, a grid of clips, loopers and step
sequencers can all run at once, in time with each other. The program in
`examples/transport_session` puts the pieces below together.

## The model in one minute

- **The clock** keeps a **grid**: a beat position that always advances at the
  current tempo, even when nothing is playing. Synced LFOs and arpeggiators
  can follow it directly.
- **Timelines** follow the grid. Each has a position in beats, plays and
  stops on its own, can loop, and can run at a different rate. Use one for an
  arrangement, one per launched clip or track, one per looper or pattern.
- **Commands** (`play`, `stop`, `locate`, `set_loop`, ...) take effect now,
  on the next boundary of a `tb.Quantize` length (the next bar, beat,
  sixteenth triplet, ...), or at an exact grid beat. They land on the exact
  frame.
- **The leader** is the timeline whose tempo map sets the tempo and bar lines
  while it plays. Otherwise the **live tempo** (`set_tempo`) applies.

Beats are always quarter notes (`tb.Beats`), as everywhere in Fire Engine.

## Running the clock

Create a clock with the device's sample rate, and in the audio callback hand
each block to `transport.process` together with what to run. It calls your
procedure once per segment of the block. It splits a block where a loop wraps
or a command lands, so within each call time is continuous.

```odin
clock, _ := transport.create(transport.default_settings(sample_rate))
defer transport.destroy(clock)

// In the device callback:
ctx := core.Process_Context{inputs = b.inputs, outputs = b.outputs, frames = b.frames}
transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
	graph.process((^graph.Graph)(user), seg)
}, g, b.output_ns)
```

Pass `b.output_ns` (the time the block will be heard) so that MIDI clock and
Link line up with what you hear. Every node in the graph now gets the clock in
`ctx.transport`.

## Playing an arrangement

An arrangement is a timeline with a tempo map, made the leader:

```odin
tempo_map: tb.Tempo_Map
tb.tempo_map_init(&tempo_map, 120)
defer tb.tempo_map_destroy(&tempo_map)
tb.tempo_map_set_tempo(&tempo_map, 8, 90) // 90 BPM from beat 8 (bar 3)

song, _ := transport.add_timeline(clock, &tempo_map) // the clock keeps a copy
transport.set_leader(clock, song)
transport.set_loop(clock, song, 0, 16) // loop bars 1–4
transport.play(clock, song)
```

- `locate(clock, song, beat)` jumps, whether playing or stopped.
- `stop` keeps the position. When the leader stops, the clock carries on at
  its last tempo and bar grid, so launched clips keep time.
- To change the map, edit yours and call `set_tempo_map` again. Call
  `transport.collect(clock)` now and then (say, once per UI frame) to free
  old copies.
- `set_tempo_override(clock, true)` makes the live tempo win over the map
  (for tap tempo), while the map's meters still apply.

## Launching clips on the beat

Give each clip, scene or track its own timeline and launch it quantized:

```odin
clip, _ := transport.add_timeline(clock)
transport.set_loop(clock, clip, 0, 8)              // a 2-bar clip
transport.play(clock, clip, tb.Quantize.Bar)       // on the next downbeat
transport.stop(clock, clip, tb.Quantize.Bars_4)    // on the next 4-bar boundary
transport.locate(clock, clip, 0, tb.Quantize.Quarter) // retrigger on the beat
```

- Quantized commands count from the current bar's downbeat. While the leader
  plays, its bars are the bar lines; otherwise the clock's live meter
  (`set_meter`) is used.
- Commands sent together apply in order. "Play the song, then launch this
  clip on the next bar" quantizes against the song's bars.
- For your own timing, pass `transport.At_Beat(b)`, an exact grid beat.

## Loopers, patterns and polymeters

A looper's loop or a sequencer pattern is a looping timeline:

```odin
pattern, _ := transport.add_timeline(clock)
transport.set_loop(clock, pattern, 0, 3)  // a 3-beat pattern against 4/4
transport.set_rate(clock, pattern, 0.5)   // half time
transport.play(clock, pattern, tb.Quantize.Bar)
```

Patterns of different lengths drift against each other and realign
naturally: that is a polymeter.

## Writing a node that follows time

A node reads `ctx.transport` (`core.Transport`). It can be nil when the node
runs without a clock, for example in `graph.process` called directly.

- `t.grid`, `t.tempo_bpm`, `t.meter`, `t.bar`, `t.bar_start` describe frame 0
  of the call.
- `core.transport_timeline(t, id)` finds a timeline's `core.Timeline_State`.
  The node keeps the `Timeline_Id`, given to it by the app.
- Flags say what changed at frame 0: `.Started`, `.Stopped` and `.Jumped`
  (a locate or loop wrap) on a timeline, and `.Tempo_Changed` and
  `.Meter_Changed` on the clock. On `.Jumped` or `.Stopped`, a sampler should
  end its notes.

To act on beats inside the call, find the first beat due with
`transport_next_multiple`, then its frame with `transport_offset_of`. The
metronome in the example does exactly this:

```odin
next := core.transport_next_multiple(t, 1) // next whole grid beat due
click_at := core.transport_offset_of(t, next)
for i in 0 ..< ctx.frames {
	if i == click_at {
		// ... start a click ...
		next += 1
		click_at = core.transport_offset_of(t, next)
	}
}
```

Use `timeline_next_multiple` and `timeline_offset_of` for a timeline's own
beats. Don't round `t.grid` yourself. A beat that fell between the previous
call's last frame and this call's first is due at frame 0 here, and these
helpers get that right.

## Showing time in a UI

From the control thread, `transport.status(clock)` gives the grid and tempo,
and `transport.timeline_status(clock, id)` gives a timeline's position and
play state, as of a recent block.

## MIDI clock out

`transport.midi_clock_create` makes a node that sends 24-PPQ clock and,
following a timeline, Start, Stop, Continue and Song Position:

```odin
mc, _ := graph.add_node(g, transport.midi_clock_create({follow = song}), 0, 0)
graph.connect_events(g, mc, graph.OUTPUT)
graph.commit(g)

// After processing each block, send the graph's MIDI output:
midi.output_push_events(&out, core.event_writer_events(&writer), ports[:], b.output_ns, sample_rate)
```

Ticks fall on the followed timeline's beats while it plays, and on the grid
otherwise (set `send_while_stopped` to keep ticking).

## Ableton Link

`fire:link` syncs tempo and beat phase with other apps on the network.

:::caution[Licence]
Ableton Link is GPLv2+ unless you hold Ableton's commercial licence. An app
that links `fire:link` must follow those terms. The rest of Fire Engine is
MIT and never depends on it.
:::

Build the library once (it fetches a pinned Link release into
`third_party/`, which is never committed):

```bash
./scripts/link.sh
```

Then attach Link to the clock:

```odin
l, _ := link.create(120, quantum = 4)
defer link.destroy(l)
transport.set_sync(clock, link.sync(l))
link.enable(l, true)
```

The clock now runs at the session tempo, and its grid is the session's beat
timeline. Quantized launches therefore land on the same downbeats as your
peers' (with a quantum of one bar). `set_tempo`, or a leader's tempo map,
changes the session tempo for everyone. Before `link.destroy`, detach with
`transport.set_sync(clock, {})` and let one block pass.

## See also

- [`fire:transport` reference](/reference/transport/) and
  [`core.Transport`](/reference/core/#transport)
- [Design: clock and timelines](/design/transport/)
