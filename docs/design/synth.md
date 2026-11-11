---
title: Synth device design
description: The plan for Pads' synthesizer device, a spectral-warping wavetable synth with Vital's features, built in our own code and GUI.
---

The **synth** is a pad's third instrument device, after the sampler and
the slicer. It is a wavetable synthesizer with the features of Vital: three
wavetable oscillators with unison and warp modes, a sample oscillator, two
filters of eight models, envelopes, drawable LFOs, a modulation matrix,
macros and nine effects. Each feature is meant to sound and behave as Vital's
does, but it is written in our own code, with our own data model, in
Pads' bottom panel.

This page is the plan: what we build, where it lives, the order of the
milestones and how each one is tested. The parts are checked off in
`TODO.md` as they land.

## Ground rules

- **Vital is a design reference, as JUCE is.** We read `vital/` (a local
  checkout, gitignored) to learn what each feature does and how it sounds:
  the algorithms, their ranges and curves, the order things happen in. We
  write each unit afresh in Odin, in this repository's style
  (CONVENTIONS.md). No file is translated line by line.
- **Nothing of Vital's ships.** Its name and its author's are trademarks,
  and its factory presets and wavetables are under a licence that forbids
  redistribution. The synth has its own name in the UI, its own built-in
  wavetables (generated) and, later, its own presets.
- **Where it lives.** The DSP is engine code, so it is MIT, in
  `f_engine/synth` (`fire:synth`): the voice, oscillators, wavetables,
  filters, modulators and matrix. It is a `core.Node`, so any host can use
  it, not just Pads. The nine effects go in `f_engine/fx`, each a
  standalone node as well as a unit the synth chains, so the rest of Pads
  can use them later as insert effects. The device's model, project file
  and UI are in `apps/pads` (GPL).
- **Real-time rules.** `[rt]` code allocates nothing, takes no locks,
  logs nothing. Wavetables and LFO shapes are built on the control thread
  and swapped in by pointer. Every parameter is smoothed.

## Tabs

The bottom panel's tabs for a synth pad:

| Tab | What is on it |
|---|---|
| **Osc** | Three wavetable oscillators (one shown large, A/B/C to switch; each with a power button and level meter), the sample oscillator, and a 3D view of the wavetable with the playing frame. Wavetable, frame, level, pan, octave/semitone/cents, unison (voices, detune, blend, stereo spread, frame spread, stack style, detune power and range), phase and random phase, the warp (distortion) mode and amount, and the destination (Filter 1, Filter 2, both, effects, direct out). |
| **Filter** | Filter 1 and Filter 2 side by side: model and style, cutoff, resonance, drive, blend, key tracking, inputs (which oscillators feed each), and serial or parallel. The response is drawn live, as the Pads filter is now. |
| **Env** | Six envelopes (Env 1 is the amplifier): delay, attack, hold, decay, sustain, release, plus the attack, decay and release curves. A dot rides the curve while a note plays. |
| **LFO** | Eight LFOs (one large, 1–8 to switch): a drawn shape (points and curves, with preset shapes), its mode (trigger, sync, envelope, sustain envelope, loop point, loop hold), rate or tempo division, fade-in, delay, phase, smoothing and stereo offset. Its R1–R4 are the four random modulators (Perlin, sample and hold, sine glide, Lorenz). |
| **Mod** | The modulation matrix: every route (up to 64) with its source, destination, amount, bipolar, curve, stereo and bypass. Drag a source anywhere, onto any knob, to make a route. |
| **Effects** | The nine effects in a reorderable chain, each with an on button and a picture of what it does: chorus, compressor, delay, distortion, EQ, filter, flanger, phaser, reverb. |
| **Macro** | Four macros (renamable knobs, sources for the matrix), and the keyboard sources: velocity, note, note in octave, aftertouch, mod wheel, pitch wheel, stereo, random. |
| **Global** | Voices (polyphony 1–32, mono, legato), glide (time, slope, octave scaling, always), voice priority and stealing, pitch-bend range, velocity tracking, transpose (whole semitones) and tune, volume, oversampling (1×, 2×, 4×, 8×), the oscilloscope and spectrum, and the track's I/O. |

