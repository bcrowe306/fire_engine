---
title: The Pads API design
description: One Odin API for everything Pads does, a C ABI and remote methods generated from it, and the app a client of it; built a module at a time.
---

Status: stages 1 (the foundation, history, transport), 2 (project,
settings) and 3 (pads, params, effects, devices) built 2026-11-14; the
rest planned (decisions taken 2026-11-13). Using it: the
[guide](/guides/api/) and the [reference](/reference/pads-api/).

### Stage 1, as built

- `apps/pads/core` (package `pads_core`): `Core` holds the bus, host,
  model, Rec's capture and the transport's own state (tap tempo, Stop's
  timing); Pads' `App` embeds it (`using core`), so fields move into it a
  module at a time without touching the UI's reads. `tick` is the app's
  clock (a tap tempo's start comes due on it).
- `apps/pads/api` (package `pads_api`): `api.odin` (the handle, `Result`,
  `last_error`, `api_post`, `api_frame`), `subscriptions.odin` (topics
  reported by comparing snapshots once a frame: coalesced, whoever made
  the change), `history.odin` (undo, redo, step names, go to, groups,
  gestures), `transport.odin`. Setters seal the undo step unless a
  gesture is open (`history_gesture_begin/end`), which is how the UI's
  drags merge.
- The generator is `scripts/api.py` (not a shell script): the header
  (`apps/pads/api/include/pads_api.h`), `gen_c.odin` (`proc "c"` shims,
  `Table_V1`, `api_table`), `gen_remote.odin` (`remote_call`) and
  docs/reference/pads-api.md. `--check` also fails on an API proc without
  a doc comment or a test naming it, and compiles the header.
- Callbacks (`Change_Proc`, `Post_Proc`) are `proc "c"` in Odin too, so one
  type serves both.
- Remote: a control-socket line starting with `{` is an API call
  (`ui.Control.json`), answered at once; drive commands work beside it.
  `subscribe` and `api_post` aren't remote yet (stage 8).
- The lint is `scripts/lint_api.py` (in `task app:lint` and CI): the calls
  into the model a built module owns, banned in package `pads`.
- Input quantize (in the toolbar) is the sequencer's, stage 5.

### Stage 2, as built

- The project's files moved into the core (`Files`: untitled, the recent
  list, Pads' folders, the unsaved folder's setting) with the actions
  (`core/project.odin`): new, from a template, open, save, save as,
  rename, templates, recover, autosave, clean up, the open-project
  marker. Each returns an `Outcome` (the `Result`s, in order) and why.
  What the UI does around them (selection and view reset) is a hook,
  `Hooks.opened`; the toasts are the UI's, from `last_error`.
- Leaving a project with changes is `Busy` unless `discard_changes`; the
  API then throws its backup away and an untitled one's folder, as
  Pads' own leave flow did. The ask-to-save prompt stays the UI's.
- Settings are a registry in the core (`core/settings.odin`): each the
  app's field by pointer, named as settings.ini names it, with its kind,
  range or choices and a group the app applies (`settings_apply` in
  `settings_api.odin`: reopen the device, the ports, the sync; then
  save). Pads' `App_Settings` keeps its fields (the theme is ImGui's);
  the registry points at them. The Settings window still edits those
  fields itself; the test-script commands (`mixer`, `repeat_all`'s rate,
  the new `setting NAME VALUE`) go through the API, as the lint checks
  for shell.odin.
- Sync is the setting `midi.sync`; `transport_set_sync`,
  `transport_set_clock_out` and the transport snapshot's `sync` and
  `clock_out` read and set it.
