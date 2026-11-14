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
In this version: **history** and **transport**, with results, errors,
threading and changes. Pads' own toolbar, history menu, shortcuts and
script commands for these already go through it.

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
