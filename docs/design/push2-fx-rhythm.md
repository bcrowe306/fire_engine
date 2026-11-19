---
title: "Push 2: the rhythm and pitch panels"
description: Cutter, Stutter and Pitch shift on Push 2's display - their pictures on the tempo grid, their knobs, Perform's Intensity.
---

# Push 2: the rhythm and pitch panels

Part of [the other devices' panels](/design/push2-devices/), in the
conventions of [Push 2 in Pads](/design/push2/) ("One way everywhere"):
a picture of what the device does over its knobs, choices as dropdowns,
the lower row only the device's own choices. On is Mute + Device, Remove
is Delete + Device.

Code: `apps/pads/ui_ctl_fx_rhythm.odin` (the panels) and
`apps/pads/ui_fxpic_rhythm.odin` (the pictures: `rhy_cutter_picture`,
`rhy_stutter_picture`, `rhy_pitch_picture`, each drawing into a size it's
given from plain values, so Pads' window can use them later). Tests:
`tests/e2e/test_push2_fx_rhythm.py`.

The three are mostly played as **Perform effects**, held from a pad: there
every panel's first encoder is the effect's Intensity, the device's own
knobs one column to the right, and the picture shows the effect as it
plays at that intensity (where the pad is pressed, while it's held), with
its own setting faint beside it and both named in the caption ("Intensity
0.44 (its own 1/16)"). While not held, the caption says so.

Each device has three knobs at most, so each is one bank (named for what
it does; with one bank the page strip doesn't show).

**The tempo grid.** The cutter's and the stutter's pictures are one bar of
the transport (its meter's beats, sixteenths faint), the playhead running
across it, and at the top right where the transport is ("Bar 3 · beat 2 ·
120 BPM", or Stopped). Stopped, the clock's own bar runs on, as the cutter
still follows it. **Tempo divisions** (the cutter's Rate, the stutter's
Length) are dropdowns of their names, from 1/4 to 1/128 with dotted and
triplet ones between (1/8 D, 1/8 T...); a value between them (automation,
an old project) reads as beats and the dropdown shows the nearest.

## Cutter

| Bank | Knobs |
|---|---|
| Gate | Rate (dropdown: faster to the right), Duty (% open), Depth (%) |

**Picture:** the gate over the bar, cut by cut: open (full height) for
Duty of each cycle of Rate, closed down to Depth's floor (a line at its
level when it lets something through; the caption says "closes fully" or
"down 6.0 dB"). The cut under the playhead is lit, those already played
this bar brighter than those to come. The cycles are counted from the
clock's grid beat 0, as the effect counts them, so they're drawn where the
effect cuts. In Perform, the Rate it plays at (Intensity makes it up to
four times slower) fills, its own an outline behind.

**Lower row:** nothing (no choice of its own).

## Stutter

| Bank | Knobs |
|---|---|
| Repeat | Length (dropdown: longer to the right) |

**Picture:** the bar of signal coming through, and the slice. Not
repeating, the slice it would take is bracketed, Length long and ending
at the playhead, sliding along with it. Repeating, the slice it took is
bracketed where it was, and from where it started its copies take the
signal's place, each copy's start marked, those played bright and those to
come faint, counted in the caption ("repeating 1/8 ×4"). The signal is a
picture of one (a beat's kick, snare and hats), not what goes in, which
isn't kept: it shows where the sound goes, the repeated slice the same
shape each time.

**Lower row:** in a slot, button 1 is **Repeat (hold)**: it repeats while
held and stops when let go. (A slot's stutter repeats whenever the slot is
on, which Mute + Device also sets; this makes it playable from the Push.)
In Perform, its pad holds it, so the row is empty.

## Pitch shift

| Bank | Knobs |
|---|---|
| Shift | Pitch (whole semitones, ±24), Window (ms), Mix (%) |

**Picture:** a keyboard four octaves wide (C two octaves down to C two up,
each C labelled in semitones), the key played (0) in the middle and an arc
from it to the key it sounds as (between keys for a fraction of one), the
two as bright as Mix makes the dry and the wet. The caption names the
interval ("+7.0 st · a fifth up · ×1.498 the speed"; "+25 ct" off it). In
Perform, the interval it plays at (Intensity scales it toward unison)
is the bright arc and its own a faint one. At the right, the two read
heads: each one's window (Window long) fading in and out, half a window
apart, and a cursor through both where they read now, each head's gain on
it; it moves the way and (a twentieth as fast, so it can be seen) at the
rate the heads sweep.

**Lower row:** nothing.

## Checked

`tests/e2e/test_push2_fx_rhythm.py`: each device in a pad's slot (a sample
on the pad) and as Perform's first effect; its bank count; every knob
turned both ways moves its parameter (the dropdowns included, the cutter's
Rate to fewer beats as it turns right); Intensity on the first encoder in
Perform; Mute + Device and Delete + Device on a slot; the stutter's Repeat
(hold); the display saved stopped, while the transport plays, and in
Perform while held. The panels draw in well under a millisecond on an M-series
Mac (the probe's `fx_draw_us`).
