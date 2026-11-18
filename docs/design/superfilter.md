---
title: SuperFilter
---

# SuperFilter

A modulated filter effect for Pads in the manner of an "auto filter": a
filter whose cutoff moves with an LFO and an envelope follower (its own
input or a sidechain key), with drive, clip and dry/wet, shown as the
spectrum under the filter's response curve, the curve moving as the
filter does. It goes **alongside** the existing Filter effect (the
synth's), not in place of it, in pad and audio-track chains, buses and
the master (not the Perform effects, not the synth's own rack).

Status: planned (2026-11-17). Nothing built.

## What it has

From the reference (an auto-filter's panel) and the decisions made:

| Section | Controls |
|---|---|
| Filter | Freq (cutoff), Type, Slope 12/24, Res, Morph (what it does depends on the type) |
| Circuit | Circuit (the analog voicing), Drive |
| Envelope follower | Amount (bipolar), Attack, Release, Hold, S&H (on, and its rate) |
| Sidechain | Source (itself, any pad, any bus), key low cut, key high cut, key gain, Listen |
| LFO | Amount (bipolar), Rate, Mode (Hz, Sync, Dotted, Triplet, Sixteenths), Wave, Wave Morph |
| LFO, expanded (▼) | Stereo (Phase or Spin), phase offset, Retrigger (off, beat, bar, at play), smoothing |
| Output | Clip (on/off), Output gain, Dry/Wet |
| Display | input spectrum, the response at the modulated cutoff (and the knob's own, faint), a handle: drag across for Freq, up and down for Res |
| Meters | input and output, either side of the panel |

### Types and circuits

The **type** says what the filter does; the **circuit** says how it
sounds, for the types built from the analog-style poles. Our circuits are
the `fx` filter's existing models, voiced by ear (no attempt to clone
anyone's):

- Circuits: Clean (`Digital`; its 24 dB is two in a row), Analog,
  Dirty, Ladder, and Diode. Diode is a four-pole low-pass whatever its
  blend, so it makes Low only (24 dB; there is no slope to choose). A
  type a circuit doesn't make plays on Analog, and the UI greys the
  circuit out (`super_filter_circuit_has`, `super_filter_has_slope`).
- Types:
  - Low, High, Band, Notch, Peak: any circuit; slope 12 or 24 where the circuit has it.
  - Morph: one sweep low → band → high → notch (Morph sets where, 0..1), on the circuit.
  - DJ: one knob. Freq below the middle is a low-pass coming down, above it a high-pass going up, flat at the middle (Res adds the bump).
  - Comb: the `Comb` model. Morph is the feedback, negative to positive, through the comb's octave and fifth peaks.
  - Vowel: the `Formant` model. Morph moves through the vowels (a e i o u), Freq transposes them.
  - Phaser: the `Phaser` model. Morph is the stages' spread.

The circuit menu greys out for Comb, Vowel and Phaser. The slope buttons
grey out where a circuit has only one slope.

### The modulation

The cutoff is summed in octaves (so an LFO sweeps evenly by ear), each
sample, for each side:

`cutoff = freq · 2^(lfo_amt · 5 · lfo(t, side) + env_amt · 5 · env(t))`

clamped to 20 Hz..20 kHz, with LFO Amount and Envelope Amount each
reaching ±5 octaves. The `fx` filter already takes a cutoff buffer for
each sample, so the modulation is at audio rate, with no zipper noise.

- **LFO.** Waves: sine, triangle, ramp up, ramp down, square, random
  steps, random smooth. Wave Morph is a skew for sine, triangle and the
  ramps, the pulse width for square, and the glide for the random waves.
  Modes: Hz (0.01–40), Sync / Dotted / Triplet (the `fx.Sync` divisions,
  8 bars down to 1/64), and Sixteenths (1–64 sixteenths, a whole number).
  In the synced modes the phase comes from the timeline's beat, so a
  wobble is on the beat wherever play starts and after any jump; Hz runs
  free. Stereo: **Phase** (0–360°, the right side's phase against the
  left's) or **Spin** (the right side's rate higher by 0–2 Hz, so they
  drift). Retrigger: off, each beat, each bar, or at play; plus a phase
  offset (0–360°) and smoothing (a one-pole on the LFO's output, 0–100 %,
  which rounds square and random steps).
- **Envelope follower.** It follows the key: its own input, or the
  sidechain's (another pad or bus, after its fader), through the key's
  low cut and high cut, at the key's gain. Attack is 0.1–100 ms and
  Release 1–3000 ms. **Hold** (on/off) keeps the envelope at its peak
  until the level falls to half of it, so a drum opens the filter for its
  whole body and not just its click. **S&H** (on, plus a sync rate)
  samples the envelope at that division and holds it: the filter moves in
  steps, in time.
- **Listen** sends the key, as filtered, to the track's output, to set the
  key by ear. The Compressor and Gate already listen like this.

### The output stage

drive (into the circuit) → filter → **Clip** (a soft clip at 0 dBFS, on
or off) → output gain (±24 dB) → dry/wet (equal power, the dry in time).
At any Res, Clip keeps a self-oscillating filter from going over full
scale. There is no oversampling, as decided. The drive's aliasing at high
settings is accepted and noted in the docs.

## Where it lives

- **Engine (MIT, `f_engine/fx/super_filter.odin`, built 2026-11-17):** a
  `Super_Filter` node with 4 inputs (2 audio, 2 key) and 2 outputs.
  - It filters in 32-frame pieces, each gathered whole first. Because the
    filter works its coefficients out at a render's two ends, only whole
    pieces give the same result at any block size. So the node is 32
    frames (0.67 ms) late, and reports that as its `latency`.
  - Parameter changes take effect at the start of the piece they fall in,
    or the next one.
  - For Vowel, the modulation transposes the formants, since the formant
    bank follows no cutoff. It is built from the `fx` filter (`filter_render`
  with a cutoff buffer) and two new `fx` units (built in step 1,
  `f_engine/fx/lfo.odin` and `follower.odin`):
  - `Lfo`: `lfo_render` over a `Beat_Clock`, usable elsewhere. The
    synth's LFO is the synth's own.
  - `Follower`: `follower_render`, with attack, release, Hold and S&H. Its
    output is in dB over 48 dB, so a quiet key still moves it. It reads the tempo and beat from the
  process context's transport for the synced modes and Retrigger. It
  publishes three atomics for the UI: the modulated cutoff (for each
  side), and the input and output peaks. Every parameter is in its
  `Param_Info` table, automatable and smoothed where continuous. The node
  has a doc comment and is exported, so `./scripts/docs.sh` adds it to the
  reference.
- **Pads model:**
  - `Effect_Kind.Super_Filter`, appended to the enum.
  - `keyable` includes it.
  - A new field on `Effect_Slot`, `key_lpf` (the key's high cut), saved
    from the next `PROJECT_VERSION`. `key_hpf` is the low cut already.
  - The key gain is a node parameter.
  - `key_allowed` already stops loops.
- **Engine wiring (`mixer_engine.odin`):**
  - The keyed path already puts a high-pass on the key.
  - It gains a low-pass after the high-pass, built only for SuperFilter.
  - Listen already works this way.
- **API:**
  - Parameters go through the existing effect-parameter calls.
  - New calls:
    - `effect_key_high_cut` and `effect_set_key_high_cut`.
    - `effect_super_filter_state`, returning the modulated cutoffs and the
      meters (for surfaces and scripts).
  - Run `scripts/api.py` and add a test for each new call.
- **Window UI (`ui_superfilter.odin`):**
  - Its own panel, laid out like the reference, in Pads' theme.
  - The left strip: the Sidechain section (its source, low and high cut,
    gain, Listen) and ▼ for the LFO's extras.
  - The display:
    - The spectrum, from the existing `spectrum` tap.
    - The response, computed from each type and circuit's linear prototype
      (`svf_response` for Clean; analytic for the two- and four-pole
      shapes, the comb and the formant bank) and drawn at the modulated
      cutoff each frame, so it moves with the LFO.
    - The knob's own curve, faint behind it.
    - The handle: drag across for Freq, up and down for Res, Shift for
      fine, double-click to reset.
  - Under the display, the envelope row. Below that, the LFO row: Amount,
    Rate (its label follows the mode), Wave (a small picture of the wave),
    Morph, Mode.
  - The Envelope Amount knob.
  - The right column: Drive, Circuit, Clip, Output, Dry/Wet.
  - The in and out meters at the edges.
  - The Rate knob pulses on the LFO's phase. The S&H light steps.
- **Push 2:**
  - It mirrors the same panel (Push 2 mirrors Pads): the display drawn
    offscreen, the spectrum and curve included.
  - Encoder pages:
    1. Freq, Res, Morph, Type, LFO Amt, Rate, Envelope, Dry/Wet.
    2. Drive, Circuit, Slope, Clip, Output, Wave, Wave Morph, Mode.
    3. Attack, Release, Hold, S&H, S&H Rate, Source, Key Low, Key High.
    4. Stereo, Phase/Spin, Offset, Retrigger, Smoothing, Key Gain, Listen.
  - The lower buttons switch pages, as the other devices do.
  - Shift is fine on every encoder.
- **Presets** (factory, in the browser under SuperFilter):
  1. Wobble 1/8
  2. Wobble 1/4 Triplet
  3. Duck to Kick (keyed from a pad, negative envelope)
  4. DJ Sweep
  5. Talk Box (Vowel, slow LFO)
  6. Comb Shimmer
  7. Random Steps (S&H 1/16)
  8. Slow Pad Sweep (4 bars)
  9. Auto-Wah (envelope, Band)
  10. Stereo Spin

## Tests

- **DSP, through `testkit.render`:** finite output, zero allocations on the
  rt thread, and the same result at any block size, for every type × circuit.
  The behaviour each one promises:
  - Low attenuates an octave above the cutoff by its slope (±2 dB), and so
    on for each type.
  - DJ at the middle is flat within 0.5 dB.
  - Dry/Wet at 0 is the input, bit for bit.
  - Clip keeps the output at or under 0 dBFS with Res at its maximum and
    drive at its maximum.
  - A synced LFO's period matches the tempo, and its phase is the same
    after a jump.
  - Phase 180° puts the sides in opposition.
  - Retrigger (bar) restarts the LFO at each bar.
  - The envelope opens on the key and not on the input when keyed.
  - Hold keeps it open while the level stays above half.
  - S&H steps at its division.
  - The modulated cutoff the node publishes matches the curve that is drawn.
- **Model:** saving and loading every parameter, `key_lpf`, keying from a pad
  and from a bus, `key_allowed` refusing a loop, and Listen.
- **API:** the new calls, and `--check`.
- **e2e:**
  - Add SuperFilter to a pad.
  - Drag the handle; Freq and Res change.
  - Pick a type; the Morph label follows it.
  - Key it from a pad.
  - Push 2 pages: each encoder moves its parameter.
  - Screenshots of the panel and the Push display.
- **Profile:** the cost of one stereo instance for each circuit, at 48 kHz
  and 128-frame blocks, on the cloud ARM machine and x86. The aim is
  under 2 % of a core for Clean and under 6 % for Ladder and Diode on the
  Graviton. Measure first; the user picks any fixes.

## Build order

For every internal device (this one first), the window's UI and Push 2's
are built in the same step, never one after the other: Push 2 mirrors
Pads, so one drawing serves both.

1. `Lfo` and `Follower` in `fx`, each tested (built 2026-11-17).
2. The `Super_Filter` node: the types, circuits, modulation and output
   stage, with its DSP tests and profile (built 2026-11-17).
   - On an Apple-silicon Mac at `-o:speed`, one stereo instance with the
     LFO and envelope moving, at 48 kHz in 128-frame blocks:
     - Clean: 0.42 % of a core.
     - Analog: 0.50 %.
     - Dirty: 0.69 %.
     - Diode: 0.77 %.
     - Ladder: 0.88 %.
     - Phaser: 1.16 %.
   - The Graviton and x86 profile ran at the end (step 5).
3. Pads model, engine wiring (the key's high cut), save/load, API
   (built 2026-11-18).
   - SuperFilter is always keyed in the graph: keyed from nothing, its
     own input feeds the key's filters, so the low and high cut and
     Listen work on itself too.
   - `dsp.Wet` (every slot's on/off) now delays its dry signal by the
     effect's latency, so a late effect (SuperFilter, the Limiter's
     lookahead, a plug-in) fades without combing and stays in time
     switched off.
   - Slots keep up to 32 parameters (24 before; SuperFilter has 30).
4. The panel, in the window and on Push 2 together: one drawing of the
   display and the controls serves both (Push 2 mirrors Pads), and the
   encoder pages are wired with it. Each piece is checked in both places
   before the next: screenshots of the window and of the Push display,
   and e2e on the mouse and on the encoders.
   - Built 2026-11-18 (`apps/pads/ui_superfilter.odin`). The display is
     one drawing (`sf_display`) in both places.
   - Its response is measured: an impulse through the filter stage
     (`fx.super_filter_impulse`), read by an FFT, once per change of the
     settings. The live cutoff only moves that curve along the
     frequencies, so the curve follows the LFO each frame for nothing.
   - The window: Type, Circuit, 24 dB and Clip on the slot's header line;
     the display (the handle: Freq across, Res up and down); two rows of
     knobs (filter, output stage, envelope; LFO, key gain, Hold, S&H).
     The sidechain's row and the LFO's extras fold away behind buttons on
     the display; the sidechain row stays open while it has a key or
     filters. It fits the 1440 x 900 window unscrolled.
   - Push 2: the same display over four banks, Filter, Circuit, Envelope
     (with the key's source and cuts) and LFO (with Listen). On, the
     banks, Remove on the lower row.
5. Presets, docs (reference, a guide page), full suites (built
   2026-11-18).
   - The ten presets are factory effect presets (`EFFECT_PRESETS`,
     `apps/pads/model/fx_presets.odin`), the first of any effect's. They
     are listed under SuperFilter in the Library's Effects and loaded by
     `effect_load_preset` (the slot's key kept). Duck to Kick can't name
     the kick: its info says to choose it.
   - Docs: the Effects guide's SuperFilter section, Pads' guide, the
     reference.
   - Profile, one stereo instance, the LFO (Spin) and envelope moving,
     48 kHz, 128-frame blocks, `-o:speed`, as a share of a core:

     | | Mac (Apple silicon) | Graviton (t4g) | x86 (DO droplet) |
     |---|---|---|---|
     | Low, Clean 12 dB | 0.54 % | 0.98 % | 1.36 % |
     | Low, Analog 24 dB | 0.51 % | 1.15 % | 1.57 % |
     | Low, Dirty 24 dB | 0.70 % | 1.41 % | 2.00 % |
     | Low, Ladder 24 dB | 0.89 % | 1.43 % | 1.91 % |
     | Low, Diode | 0.78 % | 1.37 % | 1.88 % |
     | DJ | 0.32 % | 0.99 % | 1.37 % |
     | Comb | 0.39 % | 1.17 % | 1.55 % |
     | Vowel | 0.59 % | 1.80 % | 2.42 % |
     | Phaser | 1.17 % | 1.59 % | 2.39 % |

     The worst block (p99) was 108 µs of the 2667 µs a block has (x86,
     Vowel).
   - The display's measurement (an impulse of 4096 and an FFT, once per
     change of a setting): 0.07–0.42 ms on the Mac, 0.19–0.41 ms on
     Graviton, 0.21–0.63 ms on x86. On x86 it took 2–4 ms until
     flush-to-zero was turned on for it: the impulse's tail decays into
     denormals. (The synth's `measure_filter` has the same tail, without
     flush-to-zero.)

## Read but not taken

- Oversampling: 2× or 4× for the drive and clip stages. Left out to save
  CPU on small devices.
- Key tracking and envelopes triggered by notes. SuperFilter is an audio
  effect. A synth's filter already has these.
- SuperFilter in the Perform effects or in the synth's rack. It can be
  added later; its node doesn't care where it sits.

## Later: the other devices

After SuperFilter, the existing internal devices (Compressor, Gate,
Limiter, Saturation, Bit-crusher, Delay, Reverb, Chorus, Flanger, Phaser,
Ring mod, Comb, Pitch shift, Cutter, Stutter, Distortion, EQ, Filter, the
simple filters, and the synth's pages) are redesigned the same way: a
panel of their own, drawn once for the window and Push 2 together, each
showing what it does to the sound. Planned and asked about device by
device when SuperFilter is done.
