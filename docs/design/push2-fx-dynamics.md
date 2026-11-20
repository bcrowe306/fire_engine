---
title: "Push 2: the dynamics' panels"
description: Compressor, Gate and Limiter on Push 2's display - their pictures, their banks of knobs, what moves with the signal.
---

# Push 2: the dynamics' panels

Part of [the other devices' panels](/design/push2-devices/), in the
conventions of [Push 2 in Pads](/design/push2/) ("One way everywhere"):
a picture of what the device does to the level over named banks of knobs
(◀ ▶ page them, the page strip names them), choices as dropdowns. None of
the three has a choice of its own for the lower row, so it stays empty: On
is Mute + Device, Remove is Delete + Device (on the synth's Effects tab,
button 8 is the effect's On, as on every effect there).

Code: `apps/pads/ui_ctl_fx_dynamics.odin` (the panels) and
`apps/pads/ui_fxpic_dynamics.odin` (the pictures: `draw_dyn_compressor`,
`draw_dyn_gate`, `draw_dyn_limiter`, each drawing into a rect it's given
from plain values, so Pads' window can use them later). Tests:
`tests/e2e/test_push2_fx_dynamics.py`.

**In Perform** every bank's first encoder is the effect's Intensity, the
device's knobs one column to the right. **The sidechain** (a pad's or a
bus's Compressor or Gate) is a bank of its own: Source (Itself, another
pad, a bus it doesn't feed), Key HPF (the key's high-pass, Off at 0 Hz) and
Listen; the last two are in brackets while it listens to itself, as the
window shows them only once it has a key. The picture says what it listens
to ("Key: Pad A2").

## Compressor

The slot's Compressor is the synth's three-band compressor (`synth_twin`),
so one panel serves a slot, Perform and the synth's Effects tab, on the
synth's parameters.

| Bank | Knobs |
|---|---|
| Main | Bands (dropdown: Three bands, Low + rest, Rest + high, One band), Attack, Release, Mix |
| Low, Band, High | the band's Upper (threshold), Upper Ratio, Lower (threshold), Lower Ratio, Gain |
| Sidechain | Source, Key HPF, Listen (a pad's or a bus's slot only) |

A band that goes with the one beside it (Bands not Three) keeps its bank,
its knobs in brackets.

Attack and Release read as times (`dyn_ms`: "1.4 ms", "28 ms", "1.25 s"):
the middle band's, the one every Bands setting uses
(`fx.compressor_band_ms`; the low band's are longer, the high's shorter:
2.8, 1.4 and 0.7 ms of attack, 40, 28 and 15 ms of release at 0.5). Their
0..1 scales the bands' times by e^(8x-4), so an encoder turns them in
ratios, about 5 % a detent (14 detents double them).

**The picture:** the three bands side by side. Each has its level in and
out now (two bars, -80..0 dB) and its transfer curve, input across, output
up: pressed down above Upper by Upper Ratio, lifted below Lower by Lower
Ratio (nothing under -60 dB lifted further, at most 30 dB up), then Gain,
as `fx.compressor_render` settles. Upper is a bright line, Lower a dim one;
a dot sits where the band's level is now (in, out), and the text under its
name says how far it is moving it ("up 4.2 dB"). The band whose bank is
shown is framed; a band not split off is dim and says "(with Band)"; its
range is written by its name (< 120 Hz, 120 Hz - 2.5 kHz, > 2.5 kHz).

The levels are the engine's own (`fx.Compressor.levels`, each band's mean
square in and out), read from the slot's chain (`pm.slot_chain`) or the
synth's (`pm.synth_chain`). Attack, Release and Mix aren't drawn.

## Gate

| Bank | Knobs |
|---|---|
| Main | Threshold, Range, Attack, Hold, Release, Hysteresis, Ratio |
| Sidechain | Source, Key HPF, Listen (a pad's or a bus's slot only) |

Attack, Release and Ratio turn in ratios (0.05 ms to 100 ms on one
encoder); the times read in ms or s.

**The picture,** left to right:

- **Its curve,** input across, output up (-90..0 dB): open (unity) above
  where it opens (Threshold), closed below where it closes (Threshold less
  Hysteresis, the band between shaded), turned down by Ratio to at most
  Range (`dsp.expander_curve`, as the gate does); the way up from closed, a
  faint line to the threshold. A dot where its level is now.
- **Its reduction now** (a bar, its full height the Range), "Open" or
  "Closed" and the dB beside it.
- **Its envelope:** the gain over a sound that opens it and leaves it
  (the sound faint behind): Attack up from the floor (-Range), open, Hold
  once the sound falls under where it closes, Release down to the floor;
  each stage as long as it is set on a log scale (0.05 ms to 3 s on one
  line), its time under it.

The reduction is the gate's meter (`pm.slot_reduction`). The level is what
the slot puts out (its watched output, `pm.watch_read`) plus the reduction:
its input. Keyed, what it hears isn't its input, so the dot isn't drawn.
The engine doesn't say where the gate is in its envelope (attack, hold,
release) or its detector's level: the envelope is drawn from the settings.

## Limiter

| Bank | Knobs |
|---|---|
| Main | Input, Ceiling, Release |

Release turns in ratios (1 ms to 2 s), reading in ms or s.

**The picture:** its curve (input across, output up, -48..0 dB: raised by
Input, flat at the Ceiling) with a dot where its level is now; its
reduction now (a bar, 0..24 dB, and its number); and the last four seconds
of it, from the top down, the output's level under it, the Ceiling a line.
The reduction is the limiter's meter, sampled each time the display draws
(every 20 ms kept, in the panel's own ring); the level is the slot's output
plus the reduction, less Input.

## Drawing time

The panels' drawing (`Ctl_State.fx_draw_us`, the e2e's `draw_us`), on an
M-series Mac at `-o:none` while the e2e suite ran: Compressor 60-135 µs,
Gate about 210 µs, Limiter about 65 µs.
