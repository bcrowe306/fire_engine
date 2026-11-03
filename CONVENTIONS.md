# Fire Engine — Coding Conventions

These rules apply to all code in `f_engine/` and `tests/`. When a rule is broken
on purpose, leave a comment explaining why.

## Language & toolchain

- Odin, pinned in CI to the version in `.github/workflows/ci.yml` (`dev-2026-10` today).
- The source tree is one Odin collection: build with `-collection:fire=f_engine`.
  Import engine packages as `import "fire:dsp"`, never with relative paths.
- License: MIT. JUCE (in `JUCE/`) is a **design reference only**. Read it to
  understand a problem (driver quirks, backend abstraction shape), then write our
  own code. Never translate JUCE source line by line. The ASIO SDK is never
  committed; the ASIO backend is an opt-in build flag.

## Package layout

| Package          | Purpose                                                    | May import          |
|------------------|------------------------------------------------------------|---------------------|
| `fire:core`      | Shared types: `Event`, `Transport`, `Process_Context`, `Node`, `Param_Info`, `Error` | `fire:timebase` |
| `fire:timebase`  | Sample/second/beat/tick/BBT conversions, tempo map         | —                   |
| `fire:rt`        | Realtime utilities: FTZ/DAZ, SPSC queue, `host_time_ns` (the device/MIDI clock), `set_realtime_priority`, `precise_sleep` | — |
| `fire:dsp`       | DSP primitives and simple nodes                            | `core`, `rt`        |
| `fire:testkit`   | Test-only: generators, analyzers, WAV, golden files, null backend, callback harness | anything |
| `fire:backend`   | Device API and shared layer: format conversion, channel selection, block splitting, device events (see `docs/design/backend.md`) | `core`, `rt` |
| `fire:backend/fake` | Simulated driver for tests and headless runs           | `backend`, `core`   |
| `fire:backend/<api>` | Drivers: `coreaudio` (macOS), `alsa` and `jack` (Linux; JACK loaded at run time), `wasapi` (Windows); planned ASIO | `backend`, `core`, `rt`, `sys/<api>` |
| `fire:midi`      | MIDI 1.0 ⇄ UMP, input scheduling into blocks, SysEx queue, output sender, driver interface | `core`, `rt` |
| `fire:midi/<api>` | MIDI drivers: `coremidi` (macOS), `alsa` (Linux sequencer), `winmm` (Windows) | `midi`, `core`, `rt`, `sys/<api>` |
| `fire:sys/<api>` | Raw OS API bindings, no logic. Package name `<api>_sys` (Odin package names must be unique) | OS packages only |
| `fire:graph`     | Audio graph: nodes + connections, compiled plans, multithreaded scheduler, latency compensation (see `docs/design/graph.md`) | `core`, `rt` |

`dsp` must never import `backend` or `graph`. Engine packages must never import `testkit`.

Platform-specific files use build tags (`#+build darwin`). A test package for one
platform adds a `#+build !<os>` stub file with one empty test, so it compiles everywhere.

## Naming

- `snake_case` for procs, variables, fields and package names.
- `Ada_Case` for types (`Smoothed_Value`, `Tempo_Map`).
- `SCREAMING_SNAKE_CASE` for constants (`MAX_CHANNELS`).
- Enum members use `Ada_Case` (`.Out_Of_Memory`).
- Procs that run on the audio thread are documented with `// [rt]` above the
  declaration. Anything not marked `[rt]` may allocate or block.
- Units go in names when they aren't obvious: `cutoff_hz`, `gain_db`, `time_ms`, `offset_frames`.

## Numbers

- Audio samples are `f32`. Buffers are **planar**: `[][]f32`, one slice per channel.
- Use `f64` where precision matters: filter coefficients and state, phase
  accumulators, long sums, and all time and tempo math.
- Sample positions are `i64` (`timebase.Sample_Time`). Never use `f32` or `f64`
  for absolute time in samples.

## Memory

- Every proc that allocates takes an `allocator: mem.Allocator` parameter
  (defaulting to `context.allocator` is fine on the control thread).
- Whoever allocates something frees it. Pair each `make_*`/`init_*` with a `destroy_*`/`release_*`.
- **The audio thread never allocates, frees, locks or makes syscalls.** The test
  harness enforces this by installing a trapping allocator as both
  `context.allocator` and `context.temp_allocator` around every `process` call.
- Everything `process` needs is allocated in `prepare(sample_rate, max_block)`.

## Node lifecycle

```
init  →  prepare(sample_rate, max_block)  →  process* / reset*  →  release
          ↑                                                        │
          └──────────────── (re-prepare on rate/size change) ──────┘
```

- `init`: construct the node. Control thread; may allocate.
- `prepare`: allocate and size everything. Control thread. Returns `core.Error`.
- `process`: `[rt]`. Receives `frames` with `0 ≤ frames ≤ max_block`, and frames
  may change on every call. **Cannot fail**: there is no error return. Problems go
  into atomic counters or flags that the control thread reports later.
- `reset`: `[rt]`. Clears state (delay lines, envelopes, voices). Never allocates.
- `release`: frees what `prepare` allocated. Control thread.
- Always call these through `core.node_*`. In debug builds they assert that
  calls arrive in a legal order.

## Events & parameters

- Every block gets an `[]core.Event` sorted by `offset` (frames into the block).
- Parameters have **stable `u32` IDs** that never change once shipped. They are
  declared with `core.Param_Info` (range, default, unit, smoothing).
- Nodes opt in to `dsp.Smoothed_Value` for each parameter. Discrete or stepped
  parameters are not smoothed.

## Threads

- Control → audio: lock-free SPSC queues (`rt.Spsc_Queue`) carry commands and events.
- Structural changes (a new graph) are built on the control thread and swapped
  in with one atomic pointer store. The old object goes back on a queue and is
  freed on the control thread.
- Audio threads enable FTZ/DAZ (`rt.enable_flush_to_zero`) and request realtime
  priority.

## Errors

- Control-thread procs return `(value, core.Error)` or just `core.Error`.
  Propagate with `or_return`.
- A proc that builds something in steps and cleans up on failure fills a
  caller-owned pointer (`open_x(a, &a.thing, ...) -> Error`) instead of
  returning the struct. A `defer` that cleans up a named result is not reliably
  visible to the caller: in the WASAPI driver at `-o:speed`, the caller got the
  pre-cleanup value and released COM objects twice.
- `assert` is for invariants (bugs), not for expected failures. Asserts stay on
  in debug builds and in tests.
- `panic` is for unrecoverable programmer errors only, and never on the audio thread.

## SIMD

- Write clear scalar loops first. Use `#simd` only when a benchmark shows it
  helps, and keep the scalar version as a reference that the SIMD version is tested against.

## Testing (see `tests/README.md`)

- Every DSP unit is tested through `testkit.render` (the null backend), never by
  calling `process` by hand.
- Every DSP test checks at least that:
  1. output is finite (no NaN or Inf)
  2. the trapping allocator recorded no allocations in `process`
  3. output is block-size invariant
- Compare floats with tolerances, either absolute or in dB. Never check floats
  for exact equality unless the test is about bit-exactness.
- Golden files live in `tests/golden/`. Regenerate them only on purpose, with
  `FIRE_UPDATE_GOLDEN=1`, and review the diff plot first.

## Style

- Tabs for indentation, as `odin` and the core library do.
- Keep procs short. If it needs a long comment to explain *what* it does, split it.
- Comments explain *why* and give units or references (paper, equation, RFC).
