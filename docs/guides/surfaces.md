---
title: Control surfaces
description: Hardware controllers in Pads through fire-surface - surfaces found on the MIDI ports, their claim tables applied before the engine, fsurf.daw and the Pads API, Settings, the monitor and the virtual controller.
---

A control surface is a hardware controller (pads, faders, knobs, a
transport section, a display) with a library that knows it. Pads hosts
surfaces written with **[fire-surface](https://github.com/bcrowe306/fire-surface)**,
an open protocol and SDK. fire-surface is in this repository as a git
submodule, `extern/fire-surface`, and builds use
`-collection:fsurf=extern/fire-surface`. After cloning, run:

```bash
git submodule update --init
```

A surface is a `.fsurf` file: a dynamic library. You can write it in C
against `fsurf.h`, or in Odin with fire-surface's kit. Its
[protocol](https://github.com/bcrowe306/fire-surface/blob/main/docs/protocol.md),
[kit](https://github.com/bcrowe306/fire-surface/blob/main/docs/kit.md),
[`fsurf.daw`](https://github.com/bcrowe306/fire-surface/blob/main/docs/daw.md),
[tools](https://github.com/bcrowe306/fire-surface/blob/main/docs/tools.md)
and [displays](https://github.com/bcrowe306/fire-surface/blob/main/docs/displays.md)
are documented there. This page is how Pads hosts them.

## Where Pads finds surfaces

When Pads starts, it loads every `.fsurf` it finds in:
1. its own Surfaces folder, beside `settings.ini` (on macOS,
   `~/Library/Application Support/Pads/Surfaces`)
2. the folders in `FSURF_PATH`
3. the system's surface folders (`~/Library/Audio/Plug-Ins/fsurf` on
   macOS; see fire-surface's protocol page)

`--surface PATH` loads one more (`--surface-dev` reloads libraries when
they're rebuilt), and so does the API's `surface_load`.

## Finding a controller

Each library's surfaces say which controllers are theirs. Pads matches
the MIDI ports' names against them, asks the device who it is when the
surface says to (an identity request, read from its SysEx reply), and
starts the surface that fits best.
- **Unplugged:** the controller's surface is kept, and starts again when
  it's back. Ports appearing and going are handled without stopping the
  audio.
- **Settings:** a surface's own settings are kept between runs, in
  `Surface Settings` beside `settings.ini`.

## MIDI: the claim table

A surface says which of its controller's messages are its own, with its
claim table. Pads applies the table where the engine takes MIDI from the
ports, on the audio thread, before the engine sees anything:

| A surface's message | |
|---|---|
| claimed | goes to the surface only (a button doesn't play a note) |
| observed | goes to the engine and the surface |
| remapped | goes to the engine changed: drum pads, a keyboard in a scale, with no added latency |
| passed (anything else) | goes to the engine, as from any controller (a keyboard's keys) |

- A note off goes where its note on went, even if the surface changed
  mode in between.
- SysEx is routed on the control thread.
- What a surface hands on itself (`inject_midi`) goes into the engine as
  if from its port, and skips the claim table.
- A surface's own MIDI goes straight to its ports.

The engine side is generic: `midi.Input_Filter`, which the app layer's
`Surfaces` (app/core/surfaces.odin) puts on the host's input.

## What a surface can reach

- **`fsurf.daw`:** the standard extension. A surface written for any host
  gets Pads through it:
  - the transport
  - the pads as tracks, with their mixer
  - the selected pad's sound and inserts, with their parameters
  - the launcher's lanes and rows
  - Keyboard mode's scale
  - undo, redo, save and the views

  Pads tells a surface what changed: the API's changes, and once a frame
  what the API doesn't report (pads' names, devices, parameter values).
- **`fire.pads`:** the [Pads API](/guides/api/)'s function table,
  everything Pads does.

## Settings → Control Surfaces

- **Found:** each controller, its ports and its state (running, asking
  who it is, unplugged...). *Stop* forgets one assigned by hand, or turns
  detection off for one found. *Show* opens its virtual controller.
- **Assign by hand:** a surface on ports you choose, whatever their names,
  for a controller Pads doesn't recognise by itself.
- **Surfaces:** each library's surfaces, with detection on or off (kept
  between runs), and why a library didn't load.
- **MIDI monitor:** each message from a surface's controller (what its
  claim table did, and which rule), and each it sent, named by the surface:

  ```
  in  1  99 24 64  remap (rule 7)  Grid (kit example) / Pads 3,0 (Drum)
  ```
- **Virtual controller:** the surface's controls where it placed them,
  lit as it lights them, its displays mirrored. Click, drag an encoder up
  and down, drag a fader along it: what you do reaches the surface as its
  controller's MIDI, through its claim table.

## From scripts and tests

- **The API:**
  - libraries: `surface_load`, `surface_library_*`, `surface_offered_*`
  - the surfaces running: `surface_count`, `surface_name`,
    `surface_state`, `surface_ports`
  - `surface_assign`, `surface_unload`, `surface_set_detect`
  - the monitor: `surface_monitor*`
  - a surface's controls by name: `surface_control_*`, `surface_press`,
    `surface_release`, `surface_turn`, `surface_move`
- **Script commands:**
  - `surface load|libs|list|unload|assign|detect`
  - `surface press|release|turn|move N NAME...`
  - `surface monitor on|off|show|clear`
- **Pretend controllers:** Pads started with `--fake-midi` has pretend
  MIDI ports (`fire:midi/fake`). The script command `midiport` drives
  them:
  - `midiport plug ID in|out|inout NAME...` plugs one in
  - `midiport play ID HEX...` sends MIDI from it
  - `midiport sent ID` shows what was sent to it
  - `midiport unplug ID` unplugs it

  `tests/e2e/test_surfaces.py` and `tests/app_ui/drive/surfaces.txt`
  use the kit's examples this way.

## Not yet

- **USB and HID devices** (a Push 2's or an MPC's display): a surface's
  displays are mirrored in its virtual controller, not sent to the device.
  libusb and hidapi come as their own step.
- **The ring:** Pads doesn't draw a surface's window on its tracks yet.
