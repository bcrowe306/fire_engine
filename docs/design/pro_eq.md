---
title: ProEq
---

# ProEq

An eight-band parametric EQ for Pads, in the manner of an "EQ Eight":
the input and output spectrum under the summed response, a numbered
handle for each band to drag, the selected band's Freq, Gain and Q at the
side, and a type and on switch for each band under the display. It goes
**alongside** the existing EQ (the synth's three bands), not in place of
it, in pad and audio-track chains, buses and main.

Status: built (2026-11-18).

## What it has

From the reference (an EQ Eight panel) and the decisions made:

| Section | Controls |
|---|---|
| Bands (×8) | On, Type, Slope (cuts), Freq, Gain, Q |
| Selected band (left strip) | Freq, Gain, Q of the band picked on the display or under it |
| Display | the input spectrum faint, the output solid, the summed curve, the selected band's own curve filled, boosts and cuts tinted, a subtle grid, the eight handles |
| Right column | Audition (headphones), Spectrum on/off, Mode (Stereo, L/R, M/S), Edit (A/B: which side's bands are shown and edited), Adaptive Q, Scale, Gain (output), Oversampling |
| Meters | input and output, at the panel's edges (as SuperFilter's) |

### Band types

- **Low cut, High cut:** a slope for each band: 12, 24, 36, 48 or 96 dB
  an octave (Butterworth, from second-order sections in a row; Q shapes
  the corner of the 12 dB slope and the last section of the others).
- **Low shelf, High shelf:** Gain below or above Freq; Q is the shelf's
  slope.
- **Bell:** Gain around Freq, Q its width.
- **Notch:** a cut to nothing at Freq, Q its width.
- **Band-pass:** passes around Freq only (0 dB at the peak), Q its width.
- **Tilt:** a first-order tilt through Freq: Gain up above it and the
  same down below (half of it each side).

Defaults, as in the reference: band 1 a low cut (off), 2 to 7 bells
spread evenly in octaves from 100 Hz to 8 kHz (2 and 7 shelves), 8 a
high cut (off). Bands 1 and 8 are off at first; the others are on and
flat.

### The filters

- **Zero latency, minimum phase.** Every band is a run of second-order
  sections designed so their magnitude matches the analog prototype up to
  Nyquist (Vicanek's matched second-order design), so a bell or shelf at
  16 kHz keeps its shape instead of cramping. Coefficients are worked out
  on the control side's values per 32-frame piece and smoothed between,
  so sweeps don't zip.
- **Oversampling (switch, off by default):** 2× through `dsp.Oversampler`
  around the whole band chain, for steep high bands and boosts near
  Nyquist. It adds the oversampler's latency (reported, so `dsp.Wet` and
  the graph keep it in time) and about twice the CPU.
- **Adaptive Q (on by default):** a bell's Q rises with its gain, so a
  big boost or cut gets narrower (voiced by ear; flat bands are
  unchanged).
- **Scale (−200..200 %, 100 by default):** multiplies every band's gain,
  shelves', bells' and tilt's; cuts, notches and band-passes are kept.
- **Gain:** the output, ±24 dB.
- A flat band (a gain type at 0 dB) or a band that is off costs nothing.

### Stereo

- **Stereo:** one set of eight bands for both sides (A).
- **L/R:** A filters the left, B the right.
- **M/S:** A filters the mid, B the side (encoded before the bands,
  decoded after).
- **Edit A/B** picks which set the panel shows and edits; the other set's
  curve is drawn faint. Edit is the panel's, not a parameter: it is not
  saved in the slot or automated.
- B starts as a copy of A the first time L/R or M/S is chosen.

### Audition

Held (the headphones button on, and a band's handle held or its
on-switch area held), the output is only what that band touches: a
band-pass at its Freq and Q (for a cut, at its corner). Let go, the EQ
plays as before. It is the slot's, as Listen is: not saved, not
automated.

## The display

Drawn once (`proeq_display`) for the window and Push 2, as SuperFilter's.

- **Grid (subtle):** vertical lines at 100 Hz, 1 kHz and 10 kHz a little
  stronger, the 2..9 multiples fainter; horizontal lines every 6 dB (the
  range follows Scale: ±12 dB at 100 %, more when a band goes past it),
  0 dB a little stronger. Labels along the bottom (100, 1k, 10k) and
  the left (12, 6, 0, −6, −12) as in the reference. All at low alpha in
  the theme's colours, under everything else.
- **Spectrum:** the input faint (a filled outline), the output solid over
  it, from two spectrum taps on the slot (before and after), at the
  existing tap's rate. Off with the Spectrum switch.
- **Curve:** the summed response of the shown set, worked out from each
  band's analog prototype at 16 points an octave (cheap: no impulse to
  measure; the matched design follows the prototype), each frame, so it
  follows automation.
