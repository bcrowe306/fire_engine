---
title: Recording
description: Record audio takes to disk, MIDI and automation into clips, with punch in/out, loop recording, overdub, and latency compensation you can measure.
---

`fire:record` records into what [clips](/guides/clips/) play: audio takes
written to disk, MIDI clips, and automation lanes. Recorders are graph
nodes that follow a timeline, so a take knows exactly where it belongs.

`examples/recording` loop-records all three over a one-bar loop, offline.

## Audio takes

A `Disk_Writer` owns a thread that writes the takes of any number of
audio recorders. A recorder is a sink node: connect what it records to
its inputs.

```odin
disk, _ := record.disk_writer_create({})
defer record.disk_writer_destroy(disk) // after the graph

node, vocal, _ := record.audio_recorder_create(disk, {
	timeline = song, channels = 2, directory = "takes", name = "vocal",
})
id, _ := graph.add_node(g, node, 2, 0)
graph.connect(g, graph.INPUT, 0, id, 0)
graph.connect(g, graph.INPUT, 1, id, 1)
graph.commit(g)

record.audio_recorder_arm(vocal, true)
transport.play(clock, song)
```

- **When it records:** while armed and its timeline plays. With a punch
  range (`audio_recorder_set_punch(vocal, 16, 32)`), only between those
  positions. With no timeline, whenever armed, like a tape.
- **Takes** come back once they are finished: at a stop, a disarm, a
  punch-out, a locate or a loop wrap. Poll from the control thread:

  ```odin
  for &take in record.audio_recorder_poll(vocal) {
  	defer record.take_destroy(&take)
  	src, _ := stream.source_open(streamer, take.path)
  	c, _ := clip.audio_clip_create(src, {mode = .Original})
  	clip.audio_player_set(player, c, {at = take.start, length = take.length})
  }
  ```

  `take.start` is the timeline position of the take's first frame, and
  `take.length` the beats it covers. To make the clip follow later tempo
  changes, give it the tempo it was recorded at,
  `bpm = f64(take.length) / (f64(take.frames) / take.sample_rate) * 60`,
  and `.Repitch` or `.Stretch`.
- **Files** are `<directory>/<name>-<n>.wav`, 32-bit float by default
  (`encoding` for 16, 24 or 32-bit integer). They are valid WAV files
  even if the app crashes while recording.
- **Offline**, create the writer with `{manual = true}` and call
  `disk_writer_service` after each block: everything is written as you
  go, and nothing can be dropped.

**What a recorder guarantees:**

- **Exact frames at any block size.** Punch edges land on the first frame
  at or after the position; the same input gives the same file whatever
  the block pattern.
- **The audio thread never waits.** It copies into blocks preallocated at
  creation (4 s of audio by default, `buffer_seconds`). If the disk falls
  further behind than that, the missing audio is written as silence, so
  everything after it stays in place; `take.dropped_frames` and
  `audio_recorder_status` count it.
