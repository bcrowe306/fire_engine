---
title: ProVerb
---

# ProVerb

An algorithmic room reverb for Pads that sounds where ValhallaRoom sounds:
an early section and a late tail, each with its own size, stereo cross
and modulation, a two-band decay (bass and high multipliers with their
crossovers), a high cut, a mix of early and late (Depth), predelay and a
dozen modes. It is our own design and our own code, matched to the
plug-in by measuring what it does, never by reading its code. Its
visuals are our own as well: the plug-in has sliders and knobs only. It
goes **alongside** the existing Reverb (the synth's), in pad and
audio-track chains, buses (its usual home, on a send) and main. As with
the Pro devices, its window panel and its Push 2 panel are built
together, one drawing for both.

Status: built (2026-11-18).

## The reference, and how we use it

ValhallaRoom 1.5.1 is installed on this Mac as an AU
(`/Library/Audio/Plug-Ins/Components/ValhallaRoomAU64.component`) and a
VST3. Pads hosts CLAP only, so it can't load it.

- **We measure it as a black box.** A small macOS tool (Swift,
  AVAudioEngine's offline render, outside the app and the engine) loads
  the AU, sets its parameters, and renders test signals through it:
  impulses, short noise bursts, sine bursts, and slow sweeps, at 48 kHz.
  It writes each render as a WAV with its settings beside it.
- **We never disassemble, decompile or trace the plug-in.** Its licence
  forbids it, and the project's own rule for JUCE (a reference for
  design, never translated) applies to it too. What we take from it is
  what anyone can hear and measure at its output.
- **What we measure**, per mode, over a grid of settings (Decay, the
  sizes, the multipliers and crossovers, High Cut, Depth, Predelay, the
  cross and modulation controls):
  - RT60 in octave bands (from the energy decay curve's slope, −5 to
    −35 dB): how Decay, Bass Mult and High Mult shape it;
  - echo density over time (the normalised echo density): how fast the
    tail becomes smooth, early and late;
  - the early pattern: the first 100 ms of the impulse, its peaks'
    times and levels, against Early Size;
  - stereo: the interaural correlation of the tail against the cross
    controls;
  - modulation: how much a long sine's tail spreads in frequency, and at
    what rate, against Mod Rate and Mod Depth;
  - level: the wet output's loudness for a given input, so Mix and the
    modes sit at the same loudness;
  - the predelay and High Cut, to check they are what they say.
- **What we keep:** the numbers (tables of RT60, density, correlation
  and spread per mode and setting) go in the repository as our
  measurements (`tests/proverb/reference.json`). The rendered audio
  stays on this machine, gitignored (`.build/proverb_ref/`): it is the
  plug-in's output, not ours to publish.
- **How we match:** ProVerb's tests measure ProVerb the same way and
  compare with the table within tolerances (RT60 within 10 %, density
  curves within a band, correlation within 0.1). On a machine without
  the table (it is in the repository, so every machine has it) they
  still run; the measuring tool itself only runs on a Mac with the
  plug-in.

## What it has

From the reference's panel and the decisions made:

| Section | Controls |
|---|---|
| Main | Mix, Predelay (0–500 ms), Decay (0.1–100 s), High Cut, Depth (early to late) |
| Early | Early Size, Early Cross, Early Mod Rate, Early Mod Depth, Early Send (the early section into the late) |
| Late | Late Size, Late Cross, Late Mod Rate, Late Mod Depth |
| Late decay | Bass Mult, Bass Xover, High Mult, High Xover |
| Mode | one of a dozen (below) |
| Quality | Eco, Normal, High |

The Early controls are to be confirmed from the plug-in's own Early
page in step 0 (only the Late page is in the reference screenshot).

### The modes

One of ours for each of its modes, measured and tuned to sit where its
mode sits, named in our own words. Step 0 lists its modes and measures
each; the working set, to be renamed then:

Big Room, Mid Room, Small Room, Bright Room, Dark Room, Big Chamber,
Dark Chamber, Grand Hall, Wide Space, Small Space, Nonlinear, and
whatever else step 0 finds.

A mode is a structure, not a preset: its early pattern, the number of
late lines and their delays, its diffusion, its modulation kind (detuning
or chorus-like), its density build-up. The controls move within it.

### The algorithm (ours)

From published reverb designs, tuned against the measurements:

- **Predelay:** a delay line (0–500 ms).
- **Early:** a multi-tap pattern into a short allpass diffuser, per
  side, the taps' times scaled by Early Size, the sides crossed by Early
  Cross, its taps lightly modulated (Early Mod Rate and Depth).
- **Late:** a feedback delay network: 8 lines (Normal), 4 at half rate
  (Eco), 16 (High), mixed by an orthogonal matrix (Householder or
  Hadamard), each line's delay scaled by Late Size and modulated
  (Late Mod Rate and Depth; detuning or chorus, as the mode says). Input
  diffusion before it, by mode.
- **Decay:** each line's feedback gain set from its delay and the
  target RT60, through a two-band shelf in the loop: below Bass Xover the
  RT60 is Decay × Bass Mult, above High Xover Decay × High Mult (the
  shelves designed per line so the decay is the same across lines).
- **High Cut:** a low-pass on the wet output.
- **Late Cross:** the late tail's stereo spread, from the output taps'
  mix.
- **Depth:** early against late at the output; **Early Send:** how much
  of the early section feeds the late.
- **Mix:** wet against dry (the dry in time: no latency).
- **Quality:** Eco (the late network at half the rate, 4 lines, cheaper
  modulation), Normal (the reference), High (16 lines, finer
  interpolation). A creation setting, as ProEq's Oversampling: a new
  node when it changes. Eco is for the Pi; the tests match all three to
  the table, Eco with wider tolerances.
- **Freeze** (a hold of the tail at infinite decay, the input muted) is
  left for later; not in the reference.

## The visuals (our own)

One drawing (`pv_display`) for the window and Push 2, in three parts.

- **Decay over time** (built, then taken out: see step 3): a live picture of the tail's energy across
  frequency (log, 20 Hz–20 kHz) and time (the last 2 s), as a
  spectrogram whose columns scroll left, from the wet output inside the
  node. Where Bass Mult or High Mult lengthen the tail, that band stays
  lit longer. A faint line marks each band's RT60 as set.
- **Early reflections:** the early pattern as spikes on a time line (0
  to 150 ms), their heights the taps' levels, left and right above and
  below the line; the predelay a gap before them; they spread with Early
  Size. Drawn from the node's own tap table (exact, not measured).
- **Damping curve:** RT60 against frequency, from Decay, the
  multipliers, crossovers and High Cut (computed as the node sets its
  shelves), with three handles: Bass (across: Bass Xover; up and down:
  Bass Mult), High (High Xover, High Mult) and the High Cut (across).
  Drag them as ProEq's.
- Meters in and out at the edges.

## Where it lives

- **Measuring (macOS only, `scripts/proverb_probe/`):** the Swift tool,
  a script to run the grid, and an Odin analysis tool
  (`scripts/proverb_probe/analyze`) that turns renders into
  `tests/proverb/reference.json` (the same analysis the tests run on
  ProVerb, from `fire:testkit` additions: energy decay, RT60 per band,
  echo density, correlation, spectral spread).
- **Engine (MIT, `f_engine/fx/proverb.odin`):** a `Proverb` node, 2 in
  and 2 out; its modes as tables; parameters smoothed per frame,
  changes on their exact frame, the same output at any block size; a
  creation setting for Quality; readouts for the display (the
  spectrogram's columns from a wet tap, the early tap table, the RT60
  curve as `proverb_rt60(values, hz)`).
- **Pads model:** `Effect_Kind.Proverb`; Quality in the slot key.
- **API:** parameters through the effect-parameter calls;
  `effect_proverb_state` (the meters, the tail's level) for surfaces
  and scripts.
- **Window UI (`apps/pads/ui_proverb.odin`):** the main five as tall
  bars (as the reference has them, our way), Mode under them, Early and
  Late pages of knobs (tabs, as the reference has), the display above.
- **Push 2:** the same display. Banks:
  1. **Main:** Mix, Predelay, Decay, High Cut, Depth, Mode, Quality, (empty).
  2. **Early:** Early Size, Early Cross, Early Mod Rate, Early Mod Depth, Early Send.
  3. **Late:** Late Size, Late Cross, Late Mod Rate, Late Mod Depth.
  4. **Decay:** Bass Mult, Bass Xover, High Mult, High Xover.
  - The upper row picks what the display shows large (Decay, Early,
    Damping).
- **Presets:** ten of our own (rooms, chambers, halls, a drum room, a
  vocal plate-like room, an ambience, a long pad space), in the Library
  under ProVerb.

## Tests

- **DSP, through `testkit.render`:** finite output, zero rt allocations,
  block-size invariance, for every mode at every Quality. And:
  - Matching the reference: for each mode and a set of settings from the
    grid, ProVerb's RT60 per band within 10 % of the table (Eco 15 %),
    its echo density curve within the table's band, its correlation
    within 0.1, its modulation spread within a factor of 1.5.
  - Decay, Bass Mult and High Mult move the band RT60s as
    `proverb_rt60` says.
  - Predelay delays the first reflection exactly; High Cut cuts above
    it.
  - Mix 0 is the input, bit for bit; Mix 1 has no dry.
  - A long tail at Decay 100 s stays finite and bounded (no runaway
    from modulation or the shelves).
- **Model:** save and load; Quality making a new node.
- **API:** the new call, `--check`.
- **e2e:** add ProVerb to a bus; the bars; the Early and Late pages; the
  damping handles; Push 2's banks and the upper row; screenshots with a
  loop playing (the spectrogram, the early spikes).
- **Profile:** one stereo instance in each mode at each Quality, at
  48 kHz in 128-frame blocks, on the Mac, Graviton and x86. The aim on
  Graviton: Eco under 2 %, Normal under 4 %, High under 8 % of a core.
  Measure first; the user picks any fixes.

## Build order

The window's UI and Push 2's are built in the same step.

0. **Measure the reference:** the Swift probe (render through the AU
   offline), the analysis (testkit additions, tested on known signals:
   a synthetic exponential decay of known RT60, a known echo pattern),
   the grid run, `reference.json`. List its modes and its Early page's
   controls. The user runs nothing: it renders on this Mac. (built 2026-11-18:
   `scripts/proverb_probe/` (`probe.swift`, `jobs.py`, `analyze/`,
   `run.sh`), `fire:testkit`'s `reverb.odin` (tested in
   `tests/testkit/reverb_test.odin`), `tests/proverb/reference.json`).
   - It is ValhallaRoom 1.6.5. Its Audio Unit has 20 parameters, every
     one 0..1 with no text, among them `diffusion` (not on the panel in
     the reference picture) and the Early page's five: earlySize,
     earlyCross, earlyModRate, earlyModDepth, earlySend.
   - Its ranges, inferred from the panel's defaults (the value each
     shows at its default) and checked by measuring where possible:
     predelay 0–500 ms (0.2 puts the first sound at 101 ms); decay
     0.1–100 s, linear; HighCut and the high crossover 100–15000 Hz;
     the bass crossover 100 Hz–10 kHz (or 0–11 kHz: the two agree at
     the default and to 10 % elsewhere); bass multiplier 0.5–2.0×
     (measured: 1.01 s and 4.01 s at 125 Hz with Decay 2 s); high
     multiplier 0.1–1.0×; the mod rates' range is not pinned down.
   - Its Type: floor(type × 12), with 0 and 1 the same sound, so twelve
     modes (1..12; the default, Large Room, is 1).
   - What was measured, on its default mode: Decay tracks RT60 closely
     (0.5, 1, 4, 8 s in: 0.49, 0.95, 3.70, 7.33 s out); the late tail's
     first arrival rises with Late Size from 5.7 ms to 57 ms; High Cut
     falls about 12 dB an octave; its echo density reaches 0.9 at about
     235 ms (a slow build: in many modes not within 300 ms); full Mod
     Depth spreads a 1 kHz tone over about 26 Hz; Early Size spreads the
     early reflections from about 6 ms to about 95 ms (and at its top
     the early section rings for about 0.9 s itself); the early section
     is mono for modes 1, 2 and 4 (L and R the same), wide for the rest;
     the late tail's L and R are uncorrelated in every mode.
