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
    Beside it the filter's own envelope, the full height of its plot
    (upside down for a negative amount, faint at none). The filter's knobs
    (cutoff, resonance, key tracking, velocity, the envelope's amount)
    spread under the response, the envelope's A, D, S, R under it.
  - **Pitch**: the pitch envelope, full height (upside down for a negative
    amount, faint at none),
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
    swatches and picker), volume, pan, transpose, fine tune, how many notes it plays at
    once, Clear Pad. An audio pad shows only Sample, Effects and Global.
    A note past the voice count fades the oldest out over 3 ms, so taking
    over never clicks. The voice mode is **Poly**, **Mono** (one note at
    a time, each starting the sample again) or **Legato**: a note played
    over a held one slides the sounding voice to it without starting it
    again, and letting go slides back to the newest note still held. In
    mono and legato, **Glide** sets the slide's time. **Always** makes
    every note glide from the last, not only notes played over a held
    one. **By octave** makes the time an octave's, so wider leaps take
    longer. A slicer has no glide: its keys are its slices.
- **Sample** (bottom tab): how the pad plays — **One-shot** to the end,
  **Gate** while held, **Loop** loops while held, **Hold** loops until hit
  again; reverse; its **choke group** (a hit stops the others playing in
  its group: open and closed hi-hats; the pads show theirs as a badge,
  `C2`); a loop's direction and crossfade. Under that, **Warp**: on, the
  sample follows the tempo at its own pitch, made longer or shorter
  rather than played faster or slower. Pick how in its dropdown —
  **Beats** (cut at its hits, or on a 1/16, 1/8 or 1/4 grid of its own
  beats, each piece played as it was and moved to its new time: drums
  and loops, attacks exact; **Fill gaps** loops a piece's tail when
  slower instead of leaving silence), **Tones** (a spectral stretch of the
  whole: voices, bass, pads), **Complex** (the spectral stretch started
  again at each strong hit: full mixes, attacks kept crisp) or
  **Re-pitch** (faster or slower, the pitch with it). Its own tempo is
  guessed from its length (a whole number of beats; drag or type it, or
  the wand guesses again); its beats are drawn over the waveform (bars
  numbered). The warped sound is rendered in the background into the
  project's `warped/` folder, kept there for the next time, and played
  once ready (it shows "Rendering..." until then, the ratio after). All
  this over the waveform, on black. Drag **S** and **E** (by
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
    project tempo, pitch unchanged, as a new file (Warp does it without
    touching the sample);
  - record (the circle) — record the audio input onto the pad.

- **Sequence** (middle tab): the sequencer, editing the sequence the
  toolbar picks. Its name (double-click it, press F2, or right-click it
  or its entry in the toolbar's list to rename it); **Duplicate** (Cmd+D:
  into the next empty sequence, named "… copy", with its audio takes);
  **Own tempo** (it plays at its own tempo, which takes over exactly where
  the sequence does, in the song or switching live); **Copy Bars to…**
  (from its menu or the palette: bars, every pad or one or a bank, into
  another sequence at a bar, replacing or laid over). Its length (1–64 bars, ×2 doubles with the notes); the
  grid (1/4 to 1/64, triplets) and Quantize (Cmd+U, the notes there);
  swing (on 1/8 or 1/16). Below, the current bank's pads (pad
  1 at the bottom, as on the grid) as
  rows, edited with four tools (on the row over the editor, or the keys
  while it has the keyboard; Escape: back to Select):
  - **Select** (V): click a note (Shift-click adds or takes away), drag on
    empty space to box-select, drag selected notes to move them, their
    ends to resize them all, double-click empty space to add one;
  - **Draw** (B): click to add a note, drag along a row to paint one on
    each grid step (one undo step), click a note to remove it;
  - **Erase** (E): click or sweep across notes to remove them;
  - **Move** (M): drag the selection (Alt-drag copies it), in time and to
    other rows.
  With notes selected, Delete or Backspace (the Mac's delete key) removes
  them; **0** mutes them (they stay where they are, drawn hollow, and are
  not played; 0 again unmutes them); the arrows nudge them a grid step
  (Shift: a bar) or a row up or down; Cmd+D duplicates them after
  themselves, Cmd+C copies and Cmd+V pastes them (into any sequence; at
  the selection's bar, or where the grid's menu was opened). Cmd+A
  selects every note shown. Right-click a note for its commands and the
  selection's. Drop a sample from the browser on a row (its name or
  along it: the row lights) to load it onto that row's pad. Drag the bar
  between the grid and the lane below to make the lane taller or
  shorter.
  Click a row's name to select its pad (its strip and devices follow) and
  every note in its row, and to hear it (the **headphones** turn that
  off); right-click it for the pad's commands (**Rename…**, colour, mute,
  solo, its piano roll...). **Drums | Piano roll** switches to one pad's
  notes on a keyboard (its own pitch is the marked C3, four octaves each
  way; double-click a row's name to open it), where it plays
  chromatically. **Fold** shows only the rows that have notes (drums: the
  pads used, from every bank; piano roll: the pitches used). The wheel
  scrolls the rows when they don't all fit. Notes of one pad (and pitch) never overlap: a note cuts short the
  one before it, replaces one that starts with it, and takes over one it
  covers (a note it reaches into keeps the part after it), however it got
  there (drawn, moved, pasted, recorded, imported). Under the rows, a lane: each note's velocity, its chance (the
  probability it plays each time round), or the selected pad's
  automation (volume, pitch or an EQ band), one lane at a time. With
  **Select** a click adds a point and a drag moves one; with **Draw** a
  drag draws freehand (a point each grid step) and **Shift**-drag a
  straight line; **Ctrl**-drag on a line bends it into a curve (up bends
  it in, down out; the engine plays the same curve); **Erase** sweeps away
  every point in the columns it crosses; right-click a point to delete it.
  Each stroke is one undo step, and a dot rides the line at the value
  playing. The **magnet** (Snap) puts notes and points on the grid; off,
  they go anywhere (hold Cmd on macOS, Alt elsewhere, to place one freely
  while it is on). Recording overdubs: hit pads (mouse, keys or
  MIDI) while it plays, and each pass is one undo step. Pads light when
  the sequencer plays them.
