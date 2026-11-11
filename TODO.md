# TODO

Work agreed on but not started. Each item needs a plan before it is built.

## Pads

- **Control surfaces.** Load a surface script (the engine's `fire:surface`
  manager), give it MIDI in and out ports, load and unload it from Settings
  > MIDI. To plan first: what a script can see and do (pads, sequences,
  transport, the mixer, the selection, LEDs and displays), how it maps to
  the app's commands, how scripts are found, versioned and reloaded, and
  how they are tested without hardware.
- **One item on macOS.** A `.pads` project shows as a folder in Finder;
  packaging Pads as an `.app` with a document type would show it as one
  file.
- **Warp cache.** Renderings in a project's `warped/` folder are never
  removed; clean up those no pad uses (on save, or from Settings > Project).
- **Several strips at once: more fields.** Inserts and EQ are not yet
  edited across selected channel strips.