**Modulation is shown where it happens.** Drag a source's handle (an
envelope's, an LFO's, a macro's) onto a knob. The knob gets a ring in the
source's colour; drag the ring to set the amount, and right-click it to
remove the route. While notes play, a dot on the ring shows where the
modulation has the value now. Every route is also listed in the Mod tab.
This is the "vivid visual feedback" rule: each control shows the audio it
shapes.

## Architecture

**Voices.** A `Synth` node holds up to 32 voices. A voice runs the three
oscillators and the sample oscillator, sends each to its destination (a
filter, both filters, the effects or straight out), runs the two filters,
then the amp envelope. The voices' sum goes through the effect chain, then
out. Notes and expressions arrive as events (the same `Note_On`,
`Note_Off`, `Note_Expression` and `Note_Choke` the sampler takes), so the
router's per-track stream feeds it unchanged.

**Modulation runs at two rates.** Envelopes, LFOs and the matrix run once
per 16-frame sub-block, and their outputs are interpolated linearly across
it. This is cheap and sounds smooth. FM, ring modulation and sync run at
audio rate, between oscillators. Each voice has its own copy of its
modulators (envelopes, per-note LFOs, velocity, note); global sources
(free-running LFOs, macros, wheels) are computed once per block. A route
adds `amount × curve(source)` to the destination's normalised value, which
is then clamped and mapped to its unit.

**Wavetables.** A wavetable is 1 to 256 frames of 2048 samples. When it is
loaded, each frame's spectrum is computed (an FFT), and from it a set of
band-limited copies, one per octave, so high notes do not alias. The
oscillator reads two neighbouring frames and two mip levels, and
interpolates both. Spectral morphs (milestone 3) act on the frame's
spectrum before it is turned back into a wave. All of this is done off the
audio thread; the audio thread only reads tables.

**SIMD.** Unison voices are the inner loop: up to 16 per oscillator, with
`#simd[4]f32` lanes, so four unison voices are rendered at once. That
works on NEON (ARM) and SSE (x86) alike. We profile on the ARM machine
(our slowest) from the first milestone, against a budget (below).

**Oversampling.** With 2×, 4× or 8× set, the voices (oscillators, filters,
distortion) run at that rate and are brought down by a half-band filter
before the effects. `fire:dsp`'s oversampler is reused where it fits.

## Data model

A synth pad's sound is a `Synth_Patch` in the Pads model, saved in the
project file (a new version):

- **Parameters** in a flat array, each with an id, a range, a default, a
  unit and a curve, so automation, MIDI learn, undo (with drag merging)
  and the knob widgets work as they already do for the sampler.
- **Routes**: up to 64 `{source, destination, amount, bipolar, power,
  stereo, bypass}`.
- **LFO shapes**: up to 8, each a list of points (x, y) with a curve per
  segment, and a name.
- **Wavetables**: a reference per oscillator, either to a built-in table
  by name or to a sample in the project's sample store (imported WAVs
  become wavetables). The sample oscillator refers to a sample.
- **Effect chain**: the order of the nine, and each one's on/off.
- **Macro names.**

An **init patch** (one saw oscillator into Filter 1, Env 1 on the amp) is
what a new synth pad starts with.

## Pads integration

- `Pad_Kind.Synth`. The pad's right-click menu offers **Synth**, as it
  offers **Slicer**.
- A synth plays chromatically: the piano roll has a row per note, and an
  armed track's MIDI input plays it. A pad hit, or a note in the drum
  grid, plays C3.
- Its pad face shows the current frame of oscillator 1's wavetable.
- Automation lanes and MIDI learn reach every parameter.
- Drive commands (`synth PAD`, `synth_param PAD NAME VALUE`, `route ...`)
  and state fields for tests, as the slicer has.

## Milestones

The order is "playable first". Each milestone is tested, test-driven
(screenshots), profiled, documented, committed, cloud-tested and pushed.