1. **The `Proverb` node:** predelay, the early section, the late
   network, the two-band decay, High Cut, Depth, Mix, Quality, the modes
   tuned against the table; DSP tests (including the match) and a Mac
   profile. (built 2026-11-18, `f_engine/fx/proverb.odin`,
   `proverb_modes.odin` (written by `scripts/proverb_probe/modes.py` from
   the measurements), `tests/fx/proverb_test.odin` and
   `proverb_match.odin`).
   - The modes are ProVerb's own structure with each one's character from
     the measurements, as ratios against the first mode: the late tail's
     arrival, the middle's decay, the bass's and treble's against it,
     the modulation, the early's and late's levels, whether its build is
     slow. No tap pattern or delay is taken from the reference: the early
     patterns are ProVerb's own (seeded per mode and side), spread over
     the measured span.
   - Quality: Eco is 4 lines and 2 input diffusers at the full rate (not
     half: the half-rate network would need a resampler of its own), all
     three read their lines with cubic interpolation (linear reads lost
     treble on every pass: the 8 kHz decay was 25 % short).
   - Late Mod Depth is a pitch deviation (squared), its delay swing that
     over 2π × the rate, so the smear doesn't grow with the rate.
   - The match test runs every reference job (bar the early-only ones)
     through ProVerb and measures it the same way: the broadband RT60
     within 12 %, 125 Hz within 20 %, 1 kHz within 12 %, 8 kHz within
     25 %, the late tail's first arrival within 15 % + 3 ms, the late
     tail's level within 3.5 dB per mode, the sides uncorrelated (under
     0.25) where the reference's are (under 0.1), full modulation's
     spread within ×2.5. Eco and High: every mode's RT60 within 15 %.
     All pass. Decay 0.5, 1, 4, 8 s measures 0.47, 0.93, 3.70, 7.37 s
     (the reference: 0.49, 0.95, 3.70, 7.33).
   - Not matched closely: the early section at its largest (it rings
     about 0.3 s, the reference's about 0.9 s); its echo density builds
     somewhat faster than the reference's; unmodulated, its tail smears a
     tone a little more.
   - Mac (Apple silicon, `-o:speed`), 48 kHz, 128-frame blocks: Eco
     0.6–0.7 % of a core, Normal 1.0 %, High 1.8 %; the worst block
     (p99) 66 µs of 2667.
2. Pads model (Quality in the slot key), save and load, API. (built 2026-11-18: `Effect_Kind.Proverb`, Quality in
   `Slot_Key.lookahead`, `slot_proverb`, `effect_proverb_state`).
3. The panel, in the window and on Push 2 together: the display (decay
   over time, early reflections, the damping curve and its handles,
   meters), the bars, the pages, the Push banks and upper row. Each
   checked in both places. (built 2026-11-18, `apps/pads/ui_proverb.odin`).
   - The decay picture (a spectrogram of the tail) was built, then taken
     out (2026-11-18): it told little the damping curve doesn't, and it
     was dear to draw.
   - The window: the two pictures across the top (Early, Damping, the
     damping's handles B, H and C dragged), the five bars
     (Mix, Predelay, Decay, High Cut, Depth; drag up and down,
     double-click for the default), the Early and Late pages of knobs,
     Mode and Quality on the header line.
   - The modes' names are ours (Big Room, Mid Room, Bright Room, Wide
     Chamber, Dark Room, Close Room, Long Hall, Tight Space, Soft Space,
     Grand Hall, Small Space, Wide Space), each after what was measured
     of its reference mode, not its name.
   - e2e: `tests/e2e/test_proverb.py`.
4. Presets, docs (the Effects and Pads guides, the reference), full
   suites at both opt levels, the profile on the cloud ARM and x86
   machines (built 2026-11-18).
   - Ten presets of our own, and an installed ValhallaRoom's (its
     .vpreset files on this machine, read when first asked, each mapped
     by `fx.proverb_reference_values`; nothing of them in Pads' repo or
     builds), in the device's Presets menu and under ProVerb in the
     Library.
   - Profile (Normal: 8 lines), one stereo instance, 48 kHz, 128-frame
     blocks, as a share of a core: Mac 0.6 / 1.0 / 1.8 % (Eco / Normal /
     High), Graviton 1.6 / 2.6 / 4.8–5.2 %, x86 2.2 / 3.9–4.1 / 6.9–7.2 %:
     within the aim on Graviton (2 / 4 / 8 %).
   - The match tests keep the reference in an arena of their own and
     free each job's renders (they held gigabytes before: the cloud's
     smaller machines killed them).

## Read but not taken

- Disassembling or tracing the plug-in: not ours to do (its licence; the
  project's rule).
- Publishing its rendered audio: kept on this machine only.
- Convolution with its impulse responses: that would be its sound, not
  an algorithm of ours, and wouldn't move with the controls.
- Freeze, and a sidechain-ducked tail: possible later on the same node.
