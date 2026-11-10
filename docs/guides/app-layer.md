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
task app:drive -- tests/app_ui/drive/smoke.txt   # run it from a script
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
screenshot after_input     # → <out>/after_input.png
theme light                # an app's own command
```

The script runs one command per frame (`wait N` for more), and the app
quits when it ends. Under a driver the platform advances time by a fixed
1/60 s per frame, so screenshots are repeatable.

```bash
.build/app/pads --drive script.txt --out shots/ [--headless]
```

Apps add their own commands with `Driver.command` (Pads: `theme`,
`demo`).

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

## Cost

Building and submitting a frame of ImGui's demo window takes about
0.07 ms of CPU (median; 0.8 ms at the 99th percentile) on an Apple
M-series Mac, headless. `pads --profile N` measures it on any machine.
