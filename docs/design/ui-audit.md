# Pads UI audit (step 1 of the interface redesign)

Status: draft, for review. The list of tasks and the click counts are
what the code and screenshots suggest; correct them where your own use
differs, since they decide which sections are redesigned first.

Screenshots: run the tour and look in `.build/ui_audit/shots/`
(1440x900 logical, dark, then light and 1100x760):

```bash
task app:pads
.build/app/pads --headless --fake --prefs .build/ui_audit/prefs --drive tests/app_ui/drive/ui_audit.txt --out .build/ui_audit/shots
```

## The layout now

```
+--------------------------------------------------------------------------+
| Menu: File Edit Sequence View Help                                        |
| Toolbar: transport, position, sequence, Pattern/Song, launch, BPM, Tap,   |
|          meter, count-in, automation, quantize, pad/keys/levels views     |
+-----------+--------------------------------------------------------------+
| Browser | | Sequence | Song | Mixer | Perform        (one at a time)      |
| Devices   |                                                              |
| (tabs)    |                     about 45% of the height                  |
|           +--------------------------------------------------------------+
|           | "A1 kick · Sampler" | EQ | +        (the selected pad's chain)|
|           | Bank A-H | Sample Env Filter Pitch LFO Global    | strip     |
|           | 4x4 pads | (the device's page)                   | (fader)   |
+-----------+--------------------------------------------------------------+
| Status: audio, CPU, MIDI in/out, selected pad, last message               |
+--------------------------------------------------------------------------+
```

The bottom half (pads, device, channel strip) is always there; the top
half shows one of four views.

## The tasks you do most, and what they take now

Clicks are counted from a project already open with the pad selected
where it says so. These are estimates; please correct them.

| # | Task | How now | Clicks, views |
|---|---|---|---|
| 1 | Put a sample on a pad | Drag from the Browser onto a pad | 1 drag; must find the file in a narrow tree |
| 2 | Hear samples before choosing | Click a file (auto-play), or the play button under the tree | 1 per file |
| 3 | Program a beat | Sequence view, pencil tool, click cells | 1 + 1 per note; rows A12–A16 are off screen at 900 px |
| 4 | Record a beat live | Record, play pads (mouse or keys), stop | 2 + playing; count-in is an unlabeled icon |
| 5 | Shape a sound | Select pad, pick a device tab, turn knobs | 2 + knobs; a synth's second knob row is cut off at 900 px |
| 6 | Chop a loop | Select pad, Sample tab, Transients/Equal, Sensitivity, Chop | 4–5 |
| 7 | Balance the mix | Mixer view (the sequence goes away), faders | 1 + faders; 4 pad strips, then a wide gap, then buses |
| 8 | Add an effect | Mixer view, an empty insert slot, choose | 3; slots are blank boxes with no "+" |
| 9 | Make variations (new sequence) | Toolbar sequence menu, or Perform's "+ New", or Song's list | 2; three places do it |
| 10 | Arrange a song | Song view, Add Sequence, set repeats, Pattern/Song switch | 3+ per step |
| 11 | Perform (launch sequences, FX) | Perform view | 1 + pads; the Seq names are cramped |
| 12 | Export | File > Export or Cmd+E, dialog | 2–3 |

## What the screenshots show

### Whole window
- **"Devices" means two things**: the left tab is a library of
  instruments and effects to drag onto pads, while the bottom panel (named
  Devices in the code and the docs) is the selected pad's chain. The
  library sits apart from the Browser, which is also a library.
- **The bottom half is fixed at about 45%**, whatever the top view is.
  The Mixer and Song views, which need height, get about 600 px, while
  the pad grid repeats what the sequence rows already show.
- **The toolbar has 20 controls, most of them icons with no labels**
  (count-in, automation write, the three view icons on the right). At
  1100 px wide the right end is cut off.
