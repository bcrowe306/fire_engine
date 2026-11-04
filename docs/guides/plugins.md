---
title: Plug-ins
description: Host CLAP instruments and effects as graph nodes, and turn your own nodes into CLAP plug-ins other hosts can load.
---

Fire Engine's plug-in format is [CLAP](https://cleveraudio.org), an open
(MIT) standard. That works both ways:

- **`fire:clap` hosts CLAP plug-ins** as graph nodes: anyone's .clap files.
- **`fire:clap/sdk` makes CLAP plug-ins** from Fire Engine nodes, so a
  device you write in Odin loads in any CLAP host (and in Fire Engine).

## Hosting

```odin
lib, err := clap.library_open("/Library/Audio/Plug-Ins/CLAP/Example.clap")
defer clap.library_close(lib)
for p in lib.plugins do fmt.println(p.id, p.name, p.features)

node, plugin, _ := clap.plugin_create(lib, lib.plugins[0].id, {})
ins, outs := clap.plugin_channels(plugin)
id, _ := graph.add_node(g, node, ins, outs)
graph.connect_events(g, player, id) // notes, for an instrument
graph.commit(g)
```

- **Finding plug-ins.** `default_search_paths()` lists this system's CLAP
  folders and those in `CLAP_PATH`; `find_libraries` finds the .clap files
  and bundles in them. Opening a library runs its code, so scan once and
  keep what you found.
- **One library per path.** Opening a path again returns the library
  already open there: CLAP libraries are initialized once per load. It
  stays loaded while any plug-in made from it exists.
- **Parameters** are the node's (`node_params`), with CLAP's own ids, so
  `graph.set_param`, automation clips and the automation recorder all work.
  Ramps (`core.Param_Ramp`), which CLAP lacks, reach the plug-in as values
  every 32 frames and exactly its target at the end.
- **Events** go both ways: notes, per-note expression, parameter values and
  MIDI in; the plug-in's notes, MIDI and parameter changes (the user turning
  its knobs) come out of the node's events.
- **The transport** is the clock (by default its leader timeline) as CLAP's
  transport event: tempo, position, loop, bar and meter.
- **Latency** is the node's, so the graph compensates it.
- **State:** `plugin_save_state` returns bytes to keep with your project;
  `plugin_load_state` restores them.

**Threads.** CLAP has a "main thread": the thread that creates the
plug-in. Call `plugin_create`, the state, parameter-text and editor
procedures, and add the node to the graph there; the graph's audio thread
processes it. Call `plugin_idle(plugin)` regularly (every UI frame): it
runs what the plug-in asked to do on the main thread and returns its
requests:

| `Requests` field | Do |
|---|---|
| `restart` | remove the node and add it again (it is re-activated) |
| `params_changed` | read `node_params` again: its parameters changed |
| `latency` | `graph.commit`: its latency changed |
| `gui_resize` | resize the editor's window to `gui_size` |

**Editors.** A plug-in with an editor draws it into a window you give it:

```odin
if clap.plugin_gui_supported(plugin, .Cocoa) {
	w, h, _ := clap.plugin_gui_open(plugin, {api = .Cocoa, handle = uintptr(ns_view)})
	// size your window to w × h; later:
	clap.plugin_gui_close(plugin)
}
```

`.Win32` takes an HWND and `.X11` a window id. Fire Engine itself has no
windows: the app owns them.

## Making plug-ins

Any node becomes a plug-in. A plug-in library is an Odin package built
as a shared library that exports `clap_entry`:

```odin
package my_plugins

import "fire:clap/sdk"
import "fire:core"
import "fire:dsp"
import c "fire:sys/clap"

defs := [?]sdk.Plugin_Def{
	{id = "com.example.synth", name = "Example Synth", vendor = "Example", version = "1.0",
	 features = {"instrument", "synthesizer"}, outputs = 2, notes_in = true,
	 make = proc() -> core.Node { return dsp.synth_create(16) }},
}

@(export, link_name = "clap_entry")
clap_entry := c.Plugin_Entry{c.VERSION, init, sdk.entry_deinit, sdk.entry_get_factory}

init :: proc "c" (path: cstring) -> bool { return sdk.entry_init(defs[:]) }
```

```bash
odin build my_plugins -collection:fire=f_engine -build-mode:shared -o:speed -out:MyPlugins.clap
```

On macOS a plug-in is a bundle: `MyPlugins.clap/Contents/MacOS/MyPlugins`
plus an `Info.plist` (`scripts/clap.sh` makes one for the test plug-ins).

The node's parameters, audio channels (one port each way), notes, latency
and state (its parameter values) become the plug-in's. A node hosted this
way sounds exactly like the node itself: the tests render fire:dsp's
gain, synth and tempo-synced delay both ways and compare bit for bit.

## How it is checked

`tests/clap` hosts two test libraries that `scripts/clap.sh` builds:

- a plug-in written in C against CLAP's own headers (in `vendor/clap`). It
  reports how its C compiler lays out every CLAP struct, which must match
  the Odin declarations in `fire:sys/clap`, and it counts calls the host
  makes on the wrong thread;
- Odin plug-ins made with `fire:clap/sdk` from fire:dsp nodes.

Both are checked on macOS, Linux and Windows. Hosting adds no measurable
cost: a hosted gain takes as long per block as the gain node itself.
