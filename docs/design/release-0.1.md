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
   - [ ] A tempo lane in the song (points, ramps), followed when playing
     and exporting.
   - [ ] Time-signature changes at song steps.
   - [ ] Locators (named markers in the song) to jump to.
   - [ ] A loop range in the song: loop a few bars of it.
4. **Freeze, groups, sidechain**
   - [ ] Freeze a track: its sound rendered to audio and played instead
     (its devices off), unfrozen to edit; flatten to an audio pad.
   - [ ] Track groups: pads grouped under a group track (a bus with its
     own strip), folded in the mixer.
   - [ ] Sidechain: the compressor (and gate) keyed from another track.

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
