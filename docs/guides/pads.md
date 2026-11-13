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
panel or tab is in front (see [The transport](#the-transport)). Below it,
the **Library** runs the full height on the left (its **Browser** and
**Devices** tabs: see below; drag its right edge to make it wider, View >
Library or Cmd+L to hide it); the **Sequence**, **Song**, **Mixer** and
**Perform** are tabs in the middle; and along the bottom, beside the
Library, is the **pads area**, the device view (as Ableton's). Drag its
top edge to make it taller or shorter. **Fold** it (the arrow at the
right of its header, View > Fold the Pads Area or Cmd+J) and it becomes a
bar of the bank's 16 pads, each its name and colour, bright while it
plays, so the view above gets the height (all 16 rows of a drum
sequence fit): click a pad in the bar to select it and unfold on it.
Files and devices drop onto the bar's pads as onto the grid. Across the
pads area's top, where a panel's tab would be, is a tab for each device
of a track, and at the right how the pads play (as pads, a keyboard, or
velocities) and the fold button; below,
the pad grid on the left (always there, to pick another pad), the device
in front, and at the far right the track's channel strip (a pad's is the
mixer's without its EQ, inserts and sends: output, pan, fader, meter,
mute and solo). A pad is a sampler device: its chain starts with **A1 kick
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

Buttons that are only an icon (play, stop, the sample edits) have no
frame: the icon is dimmed at rest, brightens under the mouse, and takes
a colour when on — green while playing, the accent for other toggles.
Switches are lit buttons: the label is the button, with a light at its
left, lit when on. Settings set once (lengths, swing, voices) are value
bars: the name at the left, the value at the right, filled as far as the
value goes; drag across them, scroll, or double-click to type.

The **pads area** (the pads, the sound's devices and effects, the
channel strip) draws its accent (selection, focus, the active tab,
knobs' arcs, lit buttons) in the colour of the pad it shows, so it says
which pad you are on; the rest of the window keeps the theme's accent,
as does the area for an empty pad, a bus or the performance effects. A pad colour too
dark or too light to stand out is lightened or darkened for the accent
(the pad keeps its own). Record is always red and blinks while it
records.

- **Library** (left): for finding sounds and devices fast, in two tabs,
  each with a search box at its top. **Browser**: sections that open and
  close (click a section's header), **Favourites** and **Folders** (the
  search finds files under the folder shown, listed as **Files**), and the
  preview at its foot. **Devices**: **Instruments**, **Effects** and
  **Plug-ins** (see [The Library's devices](#the-librarys-devices)),
  found by name.
  - **Favourites** are favourite folders, as tabs. A new install has **Documents** and
    **Project** (the open project's samples). The **+** tab, or the
    star, adds the folder shown; right-click a folder for **Add to
    favourites**; right-click a tab to rename it, move it or remove it.
    Favourites are kept with your preferences, not in the project.
  - **Folders**: **back**, **forward** and **up** (Backspace), and the folder's path:
    click any part to go there. **Refresh** reads the folders again.
  - The **tree**: click a folder to open it in place (its icon shows it open),
    double-click to go into it. Links to folders work. Only audio files
    (WAV, AIFF, FLAC, MP3, Ogg) and folders show. Each WAV or AIFF shows
    its length at the right of its row (read from the file's header the
    first time its row shows; other formats show none yet).
  - **Search** finds file names (any case) in every folder under the one
    shown, on a background thread; the results list the path under it.
  - Click a file to select it (with auto-play, it plays at once), or drag
    it onto a pad. **Double-click** it, or press **Enter**, to put it on
    the selected pad; with **Shift** (Shift+Enter, Shift and
    double-click), on the **next empty pad** (the selected pad if it is
    empty, else the first empty one after it). The two buttons under the
    preview do the same and say where: **To A3**, **To next empty: A5**.
    With the list focused, the arrow keys move up and down (and preview
    what they land on); Right and Left open and close a folder.
  - The **preview**, at the bottom: the file's waveform with a playhead;
    play/stop (the icon turns to a stop while it plays); **auto-play**
    (on at first: selecting a file plays it); **sync** (while the
    sequencer plays, a loop of about 1, 2, 4… 64 beats is stretched to
    the project's tempo, pitch unchanged, and shows its beats; one-shots
    play as they are); and the preview's own volume (a value bar: drag
    it, or double-click to type). It plays straight to
    the output, past the mixer and main's effects, and never into an
    export.
- **Pads** (bottom left): 128 pads in 8 banks (A–H) of 16, numbered from
  the bottom left (pad 1) up, as on an MPC. Click a pad, or
  press its key, to play it and select it. The keys sit as the pads do:
  `Z X C V` is the bottom row (pads 1–4), then `A S D F`, `Q W E R`, and
  `1 2 3 4` the top (pads 13–16). A pad with a sound shows:
  - its name, large, at the top (cut off at the pad's edge), and under it
    its kind: sampler, synth, slicer (and its slices), audio, plug-in;
  - **M**ute (bottom left) and **S**olo (bottom right): the same switches
    as its mixer strip's;
  - behind them, faint, the sound's waveform (the region it plays);
    **View > Pad Waveforms** turns these off.

  An empty pad shows a "+" (drop a sound here), its label and its key
  (`A1 · Z`). Its note (pad N is MIDI note N−1: A1 is C-2, what a MIDI
  controller plays it with) is in its tooltip. Selected, its page says
  what to put on it: **Browse** (the Library's Browser), **Record** (an
  audio track), **Synth**, **Slicer** (empty: a sound dropped on it is
  sliced) or **Plug-in** (an instrument plug-in found).

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
- **Sample** (bottom tab): the waveform takes most of the page, with one
  toolbar line above it and a row of knobs below.
  - **The toolbar**, left to right:
    - the **play mode** menu: **One-shot** to the end, **Gate** while held,
      **Loop** loops while held, **Hold** loops until hit again; when
      looping, the loop's direction (Forward, Ping-pong) and crossfade, in
      the same menu;
    - **Reverse**;
    - the **choke group** (a hit stops the others playing in its group:
      open and closed hi-hats; the pads show theirs as a badge, `C2`);
    - **Warp**, and the chevron beside it for its settings (below);
    - **Chop**: a popup with how (at the transients, with a sensitivity,
      or into equal parts) and **Chop into pads**, onto consecutive pads,
      each playing its slice of the same file;
    - record (the circle): record the audio input onto the pad;
    - **...**, the edits: **Crop**, **Delete**, **Silence**, **Fade in**
      and **out**, **Normalize**, **Reverse audio**, **Trim** (silence
      from both ends), **To a pad** (the selection on the next empty
      pad), and **Stretch to beats** (time-stretch the region to N beats
      at the project tempo, pitch unchanged, as a new file; Warp does it
      without touching the sample). Edits write a new file into the
      project and leave the original alone, so they undo.
  - **Warp**: on, the sample follows the tempo at its own pitch, made
    longer or shorter rather than played faster or slower. Its settings
    (the chevron) pick how — **Beats** (cut at its hits, or on a 1/16,
    1/8 or 1/4 grid of its own beats, each piece played as it was and
    moved to its new time: drums and loops, attacks exact; **Fill gaps**
    loops a piece's tail when slower instead of leaving silence),
    **Tones** (a spectral stretch of the whole: voices, bass, pads),
    **Complex** (the spectral stretch started again at each strong hit:
    full mixes, attacks kept crisp) or **Re-pitch** (faster or slower,
    the pitch with it). Its own tempo is guessed from its length (a
    whole number of beats; drag or type it, or the wand guesses again);
    its beats are drawn over the waveform (bars numbered). The warped
    sound is rendered in the background into the project's `cache/warp/`
    folder, kept there for the next time, and played once ready (it
    shows "Rendering..." until then, the ratio after). Warped, the pad's
    **Transpose** (and Fine) keeps its timing: Tones and Complex shift the
    pitch in the stretch, Beats re-pitches each piece where it falls (its
    hits on time); the rendering has the pitch in it (until it is ready,
    the pad plays transposed the old way). In Re-pitch, pitch and speed
    are one, so Transpose plays it faster or slower as before.
  - **The waveform**, on black: drag **S** and **E** (by their tags or
    their lines) to set the region the pad plays, **L** for the loop;
    drag the squares under the tags in from the region's ends to fade it
    in and out (a ramp shows each fade; the fades are the pad's, so the
    file is left alone); drag across the wave to select. While the pad
    plays, a white playhead runs through the wave and the sound's
    spectrum moves behind it, faint, in the pad's colour.
  - **The knobs**: Volume, Pan, Transpose, Fine, Attack and Release (the
    same as on the Global and Env tabs).

- **Sequence** (middle tab): the sequencer, editing the sequence the
  toolbar picks (or its own arrows, either side of its name). Its name (double-click it, press F2, or right-click it
  or its entry in the toolbar's list to rename it); **Duplicate** (Cmd+D:
  into the next empty sequence, named "… copy", with its audio takes);
  **Own tempo** (it plays at its own tempo, which takes over exactly where
  the sequence does, in the song or switching live); **Copy Bars to…**
  (from its menu or the palette: bars, every pad or one or a bank, into
  another sequence at a bar, replacing or laid over). Its length (1–64 bars, ×2 doubles with the notes);
  swing (on 1/8 or 1/16). Under that, two tabs: **Notes** (the default)
  and **Automation**, each with its tools on the same line. The tab you
  pick stays as you move around the app, and is saved with the project.

  In **Notes**: the grid (1/4 to 1/64, triplets) and Quantize (Cmd+U,
  the notes there), input quantize. Below, the current bank's pads (pad
  1 at the bottom, as on the grid) as
  rows, edited with four tools (on the tab's line, or the keys
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
  solo, its piano roll...), and at its top **Track Loop**: the track goes
  round on its own inside the sequence, any length (1, 3, 5 beats, or
  dragged a 1/16 at a time) — 3 beats in a 4/4 bar drifts against the
  rest (polymeter), starting again at each of the sequence's passes. Its
  row shows the loop's end (and each time round), dims the rest and
  draws what plays there as ghosts; notes past the loop aren't heard.
  Recording into it, each pass lands inside the loop. An audio track
  loops the same way, exact to the sample (its Audio tab's **Loop**
  too); its takes are recorded a loop each. Saved, exported, frozen and
  played in the song as heard. **Drums | Piano roll** switches to one pad's
  notes on a keyboard (its own pitch is the marked C3, four octaves each
  way; double-click a row's name to open it), where it plays
  chromatically. **Fold** shows only the rows that have notes (drums: the
  pads used, from every bank; piano roll: the pitches used). The wheel
  scrolls the rows when they don't all fit; **Cmd+wheel** (Ctrl) over
  them, or the **Rows** control beside Fold (dragged), makes them taller
  or shorter — fewer or more at once (at its least: as many as fit). Notes of one pad (and pitch) never overlap: a note cuts short the
  one before it, replaces one that starts with it, and takes over one it
  covers (a note it reaches into keeps the part after it), however it got
  there (drawn, moved, pasted, recorded, imported). Under the rows, a
  slim lane (drag its top edge for more): each note's velocity, its
  chance (the probability it plays each time round; a new note's is
  100%), or a **MIDI CC** of the selected pad, as its name at the left
  picks (**CC…** adds one: the usual ones by name, any of 0–127). A CC
  lane is steps 0–127, each held until the next, drawn with the note
  tools; it goes out on the pad's MIDI out and, on a plug-in pad, to its
  instrument.

  In **Automation**: one automation at a time across the whole view, its
  value scale at the left, the notes drawn grey beneath it for timing
  (**Notes** turns them off). The menu at the left of the tab's line
  picks which: the automations this sequence has; **New automation**: a
  track (a pad with a sound, a bus, main), then a device (a pad's
  Volume, Sound, EQ, each insert, each send on; a bus's or main's Volume,
  Pan and effects), then any of its parameters (a plug-in's too); or
  **Touch a control…**: the next knob or fader you move anywhere becomes
  it (Escape cancels). Right-click any knob or fader for **Automate**
  (**Show Automation** once it has some): the tab opens on it.
  Frequencies are drawn on a log scale. Its tools (or their keys):
  **Select** (V) a click adds a point and a drag moves one; **Draw** (B)
  draws freehand (a point each grid step; **Shift**: a straight line);
  **Line** (L) drags a straight line; **Curve** (C) drags a segment up or
  down to bend it (up bends it in, down out; **Ctrl**-drag does with any
  tool; the engine plays the same curve); **Erase** (E) sweeps away every
  point in the columns it crosses; right-click a point to delete it. The
  point under the mouse says where it is and its value. Each stroke is
  one undo step, and a dot rides the curve at the value playing.

  **Recording knob moves**: the **Auto** button beside Rec (off by
  default). With it on and Rec recording, a knob or fader moved writes its
  moves into the sequence as that parameter's automation, over what was
  there for as long as it is held (thinned to the shape: a point only
  where the line would miss it); each pass round the loop is one undo
  step. With it off, knobs only change the sound.

  The **magnet** (Snap) puts notes and points on the grid; off,
  they go anywhere (hold Cmd on macOS, Alt elsewhere, to place one freely
  while it is on). Recording overdubs: hit pads (mouse, keys or
  MIDI) while it plays, and each pass is one undo step. Pads light when
  the sequencer plays them.
- **Perform** (middle tab): the whole height (the pads area folds to
  its bar while it shows, and stays folded going to or from Song), with
  three grids side by side and the levels at the right.
  - **The bar on top**: the launcher's **window** (arrows: a lane, a
    row at a time; "Lanes 1–4 · rows 1–4"), **+** (a new lane, up to 16)
    and **Keys** (the computer's pad keys play the window's sequence pads
    instead of the pads); **Launch** or **Hold** (a sequence plays
    only while its pad is held, its lane going back to what it played
    when you let go); **at** End, Bar, Beat or Now (when a launch
    happens: when its lane's sequence comes round, or the next bar,
    beat, at once); **Continue** (on, a launched sequence carries on
    where the playhead is in what played — its lane's sequence, or with
    none the leading lane's: that pass so far, modulo the new one's
    length — for seamless changes; off, it starts from its top);
    **Record to Song** (armed, what you launch is
    written into the Song as clips, launcher lane k onto song lane k
    (named after it), from where each starts to where it is replaced or
    stopped; the take goes in when you stop, or disarm, as one undo
    step, over the clips that began on those lanes in its time); and, at
    the right, **Hold effects**.
  - **Sequences**: **lanes** (8 in a new project: Settings > Projects >
    Launcher lanes), each sequence in one, at a row of it. A lane plays
    one sequence at a time, the lanes all together (drums in one, a bass
    sequence in another, fills in a third). The grid is a **4 × 4 window**
    (as a pad controller's) over the lanes: its columns are lanes, their
    **headers** their names (click one: rename, colour, stop, a new
    sequence at its end, delete — its sequences go to the lane before);
    each row's arrow launches that **scene** (the row of every lane), each
    lane's square stops it. Under it, the **overview**: every lane and its
    sequences, the window outlined (click or drag to move it). A press
    launches a sequence in its lane; stopped, it starts playing, alone.
    **Option-drag** a sequence pad to another lane or row (or its menu:
    Move to the Lane Before / After, Move Up / Down a Row); a lane's **+**,
    after its last, makes a new sequence there (an unused one). A ring at
    a pad's corner: it plays a pad that another lane's sequence plays too
    (both play it). A pad shows its sequence's notes, a bar filling across while it
    plays, a countdown while queued ("in 2.2"), "stops" when its column is
    about to; empty pads are nearly invisible (a + on hover: click one to
    make a new sequence there). **Shift-click** launches a sequence
    alone: the other columns stop when it takes over. **Option-click**
    only goes to a sequence (to edit it); right-click one for its
    commands. At each row's right, an
    arrow launches the row (its sequences together, a scene); under each
    column a square stops it; the last one stops them all. The loop goes
    round a length every column fits a whole number of times. Recording
    in pattern mode goes into the sequence being edited (the one launched
    last). Picking a sequence elsewhere (the toolbar, the Sequence view)
    plays it alone, as before.
  - **Pads**: the 16 pads to play, as in the pads area (its banks, Pads,
    Keyboard or Velocity as the MIDI page sets).
  - **Effects**: the 16 performance effects, coloured by kind (filters
    violet, rhythm teal, pitch pink, space blue, drive coral; see below).
  - **Levels**: main and the cue (headphones; Settings sets where it
    plays), each a strip with its fader and meter as in the mixer, its
    level under it. The cue's meter is what the cue output plays (silent
    while no cue output is set).
- **A pad's MIDI page** (the **MIDI** tab, first in its chain in the
  bottom area, before its sound; it reads **MIDI · Repeat** or **MIDI ·
  Arp** when one is on): how the 16 pads play — **Pads**, each its own
  sound; **Keyboard**, the 16 pads are a scale (or diatonic chords:
  triads, sevenths, power chords) on the selected pad, from any root and
  octave, the bottom-left pad the root (the bank buttons, A–H, pick which
  16 notes, from the bottom of the MIDI range up: A starts at the root's
  lowest octave (C-2 for C) and each bank goes on from the last. It opens
  on the bank holding the pad's own note (C3), and back in Pads mode the
  pads' own bank returns; the computer keyboard's pad keys follow);
  **Velocity**, the selected pad at 16 velocities. Then the pad's own
  **note repeat** (held, it plays at once and again on every step of the
  sequence's grid while playing, else the clock's: its step and gate; a
  press just before a step is that step's note, never a double hit)
  and **arpeggiator** (the notes held on it — a chord in Keyboard mode —
  one after another: up, down, up-down, random, as played; 1–4 octaves;
  gate; latch), each with a bar of its steps lighting the one playing
  (bright while it is on); one or the other, saved with the pad, acting
  on its live notes (not the sequencer's). Recording, what they play is
  what goes into the sequence: each repeat, each arpeggiated note, where
  it fell and as long as it sounded (not the key you held), never moved
  by input quantize (they are on their own grid already; only the first,
  played at the press, goes onto that grid when input quantize is on, so
  1/32 repeats aren't pulled onto 1/16s and merged). **Note Repeat** in
  the toolbar (MPC-style) turns note repeat on for every pad you hold, at
  its dropdown's rate and gate (kept with the settings); a pad's own
  works while it is off. While it is on, **Quantize** uses its rate. And its **MIDI**: activity
  lights, the key that plays it and **Learn** (the next note you play
  plays it), and **MIDI out** (its hits also go out as a note on a
  channel, from its own output port). Projects from before each pad had
  its own give every pad the project's old note repeat and arpeggiator
  settings.
- **Mixer** (middle tab): down its left side, in the middle, a column of
  icons for what the strips show — **Inserts**, **EQ**, **Sends**, **I/O**
  (each lit when shown, grey when not, named on hover; hidden ones give
  the fader the room) — and **narrow** or wide strips (narrow: more at
  once, the names their labels, the fader's level in the peak readout's
  tooltip; wide: 112 points, the I/O dropdowns and Mute, Solo and Arm
  taller while the Mixer has the height, else a row's size); kept in the
  app's settings. With the pads area folded (Cmd+J) the strips get the
  room: a bigger pan knob, and the sends as **knobs**, three to a row on
  a wide strip (two narrow), each ring its level over its bus's letter or
  name (orange when pre-fader), dragged up and down, with the rows' double-click and menu. Then a channel strip, as in Logic, for every pad with a
  sound (all banks; it scrolls sideways), then, at the right whatever
  room the pads leave, the buses (four to start with, up to 16: the **+**
  adds one; they scroll when many) and main, pinned on the right with its
  **meters column** (its chevron folds it away to a thin bar, and the
  bar opens it again). Right-click a bus's name to **Rename…** (or
  double-click it) or **Delete Bus** (what went to it goes to main; the
  buses after it move up a letter). Click strips' names with **Shift** (a
  range) or **Cmd** (one more) to select several: then moving one's
  fader, pan or a send moves them all by as much, and mute, solo and the
  output change them all (one undo step). **Groups** are buses:
  **Group Selected Pads** (**Cmd+G**, or a pad's right-click menu) puts
  the selected pads on a new bus named for the group (its name opens to
  type) and goes where the first of them went. The mixer shows each
  group's pads together behind its tab (the group's name down it): click
  the tab to fold its pads away or back, right-click it to rename or
  **Ungroup** (the pads go where the group went, the bus goes). The
  group's own strip is its bus's, with the other buses. From the top:
  - the pad's **EQ**: its switch (off on a new pad: it plays flat whatever
    its bands are; projects from before keep theirs on where it isn't
    flat) and its curve over a faint grid (100 Hz, 1 kHz, 10 kHz across;
    ±6 and ±12 dB); click the curve for the EQ tab below (its **EQ on**
    there too);
  - a block of rows, as many as the room has (the same on every strip;
    more scroll): its four **inserts** (a bus and main have five slots) —
    drag one onto another slot of the same strip to swap them (one undo
    step) — and its **sends**, one per bus, each a bar of its level:
    drag a send across for its level (right: more; Shift for fine), double-click
    to turn it on at 0 dB or off, right-click for **Pre-fader** (it then
    ignores the fader, and shows `pre`, its bar in yellow). A muted pad
    sends nothing;
  - its **cue** send, while a cue output is set (Settings > Audio): how
    much of it goes to the headphones mix on top of main (a send's knob:
    double-click, right-click for pre-fader);
  - its **audio in** (a channel or pair of the interface, its level
    along the row: what it records) and its **MIDI in** (all MIDI, a
    port and channel, or none; its light), each a dropdown;
  - **pan** (drag; double-click centres);
  - two readouts: the fader's level, and the loudest peak since you last
    clicked it (red above 0 dB);
  - the **fader** (Logic's taper: finer near 0 dB; double-click for 0 dB)
    beside the stereo meter and its dB scale. Each side's bar is its peak
    with its **RMS** (the average) inside it, a line its held peak; green,
    then amber, then red (dBFS: above -12 and 0; a K scale: above its 0
    and +4). A strip with a compressor, gate or limiter shows its **gain
    reduction** beside the meter, down from the top (0–24 dB);
  - **M**ute and **S**olo;
  - its **MIDI out** (off, the default output or a port, and its
    channel: its hits also go out as a note) and its **output**, right
    above its name: Main or a bus (click to choose). A bus's output is Main or another bus (one that would bring
    it back round to itself can't be picked). Either can also go to a
    **direct out**: an open output pair of the interface (by its name),
    straight there, not through main (exports fold direct outs back into
    the mixdown). One whose pair isn't open shows `(not open)` in amber
    and plays in main until it is;
  - the name on the pad's colour (click to select the pad; right-click
    for its commands and **Colour**: with several strips selected,
    their colour, all at once as one undo step).

  **Main's meters column**: its **loudness** (EBU R128): short-term (3 s)
  large, momentary (400 ms), and integrated since the last reset (click
  it to start again); its **true peak** (between the samples too; red
  over -1 dBTP; click to reset); its **phase correlation**, a bar from
  -1 to +1 (green in phase, amber near 0, red out of phase: it thins or
  cancels in mono); and a **stereo view** (a goniometer: mono straight up
  and down, wide sideways, out of phase flat across).

  **Settings > Appearance > Meters**: the scale (**dBFS**, or **K-12**,
  **K-14**, **K-20**: their 0 that far under full scale), **RMS
  emphasis** (the average bright and the peak dim), the **peak hold**
  (0–10 s; 0: none) and how fast the bars **fall** (dB a second).

  Click a slot to edit it in the **Effects** tab: what it holds, on or
  off (a 15 ms fade), and its settings. The effects are:
  - **the synth's own** (the same algorithms, pictures and knobs as a
    synth's Effects tab): Chorus, Compressor, Delay, Distortion, EQ,
    Filter, Flanger, Phaser, Reverb;
  - **Gate, Limiter, Ring mod, Comb, Pitch shift, Cutter, Stutter**, as
    before;
  - **a CLAP plug-in**.

  Projects from before open with their old effects converted to the
  nearest settings of the synth's. The low-, high- and band-pass become
  the Filter, the saturation and bit-crusher become the Distortion, and
  the delay, reverb, compressor, chorus, flanger and phaser keep their
  times, feedback, mix and tone. They sound close, not identical. A
  plug-in that can't be found plays nothing and says so. A pad's volume
  is its fader, after its inserts; the volume lane of a sequence moves it.

  **Freeze** (a pad's right-click menu) renders the pad's sound (its
  instrument through its inserts, before its fader, sends and pan) for
  each sequence it has notes in, once each, into the project's samples,
  then plays those instead, as an audio pad plays its takes. Its device
  and inserts leave the graph, CPU and all (a heavy plug-in or synth
  costs nothing while frozen); its fader, sends and output still work,
  and the tempo lane still moves it. Its device page says it is frozen,
  with **Unfreeze** (back as it was: its plug-ins' state is kept) and
  **Flatten to Audio** (an audio pad whose takes are the renderings).
  While frozen, editing its inserts changes nothing you hear. Freeze,
  Unfreeze and Flatten are each one undo step. Exports never have the
  metronome in them.

  A **Compressor** or **Gate** in a pad's insert or a bus slot has a
  **Sidechain**: it can listen to another pad's or a bus's output (after
  its fader) instead of what goes through it, as a bass ducking under the
  kick. The list offers only sources that can't make a loop: any other
  pad, or a bus the track doesn't feed (by its route, its sends or the
  buses after them). **Key high-pass** filters the key first (0 Hz:
  none), so a kick keys by its click, not its boom. **Listen** plays the
  filtered key on the track instead, to set it by. Keyed, the compressor
  only presses down: a quiet key lifts nothing.
- **Performance effects** (the Perform tab's right grid): 16 effects on main, each
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
  plays the song (with the toolbar's **Loop** on it goes round, otherwise
  it stops at the end). The song is **lanes of clips**: any sequence on any
  lane, from any bar and as long as you like, several playing at once (a
  drum sequence on one lane, a fill or a bass sequence on another). Coming
  to the Song tab folds the pads area to its bar of 16 pads (the song gets
  the height); leaving it unfolds it again.
  - **Down the left**, the sequences in use (and one empty one, for a
    new sequence), each with its colour, length, own tempo and how many
    clips of it the song has (the playing one lit). Drag one onto a lane;
    double-click it or its **+** to add it at the end of the first lane;
    click it to edit it; right-click for its commands (**Colour** among
    them: its colour shows on the launcher, the toolbar's list, the song
    and the Sequence panel).
  - **The bar above**: the **arrangement** picker (several songs from the
    same sequences, one current: Song mode and export play it;
    right-click it to add, duplicate, rename or delete one); the tools,
    **Select** (V) and **Draw** (B); **Snap** (Bar, Beat or Off; Shift
    while dragging snaps to the beat); **+ Lane**; **Merge into this…**
    (lays another sequence's notes and automation over the current one);
    **Tempo lane**; **fit** (Cmd+0); and the song's length in minutes and
    bars.
  - **Over the lanes**, the song's time: the **markers** (locators:
    double-click the strip for one at that bar, its name box opens; click
    one to go there, playing or stopped; drag one to move it; right-click
    to rename or remove it; **Alt+Right** and **Alt+Left** go to the next
    and previous), the **ruler** (click it to play the song from that bar;
    drag along it for the **loop range**, the bars the loop goes round;
    right-click it to loop one bar, go back to the whole song, add a
    marker or change the time signature there), the **time signature
    lane** (the song's from its start, and each change at the bar it
    starts: click one to pick another, double-click the lane for a change
    at that bar, right-click a change to remove it; the metronome, bars
    and the clock follow it), and the **tempo lane** (shown with **Tempo
    lane**, and anyway once it has points: double-click for a tempo point
    there, the first keeping the project's tempo at the start; drag a
    point in time and tempo; right-click one to make it **ramp** to the
    next or remove it). Without tempo points the song plays at the
    project's tempo. The markers, loop range and both lanes are each
    arrangement's own.
  - **The lanes**: each with its header (its name, Lane 1, 2... —
    double-click to rename it — and **M**ute and **S**olo) and its clips
    on a grid: a line every bar, every 2, 4, 8... bars as you zoom out (so
    the lines stay apart), and the beats too when zoomed in.
    **Cmd+scroll** zooms round the mouse; scrolling sideways (or
    Shift+scroll) moves along; the view follows the playhead. Lanes grow
    to fill the height; more scroll up and down.
  - **A clip** shows its sequence's colour, its name (and section),
    its notes along it, a notch where its sequence goes round again,
    hatched when muted (or its lane silent), outlined when selected. Click
    one to select it (Shift or Cmd: one more or less), drag empty space
    for a box; drag a clip to move the selection in time and across lanes
    (**Alt** as you start: copies); drag its **right end** for any length
    (it goes round its sequence, the last time cut short) and its **left
    end** to begin later or earlier (its notes stay where they were); all
    snapped. Double-click a clip to edit its sequence (the Sequence tab
    opens on it); right-click it for **Edit Its Sequence**, **Mute**,
    **Duplicate**, **Remove from Song** (the selection, when it is in
    it). With **Draw**, drag along a lane to paint the current sequence
    there (a click: its own length); with Select, double-click a lane for
    it at that bar. Cmd+C copies the selected clips and Cmd+V pastes them
    after the selection (or where the song plays), Cmd+D duplicates them
    after themselves, Cmd+X cuts them, Delete or Backspace removes them,
    Cmd+A selects them all.
  - **Under the lanes**, the selected clip's settings on one line: its
    sequence, a **section** name (shown on the clip), the **bar** it
    starts at and its **length** in bars (numbers to drag, scroll, or
    double-click and type), **Transpose**, **Mute**, and in **…** the part
    of its sequence it goes round (from which beat, how long; **Whole
    sequence**); duplicate, remove, and how long it plays.
  - Where clips overlap, all of them play. The playhead (and recording in
    song mode, and the Sequence panel following along) goes by the topmost
    lane's clip there; an audio pad's takes play from that clip only.
    Older projects' songs (a chain of steps) open as clips on Lane 1, one
    after another, their steps' tempos and time signatures in the song's
    lanes.

  In pattern mode, a sequence picked while playing takes over **at the
  end of the playing sequence**, **at the next bar**, **at the next beat**
  or **at once** — exactly there; the Sequence panel shows what comes next
  and when.

### The status bar

Along the bottom of the window:
- the audio engine: running or not, its device, rate and buffer (click
  for Settings > Audio);
- its load, a bar that warms as it fills, and the dropouts since start;
- MIDI in and out lights;
- the track selected, in its colour;
- the delay compensation (**PDC**), when effects add latency: every
  track is delayed to line up with the slowest (a strip's own is in the
  tooltip under its inserts);
- at the right, the newest message (click it for the recent ones, and
  to open the log file: every message also goes into `pads.log` in the
  settings folder, the one before kept as `pads.log.1` past 1 MB).

**Moving between pads**: the arrow keys move the selection, Left and
Right to the previous and next pad, Up and Down to the pad above and
below in the grid (on to the next bank at its edge). They don't while
typing, while the browser's list has the keyboard, or while the piano
roll has notes selected (its arrows move them). With the sequence editor
in front and nothing selected, Up and Down step to the row above or
below. A row's name, clicked, selects its pad too.

A pad given its first sound gets a colour of its own: the one fewest
pads have, and not its neighbours'.

### The Library's devices

The Library's Devices tab: the devices there are, in a tree (its search
box finds them by name).
- **Instruments**: Synth, Sampler, Slicer, Audio track, then the synth's
  presets by kind (yours too), then the CLAP instruments found.
- **Effects**: the synth's (Sound) and the rest (Rhythm and pitch).
- **Plug-ins**: the CLAP effects found (Settings > Plug-ins), by vendor.

Drag one onto a pad. An instrument becomes the pad's, and a preset loads
onto a synth (making the pad one). An effect goes in the pad's first
empty insert and opens in front. Double-click one to put it on the
selected pad. Each is one undo step.

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
  *armed*), and choose its **monitoring** (**Off** for a new pad, so a
  microphone near the speakers doesn't feed back): **Auto** (its
  input heard through its strip and effects while it is armed), **In**
  (always) or **Off** (you hear it on the interface; it still records).
  Use headphones. Every pad's strip has its audio input and monitoring
  (a menu, as Live's), whatever its device — sampling into a pad records
  its input — in the Mixer and in the bottom area, wherever you record
  from: for an audio track as above; for any other pad, Auto hears its
  input while you sample into it (straight to its bus), In always, Off
  never. **No input** (at the top of the menu): it records and monitors
  nothing, and stays so when the interface changes.
- Press **Record** (Cmd+R). After the count-in, if one is set, the input
  is recorded while the sequence plays; when you stop, each loop pass is
  a **take** of the track's part in that sequence, placed where it was
  played, over what was there: of several passes the last is heard, and a
  short punch replaces only what it covers. The earlier passes stay, to
  pick again. One undo step, **Record Audio**. With **Settings > Recording
  > Each pass onto a track of its own**, each pass after the first goes
  onto the next empty pad instead, an audio track lined up with it
  (doubling).
- The part loops with its sequence and follows the tempo (faster or
  slower; or, set to **Stretch** in the Audio tab, at its pitch, and
  transposed). Each sequence has its own: pick another sequence, or let
  the song move on, and the pad plays that sequence's, switching exactly
  where the sequences change.
- A sound file dropped on an audio track's row in the Notes grid is a take
  there, where it was let go (cut at the sequence's end).
- In the Notes grid an audio track's row shows its part as a condensed
  waveform. The Sample tab shows it too (**Edit**, or a double-click,
  opens the Audio tab); **Clear Take** empties it (Clear Pad empties every
  sequence's).

### The Audio tab

The Sequence view's third tab edits the selected audio track's part in
the current sequence, large. Nothing touches the recorded files: a part
is regions of its takes, and what plays is a mix of them made in the
background (each region over what is under it, crossing through its
fades) and kept by what went into it.

- **Click** a region to select it (its fades, gain and pan show above, to
  drag or type); a click also places the **cursor**. **Drag** a region to
  move it, its **ends** to trim it, the **squares at its top corners** for
  its fades. **Drag across empty space**, or **Shift-drag** anywhere, to
  select a range of beats. Moves and trims snap to the grid (Snap, the
  grid's menu; Cmd held: freely).
- The tools act on the range, else the selected region, else the whole
  part: **Split** (Cmd+T: at the cursor, or the range's ends), **Cut** (Cmd+X),
  **Copy** (Cmd+C), **Paste** (Cmd+V, at the cursor, on any audio track),
  **Delete** (the range goes silent; a region goes and what is under it
  plays again), **Crop**; on the region, **Normalize** (its loudest at
  0 dB, by its gain), **Reverse** and **Mute**.
- **Takes** lists the passes recorded: pick one for the range (comping a
  phrase from another pass), the region, or everywhere. **Spread Takes**
  puts each take after the first onto a track of its own, lined up.
  **Consolidate** writes the part as it plays into a new take (the older
  ones kept).
- **Repitch | Stretch**: how the part follows another tempo; Stretch keeps
  its pitch and can transpose it.

Audio is recorded in pattern mode (not while the song plays). A project
from before audio pads opens with every pad a sampler.

### Resampling and bouncing

- **Resampling.** An audio track's input menu also has **From a track**
  (another pad's output, after its fader), **From a bus** and **Main
  (resample)** (everything heard but the click; shown as *Main mix*). Arm
  it and record as from the interface: the take is lined up after the
  latency of the effects before the tap (a look-ahead limiter, a plug-in),
  so its hits land on the frames the sequencer played them. Such a track
  isn't monitored (you hear its source already, and it would feed main
  back into itself); its meter shows the source.
- **Bounce to Pad** (a pad's right-click menu; with several selected,
  theirs together; a bus strip's menu) renders the current sequence once,
  offline, with only those pads or that bus heard (after their faders and
  sends, before main's effects and fader), into a new sample on the next
  empty pad, named *Bounce A1*, *Bounce 2 pads*, *Bounce Bus A*. Main's
  menu resamples the whole mix (File > Resample Sequence to Pad).
- **Bounce in Place** (a pad's menu) renders the pad's sound (its device
  through its EQ and inserts, before its fader) in each sequence it plays
  in, as Freeze does, onto the next empty pad as an audio track with
  those takes, the pad's fader, bus, sends and cue, named *… (bounced)*;
  the pad is muted. One undo step.

Exports, freezes and bounces wait for samples and audio takes to be
loaded before they render (offline, nothing else waits for the disk).

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

- In the browser, **Alt+Enter** slices the selected file onto the
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
first tab) is laid out like the sampler's Sample tab: one line of tools,
the waveform taking most of the page, and the selected slice's settings
under it. The line (it wraps in a narrow window):

- **How it plays** (a dropdown showing Mono or Poly, and Thru and Gate
  when on): **Mono | Poly** (in Mono a slice cuts off the one before; in
  Poly slices ring together), **Thru** (a slice plays on to the sample's
  end), **Gate** (a slice stops when its key is let go, otherwise it plays
  to its end); **From** sets the base note; **Fade in** and **Fade out**
  (ms) shape every slice's ends, so cuts don't click; **Velocity** sets
  the sensitivity: 0% plays every hit equally loud, 50% follows how hard
  you hit, and above 50% makes soft hits softer still.
- **How it is sliced** (a dropdown showing the way): **Transients |
  Beats | Equal | Manual** slices it again, at its hits (with a
  sensitivity), on a grid of its tempo (bars, 1/4, 1/8, 1/16), or into
  equal parts. Editing a marker by hand switches it to Manual.
- The slice count, **Warp** (its settings behind the arrow, as on the
  Sample tab), the buttons below, and record.
- The waveform has a marker for each slice. Drag a marker by its numbered
  tag or its line, **double-click** between markers to add one, and
  **right-click** a marker to remove it (slice 1 always stays). Each slice
  has a gray **level line** with a handle: drag it up or down (-24 to
  +6 dB). Time or bars show along the bottom. The wheel zooms around the mouse,
  Shift+wheel pans, and the strip underneath shows the whole sample with
  the visible part as a window you can drag. However far you zoom, the
  wave is drawn at the screen's own resolution: a peak each pixel, read
  from peaks kept at every zoom (so it stays quick). Zoomed in past a
  sample a pixel, it draws the samples themselves joined by a line, and
  as dots when they are far apart. The Sample tab's and an audio take's
  waveforms do the same. Markers are placed in the
  sample, so they stay put when the sample is warped or stretched.
- Under the waveform, the selected slice: **play** it, and set its own
  **level**, **pitch**, **pan** and **Reverse**.
- The buttons after Warp: **Slices to a sequence** writes a new
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

Its device has eight tabs; **Modulate**, at the tab line's right, shows
(under the tabs, on every tab) the **sources**: E1–E6 (envelopes), L1–L8 (LFOs), R1–R4 (random), M1–M4 (macros), velocity,
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

## Plug-in instruments

A CLAP instrument found in Settings > Plug-ins can be a pad's device.
Drag it from the Devices panel (Instruments > Plug-ins) onto a pad. The
pad plays it chromatically, like a synth: its keys, Keyboard mode, the
piano roll and an armed track's MIDI play its notes. The wheels and
aftertouch reach it as MIDI.

Its page shows the plug-in, **Change instrument…**, **Open editor** (the
plug-in's own window, when it has one) and its parameters as knobs. A
plug-in with many parameters gets a box to find one by name. A knob shows
the value the plug-in has, so moves in its own window show there too.
Moving a knob is an undo step.

Right-click a knob to give it one of eight automation lanes (or to stop
automating it). The lane then appears in the sequence's Automation list
under that parameter's name. It runs 0 to 100 % of the parameter's range.
A plug-in pad's other lanes are volume and the EQ.

Saving keeps each plug-in's own state with the project: instruments and
plug-in effects, in inserts and bus slots. A plug-in that can't be found
says so on its page and plays nothing; the rest of the project plays.
Plug-in effects have **Open editor** on their pages too.

## The transport

The toolbar under the menus, always showing: what is needed while
playing. From the left: the tempo, Tap, the time signature, Count-in and
Click; the sequence, Pattern | Song and the position; then the transport
(centred on the window when there is room): play, stop, Rec, Loop, Auto,
Sample, how the pads play (**Pads**, **Keyboard**, **Vel**: as in the
bottom area's header) and Note Repeat. Play and stop are icons; the rest
are labelled lit buttons. A new project counts in a bar and clicks while
recording (the Click on, only while recording; both in the metronome's
menu).

- **Play** (green while playing) and **Stop**, or Space for both. Press
  **Stop** twice (or when stopped) to silence every sound still ringing.
  **Rec** (red whatever the accent, blinking while it records; Cmd+R)
  arms recording: from a stop it plays, after the count-in.
- **Sample** (beside Auto): recording a sample straight into a pad, from
  the pad, by the method its arrow chooses:
  - **Hold**: **Option-press** (Alt) a pad: it records the input while you
    hold it, and the take becomes its sample (Cmd-click still selects).
  - **Arm**: turn **Sample** on; the next pad you press (on the grid, its
    key, or from a MIDI controller) records while you hold it.
  - **Threshold**: as Arm, the sample starting where the sound first
    passes the level (its start marker 5 ms before, so the attack is
    whole; nothing kept if it never does).
  - **Bars**: turn Sample on; the next pad you press records the next 1–16
    bars in time, from the next bar's start (playback starts if stopped),
    and stops by itself: a sample exactly that many bars long.
  It records the pad's own input (as an audio track's: Global tab), moved
  by the device's latency like every take; Sample turns off after one,
  unless **latched**: Ctrl-click it (a right-click, or Cmd-click; or
  Latch in its menu) and it stays on for pad after pad, until a click
  turns it off ("Sample · latched"). The pad shows **REC** while it
  records, and clicking Sample stops it. An empty pad's page has a wide
  **Hold to Record** button: it records into the pad while you hold it,
  as Option-pressing the pad does.
- **Loop**: on, a sequence (or the song) goes round; off, it plays once
  and stops. **Count-in** (click for off, 1 bar, 2 bars; the button says
how many):
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
  after another. (When a sequence picked while playing takes over is set
  in the Perform tab: **End**, **Bar**, **Beat** or **Now**.)
- **Tempo**: drag it (right or up) to change it by 1 BPM, with **Shift**
  by 0.1; scroll it; double-click to type it. **Tap** in time to set it: it
  flashes with each tap, and the fourth starts playback a beat later,
  where a fifth tap would land, flashing on the beats until then (playing,
  taps only change the tempo; a pause of 2 s starts again). The **time signature** (4/4, 3/4, 6/8... or
  any beats and unit) sets a bar's length: sequences' bars, the grid's
  bars, the metronome's accent, exports.
- The **metronome** (**Click**): on/off, and (the arrow) its level, its sound
  (**Beep**, **Wood**, **Stick**, **Cowbell**), **Accent the bar** (the
  bar's first beat higher), **Only while recording** (and counting in),
  and the count-in. Saved with the project.

Elsewhere, near what they change:
- **Play modes** (at the right of the pads area's header): the pads as
  pads, as a keyboard of the selected pad, or as it at 16 velocities — as
  on a pad's MIDI page.
- **Input quantize** (the magnet in the Sequence view, beside its
  **Quantize**): on, recorded notes move toward the grid shown beside it;
  the arrow sets the grid (1/4–1/64, triplets), the **strength** (100%:
  onto the grid; 50%: half way) and **swing** (the grid's off-beats
  pushed later).

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
**MIDI out** (a pad's MIDI page: on, channel, note, and its own output port)
goes out; the status bar's MIDI lights do the
same for all MIDI.

**Arming**: every strip has **R**, and an armed pad a red dot. Selecting a
track arms it, and the one armed before by selecting goes back (Settings >
Recording turns this off); click R to arm only that track, or Cmd-click
to arm more (those stay armed when the selection moves). An armed audio
track records its input when you record (and monitors it: **Auto**,
**In**, **Off**); an armed sampler track plays its own port's notes and
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
plug-in list (`plugins.ini`) and window layout (`layout2.ini`) sit beside
it.

- **Appearance**: the theme (Dark, Light, Midnight, Graphite, Paper, and
  your own), every one of its colours (click a swatch), **Save as
  preset**; the **zoom** (50–300%: everything drawn larger or smaller, as
  a browser zooms); the **control size** (Auto, Compact 28 pt,
  Comfortable 34 pt, Touch 44 pt: how tall buttons and fields are; Auto
  is Comfortable in this layout); the pads' waveforms; whether the layout is
  remembered, and **Reset layout**.
- **Audio**: the **driver** where there is a choice (WASAPI or ASIO on
  Windows, ALSA or JACK on Linux; one not built in or not installed is
  greyed with why; switching opens its default devices at once, kept with
  **Keep** or back in 10 s), the output and input interfaces (on macOS an
  input and output on different devices just work: one aggregate made of
  the two), sample rate and buffer
  size (what each interface offers), then the interface's **channels**,
  inputs and outputs side by side: each one a switch, its number, the
  interface's own name for it (CoreAudio, ASIO and JACK give names;
  WASAPI and ALSA only numbers) and a name of yours to type (it shows
  wherever the channel does). **All** and **None**; a level meter beside
  each open input, and **Test** beside each open output pair (a second
  of tone, to find which speaker it is). **Main output** is the pair main
  plays on (its switches stay on); **Cue output** a pair for a
  headphones mix: a copy of main, each track's **cue send** (the strips
  show one while a cue pair is set) and the click, at its own level, with
  **Click on the cue only** to keep the click out of main. Each interface
  keeps its own channels, names and pairs (in settings.ini, a section
  each), so switching interfaces and back puts them back. What isn't
  there says so: an interface not connected plays through the system's
  until it is back (plugged in again, Pads switches back to it and says
  so; the device lists follow what is plugged in); a channel it no longer has is left out (kept, with
  **Forget them**); main on a pair that isn't open plays on the first
  open one; the settings and the project keep everything for when the
  hardware is back. A pad whose input isn't on the interface (another
  one is, or the project came from elsewhere) takes the next input (pair)
  there is, round to the first (not an edit: the device decides it). Changes wait for **Apply**,
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
  an 1/8). **Timing**: the device's latencies (in, out, the round trip),
  and the **recording offset** (frames, either way). Every audio take (an
  audio track's, a sample recorded onto a pad) is moved earlier by the
  round trip plus the offset, so it lines up with what you heard when you
  played it; every hit you play (pads, MIDI) is recorded earlier by the
  output latency, for the same reason (a MIDI effect's notes, made on the
  engine's grid, are not moved). Measure the offset once with a loopback
  cable if your interface's takes land late or early.
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
samples, sequences, song, mixer, MIDI map and settings) and its audio
in `Samples/`, by where it came from: `Imported/` (files brought in, copied
there), `Recorded/` (sampled into pads, audio tracks' takes) and
`Processed/` (bounces, freezes, consolidations, edits' results, exports to
a pad). Every new file gets a name no file there has: nothing is ever
written over. `cache/` holds what can be made again (warp and comp
renderings): deleting it is safe. Closing a project trims it: what the
project plays stays, and of the rest the newest 1 GB. A project moves as one folder, between
systems too (its paths are stored relative, with `/`).

Projects from before keep their `samples/` folder: it still opens, and
new files go to the new folders.

Projects saved before there were 128 pads open with their 64 pads in
banks A–D, and keep their own MIDI map (where key 36 played A1).

- **MIDI files**: **File > Import MIDI File…** reads one into the
  current sequence as General MIDI drums (key 36 is A1). Dropping a .mid
  on a pad (from the Finder or the browser, which lists them) puts its
  notes all on that pad, pitched; dropped on the window, it goes in as
  drums. **Export Sequence as MIDI…** and **Export Song as MIDI…** write a
  track a pad, named after it, on General MIDI drum keys (the song: its
  steps in order, with their repeats, parts, transposes and tempos).
- **File > New** (Cmd+N), **Open…** (Cmd+O, a folder), **Open Recent**
  (the last 8, kept in the user's preferences folder), **Save** (Cmd+S),
  **Save As…** (Cmd+Shift+S: a name and a place; it becomes the folder
  `<name>.pads`, its files copied there, each at the same place in the
  folder; a file from outside the folder goes into `Samples/Imported`), **Rename Project…** (its
  folder renamed beside where it is).
- Everything a project holds is saved with it: every pad's and track's
  settings, devices, inserts and sends, the buses and performance
  effects, the sequences and the song, the synths' patches and their own
  wavetables, the transport. How the app was left is saved too: how the
  pads play (and Keyboard mode's scale, root, octave and chord), the bank
  and pad selected, and the sequence pads' bank. A test sets every
  setting to new values, saves, loads, and checks each one came back.
- A project saves when you save it. The window's title shows the
  project, with a dot while it has unsaved changes. Quitting, closing
  the window, **New**, **Open** and **Open Recent** ask first when there
  are changes: **Save**, **Don't Save** or **Cancel** (an untitled
  project's Save asks for its name and place, then goes on). Opening a
  project starts a new undo history; **Edit > History** lists its steps,
  newest first, with any undone ones above. Choose one to go back to
  just after it, or forward to an undone one.
- **Templates**: **File > Save as Template…** keeps a copy of the
  project, its samples with it, in the settings folder's `Templates`.
  **File > New from Template** starts a new, untitled project from one
  (asking first if there are changes).
- **Autosave** (Settings, every minute to start with) keeps a backup of
  unsaved changes beside the project, in its folder's `.autosave/`; the
  project itself stays as last saved. If Pads stops without closing (a
  crash, power lost), the next start offers to **Recover** them, or
  **Discard** them. Recovered changes are unsaved until you save.
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
plugin_pad PAD PATH ID                       pad PAD (0..) plays CLAP instrument ID (selected)
group PAD... [as NAME] | group fold B | unfold B | ungroup B   pads (0..) under a new group bus (B: 1..)
sidechain PAD SLOT pad N | bus B | off [listen] [hpf HZ]   pad PAD's insert SLOT (0..) keyed from pad N or bus B (0..)
plugin_editor open|close / plugin_lane LANE PARAM   its window; lane LANE (1..8) moves parameter PARAM
expect plugin loaded|failed|editor|no-editor
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
song add SLOT [REPEATS] | mode on|off | loop on|off | clear | step STEP
song tempo BEAT BPM [ramp] | meter STEP NUM DEN | marker BEAT NAME | range START END | range off | jump MARKER
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
| `test_browser.py` | the tree (click, double-click), back/forward/up and the path, keys, favourites (star, pills, right-click), search, the preview's buttons, loading onto the selected pad or the next empty one (Shift+Enter, the foot's buttons), dragging files and search results onto pads |
| `test_pads.py` | pads by mouse and keys, banks, playback (modes, Reverse) and the Global tab (knobs, Clear Pad, undo), the Sample tab (edits, chop, stretch), files dropped from the desktop |
| `test_sampling.py` | a sample recorded into a pad by Option-press (Hold), and by the Sample control armed (Arm): the take on the pad, the control disarmed |
| `test_audio.py` | a pad made an audio track (input, monitor, undo), arming (Global tab and the strip's R), recording a take from the fake device's input, Clear Take |
| `test_devices.py` | the bottom panel as a device view: a pad's chain (sampler, EQ, inserts added with +), a bus's chain from the mixer, a performance effect, a pad chosen again |
| `test_devices_panel.py` | the Library's devices: an effect, a synth and a preset dragged onto pads (one undo step), found by typing; the sequence pads launched (at Now), held (its column back to what it had when let go), their banks |
| `test_app_gaps.py` | the arrow keys moving between pads; Keyboard mode opening on C3's bank and bank A at C-2; the status bar; Edit > History jumping back and forward; MIDI exported and read back; new pads' own colours |
| `test_fx_views.py` | effect pictures: a filter's response dragged, the dynamics' curve and gain reduction meter, delay, reverb, comb, chorus, cutter, pitch, bit-crusher |
| `test_device.py` | the device tabs (Transpose in whole semitones on a sampler and a slicer): the amp envelope's handles, the filter's type, slope and response handle (and the live cutoff above the setting while its envelope opens it), the pitch envelope, an LFO routed to the cutoff, Global, an audio pad's tabs; legato chosen, its glide dragged, Always set and undone |
| `test_sample.py` | the Sample tab's wave: S and E dragged by their tags, the fade handles (and undo), the playhead while it plays, the bottom panel's channel strip |
| `test_commands.py` | the menus made from the command list (a pad's, a note's, a song step's, an effect slot's, a bus's, a knob's), the palette on the selection, commands by id |
| `test_song_lanes.py` | the Song tab's lanes: the pads area folded while it shows; sequences dragged from the list onto a lane (and double-click, +); clips moved across time and lanes, Alt-dragged copies, their ends dragged (the left end keeping the notes in place); painting with Draw, double-clicking a lane, a box; Cmd+C / Cmd+V / Cmd+D / Cmd+X, Backspace, Cmd+A, a clip's menu; lanes renamed, muted, soloed; the clip strip (section, transpose, mute); Cmd+scroll zoom and fitting; the ruler playing from a bar; arrangements; a sequence's colour |
| `test_note_keys.py` | the editor's keys on selected notes: Backspace, 0 to mute and unmute, Cmd+A, the arrows (a step, a bar, a row), Cmd+D; the toolbar's Pattern / Song, the launch setting (in Perform) |
| `test_tracks.py` | arming follows the selection (Cmd-click arms more, the setting off); a track's MIDI input chosen on its strip, an armed track played by its own port; the input meters |
| `test_settings.py` | the Settings window: theme and zoom (clicks still land, zoomed), a shortcut pressed in (and a clash taken), audio applied and kept, the tempo following MIDI clock and the clock out, a new project's defaults from settings.ini (a hand-written comment kept), plug-ins scanned and offered |
| `test_synth.py` | a pad made a synth from its menu and played; Keyboard mode's banks moving the notes, a key recorded at its pitch; a source dragged onto a knob, its ring's handle dragged and right-clicked away (and undone); the envelope's attack handle and an LFO point drawn; a wavetable chosen; legato and oversampling; the effects chain (an effect switched on, dragged to the front, undone); a random modulator (its style, dragged onto a knob); the wavetable editor (a new table, a harmonic dragged, a keyframe added and undone); presets (stepped through, chosen, saved as yours and found again) |
| `test_reaudit.py` | what the UI re-audit fixed: Escape closes Settings; another pad selected shows its sound, not the MIDI page; the slicer's settings behind its two dropdowns; a 1100×760 window keeping the toolbar and the mixer's strips whole |
| `test_slicer.py` | slicing from the browser (Alt+Enter, Cmd+Shift+Enter, the file's menu, Alt-drag, an empty pad's Slicer half); an empty slicer filled by a drop; markers dragged, added and removed; a slice's level line; zoom and the overview; slices to a sequence and to a pad; the piano roll's slice rows; Keyboard mode playing slices; back to a sampler with the slices kept |
| `test_tweaks.py` | several pads selected (Shift, Cmd) muted, choked and cleared; the choke group in the Sample tab; Stop twice; Settings; a sample dropped on a sequence row; the lane's height; renaming the project; buses added, renamed and routed, several strips moved at once; a pad's warp |
| `test_sequence_tabs.py` | the Sequence view's Notes (the default) and Automation tabs, the tab kept while moving around and saved with the project; Line and Curve; a new automation from the menu; the notes under the curve off and on; a drawn note at 100% chance; a CC lane drawn for the selected pad |
| `test_automation_targets.py` | a mixer fader's right-click Automate, Touch a control learning a knob, knob moves recorded only with Auto on |
| `test_automation_draw.py` | automation drawn freehand, as a Shift line, bent with Ctrl, swept with Erase; the Snap toggle |
| `test_layout.py` | the default window at the Comfortable size (the other tests run at Compact, `--control-size compact`, the size their positions were written for): the pads area folded to a bar and unfolded by a pad and by its button, one search finding a file and a device, Cmd+L, the control size in Settings |
| `test_audio_channels.py` | an interface's channels in Settings > Audio (the test interface, --fake-interface): channels on, one named, the cue pair, Apply and Keep, what opens, a track's inputs by name, the interface gone at the next start |
| `test_freeze.py` | Freeze from a pad's menu (rendered, played instead), Unfreeze from its page, undo, Flatten to Audio |
| `test_audio_edit.py` | the Audio tab by mouse: a take, a click (cursor and region), Split, a Shift-dragged range deleted and undone, a region moved, its fade handle, Copy and Paste, Normalize, Reverse, Consolidate, the region's gain typed, a take picked |
| `test_repeat_toolbar.py` | the toolbar's Note Repeat: on and off, its rate from its dropdown, Quantize's grid with it |
| `test_track_loop.py` | per-track loops: a row's menu giving the kick 3 beats, off, undo; an audio track's loop typed in the Audio tab |
| `test_vertical_zoom.py` | the Sequence view's vertical zoom: Cmd+wheel over the rows, the Rows control dragged, back to fit |
| `test_tweaks2.py` | a new project's count-in and click; Monitor from both strips; the toolbar's play mode; the sequence's arrows; Sample latched (right-click, Cmd-click) and on after a take; Hold to Record |
| `test_resample.py` | an audio track's input from main, a track and a bus; Bounce to Pad of a pad, of two selected, of a bus; Bounce in Place, undo |
| `test_groups.py` | track groups: pads selected and grouped with Cmd+G (named), the tab folding them away and back, Ungroup, undo |
| `test_sidechain.py` | a loop's compressor keyed from the kick (the list without its own output), Listen, undo |
| `test_song_time.py` | the song's time: a loop range dragged on the ruler, a marker by double-click (named), Alt+arrows to markers, a time signature change on its lane, a tempo point on the tempo lane, undo |
| `test_note_tools.py` | the editor's tools: a row's name (its pad, its notes, the headphones; Delete on the selection), Draw painting and Erase sweeping (one undo step each), Move and Alt-copy, V/B/E/M, a row's Rename, the piano roll and Fold |
| `test_sequences.py` | renaming (double-click, F2, undo), Duplicate (menu, Cmd+D), own tempo, the Copy Bars dialog, a marked part copied and pasted |
| `test_sequencer.py` | play/stop and Space, the metronome, notes by clicking the piano roll (and right-click, undo), ×2 and clear, recording from the pad keys, the lanes |
| `test_live.py` | the sequence pads (launch when stopped, queue to the end of the playing pass, the cell's menu), performance effects as hard as pressed and their Intensity knob, the toolbar's play modes |
| `test_lanes.py` | launcher lanes: one renamed from its header, one added (the window following) and a sequence made at its end, sequences moved by menu and Option-drag, the overview moving the window, a lane deleted, undo |
| `test_perform_view.py` | the Perform tab: the pads area folded (and kept so from Song), a row launched (its columns together), a column stopped and launched again, Stop All, Shift-click launching alone, Continue, Option-click not launching, Record to Song writing the launches into lanes, the main fader |
| `test_mixer.py` | a strip per pad with a sound, faders, mute/solo, pan, sends (drag across, double-click, pre-fader; with the inserts and EQ toggled off), outputs, inserts, the EQ display and switch, the I/O rows, the peak readout; the toggles (narrow, a section off), main's meters (integrated reset, correlation, stereo, folded and back); two strips coloured at once; the buses against main |
| `test_perform_song.py` | a pad's MIDI page (play modes, its note repeat and arpeggiator), holding performance effects, the song and its switches |
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
