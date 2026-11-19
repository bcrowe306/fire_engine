---
title: ProSaturator
---

# ProSaturator

A waveshaping saturator for Pads, in the manner of Ableton's Saturator: a
choice of curves (and a Waveshaper with its own shape controls), Drive
into it, a Color pre-emphasis around it, a DC filter, a soft clip at the
output, Output and Dry/Wet, and a Quality switch for oversampling. Its
display draws the curve with the signal moving on it, the harmonics it
adds, the Color EQ and the levels in and out. It goes **alongside** the
existing Saturation and the synth's Distortion, in pad and audio-track
chains, buses and main. As with the other Pro devices, its window panel
and its Push 2 panel are built together, one drawing for both.

Status: built (2026-11-18).

## What it has

From the reference (Ableton's Saturator) and the decisions made:

| Section | Controls |
|---|---|
| Left | Drive (−36..36 dB), DC (on/off), Color (on/off) |
| Display | the curve with the signal on it, the harmonics, the Color EQ, meters in and out |
| Under the display | Type (the menu), Quality (Off, 2×, 4×) |
| Color (shown when on) | Base, Freq, Width, Depth |
| Waveshaper (shown for its type) | Drive, Lin, Curve, Damp, Depth, Period |
| Right | Soft Clip (on/off), Output (−36..+12 dB), Dry/Wet |

### The curves

Ten types, each our own voicing (no attempt to copy anyone's numbers):

- **Analog Clip:** a smooth knee into a hard ceiling.
- **Soft Sine:** a sine-shaped soft clip, the gentlest.
- **Bass Shaper:** soft on quiet signals, harder as it rises, for bass:
  the curve's knee moves with the level so lows keep their weight.
- **Medium Curve** and **Hard Curve:** tanh-like curves of two
  steepnesses.
- **Sinoid Fold:** past full scale the wave folds back (a sine folder).
- **Digital Clip:** a hard clip at ±1.
- **Tube:** asymmetric (a tanh with a fixed bias, the halves clipping
  differently): even harmonics.
- **Tape:** a soft symmetric curve with a gentle high-frequency loss
  that grows with the drive (a one-pole low-pass after the curve, its
  corner falling as Drive rises).
- **Waveshaper:** a curve built from six controls:
  - Drive (how far into the curve, 0..1),
  - Lin (the linear part kept, −1..1),
  - Curve (a cubic term, −1..1),
  - Damp (flattens small signals, a noise gate in the shaper, 0..1),
  - Depth (the amplitude of a sine term, −1..1),
  - Period (the sine term's density, 0..1).

Every curve is normalised so a quiet signal at 0 dB Drive comes out at
about the level it went in (unity slope near zero), except where the
curve itself can't (Damp, Fold).

### Around the curve

- **Drive:** gain into the curve, ±36 dB.
- **Color:** a pre-emphasis before the curve and its inverse after, so
  Color changes which frequencies saturate more than how the result
  sounds. Base (−1..1) is a low shelf at 200 Hz (±12 dB); Freq (30 Hz..
  18 kHz), Width (0..1, the bell's width) and Depth (−1..1, ±12 dB) a
  bell. The inverse after the curve takes back the EQ's level change, not
  its effect on the distortion.
- **DC:** a 10 Hz high-pass after the curve, for asymmetric types (Tube,
  the Waveshaper with Curve) that leave an offset. On by default.
- **Soft Clip:** a gentle tanh after everything, so the output never
  passes full scale.
- **Output:** −36..+12 dB. **Dry/Wet:** 0–100 %, the dry in time with
  the oversampling.
- **Quality:** Off, 2× or 4× (`dsp.Oversampler` around the curve and
  Tape's filter). The oversampler's latency is the node's; a change makes
  a new node (as ProEq's Oversampling).

## The display

One drawing (`ps_display`) for the window and Push 2.

- **The curve:** input across, output up, −1..1, on a subtle grid (the
  axes and quarters). The type's static curve at the current Drive and
  Waveshaper settings (`pro_saturator_curve`, contextless), drawn as the
  node computes it.
- **The signal on it:** the last ~50 ms of input (after Drive and the
  Color pre-emphasis) plotted along the curve as fading dots, so how hard
  it is driven shows as how far up the curve they reach. From a small
  ring the node fills (256 points, sampled every 8 frames), read from any
  thread.
- **Harmonics:** a strip of bars under the curve (in the window; on Push
  2, at its right): the first eight harmonics of the loudest partial of
  the input, in dB, as the output has them against the input
  (a 2048-point FFT of each, from taps inside the node, at the UI's rate).
- **The Color EQ:** when Color is on, its pre-emphasis response drawn
  faint across the display's lower part, in dB (±12).
- **Meters:** input (after Drive) and output, at the display's edges,
  peaks held a second.

## Where it lives

- **Engine (MIT, `f_engine/fx/pro_saturator.odin`):** a `Pro_Saturator`
  node, 2 in and 2 out.
  - Parameters (about 18): Type, Drive, DC, Color, Base, Freq, Width,
    Depth, Waveshaper Drive, Lin, Curve, Damp, Depth, Period, Soft Clip,
    Output, Dry/Wet, Quality (a creation setting, as ProEq's
    Oversampling).
  - Drive, Output, Dry/Wet and the Waveshaper's knobs smoothed per frame
    (the shaper's coefficients from the smoothed values); the Color EQ
    redesigned on change, smoothed by the SVF; changes on their exact
    frame, so any block size gives the same output.
  - Readouts (atomics): peaks in and out; the signal ring for the curve;
    the input and output taps for the harmonics.
  - Exported helpers: `pro_saturator_curve(values, x) -> y`,
    `pro_saturator_color_response(values, hz) -> db`,
    `pro_saturator_defaults`, `pro_saturator_readout`,
    `pro_saturator_signal`, `pro_saturator_read_taps`.
- **Pads model:** `Effect_Kind.Pro_Saturator`; Quality in the slot key (a
  new node when it changes). Not keyable.
- **API:** parameters through the effect-parameter calls;
  `effect_pro_saturator_state` (the meters, the harmonics as eight
  numbers in a struct) for surfaces and scripts.
- **Window UI (`apps/pads/ui_prosaturator.odin`):** laid out like the
  reference, in Pads' theme. The Color row and the Waveshaper row show
  only when they apply (Color on; the Waveshaper type), each a row of
  knobs under the display.
- **Push 2:** the same display. Banks on the lower row (On at its left,
  Remove at its right):
  1. **Main:** Drive, Type, Output, Dry/Wet, Soft Clip, DC, Color, Quality.
  2. **Color:** Base, Freq, Width, Depth (greyed while Color is off).
  3. **Waveshaper:** Drive, Lin, Curve, Damp, Depth, Period (shown for
     the Waveshaper type; for the others, the bank says so).
- **Presets** (factory, in the Library under ProSaturator):
  1. Warm Bus (Analog Clip, a little drive)
  2. Tube Glow (Tube, soft clip on)
  3. Tape Kiss (Tape, gentle)
  4. Bass Weight (Bass Shaper)
  5. Fuzz (Hard Curve, a lot of drive)
  6. Fold Lead (Sinoid Fold)
  7. Digital Crunch (Digital Clip, no oversampling)
  8. Presence Drive (Color: a bell at 3 kHz into Medium Curve)
  9. Parallel Grit (Hard Curve, 30 % wet)
  10. Shaper Bells (the Waveshaper, Depth and Period up)

## Tests

- **DSP, through `testkit.render`:** finite output, zero rt allocations,
  block-size invariance, for every type at every Quality, Color on and
  off. And what it promises:
  - Each curve's static shape: a slow ramp through the node (Drive 0,
    DC, Color and Soft Clip off) comes out on `pro_saturator_curve`
    (±0.01).
  - Unity near zero: a −40 dBFS sine comes out within 0.5 dB at Drive 0
    for every type but the Waveshaper with Damp and Fold.
  - Harmonics: Tube makes a 2nd harmonic a symmetric curve doesn't;
    Digital Clip makes odd harmonics.
  - Oversampling: a 10 kHz sine driven hard aliases less at 4× than off
    (energy at non-harmonic frequencies), and the reported latency
    matches.
  - DC on leaves no offset after Tube.
  - Soft Clip keeps the output at or under full scale.
  - Color: the pre-emphasis and its inverse cancel at a small level (a
    quiet sweep comes out flat within 0.5 dB with Color on).
  - Tape's high loss grows with Drive.
  - Dry/Wet 0 is the input (as late as Quality), bit for bit.
  - The readouts: the signal ring advances, the peaks match.
- **Model:** save and load; Quality making a new node.
- **API:** the new call, `--check`.
- **e2e:** add ProSaturator to a pad; turn Drive; pick each type; Color
  on (its row appears) and its knobs; the Waveshaper's row; Quality;
  Push 2's banks; screenshots of the panel and the Push display with a
  loop playing (the signal on the curve, the harmonics).
- **Profile:** one stereo instance of each type at each Quality, Color
  on, at 48 kHz in 128-frame blocks, on the Mac, Graviton and x86. The
  aim on Graviton: under 1 % of a core off, under 4 % at 4×. Measure
  first; the user picks any fixes.

## Build order

The window's UI and Push 2's are built in the same step.

1. The `Pro_Saturator` node: the ten curves, Drive, Color, DC, Soft Clip,
   Output, Dry/Wet, Quality, the readouts and taps; DSP tests and a Mac
   profile. (built 2026-11-18,
   `f_engine/fx/pro_saturator.odin`, `tests/fx/pro_saturator_test.odin`).
   - 18 parameters. It works in 64-frame chunks (its oversamplers'
     block), every change on its frame: the output is the same at any
     block size.
   - Color runs at the graph's rate, before and after the oversampled
     curve; Tape's low-pass runs at the curve's rate, its corner falling
     from 18 kHz as Drive rises past 0 dB (3.6 kHz at +24).
   - Quality is a creation setting (`Pro_Saturator_Settings.quality`); 2×
     is 31 frames late, 4× a few more.
   - Mac (Apple silicon, `-o:speed`), Drive 12 dB, Color on, 48 kHz,
     128-frame blocks, as a share of a core:

     | | Off | 2× | 4× |
     |---|---|---|---|
     | Analog Clip | 0.47 % | 0.87 % | 1.69 % |
     | Medium Curve | 0.20 % | 0.52 % | 0.92 % |
     | Tube | 0.21 % | 0.53 % | 0.94 % |
     | Tape | 0.17 % | 0.50 % | 0.95 % |
     | Waveshaper | 0.26 % | 0.68 % | 1.31 % |

     Analog Clip's knee takes two `pow`s a sample: the dearest.
2. Pads model (Quality in the slot key), save and load, API. (built 2026-11-18).
   - Quality joins the slot's key (`Slot_Key.lookahead`, shared with
     ProComp's Lookahead): a change makes a new node.
   - The harmonics are the model's (`pro_saturator_harmonics`): a
     2048-point FFT of the node's input and output taps, the input's
     loudest partial above 20 Hz and its first eight harmonics on each
     side, in dB against that side's fundamental.
   - API: `effect_pro_saturator_state` (the peaks, h1..h8 of the
     output).
3. The panel, in the window and on Push 2 together: the display (the
   curve, the signal on it, the harmonics, the Color EQ, the meters), the
   left, right and conditional rows, the Push banks. Each checked in both
   places: screenshots, e2e on the mouse and the encoders. (built 2026-11-18,
   `apps/pads/ui_prosaturator.odin`).
   - One drawing (`ps_display`): the meters at its edges, the curve a
     square at the left (as wide as it can be on a short display), the
     harmonics' eight bars at its right (the output's filled, the
     input's a line on each), Color's EQ a faint line across its lower
     part.
   - The window: Drive, DC and Color at the left; Type (all ten in sight)
     and Quality under the display; Color's row while it is on, the
     Waveshaper's for its type; Soft Clip, Output and Dry/Wet at the
     right.
   - e2e: `tests/e2e/test_prosaturator.py`.
4. Presets, docs (the Effects and Pads guides, the reference), full
   suites at both opt levels, the profile on the cloud ARM and x86
   machines. (built 2026-11-18).
   - The ten presets, under ProSaturator in the Library.
   - Docs: the Effects guide's ProSaturator section, Pads' guide, the
     reference.
   - Full suites pass at both opt levels on the Mac, Graviton and x86;
     `task app:test` 304 of 305 on the Mac (the segv crash-report test,
     failing before ProSaturator).
   - Profile, one stereo instance, Drive 12 dB, Color on, 48 kHz,
     128-frame blocks, `-o:speed`, as a share of a core (Off / 2× / 4×):

     | | Mac | Graviton | x86 |
     |---|---|---|---|
     | Analog Clip | 0.47 / 0.87 / 1.69 % | 0.87 / 2.02 / 3.91 % | 1.34 / 3.25 / 5.80 % |
     | Medium Curve | 0.20 / 0.52 / 0.92 % | 0.50 / 1.24 / 2.31 % | 0.83 / 2.13 / 3.54 % |
     | Tube | 0.21 / 0.53 / 0.94 % | 0.52 / 1.28 / 2.39 % | 0.85 / 2.11 / 3.77 % |
     | Tape | 0.17 / 0.50 / 0.95 % | 0.41 / 1.11 / 2.09 % | 0.62 / 1.74 / 3.09 % |
     | Waveshaper | 0.26 / 0.68 / 1.31 % | 0.68 / 1.64 / 3.14 % | 0.96 / 2.41 / 4.49 % |

     Within the aim on Graviton (1 % off, 4 % at 4×), Analog Clip at 4×
     only just (3.91 %). Its knee's two `pow`s a sample are the cost; a
     cheaper knee (a rational one) is the fix, if wanted. The worst
     block (p99) 220 µs of 2667 (x86, Analog Clip, 4×).

## Read but not taken

- Ableton's exact curves and numbers: our own voicing, as with the other
  devices.
- More than 4× oversampling: 4× is enough for these curves at the drives
  they go to; 8× doubles the work again.
