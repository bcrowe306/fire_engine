---
title: The application layer
description: Building GUI apps on Fire Engine with app:ui (SDL3, SDL_GPU and Dear ImGui, statically linked), its flat themes, and driving the UI from scripts with screenshots for testing.
---

The application layer lives outside the engine, in `app/` (the `app`
collection): `app:ui` is the window and GUI, `app:core` the model, commands
and engine host (from the next milestone). Apps built with it live in
`apps/`; the first is **Pads**, a sampler and sequencer. The engine never
imports any of it.

Build the libraries once (`task deps`, see [Building](/guides/building/)),
then:

```bash
task app:run                       # build and run Pads
task app:drive -- tests/app_ui/drive/pads.txt   # run it from a script
```

## The platform

```odin
import "app:ui"
import im "deps:imgui"

p: ui.Platform
if !ui.platform_init(&p, {title = "My app", width = 1280, height = 800, vsync = true}) do return
defer ui.platform_destroy(&p)
for ui.frame_begin(&p) {
	if im.Begin("Hello") do im.Text("Hello")
	im.End()
	ui.frame_end(&p)
}
```

- SDL3 opens the window and reads input; SDL_GPU draws (Metal on macOS,
  Vulkan on Linux, D3D12 on Windows); Dear ImGui (docking branch) builds
  the UI. All three are linked into the binary.