- **The same choice is in two places**: Pattern/Song in the toolbar and in
  the Song view; when sequences change ("Sequence end") in the toolbar
  and "at End/Bar/Beat/Now" in Perform; a new sequence in three places.
- **Toasts stay long and cover the channel strip's routing buttons**
  (bottom right), the one place they hurt.

### Sequence
- Two rows of controls above the grid (length, ×2, grid, Quantize,
  Swing, 1/8 vs 1/16 swing, lanes, delete; then tools, Drums/Piano roll).
  The "1/8 | 1/16" next to Swing reads like a second grid setting.
- Empty pads take as much room as used ones; only 11 of 16 rows fit.
- The velocity lane is large and always open.

### Pads (the 4x4 grid)
- On a loaded pad, the note label (C-2 · 0) is drawn over the waveform
  thumbnail and is hard to read; the M/S buttons and the armed dot
  crowd the bottom edge.
- Empty pads show note name and number, which say little before a pad
  has a sound; there's no hint that you can drop a file there.
- An empty pad's device page says "No sample on A1" with nothing to click
  next (no browse or record button).

### Device pages
- Sampler: the Sample page is dense but works; its chop tools are a row
  of unlabeled icons.
- Synth: 30 modulation chips (E1…Rnd) on every page, and the Mod page
  repeats them as big buttons; the oscillator page's second knob row is
  cut off at 900 px, with no sign that it scrolls.
- The preset bar (synth) is far right, away from the device name on the left.

### Mixer
- 4 pad strips, a wide empty gap, 4 bus strips, then main. Faders are
  short (about 80 px) in a tall panel; insert slots are blank boxes.
- Sends A–D are rows of tiny knobs labeled with a letter only.
- Each strip's colour bar is at the very bottom, cut by the panel's edge.

