# Pads 0.1.1-dev

The second development release of Pads: a pad sampler, sequencer, song
arranger and mixer built on the Fire Engine audio engine. It is for
trying out and for feedback. Projects saved with 0.1.0-dev open in this
one (and are converted), but things will change, and some will break.

## New since 0.1.0-dev

- **A new layout**: one Library (Browser and Devices tabs, each with its
  own search), a flatter toolbar with the transport at its centre, a pads
  area that folds, pads that show their name, kind and waveform.
- **Song as lanes of clips**: any sequence on any lane, any length,
  several at once, under the time-signature and tempo lanes; zoom with
  Cmd/Ctrl+scroll.
- **Perform**: launcher lanes (8 to 16, named), three grids and the
  levels; Shift-click launches a sequence alone, Continue carries a launch
  on where the playhead is, Record to Song.
- **Sequences**: Notes and Automation tabs; automation of any parameter
  (a pad's sound, EQ, fader, inserts, sends, buses, main, plug-ins), with
  Automate on any knob's or fader's right-click, Touch to learn a
  control, knob moves recorded with Auto on; MIDI CC lanes; per-track
  loops of any length (polymeter); vertical zoom.
- **Audio**: audio clips (an audio track's regions of its takes), sampling
  into a pad (Hold or Arm, from an input, another track, a bus or main),
  resampling and bounces, recording timing set from the device's round
  trip, a warped pad's Transpose keeping its timing.
- **Mixer**: redesigned strips (inserts, EQ, sends, I/O as toggled
  sections; narrow or wide), main's loudness (EBU R128), an interface's
  inputs and outputs chosen and named, cue and direct outs, the audio
  driver chosen (CoreAudio; WASAPI and ASIO; ALSA and JACK).
- **Automation you can see**: a ring on any knob a lane, envelope or LFO
  moves, a mark across any fader, the filter picture moving with it.
- **Projects**: unsaved projects live in Pads' own folder until saved;
  Clean Up Project; takes never written over; a project's cache trimmed
  when it closes.
- **The Pads API**: one API for everything the app does, with a C ABI
  for control surfaces and scripts (docs/guides/api.md).
- **Faster audio**, for small machines (Raspberry Pi, low-end laptops):
  SIMD unison in the synth, cheaper reverb, chorus, phaser, compressor
  and loudness meter, a pad's strip one node; the heavy benchmark project
  went from 43% to 27.5% of an audio block on a two-core ARM machine.
  Settings > Appearance > Frame rate caps the UI's frames (60 or 30).
- **Fixes**: no pop at a synth note's start; envelopes without corners;
  Sync LFOs follow the sequencer; the knob menu's ImGui error; the
  slicer's playhead when warped; the Browser's arrow keys; Pads starting
  when its audio device is unplugged; and more.

## What it does


- **Pads**: 128 pads in eight banks, each a sampler (regions, loops,
  envelopes, filter, pitch, LFOs, mono, legato and glide), a slicer, a
  wavetable synth (with presets, effects, modulation and a wavetable
  editor), an audio track, or a CLAP instrument plug-in.
- **Sequences**: 64 of them, each a drum grid and a piano roll, with
  velocity, chance, automation and MIDI CC lanes, per-track loops;
  sequence pads to launch them in Perform (Launch or Hold, quantized),
  and MIDI file import and export.
- **Song**: lanes of clips, arrangements, a tempo lane (steps and ramps),
  time signatures, markers, a loop range.
- **Mixer**: a strip per pad, 16 buses, main; inserts and bus effects
  (the synth's nine effects, dynamics, rhythm and pitch effects, CLAP
  plug-ins with their own windows and state); sends; groups; sidechain
  for the compressor and gate; freeze and flatten; delay compensation.
- **Perform**: a launcher of lanes, 16 performance effects, keyboard mode with scales and
  chords, note repeat, an arpeggiator.
- **Recording** audio, audio clips, samples into pads and MIDI, with a count-in and a metronome (four
  sounds, an accent).
- **Projects**: save prompts, crash recovery, templates, undo history,
  export (mixdown or stems, 16/24/32-bit), resample to a pad.
- Ableton Link, MIDI clock in and out, MIDI out per pad.

## Known not to work yet

- The packages are not signed. On macOS, open Pads the first time with
  right-click > Open; on Windows, SmartScreen asks once ("More info" >
  "Run anyway").
- No MIDI learn from a controller to a knob yet (pads learn their notes).
- macOS: Apple silicon only in this build.
- Linux: the AppImage and .deb need glibc 2.34 and GCC 12's libstdc++
  or newer: Ubuntu 22.04, Debian 12, Raspberry Pi OS Bookworm (64-bit) and
  anything since (x86-64 and ARM64).
- A plug-in that crashes takes Pads down with it (its scan blocks it the
  next time).

## Feedback

Issues and ideas: https://github.com/bcrowe306/fire_engine/issues