- Each frame is drawn into an offscreen texture and copied to the
  window. Screenshots are therefore a download of that texture, and
  `headless = true` draws with no window on screen at all (on Linux
  without a display server, through SDL's offscreen driver and any Vulkan
  device, including Mesa's software one).
- High-DPI: ImGui works in logical points and draws at the display's
  pixel density; `Platform.ui_scale` enlarges the style only where the OS
  asks for more (a Windows display at 150%).

## Themes and fonts

A `ui.Theme` is a set of design tokens: surface colours from the back
(`bg`, `surface`, `raised`, `hover`, `pressed`), text colours, one
`accent`, signal colours, corner radii and spacing. The style is flat:
areas differ by colour, controls have no borders (the light theme adds a
hairline around panels, where white on near-white needs one).

```odin
ui.set_theme(&p, ui.theme_light())   // or theme_dark(), or your own Theme
```

Open Sans is embedded at three weights, `p.fonts.regular` (the default),
`semibold` and `bold`. ImGui renders any size of a loaded font:

```odin
im.PushFontFloat(p.fonts.bold, 22)
im.Text("Title")
im.PopFont()
```

Lucide's icons are merged into each weight, so labels mix icons and text:
`ui.ICON_PLAY + "  Play"`. `app/ui/icons.odin` has a constant for each of
Lucide's 2,342 icons.

## Widgets

Widgets draw with the current theme and **never change the model
themselves**: they edit a copy and report what the user did as a
`ui.Edit` (`changed`, `started`, `ended`, `active`), which the caller turns
into a command. That keeps every change undoable (see
[commands and undo](/guides/app-core/)):

```odin
v := model.volume
e := ui.knob("Volume", &v, 0, 1, default = 0.8)
if e.changed do app.set_value(&history, "Set Volume", {pad, F_VOLUME}, model.volume, v, set_f32)
if e.ended do app.seal(&history)   // the next drag is its own undo step
```

| Widget | What it is |
|--------|-----------|
| `knob` | Rotary control: drag up and down (Shift: fine), scroll, double-click for the default |
| `fader` | Vertical or horizontal, the same gestures |
| `meter` | Peak and RMS on a dB scale, with a held peak; green, amber above -12 dB, red above -3 |
| `pad` | A sampler pad: name, detail, colour, lit while playing, outlined when selected; reports velocity from where it was hit |
| `toggle` | An on/off switch |
| `segmented` | Mutually exclusive options in a row |
| `icon_button` | An icon with no frame, centred in a square, with a tooltip: dimmed at rest, full text under the mouse, `color` (or the accent) when `on`, faint when `disabled` |
| `xy_pad` | Two values, 0..1 |

### Editors

| Editor | What the user does | What it reports |
|--------|--------------------|-----------------|
| `waveform` | zoom (wheel), pan (Shift+wheel), drag markers, drag a selection | `Wave_Edit`: marker moved/released, selection, click |
| `step_grid` | click or drag to paint cells on or off | an `Edit`; the cells |
| `piano_roll` | click to add, drag to move, drag the end to resize, right-click to delete | `Roll_Edit`: what to add, move or delete |
| `automation_lane` | click to add a point, drag to move, right-click to delete | `Lane_Edit` |

The piano roll and the automation lane never change the notes or points
they are given: they say what the user asked for, and the app makes a
command of it.

## The shell

- **Actions.** A `ui.Action` is something the user can do, with a label,
  an icon, a shortcut (`ui.MOD_CMD | i32(im.Key.Z)`: Cmd on macOS, Ctrl
  elsewhere), and optional `enabled` and `checked` callbacks. Menus show
  them with `menu_action`, `handle_shortcuts` runs them from the keyboard,
  and drive scripts by id (`run_action`).
- **Command palette.** Cmd/Ctrl+K (bind `palette_open` to an action): type
  to filter (letters in order: "svas" finds Save As), arrows to choose,
  Enter to run.
- **Toasts.** `ui.toast(&ws.toasts, .Success, "Saved")`: a notice in the
  bottom right that fades.
- **Workspace.** `workspace_draw` puts a dockspace over the whole window
  and draws each open `Panel` in it. The first time (set
  `has_saved_layout` when your ImGui ini file already exists), panels dock
  where `panel_add` asked: the centre, left, right or bottom.
  `workspace_reset_layout` puts them back.

`apps/gallery` shows all of it, wired to a real `History` so everything
undoes: `task app:gallery`.

## Driving the UI from a script

A `ui.Driver` runs the UI from a script of input events and screenshots,
so layouts and interactions can be checked without a person. Events go
into SDL's queue, so they reach ImGui exactly as a mouse and keyboard
would. Coordinates are logical points from the window's top left.

```text
size 1280 800              # resize the window
wait 3                     # let frames pass
click 48 164               # move, press, release
drag 150 131 280 131 6     # press, move over 6 frames, release
scroll 0 -2
key cmd+z                  # cmd is Cmd on macOS, Ctrl elsewhere
text hello pads            # type into the focused field
hold shift                 # keep a modifier down (a Shift-drag), until: let shift
screenshot after_input     # → <out>/after_input.png
theme light                # an app's own command
```

The script runs one command per frame (`wait N` for more), and the app
quits when it ends. Under a driver the platform advances time by a fixed
1/60 s per frame, so screenshots are repeatable.

```bash
.build/app/pads --drive script.txt --out shots/ [--headless]
```

Apps add their own commands with `Driver.command` (Pads: `load`, `hit`,
`chop`, `expect`... see [Pads](/guides/pads/); the gallery: `theme`,
`action ID`). `drop X Y PATH` drops a file on the window as the desktop
would.

Key presses release their modifiers with the key, as a keyboard does, so
`key cmd+k` followed by `text tog` types into the field Cmd+K focused.

### Finding items by what they say

Coordinates break when a layout changes; tests should click what a person
sees. The **probe** (`ui.probe_on`) records every item each frame draws —
its label, its window, the part of it that shows — through ImGui's
test-engine hooks (`vendor/imgui/probe.cpp`, built into the static
library by `task deps`). Commands that use it wait up to a second for
their item to show:

```text
click_item "Kick 808.wav" in browser          # the item's centre; "in" names a panel by its id
click_item seq in sequence at 0.5 0.1         # a point inside it (fractions of its size)
click_item "A1 send B" in mixer right         # right-click (or double)
drag_item "Kick 808.wav" in browser to "pad A1"
drag_by "A1 fader" in mixer 0 40              # drag a knob or fader by an offset
drag_by tempo 20 0                            # ui.number_drag: 4 points a step (Shift: fine steps)
expect_item "Stop (Space)" / expect_no_item "Stop (Space)"
items fader                                   # list what shows (window, label, rect, raw label)
```

A label matches as shown (before any `##`), then as given (`##search`),
then as the end of a shown label (an icon goes first: `"  Mixer"` is the
Mixer panel's tab, not the Mixer menu). `Label#2` is the second match.
Clicks press a frame after the mouse arrives, as a person's do (ImGui
treats tabs as hovered only if they were the frame before).

Widgets drawn with an `InvisibleButton("##…")` name themselves for the
probe: knobs, faders, toggles and segmented choices by their labels, icon
buttons by their tooltips, the editors as `waveform`, `piano roll`,
`lane` (or their ids). An app names its own after drawing them with
`ui.name("pad A1")`, and draws combos with `ui.combo`/`ui.combo_char`
(ImGui gives a combo no label to find).

### Live control and crashes

`ui.Control` takes commands from a test harness over TCP on 127.0.0.1:
the same commands as a script, one per line, each answered with a line
of JSON once it has run (`{"ok": true, "output": "..."}`, or `"ok":
false` and an `"error"`). With it the app runs as usual between commands,
in a window or headless. Pads starts it with `--control PORT` (0: any
free port; it prints the one it took).

`ui.crash_install` (with `context.assertion_failure_proc =
ui.crash_assertion` in main) makes a crash report itself on standard
error: the cause (a bad memory access, a failed assertion or bounds
check), the last command the driver ran, and a back trace (procedure
names in a `-debug` build; a failed assertion or bounds check also
prints its file and line), then dies as it would have:

```text
=== CRASH: SIGSEGV (a bad memory access)
=== last command: drag_item "Kick 808.wav" in browser to "pad A1"
=== back trace:
	#0 _sigtramp at /usr/lib/system/libsystem_platform.dylib
	#1 pads::[ui_browser.odin]::draw_rows at .build/app/pads
```

Never pass an Odin `string` to ImGui's `%s` (`im.Text("%s", "x")`,
`im.Text("%s", ui.ICON_X)`): C reads its length as the next pointer and
crashes. Pass a `cstring(...)` or `fmt.ctprintf(...)`. `task app:lint`
(part of `task app:test`) flags those calls.

## Testing UI

- `tests/app_ui` holds `odin test` cases that need no window (the PNG
  writer, for one).
- `apps/ui_tests` holds cases that do: each draws a UI, is driven by a
  script, and checks the widgets' state and the screenshot's pixels. It is
  a program because macOS allows windows only on the main thread, and
  `odin test` runs tests on worker threads. It skips (exit 0) on a machine
  with no GPU device at all.

```bash
task app:test
```

- `tests/e2e` drives Pads end to end over the control socket (pytest):
  see [Pads](/guides/pads/#end-to-end-tests-and-live-control).

## Cost

On an Apple M-series Mac, headless, building and submitting a frame takes
about 0.07 ms of CPU for ImGui's demo window and 0.35 ms (1.2 ms at the
99th percentile) for the gallery's whole workspace: three docked panels
with every widget and editor. `pads --profile N` and `gallery --profile N`
measure it on any machine.
