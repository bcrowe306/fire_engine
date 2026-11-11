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
- **Synth** — in progress (plan: docs/design/synth.md). A wavetable synth
  with Vital's features, written anew (Vital is a reference only, as JUCE
  is; none of its name, presets or wavetables ship). Tabs: Osc, Filter,
  Env, LFO, Mod, Effects, Macro, Global.
  1. A playable voice — done: 3 wavetable oscs + sample osc, unison, warp
     modes, 2 filters (8 models), 6 envelopes, 8 LFOs, matrix (drag to
     assign), macros, voices, glide, oversampling, live visuals. Still to
     do: get the 8-voice budget under 25% of the ARM core (SIMD unison,
     cached per-voice values); lanes for every synth parameter (today the
     Pitch, Cutoff and Resonance lanes reach its transpose and filter 1).
  2. The nine effects (chorus, compressor, delay, distortion, EQ, filter,
     flanger, phaser, reverb) in `fire:fx` — done: a reorderable chain,
     every setting modulatable, the Effects tab with a picture each.
     Still to do: profile the chain on ARM (6.7% of an M-series core with
     all nine on; the chorus's eight delays are the likely hot spot).
  3. Spectral morphs, spectral unison, the four random modulators — done
     but spectral unison: the eleven morphs (osc Morph), the randoms
     (Perlin, sample and hold, sine glide, Lorenz). Spectral unison (each
     unison pair its own morphed buffer) waits on the voice budget: 8× the
     rebuilds, 128 KB an oscillator a voice.
  4. The wavetable editor — done: drawn, line, harmonic and audio
     keyframes, crossfade or spectral blends, a window over the app.
  5. Presets (our own format, a built-in bank).
  - Later: MPE (per-note bend, slide, lift) and microtuning (.scl/.kbm/.tun).
- **Effects from the synth as inserts** — the nine `fire:fx` effects
  (milestone 2 above) offered in Pads' insert and bus effect slots too,
  alongside the existing ones.
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
