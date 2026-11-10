---
title: Pads
description: The Pads sampler built on the application layer — loading, playing and shaping samples on 128 pads, chopping, stretching and editing them, and driving and testing it from scripts.
---

Pads (`apps/pads`) is a sampler and sequencer built on Fire Engine and its
[application layer](/guides/app-layer/). It is one binary: SDL3 and Dear
ImGui are linked in. This page covers what it does so far : samples, the
sequencer, playing live, the mixer, the song, export and projects, and
the layout, mixer strips and browser that followed (milestones 4 to 10 of
`app/PLAN.md`). The timeline arranger, stem
splitting and more export formats are for later.

```bash
task deps        # once per machine: the static SDL3 and ImGui libraries
task app:run     # build (optimized) and run
task app:pads OPT=none   # a debug build in .build/app/pads
```

| Option | |
|---|---|
| `--project DIR` | a project folder: opens the project in it, or starts one there (default: a new one in the temporary folder) |
| `--fake` | the simulated audio driver: no sound card needed |
| `--drive FILE` | run from a [drive script](#scripts-and-tests) |
| `--out DIR` | where a script's screenshots go (default `.build/app/shots`) |
| `--headless` | no window on screen |
| `--control PORT` | take commands live from a test harness on 127.0.0.1:PORT (0: any free port, printed) |
| `--prefs DIR` | where preferences go: recent projects, the browser's favourites (default: the system's place for them) |
| `--profile N` | draw N frames flat out and print the CPU time per frame (after `--drive`'s script, if given) |

With `--fake`, the simulated device runs on the UI thread as frames go by,
so everything plays (and scripts play the same way every run) without a
sound card. Without it, Pads opens the default output and every MIDI input
port.

## The window

The **transport toolbar** runs across the top, under the menus, whatever
panel or tab is in front (see [The transport](#the-transport)). Below it
the layout follows Ableton Live's: the **Browser** down the left; the
**Sequence**, **Song**, **Mixer** and **Perform** as tabs in the middle;
and along the bottom, the device view (as Ableton's): across its top,
where a panel's tab would be, a tab for each device of a track; below,
the pad grid on the left (always there, to pick another pad), the device
in front, and at the far right the track's channel strip (a pad's is the
mixer's without its EQ, inserts and sends: output, pan, fader, meter,
mute and solo). The bottom panel stays where it is (it has no tab of its
own to drag). A pad is a sampler device: its chain starts with **A1 kick
· Sampler** (with its own tabs:
**Sample**, **Env**, **Filter**, **Pitch**, **LFO**, **Global**; an audio
pad's is **· Audio**), its **EQ**, then each insert with an effect, and
**+** to put an effect in the next empty insert. Click an effect slot
anywhere (a strip's insert, a bus's slot, a performance effect's Edit) and
the panel shows that track's chain with that effect in front: a bus shows
its slots, a performance effect itself. Click a pad to show its chain
again. Right-click an effect's tab for its commands. Drag the divider between the grid and the tabs to give
either more room (double-click it to go back to a square grid). Panels
are tabs that can be dragged elsewhere; **View > Reset Layout** puts
them back.

Buttons that are only an icon (play, record, the sample edits) have no
frame: the icon is dimmed at rest, brightens under the mouse, and takes
a colour when on — green while playing, red while recording, the accent
for other toggles.

- **Browser** (left): for finding sounds fast.
  - **Tabs** are favourite folders. A new install has **Documents** and
    **Project** (the open project's samples). The **+** tab, or the
    star, adds the folder shown; right-click a folder for **Add to
    favourites**; right-click a tab to rename it, move it or remove it.
    Favourites are kept with your preferences, not in the project.
  - **Back**, **forward** and **up** (Backspace), and the folder's path:
    click any part to go there. **Refresh** reads the folders again.
  - The **tree**: click a folder to open it in place (its icon shows it open),
    double-click to go into it. Links to folders work. Only audio files
    (WAV, AIFF, FLAC, MP3, Ogg) and folders show.
  - **Search** finds file names (any case) in every folder under the one
    shown, on a background thread; the results list the path under it.
  - Click a file to select it, double-click (or Enter) to put it on the
    selected pad, or drag it onto a pad. With the list focused, the arrow
    keys move up and down (and preview what they land on); Right and
    Left open and close a folder.
  - The **preview**, at the bottom: the file's waveform with a playhead;
    play/stop (the icon turns to a stop while it plays); **auto-play**
    (on at first: selecting a file plays it); **sync** (while the
    sequencer plays, a loop of about 1, 2, 4… 64 beats is stretched to
    the project's tempo, pitch unchanged, and shows its beats; one-shots
    play as they are); and the preview's own volume. It plays straight to
    the output, past the mixer and main's effects, and never into an
    export.
- **Pads** (bottom left): 128 pads in 8 banks (A–H) of 16, numbered from
  the bottom left (pad 1) up, as on an MPC. Click a pad, or
  press its key, to play it and select it. The keys sit as the pads do:
  `Z X C V` is the bottom row (pads 1–4), then `A S D F`, `Q W E R`, and
  `1 2 3 4` the top (pads 13–16). Each pad shows:
  - its sample's name at the top, centred (cut off at the pad's edge);
  - its note in the middle: pad N is MIDI note N−1, so A1 is `C-2 · 0`
    and H16 is `G8 · 127` (what a MIDI controller plays it with);
  - **M**ute (bottom left) and **S**olo (bottom right): the same switches
    as its mixer strip's;
  - behind them, the sound's waveform (the region it plays); **View > Pad
    Waveforms** turns these off.

  Right-click a pad for its colour: 24 swatches and a picker (also behind
  the colour button in the Global tab). The colour shows on the pad, its
  mixer strip and its row in the sequencer. Hovering a pad tells its key
  and mode. Files dropped on the window from the desktop, or from the
  browser, land on the pad under the mouse.
- **The device tabs** show what each setting does to the sound as it
  plays: plots on black, with the newest note's place on them.
  - **Env**: the amp envelope as a curve: drag the attack's peak, the
    decay's end (up and down: the sustain) and the release's end; knobs
    under it. A dot rides the curve while a note sounds.
  - **Filter**: off, low-pass, high-pass, band-pass or notch (each button
    shows its curve), 12 or 24 dB. The response plot shows the setting
    faintly and, brightly, the filter as it is now — its envelope, the
    velocity, key tracking, LFOs and automation all move it. Drag its
    handle sideways for the cutoff and up for resonance (Shift: fine).
    Beside it the filter's own envelope (drawn as deep as its amount);
    knobs for cutoff, resonance, key tracking, velocity, the envelope's
    amount and its A, D, S, R.
  - **Pitch**: the pitch envelope (upside down for a negative amount),
    how many semitones it has the newest note at now, and knobs for its
    amount, velocity to pitch, key tracking and A, D, S, R.
  - **LFO**: two, side by side: a shape (sine, triangle, saw up and down,
    square, sample & hold), **Auto** (free-running), **Trigger** (each
    note starts it again) or **Sync** (to the beat: 4 bars to 1/16T), its
    rate, fade-in and phase. Its trace scrolls by live over its shape.
    Each sends to up to three destinations (volume, pan, pitch, cutoff,
    resonance) with an amount each — routes the engine keeps in a table
    that will grow into a full modulation matrix.
  - **EQ** (a device of the chain): the pad's three bands. Each effect
    is a device after it (its settings, on/off, remove), with a picture
    of what it does over its knobs: a filter's response (drag it: the
    cutoff sideways, resonance up; a held performance filter's curve
    follows the press), a compressor's, gate's or limiter's curve with
    a meter of how far it turns down now, saturation's curve, a
    bit-crusher's steps over a clean sine, a delay's echoes after a hit
    (ping-pong in two colours, on the beat grid) beside its tone — the
    low and high cuts in its feedback (each echo through them again, the
    fainter lines) over the live spectrum of what it puts out; synced,
    its time is a note value (1/64 to 2 bars, dotted and triplets); a reverb's decay (its
    highs dimmer), a comb's teeth, a chorus's, flanger's or phaser's sweep
    with where it is now, a ring mod's carrier, a pitch shift's
    semitones, a cutter's or stutter's slices over a bar with the
    playhead. Filters and the comb show the live spectrum of what they
    put out behind their curve too. A device's knobs spread evenly
    across its width; frequency knobs turn in ratios.
  - **Global**: sampler or audio track, name and colour (click it for the
    swatches and picker), choke group (a pad cuts the others in its
    group), volume, pan, transpose, fine tune, how many notes it plays at
    once, Clear Pad. An audio pad shows only Sample, Effects and Global.
- **Sample** (bottom tab): how the pad plays — **One-shot** to the end,
  **Gate** while held, **Loop** loops while held, **Hold** loops until hit
  again; reverse; a loop's direction and crossfade — over the waveform,
  on black. Drag **S** and **E** (by
  their tags or their lines) to set the region the pad plays, **L** for the
  loop; drag the squares under the tags in from the region's ends to fade
  it in and out (a ramp shows each fade; the fades are the pad's, so the
  file is left alone); drag across the wave to select. While the pad
  plays, a white playhead runs through the wave. The
  toolbar (it wraps when narrow):
  - edits — crop, delete, silence, fade in and out, normalize, reverse,
    trim silence, and put the selection on the next empty pad. Edits write
    a new file into the project and leave the original alone, so they undo;
  - **Chop** — at the transients (with a sensitivity) or into equal parts,
    onto consecutive pads, each playing its slice of the same file;
  - **Stretch to beats** — time-stretch the region to N beats at the
    project tempo, pitch unchanged;
  - record (the circle) — record the audio input onto the pad.

- **Sequence** (middle tab): the sequencer, editing the sequence the
  toolbar picks. Its name (double-click it, press F2, or right-click it
  or its entry in the toolbar's list to rename it); **Duplicate** (Cmd+D:
  into the next empty sequence, named "… copy", with its audio takes);
  **Own tempo** (it plays at its own tempo, which takes over exactly where
  the sequence does, in the song or switching live); **Copy Bars to…**
  (from its menu or the palette: bars, every pad or one or a bank, into
  another sequence at a bar, replacing or laid over). Shift-drag in the
  rows to mark a part (whole bars when long), Cmd+C to copy it, and Cmd+V
  to paste it into any sequence, at its marked part or its first bar.
  Its length (1–64 bars, ×2 doubles with the notes); the
  grid (1/4 to 1/64, triplets) and Quantize (Cmd+U, the notes there);
  swing (on 1/8 or 1/16). Below, the current bank's pads (pad
  1 at the bottom, as on the grid) as
  rows: click to add a note, drag to move, drag its end to resize,
  right-click to delete; the wheel scrolls the rows when they don't all
  fit. Notes of one pad (and pitch) never overlap: a note cuts short the
  one before it, replaces one that starts with it, and takes over one it
  covers (a note it reaches into keeps the part after it), however it got
  there (drawn, moved, pasted, recorded, imported). Under the rows, a lane: each note's velocity, its chance (the
  probability it plays each time round), or the selected pad's
  automation (volume, pitch or an EQ band; click to add a point, drag,
  right-click to delete). Recording overdubs: hit pads (mouse, keys or
  MIDI) while it plays, and each pass is one undo step. Pads light when
  the sequencer plays them.
- **Perform** (a panel beside the Mixer): at its top, the **launcher**:
  every sequence in use as a cell (its name, bars, its own tempo). Click
  one to launch it — stopped, it starts playing; playing, it takes over
  **at once**, on the **next beat**, the **next bar** or at the **sequence
  end** (chosen beside it, as in the Song tab). The playing cell runs a
  bar across; a queued one pulses with the beat and counts down; Shift-
  click only shows a sequence; **+ New** goes to the next empty one;
  right-click a cell for the sequence's commands. A sequence's own tempo
  takes over where it does. Below, how the pads play — **Pads**, each its
  own sound; **Keyboard**, the 16 pads are a scale (or diatonic chords:
  triads, sevenths, power chords) on the selected pad, from any root and
  octave, the bottom-left pad the root; **Velocity**, the selected pad at
  16 velocities. Under note repeat and the arpeggiator, a bar of their steps lights the one playing (bright while it is on). **Note repeat** retriggers held pads on the grid;
  the **arpeggiator** walks held notes (up, down, up-down, random, as
  played; 1–4 octaves; gate; latch). MIDI: activity lights, **Learn**
  (the next note you play plays the selected pad), and **MIDI out** (the
  pad's hits also go out as a note on a channel).
- **Mixer** (middle tab): a channel strip, as in Logic, for every pad
  with a sound (all banks; it scrolls sideways), then buses A–D and main
  pinned on the right. From the top:
  - the pad's **EQ** curve (click it for the Effects tab, where the EQ is);
  - its two **inserts** (a bus and main have five slots);
  - its four **sends**, one per bus: drag a send up and down for its
    level (Shift for fine), double-click to turn it on at 0 dB or off,
    right-click for **Pre-fader** (it then ignores the fader, and shows
    `pre`, its knob in yellow). A muted pad sends nothing;
  - its **output**: Main or a bus (click to choose);
  - **pan** (drag; double-click centres);
  - two readouts: the fader's level, and the loudest peak since you last
    clicked it (red above 0 dB);
  - the **fader** (Logic's taper: finer near 0 dB; double-click for 0 dB)
    beside the stereo meter and its dB scale;
  - **M**ute and **S**olo, and the name on the pad's colour (click to
    select the pad).

  Click a slot to edit it in the **Effects** tab: what it holds
  (filters, dynamics, saturation, bit-crusher, delay, reverb, chorus,
  flanger, phaser, ring mod, comb, pitch shift, cutter, stutter, or a CLAP
  plug-in), on or off (a 15 ms fade), and a knob for each setting. A
  plug-in that can't be found plays nothing and says so. A pad's volume
  is its fader, after its inserts; the volume lane of a sequence moves it.
- **Performance effects** (in the Perform panel): 16 effects on main, each
  on while its pad is held — filter sweeps, stutters at 1/8 to 1/32,
  cutters, bit-crusher, ring mod, pitch up and down, delay, reverb,
  distortion. **Hold** latches them. Where you press is how hard it plays
  (slide while held): the top is all of it — filters sweep further,
  stutters and cutters go faster, pitch shifts go further, the rest blend
  in more. Each pad fills to how hard it plays and marks its own
  intensity (the **Intensity** knob in the Effects tab, when the press
  doesn't say). Right-click one to edit it.
- **File > Import MIDI File…** reads a `.mid` into the current sequence:
  as General MIDI drums: key 36 (the kick) onto A1, 37 onto A2, and on.
  (`import_midi` in the model can also go by the MIDI map, where key N is
  pad N, or put every note on one pad, pitched.)

Every change is undoable (Cmd+Z / Cmd+Shift+Z; Ctrl elsewhere). A knob
drag is one step. Cmd+K opens the command palette; Cmd+1..8 switch banks (or View > Bank);
Delete clears the pad; View > Light Theme switches theme.

- **Song** (middle tab): **Pattern** plays the current sequence; **Song**
  plays the chain of steps below, each a sequence played 1–16 times
  (drag a step onto another to move it; with the toolbar's **Loop** on it
  goes round, otherwise it stops at the end). On the right, the
  **sequences** in use, each with its length, own tempo and how many times
  the song plays it (the playing one lit): double-click one or its **+** to
  add it at the end, drag it onto a step to put it before that one or
  onto the **+** at the end, click it to edit it, right-click for its
  commands. **Add** (the current sequence's name) puts the current one at
  the end; **Merge into this…** lays another sequence's notes and
  automation over the current one. In pattern mode, a sequence picked
  while playing takes over **at the end of the playing sequence**, **at
  the next bar**, **at the next beat** or **at once** — exactly there; the
  Sequence panel shows what comes next and when.

## Commands and right-click menus

Everything you can do to something is a command in one list
(apps/pads/commands.odin): what it applies to (a pad, a note, the marked
part of the piano roll, a sequence, a song step, an effect slot, a bus,
a file, an automation point, an audio take), its icon and shortcut. The
menus are made from it, so right-click anything for what applies:

- **a pad** (on the grid, or its strip's name): play, select, edit its
  sound, mute, solo, arm, make it an audio track, copy, paste,
  duplicate to the next empty pad, clear, its colour;
- **a note**: delete, duplicate after itself, velocity 100/70/40%, chance
  50%; **the marked part**: copy, paste, duplicate after, delete;
- **a sequence** (its name, or its entry in the toolbar's list): edit,
  rename, duplicate, copy bars, double, add to the song, own tempo, clear;
- **a song step**: edit its sequence, repeat once more or less,
  duplicate, remove;
- **an effect slot** (an insert, a bus slot, a performance effect):
  edit, on, copy, paste, remove; **a bus**: mute, solo, reset;
- **a file** in the browser: load onto the selected pad or the next empty
  one, preview; **an automation point**: delete; **a take**: clear;
- **a knob**: reset to its default, or type a value.

The palette (Cmd+K) lists the selection's commands as well ("Pad:
Duplicate to Next Empty Pad" acts on the selected pad, "Sequence: …" on
the current one), and drive scripts (and later control surfaces) run any
command by its id: `command pad.mute pad 3`.

## Audio pads

A pad is a **sampler** (it plays its sample when hit) or an **audio
track**: switch it with **Sampler | Audio** at the top of the Global tab.
An audio pad is a pad like any other: it has a strip in the mixer, its
EQ, inserts, sends, mute and solo, and a row in the sequence. What it
plays is a **take** per sequence:

- In the Global tab pick its **input** (inputs 1 + 2, or input 1 or 2 alone,
  on both sides), **Arm** it (or click **R** on its strip; its pad reads
  *armed*), and turn **Monitor** on to hear the input through its strip
  while armed (use headphones).
- Press **Record** (Cmd+R). After the count-in, if one is set, the input
  is recorded while the sequence plays; when you stop, the take is folded
  into the current sequence's take for that pad, exactly one sequence
  long: every frame lands where it was played, over what was there, so of
  several passes the last is heard (and a short punch replaces only what
  it covers). One undo step, **Record Audio**.
- The take loops with its sequence and follows the tempo (it plays faster
  or slower). Each sequence has its own: pick another sequence, or let
  the song move on, and the pad plays that sequence's take, switching
  exactly where the sequences change.
- The Sample tab shows the current sequence's take with a playhead;
  **Clear Take** empties it (Clear Pad empties every sequence's).

Audio is recorded in pattern mode (not while the song plays). A project
from before audio pads opens with every pad a sampler.

## The transport

The toolbar under the menus, centred, always showing. Its buttons are
icons whose colour shows their state.

- **Play** (green while playing) and **Stop**, or Space for both.
  **Record** (red; Cmd+R) arms recording: from a stop it plays, after the
  count-in.
- **Loop**: on, a sequence (or the song) goes round; off, it plays once
  and stops. **Count-in** (the timer; click for off, 1 bar, 2 bars):
  bars of click before recording starts, with nothing played or recorded
  until the top (the position shows them as bar 0, in yellow).
- The **position**: bar . beat . sixteenth of the sequence playing.
- The **sequence**: pick one of the 32 (those with notes are marked), or
  step with the arrows.
- **Tempo**: drag it (right or up) to change it by 1 BPM, with **Shift**
  by 0.1; scroll it; double-click to type it. **Tap** in time to set it: it
  flashes with each tap, and the fourth starts playback a beat later,
  where a fifth tap would land, flashing on the beats until then (playing,
  taps only change the tempo; a pause of 2 s starts again). The **time signature** (4/4, 3/4, 6/8... or
  any beats and unit) sets a bar's length: sequences' bars, the grid's
  bars, the metronome's accent, exports.
- The **metronome**: on/off, and (the arrow) its level, **Only while
  recording** (and counting in), and the count-in.
- **Play modes** (at the toolbar's right): the pads as pads, as a
  keyboard of the selected pad, or as it at 16 velocities — as in the
  Perform panel.
- **Input quantize** (the magnet): on, recorded notes move toward the
  grid shown beside it; the arrow sets the grid (1/4–1/64, triplets), the
  **strength** (100%: onto the grid; 50%: half way) and **swing** (the
  grid's off-beats pushed later).

These settings are saved with the project.

## Projects

A project is a folder, `Name.pads`: `project.fire` (a
[fire:session](/guides/sessions/) file whose app chunks hold the pads,
samples, sequences, song, mixer, MIDI map and settings) and `samples/`
(every imported, recorded, edited, chopped or resampled file is copied
there), so a project moves as one folder.

Projects saved before there were 128 pads open with their 64 pads in
banks A–D, and keep their own MIDI map (where key 36 played A1).

- **File > New** (Cmd+N), **Open…** (Cmd+O, a folder), **Open Recent**
  (the last 8, kept in the user's preferences folder), **Save** (Cmd+S),
  **Save As…** (Cmd+Shift+S: a folder; the samples are copied there).
- Changes are saved on their own every minute, and on quitting. The
  window's title shows the project, with a dot while it has unsaved
  changes. Opening a project starts a new undo history.
- A new project lives in the temporary folder until **Save As** gives it a
  place.

## Export

**File > Export Audio…** (Cmd+E): the current sequence (once) or the song;
a mixdown, or stems — a file per pad with a sound, or per bus (and main,
for the pads that go straight there); 16-bit (dithered), 24-bit or 32-bit
float WAV; 44.1, 48 or 96 kHz (resampled from the engine's rate with
`dsp.Resampler` at High quality); and a tail for reverb and echoes. It
renders offline through the same engine (the device closes meanwhile),
a slice each frame, with a progress bar. **File > Resample Sequence to
Pad** renders the current sequence once into a new sample on the next
empty pad (one undo step).

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
- The mixer (model/mixer.odin, mixer_engine.odin): each pad's EQ goes
  through its inserts (each effect in a `dsp.Wet`, so on/off never
  clicks), a gain for mute and solo, and a `dsp.Meter`, into its bus or
  main; a bus is a summing gain, its five slots, a fader, a `dsp.Pan` and
  a meter, into main; main is the same with the 16 performance effects
  after its slots, then OUTPUT. Changing what a slot holds makes a new
  node and wires its chain again; changing a setting is a parameter
  change. Slots and buses are plain values in the project, so every edit
  undoes.
- What plays is a plan (model/song.odin): segments of sequences on a
  timeline that runs on (it never loops), built into one clip and placed
  where it started — a sequence looping; one sequence until the switch
  point, then the next looping; the whole song. So switching is exact to
  the frame, and export plays the same plan once.
- Saving writes each field of the model explicitly (project_file.odin),
  versioned, so later versions can read older projects. Loading builds a
  new model and engine from the file.
- Export (export.odin) mutes all but a stem's pads in the mixer while it
  renders that stem, writes through `fire:audiofile`, and gives the
  device back when it ends.
- The router (model/router.odin) is the pipeline every note takes: UI hits
  and MIDI notes (by the MIDI map) are live notes; live notes go through
  the arpeggiator or note repeat (`fire:perform`) when one is on; then
  choke groups, Hold, Gate, keyboard notes (each its own voice, tuned),
  and MIDI out. It reports live notes back to the UI with the sequencer's
  position, for recording and MIDI learn.
- `apps/pads/*.odin` is the UI: one file per panel, the actions and menus
  in `shell.odin`.

Costs (Apple M-series, optimized): 0.35 ms of CPU per frame with a bank
loaded, the sequencer playing and the mixer showing (p99 1.1 ms); the
engine, with 8 pads in a busy sequence, automation, the arpeggiator, an
insert on every pad and reverb and a compressor on main, 19× real time
(5% of one core); on 30 s of audio, import 3 ms, chop at transients 76 ms, normalize
8 ms, stretch 87 ms; saving a project 1 ms, opening it 12 ms.

## Scripts and tests

Pads adds these commands to [drive scripts](/guides/app-layer/#driving-the-ui-from-a-script):

```text
load N PATH          load a file onto pad N (0..63)
hit N / release N    play pad N / let it go
select N / bank N    select a pad / show a bank (0..3)
browse DIR           show DIR in the browser (onto its back list)
browser up|back|forward|refresh|fav   (fav: the folder shown becomes a tab)
browser open|toggle|select REL        a folder or file under the one shown; tab N
search QUERY         search under the folder shown ("search" alone stops)
preview play|stop | auto on|off | sync on|off | volume DB
expect root NAME / expect rows K / expect results K / expect previewing 0|1
expect favorites K / expect selected_file NAME
state                the app's state as one line of JSON (what tests/e2e reads)
crash segv|assert|bounds   crash on purpose (the crash reporter's test)
set N FIELD VALUE    volume, pan, pitch, mode (0..3), choke, reverse (0/1)
chop N equal K       (or: chop N transients SENSITIVITY)
theme light|dark     action ID (an action from the palette: undo, bank_b...)
command ID KIND [I [S]]   a command on something: pad I, note I of sequence S, sequence I,
                     song_step I, bus I, file PATH, take I (command pad.duplicate pad 0)
expect pad N FIELD VALUE   sample, name, volume, pan, pitch, mode, start, end, choke
expect samples K / expect undo NAME / expect selected N / expect bank N / expect dark 0|1
panel ID             bring a panel (browser, sequence, song, mixer, perform, pads) or a pad tab (sample, env, filter, pitch, lfo, effects, global) to the front
play / stop / rec on|off / metronome on|off   (rec only arms; the toolbar's Record also plays, counting in)
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
insert PAD SLOT KIND / busfx BUS SLOT KIND / perf_fx N KIND   (BUS 4 = main; KIND: lowpass, reverb, ring...)
plugin BUS SLOT ID PATH                      a CLAP plug-in in a bus slot
edit_fx pad P S | bus B S | perf N           the slot the Effects tab edits
fx_param ID VALUE                            one of its settings
send PAD BUS DB [pre|post]   a pad's send to bus BUS (1..4; -60 dB is off)
route PAD BUS / busvol BUS DB / mute pad N | bus B / solo ... / perf N on|off
expect level main | bus B | pad N above|below DB   (the meter as shown)
expect fx KIND                               what the edited slot holds
save / save_as DIR / open DIR / new          projects
export PATH [song] [stems pads|buses] [rate HZ] [bits 16|24|32] [tail S]
resample / export_dialog [off]               resample to a pad; the Export dialog
song add SLOT [REPEATS] | mode on|off | loop on|off | clear
switch end|bar|beat|now                      when a sequence picked while playing takes over
expect file PATH / expect song K / expect dirty 0|1 / expect pads_loaded K
```

A failed `expect` makes Pads exit 1. `tests/app_ui/drive/pads.txt` drives
the model by command and takes the layout screenshots (dark, light,
narrow); `pads_input.txt` uses only input events — keys, clicks, a knob
drag, shortcuts, the palette — and checks the model after each;
`pads_sequence.txt` covers the sequencer (by command, then by clicks,
Space and Cmd+R with the pad keys); `pads_perform.txt` the play modes,
repeat, the arpeggiator, MIDI in and learn, automation and MIDI import;
`pads_mixer.txt` the buses, sends, inserts, mute, meters and performance
effects; `pads_project.txt` switching on the grid, the song, save, new,
open, export and resample (into `.build/app/drive_project`);
`pads_browser.txt` the browser on `tests/app_ui/fixtures/library`: the
tree, clicks and arrow keys, back, forward and up, a favourite, search,
and the preview (auto-play, stop, sync). `task app:pads-drive` gives
each script an empty preferences folder (`--prefs .build/app/pads_prefs`),
so a script never sees or changes your favourites; do the same when you
run one by hand.

```bash
task app:test          # tests/app_* and tests/pads_*, the UI cases, then every pads*.txt script
task app:pads-drive    # just the scripts (debug build, fake driver, headless)
.build/app/pads --fake --headless --drive tests/app_ui/drive/pads.txt --out .build/app/pads_shots
.build/app/pads --fake --headless --prefs .build/app/my_prefs --drive tests/app_ui/drive/pads_browser.txt --out .build/app/pads_shots
.build/app/pads --fake --headless --profile 600 --drive tests/app_ui/drive/profile_loaded.txt
```

The fixtures (samples, the `library/` folders and `beat.mid`) are made by
`tests/app_ui/fixtures/make.py`.

## End-to-end tests and live control

`tests/e2e` uses Pads as a person does, by mouse and keyboard, over its
control socket (`--control`), and checks the app's state after each step;
a crash fails the test with the app's crash report (the cause, the last
command, a back trace). Each test gets a fresh Pads with its own
preferences and project. On the Mac a window opens (watch it); elsewhere,
and with `HEADLESS=1`, it runs headless.

```bash
task deps                              # once: also puts pytest in .deps/venv
task app:e2e                           # the suite (a window on the Mac)
task app:e2e HEADLESS=1                # headless (what task app:test runs)
task app:e2e -- -k browser -x          # some tests; stop at the first failure
.deps/venv/bin/python -m pytest tests/e2e -q   # the same, by hand (after task app:pads OPT=none)
```

| File | What it uses |
|---|---|
| `test_browser.py` | the tree (click, double-click), back/forward/up and the path, keys, favourites (star, pills, right-click), search, the preview's buttons, dragging files and search results onto pads |
| `test_pads.py` | pads by mouse and keys, banks, playback (modes, Reverse) and the Global tab (knobs, Clear Pad, undo), the Sample tab (edits, chop, stretch), files dropped from the desktop |
| `test_audio.py` | a pad made an audio track (input, monitor, undo), arming (Global tab and the strip's R), recording a take from the fake device's input, Clear Take |
| `test_devices.py` | the bottom panel as a device view: a pad's chain (sampler, EQ, inserts added with +), a bus's chain from the mixer, a performance effect, a pad chosen again |
| `test_fx_views.py` | effect pictures: a filter's response dragged, the dynamics' curve and gain reduction meter, delay, reverb, comb, chorus, cutter, pitch, bit-crusher |
| `test_device.py` | the device tabs: the amp envelope's handles, the filter's type, slope and response handle (and the live cutoff above the setting while its envelope opens it), the pitch envelope, an LFO routed to the cutoff, Global, an audio pad's tabs |
| `test_sample.py` | the Sample tab's wave: S and E dragged by their tags, the fade handles (and undo), the playhead while it plays, the bottom panel's channel strip |
| `test_commands.py` | the menus made from the command list (a pad's, a note's, a song step's, an effect slot's, a bus's, a knob's), the palette on the selection, commands by id |
| `test_song_side.py` | the Song tab's sidebar: double-click and + to add, dragging onto a step and onto the end, click to edit, right-click, undo |
| `test_sequences.py` | renaming (double-click, F2, undo), Duplicate (menu, Cmd+D), own tempo, the Copy Bars dialog, a marked part copied and pasted |
| `test_sequencer.py` | play/stop and Space, the metronome, notes by clicking the piano roll (and right-click, undo), ×2 and clear, recording from the pad keys, the lanes |
| `test_live.py` | the launcher (launch when stopped, queue to the sequence end, the cell's menu), performance effects as hard as pressed and their Intensity knob, the toolbar's play modes |
| `test_mixer.py` | a strip per pad with a sound, faders, mute/solo, pan, sends (drag, double-click, pre-fader), outputs, inserts, the EQ display, the peak readout |
| `test_perform_song.py` | play modes, repeat, the arpeggiator, holding performance effects, the song chain and its switches |
| `test_app.py` | menus, undo/redo, the command palette and theme, panels and Reset Layout, the export dialog, save/new/open and export |
| `test_crawl.py` | a hunt for crashes: every item showing in each panel and tab clicked (left and right), and a browser file dragged onto every kind of target |
| `test_harness.py` | the harness: crashes are reported, a missing item is an error |

A test reads like what a person does:

```python
def test_dragging_a_sample_onto_a_pad_loads_it(app, library):
    app.browse(library)
    app.click("Drums", window="browser")
    app.click("Kicks", window="browser")
    app.drag("Kick 808.wav", "pad A1", from_window="browser")
    assert app.pad(0)["name"] == "Kick 808"
```

`app` (tests/e2e/pads.py) has `click`, `drag`, `drag_by`, `key`, `type`,
`panel`, `expect_item`, `items`, `state` (the app's state: pads, mixer,
browser, preview, sequencer, toasts), `until` and `screenshot`; `cmd`
runs any drive command. A failing test keeps a screenshot in
`.build/app/e2e/<test>/failure.png`. The names items go by: pads are
`pad A1`; mixer parts are `A1 fader`, `A1 send B`, `A1 slot 1`, `A1
output`, `Bus A mute`, `Main fader`; favourite pills `tab Documents`;
performance effects `fx 1`; song steps `song step 1`; browser rows their
names; icon buttons their tooltips; combos their ids (`##arp_mode`).
`items` (or `task app:ctl -- items`) lists what shows.

### Driving it live

`task app:ctl` starts Pads under remote control and runs the commands you
type, printing each answer — or the crash report if it dies:

```bash
task app:ctl
browse tests/app_ui/fixtures/library
click_item Drums in browser
drag_item "Closed Hat.wav" in browser to "pad A2"
state
```

```bash
task app:ctl -- --headless 'click_item "  Mixer"' 'items fader'   # some commands, then quit
.deps/venv/bin/python tests/e2e/ctl.py --keep 'load 0 tests/app_ui/fixtures/kick.wav'   # then type more
```

`crash segv|assert|bounds` crashes on purpose (to see a report).
