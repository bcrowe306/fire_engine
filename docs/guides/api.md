---
title: The Pads API
description: One API for everything Pads does, used by its own UI and scripts, by surfaces and scripts loaded into it, and by other processes, in Odin, in C and as JSON lines.
---

Everything Pads does goes through one API: its own toolbar, menus and
shortcuts, its test-script commands, control-surface libraries and scripts
loaded into it, and other processes. Each thing it does is one procedure,
named `module_verb_object` (`transport_set_tempo`, `history_undo`), the
same in three forms:

| From | As |
|---|---|
| Odin (Pads itself, a script host) | `pads_api.transport_set_tempo(api, 128)` (package `apps/pads/api`) |
| C (a surface library, a script wrapper) | `t->transport_set_tempo(t->api, 128)` through the function table `Pads_Api_V1` (`pads_api.h`) |
| Another process | `{"method": "pads_transport_set_tempo", "args": {"bpm": 128}}`, a line over the control socket |

The C header, the table and the remote methods are generated from the Odin
declarations (`python3 scripts/api.py`), so the three never differ. Every
procedure is in the [reference](/reference/pads-api/).

The API is being built a module at a time ([the design](/design/api/)).
In this version: **history**, **transport**, **project**,
**settings**, **pads**, **params**, **effects**, **devices** and
**mixer**, with results, errors, threading and changes. Pads' own toolbar, History and File menus, shortcuts, pad
menus and script commands for these already go through it.

## Results and errors

Every procedure returns a `Result` (`Ok`, `Not_Found`, `Invalid_Argument`,
`Busy`, `Unsupported`, `Io_Error`), after what it gives:

```odin
if r := pads_api.transport_set_tempo(api, 500); r != .Ok {
	why, _ := pads_api.last_error(api) // "the tempo is 40..300 BPM"
}
s, _ := pads_api.transport_state(api)
```

Nothing that fails changes anything. In C a value comes back through the
last parameter (`Pads_Transport_State* out`); over the socket it is the
answer's `"value"`, and a failure's reason its `"error"`.

## Threads

Call the API on the control thread: Pads' UI thread, where a surface's or
script's callbacks run. Another thread (a script's own, a socket's) posts a
call with `api_post`; it runs at the next frame:

```odin
pads_api.api_post(api, proc "c" (api: ^pads_api.Api, user: rawptr) {
	context = runtime.default_context()
	pads_api.transport_play(api)
}, nil)
```

## Undo

Each edit is one undo step, named as the Edit menu names it. To make
several edits one step, group them; a value moved continuously (a knob
held) is a gesture, its edits merging as a drag's do:

```odin
pads_api.history_group_begin(api, "Set Up the Click")
pads_api.transport_set_count_in(api, 1)
pads_api.transport_set_metronome_sound(api, .Cowbell)
pads_api.history_group_end(api) // one step, "Set Up the Click"

pads_api.history_gesture_begin(api) // a fader held
for bpm in ramp do pads_api.transport_set_tempo(api, bpm)
pads_api.history_gesture_end(api) // one step
```

