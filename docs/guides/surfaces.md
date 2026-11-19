---
title: Control surfaces
description: Hardware controllers in Pads through fire-surface - surfaces found on the MIDI ports, their claim tables applied before the engine, their USB displays (Push 2), fsurf.daw and the Pads API, Settings, the monitor, the log and the virtual controller.
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

## Displays and other USB devices

A surface can name devices besides its MIDI ports: a display over USB
bulk (Push 2's), or HID. Pads opens them when the surface starts, through
libusb (bulk) and the hidapi built into SDL3 (HID), each on a thread of
its own (`app/core/devices.odin`, `app/devices`):
- what the surface writes (its display's frames) is written there, so a
  slow transfer never holds up Pads
- what the device sends reaches the surface
- a device that isn't there yet, or is unplugged, is tried again each
  second; when it comes back, the surface is told and sends its display
  whole
- Settings → Control Surfaces shows each surface's devices ("display:
  open")

libusb is built by `task deps` (`task deps:libusb`, or
`./scripts/libusb.sh`), static, at a pinned release (LGPL-2.1). Without
it Pads still builds, opening HID devices but no USB bulk ones.

Per system:
- **macOS:** nothing to install.
- **Linux** (the Raspberry Pi too): a user opens a USB device only if a
  udev rule lets them. For Push 2, as root:

  ```bash
  echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="2982", ATTR{idProduct}=="1967", MODE="0666"' > /etc/udev/rules.d/60-push2.rules
  udevadm control --reload-rules && udevadm trigger
  ```

  The interface Pads claims is taken from its kernel driver while open;
  MIDI stays with ALSA.
- **Windows:** a USB bulk interface needs the WinUSB driver bound to it
  (Push 2's display has it).

### Push 2

fire-surface's [`push2_odin`](https://github.com/bcrowe306/fire-surface/blob/main/examples/push2_odin/push2.odin)
is a surface for Ableton Push 2, tried on the device. Build it in the
submodule (`cd extern/fire-surface && ./scripts/build.sh`) and put
`.build/push2_odin.fsurf` in Pads' Surfaces folder, or start Pads with
`--surface` and its path.
- It uses Push 2's **User Port**: Ableton Live keeps the Live Port. To run
  both, turn Live's Track, Sync and Remote switches for the User Port
  off.
- **Display:** the eight tracks in view with their names and volumes, or
  the selected device's parameters (Device), and the transport. On USB
  power alone Push 2 dims its display; its power supply brightens it.
- **Pads:** Note, a keyboard in Keyboard mode's scale (Octave Up and
  Down); Layout, drum pads (Repeat held: note repeat); Session, the
  launcher's clips (the arrows move the window).
- **Encoders:** Mix, the volumes (Shift held: pans); Device, the selected
  device's parameters (Page < and >); the master encoder, the selected
  pad's volume; Tempo, the tempo.
- **Buttons:** Play, Record, Stop, Metronome, Tap Tempo, Undo (Shift:
  Redo); under the display, the upper row mutes and the lower row
  selects.

## Pads' views on a display

A surface can show Pads' own views on its display, drawn with Pads'
widgets, fonts and theme: `view_frame` in the Pads API (`fire.pads`) gives
the newest frame of a view at the size asked for, as RGBA.
- **Views:** `Device`, the selected pad's sound (page 0: its amp
  envelope; 1: its filter's response and envelope; 2: its pitch envelope;
  3: its LFOs). `Mixer`, `Sequencer`, `Clip` and `Browser` come with Push
  2's modes ([the plan](/design/push2/)).
- **How:** each view asked for in the last two seconds is drawn after
  Pads' own frame, in an ImGui context of its own, offscreen on the GPU
  (`app/ui/offscreen.odin`), and read back without waiting: a frame later.
- **From scripts:** `view KIND PAGE W H [PATH]` asks for a view and saves
  its newest frame as a PNG.

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
- **Monitor and log**, in three tabs:
  - **MIDI:** each message from a surface's controller (what its claim
    table did, and which rule), and each it sent, named by the surface:

    ```
    in  1  99 24 64  remap (rule 7)  Grid (kit example) / Pads 3,0 (Drum)
    ```
  - **Log:** what each surface logged (`core:log` in an Odin surface,
    `log` in fsurf.h) and what Pads wrote about one (a library that didn't
    load, a device that didn't open), with its time (seconds since the
    surfaces started), level and surface:

    ```
    12.345  info     Grid (kit example)  mode: keys
    ```

    Filter it by level and by surface, copy what's shown, or clear it.
    **Debug lines** are kept only while their toggle is on, or when Pads
    was started with `--surface-dev`, so a surface can leave its debug
    calls in. A surface keeps at most 1024 lines, its oldest going first;
    a line repeated is counted on one (`(x3)`).
  - **Both:** the MIDI and the log lines in one timeline, in the order
    they came: what was pressed, then what the surface made of it.
