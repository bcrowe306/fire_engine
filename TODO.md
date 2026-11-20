# TODO

Work agreed on but not started. Each item needs a plan before it is built.

## Pads

### Devices

A pad is a track; its device is its source of sound. Each needs its own
plan before it is built.

- **Synth** — the five milestones done (plan: docs/design/synth.md); what is left of each is noted under it. A wavetable synth
  with Vital's features, written anew (Vital is a reference only, as JUCE
  is; none of its name, presets or wavetables ship). Tabs: Osc, Filter,
  Env, LFO, Mod, Effects, Macro, Global.
  1. A playable voice — done. Still to do: the filters, now the larger
     share of the 8-voice budget on ARM.
  2. The nine effects in `fire:fx` — done. Still to do: profile the chain
     on ARM (6.7% of an M-series core with all nine on; the chorus's eight
     delays are the likely hot spot).
  3. Spectral unison (each unison pair its own morphed buffer) waits on the
     voice budget: 8x the rebuilds, 128 KB an oscillator a voice.
  5. Presets — done. Later: more of the bank; tags and search; an audio
     keyframe's sound carried along.
  - Later: MPE (per-note bend, slide, lift) and microtuning (.scl/.kbm/.tun).
- **MIDI learn for any knob** (today: pads only).
- **Signing** (after 0.1.0-dev): macOS Developer ID signing and
  notarization of the .app/.dmg; Windows code signing of the installer and
  Pads.exe. 0.1.0-dev ships unsigned.
- **Control surfaces: after the SDK.** fire-surface is in Pads
  (extern/fire-surface, docs/guides/surfaces.md). Next, in order, as in
  fire-surface's docs/design.md ("After version 1"):
  - USB on Android through its USB permission (none on iPad).
  - Surfaces linked into Pads, not only loaded (iOS and Android).
  - Scripted surfaces in Lua (or Luau): user surfaces on iPad and Android,
    MIDI only there; scripts kept off the audio thread by the claim table.
- **Several strips at once: more fields.** Inserts and EQ are not yet
  edited across selected channel strips.

## Open work from the Push 2 and scales sessions

- **Push 2 on a real Push 2.** Only the virtual one and the display images
  so far.
- **Push 2: Clip mode's steps on the pads.**
- **Push 2: profile the device panels' drawing** on the ARM and x86 cloud
  machines.
- **Pads' window adopting the Push 2 device pictures** (written to be
  shared: ui_fxpic_*.odin).
- **Scales, chords and progressions** play modes, and a project key:
  planned in docs/design/scales-chords.md (in progress).
