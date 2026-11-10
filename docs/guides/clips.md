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
- `examples/clip_launcher` and `examples/arrangement` are the two ways of
  making a session out of them, described at the end of this guide.

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
- **Chance.** `add_note(..., probability = 0.5)` plays a note half the
  times it comes round. The player rolls with its own generator, seeded
  by `Midi_Player_Settings.seed`: the same seed makes the same choices, at
  any block size. Saved clips keep it (MIDI clip chunks, version 2).
- **Swing** is applied while building: `clip.swing(at, grid, amount)`
  moves off-beat positions late (amount 0 is straight, 1 puts the
  off-beat three quarters through its pair, 2/3 a triplet feel), and the
  positions between in proportion, so notes keep their order. Keep your
  model straight and swing the clip you build from it.
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
provides Signalsmith Stretch (MIT), ported to Odin: no build step.

```odin
settings := clip.default_audio_player_settings(tl, streamer)
settings.stretcher = &stretch.signalsmith
node, player := clip.audio_player_create(settings)
id, _ := graph.add_node(g, node, 0, 2) // prepare first: the stretcher needs the sample rate
loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = .Stretch})
clip.audio_player_set(player, loop, {loop = true})
```

A Stretch clip can also be shifted in pitch, independently of tempo, with
`transpose` in semitones (`{bpm = 100, mode = .Stretch, transpose = -3}`).
Only Stretch clips transpose; a custom stretcher needs `set_transpose` for it.

- **Tempo without pitch change.** `examples/stretched_loop` plays the same
  tone repitched and stretched through a tempo ramp. Repitched, it rises
  from 407 Hz to 571 Hz; stretched, it stays at 440 Hz.
- **On the beat.** The stretcher hears its input about 60 ms late (it
  analyses 120 ms blocks). The player primes it at every start and jump
  and feeds it ahead, so clicks recorded on beats land on the timeline's
  beats. In the tests they land within about 3 ms, with no drift through
  tempo changes and loops.
- **Cost.** Stretching costs far more CPU than repitching (FFT analysis
  and resynthesis), so use it where pitch must hold. On an Apple M1, a
  stereo clip at the default preset takes about 0.7% of one core (10 s in
  71 ms), as fast as the C++ original.
- **Bring your own.** Any `clip.Stretcher_VTable` works; `fire:stretch`
  is one.

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

## Automation

An `Automation_Clip` holds one curve (a lane) per parameter, in beats. An
automation player node plays it on a timeline and moves the parameters of
the node it is event-connected to, sample-accurately: one player per node
being automated, one lane per parameter of that node. Clips are built, placed and
swapped like MIDI clips, so the same clip can be a launcher clip's envelope
or an arrangement lane.

```odin
b: clip.Automation_Builder
clip.automation_builder_init(&b, length = 16)
clip.automation_add_point(&b, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 0, 200, .Curve, tension = 0.6)
clip.automation_add_point(&b, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 8, 8000)
clip.automation_add_point(&b, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 16, 200)
sweep, _ := clip.automation_build(&b)
clip.automation_builder_destroy(&b)

node, player, _ := clip.automation_player_create({timeline = song})
auto, _ := graph.add_node(g, node, 0, 0)
graph.connect_events(g, auto, filter) // a one-pole lowpass: the lane is its cutoff
clip.automation_player_set(player, sweep, {loop = true})
clip.automation_clip_release(sweep)
```

**Segments.** Each point says how the value moves on to the next one:

| Shape | Moves |
|-------|-------|
| `.Linear` | in a straight line |
| `.Step` | not at all, then jumps at the next point |
| `.Curve` | along a bend set by `tension` (−1..1): positive starts slowly, negative quickly |

Two points at the same position make a jump there. Before a lane's first
point it holds the first value, after its last the last. Values are in the
parameter's own units (`Param_Info`: dB, Hz and so on), so a straight
segment in dB is a natural fade.

**What the node receives.**

