---
title: "Push 2: Chorus, Flanger and Phaser"
description: The modulation effects' panels on Push 2's display: banks, knobs, pictures.
---

The modulation family's panels on Push 2's display (docs/design/push2-devices.md;
the conventions: docs/design/push2.md, "One way everywhere"). All three are
the synth's effects (`pm.synth_twin`), so an effect slot, a Perform effect
and the synth's Effects tab hold the same parameters and show the same
panel (2026-11-19): `fx_panel_modulation` in `apps/pads/ui_ctl_fx_modulation.odin`, its
pictures in `apps/pads/ui_fxpic_modulation.odin`.

**Where it is.** In a slot the knobs start at the first encoder (the
eighth is free). As a Perform effect, Intensity is the first encoder of
every bank and the effect's knobs follow it; on the synth's Effects tab,
the effect picker is the first encoder of every bank and On is the lower
row's last button. A slot saved with the app's old chorus, flanger or
phaser settings is converted to the synth's when it loads
(`pm.convert_slot`), so there is no older layout to show.

**The lower row.** None of the three has a choice of its own for it: it's
empty (On is Mute + Device, Remove is Delete + Device; on the synth's tab,
On is button 8).

**The pictures** draw from plain values (the effect's `fx` settings as
they play now, automation included, and its sweep's phase) into a size
they're given, so Pads' window can use them later. The sweep's phase is
the running effect's own while it moves; when no sound runs through it,
the picture's clock moves it at the effect's rate, so the sweep always
shows. Each keeps a column at its right (`MOD_SIDE`, 104 px) for its
LFO: the LFO's cycle in a box at its top with each side's place on it now
(the left side the device's colour, the right a bluer one), L and R under
it, and at the bottom the page strip; the effect is drawn left of the
column, so neither the box nor the strip covers it or its axis labels.
What it is and its main settings are at the top left. An effect that's off
draws dimmed, "(off)" after its name.

The Rate knob is the free rate (Hz) while Sync is Hz, the tempo division
while Sync is Tempo, Dotted or Triplet (as the window's Rate knob).

## Chorus

| Bank | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| Main | Rate | Depth | Voices ▾ | Feedback | Mix | Sync ▾ |
| Delays | Delay 1 | Delay 2 | Cutoff | Spread | | |

Cutoff and Spread are the feedback's band (its centre and width).

**Picture: its delays on a time line** (20, 40 or 80 ms long: steps, so a
knob moves the voices, not the scale). The left side's voices above the
middle, the right's below, a row a pair: each delay's sweep a faint bar,
where it is now a dot (Delay 1's filled, Delay 2's a ring), the echo the
feedback makes a fainter dot at twice the time; the dry signal a bar at 0
as tall as Mix leaves it. The LFO box: the sine, every voice's place on it.

## Flanger

| Bank | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| Main | Rate | Depth | Center | Feedback | Mix | Sync ▾ | Offset |

**Picture: its comb's response** on a linear axis to 10 kHz (a comb's
teeth are evenly spaced): the left side filled, the right a line, computed
from the delay as the sweep has it now, so the teeth spread and close as
it sweeps; feedback sharpens them (negative feedback moves peaks to
notches). Where the teeth are closer than the picture's points (a low
Center), each point is their average. The caption gives the delay now in
ms. The LFO box: the triangle, the sides apart by Offset.

## Phaser

| Bank | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| Main | Rate | Depth | Center | Feedback | Blend | Mix |
| LFO | Sync ▾ | Rate | Offset | | | |

Rate is on both banks: on LFO, beside Sync, to set the two together.

**Picture: its response** (log frequency, as the window's filters): the
twelve all-passes taken after four, eight or twelve by Blend, fed back
through their band by Feedback, mixed by Mix (`fx`'s phaser filter as a
linear filter: no saturation), at the centre the sweep has now, the left
side filled and the right a line; the notches sweep as it plays. Along the
top, the sweep's reach (Center ± Depth semitones), the centre marked and
each side's place on it now.

## Checked

tests/e2e/test_push2_fx_modulation.py: each device in a slot, as a
Perform effect and on the synth's tab: the banks, every bank's every knob
turning its parameter (Voices and Sync as choices; with Sync on a
division, Rate turns Tempo), Intensity first in every bank in Perform,
the synth tab's On and picker, Mute + Device and Delete + Device on a
slot; the display saved for every bank.