- **Perform** (a panel beside the Mixer): at its top, the **launcher**:
  every sequence in use as a cell (its name, bars, its own tempo). Click
  one to launch it — stopped, it starts playing; playing, it takes over
  **at once**, on the **next beat**, the **next bar** or at the **sequence
  end** (the toolbar's **launch** setting). The playing cell runs a
  bar across; a queued one pulses with the beat and counts down; Shift-
  click only shows a sequence; **+ New** goes to the next empty one;
  right-click a cell for the sequence's commands. A sequence's own tempo
  takes over where it does. Below, how the pads play — **Pads**, each its
  own sound; **Keyboard**, the 16 pads are a scale (or diatonic chords:
  triads, sevenths, power chords) on the selected pad, from any root and
  octave, the bottom-left pad the root (the bank buttons, A–H, pick which
  16 notes: A the first 16 from the root, B the next 16, and on; the
  computer keyboard's pad keys follow); **Velocity**, the selected pad at
  16 velocities. Under note repeat and the arpeggiator, a bar of their steps lights the one playing (bright while it is on). **Note repeat** retriggers held pads on the grid;
  the **arpeggiator** walks held notes (up, down, up-down, random, as
  played; 1–4 octaves; gate; latch). MIDI: activity lights, **Learn**
  (the next note you play plays the selected pad), and **MIDI out** (the
  pad's hits also go out as a note on a channel).
- **Mixer** (middle tab): a channel strip, as in Logic, for every pad
  with a sound (all banks; it scrolls sideways), then the buses (four to
  start with, up to 16: the **+** adds one; they scroll when many) and
  main, pinned on the right. Right-click a bus's name to **Rename…** (or
  double-click it) or **Delete Bus** (what went to it goes to main; the
  buses after it move up a letter). Click strips' names with **Shift** (a
  range) or **Cmd** (one more) to select several: then moving one's
  fader, pan or a send moves them all by as much, and mute, solo and the
  output change them all (one undo step). From the top:
  - the pad's **EQ** curve (click it for the Effects tab, where the EQ is);
  - its two **inserts** (a bus and main have five slots);
  - its **sends**, one per bus (four show; with more buses they scroll):
    drag a send up and down for its
    level (Shift for fine), double-click to turn it on at 0 dB or off,
    right-click for **Pre-fader** (it then ignores the fader, and shows
    `pre`, its knob in yellow). A muted pad sends nothing;
  - **pan** (drag; double-click centres);
  - two readouts: the fader's level, and the loudest peak since you last
    clicked it (red above 0 dB);
  - the **fader** (Logic's taper: finer near 0 dB; double-click for 0 dB)
    beside the stereo meter and its dB scale;
  - **M**ute and **S**olo;
  - its **output**, right above its name: Main or a bus (click to
    choose). A bus's output is Main or another bus (one that would bring
    it back round to itself can't be picked);
  - the name on the pad's colour (click to select the pad).

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
  plays the chain of steps, each a sequence played 1–16 times (drag a step
  onto another to move it; with the toolbar's **Loop** on it goes round,
  otherwise it stops at the end). Across the top, the **timeline**: the
  song laid out in time, bars on its ruler and its total length in minutes
  and seconds (at each step's tempo), each step a block in its sequence's
  colour with its name and repeats (muted ones hatched), and the playhead;
  click the ruler to play the song from that bar, a block to select its
  step (Shift-click: a range; Cmd-click: one more or less). A selected or
  hovered block has a grip at each end: drag the right one to change how
  much of its sequence it plays, the left one to change where that part
  starts (its end stays), by bars (Shift: beats); drag a block's middle
  to move the selected steps elsewhere (a line shows where they land).
  With steps selected, Cmd+C copies them and Cmd+V pastes them after the
  last selected, Cmd+D duplicates them there, Cmd+X cuts them, Delete or
  Backspace removes them, Cmd+A selects them all. The playing step's
  card runs a bar across (drag cards too; a selected card takes the
  selection with it). On the left, every
  **sequence** slot with its colour, length, own tempo and how many times
  the song plays it (the playing one lit): double-click one or its **+** to
  add it at the end, drag it onto a step to put it before that one or
  onto the **+** at the end, click it to edit it, right-click for its
  commands (**Colour** among them: its colour shows on the launcher, the
  toolbar's list, the song and the Sequence panel). On the right, the
  selected **step**: its sequence, a section name (shown on the
  timeline), **Repeats**, which part of the sequence it plays (**Start**
  and **Length** in beats, drawn over the sequence), **Transpose** — each a
  number to drag (a step at a time; Shift: finer), scroll, or
  double-click and type — **Mute**, its **own
  tempo**, and Duplicate/Remove. The picker at the top holds
  **arrangements**: several songs from the same sequences, one current
  (Song mode and export play it); right-click it to add, duplicate,
  rename or delete one. **Add** (the current sequence's name) puts the current one at
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

## Slicers

A pad's **device** is what plays its notes: a **sampler** (the whole
sample, pitched by the keyboard), an **audio track**, or a **slicer**: its
sample cut into slices, each slice on its own key from the base note
(C3 by default: slice 1 on C3, slice 2 on C#3...). It is much like a
sampler in slice mode: the Env, Filter, Pitch, LFO and Global tabs, and
warp, work on it as on a sampler.
On either, the Global tab's **Transpose** moves in whole semitones (drag
or scroll it); **Fine** is for anything in between, in cents.

Ways to make one:

- In the browser, **Shift+Enter** slices the selected file onto the
  selected pad if it is empty, else the next empty one;
  **Cmd+Shift+Enter** slices it onto the selected pad. The file's
  right-click menu has both (**Slice onto Next Empty Pad**, **Slice onto
  Selected Pad**).
- Drag a file onto a pad with **Alt** held. Dragged over an empty pad, the
  pad shows two halves: **Sampler** at the top, **Slicer** at the bottom.
  Let go on the one you want. A file dropped on a slicer pad goes into
  the slicer.
- In a pad's right-click menu, **Slicer** makes a sampler a slicer (sliced
  at its transients), makes a slicer a sampler again (its slices kept for
  next time), or makes an empty pad an **empty slicer**. Drop a sample
  into an empty slicer, or press its record button to record the input
  into it; either way it is sliced when the sample arrives.

A new slicer is cut at its **transients**. The **Slicer** tab (the pad's
first tab):

- **Mono | Poly**: in Mono a slice cuts off the one before; in Poly slices
  ring together. **Thru** plays a slice on to the sample's end. **Gate**
  stops a slice when its key is let go (otherwise it plays to its end).
- **From** sets the base note. **Fade in** and **Fade out** (ms) shape
  every slice's ends, so cuts don't click. **Velocity** sets the
  sensitivity: 0% plays every hit equally loud, 50% follows how hard you
  hit, and above 50% makes soft hits softer still.
- **Transients | Beats | Equal | Manual** slices it again: at its hits
  (with a sensitivity), on a grid of its tempo (bars, 1/4, 1/8, 1/16), or
  into equal parts. Editing a marker by hand switches it to Manual.
- The waveform has a marker for each slice. Drag a marker by its numbered
  tag or its line, **double-click** between markers to add one, and
  **right-click** a marker to remove it (slice 1 always stays). Each slice
  has a gray **level line** with a handle: drag it up or down (-24 to
  +6 dB). The waveform shows dB down the left side (a line at -6 dB), and
  time or bars along the bottom. The wheel zooms around the mouse,
  Shift+wheel pans, and the strip underneath shows the whole sample with
  the visible part as a window you can drag. Markers are placed in the
  sample, so they stay put when the sample is warped or stretched.
- Under the waveform, the selected slice: **play** it, and set its own
  **level**, **pitch**, **pan** and **Reverse**.
- The buttons by the slice count: **Slices to a sequence** writes a new
  sequence that plays each slice where it falls. **Slice to pad** copies
  the selected slice onto the next empty pad, as a sampler of just that
  part (with its level, pitch, pan and direction). **To sampler** turns
  the slicer back into a sampler.

In the piano roll a slicer has a row per slice ("Slice 3 D3"). In
**Keyboard** play mode, the selected slicer's slices are laid out on the
pads, slice 1 on the bottom-left pad. A sequencer note's pitch chooses its
slice, and so does a MIDI note's key.

## Synths

A pad can be a **synth**: a wavetable synthesizer (`fire:synth`; the
design is in [docs/design/synth.md](/design/synth/)). Right-click a pad and
choose **Synth** (again to make it a sampler; its patch is kept). It plays
chromatically: a pad hit plays C3, the piano roll and Keyboard mode play
its pitches, and an armed track's MIDI plays it (an armed synth taking
All MIDI too, by key rather than the drum map), pitch bend, the mod wheel
and channel pressure included. The Pitch, Cutoff and Resonance lanes reach
its transpose and filter 1.

Its device has eight tabs; on the tab bar's line (or just under it) are
the **sources**: E1–E6 (envelopes), L1–L8 (LFOs), R1–R4 (random), M1–M4 (macros), velocity,
key, aftertouch, mod wheel, pitch bend and random. **Drag a source onto any
knob** on any tab to modulate it: the knob gets a ring in the source's
colour from its value to where the source takes it, and a dot shows where
the newest note has it now. Drag the ring's end up or down for the amount
(Shift: fine); right-click it to take the modulation away.

**Presets** sit on the line of the device's tabs, at its right. The menu
lists yours first, then the built-in bank by kind (basic, lead, keys,
bass, pad, FX). The arrows step to the preset before or after, and the
disk saves the sound as one of yours. Yours are kept in the settings
folder under `Presets/Synth`, one `.fsyn` file each, and carry any of
the project's own wavetables they play (an audio keyframe's sound stays
behind). Loading a preset is one undo step.

- **Osc**: oscillators A, B and C and the sample oscillator. Each has an on
  switch, a wavetable (built in, or any sound dropped on its view: cut
  into frames of 2048 samples), where it goes (filter 1, filter 2, both,
  or past the filters), and key tracking. The view shows the table's
  frames stacked back in perspective, the one playing in the pad's
  colour. Knobs: level, pan, frame, transpose, tune, phase, random phase;
  unison voices (up to 16), detune, blend, stereo spread, the detune's
  curve and range; the warp's amount. The unison stack (chords,
  harmonics, octaves) and the warp (sync, formant, quantize, bend,
  squeeze, pulse width, FM and RM from the other oscillators or the
  sample) are chosen beside them, with the warp's spread and phase.
  **Morph** (beside Key track) changes the frame's harmonics before they
  become a wave, so it never aliases. The modes are vocode, formant
  scale, harmonic stretch, inharmonic stretch, smear, random amplitudes,
  low-pass, high-pass, phase disperse, Shepard tone (to the octave up)
  and skew (the higher harmonics read from further along the table).
  The **Morph** knob sets how far. Formant scale, the two stretches and
  skew do nothing at 50%; the others do nothing at 0. The view draws
  the playing frame as morphed.
