---
title: "Push 2: Space (Delay, Reverb, Comb)"
description: The space family's panels on Push 2's display - each device's picture, its named banks of knobs and its lower row, wherever it can be.
---

# Push 2: Space (Delay, Reverb, Comb)

One family of [the devices' panels](push2-devices.md) on Push 2's display
(2026-11-19), following [the display's
conventions](push2.md#one-way-everywhere-the-displays-conventions):
a picture of what the device does over named banks of knobs (◀ ▶ page
them, the page strip names them), choices as dropdowns, On as Mute +
Device and Remove as Delete + Device.

Code: `apps/pads/ui_ctl_fx_space.odin` (the panels), `apps/pads/ui_fxpic_space.odin`
(the pictures: procs that draw into a size they're given from plain
values, so Pads' window can use them later). Tests:
`tests/e2e/test_push2_fx_space.py`.

**Where each can be.** Delay and Reverb play the synth's algorithms (their
parameters are the synth's: `pm.synth_twin`), so the same panel shows in an
effect slot (a pad's, a bus's, Main's), as a Perform effect and on the
synth's Effects tab. Comb is a slot effect of its own (`dsp.COMB_PARAM_*`),
common as a Perform effect. Wherever it is:

- **A Perform effect:** Intensity is the first knob of every bank, the
  device's own after it.
- **The synth's Effects tab:** the effect picker is the first knob of every
  bank (another effect of the chain: its panel), On the lower row's last
  button. The picture is in the pad's colour.
- **Off** (Mute + Device, or the synth's On): the picture dims.

**Old projects.** Slots saved with the app's earlier delay and reverb
(milliseconds, beats, a ping-pong switch) are converted to the synth's
settings when the project is read (`pm.convert_slot`), so a slot never
holds them while Pads runs; were one to, it would get the generic panel.

**The signal.** A slot's pictures put the spectrum of what the slot puts out
now (the tap `ctl_effect` watches) behind the tone; on the synth's tab, the
pad's sound. A held Perform effect is drawn as hard as it is pressed. The
rest is drawn from the parameters (with automation where it plays): the
echoes and the reverb's tail are computed, not read from the engine.

## Delay

**Picture.** At the left, the echoes of one hit on a time line: the hit,
as loud as the dry, then each echo, the left side above the line and the
right below, as its style routes them (Mono and Stereo a line each side;
Ping-pong the input into the right, the right into the left, back through
the feedback; Mid ping-pong each side into the other), each as loud as
the mix and feedback make it (a ring where negative feedback turned it
upside down), until it falls under -30 dB; the beats at the project's
tempo behind (bars where beats would crowd). Its caption: the time (a
division, dotted or triplet when synced; each side's when they differ) and
the style. At the right, the tone: the band its feedback goes through
(Cutoff and Spread), each echo through it once more (the fainter lines),
over the spectrum of what it puts out.

| Bank | Knobs |
|---|---|
| Echoes | Time, Feedback, Mix, Sync, Style, Time R |
| Tone | Cutoff, Spread |

- **Time** follows Sync: free, a time in milliseconds (turned up: longer;
  its parameter is a rate, so it is drawn as the time it makes); synced, a
  dropdown of divisions (Freeze, 32/1 ... 1/64). Time R likewise, named
  "(Time R)" while the style is Mono (it has no say then).
- **Sync** (Free, Tempo, Dotted, Triplet) and **Style** are dropdowns.
- **Lower row:** the four styles (Mono, Stereo, Ping-pong, Mid ping-pong),
  the one it has lit. (Style is also a dropdown in Echoes, so every
  parameter is on a knob.)

## Reverb

**Picture.** At the left, the tail of one hit on a time line (0 to -60 dB):
the pre-delay a gap, the early reflections (the first trip round its loop,
denser the larger the size), then the fall of 60 dB in the decay time,
wavering with the chorus (its depth and rate), and dimmer the lows' and
highs' own falls (what the shelves take off each trip round the loop);
its caption the decay and pre-delay. At the right, how long it rings at
each frequency (its RT60 from the decay, size and shelves), what the
input's cuts take away shaded, over the spectrum of what it puts out.

| Bank | Knobs |
|---|---|
| Room | Decay, Size, Pre-Delay, Mix, Chorus, Rate |
| Tone | Lo Cut, Hi Cut (the input's), Lo Shelf, Lo Gain, Hi Shelf, Hi Gain (the tail's) |

- **Lower row:** nothing of its own (On: Mute + Device; on the synth's tab,
  its On).

## Comb

**Picture.** Its response on a straight frequency axis, so its teeth are
evenly spaced: at the frequency and each multiple, or, with the feedback
upside down, halfway between (an octave down, the odd harmonics only),
each tooth a dot (the first bright, named: its frequency and note), as
much of it as the mix (a held Perform effect: as hard as it is pressed),
over the spectrum of what it puts out. The axis spans about twelve teeth.

| Bank | Knobs |
|---|---|
| Comb | Frequency, Feedback, Mix |

- **Lower row:** All Harmonics and Odd Harmonics, the feedback's sign (the
  one it has lit): a press turns the feedback over, keeping its amount.

## Checked

- E2E on the encoders (`test_push2_fx_space.py`): each device in a slot,
  as a Perform effect and (Delay, Reverb) on the synth's Effects tab; the
  bank count; every bank's every knob moves its parameter (the choices
  too; the delay's times both synced and free); Intensity on every bank's
  first knob in Perform; the synth tab's picker and On; the lower rows;
  Mute + Device and Delete + Device. The display saved for every bank and
  looked at.
- Drawing time on this Mac (`fx_draw_us`): see the commit's report.
