---
title: Pads
description: The Pads sampler built on the application layer — loading, playing and shaping samples on 64 pads, chopping, stretching and editing them, and driving and testing it from scripts.
---

Pads (`apps/pads`) is a sampler and sequencer built on Fire Engine and its
[application layer](/guides/app-layer/). It is one binary: SDL3 and Dear
ImGui are linked in. This page covers what it does so far (samples: the
fourth milestone of `app/PLAN.md`); the sequencer, the mixer and song mode
come next.

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
- `apps/pads/*.odin` is the UI: one file per panel, the actions and menus
  in `shell.odin`.

Costs (Apple M-series, optimized): 0.35 ms of CPU per frame with a bank
loaded (p99 0.8 ms); on 30 s of audio, import 3 ms, chop at transients
76 ms, normalize 8 ms, stretch 87 ms.

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
```

A failed `expect` makes Pads exit 1. `tests/app_ui/drive/pads.txt` drives
the model by command and takes the layout screenshots (dark, light,
narrow); `pads_input.txt` uses only input events — keys, clicks, a knob
drag, shortcuts, the palette — and checks the model after each.

```bash
task app:test          # tests/app_* and tests/pads_*, the UI cases, then both scripts
task app:pads-drive    # just the scripts (debug build, fake driver, headless)
.build/app/pads --fake --headless --drive tests/app_ui/drive/pads.txt --out .build/app/pads_shots
.build/app/pads --fake --headless --profile 600 --drive tests/app_ui/drive/profile_loaded.txt
```

The sample fixtures are made by `tests/app_ui/fixtures/make.py`.