- **The wavetable editor** (the pencil beside an oscillator's wavetable)
  opens a window over the app. A built-in table can't be edited: start
  a **New table** (a sine to a saw) or **Edit a copy** of the one
  playing (up to four of its frames, as drawn keyframes). A table has up
  to 16 keyframes, each at a frame. On the strip along the top, click one
  to edit it, drag it along, or double-click between two for a new one;
  **+** adds one halfway to the next, the bin removes the chosen one.
  Each keyframe is made one of four ways:
  - **Draw**: drag across the cycle to draw it.
  - **Lines**: points joined by curves. Drag a point, double-click for a
    new one, right-click one to remove it; drag a line's middle dot to
    bend it.
  - **Harmonics**: 64 bars for the levels, and below them the phases;
    drag across them.
  - **Audio**: a cycle of the table's sound (drop one on it); drag along
    the sound to choose where.

  Frames between keyframes **Crossfade** (a mix of the two waves) or are
  **Spectral** (each harmonic's level and phase glide), as the table is
  set. The 3D view beside shows the table as built, the keyframe lit.
  Every edit is one undo step, the table is saved with the project, and
  the sound follows within a tenth of a second. Tables of the project's
  own are also listed in each oscillator's wavetable menu.
- **Filter**: two filters side by side: analog, dirty, ladder, digital,
  diode, formant, comb or phaser, each with its styles. The response is
  measured from the filter itself and drawn; drag its handle for cutoff
  and resonance. The link button puts filter 1 into filter 2.
- **Env**: six envelopes, the first the amplifier's: delay, attack, hold,
  decay, sustain, release, and the curves of the attack, decay and
  release. Drag the curve's corners, or a segment up and down to bend it.
- **LFO**: eight LFOs, each a shape you draw: drag points, double-click to
  add one, right-click to take one away, drag a segment up and down to
  bend it (or pick a preset). Mode (trigger, sync, envelope, sustain
  envelope, loop point, loop hold), rate (in seconds, to the tempo,
  dotted, triplet, or the note's pitch), phase, fade-in, delay, stereo
  offset and smoothing. **R1–R4** on the same row are the four random
  modulators. Each has a style: *Perlin* (smooth noise), *Sample & hold*
  (a new value each step, held), *Sine glide* (a new value each step,
  glided to) or *Lorenz* (a chaotic attractor's path, which never
  repeats). Each also has a rate (as an LFO's), *Stereo* (the right side
  wanders on its own) and *Retrigger* (every note wanders the same way).
  The picture shows four seconds of its wander at that rate. While a
  note plays and the modulator is routed, a dot at its right edge shows
  the newest note's value.
- **Mod**: every source as a chip, and every modulation: its amount, curve,
  bipolar, stereo (the right side moved the other way) and on.
- **Effects**: the synth's nine effects in a chain: chorus, compressor,
  delay, distortion, EQ, filter, flanger, phaser and reverb. Each row has
  a power button; drag a row up or down to move it in the chain. Click
  one to see its page: its choices, a picture of what it does and its
  knobs. The pictures are the EQ's and filter's responses (drag the
  filter's handle for cutoff and resonance), a sine through the
  distortion, the delay's echoes (left above, right below), the reverb's
  tail, each compressor band's level in and out against its thresholds,
  and the chorus, flanger and phaser sweeps, their dots moving as they
  play. Delay, chorus, flanger and phaser rates are in Hz or follow the
  tempo (straight, dotted, triplet). Every knob takes modulation: macros
  and the wheels move it, and so do the newest note's envelopes and LFOs.
  An oscillator sent to *Direct out* skips the effects.
- **Macro**: four macro knobs (named as you like), their chips, and the
  keyboard's sources.
- **Global**: poly, mono or legato; oversampling (1× to 8×); voice
  priority; always glide, glide by octaves; volume, voices, glide time
  and curve, bend range, velocity tracking, transpose, tune; and the
  output as an oscilloscope and a spectrum.

## The transport

The toolbar under the menus, centred, always showing. Its buttons are
icons whose colour shows their state.

- **Play** (green while playing) and **Stop**, or Space for both. Press
  **Stop** twice (or when stopped) to silence every sound still ringing.
  **Record** (red; Cmd+R) arms recording: from a stop it plays, after the
  count-in.
- **Loop**: on, a sequence (or the song) goes round; off, it plays once
  and stops. **Count-in** (the timer; click for off, 1 bar, 2 bars):
  bars of click before recording starts, with nothing played or recorded
  until the top (the position shows them as bar 0, in yellow). The
  count-in clicks even with the metronome off (a setting). A hit a little
  before a sequence's first beat — at the end of the loop, or of the
  count-in — is recorded on it (by default up to a 1/16 early; a
  setting).
- The **position**: bar . beat . sixteenth of the sequence playing.
- The **sequence**: pick one of the 32 (those with notes are marked), or
  step with the arrows.
- **Pattern | Song**: play the sequence shown, or the song's steps one
  after another (the Song tab has the same switch). Beside it, **launch**:
  when a sequence picked while playing takes over — **At once**, the
  **Next beat**, the **Next bar** or at the **Sequence end**.
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

## Tracks: ins, outs and arming

Each pad is a track. Its strip (and its Global tab, or an audio track's
Sample tab) has its **input**, right above its output: for a sampler
track, its **MIDI in** — *All MIDI* (any port's notes, by the drum map:
note N plays the pad the map gives it, Learn changes it), *No MIDI*, or
one port (any channel, or 1–16), whose notes play it chromatically (E3 is
four semitones up) while it is **armed**, and record onto it, pitched.
For an audio track, its **audio input**: a channel of the interface (In 1,
In 2...) or a stereo pair (In 1/2...), with its level along the row. A
sampler track's light flashes green as its MIDI comes in and blue as its
**MIDI out** (Perform panel: on, channel, note, and its own output port)
goes out; the toolbar's light (click it for the MIDI settings) does the
same for all MIDI.

**Arming**: every strip has **R**, and an armed pad a red dot. Selecting a
track arms it, and the one armed before by selecting goes back (Settings >
Recording turns this off); click R to arm only that track, or Cmd-click
to arm more (those stay armed when the selection moves). An armed audio
track records its input when you record (and monitors it, with
**Monitor**); an armed sampler track plays its own port's notes and
records them. Pads hit on the grid or the computer keyboard, and notes
by the drum map, record onto any pad, armed or not.

## Settings

**File > Settings…** (Cmd+,) holds what is the same for every project, in
a window over the app: its pages down the left, each page scrolling on
the right. They are kept in `settings.ini`: in your configuration folder
(macOS `~/Library/Application Support/Pads`, Windows `%APPDATA%\Pads`,
Linux `~/.config/pads`), or beside the app when a `settings.ini` is
already there (a portable install, on a stick); the window shows which.
It is a plain text file: what you write in it by hand (comments too)
stays when Pads writes it back. The recent projects, browser favourites,
plug-in list (`plugins.ini`) and window layout (`layout.ini`) sit beside
it.

- **Appearance**: the theme (Dark, Light, Midnight, Graphite, Paper, and
  your own), every one of its colours (click a swatch), **Save as
  preset**; the **zoom** (50–300%: everything drawn larger or smaller, as
  a browser zooms); the pads' waveforms; whether the layout is
  remembered, and **Reset layout**.
- **Audio**: the output and input devices, sample rate and buffer size
  (what each device offers), input channels. Changes wait for **Apply**,
  which opens the device with them; keep them within 10 s or they go
  back (no getting stuck without sound). Below, the engine now: the rate
  and buffer it runs at, the latency in, out and round trip, its block,
  channels, dropouts since starting, and its **load** (how much of each
  buffer's time it takes to make it).
- **MIDI & Sync**: MIDI on or off, each input port on or off, the output
  port (pads' MIDI out and the clock go there), activity, and an **input
  offset** (MIDI notes recorded that much earlier, for a controller's own
  delay). What the **tempo follows**: Pads, an incoming **MIDI clock**
  (its tempo, Start, Stop and Song Position; the tempo it hears shows),
  or an **Ableton Link** session (start and stop with it too; how many
  apps are in it). **Clock out** sends MIDI clock to the output. Link is
  built in whenever its library is there (`task deps` builds it).
- **Recording**: **Arm the selected track** (on by default), whether the
  count-in clicks with the metronome off (on by default), and how early a
  hit before a sequence's downbeat still goes on it (off, a 1/32, a 1/16,
  an 1/8).
- **Projects**: what a new project starts with (tempo, time signature,
  sequence length, buses), the folder Save starts in, autosave (off, or
  every 1–10 minutes), opening the last project on start, and the export
  sample rate and bit depth.
- **Plug-ins**: the folders searched (the system's CLAP folders and
  CLAP_PATH's, then your own), **Scan now** (a library a frame; on start
  if you like), and what was found: name, vendor, version, kind, and
  whether it is used (a blocked one is never opened). A library that
  stops Pads during a scan is blocked at the next start. The effect
  plug-ins found are offered in every effect slot's list.
- **Keyboard**: every command and its shortcut; click one and press the
  new keys (Esc keeps it, Backspace takes it away). One already used is
  shown, with **Take it**; **Reset** one or all. The editors' own keys
  are listed below them.

To work on several pads at once, **Shift**-click pads (a range) or
**Cmd**-click them (one more or less): right-click one of them to
**Mute**, **Solo**, set their **Choke Group** or **Clear Pads**, or press
Delete to clear them (each one undo step).

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
  **Save As…** (Cmd+Shift+S: a name and a place; it becomes the folder
  `<name>.pads`, the samples copied there), **Rename Project…** (its
  folder renamed beside where it is).
- Changes are saved on their own every minute, and on quitting. The
  window's title shows the project, with a dot while it has unsaved
  changes. Opening a project starts a new undo history.
- A new project is "Untitled" and lives in the temporary folder: **Save**
  asks for its name and place (Documents to start with), as Save As
  does.

## Export

**File > Export Audio…** (Cmd+E): the current sequence (once) or a song
(pick the arrangement; the file is named after it, and the dialog shows
its length);
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
send PAD BUS DB [pre|post]   a pad's send to bus BUS (1..the buses in use; -60 dB is off)
addbus / delbus B / busdest B D (0 = main) / busname B NAME
warp PAD on|off [beats|tones|complex|repitch] [BPM]
rename_project NAME
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
| `test_device.py` | the device tabs (Transpose in whole semitones on a sampler and a slicer): the amp envelope's handles, the filter's type, slope and response handle (and the live cutoff above the setting while its envelope opens it), the pitch envelope, an LFO routed to the cutoff, Global, an audio pad's tabs; legato chosen, its glide dragged, Always set and undone |
| `test_sample.py` | the Sample tab's wave: S and E dragged by their tags, the fade handles (and undo), the playhead while it plays, the bottom panel's channel strip |
| `test_commands.py` | the menus made from the command list (a pad's, a note's, a song step's, an effect slot's, a bus's, a knob's), the palette on the selection, commands by id |
| `test_song_arrange.py` | the Song tab arranged: a step's settings (mute, part, transpose, own tempo, name), the timeline's ruler playing from a bar, arrangements (duplicate, each its own song, undo), a sequence's colour |
| `test_note_keys.py` | the editor's keys on selected notes: Backspace, 0 to mute and unmute, Cmd+A, the arrows (a step, a bar, a row), Cmd+D; the toolbar's Pattern / Song and launch setting |
| `test_song_overview.py` | the Song timeline: Shift- and Cmd-click selection, the blocks' end and start handles (bars; Shift: beats), dragging a block to move the selection, Cmd+C / Cmd+V / Cmd+D / Cmd+X, Backspace, Cmd+A, undo |
| `test_tracks.py` | arming follows the selection (Cmd-click arms more, the setting off); a track's MIDI input chosen on its strip, an armed track played by its own port; the input meters |
| `test_settings.py` | the Settings window: theme and zoom (clicks still land, zoomed), a shortcut pressed in (and a clash taken), audio applied and kept, the tempo following MIDI clock and the clock out, a new project's defaults from settings.ini (a hand-written comment kept), plug-ins scanned and offered |
| `test_synth.py` | a pad made a synth from its menu and played; Keyboard mode's banks moving the notes, a key recorded at its pitch; a source dragged onto a knob, its ring's handle dragged and right-clicked away (and undone); the envelope's attack handle and an LFO point drawn; a wavetable chosen; legato and oversampling; the effects chain (an effect switched on, dragged to the front, undone); a random modulator (its style, dragged onto a knob); the wavetable editor (a new table, a harmonic dragged, a keyframe added and undone); presets (stepped through, chosen, saved as yours and found again) |
| `test_slicer.py` | slicing from the browser (Shift+Enter, Cmd+Shift+Enter, the file's menu, Alt-drag, an empty pad's Slicer half); an empty slicer filled by a drop; markers dragged, added and removed; a slice's level line; zoom and the overview; slices to a sequence and to a pad; the piano roll's slice rows; Keyboard mode playing slices; back to a sampler with the slices kept |
| `test_tweaks.py` | several pads selected (Shift, Cmd) muted, choked and cleared; the choke group in the Sample tab; Stop twice; Settings; a sample dropped on a sequence row; the lane's height; renaming the project; buses added, renamed and routed, several strips moved at once; a pad's warp |
| `test_automation_draw.py` | automation drawn freehand, as a Shift line, bent with Ctrl, swept with Erase; the Snap toggle |
| `test_song_side.py` | the Song tab's sidebar: double-click and + to add, dragging onto a step and onto the end, click to edit, right-click, undo |
| `test_note_tools.py` | the editor's tools: a row's name (its pad, its notes, the headphones; Delete on the selection), Draw painting and Erase sweeping (one undo step each), Move and Alt-copy, V/B/E/M, a row's Rename, the piano roll and Fold |
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

## Licence

Pads is free software under the GNU General Public License, version 3 or
later (`apps/pads/LICENSE`), so that it can include Ableton Link
(GPL-2.0-or-later). Fire Engine itself — the engine and the application
layer Pads is built on — stays under the MIT licence.