- **Tint:** the area between 0 dB and the curve, green for boosts and red
  for cuts, at low alpha.
- **Selected band:** its own curve, filled in its colour, under the summed
  curve.
- **Handles:** a numbered circle per band on the curve at its Freq (and
  Gain for the gain types; cuts, notches and band-passes sit at 0 dB).
  Selected: filled. On: outlined. Off: grey.
  - Drag across: Freq. Up and down: Gain (gain types) or Q (the others).
    Shift: fine. Alt-drag up and down, or the mouse wheel: Q.
    Double-click: the band on or off. Click: select.
- **Other set (L/R, M/S):** its curve, faint, in the other colour.

## Where it lives

- **Engine (MIT, `f_engine/fx/pro_eq.odin`):** a `Pro_Eq` node, 2 in and
  2 out. It is new rather than an extension of `dsp.Eq`, which stays as
  it is: `dsp.Eq` is an SVF chain with no slopes, sides or matched design.
  - Parameters: 16 bands (8 for A, 8 for B) × On, Type, Slope, Freq,
    Gain, Q (96), then Mode, Adaptive Q, Scale, Gain and Oversampling: 101
    in all, each in its `Param_Info` table, automatable and smoothed
    where continuous.
  - Exported helpers for the UI: `pro_eq_response(values, set, hz)` and
    `pro_eq_band_response(values, set, band, hz)` (the prototype,
    contextless), `pro_eq_defaults()`.
  - It publishes the input and output peaks for the meters.
  - Audition is a runtime flag (`pro_eq_audition(node, band)`, an atomic),
    not a parameter.
- **Pads model:**
  - `Effect_Kind.Pro_Eq`, appended.
  - Slots hold up to 32 parameters; ProEq needs 101. A slot will keep
    only its parameters that differ from the defaults (sparse), up to
    `MAX_EFFECT_PARAMS`, raised to 112. To be measured in step 2: the
    slot's size in undo snapshots, and whether a separate band table on
    the slot is better.
  - A new `PROJECT_VERSION` if the saved form changes.
- **Engine wiring:** a second spectrum tap after the slot (the first is
  already before it) for ProEq only.
- **API:**
  - Parameters through the existing effect-parameter calls.
  - New calls: `effect_pro_eq_state` (the meters, the shown set),
    `effect_pro_eq_audition` and `effect_set_pro_eq_audition`,
    `effect_pro_eq_spectrum` (the post tap's bins, for surfaces and
    scripts), and the panel's selected band and Edit side
    (`effect_pro_eq_selected`, `effect_set_pro_eq_selected`).
  - Run `scripts/api.py` and test each new call.
- **Window UI (`apps/pads/ui_proeq.odin`):**
  - Laid out like the reference: the selected band's Freq, Gain and Q
    knobs on the left; the display; the right column; under the display,
    eight band cells (a type menu with its picture, an on switch with
    the band's number; Slope in the cell's menu for cuts).
  - The display taller than SuperFilter's (about 120 px), still fitting
    the 1440 × 900 window unscrolled.
- **Push 2:** the same display (Push 2 mirrors Pads), drawn offscreen.
  - The **upper row** picks a band (lit in its colour, dim when off);
    Shift + an upper button turns it on or off. Touching an encoder in
    the Bands bank selects that band too.
  - Banks on the lower row (On at its left, Remove at its right, as
    SuperFilter):
    1. **Band:** Freq, Gain, Q, Type, Slope, On, Scale, Gain (output).
    2. **Bands:** the eight bands' Freq.
    3. **Global:** Mode, Edit, Adaptive Q, Oversampling, Spectrum,
       Audition, Scale, Gain.
  - Shift is fine on every encoder; Delete + touching an encoder resets
    it.