- **Virtual controller:** the surface's controls where it placed them,
  lit as it lights them, its displays mirrored. Click, drag an encoder up
  and down (or scroll on it), drag a fader along it; right-click a button
  to hold it until you click it again: what you do reaches the surface as
  its controller's MIDI, through its claim table.

## Push 2 on Screen

**View > Push 2 on Screen** (or `--virtual-push2`) opens a window with
Push 2 in it, laid out as the device is: its encoders, both rows, the
display (Pads' views on it, as on the hardware), the pads, the scene
buttons, the touch strip and every button around them.

- **No Push 2 plugged in:** Pads starts its Push 2 surface with no
  controller (`surface_assign_virtual`): on a MIDI port number no device
  uses (from 200), its output going nowhere, its ports reading "Virtual".
  Closing the window stops it.
- **A Push 2 plugged in:** the window shows that one, and plays it too.
- **The mouse:** click to press (a pad lower down plays softer); hold for a
  long press (Repeat's settings, Quantize's); right-click a button to hold
  it (Shift, Select, Delete, Mute...) until you click it again. Shift on
  the keyboard is Push 2's while the window has the keys. Drag an encoder
  up or down, or scroll on it: dragged, it's touched (its column lit, one
  undo step). Drag along the touch strip to bend the pitch.

- **Its size:** resize the window as you like (Push 2 keeps its shape,
  centred). **Fill** spreads it over Pads' window; **Full Screen** over
  the whole screen. Esc goes back to a window.
- **As the device looks:** knurled encoders, rubber buttons with their
  names printed where Push 2 has them (two lines where it has two),
  Record's circle and Play's triangle, the arrows and Octave/Page as
  diamonds split corner to corner, the scene buttons' chevrons, the touch
  strip's 31 lights, frosted pads.
- **Its lights are the device's:** Pads keeps a copy of Push 2's colour
  palette from what the surface sends (its SysEx palette entries), so
  each light shows the colour the hardware would. The pads, the rows'
  thin strips, the scene buttons, Mute, Solo, Stop Clip, Play, Record and
  Automate in their colours; the other buttons' names backlit white, dim
  or bright. A light's MIDI channel makes it pulse or blink in time, as
  on the device. With a Push 2 plugged in, its palette is heard the same
  way.

Push 2's encoder touches and its strip's pitch bend aren't in its layout
(fsurf.layout has one binding a control): the window knows them from
Pads' own surface. What a surface with no controller sends goes to
`Surfaces.listen` (Pads' app layer), counted as sent.

## From scripts and tests

- **The API:**
  - libraries: `surface_load`, `surface_library_*`, `surface_offered_*`
  - the surfaces running: `surface_count`, `surface_name`,
    `surface_state`, `surface_ports`, `surface_devices`
  - `surface_assign`, `surface_assign_virtual` (no controller),
    `surface_unload`, `surface_set_detect`, `surface_id`
  - the monitor: `surface_monitor*`
  - Pads' views for displays: `view_frame`
  - the log: `surface_log_count`, `surface_log_line`, `surface_log_level`,
    `surface_log_surface`, `surface_log_message`, `surface_log_clear`,
    `surface_log_set_debug`, `surface_log_debug`
  - a surface's controls by name: `surface_control_*`, `surface_press`,
    `surface_release`, `surface_turn`, `surface_move`
- **Script commands:**
  - `surface load|libs|list|unload|assign|detect`
  - `surface press|release|turn|move N NAME...`
  - `surface monitor on|off|show|clear`
  - `view KIND PAGE W H [PATH]`
  - `surface log show|clear|debug on|off`
- **Pretend controllers:** Pads started with `--fake-midi` has pretend
  MIDI ports (`fire:midi/fake`). The script command `midiport` drives
  them:
  - `midiport plug ID in|out|inout NAME...` plugs one in
  - `midiport play ID HEX...` sends MIDI from it
  - `midiport sent ID` shows what was sent to it
  - `midiport unplug ID` unplugs it

  `tests/e2e/test_surfaces.py` and `tests/app_ui/drive/surfaces.txt`
  use the kit's examples this way.
- **Pretend USB and HID devices:** with `--fake-usb`, the script command
  `usbdev` drives them:
  - `usbdev plug ID VID PID [hid PAGE]` plugs one in (hex ids)
  - `usbdev send ID HEX...` sends from it
  - `usbdev written ID` shows the bytes and writes it was sent
  - `usbdev unplug ID` unplugs it

## Not yet

- **The ring:** Pads doesn't draw a surface's window on its tracks yet.
- **Push 2's touch strip LEDs and palette:** the surface uses a few
  colours of its own; track colours on the pads wait.
