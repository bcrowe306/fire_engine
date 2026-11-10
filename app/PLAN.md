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
   MIDI in and out and import. *Done:* see docs/guides/pads.md.
6. **Pads: mixer and FX.** Inserts, buses, main, performance FX, CLAP
   plug-ins in slots. *Done:* see docs/guides/pads.md.
7. **Pads: song, export, save.** Slot chain, mixdown and stems and
   resample, project folders, autosave. *Done:* see docs/guides/pads.md.
8. **Pads: interface rework.**
   - *Icon buttons* become bare icons: no frame, the glyph centred in a
     square hit area, with its colour showing the state. Idle is dimmed
     text, hover is full text, on is the accent. Some icons have their own
     colour: play is green while playing, record red while armed. Disabled
     icons are faint. Tooltips stay. Every `ui.icon_button` caller moves to
     the new widget, and the gallery gets a case for it.
   - *Layout, as in Ableton:*
     - The browser is in the left sidebar.
     - The centre holds Sequence, Song and Mixer as tabs.
     - The bottom panel holds the pad grid and bank switch on the left, at
       a fixed width with a divider. The selected pad is on the right, in
       tabs: Sample, Pad, Effects and Perform.
     - There is no right sidebar.
     - The layout gets a version number, so an older saved `imgui.ini`
       falls back to the new default.
   - The drive scripts' `panel` command and the screenshots follow the new
     layout. *Done:* see docs/guides/pads.md.
