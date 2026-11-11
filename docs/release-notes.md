# Pads 0.1.0-dev

The first development release of Pads: a pad sampler, sequencer, song
arranger and mixer built on the Fire Engine audio engine. It is for
trying out and for feedback. Projects saved now will open in later
versions, but things will change, and some will break.

## What it does

- **Pads**: 128 pads in eight banks, each a sampler (regions, loops,
  envelopes, filter, pitch, LFOs, mono, legato and glide), a slicer, a
  wavetable synth (with presets, effects, modulation and a wavetable
  editor), an audio track, or a CLAP instrument plug-in.
- **Sequences**: 64 of them, each a drum grid and a piano roll, with
  velocity, chance and automation lanes; sequence pads to launch them in
  Perform (Launch or Hold, quantized), and MIDI file import and export.
- **Song**: steps in order, arrangements, a tempo lane (steps and ramps),
  time signatures per step, markers, a loop range.
- **Mixer**: a strip per pad, 16 buses, main; inserts and bus effects
  (the synth's nine effects, dynamics, rhythm and pitch effects, CLAP
  plug-ins with their own windows and state); sends; groups; sidechain
  for the compressor and gate; freeze and flatten; delay compensation.
- **Perform**: 16 performance effects, keyboard mode with scales and
  chords, note repeat, an arpeggiator.
- **Recording** audio and MIDI, with a count-in and a metronome (four
  sounds, an accent).
- **Projects**: save prompts, crash recovery, templates, undo history,
  export (mixdown or stems, 16/24/32-bit), resample to a pad.
- Ableton Link, MIDI clock in and out, MIDI out per pad.

## Known not to work yet

- The packages are not signed. On macOS, open Pads the first time with
  right-click > Open; on Windows, SmartScreen asks once ("More info" >
  "Run anyway").
- No MIDI learn for knobs, and no MIDI CC lanes (next on the roadmap).
- macOS: Apple silicon only in this build.
- Linux: the AppImage and .deb are built on Ubuntu 24.04; older systems
  may lack its C library.
- A plug-in that crashes takes Pads down with it (its scan blocks it the
  next time).

## Feedback

Issues and ideas: https://github.com/bcrowe306/fire_engine/issues
