---
title: ProComp
---

# ProComp

A clean compressor for Pads, in the manner of Ableton's: a transfer curve
with a dot where the level is now, the threshold, gain-reduction and
output meters around it, a picture of its activity over time, a
sidechain with its own EQ. It goes **alongside** the existing Compressor
(the synth's multiband), not in place of it, in pad and audio-track
chains, buses and main. As with SuperFilter and ProEq, its window panel
and its Push 2 panel are built together, one drawing for both.

Status: built (2026-11-18).

## What it has

From the reference (Ableton's Compressor) and the decisions made:

| Section | Controls |
|---|---|
| Left | Ratio, Attack, Release, Auto (release) |
| Display | three views: the transfer curve, the activity, the meters alone; Threshold and Output dragged by their arrows on the meters |
| Strip under the display | the view buttons, Knee, Lookahead (0, 1, 10 ms), Env (Lin or Log) |
| Right | Makeup (auto), Peak / RMS / Expand, Dry/Wet |
| Sidechain (folded row) | Source (itself, any pad, any bus), EQ on, EQ type, Freq, Q, Gain, the key's Gain, the key's Mix, Listen |

### The compressor

- **Feed-forward, stereo-linked:** one gain for both sides, from the
  louder.
- **Detection:** Peak (the rectified signal), RMS (a 10 ms window), or
  Expand: below the threshold the signal goes down by the ratio (a
  downward expander), above it untouched.
- **Ratio:** 1:1 to ∞:1 (the knob's top is ∞, a limiter). In Expand, 1:1
  to 1:∞ (a gate at the top).
- **Knee:** 0 to 18 dB, quadratic, centred on the threshold.
- **Attack and Release** (0.01–1000 ms, 1–3000 ms) on the gain
  reduction, in dB.
  - In Expand, Attack is how fast it opens and Release how fast it
    closes.
  - **Env:** Log (the envelope moves in dB, smooth on transients) or Lin
    (in linear gain, snappier).
  - **Auto** release: program-dependent. Short after a short peak, long
    after a sustained one (two release stages blended by how long the
    reduction has lasted), voiced by ear.
- **Lookahead:** 0, 1 or 10 ms. The signal is delayed and the detector
  sees it early, so the attack catches the transient. The node reports
  it as its latency; a change makes a new node (as ProEq's oversampling).
- **Makeup:** on, the compressed signal (not the dry under it) is raised
  by the gain reduction the curve gives at 0 dBFS (the static estimate,
  not a moving gain).
- **Output:** ±36 dB. **Dry/Wet:** 0–100 % (parallel compression, the dry
  in time with the lookahead).

### The sidechain

- Its key: its own input or any pad or bus (Pads' existing key sources,
  `key_allowed` refusing loops), taken as inputs 3 and 4.
- **EQ** (in the node): one filter on the key, a type (low-pass,
  band-pass, high-pass, notch, peak, low shelf, high shelf), Freq, Q and
  Gain (for peak and shelves). So a de-esser is a band-pass key at 6 kHz.
- **Gain:** the key's level, ±24 dB. **Mix:** how much of the key is the
  outside source and how much the ProComp's own input (0: its own, 100 %:
  the key's).
- **Listen:** the slot plays the key as it reaches the detector (after
  the EQ), to set it by: Pads' existing Listen on the slot.

## The display

One drawing (`pc_display`) for the window and Push 2.

- **Transfer curve:** input dB across, output dB up, −60 to 0 on a
  subtle grid (lines every 6 dB). The curve from the threshold, ratio,
  knee and mode, as the node computes it (`pro_comp_curve`). A ring on
  the curve at the threshold; a dot at the detector's level now (where
  the signal is on the curve), moving as it plays.
- **Activity:** the last 4 seconds scrolling right to left: the input
  level (filled, faint), the output level (a line) and the gain
  reduction from the top (filled, in the accent), with the threshold as a
  line across.
- **Meters alone:** the threshold, GR and output meters, wide.
- **Around the curve and the activity:** the input meter (peak and RMS)
  with the threshold's arrow on it (drag it up and down), the GR meter
  (from the top), the output meter with the output gain's arrow. Each
  meter holds its peak for a second.
- The view is the panel's (`App.pc.view`), shared by the window and
  Push 2, not saved.

## Where it lives

- **Engine (MIT, `f_engine/fx/pro_comp.odin`):** a `Pro_Comp` node, 4 in
  (the last two the key, silence if unwired) and 2 out.
  - Parameters (about 22): Threshold, Ratio, Attack, Release, Auto,
    Knee, Lookahead, Mode, Env, Makeup, Output, Dry/Wet, EQ on, EQ type,
    EQ Freq, EQ Q, EQ Gain, Key Gain, Key Mix, Keyed (whether inputs 3
    and 4 are wired, set by Pads).
  - Every continuous parameter smoothed per frame; changes at their
    exact frame, so any block size gives the same output.
  - It publishes atomics for the UI: input peak and RMS, the detector's
    level, the gain reduction, the output peak. A history ring for the
    activity view: one entry every 256 frames (about 5 ms) of the input,
    output and gain reduction, 1024 entries.
  - `pro_comp_curve(values, in_db) -> out_db` for drawing (contextless,
    the node's own static curve), `pro_comp_defaults`,
    `pro_comp_readout`, `pro_comp_history`.
- **Pads model:** `Effect_Kind.Pro_Comp`, keyable (the key source and
  Listen as the Compressor's). The lookahead joins the slot key (a new
  node when it changes). The key filters in the graph (SuperFilter's
  high-pass and low-pass) aren't used: its EQ is the node's.
- **API:** parameters through the effect-parameter calls;
  `effect_pro_comp_state` (the meters and the detector's level) and
  `effect_pro_comp_history` (the activity, as numbers, for surfaces and
  scripts).
- **Window UI (`apps/pads/ui_procomp.odin`):** laid out like the
  reference, in Pads' theme. The sidechain row folds away behind a button
  on the display, as SuperFilter's.
- **Push 2:** the same display. Banks on the lower row (On at its left,
  Remove at its right):
  1. **Main:** Threshold, Ratio, Attack, Release, Knee, Makeup, Output, Dry/Wet.
  2. **Detail:** Mode, Auto, Lookahead, Env, View, (empty), (empty), (empty).
  3. **Sidechain:** Source, EQ on, EQ type, EQ Freq, EQ Q, EQ Gain, Key Gain, Listen (the key's Mix with Shift on Key Gain).
  - The upper row picks the view (Curve, Activity, Meters), as tabs.
- **Presets** (factory, in the Library under ProComp):
  1. Glue Bus (2:1, slow attack, auto release)
  2. Drum Punch (4:1, 10 ms attack: the transient through)
  3. Vocal Leveler (3:1, RMS)
  4. Kick Duck (keyed: choose the kick)
  5. Parallel Smash (∞:1, fast, 35 % wet)
  6. Bass Control (4:1, 1 ms lookahead)
  7. Gentle Master (1.5:1, soft knee)
  8. Snare Snap (Expand below the body)
  9. Pumping 4/4 (keyed, long release)
  10. De-ess (its own input, the key's EQ a band-pass at 6.5 kHz)

## Tests

- **DSP, through `testkit.render`:** finite output, zero rt allocations,
  block-size invariance, in every mode, with and without a key, at every
  lookahead. And what it promises:
  - The static curve: a steady tone at each level comes out where
    `pro_comp_curve` says (±0.3 dB), at several ratios and knees.
  - ∞:1 holds the output at the threshold.
  - Expand turns a tone below the threshold down by the ratio.
  - Attack: after a step up, the reduction reaches 63 % of its way in
    about the attack time (Log). Release likewise.
  - Auto release: shorter after a click than after a held tone.
  - Lookahead: the output delayed by it exactly, a step's attack starting
    before the step arrives; the reported latency matches.
  - Makeup raises a 0 dBFS tone back to about where it went in.
  - Dry/Wet 0 is the input (delayed by the lookahead), bit for bit.
  - Keyed: the key's level drives the reduction, not the input's. The EQ
    band-pass at 6 kHz makes a 6 kHz key reduce more than a 100 Hz one.
    Key Mix 0 ignores the key.
  - The readout's gain reduction matches the gain the output shows.
  - The history ring advances one entry per 256 frames.
- **Model:** save and load of every parameter; keyed from a pad and a
  bus; Listen; a lookahead change making a new node.
- **API:** the new calls, `--check`.
- **e2e:** add ProComp to a pad; drag the threshold's arrow and the
  Ratio knob; switch the view; open the sidechain row and key it from a
  pad; Push 2's banks and view tabs; screenshots of each view in the
  window and on the Push display.
- **Profile:** one stereo instance in each mode, keyed and not, with the
  key EQ on, 10 ms lookahead, at 48 kHz in 128-frame blocks, on the Mac,
  Graviton and x86. The aim on Graviton: under 1 % of a core. The
  display's drawing per frame. Measure first; the user picks any fixes.

## Build order

The window's UI and Push 2's are built in the same step.

1. The `Pro_Comp` node: detection, the curve, the envelope (Log, Lin,
   Auto), lookahead, makeup, output, dry/wet, the key and its EQ, the
   readouts and history; DSP tests and a Mac profile. (built 2026-11-18,
   `f_engine/fx/pro_comp.odin`, `tests/fx/pro_comp_test.odin`).
   - 21 parameters. The node takes its key from inputs 3 and 4 when
     `PC_PARAM_KEYED` says they are wired (Pads sets it), mixed with its
     own input by Key Mix; Listen is the node's own (it puts out what the
     detector hears, after the EQ), not the graph's.
   - Auto release: a fast release (60 ms) and a slow stage that follows
     the reduction down over 300 ms and lets go over 1.5 s, the deeper of
     the two taken: a click lets go quickly, a long squeeze slowly.
   - The lookahead is a creation setting (`Pro_Comp_Settings.lookahead`);
     its latency in frames comes from the rate at prepare, before the
     graph reads it.
   - Output gain, Dry/Wet and the key's gain glide over 10 ms (and jump
     before the first frame); every other change takes effect on its
     frame.
   - Mac (Apple silicon, `-o:speed`), 48 kHz, 128-frame blocks: 0.21–0.35
     % of a core in every mode, keyed with the EQ and 10 ms lookahead
     0.26 %. The worst block (p99) 12.5 µs of 2667.
2. Pads model (keyable, the lookahead in the slot key), save and load,
   API. (built 2026-11-18).
   - Keyable, as the Compressor (`key_allowed`, the key sources). Keyed,
     the graph wires its key into inputs 3 and 4 and Pads sends
     `PC_PARAM_KEYED`; Listen is sent to the node (`listens_itself`), so
     it plays the key after its own EQ, and from its own input too.
   - The lookahead is part of the slot's key (`Slot_Key.lookahead`): a
     change makes a new node.
   - API: `effect_pro_comp_state` (the levels, the detector's, the
     reduction) and `effect_pro_comp_moment` (one moment of the activity
     at a time: the API returns no arrays).
   - The readout's detector level is the block's loudest, so the dot on
     the curve holds still on a steady tone.
3. The panel, in the window and on Push 2 together: the three views, the
   meters and their arrows, the left, strip and right controls, the
   sidechain row, the Push banks and view tabs. Each checked in both
   places: screenshots, e2e on the mouse and the encoders. (built 2026-11-18,
   `apps/pads/ui_procomp.odin`).
   - One drawing (`pc_display`) in both places; under 90 px tall (a
     controller's display) it drops its labels and stretches the curve
     across.
   - The window: Ratio, Attack and Release at the left; the display with
     its views as small buttons at its top; under it Knee, Lookahead, Env
     and the mode; Makeup, Auto and Dry/Wet at the right. Its sidechain
     row (its own: the source, EQ, its type, Listen; then Freq, Q, Gain,
     Key Gain, Key Mix) folds away behind a button on the header line,
     open while it has a key, its EQ or Listen.
   - The meters' arrows: drag the input meter for Threshold, the output
     meter for Output (Shift: fine). Peaks hold a second.
   - e2e: `tests/e2e/test_procomp.py`.
4. Presets, docs (the Effects and Pads guides, the reference), full
   suites at both opt levels, the profile on the cloud ARM and x86
   machines. (built 2026-11-18).
   - The ten presets, under ProComp in the Library. Testing them found two
     faults, fixed with a test each: Makeup raised the dry under a
     parallel mix too (Parallel Smash peaked at 20), and Expand's attack
     and release were the wrong way round (a tone above its threshold
     came out nearly silent).
   - Docs: the Effects guide's ProComp section, Pads' guide, the
     reference.
   - Full suites pass at both opt levels on the Mac, Graviton and x86;
     `task app:test` 301 of 302 on the Mac (the segv crash-report test,
     failing before ProComp).
   - Profile, one stereo instance, 48 kHz, 128-frame blocks, `-o:speed`,
     as a share of a core:

     | | Mac | Graviton | x86 |
     |---|---|---|---|
     | Peak | 0.35 % | 0.58 % | 0.75 % |
     | RMS | 0.24 % | 0.57 % | 0.76 % |
     | Expand | 0.21 % | 0.54 % | 0.71 % |
     | Peak, Auto | 0.26 % | 0.59 % | 0.74 % |
     | Peak, keyed, EQ | 0.26 % | 0.64 % | 0.82 % |
     | RMS, keyed, EQ, 10 ms | 0.26 % | 0.71 % | 0.88 % |

     Under the aim on Graviton (1 %). The worst block (p99) 54 µs of
     2667 (x86).

## Read but not taken

- Character models (Opto, VCA, FET): clean only, as decided.
- Multiband: the existing Compressor is multiband already.
- Oversampling: a clean compressor's gain moves slowly enough not to
  need it.