9. **Pads: Logic-style mixer and sends.**
   - *Sends:* each pad gets a send to each of the 4 buses, set in dB and
     switchable between pre-fader and post-fader. The pad keeps its single
     output.
   - *Engine and project file:* the sends tap the pad's chain after its
     inserts, before or after the fader, into the bus inputs, and they are
     undoable. The project file goes to PPRJ v2; v1 files load with the
     sends off.
   - *Tests:* send levels, pre and post, mute and solo, block-size
     invariance and zero rt allocations.
   - *Strip, from top to bottom:*
     - an EQ thumbnail (the pad EQ's curve; a click opens it)
     - the insert slots
     - the send slots (bus name and a small knob)
     - the output picker
     - the pan knob
     - the fader and peak readouts in dB (a click on the peak resets it)
     - the fader beside a scaled meter
     - Mute and Solo
     - the name on the pad's colour
   - *Which strips:* every pad with a sound, in all banks, scrolling
     sideways. The buses and Main are pinned on the right, and the selected
     pad's strip is highlighted. *Done:* see docs/guides/pads.md.
10. **Pads: the browser.**
    - *Model:* the browser's model moves into `apps/pads/model`, so its
      tests run headless. It covers the tree, history, favourites and
      search. The bug behind today's broken navigation is found and gets a
      test.
    - *Favourites:* each favourite is a tab. A new install has Documents
      (the default) and the open project's samples folder. You can add a
      folder from the browser (star button, or right-click > Add to
      favourites), and rename, reorder or remove tabs. The tabs are saved
      with the user's preferences, not in the project.
    - *Navigation:*
      - a tree whose folders expand in place
      - back, forward and up buttons
      - a path whose parts you can click
      - Up and Down select (and preview); Right and Left expand and
        collapse; Enter loads the file onto the selected pad
      - dragging a file onto a pad still works
    - *Search:* a box that filters by file name through every folder under
      the tab. A background job scans the folders, with a cap, and is
      cancelled when the tab changes. Results are a flat list with
      relative paths.
    - *Preview:*
      - It has its own voice in the engine, which goes straight to the
        output, skipping the master effects.
      - Files are decoded on a background job, so the UI never waits.
      - Auto-play is on by default, with an icon that toggles it. A
        play/stop icon shows stop while a preview plays.
      - It has its own volume.
      - A tempo-sync toggle stretches a loop to the project tempo while
        the transport plays. The loop's length in beats is estimated from
        the file's length, and one-shots play raw.
      - The selected file's waveform shows in the preview strip.
    *Done:* see docs/guides/pads.md. (Search looks under the folder shown, not
    always the tab's: what you browsed to is what you search.)
11. **Pads: 128 pads and the pad's face.**
    - *128 pads* in 8 banks (A–H) of 16, numbered from the bottom left
      (pad 1) up, as on an MPC.
      - Cmd+1…8 switch banks.
      - The computer keys mirror the grid: Z X C V is the bottom row
        (pads 1–4), 1 2 3 4 the top (pads 13–16).
      - The sequencer's rows follow (pad 1 at the bottom, like a piano
        roll's low notes).
    - *Notes:* pad N answers to MIDI note N−1 (A1 = 0, H16 = 127).
      - The engine's own key per pad (now 36 + index, which would pass
        127) becomes the pad's note, routed so no two pads share one.
      - Projects saved with 64 pads load into banks A–D and keep their own
        MIDI map.
    - *Project file v3:* 128 pads, colours.
    - *The pad's face:*
      - the sample name at the top, centred and clipped to the pad
      - the note name and number in the middle (C-2 · 0)
      - Mute at the bottom left and Solo at the bottom right: the track's
        own mute and solo, the same as its mixer strip
      - behind them, the sample's waveform: on at first, with View > Pad
        Waveforms to turn it off
    - *Colours:*
      - Right-click a pad, or its colour in the Pad tab, for 24 swatches
        and a full colour picker.
      - The colour shows on the pad, its mixer strip and its sequencer row.
    - *Browser:* folders show their open or closed folder icon and no
      chevron.
    *Done:* see docs/guides/pads.md. (A MIDI file imports as General MIDI
    drums, key 36 onto A1, now that note N is pad N.)
12. **Pads: the transport toolbar.**
    - *Placement:* a bar under the menus, always visible whatever panel or
      tab shows, its controls centred. Its buttons are bare icons whose
      colour shows state.
    - *Transport:*
      - play, stop, record
      - loop on/off: off plays the sequence or song once and stops; this
        replaces the Song tab's toggle
      - count-in: off, 1 or 2 bars of click before recording
      - the position (bar.beat.tick, and the length)
      - the current sequence's number (pick one, or step with arrows)
    - *Tempo:*
      - Dragging changes it by 1 BPM; with Shift, by 0.1 (typing gives any
        value).
      - Tap tempo: the average of the last taps, reset after 2 s without
        one.
      - Time signature (beats per bar and beat unit) for the metronome,
        the grid, bars and exports.
    - *Metronome:* on/off, its volume, and "only while recording" (and
      during count-in).
    - *Input quantize:* the grid (1/4–1/64, triplets), a strength (0–100%:
      how far a recorded note moves toward the grid) and swing.
    - *The Sequence panel:* play, record and the metronome move from its
      toolbar to this one, and the BPM field leaves the Pads panel.
    - *Engine work:*
      - capture: quantize strength and swing
      - the metronome: its level, and only while recording
      - count-in: the clock runs a bar or two of click before the sequence
        starts and recording begins
      - loop off: the plan runs once
      - time signature: the meter on the clock; bars and grid lengths from
        it
    *Done:* see docs/guides/pads.md (The transport).
13. **Pads: tracks, and audio recorded into slots.**
    - *Tracks:* each of the 128 pads is a track with a kind, a device and
      a mixer channel (its strip).
      - A *Sampler* track (the default) plays its sample when hit, as now.
      - An *Audio* track plays the audio clip it holds for each sequence
        slot.
      - Synths and other devices come later. The track's device is what
        the bottom panel shows: a Sampler's Sample, Pad and Effects tabs,
        or an Audio track's clip.
    - *Recording audio:*
      - An audio track has a record-arm button, on its pad and its strip,
        and an input (in 1–2, 1, 2…).
      - Record, after the count-in, captures that input into the current
        sequence slot as an audio clip. The clip plays and loops with the
        sequence, follows the song, and goes into exports and stems.
      - A new take replaces the old, and undo brings it back.
      - Hitting an audio track's pad auditions its clip.
    - *The model:* Pad becomes Track (kind, device settings, channel);
      clips live in the project folder (samples/) like samples.
    - *Project file v4:* tracks and clips. v3 and older files load as
      Sampler tracks.
    - *Tests:* headless model tests (recording through the fake driver's
      input, playback timing, undo); e2e tests for arming, recording and
      the device panel.
14. **Later.** The timeline arranger, internal devices (synths, drum
    machines) on tracks, stem splitting, more export formats.

## Testing approach

- `app:core` is tested headless like the engine (commands round-trip
  through undo and redo; serialization round-trips; the reconciler leaves
  the engine graph equal to one built directly).
- UI logic is tested by driving ImGui frames without a GPU (input events
  in, commands out). Rendering tests (screenshots) run on the Mac, where a
  GPU is available; the cloud machines skip them.
- Profiling: UI frame time and allocations per frame; audio load of a full
  Pads project on the Mac and on ARM.
