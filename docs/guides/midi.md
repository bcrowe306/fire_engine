---
title: MIDI
description: MIDI input and output on every platform, sample-accurate input into the audio graph, scheduled output, SysEx and virtual ports.
---

[`fire:midi`](/reference/midi/) gives one API over CoreMIDI, the ALSA sequencer
and WinMM. MIDI arrives on OS threads; the engine turns it into
sample-accurate events for the audio thread.

| Platform | Create | Virtual ports | Scheduled output |
|----------|--------|---------------|------------------|
| macOS | `coremidi.create()` | yes | by CoreMIDI |
| Linux | `alsa_midi.create()` (package `fire:midi/alsa`) | yes | by the kernel queue |
| Windows | `winmm.create()` | no (`.Unsupported`) | by the engine's sender thread |

## Input into the graph

```odin
input: midi.Midi_Input
midi.input_init(&input)
d, _ := coremidi.create()
d.input = &input

ports, _ := midi.enumerate(d)
for p in ports do if p.direction == .Input do midi.open_input(d, p.id, 0)
midi.port_infos_destroy(ports)

// Fixed latency makes timing jitter-free: one buffer plus the output offset.
midi.input_set_latency(&input, midi.suggested_latency_ns(output_offset_ns, buffer_frames, sample_rate))
```

In the audio callback, turn the MIDI that has arrived into events for this
block, and hand them to the graph:

```odin
events: [256]core.Event
writer := core.Event_Writer{buffer = events[:]}
midi.input_process(&input, block.output_ns, block.frames, sample_rate, &writer)
ctx := core.Process_Context{
	inputs = block.inputs, outputs = block.outputs, frames = block.frames,
	events_in = core.event_writer_events(&writer),
}
graph.process(g, &ctx) // nodes event-connected to graph.INPUT receive core.Midi_Raw
```

An event received at host time `t` lands at `t + latency`. With the suggested
latency, every event reaches its block in time and lands on its exact frame.
Late events go to offset 0 and are counted (`midi.input_stats`).

## SysEx

Complete SysEx messages bypass the audio thread and go to the control thread:

```odin
for msg in midi.sysex_pop(&input.sysex) {
	defer delete(msg.data)
	handle_sysex(msg.port, msg.data) // payload without F0/F7
}
```

## Output

Send from the control thread directly with `midi.send(d, port, bytes, time_ns)`.
From the audio thread, push into a `Midi_Output`, whose sender thread delivers
messages at their times:

```odin
out: midi.Midi_Output
midi.output_init(&out, d)
midi.output_start(&out)
port, _ := midi.open_output(d, some_id)

// In the audio callback: a note at frame 100 of this block.
t := midi.frame_time_ns(block.output_ns, 100, sample_rate)
midi.output_push(&out, {t, port, {0x90, 60, 100}})
```

## Virtual ports and hot-plug

- `midi.create_virtual_input` and `create_virtual_output` make ports other
  apps can see (macOS and Linux).
- Poll `midi.poll_event(d)`: `.Ports_Changed` means re-enumerate; `.Port_Lost`
  names an open port whose device went away. WinMM can only report ports
  appearing.

## See also

- [`fire:midi` reference](/reference/midi/)
- [Design: backends](/design/backend/#midi-firemidi-firemidicoremidi-firemidialsa-firemidiwinmm)
