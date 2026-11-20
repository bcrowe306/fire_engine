---
title: "Push 2: the MIDI effects' and plug-ins' panels"
description: The pad's note repeat and arpeggiator, and CLAP plug-ins (in a slot, as an instrument) on Push 2's display - their pictures, their banks, the lower row.
---

# Push 2: the MIDI effects' and plug-ins' panels

Part of [the other devices' panels](/design/push2-devices/), in the
conventions of [Push 2 in Pads](/design/push2/) ("One way everywhere"):
a picture of what the device does over its knobs, named banks (◀ ▶ page
them, the page strip names them), choices as dropdowns, the lower row only
the device's own choices.

Code: `apps/pads/ui_ctl_fx_midi_plugin.odin` (the panels) and
`apps/pads/ui_fxpic_midi_plugin.odin` (the pictures: `mp_midi_picture`,
`mp_plugin_picture`, each drawing into a size it's given from plain values,
so Pads' window can use them later). Tests:
`tests/e2e/test_push2_fx_midi_plugin.py`.

## The pad's MIDI effects

The MIDI page of a pad's chain (▲ ▼ to it, or `ui_show midi`): note repeat
and the arpeggiator on the pad's live notes (the sequencer's go straight
to the pad).

| Bank | Knobs |
|---|---|
| Repeat | Rate (dropdown: 1/4, 1/8, 1/8 T, 1/16, 1/16 T, 1/32, 1/32 T), Gate (%) |
| Arpeggiator | Mode (dropdown: Up, Down, Up & Down, Random, As played), Rate (dropdown), Octaves (dropdown: 1..4), Gate (%) |

A gate's turn is one undo step (a gesture); each dropdown step is one.

**Lower row:** Repeat, Arpeggiator, Latch, each lit while on. (Mute +
Device and Delete + Device don't apply: the MIDI page always stays.)

**Picture:** one bar on the beat grid (sixteenths faint, the beats
numbered), the playhead running across it (stopped: the clock's own bar,
faint), where the transport is at the top right. It shows the bank shown's
effect:

- *Repeat:* a hit a step of Rate, Gate long; those played this bar bright,
  those to come dimmer, the one under the playhead lit. Off, dim and
  "(off)". When the arpeggiator is on too it plays instead (the router runs
  one effect a pad, the arpeggiator first), and the caption says so; the
  same for the toolbar's Note Repeat, which overrides a pad's.
- *Arpeggiator:* its notes as a roll, step by step at Rate, Gate long, in
  the pattern fire:perform's `Arp` plays: sorted low to high (As played:
  in the order they came), Up & Down playing its ends once, Random from its
  default seed, climbing Octaves (a faint line at each octave). The notes
  it walks are those held on the pad now (Keyboard mode's keys, the pad
  itself, MIDI notes into it), else the last ones played ("last played"),
  else a demo chord (0, 4, 7) until it has heard any. The caption reads
  "Up · 2 octaves · 1/16 · gate 50 % · latch · 3 notes held".

What is held is read on the UI's side (`Api.keys_held`, `App.held`, the
capture's notes back from the engine): the arpeggiator's own held keys are
the audio thread's and aren't read. Its notes come back as held ones while
recording, so a note an octave or more above one already in isn't taken as
a new one; a new chord starts after 0.6 s with nothing held.

## Plug-ins

A CLAP plug-in in an effect slot, or as a pad's instrument. Its parameters
come from the plug-in, so the banks aren't placed by hand:

- **Banks of eight** (seven after Perform's Intensity, column 0, should a
  plug-in ever be a Perform effect: the API doesn't allow one today),
  **named for the parameters' CLAP module** where the plug-in gives one (its
  last part: "Synth/Osc 1" is "Osc 1"; a second bank of one module "Osc 2";
  each module's parameters together, in the order the modules first come),
  else **by number**: "1–8", "9–16", "17–19". The module is read from the
  plug-in's own parameter info once (fire:clap doesn't keep it) and kept
  while the plug-in is shown.
- **Stepped parameters are dropdowns** of the plug-in's names for their
  steps (`value_to_text`), read once; where it names them only by their
  number ("1.00") or not at all: Off and On for two steps, else whole
  numbers.
- The knobs stay `param_knob` (undo, automation and the touch as the
  window's), their values read as the plug-in reads them ("375.00 ms",
  "-6.0 dB": its `value_to_text`, asked on the main thread, never the
  audio's, and kept per parameter until its value moves); the number where
  the plug-in gives no text.

**Picture:** at the left, who it is: its name large and its vendor and
version (an instrument: its pad's letter and name first, in the pad's
colour, as `ctl_pad_card` had it); how many parameters and banks. In the
middle, the banks as a map: a cell each, its name and a tick a parameter,
the one shown lit (five a row, up to three rows, narrower for more). At the
right, the parameter whose encoder is touched, large, with its value as
the plug-in reads it ("874.87 ms") and where it is in its range; let go, it
stays as "Last turned"; before any, "Turn an encoder".

**Lower row:** Open Editor / Close Editor (the plug-in's own window on the
computer), where the plug-in has one (`ctl_editor_button`). In a slot, On
is Mute + Device and Remove is Delete + Device; an instrument is removed
(the pad cleared) with Delete + Device. Loading and "Could not load" are
`ctl_plugin`'s as before.

A plug-in instrument's knobs set its pad's Sound (`param_set`):
`control_effect_param` sent them to `effect_set_param`, which has no place
for an instrument, so they didn't move (the window's as well); it now sends
an instrument's there.

## Checked

`tests/e2e/test_push2_fx_midi_plugin.py`: the MIDI effects' two banks,
every knob both ways (the dropdowns a step each), a gate's turn undone in
one step, the lower row's three on and off and lit; the arpeggiator over
three held keys (Keyboard mode) and after they're let go. Fire Delay
(FireOdin.clap) in a pad's slot: one bank "1–8", its first and last knobs,
Sync a dropdown, an encoder touched, Mute + Device, Delete + Device. Fire
Test Gain: its module's bank ("Main"). Fire Synth as a pad's instrument:
three banks, the first and last of each. Fire Test Sine: Open Editor on
the lower row. The display saved for each and looked at. Drawing time on
an M-series Mac: about 50 µs (MIDI), 60–80 µs (plug-ins).
