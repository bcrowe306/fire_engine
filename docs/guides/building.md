---
title: Building
description: Every build procedure in one place, as Task commands and as the plain commands behind them; the app layer's static SDL3 and Dear ImGui.
---

Fire Engine's build procedures live in Taskfiles, run with
[Task](https://taskfile.dev) (`brew install go-task`, `snap install task
--classic`, `choco install go-task`). `task --list` shows them all. Each
task is a few plain commands, written out below so you can run them by
hand without Task.

| Task | What it does |
|------|--------------|
| `task engine:test` | All engine test packages (`task engine:test -- dsp` for one) |
| `task engine:test:both` | The same at `-o:none` and `-o:speed` (before committing) |
| `task engine:docs` / `engine:docs:check` | Regenerate / check the reference docs |
| `task engine:examples` | Build and run `examples/` headless |
| `task engine:clap`, `engine:link`, `engine:surface` | Optional test fixtures (CLAP plug-ins, Ableton Link, a surface script) |
| `task deps` | Fetch and build SDL3 and Dear ImGui as static libraries (once per machine) |
| `task app:pads` | Build the Pads app (`OPT=none` for a debug build) |
| `task app:run` | Build and run Pads |
| `task app:drive -- FILE` | Run Pads from a drive script |
| `task app:test` | Test the application layer, including UI cases with a window |
| `task cloud:test MACHINE=arm` | Run the suite on a cloud test machine (`linux`, `arm`, `windows`) |

## The engine

The engine needs only Odin and a C compiler; its tasks call the scripts in
`scripts/`:

```bash
./scripts/test.sh                         # task engine:test
FIRE_OPT="none speed" ./scripts/test.sh   # task engine:test:both
./scripts/docs.sh                         # task engine:docs
./scripts/examples.sh                     # task engine:examples
```

Every build passes `-collection:fire=f_engine`.

## The app layer's libraries

The application layer (`app/`) and its apps (`apps/`) link SDL3 and Dear
ImGui **statically**, so an app is one executable with no libraries beside
it. `task deps` fetches pinned sources into `.deps/` (gitignored) and builds
them where the vendored Odin bindings look for them:

| Library | Version | Built into |
|---------|---------|------------|
| SDL3 | `release-3.4.16` | `vendor/sdl3/lib/<os>_<arch>/libSDL3.a` (`SDL3-static.lib` on Windows) |
| Dear ImGui (docking) | `v1.92.9b-docking` | `vendor/imgui/libimgui_<os>_<arch>.a` (`imgui_windows_x86_64.lib`) |
| dear_bindings (ImGui's C API) | `DearBindings_v0.21_ImGui_v1.92.9b-docking` | generated into `.deps/generated/` |

The Odin bindings themselves are committed: `vendor/sdl3` (Odin's
`vendor:sdl3`, changed only to link the static library) and
`vendor/imgui` (odin-imgui's generated bindings with the SDL3 and SDL_GPU
backends). Open Sans is in `vendor/fonts` and is embedded in each binary.

You need git, CMake (3.20+), a C/C++ compiler and Python 3. On Linux, also
SDL's build dependencies:

```bash
sudo apt-get install -y build-essential pkg-config ninja-build python3-venv \
  libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev \
  libxss-dev libxtst-dev libxkbcommon-dev libdrm-dev libgbm-dev libgl1-mesa-dev \
  libgles2-mesa-dev libegl1-mesa-dev libdbus-1-dev libudev-dev libpulse-dev \
  libwayland-dev libdecor-0-dev libvulkan-dev mesa-vulkan-drivers
```

(`mesa-vulkan-drivers` is Mesa's software Vulkan, for running the UI
headless on machines without a GPU.)

By hand, `task deps` is (on macOS and Linux; on Windows the library names
differ as in the table):

```bash
# SDL3, static
git clone --depth 1 --branch release-3.4.16 https://github.com/libsdl-org/SDL.git .deps/src/SDL
cmake -S .deps/src/SDL -B .deps/build/sdl3 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build .deps/build/sdl3 --config Release --parallel
cmake --install .deps/build/sdl3 --config Release --prefix .deps/sdl3
mkdir -p vendor/sdl3/lib/darwin_arm64        # <os>_<arch> of this machine
cp .deps/sdl3/lib/libSDL3.a vendor/sdl3/lib/darwin_arm64/

# Dear ImGui with its C API, static
git clone --depth 1 --branch v1.92.9b-docking https://github.com/ocornut/imgui.git .deps/src/imgui
git clone --depth 1 --branch DearBindings_v0.21_ImGui_v1.92.9b-docking https://github.com/dearimgui/dear_bindings.git .deps/src/dear_bindings
python3 -m venv .deps/venv
.deps/venv/bin/python -m pip install -r .deps/src/dear_bindings/requirements.txt
mkdir -p .deps/generated
.deps/venv/bin/python .deps/src/dear_bindings/dear_bindings.py --nogeneratedefaultargfunctions \
  -o .deps/generated/dcimgui .deps/src/imgui/imgui.h
cmake -S vendor/imgui -B .deps/build/imgui -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DIMGUI_DIR=$PWD/.deps/src/imgui -DGENERATED_DIR=$PWD/.deps/generated -DSDL3_INCLUDE=$PWD/.deps/sdl3/include \
  -DOUTPUT_NAME=libimgui_macosx_arm64 -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY=$PWD/vendor/imgui
cmake --build .deps/build/imgui --config Release --parallel
```

`task deps:clean` removes all of it.

## Apps

An app build passes three collections: the engine, the app layer, and the
vendored bindings:

```bash
odin build apps/pads -collection:fire=f_engine -collection:app=app -collection:deps=vendor \
  -o:speed -vet -strict-style -out:.build/app/pads     # task app:pads
```

The result has no SDL or ImGui library to ship beside it (`otool -L` on
macOS, `ldd` on Linux show only system libraries).

Pads takes a fourth, `padslink`: `apps/pads/link/on` (Ableton Link built
in, when `./scripts/link.sh` or `task deps` has built its library) or
`apps/pads/link/off` (without it; `task app:pads LINK=0` asks for this).
Pads is GPL-3.0-or-later (`apps/pads/LICENSE`); Fire Engine stays MIT.

## Testing the app layer

```bash
./scripts/test.sh app_ui                 # headless odin tests of app:ui
odin build apps/ui_tests -collection:fire=f_engine -collection:app=app -collection:deps=vendor \
  -out:.build/app/ui_tests && .build/app/ui_tests --out .build/app/ui_tests_shots
```

`task app:test` runs both. The UI cases are a program rather than
`odin test` package because macOS allows windows only on the main thread.
See [the application layer](/guides/app-layer/) for drive scripts and
screenshots.

## Releases

Pads' packages are made by `scripts/release/`, each on its own system
(the cloud test machines do Linux, ARM and Windows), into
`.build/release`:

```bash
task release:macos     # Pads.app in Pads-<version>-macos-arm64.dmg (dmgbuild, from task deps)
task release:linux     # Pads-<version>-linux-<arch>.AppImage and pads_<version>_<arch>.deb
task release:windows   # Pads-<version>-windows-x86_64-setup.exe (Inno Setup) and a .zip
task release:icons     # the icons, from apps/pads/assets/icon_source.jpeg (macOS; committed)
```

Each is built optimized, with debug info (crash reports name lines),
stamped with its version (`PADS_VERSION` in `apps/pads/version.odin`),
commit and date (`pads --version`, Help > About Pads), and carries the
licences of Pads and what it is built from. The AppImage needs
appimagetool (`~/tools/appimagetool-<arch>.AppImage`, or
`$APPIMAGETOOL`); the installer needs Inno Setup 6's `ISCC.exe` (or
`$ISCC`). The packages are unsigned for now: on macOS the app has an
ad-hoc signature (Apple silicon runs nothing unsigned), and the first
open is right-click > Open. Release notes: `docs/release-notes.md`.
