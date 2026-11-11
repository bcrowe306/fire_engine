# TODO

Work agreed on but not started. Each item needs a plan before it is built.

## Pads

### Devices

A pad is a track; its device is its source of sound. Each needs its own
plan before it is built.

- **Sampler** — done (the pad's default when a sample is loaded).
- **Slicer** — done: one sample sliced in place, slices on notes
  from a base note; the sampler's voice (envelopes, filter, pitch, LFOs),
  warp; mono/poly, thru, gate; fades; per-slice volume; velocity
  sensitivity (Ableton Simpler's Slice mode is the reference for feel).
- **Synth** — a synthesizer with the capabilities of Vital (wavetable
  oscillators, unison, filters, modulation matrix, effects). Vital's code
  is GPL-3.0: a design reference only, written anew (as with JUCE).
- **Plug-in** — a CLAP instrument as the pad's device (CLAP effects are
  already hosted in effect slots); its parameters, its window, its state.
- **Audio clip** — records into and plays a clip in the pad, looping by
  default, so audio is recorded straight into a sequence (today's audio
  track, made a device).
- **MIDI clip** — records and plays MIDI clips, to play external MIDI
  instruments from a sequence.

- **Control surfaces.** Load a surface script (the engine's `fire:surface`
  manager), give it MIDI in and out ports, load and unload it from Settings
  > MIDI. To plan first: what a script can see and do (pads, sequences,
  transport, the mixer, the selection, LEDs and displays), how it maps to
  the app's commands, how scripts are found, versioned and reloaded, and
  how they are tested without hardware.
- **One item on macOS.** A `.pads` project shows as a folder in Finder;
  packaging Pads as an `.app` with a document type would show it as one
  file.
- **Warp cache.** Renderings in a project's `warped/` folder are never
  removed; clean up those no pad uses (on save, or from Settings > Project).
- **Several strips at once: more fields.** Inserts and EQ are not yet
  edited across selected channel strips.