1. **A playable voice.**
   - The three wavetable oscillators, with unison, the stack styles and
     the warp modes: sync, formant, quantize, bend, squeeze, pulse width,
     FM and RM from the other oscillators or the sample.
   - The sample oscillator, with generated noise colours and any loaded
     sample, key tracking, loop and bounce.
   - The built-in wavetables and WAV import.
   - Two filters, all eight models: analog, dirty, ladder, digital, diode,
     formant, comb, phaser. Serial or parallel.
   - Six envelopes, eight LFOs, the matrix (with drag-to-assign and
     rings), four macros and the keyboard sources.
   - Voices, glide and oversampling.
   - Visuals: the wavetable's 3D view, filter responses, live dots on
     envelopes and LFOs, the oscilloscope and spectrum.
   - The Pads device and its eight tabs (the Effects tab says "milestone
     2").
2. **The nine effects**, in `fire:fx`, implemented to sound as Vital's
   do:
   - chorus;
   - a three-band compressor (upward and downward, as in Vital);
   - delay (stereo, ping-pong, mid ping-pong; tempo sync; its filter);
   - distortion (soft clip, hard clip, linear fold, sine fold, bit crush,
     down-sample; pre or post filter);
   - EQ (three bands: shelf or notch at the ends);
   - filter (any of the eight models);
   - flanger, phaser and reverb.

   They are reorderable and modulatable. Each is also a standalone node,
   noted in `TODO.md` for use as Pads insert effects.

   Done. `fx.Chain` runs them in the patch's order after the voices are
   brought down to the base rate. Sources sent *Direct* go around it. Every
   setting is a synth parameter (`effect_param(e, field)`, ids from 700).
   Effect parameters are the synth's, not a voice's: global sources and
   the newest voice's modulators move them. Delay, chorus and flanger
   sweep on a 32-sample control grid of their own, so a block's size
   never changes them. Cost at 48 kHz, every effect on: 6.7% of an
   M-series core (`-o:speed`).
3. **Spectral morphs and randoms.**
   - The eleven spectral morph modes: vocode, formant scale, harmonic
     stretch, inharmonic stretch, smear, random amplitudes, low-pass,
     high-pass, phase disperse, Shepard tone, skew.
   - Spectral unison.
   - The four random modulators: perlin, sample and hold, sine
     interpolated, Lorenz attractor.
4. **The wavetable editor**: drawn waves, line shapes, audio slicing, and
   frequency and phase edits.
5. **Presets** in our own format, with a browser and a built-in bank.

Later (in `TODO.md`): MPE (per-note bend, slide and lift as sources) and
microtuning (.scl/.kbm/.tun files).

## Tests and budget

- **Every unit goes through `testkit.render`.** Each must produce finite
  output, allocate nothing on the audio thread, give the same result at
  any block size, and do what it promises. For example: a saw table's
  harmonics fall as 1/n and nothing aliases above Nyquist; unison detune
  spreads the partials by the set cents; each filter model's measured
  response matches its curve; envelope stages take the times set; an LFO
  in sync mode lands on the beat; a route moves its destination by its
  amount. Golden WAVs catch regressions in sound.
- **Model and e2e tests**: making a synth pad, every tab used by mouse,
  drag-to-assign, the project round-trip, and undo.
- **CPU budget** on the ARM machine (t4g.small): eight voices, each with
  three oscillators of four unison voices and two filters, under 25% of
  one core at 48 kHz, 1× oversampling. This is profiled every milestone.

## What to watch

- **Cost.** Sixteen unison voices × three oscillators × 32 voices is a lot
  of work. Voice stealing (oldest, quietest), the budget above and
  per-oscillator power buttons keep it in hand.
- **Changing tables while it plays.** A wavetable or LFO shape changes on
  the control thread and is swapped in between blocks. The old one is
  freed only once the audio thread has let it go (the engine's
  retire-later pattern).
- **Mono and legato with sequenced notes.** Overlapping notes in the piano
  roll glide (legato) instead of retriggering, as a played keyboard does.
- **Project size.** Imported wavetables are stored like samples (once,
  shared), not inside each patch.
