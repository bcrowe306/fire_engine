---
title: Scales, chords and progressions
description: Pads' Scale, Chords and Progressions play modes, the project key, and how they reach the sequencer, the arpeggiator and Push 2 (plan, 2026-11-19).
---

# Scales, chords and progressions (plan, 2026-11-19)

Status: stages 1–3 built (2026-11-19): the key and its scales, chord
building and naming, progressions (the bank and your own), voice leading
and spread, the five play modes, the project file (v41, old projects
converted); the window (the Play mode menus, the Key and Progressions
dialogs, the pads' chord names, the status bar's key, the piano roll's
shading and Fold to key, the arpeggiator's In key); strum in the router.
Stage 4 (Push 2) is next: until then its Note mode plays the window's
note modes' keys as the window's grid counts them (see As built).

Today Pads' pads have three play modes: Pads, Keyboard (the selected pad's
notes in a scale, with an optional stacked chord on every pad) and
Velocity. Keyboard's settings (`pm.Keys`: scale, root, octave, chord) are
saved with the project. Push 2's Scale button opens them on the encoders,
and its Note mode lays 64 scale notes in a row, wrapping every 8 pads.

This phase turns that into three play modes built on one **project key**.
The modes are written for Pads itself (the window's 16 pads), and Push 2
mirrors them on its 64 pads. All of it goes through the Pads API, so
other surfaces get it too.

Everything here is ours. Hardware grooveboxes with similar modes are a
reference for what musicians expect, but none of their names, layouts
or preset progressions are copied.

## The project key

- **Saved with the project:** a key (a root and a scale), shown in the
  status bar and set from a Key dialog (the Scale dialog, renamed). Old
  projects' Keyboard settings become the project key.
- **More scales:**
  - **Kept:** today's nine.
  - **Added:** the remaining church modes (Phrygian, Lydian, Locrian),
    melodic minor, Phrygian dominant, Hungarian minor, whole tone,
    diminished (half-whole and whole-half), Japanese (in-sen) and
    Hirajoshi.
  - **Enum:** new scales are appended, so existing values keep their
    meaning in old files.
- **Used beyond the pads:**
  - **The piano roll** shades the key's notes and has a **Fold to key**
    toggle that shows only the key's rows.
  - **The arpeggiator** gets an **In key** option, which snaps its notes
    (octaves included) to the project key.
  - **The API:** `key_*` calls, including key changes, so surfaces can
    follow them.

## The play modes

The Play mode menu in the window has five modes: **Pads**, **Scale**
(today's Keyboard, renamed), **Chords**, **Progressions** and
**Velocity**. Every mode plays the selected pad, and the sequencer
records what the pads play as ordinary notes. A chord is several notes,
so it can be edited afterwards like any others.

### Scale

- **What it is:** today's Keyboard mode, using the project key.
- **The window:** the 4x4 pads keep their banks of 16 keys, as now.
- **Push 2:** Layout picks how the 8x8 grid is laid out:
  - **Fourths** (the default): each row a fourth above the one below, in
    key only. This is the usual isomorphic layout.
  - **Thirds:** each row a third above the one below.
  - **Sequential:** today's layout.
  - **Chromatic:** every semitone. Notes in the key are lit, the rest dim.
- **Kept:** Octave, the roots lit in the pad's colour, and a slicer's
  slices on its keys.
- **Removed:** the Chords setting, which stacks thirds on every key. The
  Chords mode replaces it, and old projects with it set open in Chords.

### Chords

Each pad plays one chord in the key:

- **Columns:** the key's degrees, I to vii. A 7-note key fills eight
  columns on Push 2 (the eighth is I an octave up) and four on Pads.
  Pads shows four degrees at a time, and its bank buttons shift by four.
- **Rows:** the variations, from the bottom: triad, 7th, sus4, sus2, add9,
  6th, first inversion, second inversion. Push 2 shows all eight rows;
  Pads shows four at a time, and its rows page.
- **Chord names on the pads:** for example "ii⁷ Dm7". Push 2's display
  shows the chord being played: its name and its notes on a keyboard.
- **Smaller keys:** a pentatonic or 6-note key gives five or six columns.
  Its chords are made from the key's own notes, and any that don't fit
  read "–".

### Progressions

- **The pads:** one chord per pad, in the progression's order. Up to 16
  chords fit on Pads and 64 on Push 2. A progression of eight chords
  fills two rows on Pads and one row on Push 2.
- **The other rows on Push 2:** the same chords voiced differently: up an
  octave, and with the bass note an octave down.
- **Roman numerals:** progressions are stored as numerals plus a variation
  (for example `I  V  vi  IV`), so they follow the project key.
- **Built in:** about 40 progressions of our own, grouped by style and
  mood (Pop, Soul, Jazz, Blues, Cinematic, Dark, Modal...). The bank's
  names and contents are written fresh.
- **Your own:** an editor in a window (add, remove and reorder chords,
  each one's degree and variation, the name). Your progressions are saved
  in the settings folder as `.fprog` files, as synth presets are. The
  project keeps the one in use, so it opens anywhere.
- **Choosing one:** a Progressions dialog in the window. On Push 2, the
  Browse mode's encoders scroll the bank.

### Voicing

These settings are shared by Chords and Progressions:

- **Voice leading** (on by default): each chord's inversion is chosen to
  be closest to the chord played before it. Without it, chords play in
  root position, or in the inversion their variation names.
- **Strum:** 0 to 100 ms between the notes of a chord, low note first.
  This happens in the router (on the audio thread, scheduled by frame),
  so recorded notes keep the strum.
- **Spread:** close, open, or wide (drop 2), set per project.

## Where it lives

- **The model:** `apps/pads/model/keys.odin`, extended with the key, chord
  building, the progression type and voice leading. It is a pure model,
  unit-tested.
- **The core:** `apps/pads/core/perform.odin` maps a pad and play mode to
  notes, with the voice-leading state kept per pad.
- **The router:** strum, as each note's offset in frames.
- **The API:** `perform_*` (the modes, the variations' page), `key_*`
  (the key and its scales), and `progression_*` (the bank, the current
  progression, editing).
- **The window:** the Play mode menu, the Key, Chords and Progressions
  dialogs, the pads' names, the piano roll's shading and fold, and the
  arp's In key.
- **Push 2:** Note mode's layouts, Chords and Progressions on the grid,
  the display (the key, the chord playing, the progression's chords with
  the one playing lit), and Scale and Layout on the encoders.
- **The project file:** a version step with the key, the play mode, the
  progression in use and the voicing settings. Old projects are converted
  (Keyboard becomes Scale, its Chords setting becomes Chords mode).

## Stages

1. **The model and the core:** the key, scales, chords, progressions and
   voice leading, the play modes, the project file. Unit tests cover the
   chords per scale, inversions, voice leading and the file round trip.
2. **The window:** the Play mode menu, the dialogs, the pads, the
   Progressions editor and bank, the piano roll and the arp's In key.
   e2e tests and screenshots.
3. **Strum in the router:** an rt test that the notes are offset by
   frames, and that strum is the same at any block size.
4. **Push 2:** the layouts, the Chords and Progressions grids, the
   display and the encoders, tested on the virtual Push 2 with display
   images.
5. **Docs, API check, profile, and the full suites** at both opt levels.

## As built (stages 1–3)

Where the build differs from the plan above, or settles what it left open:

- **Chords from the key's own notes:** a 7-note key stacks its own thirds
  (degree + 2, + 4, + 6: harmonic minor's vii is G# B D F, not G# C E);
  a sus4, sus2, add9 or 6th needs that interval from the key's next
  degrees. Other keys look for the intervals among their notes (a major
  or minor third, then a perfect, diminished or augmented fifth). What
  isn't one of those reads "–" and plays nothing.
- **Numerals:** by the key's degrees in a 7-note key (with its quality's
  case and ° + ø marks), by semitones from the root in the others (bIII).
  Plain "ii7 Dm7": the window's font has no superscript digits.
- **Voice leading** chooses among the chord's inversions, each within an
  octave of where it was built, the one with the least distance (each
  note to the other chord's nearest, both ways) to the chord that pad
  played last. The two inversion variations keep the inversion they name.
  The state is the core's, per pad, reset when the mode, the voicing or
  the progression changes.
- **Strum** delays a chord's notes (and their note-offs, so each sounds as
  long) by `Hit.delay_ms`; the router keeps them, up to 128, by frame and
  plays each in the block it falls in, through the MIDI effects and the
  recording like any live note.
- **Progressions** hold up to 16 chords (the window's grid); bank A plays
  them, the other banks are empty. The bank has 40, in 10 styles.
  Numerals in it are diatonic: they name degrees of whatever key is set.
- **The window's Chords mode:** the bank buttons shift by four degrees
  (bank B is V, vi, vii°, I an octave up), a two-way switch pages the
  rows. Its rows page is saved with the project.
- **Values kept:** `Play_Mode` keeps Pads 0, Scale 1 (Keyboard's),
  Velocity 2, and appends Chords and Progressions; the menus order them
  Pads, Scale, Chords, Progressions, Velocity. The scales are appended.
  The API's `perform_set_keys` and `Chord` stay for older callers (Off
  plays Chords as Scale, another chord Scale as Chords) and
  `Perform_State` gains `chord_page`; the key is `key_*`, the
  progression `progression_*`, and the new `Key` topic reports changes
  to either.
- **Push 2 until stage 4:** its Note mode stands for all three note modes
  (the window in Chords or Progressions shows Note on Push 2, and its
  keys play the window's chords as `perform_key` counts them); the Key
  dialog mirrors on its display with six encoders (scale, root, octave,
  voice leading, spread, strum).