- **Presets** (factory, in the Library under ProEq):
  1. Clean Low End (low cut 24 dB at 30 Hz)
  2. Kick Punch
  3. Snare Body and Crack
  4. Vocal Presence
  5. De-mud (a cut at 300 Hz)
  6. Air (a high shelf)
  7. Telephone (band-pass)
  8. Mid/Side Widen (M/S: side high shelf, mid low cut)
  9. Master Polish (gentle tilt and a low cut)
  10. Hi-Hat Tame (a high cut and a cut at 8 kHz)

## Tests

- **DSP, through `testkit.render`:** finite output, zero rt allocations,
  the same result at any block size, for every type, slope and mode, with
  and without oversampling. And what each promises:
  - Flat bands (gain 0, or every band off): the input, bit for bit.
  - A bell of +12 dB at 1 kHz: +12 dB at 1 kHz (±0.2), the half-gain
    width matching Q; at 16 kHz too (matched: no cramping, ±0.5).
  - Each cut slope an octave past its corner: its slope (±1.5 dB).
  - Shelves at their gain far from Freq; notch under −40 dB at Freq.
  - Tilt: +g/2 and −g/2 at the ends.
  - The node's response matches `pro_eq_response` (the drawn curve) at
    every 1/3 octave within 0.5 dB (2 dB for cuts within an octave of
    Nyquist without oversampling).
  - L/R: a band in A touches only the left. M/S: a band in B on a mono
    input does nothing.
  - Scale 0: flat (except cuts); 200: twice the gains.
  - Adaptive Q narrows a big bell.
  - Oversampling: the latency reported matches the output.
  - Audition: only the band's region.
- **Model:** save and load of every parameter (A and B), the slot's
  sparse form, undo of a drag as one step.
- **API:** the new calls, `--check`.
- **e2e:** add ProEq to a pad; drag a handle (Freq and Gain change), the
  wheel (Q); pick a type and a slope; turn a band off; Edit B in M/S;
  Push 2: each bank's encoders, the upper row selecting bands;
  screenshots of the panel and the Push display.
- **Profile:** one stereo instance, all eight bands on (a mix of types,
  the cuts at 48 dB), at 48 kHz in 128-frame blocks, on the Mac, Graviton
  and x86, oversampling off and on. The aim on Graviton: under 2 % of a
  core off, under 5 % on. The display's curve and spectra on each
  platform. Measure first; the user picks any fixes.

## Build order

The window's UI and Push 2's are built in the same step.

1. The `Pro_Eq` node: the band types and slopes, the matched design,
   stereo modes, Adaptive Q, Scale, oversampling, audition, the response
   helpers; DSP tests and a Mac profile (built 2026-11-18,
   `f_engine/fx/pro_eq.odin`, `tests/fx/pro_eq_test.odin`).
   - Each section is designed as a biquad matched to its analog shape
     (poles by their impulse response, zeros by magnitude at DC, Nyquist
     and the band's frequency), then run as a state-variable filter with
     the same response (its poles as g and k, its zeros as a mix of the
     SVF's three outputs), so moving settings don't upset it.
   - Settings move on a 16-frame grid from the reset, smoothed (12 ms)
     between: the output is the same at any block size with no latency.
     Before the first grid point they jump.
   - Oversampling is a creation setting (`Pro_Eq_Settings.oversample`,
     31 frames late at 2×): a graph reads a node's latency only as it
     builds, so the Pads slot makes a new node when it changes.
   - `pro_eq_curve` designs the bands as the node does and evaluates
     their biquads: the drawn curve is the node's response (within
     0.5 dB at every third of an octave, tested).
   - Mac (Apple silicon, `-o:speed`), all eight bands on (48 dB cuts at
     both ends), 48 kHz, 128-frame blocks: 0.66 % of a core, the same in
     M/S with 16 bands, sweeping or not; oversampled 1.75–1.81 %. The
     worst block (p99) 30 µs, 91 µs oversampled, of 2667. The curve at
     320 points: 0.04 ms.
2. Pads model (the sparse slot or band table, measured), engine wiring
   (the post tap), save and load, API (built 2026-11-18).
   - Slots keep up to 112 parameters (32 before), every ProEq parameter
     held (not sparse): a slot's parameters take 896 bytes (256 before),
     so a pad's five slots about 3 KB more, and so each undo step of a
     pad. Simpler than a band table, and B can be copied from A.
   - Oversampling is part of the slot's key (`Slot_Key.oversample`):
     changing it makes a new node, as a new kind does.
   - The input spectrum comes from the node itself (`fx.pro_eq_read_input`,
     a tap inside it) and the output from the watched slot's tap, as
     before: no second tap in the graph.
   - `pro_eq_set_mode`: leaving Stereo while B is as it started copies A
     into B, one undo step.
   - API: `effect_pro_eq_state` (peaks, the band auditioned),
     `effect_set_pro_eq_audition`, `effect_set_pro_eq_mode`. The selected
     band and the Edit side are the panel's (the window and Push 2 share
     them in the app), not the API's.
   - No new project version: slots save their parameters as before.