- **Cost:** a copy. On an Apple M1, 16 stereo recorders take 11 µs per
  512-frame block in all (0.1% of the block's time), and the disk thread
  keeps up at 14× real time.

## Latency

A performer plays along with what they hear, which leaves the engine
some time before it reaches their ears. What they play then takes time
to come back in. Without compensation every take lands late by that
round trip.

Recorders shift what they record by `latency_frames`: what arrives at
frame f is placed where the timeline was at f − latency. Punch edges and
loop wraps follow the shifted time, so a take punched in at bar 5 starts
with what was played at bar 5.

**Setting it.** Once the device is running:

```odin
record.audio_recorder_set_latency(vocal, backend.round_trip_latency_frames(&dev))
```

`round_trip_latency_frames` uses the driver's timestamps (when each
callback's input was captured and its output will be heard), and falls
back to the latencies the driver reports. Drivers differ in how well
these match reality. On the loopback devices Fire Engine tests with:

| Driver | Loopback measured | From timestamps | Reported latencies |
|---|---|---|---|
| CoreAudio, BlackHole | 512 | 512 | 0 |
| ALSA, snd-aloop | 2048 | 2048 | 1024 |
| JACK, a port connected to a port | 1024 | 2048 | 1024 |
| WASAPI, VB-CABLE | about 6400 | about 2300 | 0 |

The JACK and VB-CABLE rows are virtual devices with delays of their own
that no driver can see. Hardware interfaces vary too, so the reliable way
is to measure.

**Measuring it.** A `Latency_Probe` plays a short noise burst and finds it
in its input. Connect a cable from an output to an input (or hold a
microphone to a speaker), put the probe where the recorders are, and:

```odin
node, probe, _ := record.latency_probe_create({})
id, _ := graph.add_node(g, node, 1, 1)
graph.connect(g, graph.INPUT, 0, id, 0)
graph.connect(g, id, 0, graph.OUTPUT, 0)
graph.commit(g)

record.latency_probe_start(probe)
// about a second later:
if frames, quality, ok := record.latency_probe_result(probe); ok && quality > 0.5 {
	record.audio_recorder_set_latency(vocal, frames)
}
```

`quality` is the normalised correlation of what came back with what was
played: 1 for a clean copy at any level. The probe measures exactly what
the recorders compensate, including the engine's own block splitting.

MIDI usually needs no compensation: a keyboard's notes arrive within a
millisecond. Its recorder has the same `latency_frames` setting if yours
doesn't.

## Loop recording

When the timeline loops while a recorder records, every pass becomes its
own take. Takes of one recording share a `run`; `pass` counts from 0. All
passes of a loop over beats 0–16 have `start = 0` and `length = 16`
(the first may start later if recording began mid-loop), so any of them
can be placed over the loop: keep the last, or let the user pick (comp).

## MIDI

A `Midi_Recorder` records the notes (with per-note expression) and MIDI
channel messages it receives, into one MIDI clip per take:

```odin
node, keys, _ := record.midi_recorder_create({timeline = song})
id, _ := graph.add_node(g, node, 0, 0)
graph.connect_events(g, graph.INPUT, id) // the device's MIDI input
graph.commit(g)
record.midi_recorder_arm(keys, true)

for take in record.midi_recorder_poll(keys) {
	// take.clip: notes from take.start, take.length beats long
}
```

Notes still held when a take ends are cut there. Notes held when it
starts (before a punch-in) aren't recorded.

**Overdubbing** merges what is played into the clip that is playing.
`midi_recorder_progress` returns the take so far, with every note
finished since the last call, so the merge can happen as you play and
the new notes sound on the next pass:

```odin
// Every UI frame: the slot's clip is what it was before recording,
// plus every pass so far.
if p, ok := record.midi_recorder_progress(keys); ok {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, base.length)
	clip.add_clip(&b, base)
	for t in finished_passes do clip.add_clip(&b, t.clip, t.start)
	clip.add_clip(&b, p.clip, p.start)
	merged, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	clip.midi_player_set(player, merged, {loop = true})
	clip.midi_clip_release(merged)
	clip.midi_clip_release(p.clip)
}
```

Keeping the passes as takes means undoing an overdub is rebuilding
without the last one.

## Automation

An `Automation_Recorder` is how the app moves a parameter while it may
be recording: it passes each value on to the node it is event-connected
to, at the start of its next block, and while armed and playing writes
the moves down.

```odin
node, knob, _ := record.automation_recorder_create({timeline = song, mode = .Touch})
id, _ := graph.add_node(g, node, 0, 0)
graph.connect_events(g, id, filter)
graph.commit(g)
record.automation_recorder_arm(knob, true)

// The user grabs the cutoff knob, turns it, lets go:
clip.automation_player_suspend(lane, CUTOFF)      // the curve stops moving it
record.automation_recorder_touch(knob, CUTOFF, hz)
record.automation_recorder_set(knob, CUTOFF, hz)  // as it turns
record.automation_recorder_release(knob, CUTOFF)
clip.automation_player_resume(lane, CUTOFF)
```

- **Touch** writes while the control is held. **Latch** goes on writing
  its last value after the release, until the take ends.
- Each move is written as the old value held until it, then a short
  glide to the new one (`glide_ms`, 10 ms by default), close to what the
  node's own smoothing made of it live.
- Moves take effect at block starts (the control thread can't be more
  precise than that), and are written where they took effect.

Each take is one written range of one parameter, in timeline positions.
`clip.automation_merge` replaces that range of a lane with it:

```odin
for take in record.automation_recorder_poll(knob) {
	merged, _ := clip.automation_merge(cutoff_clip, take.param, take.start, take.end, take.points)
	clip.automation_clip_release(cutoff_clip)
	cutoff_clip = merged
	delete(take.points)
}
clip.automation_player_set(lane, cutoff_clip, {loop = true})
```

Positions in a take are timeline positions; if the lane's clip is placed
elsewhere (`at = 32`), subtract the placement first.

## See also

- [`fire:record` reference](/reference/record/)
- [Clips](/guides/clips/): playing what was recorded
- [Audio devices](/guides/devices/): device timestamps and latencies