`history_state`, `history_step_name` and `history_go_to` show and move
along the whole history (Pads' History menu uses them). While a group is
open, undo and redo answer `Busy`.

## Changes

Subscribe to a topic to hear when it changes. A callback runs on the
control thread, at most once a frame, after whatever changed it (a script,
the mouse, an undo): three tempo changes in a frame arrive as one. Read
what it is now from the topic's snapshot:

```odin
on_transport :: proc "c" (api: ^pads_api.Api, topic: pads_api.Topic, index: i64, user: rawptr) {
	context = runtime.default_context()
	s, _ := pads_api.transport_state(api)
	show_tempo(s.bpm)
}
sub, _ := pads_api.subscribe(api, .Transport, -1, on_transport, nil)
```

The playhead (`beat`, the bar and beat) moves without being reported:
poll `transport_state` for it, as for meters. Topics whose module isn't
built yet answer `Unsupported` (`TOPICS` lists those reported).

## Projects

A project is a folder ("Beat.pads"). A new one is untitled: it lives in
the unsaved folder until `project_save_as` gives it a place (and a
name). Leaving a project with changes not saved is `Busy` unless the call
says they may go: Pads asks first, and so should a surface.

```odin
if pads_api.project_open(api, "/Music/Beat.pads", discard_changes = false) == .Busy {
	pads_api.project_save(api) // (or ask, as Pads does)
	pads_api.project_open(api, "/Music/Beat.pads", discard_changes = false)
}
pads_api.project_save_as(api, "/Music/Groove")      // Groove.pads, from now on the project
pads_api.project_rename(api, "Groove 2")            // its folder renamed, where it is
pads_api.project_save_template(api, "Groove Kit")   // File > New from Template lists it
```

`project_state` says whether it is untitled or changed, and how many
recent projects and templates there are (`project_recent`,
`project_template_name`). `project_unused_files` and `project_clean_up`
are Clean Up Project; `project_recover` opens the backup a project left
when Pads stopped without closing.

## Settings

Every setting has the name settings.ini gives it, `section.key`:
`project.tempo` (a new project's), `audio.buffer`, `midi.sync`,
`appearance.zoom`. `settings_count` and `settings_name` list them,
`settings_info` says what each is (Bool, Int, Number, Choice or Text,
its range, its choices). Setting one applies it where it acts (the audio
device reopens, the MIDI ports, the sync) and saves the settings:

```odin
pads_api.settings_set_number(api, "project.tempo", 96)
pads_api.settings_set_text(api, "midi.sync", "Midi_Clock")   // a choice by its name
pads_api.settings_set_text(api, "project.folder", "/Music/Projects")
zoom, _ := pads_api.settings_get_number(api, "appearance.zoom")
```

Out of range is `Invalid_Argument`; an audio setting the device won't
open with is `Io_Error`, and it is put back. `transport_set_sync` and
`transport_set_clock_out` set the two the transport follows. In a drive
script: `setting midi.sync Midi_Clock`.

## Pads

Pads are numbered 0..127 (eight banks of sixteen; `pad_label` gives
"A1"..."H16"). `pad_state` is one pad as it is; each `pad_set_*` an undo
step (a fader dragged: in a gesture, one):

```odin
pads_api.pad_load_sample(api, 0, "/Samples/kick.wav")
pads_api.pad_set_name(api, 0, "Kick")
pads_api.pad_set_choke(api, 0, 1)        // hits of group 1 silence each other
pads_api.pad_set_kind(api, 1, .Synth)    // Sampler, Slicer, Synth, Audio
pads_api.pad_play(api, 0, true, 0.8)     // as a hit at velocity 0.8
pads_api.pad_play(api, 0, false)
```

## Parameters

Anything that can be turned has a `Param_Ref`: a track (a pad, a bus,
main), its device (its sound, an insert, its fader, pan, a send, its EQ),
the slot and the parameter's id on the device. A surface can map any
device without knowing it:

```odin
sound := pads_api.Param_Ref{track = .Pad, index = 0, device = .Sound}
n, _ := pads_api.param_count(api, sound)
for k in 0 ..< n {
	ref, _ := pads_api.param_at(api, sound, k)
	name, _ := pads_api.param_name(api, ref)    // "Cutoff"
	info, _ := pads_api.param_info(api, ref)    // its range, unit, default, steps
	text, _ := pads_api.param_text(api, ref)    // "1.20 kHz", as the UI shows it
}
```

`param_set` takes the plain value (Hz, dB, %) in its range. A knob held
is a touch: `param_touch(api, ref, true)`, the moves, then `false`. Its
moves are one undo step, and with Pads' automation recording armed and
playing, they are written into the sequence, as a knob's are. The value
`param_get` reads is the project's (what automation moves it to while it
plays is the playhead's business).

## Effects

An effect slot is a `Slot_Ref`: a pad's insert (0..3), a bus's or
main's effect (0..4), or a performance effect (0..15). Effect kinds are
listed by `effect_kind_count` and `effect_kind_name` ("Reverb"):

```odin
ins := pads_api.Slot_Ref{place = .Insert, index = 0, slot = 0}
pads_api.effect_set(api, ins, reverb)                // a new one, its defaults
pads_api.effect_set_on(api, ins, false)              // bypassed
pads_api.effect_swap(api, ins, {place = .Insert, index = 0, slot = 1})
pads_api.effect_set_plugin(api, ins, "/Library/Audio/Plug-Ins/CLAP/X.clap", "com.x.verb", "X Verb")
pads_api.effect_set_key(api, ins, .Pad, 3)           // a compressor keyed from pad 3
pads_api.effect_hold(api, 2, true, 0.7)              // performance effect 2, held
```

An insert's or a bus effect's parameters are parameters (device
`Insert`); `effect_get_param`/`effect_set_param` reach them by the
effect's own ids, a performance effect's too. A send's level is a
parameter (device `Send`); `effect_set_send_pre` takes it before the
fader.

## Devices

The synth's built-in presets (`device_preset_count`, `_name`,
`_category`), presets saved as files, and CLAP instruments:

```odin
pads_api.device_load_preset(api, 4, 0)                    // built-in preset 0: pad 4 a synth
path, _ := pads_api.device_save_preset(api, 4, "/Presets", "Mine")
pads_api.device_load_preset_file(api, 5, path)
pads_api.device_load_plugin(api, 6, "/Library/Audio/Plug-Ins/CLAP/S.clap", "com.s.synth", "S")
```

## The mixer

Buses are numbered 0..15 (`mixer_state` says how many are in use); main
is `MAIN`. Where a pad or a bus plays is an `Output`: main, a bus, or
one of the interface's output pairs.

```odin
b, _ := pads_api.mixer_add_bus(api)
pads_api.mixer_rename_bus(api, b, "Drums")
pads_api.mixer_set_pad_output(api, 0, {kind = .Bus, index = b})
pads_api.mixer_set_bus_output(api, b, {kind = .Pair, index = 1})     // outputs 3/4
pads_api.mixer_set_bus_volume(api, b, -6)                            // (param_set on its fader)
g, _ := pads_api.mixer_group_pads(api, {4, 5, 6}, "Toms")            // a group bus
pads_api.mixer_set_pad_cue(api, 0, -3, true)                         // to the headphones, pre-fader
```

A bus can't go round to itself (`Invalid_Argument`). Meters
(`mixer_pad_meter`, `mixer_bus_meter`, `mixer_cue_meter`,
`mixer_input_meter`), main's loudness and the latencies are polled; the
`Mixer` topic reports the rest (levels, pans, mutes, routing, groups).

## From C

A surface or script wrapper is handed the function table; it links
nothing. Strings in take a length; strings out are written into your
buffer, NUL-terminated and cut to fit, with their whole length in
`out_len`:

```c
#include "pads_api.h"

void tempo_up(const Pads_Api_V1* t) {
	Pads_Transport_State s;
	if (t->transport_state(t->api, &s) != PADS_RESULT_OK) return;
	t->transport_set_tempo(t->api, s.bpm + 1);
	char name[64];
	int64_t len;
	t->history_undo_name(t->api, name, sizeof name, &len); // "Set Tempo"
}
```

The table only grows within a version: `size` says how much of it the host
has, so check it before calling a function added later. A breaking change
is version 2. (Surfaces get the table from fire:surface by asking for the
extension `"fire.pads"` version 1: that comes with the surfaces stage.)

## From another process

Start Pads with `--control PORT` and send JSON objects, a line each; each
is answered with a line. Arguments go by name; an enum by its name or its
number; arguments with a default may be left out. Drive-script commands
work on the same connection.

```python
import json, socket

s = socket.create_connection(("127.0.0.1", 5555))
f = s.makefile("rw")

def call(method, **args):
    f.write(json.dumps({"method": "pads_" + method, "args": args}) + "\n")
    f.flush()
    return json.loads(f.readline())

call("transport_set_tempo", bpm=96)          # {"result": "Ok"}
call("transport_state")["value"]["playing"]  # False
call("transport_set_tempo", bpm=5)           # {"result": "Invalid_Argument", "error": "the tempo is 40..300 BPM"}
```

Calls that take a callback or a pointer (`subscribe`, `api_post`) aren't
offered over the socket yet.

## Licence

The API's declarations and `pads_api.h` are MIT. Pads is GPL-3.0-or-later;
a surface or script that only uses the API is meant to be free to have any
licence (the exception's text comes with the surfaces stage).
