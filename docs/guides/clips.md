---
title: Clips
description: MIDI and audio clips on timelines, as launcher loops or arranged regions; per-note expression, tempo-following audio, seamless loops, and MIDI files.
---

`fire:clip` turns the clock's timelines into music. A **clip** holds the
content. A **player** is a graph node that plays one clip on one timeline,
sample-accurately. There are MIDI clips (notes in beats) and audio clips
(regions of files).

- `examples/midi_clips` plays a launcher loop and an arranged clip
  together, then saves them as a MIDI file.
- `examples/audio_clips` plays a 100 BPM loop repitched into a 120 BPM
  session.

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

## Audio clips

An audio clip is a region of a file, read through
[disk streaming](/guides/audio-files/#streaming-from-disk), plus how to play
it:

```odin
src, _ := stream.source_open(streamer, "drums_100bpm.wav")
loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = .Repitch})
defer clip.audio_clip_release(loop)

node, player := clip.audio_player_create(clip.default_audio_player_settings(tl, streamer))
id, _ := graph.add_node(g, node, 0, 2) // stereo out
clip.audio_player_set(player, loop, {loop = true})
for !clip.audio_player_ready(player) do time.sleep(time.Millisecond) // preroll
transport.play(clock, tl, tb.Quantize.Bar)
```

**Modes:**

| Mode | Follows tempo | Pitch | Use for |
|------|---------------|-------|---------|
| `.Original` | no: plays at the file's speed | unchanged | one-shots, vocals, dialogue |
| `.Repitch` | yes, by speed (`bpm` says the material's tempo) | moves with tempo | drum loops, vinyl-style |
| `.Stretch` | yes (time-stretched) | unchanged | loops and stems at any tempo |

### Time-stretching

`.Stretch` clips need a stretcher in the player's settings. `fire:stretch`
provides Signalsmith Stretch (MIT, C++, vendored). Build it once:

```bash
./scripts/stretch.sh
```

```odin
settings := clip.default_audio_player_settings(tl, streamer)
settings.stretcher = &stretch.signalsmith
node, player := clip.audio_player_create(settings)
id, _ := graph.add_node(g, node, 0, 2) // prepare first: the stretcher needs the sample rate
loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = .Stretch})
clip.audio_player_set(player, loop, {loop = true})
```

- **Tempo without pitch change.** `examples/stretched_loop` plays the same
  tone repitched and stretched through a tempo ramp. Repitched, it rises
  from 407 Hz to 571 Hz; stretched, it stays at 440 Hz.
- **On the beat.** The stretcher hears its input about 60 ms late (it
  analyses 120 ms blocks). The player primes it at every start and jump
  and feeds it ahead, so clicks recorded on beats land on the timeline's
  beats. In the tests they land within about 3 ms, with no drift through
  tempo changes and loops.
- **Cost.** Stretching costs far more CPU than repitching (FFT analysis
  and resynthesis), so use it where pitch must hold.
- **Bring your own.** `fire:clip` itself has no C++. Any
  `clip.Stretcher_VTable` works, and a pure-Odin port of Signalsmith
  Stretch is planned.

**Settings:**

- `start` and `end` choose the region of the file.
- `loop_start` and `loop_end` choose what a looping placement repeats.
- `gain` is linear.
- `fade_in` and `fade_out` default to 5 ms. They apply only to clips that
  don't loop, because a loop is assumed to be seamless.

**What the player does:**

- **Converts the sample rate.** A 44.1 kHz file on a 48 kHz device just
  works.
- **Stays locked to the timeline.** In `.Repitch`, each 256-frame chunk
  plays exactly the source frames for the beats the timeline covers in that
  chunk. It follows tempo changes and ramps to within a frame, with no
  seeking.
- **Loops seamlessly:** the resampler is fed audio that already wraps at the
  loop points.
- **Never clicks.** Starts fade in over `DECLICK_FRAMES` (128). Stops,
  jumps and clip swaps crossfade over the same length.
- **Jumps instantly to cues.** The player's stream has cues at the clip's
  start, its loop start and the placement's offset. Other jumps may play
  silence until the disk delivers (`stream.stats` counts it).

Output mapping: a mono file plays on every output, a stereo file averages
into a mono output, and otherwise channels map one to one.

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
