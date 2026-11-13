---
title: Application model, commands and events
description: app:core, the GUI-free half of the application layer: a typed event bus, undoable commands, entity stores that save, background jobs, and the engine host that survives devices coming and going.
---

`app:core` is the half of the [application layer](/guides/app-layer/)
without a GUI. A headless app (a box with no screen) uses it alone; a GUI
app draws with `app:ui` on top of it. Import it as `app`:

```odin
import app "app:core"
```

The pattern it supports: **the model is plain data, every change to it is
a command, and everything else reacts to events.** Widgets turn gestures
into commands; commands change the model and can be undone; the engine,
the UI and anything else learn about changes from the bus.

## Events

A `Bus` delivers events by type: any Odin type is an event.

```odin
Pad_Changed :: struct { pad: app.Id }

bus: app.Bus
app.bus_init(&bus)
sub := app.subscribe(&bus, Pad_Changed, proc(user: rawptr, e: ^Pad_Changed) {
	// redraw the pad, update the engine...
}, user)

app.publish(&bus, Pad_Changed{id})  // now
app.post(&bus, Pad_Changed{id})     // at the next dispatch
app.dispatch(&bus)                  // once per frame, on the UI thread
app.unsubscribe(&bus, sub)
```

- Handlers run in subscription order. Unsubscribing, even yourself, is
  safe inside a handler; events posted by handlers wait for the next
  dispatch.
- From another thread, `post_any_thread` (it takes a lock).
- From the **audio thread**, a `Channel(T)`: a fixed-size lock-free queue
  `dispatch` drains. `send` never allocates or blocks; when the channel is
  full, the event is dropped and counted.

```odin
meters: app.Channel(Meter)
app.channel_init(&bus, &meters, 256)
// [rt] in the audio callback:
app.send(&meters, Meter{peak = p})
```

Posting and dispatching costs about 36 ns per event (four subscribers,
Apple M-series).

## Commands, undo and redo

A command type is a vtable of `apply` and `revert` (exact inverses) over
the model, and optionally `merge`. A `History` runs commands and keeps
undo and redo stacks:

```odin
h: app.History
app.history_init(&h, &model, limit = 500, bus = &bus)

app.execute(&h, cmd)        // applies it, records it, clears redo
app.undo(&h); app.redo(&h)
app.undo_name(&h)           // "Set Volume", for the Edit menu
```

For the common case, setting one value, `set_value` builds the command:

```odin
set_volume :: proc(ctx: rawptr, key: app.Key, v: f32) {
	m := (^Model)(ctx)
	app.store_get(&m.pads, key.id).volume = v
}
app.set_value(&h, "Set Volume", {pad_id, FIELD_VOLUME}, old, new, set_volume)
```

- **Merging.** Consecutive sets of the same key merge into one step, so a
  dragged knob undoes in one go. Call `seal` when the gesture ends (the
  mouse released): the next set starts a new step.
- **Transactions.** `begin(&h, "Add Chord")` … `end(&h)` makes the
  commands in between one step, undone in reverse.
- **Saved state.** `mark_saved` after saving; `is_dirty` says whether the
  document changed since. A set right after saving never merges into the
  saved step, so undoing it returns exactly to the saved state.
- **Keys, not pointers.** Commands name what they change by `Id` (and a
  field number), because undo outlives the memory a pointer would name.

Executing a merging set costs under a microsecond; undo and redo about
16 ns per step.

## Entities and stores

A `Store(T)` holds entities of one type by `Id`, in a stable order:

```odin
ids: app.Ids              // saved with the document, so ids stay unique
pads: app.Store(Pad)
app.store_init(&pads)
id := app.new_id(&ids)
app.store_add(&pads, id, Pad{name = "Kick"})
p := app.store_get(&pads, id)
v, at, _ := app.store_remove(&pads, id)   // keep v and at to undo
app.store_add(&pads, id, v, at)           // back where it was
```

Saving uses the engine's versioned chunks (see
[saving sessions](/guides/sessions/)):

```odin
app.document_save(&w, &ids)
app.store_save(&w, PADS_TAG, 1, &pads, write_pad)
// ...
app.store_load(chunk, &pads, read_pad)  // read_pad gets the version, to read older files
```

A store of 100,000 small entities (11 MB) saves in about 6 ms and loads in
8 ms.

## Background jobs

```odin
jobs: app.Jobs
app.jobs_init(&jobs, &bus, threads = 2)
job := app.job_start(&jobs, "Chop", proc(job: ^app.Job, user: rawptr) {
	for i in 0 ..< n {
		if app.job_cancelled(job) do return
		// ... work ...
		app.job_progress(job, f32(i) / f32(n))
	}
}, user)
app.job_cancel(job)
```

When a job ends, a `Job_Done` is delivered at the next dispatch, with its
state (`.Done`, `.Cancelled`, or `.Failed` if `run` set `job.error`).

## The engine host

A `Host` owns what an app plays through: the driver and device, the
clock, the graph, a streamer for audio files, a disk writer for
recordings, and the node registry sessions load with.

```odin
host: app.Host
app.host_init(&host, {outputs = 2, max_block = 512}, &bus)
app.host_open(&host)          // the default output; announces .Opened or .Failed
for running {
	app.host_update(&host)    // once per frame: device events, freeing what the audio thread let go
	app.dispatch(&bus)
}
```

- The clock and graph are made at the device's sample rate. If you open a
  device at another rate, the host moves everything (nodes, clips,
  timelines) to a new graph and clock through a session saved in memory,
  and announces `Host_Engine_Changed`: node and timeline ids from before
  are stale.
- If the device goes away (unplugged), the host closes it, announces
  `.Lost`, and retries every half second; when it is back, `.Restored`.
  The graph and clock carry on untouched.
- **Drivers.** `host_drivers` lists the platform's audio drivers, its
  default first (CoreAudio; WASAPI and ASIO; ALSA and JACK), each with why
  it can't be used here, if it can't (built without ASIO, libjack not
  installed). `Host_Settings.driver` picks one (one that won't make: the
  default); `host_set_driver` switches while running (the device closes,
  the new driver opens the devices in `settings`: its own ids, "" for its
  defaults; the old one stays if the new one won't make). `driver_id` is
  the one in use ("fake" for the simulated one).
- `host_render` runs the engine without a device, for exporting.
- **Timing tests.** The simulated driver can report latencies and loop its
  outputs back to its inputs (`fake_latency`, `fake_loopback`): run it as
  a device (`host_open`, `host_fake_run`) for a cable's round trip.
- `fake = true` uses the simulated driver, for tests and headless runs.
  Its device runs when you call `host_fake_run` (manual mode): an app
  running it interactively gives it a frame's worth of callbacks each
  frame.
- **MIDI.** With `midi = true` the host opens the platform's MIDI
  (CoreMIDI, ALSA, WinMM) and every input port: what they play reaches the
  graph's `INPUT` as `core.Midi_Raw`, on its frame. `core.Midi_Raw` the
  graph sends to `OUTPUT` goes to the port named by `midi_output`.
  `host_midi_inject` plays a message in as if a port had (tests, scripts,
  on-screen keyboards); `host_midi_counts` counts what went in and out
  (activity lights); `host_midi_ports` lists the ports.

## Testing

```bash
./scripts/test.sh app_core      # or task app:test
```
