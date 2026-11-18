---
title: Push 2 in Pads
description: A native-feeling Ableton Push 2 in Pads - the kit's anti-aliased drawing and TrueType text, Pads drawing its own views for the display, and the Push 2 surface's modes, in stages.
---

Ableton Push 2 works in Pads today through fire-surface's example
(`push2_odin`): its display over USB, pads, encoders and buttons, in any
host with `fsurf.daw`. This is the plan to make it feel native in Pads:
its modes laid out on the display as Live does, with Pads' own views
(the sequencer, the sound editor, the mixer, waveforms, the browser) and
Pads' look.

Choices made (2026-11-16): Open Sans the kit's default font; every view
of Pads' (sequencer, device, mixer, clip, browser); every mode (Mix,
Device, Note/Scale, Session, Browse, Clip).

## Pads' panel on the display (2026-11-16)

The display mirrors Pads instead of a layout of its own, so a Pads user is
at home on the hardware:

- **Device** is Pads' device panel itself (`View_Kind.Device`): the device
  and tab the window shows, drawn by Pads for 960 x 160 (`ui_ctl.odin`):
  its tabs on the upper row, its picture, its knobs one an encoder (more:
  pages, Page < and >), its choices on the lower row, the pad's meters at
  the right. One state: a tab or device chosen on the Push is the
  window's, and the other way round. Device pressed again: the next
  device in the chain (MIDI, the instrument, EQ, the inserts).
- Every device: the sampler (and slicer, audio pad), the synth's eight
  tabs, plug-in instruments, the EQ, the MIDI effects, every effect slot
  (an empty one: choose an effect, Add); an empty pad offers Browse,
  Record (held), Audio, Synth, Slicer; Global and the synth's Global:
  Clear Pad (Delete held + a pad clears it too).
- The encoders turn Pads' own knobs (`ui.Knob_Input`): undo, automation
  and modulation as with the mouse; a touch is one step.
- **Dialogs**: every modal goes through `modal_begin`; its words and buttons
  (`modal_text`, `modal_button`) show on the Push over any mode
  (`View_Kind.Dialog`), its choices on the lower row. One to type into is
  named, with "answer it on the computer".
- Mix and Session's two pad modes show the window's mixer, pads or
  Performance view as they're chosen.
- **Clip** is Pads' Sequence panel (`View_Kind.Sequencer`,
  `ctl_sequencer`): the same rows (pads, Piano, Fold), notes, selection
  and grid. Encoders: rows, the note selected (in time), its velocity,
  length, position, row and chance, the grid; the lower row: Piano, Fold,
  Mute, Duplicate, Delete. Automation and Audio: in Pads for now.
