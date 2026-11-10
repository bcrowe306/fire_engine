# Application layer and Pads: build plan

A library for building audio applications on Fire Engine (`app/`), and a
Koala-style sampler/sequencer built with it (`apps/pads/`). The engine
(`f_engine/`) never imports either.

## Decisions

| Topic | Decision |
|-------|----------|
| Layout | `app/` is its own collection (`-collection:app=app`): `app:core` (no GUI), `app:ui` (SDL3 + Dear ImGui). The sampler is `apps/pads/`. |
| Window, input | SDL3 through Odin's `vendor:sdl3`, **statically linked** (built from pinned source per platform). |
| GUI | Dear ImGui, docking branch, through the odin-imgui bindings vendored in `vendor/imgui/` (MIT), **statically linked**. |
| Renderer | SDL_GPU (Metal on macOS, Vulkan on Linux and the Raspberry Pi, D3D12 on Windows), with ImGui's SDL_GPU backend. |
| Look | A modern flat style built from design tokens (colour, spacing, radius, type), dark and light, switchable at runtime. Open Sans (SIL OFL) as the font, embedded in the binary. |
| Release | One executable per platform: no SDL or ImGui dylibs, fonts and shaders embedded. |
| Pads | 4 banks (A–D) × 16 pads. |
| Song | Sequence slots that chain (Koala's model) first; a timeline arranger later. |
| Mixing | Per-pad insert effects, 4 buses (A–D) and main with 5 effect slots each (engine effects and CLAP plug-ins), 16 performance FX applied while held, with HOLD. |
| Export | Mixdown WAV (16/24/32-float; 44.1/48/96 kHz), stems (per pad, per bus), resample to the next free pad. |
| Project files | A folder `Name.pads/`: `project.fire` (a `fire:session` file with the app's chunks) and `samples/` (imported, recorded and edited audio is copied in, so a project moves as one folder). |

## Library: `app:core` (headless)

Usable without a GUI, so a headless box (a Pi in a pedal) can run the same
model, commands and engine host.

- **Events.** A typed event bus. Publish/subscribe by event type, with
  subscription handles; queued delivery (drained once per frame on the UI
  thread) and immediate delivery. The audio thread publishes through a
  lock-free queue (meters, transport position, MIDI in, recording progress)
  without allocating; the bus forwards on the UI thread.
- **Commands and undo/redo.** A command has `do`, `undo`, a name, and an
  optional `merge` (consecutive knob moves become one undo step).
  Transactions group several commands into one step. The history keeps
  undo and redo stacks with a size limit, a "saved" marker for the
  unsaved-changes flag, and emits events on change. **Every edit to the
  model goes through a command**; widgets never write state directly.
- **State.** The document model as plain structs with stable IDs
  (pads, samples, sequences, slots, buses, effect slots). Changes are
  published as events. Serialization uses the engine's chunk format
  (`core.State_Writer`), versioned per chunk, stored as `fire:session` app
  chunks next to the engine's own state. Preferences (devices, theme,
  recent files, MIDI maps) live in a separate settings file.
- **Engine host.** Owns the audio device, clock, graph, streamer, disk
  writer and node registry. Opens and switches devices, survives a device
  being unplugged (reopens when it returns), renders offline for export.
  A **reconciler** maps the model to the engine: after each command it
  applies the difference (add a node, set a parameter, swap a clip), so
  the model is the source of truth and undo just works.
- **Jobs.** Background work with progress and cancel (decoding, chopping,
  stretching, exporting), reporting through the event bus.

## Library: `app:ui` (SDL3 + ImGui)

- **Platform.** SDL3 window, SDL_GPU device, ImGui docking context, frame
  loop with vsync and an idle mode (redraw only on input or events), high-DPI
  scaling, file drag-and-drop, native open/save dialogs (SDL3's).
- **Theme.** Design tokens to ImGui style and colours; dark and light;
  Open Sans regular, semibold and bold at a few sizes; a small embedded
  icon set (decided at M2, licence permitting).
- **Widgets.** Knob, fader, meter (peak and RMS, peak hold), pad, toggle,
  segmented control, waveform view (zoom, markers, selection), step grid,
  piano roll, automation lane, XY pad. Each returns what the user did; the
  caller turns that into a command.
- **Panels.** A panel interface (title, draw, menu items) with a docked
  layout that is saved; keyboard shortcuts bound to named actions; a
  command palette; notifications (toasts).

## App: `apps/pads`

- **Pads and samples.** Import by drag-and-drop or dialog; record from
  the input (loop record on bar lines, auto-trim). Per pad: trim, one-shot,
  gate and loop modes (forward, ping-pong, crossfade), attack and release,
  pitch, volume, pan, reverse, choke groups, 3-band EQ, insert effects,
  bus routing.
- **Chop and slice.** Auto-chop by transients or equal parts onto pads; a
  chopper instrument (one slice per key).
- **Stretch.** Lock a sample to N beats at the song tempo (Signalsmith or
  repitch).
- **Wave editor.** Cut, copy, paste, crop, fades, normalize, mono, trim
  silence, reverse, bounce a region to a pad. Undoable: edits write new
  files in `samples/`, so undo switches back.
- **Sequencer.** 32 sequence slots up to 64 bars; live recording with
  overdub; quantize (1/4 to 1/64, triplets, live quantize) and swing;
  metronome; grid and piano-roll editing with pen, snap, copy and paste;
  per-note velocity and probability; automation lanes.
- **Performance.** Keyboard mode with scales and chords, note repeat,
  arpeggiator, velocity mode; 16 performance FX with HOLD.
- **MIDI.** Pads from a MIDI controller with MIDI learn; import `.mid`
  onto pads; MIDI out per pad.
- **Song.** The slot chain: auto-advance, switching snapped to a beat, a
  bar or the sequence end; merging sequences by drag.
- **Export and save.** Mixdown, stems, resample to pad; save, save as,
  autosave, recent projects.

## Engine work this needs (in `f_engine`, tested as usual)

- A pad voice node, or `fire:sampler` extended: ping-pong and crossfade
  loops, reverse, attack/release, gate, choke groups across pads.
- Transient detection (for auto-chop).
- Sequence playback features: swing, per-note probability, note repeat and
  arpeggiator.
- Performance effects not yet in `fire:dsp`: stutter, cutter, bit-crusher,
  ring modulator, comb filter, pitch shifter.
- Offline stretch to a file; stem rendering.

## Milestones

Each milestone is a cycle: build, test (headless where possible, on all
four platforms), verify, profile, document, commit.

1. **Toolchain.** Scripts that fetch pinned sources and build static SDL3 and
   ImGui per platform; vendored odin-imgui and Open Sans with licences; one
   `app` build script producing a single binary; cloud machine setup.
   A window that clears the screen and shows ImGui's demo, on macOS,
   Linux, Windows and the Pi target.
2. **`app:core`.** Events, commands and history, state and serialization,
   engine host and reconciler, jobs. Headless tests.
3. **`app:ui`.** Platform loop, theme (dark and light, Open Sans), widget
   library, panels, shortcuts. A widget gallery to review the style.
4. **Pads: samples.** Project model, pads and banks, import and record,
   pad editing, the pad voice engine work, chop, stretch, wave editor.
   *Done:* see docs/guides/pads.md.
5. **Pads: sequencer and performance.** Slots, recording, grid and piano
   roll, probability, automation, keyboard and note repeat and arpeggiator,
   MIDI in and out and import.
6. **Pads: mixer and FX.** Inserts, buses, main, performance FX, CLAP
   plug-ins in slots.
7. **Pads: song, export, save.** Slot chain, mixdown and stems and
   resample, project folders, autosave.
8. **Later.** The timeline arranger, stem splitting, more export formats.

## Testing approach

- `app:core` is tested headless like the engine (commands round-trip
  through undo and redo; serialization round-trips; the reconciler leaves
  the engine graph equal to one built directly).
- UI logic is tested by driving ImGui frames without a GPU (input events
  in, commands out). Rendering tests (screenshots) run on the Mac, where a
  GPU is available; the cloud machines skip them.
- Profiling: UI frame time and allocations per frame; audio load of a full
  Pads project on the Mac and on ARM.
