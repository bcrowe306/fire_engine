---
title: Playing live
description: An arpeggiator and note repeat locked to the clock's grid (fire:perform), run inline in an instrument or as graph nodes.
---

[`fire:perform`](/reference/perform/) holds note effects for playing live:
an **arpeggiator** and **note repeat**. Both follow the clock's beat grid,
so their notes land on the exact frame of each step at any block size, and
both are plain structs with a `process` proc that turns one block's
incoming events into outgoing ones: run them inside your own node (Pads
runs them in its router), or as nodes of their own.

```odin
node, arp := perform.arp_node_create({mode = .Up, rate = .Sixteenth, octaves = 2, gate = 0.5})
id, _ := graph.add_node(g, node, 0, 0)
graph.connect_events(g, graph.INPUT, id) // MIDI or a keyboard in
graph.connect_events(g, id, synth)       // notes out
graph.commit(g)
perform.arp_node_set(arp, {mode = .Random, rate = .Eighth_Triplet}) // later, from the control thread
```

Inline, from a node's `process`:

```odin
a: perform.Arp
perform.arp_init(&a, {mode = .Up_Down, rate = .Sixteenth})
// [rt], each block:
perform.arp_process(&a, ctx.transport, ctx.frames, ctx.events_in, ctx.events_out)
```

## The arpeggiator

- Held notes play one after another, a step apart; the first on the first
  step at or after the first key.
- **Modes:** `.Up`, `.Down`, `.Up_Down` (the ends once), `.Random` (seeded:
  the same seed, the same notes), `.As_Played`.
- **Octaves** 1–4 repeat the pattern higher; **gate** is how much of a
  step each note sounds (0.05–1).
- **Latch** keeps the notes playing after the keys are let go; the first
  key of a new chord replaces them.
- Note-ons and note-offs are consumed; everything else passes through.

## Note repeat

A held note plays at once, then again on every step while it is held
(every held note, for chords). A key pressed exactly on a step plays once.

## Guarantees

- Every note an effect starts, it ends: on its gate, on release, or on
  `arp_reset` / `repeat_reset` (a stop, a bypass).
- Each note it plays has its own `core.Note_Id`.
- No allocation on the audio thread; the same output for any block sizes
  (`tests/perform`).
- Without a transport (`ctx.transport` nil) they pass events through.

## See also

- [Transport](/guides/transport/) for the clock and timelines
- [MIDI](/guides/midi/) for MIDI into the graph
