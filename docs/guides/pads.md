---
title: Pads
description: The Pads sampler built on the application layer — loading, playing and shaping samples on 64 pads, chopping, stretching and editing them, and driving and testing it from scripts.
---

Pads (`apps/pads`) is a sampler and sequencer built on Fire Engine and its
[application layer](/guides/app-layer/). It is one binary: SDL3 and Dear
ImGui are linked in. This page covers what it does so far (samples, the
sequencer and playing live: milestones 4 and 5 of `app/PLAN.md`); the
mixer and song mode come next.

```bash
task deps        # once per machine: the static SDL3 and ImGui libraries
task app:run     # build (optimized) and run
task app:pads OPT=none   # a debug build in .build/app/pads
```

| Option | |
|---|---|
| `--project DIR` | the project folder (default: a new one in the temporary folder) |
| `--fake` | the simulated audio driver: no sound card needed |
| `--drive FILE` | run from a [drive script](#scripts-and-tests) |
| `--out DIR` | where a script's screenshots go (default `.build/app/shots`) |
| `--headless` | no window on screen |
| `--profile N` | draw N frames flat out and print the CPU time per frame (after `--drive`'s script, if given) |

With `--fake`, the simulated device runs on the UI thread as frames go by,
so everything plays (and scripts play the same way every run) without a
sound card. Without it, Pads opens the default output and every MIDI input
port.

## The window

- **Browser** (left): folders and audio files. Double-click a file to put
  it on the selected pad, or drag it onto a pad.
- **Pads** (centre): 4 banks (A–D) of 16. Click a pad, or press its key —
  `1 2 3 4 / Q W E R / A S D F / Z X C V`, the top row first — to play it
  and select it. Files dropped on the window from the desktop land on the
  pad under the mouse.
- **Pad** (right): the selected pad's name and colour; its mode
  (**One-shot** plays to the end, **Gate** while held, **Loop** loops
  while held, **Hold** loops until hit again); reverse; loop direction and
  crossfade; choke group (a pad cuts the others in its group); volume,
  pan, pitch, attack and release; a three-band EQ.
- **Sample** (bottom): the waveform. Drag **S** and **E** to set the region
  the pad plays, **L** for the loop; drag across the wave to select. The
  toolbar (it wraps when narrow):
  - edits — crop, delete, silence, fade in and out, normalize, reverse,
    trim silence, and put the selection on the next empty pad. Edits write
    a new file into the project and leave the original alone, so they undo;
  - **Chop** — at the transients (with a sensitivity) or into equal parts,
    onto consecutive pads, each playing its slice of the same file;
  - **Stretch to beats** — time-stretch the region to N beats at the
    project tempo, pitch unchanged;
  - record (the circle) — record the audio input onto the pad.

- **Sequence** (bottom, beside Sample): the sequencer. Play/stop (Space),
  record (Cmd+R) and the metronome; the slot (32 of them, those with notes
  marked); length (1–64 bars, ×2 doubles with the notes); the grid (1/4
  to 1/64, triplets), Quantize (Cmd+U) and Live (quantize while
  recording); swing (on 1/8 or 1/16). Below, the current bank's pads as
  rows: click to add a note, drag to move, drag its end to resize,
  right-click to delete; the wheel scrolls the rows when they don't all
  fit. Under the rows, a lane: each note's velocity, its chance (the
  probability it plays each time round), or the selected pad's
  automation (volume, pitch or an EQ band; click to add a point, drag,
  right-click to delete). Recording overdubs: hit pads (mouse, keys or
  MIDI) while it plays, and each pass is one undo step. Pads light when
  the sequencer plays them.
- **Perform** (right, beside Pad): how the pads play — **Pads**, each its
  own sound; **Keyboard**, the 16 pads are a scale (or diatonic chords:
  triads, sevenths, power chords) on the selected pad, from any root and
  octave, the bottom-left pad the root; **Velocity**, the selected pad at
  16 velocities. **Note repeat** retriggers held pads on the grid;
  the **arpeggiator** walks held notes (up, down, up-down, random, as
  played; 1–4 octaves; gate; latch). MIDI: activity lights, **Learn**
  (the next note you play plays the selected pad), and **MIDI out** (the
  pad's hits also go out as a note on a channel).
- **File > Import MIDI File…** reads a `.mid` into the current sequence:
  drum keys onto the pads by the MIDI map (key 36 is A1).

Every change is undoable (Cmd+Z / Cmd+Shift+Z; Ctrl elsewhere). A knob
drag is one step. Cmd+K opens the command palette; Cmd+1..4 switch banks;
Delete clears the pad; View > Light Theme switches theme.

## Projects

A project is a folder. Imported files are copied into its `samples/`
folder (a name already taken gets a number), so a project carries its
audio. Saving the project file itself is milestone 7.

## How it is built

- `apps/pads/model` is the model, with no UI: the project (pads, samples
  in an `app:core` `Store`), the commands that edit it through `History`,
  the tools (chop, edit, stretch, record), and the engine. It is tested
  headless in `tests/pads_model`, rendering through the fake driver.
- The engine is one `fire:sampler` per pad (each pad's zone carries its
  region, loop, direction, crossfade, reverse and pan) into a three-band
  EQ, mixed. A router node plays the hits the UI posts through a
  lock-free queue, and handles choke groups (`core.Note_Choke`), Hold's
  toggle and Gate's release. `sync` rebuilds a pad's sample map after an
  edit marks it; it never blocks the audio thread.
- The sequencer is a timeline of the host's clock, a `clip.Midi_Player`
  playing the current sequence (rebuilt as a clip after each edit: swing
  applied with `clip.swing`, chance as the notes' `probability`, pitch as
  a tuning expression), and a `dsp.Metronome`. Its notes reach the router
  on MIDI channel 16, so they skip the live effects. Each pad also has two
  `clip.Automation_Player`s, into its sampler and its EQ; they let go of
  the pad when the sequencer stops.
- The router (model/router.odin) is the pipeline every note takes: UI hits
  and MIDI notes (by the MIDI map) are live notes; live notes go through
  the arpeggiator or note repeat (`fire:perform`) when one is on; then
  choke groups, Hold, Gate, keyboard notes (each its own voice, tuned),
  and MIDI out. It reports live notes back to the UI with the sequencer's
  position, for recording and MIDI learn.
- `apps/pads/*.odin` is the UI: one file per panel, the actions and menus
  in `shell.odin`.

Costs (Apple M-series, optimized): 0.35 ms of CPU per frame with a bank
loaded and the sequencer playing (p99 0.85 ms); the engine, with 8 pads in
a busy sequence, automation and the arpeggiator, 30× real time (3% of one
core); on 30 s of audio, import 3 ms, chop at transients 76 ms, normalize
8 ms, stretch 87 ms.

## Scripts and tests

Pads adds these commands to [drive scripts](/guides/app-layer/#driving-the-ui-from-a-script):

```text
load N PATH          load a file onto pad N (0..63)
hit N / release N    play pad N / let it go
select N / bank N    select a pad / show a bank (0..3)
browse DIR           show DIR in the browser
set N FIELD VALUE    volume, pan, pitch, mode (0..3), choke, reverse (0/1)
chop N equal K       (or: chop N transients SENSITIVITY)
theme light|dark     action ID (an action from the palette: undo, bank_b...)
expect pad N FIELD VALUE   sample, name, volume, pan, pitch, mode, start, end, choke
expect samples K / expect undo NAME / expect selected N / expect bank N / expect dark 0|1
panel ID             bring a panel to the front: browser, pads, inspector, perform, sequence, sample
play / stop / rec on|off / metronome on|off
slot N / bars N / tempo BPM / swing AMOUNT   (slot 1..32; swing 0..1 on 1/16)
note PAD BEAT LENGTH [VELOCITY]              a note in the current sequence
point PAD volume|pitch|low|mid|high BEAT VALUE   an automation point
lane velocity|chance|automation [PARAM]      what the editor's lane shows
mode pads|keys|velocity / scale NAME / chord off|triad|seventh|power
arp on|off / repeat on|off
midi KEY VELOCITY    a MIDI note in, as from a port (velocity 0: note-off)
learn PAD KEY / import_midi PATH
expect notes K / expect points K / expect playing 0|1 / expect slot N
expect midi_key PAD KEY / expect struck PAD MIN   (it has sounded MIN or more times)
```

A failed `expect` makes Pads exit 1. `tests/app_ui/drive/pads.txt` drives
the model by command and takes the layout screenshots (dark, light,
narrow); `pads_input.txt` uses only input events — keys, clicks, a knob
drag, shortcuts, the palette — and checks the model after each;
`pads_sequence.txt` covers the sequencer (by command, then by clicks,
Space and Cmd+R with the pad keys); `pads_perform.txt` the play modes,
repeat, the arpeggiator, MIDI in and learn, automation and MIDI import.

```bash
task app:test          # tests/app_* and tests/pads_*, the UI cases, then every pads*.txt script
task app:pads-drive    # just the scripts (debug build, fake driver, headless)
.build/app/pads --fake --headless --drive tests/app_ui/drive/pads.txt --out .build/app/pads_shots
.build/app/pads --fake --headless --profile 600 --drive tests/app_ui/drive/profile_loaded.txt
```

The fixtures (samples and `beat.mid`) are made by `tests/app_ui/fixtures/make.py`.
