# Pads 0.1.0-dev: the plan

The first dev release of Pads: what it must have, how it ships, and what
waits. Each item is done when it is built, tested (unit, model and e2e),
test-driven with screenshots, documented, committed, cloud-tested on
Linux, ARM and Windows, and pushed.

## Must have

1. **Small gaps**
   - [x] Project templates: save a project as a template; File > New from
     template (the user's, in the settings folder).
   - [x] Metronome sounds: a choice of click (beep, wood, stick, cowbell),
     and its accent on the bar.
   - [x] The message log written to a file in the settings folder
     (rotated), and opened from the status bar's list.
   - [x] Plug-in delay compensation: each track's latency in the mixer,
     the total in the status bar.
2. **CLAP instruments on pads**
   - [x] A CLAP instrument as a pad's device (from the Devices panel),
     played chromatically; notes, wheels and MIDI to it.
   - [x] Its editor in a window of its own (plug-in effects' too).
   - [x] Every plug-in's state saved with the project (effects' too).
   - [x] Its parameters as knobs, each assignable to one of eight lanes.
3. **Tempo, locators, loop range**
   - [x] A tempo lane under the song timeline: tempo points at any bar, a
     line (ramp) or a step to the next; followed when playing and
     exporting. Step tempos become points.
   - [x] Time-signature changes per song step (a 7/8 bridge): the
     metronome, bar lines and quantize follow it while it plays.
   - [x] Locators: named markers at any bar on the song timeline; click
     one to jump; a Locators list; previous/next marker shortcuts.
   - [x] A loop range on the song timeline: drag on its ruler for loop
     in/out; the loop button loops it in song mode (the whole song when
     unset).
4. **Freeze, groups, sidechain**
   - [ ] Freeze a track: its instrument through its inserts (before its
     fader, sends and pan) rendered over the song (or its sequences),
     tails included, and played instead; mixer moves still work; unfrozen
     to edit; flatten to an audio pad.
   - [x] Track groups are buses: grouping pads routes them to a new bus
     named for the group; the mixer folds a group's pads under its strip.
   - [x] Sidechain: the compressor and gate keyed from any pad's or bus's
     output (post-fader), with a key high-pass filter and a listen switch.

## How it ships

- **Version** 0.1.0-dev, in an About box (with the commit) and settings.
- **macOS**: a `.app` bundle (icon, Info.plist, the dylibs it needs) in a
  `.dmg` made with `dmgbuild`. Unsigned: first open is right-click > Open.
- **Windows**: an installer made with Inno Setup (Start menu shortcut,
  uninstaller), and a zip of the same files.
- **Linux**: an AppImage and a `.deb` (x86-64 and ARM64).
- **GitHub**: a tagged pre-release `v0.1.0-dev` with the packages and
  release notes (what it does, what is known not to yet).
- `scripts/release/` builds each; `task release:<os>`.

## After the release (roadmap)

- Signing: macOS Developer ID and notarization; Windows code signing.
- MIDI learn for any knob, and MIDI CC lanes.
- The rest of TODO.md.
