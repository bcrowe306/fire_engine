---
title: MIDI clips
description: Build MIDI clips with notes, per-note expression and controllers, play them on timelines as launcher loops or arranged regions, and read and write MIDI files.
---

`fire:clip` turns the clock's timelines into music. A **clip** holds the
content in beats. A **player** is a graph node that plays one clip on one
timeline, sample-accurately. `examples/midi_clips` plays a launcher loop and
an arranged clip together, then saves them as a MIDI file.

## Building a clip

Clips are immutable: your app keeps its own editable model (notes in a UI,
an undo history) and builds a clip from it after each edit.

```odin
b: clip.Midi_Builder
clip.midi_builder_init(&b, length = 8) // beats
defer clip.midi_builder_destroy(&b)

n := clip.add_note(&b, start = 0, length = 1, key = 60, velocity = 0.8)
clip.add_expression(&b, n, at = 0.5, kind = .Tuning, value = 2) // per-note: bend up 2 semitones
clip.add_controller(&b, at = 4, bytes = {0xB0, 74, 90})        // CC 74 on channel 1
clip.set_loop(&b, 0, 4)                                        // repeat only the first 4 beats

c, err := clip.midi_build(&b) // one reference, yours
```

- Notes may be added in any order. The clip sorts them by start, then key.
- **Expression** is per note (MPE or MIDI 2.0 style): volume, pan, tuning,
  vibrato, brightness and pressure, sent as `core.Note_Expression` with the
  note's own `Note_Id`. Points are steps; for a smooth bend, add points
  densely.
- **Controllers** are MIDI 1.0 channel messages (CC, pitch bend, pressure,
  program change), sent as `core.Midi_Raw`.

## Playing it

```odin
node, player := clip.midi_player_create({timeline = tl})
id, _ := graph.add_node(g, node, 0, 0)     // no audio, only events
graph.connect_events(g, id, synth)         // or graph.OUTPUT
graph.commit(g)

clip.midi_player_set(player, c, {loop = true})
clip.midi_clip_release(c) // the player holds its own reference
```

The `Placement` given to `midi_player_set` decides where the clip sits on
its timeline:

| Style | Placement | Meaning |
|-------|-----------|---------|
| Launcher | `{loop = true}` | From the timeline's beat 0, looping as long as it plays. Launch with `transport.play(clock, tl, tb.Quantize.Bar)`. |
| Arrangement | `{at = 32, length = 16}` | On the timeline from beat 32 for 16 beats. |
| Trimmed start | `{at = 32, length = 16, offset = 2}` | The same, but starting 2 beats into the clip. |
| Looped region | `{at = 32, length = 16, loop = true}` | Repeats the clip's loop until beat 48. |

Calling `midi_player_set` again swaps in a new clip or placement at the
player's next block. Notes already sounding finish normally. This is how
edits reach a playing clip.

## What the player guarantees

- **Exact frames, any block size.** A note lands on the first frame at or
  after its beat, and every block pattern gives exactly the same events.
- **No stuck notes.** A stop ends every sounding note. So does a jump: a
  locate or a timeline loop wrap.
- **Chasing.** After a start, jump or loop wrap, or when playback enters a
  clip, notes already in progress start at once with what remains of them.
  A pad entered mid-bar still sounds.
- **Cuts.** Notes end at the clip's loop end and at the end of the
  placement.
- Notes from before a clip's loop start are not replayed by the loop.

## MIDI files

```odin
mf, err := clip.midi_file_read("song.mid") // type 0 or 1
defer clip.midi_file_destroy(&mf)
for t in mf.tracks do fmt.println(t.name, len(t.clip.notes))
// mf.tempo_map holds the file's tempo and time signature changes

clip.midi_file_write("out.mid", {{"Bass", bass}, {"Keys", keys}}, &tempo_map)
```

- Each track with notes or controllers becomes a clip. All clips are as
  long as the longest track, rounded up to a whole bar, since MIDI files
  don't store a clip length.
- Writing makes a type 1 file: a conductor track with tempos and time
  signatures, then one track per clip. Tempo ramps are written as steps
  every eighth note.
- Per-note expression has no MIDI 1.0 form and is not written. Tempos
  round to whole microseconds per beat, as the format stores them.

## See also

- [`fire:clip` reference](/reference/clip/)
- [Tempo and timelines](/guides/transport/): launching, looping and
  locating the timelines clips play on