### Song
- Three areas (timeline, the list of sequences, the step's settings) but
  the step inspector is mostly empty; "1 bar ×8" in the list and
  "×4 · 4 beats" on a step say the same kind of thing two ways.

### Perform
- Four columns of controls at the same weight; the sequence slots' two
  text lines overlap ("Seq 13 / empty"); FX pads' two lines nearly touch.

### Light theme and narrow window
- Light theme: colours hold up; the waveform thumbnails on pads look
  washed out.
- 1100x760: the toolbar is cut off, the sequence shows 4 rows, and the
  device page needs arrows to reach its tabs.

## Answers (2026-11-12)

- **All the tasks matter, in an order that loops**: find source material
  (samples, sounds) → play, record or program it into sequences →
  arrange the sequences into a song; round again until the song takes
  shape, with mixing done along the way. A performer instead launches
  sequences live, like a DJ, and the order changes.
- **The Sequence view is open most of the time.**
- **Input**: keyboard and mouse today, but most people will use a hardware
  controller, and on touch devices (an iPad) touch will be the main way
  to play.
- **Screen**: a laptop, about 1440x900. Everything has to fit there
  without scrolling.

## What this means for the design

1. **Sequence is home.** Browsing, playing, shaping and a quick mix are
   reached from it without leaving it (a side panel, a drawer, a pop-over),
   not by switching to another full view. Song and Perform are the other
   two places you work; the Mixer can be a drawer over them.
2. **The flow is a loop, not a set of tabs**: source → sequence → song,
   and back. The layout should make the next step one click from the
   last, and show where you are in it.
3. **The on-screen pads are a display first** (with a controller), **an
   instrument on touch**. On a laptop they can shrink to a strip or hide;
   on touch they need to be big. So the layout needs a compact and a
   large form of the pad grid.
4. **Touch later means targets of at least 44 pt, nothing that only works
   on hover, and drags that also work as taps** (choose, then place).
   Designing for it now costs little and avoids a second redesign.
5. **1440x900 is the design size.** Every view is checked there first
   (and at 1100x760, the smallest supported), then on a large monitor
   for extra room.
6. **Two kinds of user, two starting layouts**: a producer starts in
   Sequence; a performer starts in Perform. A layout choice (or a
   remembered last view) covers both.

## Window layout: decided (2026-11-12)

Three layouts of one window, switched from the toolbar (and a shortcut);
each remembers its own panel sizes.

- **D, the default: today's layout, tidied.** The four views (Sequence,
  Song, Mixer, Perform) on top; one library on the left (the Browser and
  the Devices tab merged); fewer toolbar controls; the bottom half (pads
  and the pad's sound) folds to a bar so the views get the height.
- **B, Pads first**: big 4x4 pads and the pad's sound beside the
  sequence, like a groovebox; the library and the mixer slide over as
  drawers. For playing by hand and for touch.
- **C, Stages**: one step of the loop at a time, each laid out for its
  job: **Find sounds, Sequence, Arrange, Mix, Perform** (five stages;
  Mix and Perform are separate). A stage bar shows them in order; the
  pads strip and the transport stay on screen in every stage.
  - Find sounds: the browser large, preview in time, chop, drop or tap
    onto a pad.
  - Sequence: all 16 rows (or the piano roll), a lane below, the pad's
    sound beside it.
  - Arrange: the song timeline tall, sequences dragged in from a list;
    double-click one to open it in Sequence.
  - Mix: every strip with full-height faders, the selected strip's
    effects beside them.
  - Perform: large launch and performance-FX pads, note repeat and arp,
    main and cue levels.

### Layout D in detail: decided (2026-11-12)

- **One library, one tree with sections**: Favourites, Folders (the
  Browser's places and files), Instruments, Effects (with plug-ins),
  Project. One search filters the whole tree; the preview player stays at
  its foot. Dragging (or choosing, then tapping a pad) works from every
  section.
- **Toolbar: the playing essentials, labelled**: play, stop, record, loop,
  position, the sequence, Pattern | Song, tempo and Tap, meter, click and
  count-in, the layout switch (D | B | C), CPU. Everything else moves to
  the view it belongs to:
  - when sequences change (launch quantize): Perform only;
  - automation write: the Sequence view's lane;
  - note-input quantize: the Sequence view, beside the grid setting;
  - the pad, keyboard and levels view buttons: the bottom area's header.
- **Folding the bottom area**: a Fold button in its header (and a
  shortcut). Folded, it is a thin bar of the 16 pads only (name and
  colour, a light when it plays); clicking a pad selects it and unfolds
  on it.
- **Sequence rows: as now** (all 16, the same size), with the time and the
  room the folded bottom gives back.
- Pattern | Song leaves the Song view (it is in the toolbar).

Changed later (2026-11-12): the Library keeps two tabs, **Browser**
(Favourites, Folders, the preview) and **Devices** (Instruments, Effects,
Plug-ins), each with its own search, instead of one tree for both.

### Find sounds: decided (2026-11-12)

- **Option A, the Library's rows**: each sound's row shows its length
  (a loop's in beats once its tempo is known is a later step); no
  separate Sounds view.
- **Auditioning**: a sound plays as soon as it is selected (with the
  mouse or the arrow keys), straight away, as auto-play does now.
- **Loading without dragging** (Enter, a double-click, or the buttons at
  the Library's foot): onto the **selected pad**; with **Shift**, onto the
  **next empty pad**. The foot names where it goes ("To A3", "To next
  empty: A5").
- Preview-and-chop before loading (option B) was not chosen: chopping
  stays on the pad's Sample page.

## Order of the redesign

1. **The window layout**: Sequence as home, where the browser, device
   and mixer go, the compact and large pad grid, the two libraries made
   one.
2. **Design system**: spacing, sizes (touch targets), text, colour, one
   set of controls.
3. **Toolbar**: what's needed while playing, labels, no duplicates.
4. **Source material**: browser, preview, putting sounds on pads, chop.
5. **Sequence**: rows that fit, the lanes, recording.
6. **Pads and device pages**: shaping sounds.
7. **Song**, then **Perform**, then **Mixer**.
