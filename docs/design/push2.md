---
title: Push 2 in Pads
description: A native-feeling Ableton Push 2 in Pads - the kit's anti-aliased drawing and TrueType text, Pads drawing its own views for the display, and the Push 2 surface's modes, in stages.
---

Ableton Push 2 works in Pads today through fire-surface's example
(`push2_odin`): its display over USB, pads, encoders and buttons, in any
host with `fsurf.daw`. This is the plan to make it feel native in Pads:
its modes laid out on the display as Live does, with Pads' own views
(the sequencer, the sound editor, the mixer, waveforms, the browser) and
Pads' look.

Choices made (2026-11-16): Open Sans the kit's default font; every view
of Pads' (sequencer, device, mixer, clip, browser); every mode (Mix,
Device, Note/Scale, Session, Browse, Clip).

## Where things live

- **fire-surface's draw kit** (host-neutral): anti-aliased shapes and
  TrueType text (stb_truetype, CPU), Open Sans bundled (OFL). Any surface,
  any host, any platform (the Pi, later mobile).
- **Pads draws views** (`fire.pads`): a view of Pads' (`View_Kind`: the
  sequencer, a device, the mixer, a clip, the browser) at a size it's
  asked, with Pads' widgets, fonts and theme, offscreen on the GPU, read
  back a frame later as RGBA. Only Pads offers it.
- **Pads' Push 2 surface** (`apps/pads/surfaces/push2`, GPL with Pads):
  linked into Pads (`surfaces_add_static`), so a Push 2 works with nothing
  installed. It uses `fire.pads` for what `fsurf.daw` doesn't say, and the
  views. fire-surface's `push2_odin` stays the host-neutral example.

## The display

960 x 160 at 30 frames a second (a steady stream: Push 2 turns its display
off without one). Each mode lays out:
- a strip of eight columns, one an encoder, each with its name and value,
  lit while its encoder is touched (Push 2's encoders send touch notes)
- the mode's view: drawn by the surface (the kit), or by Pads (a view),
  or both (a view with the surface's labels over it)
- the upper and lower button rows' labels, as the buttons do in this mode

## Modes

| Mode | Display | Encoders | Pads | Buttons |
|---|---|---|---|---|
| Mix | eight strips: meter, volume, pan, sends (Pads' mixer view) | volume / pan / sends pages | as before | upper: mute or solo; lower: select |
| Device | the selected pad's sound: its device's view (filter curve, envelopes, LFOs) | its parameters, a bank each page | as before | upper: banks; lower: devices in the chain |
| Note / Scale | the keyboard or drum layout; Scale: roots and scales on the display | Scale: root, scale, in key, layout | keyboard in key or chromatic; drums: 16 pads + steps | Scale, Layout, Octave |
| Session | clip names in their colours, playing ones moving | (volumes) | the launcher, scenes on the right | stop row |
| Browse | the browser: folders and files, previewed | scroll, choose | (as before) | load, back |
| Clip | the selected pad's sample or clip: waveform, start, end, loop | start, end, loop, gain | as before | warp, loop |
| Sequencer | the selected pad's sequence: steps and notes (Pads' view) | step's note, velocity, length, nudge | the bottom rows: steps; top: the pad's notes | page, length |

## Stages

1. **The kit: anti-aliasing and TrueType** (fire-surface; built,
   fire-surface 4b39b15: pure Odin, no stb). Shapes with
   coverage (lines, rects, rounded rects, circles, arcs), alpha, text in
   any TTF at any size (glyphs cached), Open Sans bundled; the examples'
   displays redrawn with it. Tests: images against references.
2. **Pads draws views** (`fire.pads`; built: `app/ui/offscreen.odin`,
   `view_frame`, the device view's four pages): a second ImGui context rendering
   offscreen (SDL_GPU) at the size asked, read back without waiting
   (a frame late); `view_*` in the API; one view first (the device's).
   Tests: a view's pixels from the API, headless.
3. **Pads' Push 2 surface**: linked in, the example's parts moved over,
   the modes' framework (the strip, touches, the rows' labels), Mix and
   Device with Pads' views.
4. **Note / Scale and Session.**
5. **Browse and Clip.**
6. **Sequencer.**

Each stage: tests (the fake DAW or Pads headless, the virtual controller,
the display's pixels), then tried on a Push 2.
