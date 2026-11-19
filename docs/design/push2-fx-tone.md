---
title: "Push 2: Tone (EQ, Filter, the pad's EQ)"
description: The tone family's panels on Push 2's display - each device's response, its named banks of knobs and its lower row, wherever it can be.
---

# Push 2: Tone (EQ, Filter, the pad's EQ)

One family of [the devices' panels](push2-devices.md) on Push 2's display
(2026-11-19), following [the display's
conventions](push2.md#one-way-everywhere-the-displays-conventions):
a picture of what the device does over named banks of knobs (◀ ▶ page
them, the page strip names them), choices as dropdowns, On as Mute +
Device and Remove as Delete + Device.

Code: `apps/pads/ui_ctl_fx_tone.odin` (the panels), `apps/pads/ui_fxpic_tone.odin`
(the picture and the responses: procs that draw into a size they're given
from plain values, so Pads' window can use them later). Tests:
`tests/e2e/test_push2_fx_tone.py`.

**Where each can be.** The EQ and the Filter play the synth's algorithms
(their parameters are the synth's: `pm.synth_twin`), so the same panel shows
in an effect slot (a pad's, a bus's, Main's), as a Perform effect and on the
synth's Effects tab. The pad's EQ is the pad's own (three gains, not a slot).
Wherever it is:

- **A Perform effect:** Intensity is the first knob of every bank, the
  device's own after it. A held one is drawn as hard as it is pressed
  (`pm.perf_effective`: a low-pass closing toward its cutoff, a high-pass
  opening, the rest blended in).
- **The synth's Effects tab:** the effect picker is the first knob of every
  bank, On the lower row's last button. The picture is in the pad's colour.
- **Off** (Mute + Device, the synth's On, EQ On): the picture dims and its
  caption says so.

**Old projects' Low-, High- and Band-pass.** No longer offered, still read:
`pm.new_effect` and `pm.convert_slot` make each a Filter (the Digital model,
12 dB, its blend low, band or high, its cutoff and Q carried over) when it is
put in or read, Perform's first three included. So they show the Filter's
panel, its lower row lit on their response; no slot holds the old kinds
while Pads runs (were one to, the generic panel would draw it).

**The picture.** A response on a log frequency axis (20 Hz to 20 kHz, 100,
1k and 10k marked, a line each 6 dB, 0 dB stronger), shaded to 0 dB for an
EQ (its boosts and cuts) and to the floor for a filter (its pass band). Each
band's mark is a ring on the curve at its frequency; the band in focus is
filled, its own response drawn in its colour (low orange, band green, high
blue). Behind, faint, the spectrum of what the device puts out now: a
slot's (the tap `ctl_effect` watches), on the synth's tab the pad's sound;
for the pad's EQ, the pad's sound (before its EQ) through the EQ. The
responses are measured from the settings, with automation where it plays:
an impulse through the real filter (`measure_filter`, kept until the
settings change) for the synth's EQ and Filter; the state-variable design
itself for the pad's EQ. The engine is only read (the tap).

## EQ

Three bands in series: a low shelf (or, cut, a high-pass), a bell (or a
notch), a high shelf (or a low-pass); each a frequency, a gain and a
resonance (`fx.Eq_Band`).

**Picture.** The EQ's response, the three bands' marks (L, B, H). In focus:
the bank's band (Low, Band, High), or on the first bank the band whose knob
is held. Caption: the three modes, or the band in focus (its mode,
frequency and gain). The range is ±12 dB, ±18 (±24) while a gain or the
response's top passes 11 (17).

| Bank | Knobs |
|---|---|
| EQ | Low Freq, Low Gain, Band Freq, Band Gain, High Freq, High Gain |
| Low | Freq, Gain, Q, Mode (Low shelf, High-pass) |
| Band | Freq, Gain, Q, Mode (Peak, Notch) |
| High | Freq, Gain, Q, Mode (High shelf, Low-pass) |

A band that cuts keeps its Gain: the band's level (the digital filter's
gain applies whatever its style), so it is never in brackets. The
frequencies read in Hz and kHz and turn in semitones (their parameter is a
key: a log scale).

**Lower row.** Low Cut, Notch, High Cut: each band's mode, lit while it
cuts (the Mode dropdowns' choice, a press away).

## Filter

The synth's filter as an effect: eight models (Analog, Dirty, Ladder,
Digital, Diode, Formant, Comb, Phaser), each with its styles.

**Picture.** Its response measured from its settings (the nonlinear models
at a quiet level, near their linear selves), the cutoff's mark. Caption:
what the blend makes of the style (Low-pass, Band-pass, High-pass; Notch;
Peak; a shelf; or the blend's number between them), the cutoff, the
resonance; at the right, the model and style.

| Bank | Knobs |
|---|---|
| Filter | Cutoff, Res, Model, Style, Blend, Drive, Mix |
| Shape | Gain, Comb Offset, Vowel X, Vowel Y, Formant, Formant Q, Spread |

Model and Style are dropdowns (the style's names by the model). What a
model or style doesn't use is in brackets: Gain but on the Digital model
(its shelf's gain, Shelf Gain, on the Shelving style; its level on the
others), Comb Offset but on the Comb model, the vowel's five but on the
Formant model; Blend on the Formant model, Drive on Formant and Comb. Cutoff reads in Hz and kHz; the
offset and the formant's transposition in semitones.

**Lower row.** The blend's three, as the style names them: Low-pass,
Band-pass, High-pass (12 and 24 dB); Low-pass, Notch, High-pass (Notch /
pass swap); Band-pass, Peak, Notch; Low shelf, Peak, High shelf (Shelving).
Lit on the one the blend is at. None where the blend isn't a choice of
three (Dual notch / band, and the Formant, Comb and Phaser models).

## The pad's EQ

Three bands at fixed frequencies (`dsp.eq_create(3)`): a low shelf at
100 Hz, a bell at 894 Hz, a high shelf at 8 kHz, each ±15 dB.

**Picture.** Its response (flat while it is off, the marks dim), the
marks L, M, H, the band whose knob is held in focus. Caption: the three
gains, or the band held (its frequency and gain).

| Bank | Knobs |
|---|---|
| EQ | Low, Mid, High |

**Lower row.** EQ On. The pad's EQ is not an effect slot: Mute + Device
turns effects off and on and only says so here, and Delete + Device has
nothing to remove, so its switch stays a button of its own.
