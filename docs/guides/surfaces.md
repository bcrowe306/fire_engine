---
title: Control surfaces
description: Scripts in dynamic libraries that connect hardware controllers to your app, through MIDI, the transport, controls the app publishes, and graph parameters.
---

A control surface is a hardware controller (faders, knobs, pads, a
transport section) with a script that knows it. Scripts are dynamic
libraries, so they can be written, shipped and swapped without rebuilding
the app; Fire Engine's surface manager loads them and gives them a `Host`
to act through.

## What a script can do

| Through | It can |
|---|---|
| MIDI | receive everything the controller sends (short messages and SysEx) and send back: LEDs, displays, motorized faders |
| The transport | play, stop, locate, loop, set the tempo, and read the transport's state |
| Controls | read and move the controls the app publishes (track volume, mute, a device's macro, a clip slot), with touch gestures |
| Graph parameters | set any parameter of a graph node the app has named |
| The app's own API | ask for it by name and version (`get_extension`): Pads gives its whole API as `"fire.pads"` 1 |

The engine has no tracks or mixers of its own, so controls are the app's
to define: it publishes what a surface may move, and decides what moving
it does.

## Hosting surfaces

```odin
m, _ := surface.manager_create({
	clock = clock, timeline = song, graph = g, user = app,
	midi_out = proc(user: rawptr, port: int, bytes: []u8) -> bool {
		return midi.send(controller_driver, controller_out_port, bytes) == .None
	},
	on_set = proc(user: rawptr, id: u32, value: f64) { /* apply it; then control_changed */ },
	on_touch = proc(user: rawptr, id: u32, touched: bool) { /* automation touch */ },
})
defer surface.manager_destroy(m)

// The controller's input, on a MIDI driver of its own (not the audio one):
controller_driver.input = surface.manager_midi_input(m)
in_port, _ := midi.open_input(controller_driver, port_id, 0) // port index 0

lib, _ := surface.library_open(m, "surfaces/mini.dylib")
s, _ := surface.surface_start(m, lib, 0, {midi_in = 0, midi_out = 0})

surface.control_publish(m, {id = 1, name = "Volume", group = "Track 1", kind = .Continuous, min = 0, max = 1}, 0.8)
surface.node_publish(m, "filter", filter_id)

// Every UI frame:
surface.manager_update(m)
```

- **Finding controllers.** A script's descriptors carry hints: substrings
  of its controller's port names. `port_matches(descriptor, name, input)`
  tells whether a port belongs to it, so the app can start the right
  script when a controller is plugged in.
- **Controls.** `control_publish` makes a control visible (again, to
  change its description); `control_remove` withdraws it. When the app
  moves one itself (the mouse, automation), `control_changed` tells the
  surfaces at the next update: motorized faders and LEDs follow. A
  surface's own moves come to `on_set`, already clamped to the control's
  range, and aren't echoed back to it.
- **The transport** is the manager's timeline. Surfaces hear about it
  when it starts or stops, loops, changes tempo or crosses a bar; they
  read its position any time with `get_transport`.
- **Graph parameters.** `node_publish(m, "filter", id)` names a node;
  scripts find it with `node_find` and set parameters with `param_set`
  (which goes through `graph.set_param`).
- **The app's own API.** `Manager_Settings.extension` answers a
  script's `get_extension(name, version)` with whatever the app documents
  for that name (a function table), or nil. Pads answers `"fire.pads"`
  version 1 with its [API](/guides/api/#control-surfaces).
- **Threads.** Everything happens in `manager_update`, on the thread that
  calls it, so scripts never race the app.

## Writing a script

A script library exports `fire_surface_entry`, returning its surfaces by
index. In C, against `f_engine/surface/fire_surface.h`:

```c
#include "fire_surface.h"

static void on_midi(fire_surface *s, uint32_t port, const uint8_t *b, uint32_t n) {
	fire_surface_host *h = s->data;
	if (n == 3 && b[0] == 0xB0 && b[1] == 7) h->control_set(h, 1, b[2] / 127.0); // fader → volume
	if (n == 3 && b[0] == 0x90 && b[1] == 94 && b[2]) h->play(h);                 // play button
}

static void on_control(fire_surface *s, uint32_t id, double value) {
	fire_surface_host *h = s->data;
	uint8_t msg[3] = {0xB0, 7, (uint8_t)(value * 127)};
	if (id == 1) h->send_midi(h, 0, msg, 3); // the motorized fader follows
}

static fire_surface *create(fire_surface_host *h) {
	static fire_surface s;
	s = (fire_surface){.data = h, .on_midi = on_midi, .on_control = on_control};
	return &s;
}

static const char *const hints[] = {"Mini", NULL};
static const fire_surface_descriptor mini = {FIRE_SURFACE_ABI_VERSION, "com.example.mini", "Example Mini", "Example", hints, hints, create};

FIRE_SURFACE_EXPORT const fire_surface_descriptor *fire_surface_entry(uint32_t i) { return i == 0 ? &mini : NULL; }
```

```bash
cc -shared -fPIC -O2 mini.c -o mini.so   # macOS: -dynamiclib -o mini.dylib
```

In Odin, import `fire:surface` for the same types, export
`fire_surface_entry` (`@(export, link_name = "fire_surface_entry")`), and
build with `-build-mode:shared`.

- Every callback runs on the app's control thread, during
  `manager_update`; any may be NULL.
- `on_midi` gets one complete message: a short one, or a whole SysEx from
  F0 to F7.
- `on_controls_changed` means the app's set of controls changed: read them
  again (`control_count`, `control_info`), for example to re-bank faders.
- A gesture (`control_touch`) around a fader's moves lets the app record
  automation in touch mode.
- **ABI versions.** `get_extension` came with version 2. A manager loads
  scripts built for versions 1 and 2 (the host's `abi_version` is the
  manager's); a script that uses `get_extension` checks
  `host->abi_version >= 2` first.

`tests/surface` runs a C script like this one, checking that
`fire_surface.h` lays out every struct as `fire:surface` does, on macOS,
Linux and Windows. A manager update with 200 controls, 50 changes and 20
controller messages takes about 5 µs.

## See also

- [`fire:surface` reference](/reference/surface/)
- [MIDI](/guides/midi/): opening the controller's ports
- [Recording](/guides/recording/#automation): touch automation from a surface's gestures
