---
title: Saving sessions
description: Save and load a whole session (clock, timelines, every node with its parameters, clips, sample maps and plug-in state) as one versioned file, with chunks of your app's own.
---

`fire:session` saves everything the engine is playing to one file and
loads it back:

- the clock: tempo, meter, leader, and every timeline with its tempo map,
  rate, position and loop;
- the graph: every node with its type, channels, parameter values and own
  state (a player's clip, a sampler's zones, a plug-in's state, a nested
  graph), and every connection;
- chunks of your app's own: track names, colours, the window layout.

Audio is not copied in: clips, samples and recorders keep file paths,
stored both absolute and relative to the session file, so a session moved
with its audio folder still finds it.

`examples/session` saves a short song, loads it into a new engine, and
checks that it renders the same.

## Saving

```odin
s := session.Session{clock = clock, graph = g}
tracks := session.App_Chunk{tag = {'T', 'R', 'K', 'S'}, version = 1, data = my_tracks_bytes}
err := session.save(s, "songs/demo.fire", {tracks})
```

`save` writes a temporary file next to the target and renames it over the
old one, so a crash mid-save never leaves half a file. `save_bytes` gives
you the bytes instead (for undo snapshots, or your own storage).

What a node saves:

| Node | Saved |
|------|-------|
| Effects and the synth (`fire:dsp`) | Constructor arguments (filter mode, EQ bands, oversampling, lookahead, voices, a convolution's impulse response) |
| MIDI, audio and automation players | Settings, the clip, its placement |
| Sampler | Settings and the sample map (each zone's file and settings) |
| Hosted CLAP plug-ins | Library path, plug-in id, host settings, the plug-in's own state |
| Nested graphs (`graph.as_node`) | Their settings and their whole graph |
| Recorders, the latency probe, the MIDI clock | Settings (not takes or arming) |

Parameter values are saved by the graph: the last value you set with
`graph.set_param` or `graph.set_param_ramp`. A parameter you never set
isn't saved, so it starts as a newly made node has it. Values that
automation moves are saved as their base, with the automation clip.

What isn't saved: whether timelines were playing (sessions load stopped),
a `transport.Sync`, MIDI and audio devices, surfaces, and anything still
recording.

## Loading

Loading has to make nodes from names in the file. A **registry** maps
each type ID to a loader; the engine's own types register with
`register_builtin`, given what they need from your app:

```odin
reg: core.Node_Registry
core.registry_init(&reg)
defer core.registry_destroy(&reg)
env := session.Environment{
	players  = {streamer = streamer, stretcher = &stretch.signalsmith},
	disk     = disk,      // for audio recorders
}
session.register_builtin(&reg, &env) // env must outlive reg

loaded, err := session.load(s, "songs/demo.fire", &reg)
defer session.loaded_destroy(&loaded)
```

`load` **replaces** the session's contents. It makes the new timelines and
nodes beside the old ones, then removes the old ones and switches the
graph over in one block, so you can load while audio runs. If the load
fails, the session stays as it was. (The clock needs room for both sets
of timelines meanwhile: see `max_timelines`.)

IDs change on loading. Look up the new ones from the saved ones you kept
in your app's chunk:

```odin
song, _ := session.timeline(loaded, saved_song)    // a core.Timeline_Id
bass, _ := session.node(loaded, saved_bass.index)  // a graph.Node_Id
if c, ok := session.find_extra(loaded, {'T', 'R', 'K', 'S'}); ok {
	restore_tracks(c.version, c.data)
}
```

Loaded nodes start exactly at their saved parameter values, without
smoothing, so a loaded session sounds the same from its first sample.

### Missing node types

A node whose type isn't registered, or whose loader fails (a plug-in
that is no longer installed, an audio file that is gone), becomes a
**placeholder**: a silent node with the same channels and connections
that keeps the saved data. Saving again writes it back unchanged, so
opening a session on a machine without a plug-in doesn't lose that
plug-in's settings. `loaded.nodes.missing` lists them, with the reason:

```odin
for m in loaded.nodes.missing {
	fmt.printf("%s could not be loaded (%v)\n", m.type_id, m.err)
}
```

## Your own node types

To make your node savable, give its vtable a `type_id` (stable forever
once shipped), a `state_version`, and a `save` that writes what it needs
beyond its parameters. Then register a loader:

```odin
my_vtable := core.Node_VTable {
	// ... prepare, process, ...
	type_id       = "com.example.wobble",
	state_version = 1,
	save = proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
		core.write_int(w, (^Wobble)(self).voices)
		return .None
	},
}

core.register_type(&reg, {id = "com.example.wobble", load = proc(data: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
	voices := core.read_int(r)
	if version >= 2 do read_new_things(r) // values appended in version 2
	return wobble_create(voices, a), .None
}})
```

- Read values in the order you wrote them; `r.err` becomes
  `.Invalid_Data` if the data runs out, and every read after returns zero.
- To change the format, append values (or child chunks) and bump
  `state_version`. Older engines ignore what they don't read.
- Store file paths with `core.write_path` and read them with
  `core.read_path`, so they follow a moved session.
- Timeline IDs in your data: map them with `core.load_timeline(ctx, id)`.

Clips and sample maps have their own procs (`clip.write_midi_clip`,
`clip.read_audio_clip`, `sampler.write_sample_map`, ...), for apps that
keep clips outside players, like a launcher grid.

## Looking inside a file

```bash
odin run tools/session_dump -collection:fire=f_engine -- songs/demo.fire
```

It prints the chunk tree: each node's type and channels, its parameter
values, the connections and the tempo. The format is described in the
[session design notes](/design/session/).
