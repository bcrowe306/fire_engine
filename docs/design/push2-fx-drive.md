---
title: "Push 2: Distortion, Ring mod, Saturation and Bit-crusher"
description: The drive effects' panels on Push 2's display: banks, knobs, pictures.
---

The drive family's panels on Push 2's display (docs/design/push2-devices.md;
the conventions: docs/design/push2.md, "One way everywhere"), 2026-11-19:
`fx_panel_drive` in `apps/pads/ui_ctl_fx_drive.odin`, its pictures in
`apps/pads/ui_fxpic_drive.odin`.

**Where they are.** The Distortion is one of the synth's effects
(`pm.synth_twin`): an effect slot, a Perform effect and the synth's
Effects tab hold the same parameters and show the same panel. The Ring mod
is one of Pads' own: a slot or a Perform effect. In a slot the knobs start
at the first encoder (the eighth is free); as a Perform effect, Intensity is
the first encoder of every bank and the effect's knobs follow it; on the
synth's Effects tab the effect picker is the first encoder and On is the
lower row's last button.

**The lower row.** Neither has a choice of its own for it: it's empty (On
is Mute + Device, Remove is Delete + Device; on the synth's tab, On is
button 8).

**The pictures** draw from plain values (the effect's settings as they
play now, automation included, and the output's spectrum when there is
one) into a size they're given, so Pads' window can use them later. Each
pane has what it is and its main settings at its top left; an effect that's
off draws dimmed, "(off)" after its name. A Perform effect's pictures are
as hard as it's held (its mix times its Intensity, as
`pm.perf_effective` plays it: "Mix 100% × Intensity 60%").

**The signal.** The engine has no tap inside these effects (the
ProSaturator's signal ring and harmonics are its own), and none was added:
the pictures that need the input (the curve's moving dots) are drawn from
the parameters, with a test sine. What the slot puts out *is* tapped (the
watched slot, `pm.watch_read`): a slot's pictures show its output's
spectrum behind the filter's response and the ring mod's sidebands while
it plays. The synth's tab has no such tap for its effects: no spectrum
there.

## Distortion

| Bank | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| Main | Drive | Type ▾ | Mix | Filter ▾ | Cutoff | Resonance | Blend |

One bank: the seven fit, and the picture shows all three of what they do
at once. Cutoff, Resonance and Blend read in brackets while Filter is "No
filter". Drive reads by its type: dB for the clips and folds, bits for the
bit crusher ("4.3 bits"), the rate it's held at for the down-sampler
("1.02 kHz"; the picture: "held 47 samples (1.02 kHz)"). Blend reads as
the filter it makes ("Low-pass", "Band-pass", "Low 40% · Band"). Type and
Filter are dropdowns.

**The picture**, three panes:

- **The curve**: what each input level (±1.25 across) comes out as, the
  dry signal's diagonal behind; the type's shape at its drive and mix (a
  ramp through `fx.distortion_render`, the filter left out: it works in
  time). The bit crusher's steps show as steps (few enough bits, they're
  visible); the down-sampler holds in time, not level: its curve is the
  diagonal, its caption the hold.
- **A sine through it**: three cycles of a 200 Hz sine at 0.8 through the
  real distortion (filter and mix included) over the clean one: the clip's
  flat tops, the folds, the stairs, the sample-and-hold.
- **The filter**: its response (measured: an impulse through the same
  12 dB digital filter, read between the FFT's bins so the low end has no
  steps), its cutoff a dot, "before" or "after" the curve; "No filter":
  flat. The slot's output spectrum behind it.

## Ring mod

| Bank | 1 | 2 |
|---|---|---|
| Main | Frequency | Mix |

Frequency turns in ratios (1 Hz to 5 kHz on one encoder) and reads "2.50
Hz", "440 Hz", "1.20 kHz"; Mix "100 %" (the generic knob read "1.00").

**The picture**, two panes:

- **In time**: a 200 Hz tone times the carrier, mixed, over two of the
  carrier's cycles (10 ms at least, half a second at most): each column
  the output's reach, so a slow carrier reads as the tone swelling and
  falling, a fast one as the new wave; the carrier and the tone faint
  behind.
- **Sidebands**: on a log axis, the tone (a mark on the axis; a bar as
  loud as the dry part of the mix), the two sidebands it becomes (tone ±
  carrier, half the wet part each, their frequencies over them), the
  carrier a dashed line; a lower sideband under 20 Hz is said, not drawn.
  The slot's output spectrum behind.

## Saturation and Bit-crusher

The app's old effects, no longer offered in Add. A slot saved with one is
made a Distortion when the project loads (`pm.convert_slot`, from
`read_slot`; `new_effect` does the same, so the shell's `insert` and a new
project's Perform effects 10 and 16 make them the same way): the
Saturation as Soft clip at its drive and mix, the Bit-crusher as Bit crush
with the drive its bits come to, at its mix. So an old project's slot shows
the Distortion's panel with those settings, and its name is "Distortion".
A slot of either kind that somehow wasn't converted (none can be made)
keeps the generic panel.

## Checked

`tests/e2e/test_push2_fx_drive.py`: each in a slot (with a sample), as a
Perform effect, and the Distortion on the synth's tab; a new project's
Perform Bit-crusher, Ring mod and Saturation; an old Saturation and
Bit-crusher slot (`insert`): the bank count, every knob moving its
parameter (choices too), Intensity on the first encoder in Perform, the
synth tab's picker and On, Mute + Device and Delete + Device; the display
saved for every bank, after the knobs turned, with the filter after, and
while the pad plays. The panel's drawing time is printed (`DRAW ...`).