3. The panel, in the window and on Push 2 together: the display (grid,
   spectra, curve, tint, the band's own curve, handles), the band cells,
   the right column, the Push banks and upper row. Each checked in both
   places: screenshots of the window and the Push display, e2e on the
   mouse and the encoders. (built 2026-11-18,
   `apps/pads/ui_proeq.odin`).
   - One drawing (`pe_display`) in both places. The curves come from
     `fx.pro_eq_curve` each frame (0.04 ms), so they follow automation.
   - The window: Mode, Edit and Adaptive Q on the slot's header line; the
     selected band's Freq, Gain and Q at the left; the display (136 px)
     and the band cells under it; Audition, Spectrum, 2× Quality
     (Oversampling), Scale and Gain at the right.
   - The summed curve is drawn light, not in the accent, so the green and
     red tints stay apart from it.
   - The selected band, the set edited, Audition and the spectrum switch
     are the app's (`App.pe`), shared by the window and Push 2.
   - Audition plays while a handle is held (or, on Push 2, the Band bank's
     Freq, Gain or Q is touched), within 150 ms.
   - e2e: `tests/e2e/test_proeq.py` (the window's handle, menus, slopes,
     on switches, M/S and Edit B; Push 2's upper row and banks).
4. Presets, docs (the Effects and Pads guides, the reference), full
   suites at both opt levels, the profile on the cloud ARM and x86
   machines. (built 2026-11-18).
   - The ten presets are factory effect presets (`EFFECT_PRESETS`),
     listed under ProEq in the Library's Effects.
   - Docs: the Effects guide's ProEq section, Pads' guide, the reference.
   - Full suites pass at both opt levels on the Mac, Graviton and x86
     (ALSA loopback skipping on Graviton); `task app:test` 297 of 299 on
     the Mac, the two failures the segv crash-report test (failing before
     ProEq) and ProEq's own Library test, fixed since (it scrolls to the
     list's end) and passing.
   - Profile, one stereo instance, all eight bands on (48 dB cuts at both
     ends), 48 kHz, 128-frame blocks, `-o:speed`, as a share of a core:

     | | Mac (Apple silicon) | Graviton (t4g) | x86 (DO droplet) |
     |---|---|---|---|
     | Stereo | 0.66 % | 1.30 % | 1.46 % |
     | Stereo, sweeping | 0.65 % | 1.39 % | 1.62 % |
     | M/S (16 bands) | 0.66 % | 1.46 % | 1.68 % |
     | Oversampled | 1.75 % | 3.06 % | 3.76 % |
     | Oversampled, sweeping | 1.80 % | 3.16 % | 4.05 % |
     | M/S, oversampled | 1.81 % | 3.23 % | 4.09 % |

     Under the aim on Graviton (2 % plain, 5 % oversampled). The worst
     block (p99) 218 µs of 2667 (x86, oversampled, sweeping). The curve
     at 320 points: 0.04 ms (Mac), 0.11 (Graviton), 0.15 (x86).

## Read but not taken

- Linear phase: an FFT mode with fixed latency. Left out for CPU on small
  devices; oversampling covers the high bands.
- A sidechained or dynamic EQ (bands that move with a key). Possible
  later on the same node.
- More than eight bands.