- **Browse is the Library** (`ui_library.odin`: one model, the window's
  Library and the Push's display alike): its categories (each favourite,
  Files, Drives, Projects, Recent, Templates, Instruments, Synth Presets,
  Effects, Plug-ins), the category's list, the selected item's actions,
  the preview.
  - On the Push, three parts: the categories (encoder 1; Back and Up
    above, Forward and Favourite below), the list (encoder 3 a row, 4
    eight; the actions on the four buttons above and below it), the
    preview (Play and Auto-play above, Sync below, encoder 7 its volume;
    a device's words instead).
  - A sample: Sampler, Slicer, Slices → Pads, Synth Osc above; Next Empty
    below. A folder: Open, Kit → Bank (its samples onto the bank's empty
    pads), Favourite. A MIDI file: Notes. An instrument or preset: Load.
    An effect: Insert. A project: Open; a template: New (both through
    the unsaved-changes dialog).
  - Shift + a grid pad (Pads mode, browsing): the selected item onto that
    pad, as the last load did (`ui_library_load`).
  - **This Project** (a category): Save, Save As… (by name, into the
    projects folder: the name editor), Rename…, New Project, Save as
    Template…, Clean Up…, Export Audio (the sequence or song as a WAV in
    the project's Exports). Every dialog these open is answered on the
    Push.
  - **Browse from Device:** Browse pressed while Device shows a device
    opens the Library for it: a sampler's or slicer's samples (Sampler or
    Slicer lit), a synth's presets (Load), an effect slot's effects
    (Insert replaces that slot's effect), an empty pad's instruments.
  - A category by name: `ui_show` "library Effects", "browse device".
- **Shift + Record saves** from anywhere (`project_save_quick`): an
  untitled project goes into the projects folder (the "project.folder"
  setting, else Documents) as the first free "Project N".
- **Messages on the display:** Pads' newest message (a toast: saved,
  loaded, an error) as a banner over every view for two seconds; a dot in
  the top right while the project has changes not saved.
- **The name editor:** a dialog with a text field (`modal_input`: rename a
  pad, a sequence, a bus, the project, a lane, a marker, an arrangement;
  save a preset or a template) is typed on the Push. Encoder 1 moves the
  cursor (past the end: a new letter), encoder 2 turns the letter; the
  upper row: Delete, Space, Caps, Clear; the dialog's buttons below.
- **Session → Perform** (`surfaces/push2/perform.odin`, `ctl_perform`) is
  Pads' Perform tab, its state shared with the window's (launcher window,
  Hold, FX Latch, Keys: `pads_core` `launch.odin`, the API's
  `launcher_view`, `launcher_press`, `effect_press`...).
  - The grid in four quarters:
    - bottom left: the launcher's window (4 lanes × 4 rows);
    - bottom right: the pads' bank of 16 (played through their notes);
    - top right: the 16 effects (held, or latched; pad pressure is how
      hard);
    - top left: the Perform bar (lane stops; End / Bar / Beat / Now;
      Launch / Hold / Continue / Rec; Stop All / FX Latch / + Lane /
      Keys).
  - Modifiers on a sequence pad: Shift launches it alone, Select goes to
    it, Delete clears it, Duplicate copies it. Select on an effect shows
    it in Device.
  - Scene buttons launch the rows shown; Up/Down move the rows, Page < >
    the lanes, Octave the pads' bank.
  - The display: the 4 lanes (names above: their sequence in Clip; Stop
    below), the effects' legend, Main and Cue, the bar's settings lit.
    Encoders: 1 lanes, 2 rows, 5 the last effect's strength, 7 Main, 8
    Cue.
- **Note** is Pads' Keyboard play mode (either way: chosen in the window,
  the Push follows): 64 keys, 0 at the bottom left along each row, each
  playing the selected pad as that key of Pads' keyboard does
  (`perform_play_key`: chords, slicers); roots in the pad's colour, the
  rest dim, out of range dark. Octave Up/Down: Pads' keyboard octave.
  Layout keeps the drum pads.
- **Mix** is the window's mixer strips (`View_Kind.Mixer`, `ctl_mixer` in
  `ui_ctl_mixer.odin`), drawn and driven by Pads like Device: the
  selected pad's eight (Page < >: the eight before or after), each with
  its readouts, fader filled in the pad's colour, dB scale, stereo meter,
  pan, M (yellow), S (blue), R (red) and name plate.
  - Upper 1 steps the encoders' page: Volume, Pan, a Send per bus, Audio
    In, Monitor, Output, MIDI In, MIDI Out (Shift: back). A routing page's
    encoder is a dropdown: touched, its list opens; three detents a step;
    it switches as it steps, one undo step a touch.
  - Upper 2, Arm: pressed, the selected pad armed or not; held, the lower
    row arms.
  - Upper 8, Buses: the buses seven at a time, Main pinned at the far
    right (Volume, Pan, Output pages).
  - The lower row selects; with Mute, Solo or Arm held, it mutes, solos or
    arms. Delete held and an encoder touched: back to its default.
  - The master encoder is Main's level.
  - The window's mixer uses the same colours: Mute yellow, Solo blue, Arm
    red.
- **The pads' lights** come from one renderer (`surfaces/push2/render.odin`).
  - **Modes only draw:** a mode (Pads, Sequences, Keys) is a stack of
    layers, each drawing over a 64-pad frame:
    - Pads: their colours (45% unlit, an eighth when empty), the selected
      pad, a pad flashing its full colour for 120 ms as it sounds
      (`pad_struck`: a press, the sequencer), the held pads.
    - Sequences: their colours, the one shown, a playing one green on
      every beat, a queued one on every eighth, the held pads.
    - Keys: the scale, the held pads.
  - **The renderer sends:** every 15 ms it draws the frame and sends only
    what changed. Colours get palette slots 27–99 by colour, the least
    recently shown reused and none rewritten while a pad shows it; at
    most 8 slots a render, and a pad waits for its slot.
  - **Repair:** every light is sent again each second, every slot each
    four seconds.
  - **Trace:** `PADS_PUSH2_TRACE=1` logs each light and slot to the
    surfaces' log (and stderr).