- Topics `Project` (another folder, untitled or not, the recent list)
  and `Settings` (a version the registry and Pads' own save bump).
- Not yet: the Clean Up dialog keeps its per-file choice (it calls the
  model with the files ticked); the API cleans up by kind.

### Stage 3a, as built (pads, params)

Stage 3 lands in two commits: 3a the pads and the parameters, 3b the
devices and effects (and the knobs moved onto `param_set`).

- `pads`: a pad's state, name, label; set its name, colour, mode,
  volume, pan, pitch, mute, solo, choke group, monitoring, kind
  (sampler, slicer, synth, audio track); load a sample, clear,
  duplicate, copy onto another, play, arm. The pads' menus, the
  inspector, the Mixer's strip fader and pan (a gesture), the colour and
  choke menus, the browser's and drops' loads and the shell's commands
  use them. Exceptions (`api-lint:`): Paste Pad (the UI's clipboard),
  `empty_slicer` in the shell.
- `params`: `Param_Ref` is `pm.Auto_Target` (track, index, device,
  slot, param) without its cached range. Info and the list come from the
  device's node (`resolve_target`; the shown parameters); a fader, pan or
  send is fixed (-60..6 dB, -1..1). Values are the project's, read and
  written through the model's setters: a sampler's through
  `pm.voice_param_set` (the inverse of `voice_params`: attack, release
  and transpose the pad's own fields), a synth's `set_synth_value`, a
  plug-in's and an insert's `set_target_param`, faders `set_pad` and
  `set_bus`, sends `set_send_db`, EQ gains `set_pad`. `param_touch` is a
  gesture plus the core's hooks `param_touched`/`param_moved`, which
  Pads gives its automation recorder.
- The generator takes a struct as an argument (C: by value; remote: a
  JSON object of its fields, any left out zero). `Param_Info`'s default
  is `default_value` (`default` is C's).
- The lint covers the pads' fields.

### Stage 3b, as built (effects, devices)

- `effects`: `Slot_Ref` (an insert, a bus's or main's effect, a
  performance effect); kinds by index and name; set (a new one; an
  empty slot's step "Add Effect", else "Set Effect"; a performance
  effect starts off), set a plug-in, clear, on/bypass, swap (the order),
  a parameter by the effect's id (performance effects too), hold and
  intensity, a send's pre/post, and the sidechain (key, its high-pass,
  listen). The effect view, the device panel's adds, the Mixer's slot
  drags and send menu, the performance pads, the slot commands and the
  shell's effect commands use them (Paste Effect stays the UI's
  clipboard).
- `devices`: the synth's built-in presets, preset files (load, save),
  the preset a pad came from, a CLAP instrument on a pad.
- `param_set` names its step after the parameter ("Set Cutoff").
- **Not moved yet: the device knobs.** The sampler's, the synth's and
  the effects' knobs (about 28 places) still write the model through
  its setters, each with its own display scaling, merging key and step
  name ("Shape Envelope", "Voice Mode", which tests and users see). They
  move onto `param_set` with the `ui` module (stage 7), when the knob
  widget can carry its `Param_Ref` and a step name; until then a surface
  sets the same values through `param_set` and the knobs show them.

One Odin API through which everything Pads can do is done: by Pads' own
UI and its test scripts, by control-surface libraries loaded at runtime,
by scripts embedded in it (Lua, Python: later wrappers), and by other
processes. A C ABI generated from it is what libraries and wrappers bind
to.

## Decisions

| | |
|---|---|
| Shape | A typed Odin API, and a flat C ABI generated from it (one source of truth) |
| Scope | Everything: the project and the engine, the app's state (selection, play mode, Hold, sampling, settings) and the UI (views, panels, dialogs' actions) |
| Sync | Pads is a client of its API: the UI, the test-script commands and the shortcuts call it, not the model |
| Callers | Surfaces loaded in Pads, scripts in Pads, other processes, Pads itself |
| Licence | The C header and the Odin API's declarations MIT; Pads' licence gets a plug-in exception (a surface or script that only uses the API may have any licence) |
| fire:surface | Stays the engine's generic loader (MIT); a surface asks it for the Pads API by name and version, as a CLAP plug-in asks for an extension |
| Undo | Each edit one named undo step; a caller may group calls into one; continuous moves merge, as the UI's do |
| Changes | Subscriptions (topics, delivered on the control thread, batched once a frame) and read-only snapshots; meters and playheads by polling |
| Rollout | The foundation, then a module at a time, each with its UI moved onto it; the app works between stages |
| Work | One session in a worktree of its own, a commit a stage, reviewed and merged here |

## What has to change first (what the plan found)

- **The app's state lives in package `pads`** (the executable), beside
  ImGui. An API package can't import it. Stage 1 moves the app's state and
  its actions (selection, Hold, sampling, play modes, the project's
  save/open flow, Clean Up, the browser's state...) into a package of their
  own, `apps/pads/core` (no ImGui), that the API and the UI both import. The
  UI keeps only drawing and input.
- **Logic in UI files.** Several features are done inside draw procs
  (`hold_frame`, `step_track`, the export and Clean Up dialogs' actions,
  `save_project_as`, the knob hooks' recording). Each moves into core as
  its module comes up.
- **Native dialogs.** What a dialog does (Save As, Open, Export) gets an
  API taking a path; the UI's dialog only picks the path.
- **The test-script commands (`shell.odin`, ~250)** become thin: parse,
  call the API. The e2e suite then tests the API as people use it.
- **fire:surface** today publishes flat controls and a transport. It gains
  an extension query (`get_extension(name, version)`); the Pads API is
  `"fire.pads"`, version 1.

## Shape

### Odin

- One package, `pads_api` (`apps/pads/api`), a file a module.
  Names `module_verb_object`: `transport_play`, `mixer_set_volume`,
  `sequence_add_note`. (The C name is the same, prefixed: `pads_transport_play`.)
- Every proc takes `api: ^Api` (opaque: the app behind it) and returns
  what it gives plus a `Result` (`.Ok`, `.Not_Found`, `.Invalid_Argument`,
  `.Busy`, `.Unsupported`, `.Io_Error`); `last_error(api)` says why in words.
- Control thread only. Other threads (the socket, a script's own thread)
  post calls with `api_post` and get their results on the next frame.
- No allocation handed to callers: strings in are borrowed; strings out
  are written into the caller's buffer (or a temporary valid until the
  next frame, in Odin); lists by count + index.

### Identity

Stable, plain values a caller can keep:

| Thing | How it is named |
|---|---|
| Pad (track) | index 0..127 |
| Sequence | slot 0..63 |
| Bus | index 0..15; main and cue by name |
| Lane, row (launcher) | index |
| Song clip, marker | the model's id |
| Sample, take, part | the model's id (`app.Id`) |
| Effect slot | its track and index |
| **Any parameter** | a `Param_Ref`: today's `Auto_Target` (track, index, device, slot, param), generalised |

### Parameters, generically

`param_info(ref)` (name, unit, range, steps, default, log, automatable),
`param_get`, `param_set`, `param_text` (as the UI shows it), `param_touch`
(begin and end a gesture: undo merging, automation recording). With
`params_of(device)` to list them, a surface can map any device without
knowing it. Typed helpers (`mixer_set_volume`) sit on top.

### Changes

`subscribe(api, topic, filter, callback, user) -> Subscription` and
`unsubscribe`. Topics: transport, selection, pad (one or all), mixer,
sequence, song, launcher, project, settings, history, recording, ui.
Delivered on the control thread once a frame, coalesced (a value that
changed three times arrives once, as it is). Snapshots
(`transport_state`, `pad_state`, `mixer_state`, ...) for polling. Meters,
playheads and live values (the automated value now) by polling.

### C ABI

- Generated from the Odin API (a generator over the API package's
  declarations and doc comments): `pads_api.h` (MIT) and the exported
  shims (`proc "c"`, plain types: integers, doubles, `const char*` + length,
  caller buffers, opaque handles).
- Reached through a **function table** (`Pads_Api_V1`: a struct of function
  pointers, with its size and version), handed to a surface by
  fire:surface's `get_extension("fire.pads", 1)`, or to an embedded script
  host directly. Libraries link nothing.
- Versioning: the table only grows within a major version (new functions at
  the end; `size` says what a caller has); a breaking change is version 2,
  both offered for a while.

### Other processes

The same table, as messages: JSON lines over the `--control` socket (the
method a C name, its arguments by name; results and subscribed changes
back). Generated from the same declarations.

## Modules

| Module | What |
|---|---|
| `api` | the handle, results, errors, threading, subscriptions, versions |
| `history` | undo, redo, names, groups, saved state |
| `project` | new, open, save, save as, templates, rename, clean up, recover, unsaved folder |
| `transport` | play, stop, locate, loop, tempo, time signature, count-in, metronome, pattern/song, sync (MIDI clock, Link) |
| `pads` | each pad's kind, sound, name, colour, mode, choke, mute/solo, MIDI in/out, input, monitoring, arming |
| `params` | any parameter by reference (above) |
| `devices` | sampler, slicer, synth (patches, presets, wavetables), plug-ins (scan, load, editor window, state), audio tracks |
| `effects` | inserts, sends, performance effects, their order |
| `mixer` | strips, buses, groups, main, cue, meters, latency |
| `sequencer` | sequences (create, copy, name, length, tempo), notes, CC, automation lanes, track loops, quantize, input quantize, note repeat, the arpeggiator |
| `audio` | takes, regions, comping, consolidate, warp |
| `recording` | arm, record, count-in, capture, sampling into pads, passes |
| `song` | arrangements, lanes, clips, tempo and meter lanes, markers |
| `launcher` | lanes, the window, launch, stop, Hold, scenes, record to song |
| `perform` | play modes (pads, keyboard, velocity), banks, the selected track, keys |
| `export` | mixdown, stems, MIDI, bounce, freeze, resample |
| `browser` | folders, favourites, search, preview, presets, the devices list |
| `midi` | ports, mapping, learn, clock out |
| `settings` | audio device and channels, MIDI, appearance, recording, project defaults, keyboard |
| `ui` | views and panels (show, focus), selection, zoom, theme, messages (toasts), dialogs' actions |

## Keeping it in sync

1. **The app calls it.** A module's UI is moved onto the API when the module
   is built; a check then fails if a UI file of that module imports the
   model directly (`scripts/lint_api.py`, module by module).
2. **Generated files are current.** `python3 scripts/api.py --check` (in CI, as
   docs --check): the C header, the shims, the function table and the
   remote methods match the Odin declarations.
3. **Every API proc is documented and tested.** The check lists any without
   a doc comment or without a test naming it.
4. **The rule** in CONVENTIONS.md: a feature is reachable through the API
   or it isn't done; changing one changes its API entry, its docs and its
   test in the same commit.

## Documentation

- The reference, generated from doc comments (`./scripts/docs.sh`): the
  Odin API by module, and the C header.
- A guide (docs/guides/api.md): concepts (handles, results, threading,
  undo, subscriptions, parameters), a page a module with examples, the C
  ABI and its versioning, the remote protocol, writing a surface.
- Examples: an Odin caller, a C surface library (in examples/), a remote
  client (Python, a few lines over the socket).

## Testing

- tests/pads_api: every proc, headless (the model rig plus core, no
  window), its results and the changes it reports.
- tests/pads_api_c: a C program and a C surface library calling through the
  generated table (as tests/surface does today).
- tests/e2e: unchanged in what it does, now through the API.
- The remote protocol: a pytest client over the socket.

## Also to settle as it goes

- Two callers at once (a surface and the mouse on one knob): the last
  wins; a touched parameter (`param_touch`) isn't moved by another until
  let go.
- What a script may do with files (anything the app can: no sandbox at
  first; say so in the guide).
- Performance: no allocation per call; snapshots copy plain structs;
  subscriptions coalesce.
- Deprecation: an API entry kept a major version after it is replaced.

## Stages

Each: the module's API, its UI and test-script commands moved onto it,
tests, docs, both opt levels; a commit; the app working.

1. **Foundation.** `apps/pads/core` split out (the app's state and actions,
   no ImGui); `pads_api` with `Api`, results, errors, threading
   (`api_post`), subscriptions; the generator (C header, shims, table,
   remote methods) and its check; the lint; docs; modules **history** and
   **transport**.
2. **project**, **settings**.
3. **pads**, **params**, **devices**, **effects**.
4. **mixer**.
5. **sequencer**, **audio**, **recording**.
6. **song**, **launcher**, **perform**.
7. **export**, **browser**, **midi**, **ui**.
8. **Surfaces**: fire:surface's `get_extension`; `"fire.pads"` version 1; a
   C surface library in examples using it; the remote protocol complete;
   the licence exception's text.