- **While playing:** `core.Param_Ramp` events, which the node follows
  exactly, without its own smoothing. Straight segments are one ramp per
  block; curved ones, and anything under a tempo ramp, are ramps of at most
  `curve_frames` (64 by default).
- **Jumps** (steps, loop wraps, starts and locates) land on their exact
  frame. To soften one, use a short linear segment instead of a step.
- **While stopped:** a locate or a new clip sends each lane's value at the
  new position as a plain `Param_Value`, which the node smooths.
- **Outside the placement:** nothing, so parameters keep their last value.

Nodes need to handle ramps for this; see
[Writing a node](/guides/writing-a-node/). Fire Engine's own nodes do.

**Handing a parameter to the user.** While the user moves an automated
control, suspend its lane; when they let go (or on the next loop, for
latch), resume it with a glide back to the curve:

```odin
clip.automation_player_suspend(player, dsp.ONE_POLE_PARAM_CUTOFF_HZ)
graph.set_param(g, filter, dsp.ONE_POLE_PARAM_CUTOFF_HZ, user_hz) // the user's moves
clip.automation_player_resume(player, dsp.ONE_POLE_PARAM_CUTOFF_HZ, glide_ms = 50)
```

To record moves into the curve, send them through an automation recorder
and merge its takes with `clip.automation_merge`: see
[Recording](/guides/recording/#automation).

## Building a clip launcher

`examples/clip_launcher` is a grid of two tracks by two scenes, played by
a script of mid-bar presses. Its pattern:

- **One timeline per slot.** Launching a slot locates its timeline to the
  start and plays it on the next bar, and stops the track's other slots on
  that same bar:

  ```odin
  for s, i in track.slots {
  	if i == scene {
  		transport.locate(clock, s.timeline, 0, tb.Quantize.Bar)
  		transport.play(clock, s.timeline, tb.Quantize.Bar)
  	} else {
  		transport.stop(clock, s.timeline, tb.Quantize.Bar)
  	}
  }
  ```

  The clock applies all of them on the bar's frame, so the old clip ends
  exactly where the new one starts. A scene is the same for every track.
  Swapping clips under one timeline with `midi_player_set` would not work
  for this: a swap takes effect at the next block, not on a bar.
- **Players per slot, nodes per track.** Each slot has its players (MIDI or
  audio) on its timeline. A track's instruments and effects are shared:
  every slot's MIDI player is event-connected to the track's synth, and
  audio players sum into the track's input.
- **Envelopes.** An automation player on the slot's timeline makes a clip's
  automation follow its launches. Parameters keep their last value when a
  slot stops, so if one slot of a track automates a parameter, give its
  other slots a lane for it too (the demo's steady 600 Hz cutoff).
- **Stopping.** A stopped MIDI player ends its notes; an audio player fades
  out over `DECLICK_FRAMES`.

## Building an arrangement

`examples/arrangement` lays out three tracks of regions on a song with a
tempo change, loops its second half and edits the bass while it plays.

- **One song timeline** that leads, with a tempo map:
  `transport.add_timeline(clock, &tempo_map)`, then `transport.set_leader`.
- **One player per region,** each placed with `{at, length, loop}` on the
  song timeline; a track's regions feed the track's nodes. A drum track of
  two regions is two audio players into the same output.
- **Automation lanes** are automation clips placed like regions:
  `{at = 0}` without a length spans the song, and `{at = 16, length = 16}`
  is a region-length envelope such as a fade.
- **Looping and locating** use the song timeline (`transport.set_loop`,
  `transport.locate`). MIDI players chase notes already in progress at the
  new position; audio players jump to it (instantly at their cues, see
  above).
- **Edits.** Rebuild the edited clip and set it again with the same
  placement. It replaces the old one at the player's next block.
- **Bouncing** is the same loop run offline, writing each block with
  `audiofile.writer_write`. Put the streamer in offline mode first
  (`stream.set_offline(streamer, true)`), so audio players wait for the disk
  instead of dropping out when the render runs ahead of it.

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
- [Recording](/guides/recording/): audio takes, MIDI overdubs and
  automation, ready to play as clips