- **Arrows**: Left/Right the pad before or after the selected one, Up/Down
  the sequence after or before the one shown.
- The display's accent is the track's colour, as the window's bottom area.
- A synth oscillator's sound (its wavetable; the sample oscillator's
  noise) is the Osc tab's first dropdown.
- Black behind everything (the display's own look).
- **A slicer** has two tabs where a sampler has Sample (ui_ctl_slicer.odin):
  - **Slicer** (the whole sample, its slices numbered):
    - Bank 1: Slice By (a change slices again), Slice (the selected one), its setting (Sensitivity, Grid or Slices; it slices again when let go), First Key, Fade In/Out, Start, End.
    - Bank 2: Volume, Pan, Transpose, Fine, Attack, Release, Velocity, Choke.
    - Bank 3, Warp (the sampler's too): Warp (Off or its mode), Sample BPM (the guess until set); in Beats, Cut and Fill Gaps.
    - Buttons: Mono/Poly, Thru, Gate, Warp (turned on: its bank), To Sequence, To Sampler, Record; the last button steps through the banks.
  - A tab's bank buttons take the lower row's free buttons from the right; too few free, the last free one steps to the next bank.
  - **Slice** (the selected slice, shown close):
    - Encoder 1 picks the slice; then Position (not slice 1), Level, Pitch, Pan.
    - Buttons: Reverse, Hear, Split (in two at its middle), Remove, To Pad.
  - The selected slice is shared by the window's slicer page, both tabs and the slice pads (`Core.slice`; the API's `pad_slices` and `pad_select_slice`).
- **SuperFilter** (`ctl_super_filter`, ui_superfilter.odin): the window's
  display (its response at the cutoff as modulated now, the knob's own
  behind, the spectrum, the LFO's wave) over four banks:
  - Filter: Freq, Res, Morph, Type, LFO, Rate, Envelope, Dry/Wet.
  - Circuit: Drive, Circuit, Slope, Clip, Output, Wave, Shape, Mode.
  - Envelope: Attack, Release, Hold, S&H, S&H Rate, Source, Key Low, Key High.
  - LFO: Stereo, Phase or Spin, Offset, Retrigger, Smooth, Key Gain, Listen.
  - On, the four banks, Remove on the lower row.
- **Slice pads:** in Note (Keys) mode with a slicer selected, pad n plays slice n+1.
  - Slices are lit at 45% of the pad's colour, the selected one white, the sounding one at full colour; pads past the last slice are dark.
  - A press selects the slice.
- **Transport lights** (transport.odin, a task every 15 ms reading Pads' transport):
  - **Tap Tempo** blinks every beat, playing or not, brighter on the bar's first beat.
  - **Play** blinks on the beat while playing.
  - **Record** blinks fast while counting in, and on the beat while recording (Rec playing, or a sample recording into a pad). Armed and stopped, it stays lit.
  - **Metronome** (on) pulses with the click while it clicks.
  - **Session** blinks in eighths while a launch waits for its moment.
  - The display's top right shows bar.beat while playing, or the beats left (red) while counting in.
- **Browser, Shift + a load button:** the item goes onto the next empty pad, as Shift does in the window.

## Song (Master, 2026-11-17)

Master puts the Push in Song (surfaces/push2/song.odin) and turns song playback on; Shift+Master turns song playback on or off without leaving where the Push is. The window shows the Song tab.

- **One state:** the cursor, the selected lane and clip, the eight lanes shown and the length a clip added gets are in `Core.song_edit`. The API reaches them through `song_edit_state`, `song_set_cursor`, `song_select_lane`, `song_show_lanes`, `song_select_clip`, `song_clip_at`, `song_set_add_length`, `song_add_at_cursor`, `song_remove_sequence`, `song_set_clip_label`, `song_ripple_remove` and `song_ripple_duplicate`. The window draws the cursor, and its selected clip is the same one.
- **A lane plays one clip at a time (2026-11-17, everywhere):** a clip put over others, from the Push, the window or the API, makes them make way. A clip it covers is taken out, one it overlaps is trimmed, and one it sits inside is cut in two. A trimmed clip's notes stay where they were. The model's `song_make_way` does it. The window does it when a drag ends, so a drag shows the overlap until the drop. Projects that already have overlaps keep them until those clips are edited.
- **Ripple edits on the Push:** adding at the cursor inserts, and the lane's later clips move on. A cursor inside a clip puts the new one after that clip. Delete closes the gap, the lane's later clips move back, and the cursor goes back where the clip began. Duplicate pushes the later clips on. On the Clip tab, Start and Length move the lane's later clips with the clip's end. Other lanes stay put.
- **The grid:** the 64 sequences, the first at the bottom left. Each is bright when the song has it, dim when not; the current one is white, and one playing in the song flashes green on the beat.
  - A press picks the sequence.
  - Select + a pad: open it in Clip (the sequencer).
  - Duplicate + a pad: copy it.
  - Delete + a pad: take its clips out of the song, closing the gaps.
- **The scene buttons:** lanes, the top one first. Up and Down show lanes 1–8 or 9–16. A lane's light is white when selected, dim when it exists, orange when muted, blue when soloed, and green on the beat while it plays.
  - A press inserts the current sequence at the cursor on that lane, and the cursor moves to its end.
  - Select or Shift + a lane: the clip at the cursor there is selected.
  - Delete + a lane: that clip is removed and the gap closes.
  - Duplicate + a lane: that clip is copied right after itself, and the later ones move on.
  - Mute or Solo + a lane: the lane is muted or soloed.
- **Left and Right:** the cursor moves a bar (Shift: a beat).
- **The display** is Pads' Song view (`View_Kind.Song`, ui_ctl_song.odin), in three parts:
  - **The left column** is the transport: the tempo and time signature, where the song is as bar.beat.sixteenth (green while it plays) and as time, and the loop or the last marker passed.
  - **The middle six columns** are the lanes: the ruler with the loop and markers, the cursor, the playhead, and each clip with its notes. They scroll with the position, which stays a quarter of the way in. That position is the playhead while the song plays, unless the cursor was moved in the last two seconds; otherwise it is the cursor. Zoom is 8 bars to start; Fit shows the whole song.
  - **The right column** is the master's level meter, both channels, with the peak held and its dB value. It has no controls.
- **The first knob is Position on every tab.** Moving it selects the clip it lands in on the selected lane. The tabs are on the upper row:
  - **Song:** Position, Clip, Lane, Sequence, Length (of a clip inserted), Snap (the window's), Zoom. Buttons: Insert, Song Mode, Cue, Loop, + Lane, Fit.
  - **Clip:** Position, Clip, Start, Length, Transpose, Sequence, Part From, Part Length. Buttons: Mute, Duplicate, Delete, Name (the name editor), Whole, Cue, To Cursor, Insert. A clip's lane is changed in the window (the Lane knob made way for Position).
  - **The Clip knob** (Song and Clip tabs) steps through the selected lane's clips. Each step selects the clip and puts the cursor at its start, so a lane button or Insert puts a sequence before it. Its last stop, End, puts the cursor at the lane's end.
  - **Lanes:** Position, Lane. Buttons: Mute, Solo, Rename, + Lane.
  - **Arrangement:** Position, Arrangement. Buttons: New, Duplicate, Rename, Delete, Clear Song.
  - **Markers:** Position, Marker (picking one moves the cursor to it), Loop Start, Loop End. Buttons: Add, Rename, Delete, Loop, Start Here, End Here, Cue.
  - **Tempo:** Position, Tempo at the cursor (a turn sets a point there; Shift: 0.1 BPM), Ramp, Meter (from the cursor's bar). Buttons: Add Point, Remove Point, Remove Meter.
- Leaving Song (Session, Note, Layout) gives the display back what it showed before.

## The project manager (2026-11-17)

Pads shows a project manager page over the window (ui_start.odin) at two times: when it starts with no project to open, and after New Project. The page lists the recent projects with when each last changed, the projects folder's other projects, and the templates, with Empty Project and Open… buttons. Choosing a project or template opens it and closes the page. Empty Project keeps the new project that is already open. The toolbar and the status bar stay usable.

- **The Push:** while the page shows, it is in Browse on the Library's Recent category (Projects when nothing is recent). The window's Library is on the same category, so the item picked on the Push is the one lit on the page, and Open there opens it. When the page closes, the Push goes back to Mix. The surface watches `ui_start_page` for this; `ui_set_start_page` opens or closes the page.
- **Tests and scripts:** `--no-start-page` turns the page off at start and after New Project; `--drive` never shows it. The e2e harness passes the flag unless a test asks for the page (`Pads(start_page=True)`).

## Browsing with the encoders

A list in Browse (the categories on encoder 1, the items on encoder 3, eight at a time on encoder 4) moves one item per 5 encoder ticks. It moves at most one item a frame, and a fast turn's extra ticks are dropped, so it never skips items.

## The master encoder

It sets Main's volume, moving along Pads' fader curve as the window's faders do: 1/400 of the travel a tick (about 0.1 dB near 0 dB, coarser near the bottom), and Shift makes it ten times finer. One message moves at most 3 ticks, so a fast turn can't leap. It stops at +6 dB and at -60 dB (off).

## The rest of the controls (built 2026-11-17)

Every Push 2 control gets a job, and none is left doing nothing by accident.

- **Double Loop:** doubles the current sequence (its notes copied). In Song mode it doubles the selected clip's length instead, and the lane's later clips move on.
- **Quantize:**
  - A press quantizes the current sequence, or the selected notes in Clip.
  - A long press (about 0.4 s) or Shift + Quantize opens the Quantize dialog. It is a Pads dialog, so it shows in the window and on the Push. It sets the Quantize grid and strength, plus input quantize: on/off, grid, strength and swing.
  - The Quantize grid and strength are a new project setting. The window's Quantize button uses it too.
  - The Quantize light is bright while input quantize is on and dim while it's off. The display shows an "IQ 1/16" badge.
- **Fixed Length:** a picker on the display for the current sequence's length in bars (1-64).
- **Convert:** one choice view, shown in the window and on the Push. It offers only the choices that fit the selected pad:
  - Slice onto pads, Make a Slicer, Into a Synth's oscillator, and Back to a Sampler. These are the Library's load actions, applied to the sample already on the pad.
  - Resample sequence and Resample pad. Each is an offline render through the export renderer, written into the project's Samples/Resampled folder and loaded onto the next empty pad as a warped Sampler.
- **New:** a new empty sequence in the next free slot, selected. Shift + New duplicates the current sequence instead.
- **Automate:** a press turns automation recording on or off, lit red while on (this needs an API call). A long press or Shift + Automate shows the selected pad's automation lanes in Clip.
- **Add Device:** Browse on Effects (and plug-ins) for the selected pad. A load goes into its next empty effect slot.
- **Add Track:** selects the next empty pad, and in Song mode adds a lane instead. Shift + Add Track adds a mixer bus.
- **Accent:** full velocity (127) on every pad hit while on, recorded that way too, and lit while on. It's a new Pads setting the window's toolbar shows. A long press makes it momentary, on only while held.
- **Scale:** for now, Keyboard mode's scale, root, octave and chord on the display. The scales, chords and progressions grid mode replaces it later; that mode isn't built yet.
- **Swing encoder:** sets the current sequence's swing and input quantize's swing together, as one amount. While touched, the display shows the amount.
- **Setup:** a press opens Pads' Settings window. Shift + Setup shows the Push's own settings on the display: pad sensitivity and velocity curve, aftertouch, display and LED brightness.
- **User:** does nothing, and its light stays off. Pads needs the Push in User mode.
- **Shift hints:** while Shift is held, the display's knob names and button labels change to their Shift functions, with a SHIFT badge. The hardware buttons that have a Shift function light up, and the others go dark.

**How they're built:**
- **Code:** the buttons are in surfaces/push2/extras.odin, the Push's own settings page in setup.odin, and the dialogs they open in apps/pads/ui_controls.odin. Those dialogs are Sequence Length, Quantize, Convert and Scale; they show in the window and on the Push.
- **Dialog settings on the encoders:** a dialog notes each setting with `modal_knob`, which shows it over an encoder on the Push and turns it from there.
- **Resample** reuses Bounce (`export_bounce_pads`).
- **Accent** lives in the router: an atomic flag, applied to the window's hits and to MIDI hits alike, so recorded notes are at full velocity too.
- **The Quantize setting** is saved with the project, from project file version 39.
- **The Automation tab:** Automate held long opens the sequencer's Automation tab on the Push (ui_ctl_auto.odin). Its knobs are Lane, Point, Position, Value, Curve and Grid; its lower row is Add, Delete, Clear Lane and Record.
- **Shift's hints** hold the side buttons' lights with fire-surface's `light_hold` and `light_release`, which keep and restore the owners' lights. Pads' views track Shift (`a.ctl.shift`): knob names say "· fine", a SHIFT badge shows, and the browser's load buttons say "→ Next Pad".

## Closing the gaps with the window (built 2026-11-17)

The Push compared with Pads' window, each gap decided with the user. Five groups, built in this order; each one is tested, with screenshots, before the next.

1. **Settings view.** Pads' Settings as a new view on the display, covering the Audio, MIDI and Sync/Link tabs.
   - **Audio:** interface, sample rate, buffer, input and output channels, test tone.
   - **MIDI:** ports on and off, inputs and outputs, clock out.
   - **Sync:** internal clock, MIDI clock or Link, and Link's settings.
   - **On the Push:** the tabs are on the upper row and each setting is on a knob (a choice is a dropdown).
   - **Opening it:** Setup opens it on the Push and in the window together, one state. Shift + Setup stays the Push's own settings.
   - **Restarts:** a change that restarts audio asks first, in a dialog.
2. **Entering notes.**
   - **Layout in Clip:** Live's layout. The top four rows are 32 steps of the selected pad, lit where it has notes, with the playhead moving through them. The bottom four rows are 16 pads that choose and play the pad.
   - **Steps:** a step press adds or removes a note. While a step is held, the encoders set its velocity, length, chance and nudge.
   - **Step size:** the sequencer's grid (the scene buttons pick it, 1/32t to 1/4). Left and Right page through longer sequences, and the page follows the playhead while playing.
   - **Copying:** Duplicate held: press a step, or the first and last of a range, to copy it, then a step to paste there. Duplicate + a pad below copies that pad's whole row.
   - **Copy Bars** (from, to, how many) is a choice on Clip's lower row.
3. **Recording and the transport.**
   - **Recording dialog:** a long press of Record opens it, in the window and on the Push. It covers the Sample control (Arm, Threshold or Bars mode, threshold, bars, latch); arming there makes the next pad pressed record.
   - **Transport dialog:** a long press of Metronome, or Shift + Metronome, opens it. It covers Loop, count-in, the click's level, sound and accent, click only while recording, and the time signature.
   - **Loop:** Shift + Play turns it on and off directly.
4. **Sequences, lanes and play modes.**
   - **Sequence dialog:** a long press of Fixed Length, or Shift + Fixed Length, opens it. It has the name (name editor), colour, tempo, bars, the selected pad's own loop, and when a new sequence takes over (end, bar, beat, at once). Its buttons are Clear, Duplicate and Rename. A plain press of Fixed Length stays the length picker.
   - **Lane dialog:** Select + a launcher lane's upper button opens it, for the lane's name and colour.
   - **Layout** cycles between Pads and Velocity mode (the selected pad's 16 velocities), each lit differently.
5. **Cue sends, audio and CC.**
   - **Cue page:** a new page in Mix for each strip's cue send, pre or post.
   - **Audio tab** in Clip: the takes as rows, with their regions. The knobs pick the take and the region, and move or trim it. The buttons are Split, Delete, Use Take and Consolidate.
   - **MIDI CC lanes** are listed in the Automation tab with the other lanes.

**Where it is built:**
- **Pads' side:** the Settings view (ui_ctl_settings.odin, `View_Kind.Settings`), the Audio tab (ui_ctl_audio.odin), the CC lanes in ui_ctl_auto.odin, and the Cue page in ui_ctl_mixer.odin.
- **Dialogs** in ui_controls.odin: Recording, Transport, Sequence, Lane and Rename Lane. The window's Copy Bars dialog is mirrored to the Push as well.
- **Surface:** the step grid and Velocity mode are in surfaces/push2/steps.odin. Holding Record or Metronome, Shift + Metronome and Shift + Play are in push2.odin's transport handler.
- **New API calls:** `ui_select_notes`, `ui_sequencer_grid`, `ui_set_sequencer_grid`, `ui_sample_armed` and `mixer_pad_cue`.
- **The Push's lights:** while sampling is armed, the Record light blinks on the beat. In Velocity mode, Layout is lit orange.

**Left to the window (decided):**
- **Not needed:** grouping pads, renaming buses, Freeze, Bounce in Place, and Library search.
- **Can't fit the display:** plug-ins' own windows and the wavetable editor. Plug-in parameters already reach the Push through Device.

## Where things live

- **fire-surface's draw kit** (host-neutral): anti-aliased shapes and
  TrueType text (stb_truetype, CPU), Open Sans bundled (OFL). Any surface,
  any host, any platform (the Pi, later mobile).
- **Pads draws views** (`fire.pads`): a view of Pads' (`View_Kind`: the
  sequencer, a device, the mixer, a clip, the browser) at a size it's
  asked, with Pads' widgets, fonts and theme, offscreen on the GPU, read
  back a frame later as RGBA. Only Pads offers it.
- **Pads' Push 2 surface** (`apps/pads/surfaces/push2`, GPL with Pads):
  linked into Pads (`surfaces_add_static`), so a Push 2 works with nothing
  installed. It uses `fire.pads` for what `fsurf.daw` doesn't say, and the
  views. fire-surface's `push2_odin` stays the host-neutral example.

## The display

960 x 160 at 30 frames a second (a steady stream: Push 2 turns its display
off without one). Each mode lays out:
- a strip of eight columns, one an encoder, each with its name and value,
  lit while its encoder is touched (Push 2's encoders send touch notes)
- the mode's view: drawn by the surface (the kit), or by Pads (a view),
  or both (a view with the surface's labels over it)
- the upper and lower button rows' labels, as the buttons do in this mode

## Modes

| Mode | Display | Encoders | Pads | Buttons |
|---|---|---|---|---|
| Mix | Pads' mixer strips (pads, or buses + Main) | the page Upper 1 chose (volume, pan, sends, routing) | upper: page, Arm, Buses | lower: select, or mute / solo / arm while held |
| Device | the selected pad's sound: its device's view (filter curve, envelopes, LFOs) | its parameters, a bank each page | as before | upper: banks; lower: devices in the chain |
| Note / Scale | the keyboard or drum layout; Scale: roots and scales on the display | Scale: root, scale, in key, layout | Pads' Keyboard mode (built); drums: 16 pads + steps | Scale, Layout, Octave |
| Session | Sequences: Pads' launcher (built) | rows, lanes | Pads' pads, or its sequences | stop row |
| Browse | the browser: folders and files, previewed | scroll, choose | (as before) | load, back |
| Clip | Pads' sequencer: the sequence's notes (built) | rows, note, velocity, length, position, row, chance, grid | as before (steps on the pads: later) | Piano, Fold, Mute, Duplicate, Delete |

## Stages

1. **The kit: anti-aliasing and TrueType** (fire-surface; built,
   fire-surface 4b39b15: pure Odin, no stb). Shapes with
   coverage (lines, rects, rounded rects, circles, arcs), alpha, text in
   any TTF at any size (glyphs cached), Open Sans bundled; the examples'
   displays redrawn with it. Tests: images against references.
2. **Pads draws views** (`fire.pads`; built: `app/ui/offscreen.odin`,
   `view_frame`, the device view's four pages): a second ImGui context rendering
   offscreen (SDL_GPU) at the size asked, read back without waiting
   (a frame late); `view_*` in the API; one view first (the device's).
   Tests: a view's pixels from the API, headless.
3. **Pads' Push 2 surface**: linked in, the example's parts moved over,
   the modes' framework (the strip, touches, the rows' labels), Mix and
   Device with Pads' views.
4. **Note / Scale and Session.**
5. **Browse and Clip.**
6. **Sequencer.**

Each stage: tests (the fake DAW or Pads headless, the virtual controller,
the display's pixels), then tried on a Push 2.
