---
title: Profiling
description: Measuring where Pads and the engine spend their time with Spall traces (fire:prof), the benchmark projects, the trace summary, and perf on Linux.
---

Pads has to fit small machines (a Raspberry Pi 4 or 5, a low-end x86
laptop, an ARM laptop), so changes made for speed are measured first and
judged by their numbers on the ARM test machine, not only on a fast Mac.

## Zones: `fire:prof`

`fire:prof` records named zones into a [Spall](https://gravitymoth.com/spall/)
trace (Odin's `core:prof/spall`). It is off unless the build has
`-define:FIRE_PROF=true`; then `prof.zone` costs a few nanoseconds, and off
it compiles to nothing, so zones stay in the code.

```odin
import "fire:prof"

draw_mixer :: proc(a: ^App) {
	prof.zone("mixer") // ends with the scope
	...
	prof.begin("strips")
	...
	prof.end()
}
```

Every thread writes into a buffer of its own (32 MB, made on its first
zone) and names itself with `prof.thread_name`. A full buffer is written
out on its own thread (shown as "Spall Trace Buffer Flush"); on the audio
thread that is a syscall, so a profiling build is for measuring, not for
playing live.

What is zoned now:

- **Audio:** the device callback (`audio callback`), each block of the
  graph (`graph`) and each node in it, by type (`node_type_name`: its
  `type_id`, else its vtable's `name`); the graph's worker threads; in
  Synth 1, each voice step (`synth voice`), its oscillators (`synth osc`)
  and filters (`synth filter`), and its effects chain (`synth effects`).
- **UI:** the frame (`frame`) and its parts (`api_frame`, `host_update`,
  `fake audio`, `workspace`, `project_frame`, `sync`, `editors_frame`),
  every panel by its title (`Mixer`, `Sequence`, ...), the toolbar and
  status bar, SDL's events (`events`), `im.Render` and the GPU draw
  (`gpu draw`).

## Recording a trace

```bash
task app:pads-prof                       # .build/app/pads-prof, zones built in
.build/app/pads-prof --trace pads.spall  # use it; the trace is written when it quits
```

Open the file at [gravitymoth.com/spall](https://gravitymoth.com/spall/) for
a timeline, or summarize it:

```bash
python3 scripts/prof.py pads.spall --per frame --budget graph=5333
python3 scripts/prof.py before.spall after.spall --compare --per frame
```

For each thread (graph workers merged), each zone's calls, total and self
time (less the zones inside it), the median and 99th percentile of one
call, and with `--per frame` its time per frame. `--budget ZONE=US` sets a
zone's calls against a budget: an audio block of 256 frames at 48 kHz is
5333 µs, a frame at 60 a second 16667 µs.

## The benchmark

```bash
./scripts/profile.sh [DIR] [FRAMES]      # default .build/profile, 600 frames
```

It plays `tests/app_ui/drive/profile_heavy.txt` (eight synth pads of three
oscillators × four unison voices and two filters, four with chorus and
reverb, holding chords; drums and a chopped loop; inserts, a bus reverb)
headless on the fake device, with each main view shown (Sequence, Mixer,
Song, Perform), and an empty project; a trace and a summary of each go into
DIR. On a machine without a GPU, `gpu draw` is the software renderer's.

## Cache and branch counters: perf (Linux)

```bash
perf stat -e cycles,instructions,cache-misses,L1-dcache-load-misses,LLC-load-misses,dTLB-load-misses,branch-misses -- \
  .build/app/pads-prof --fake --headless --profile 600 --drive .build/profile/heavy-sequence.txt
perf record -F 1999 -g -- .build/app/pads-prof --fake --headless --profile 600 --drive .build/profile/heavy-sequence.txt
perf report --no-children --sort symbol
```

Virtual machines may not pass the hardware counters through (perf then
reports them `<not supported>`); `perf record` still samples by time.

## What it has found

Measured 2026-11-14, the heavy project's audio alone (`heavy-audio`) on the
ARM machine (AWS t4g.small: 2 Graviton2 cores), as a share of a 256-frame
block:

| | median | p99 |
|---|---|---|
| before | 43.3% | 47.2% |
| after the reverb, chorus and loudness meter | 32.5% | 37.9% |
| after the pads' strips and flat EQ bands | 30.0% | 34.0% |

- **The reverb** (Synth 1's, and the inserts' and buses', which are the
  same): its delays' wander called `sin` or `cos` sixteen times a sample;
  now a point turned a step each sample gives the four phases it needs.
  Its sixteen lines run as four `#simd[4]f32` rows of the 4 × 4 grid it
  mixes them in. 71 → 40 µs a block on an M-series core.
- **The chorus**: its eight delays (a pair a voice) ran one at a time,
  each working out the same filter and mix; now they share those
  (`delay_shared`), and run four at a time, a lane a delay. 67 → 33 µs.
- **The loudness meter** (the master's): its true-peak interpolator ran
  four 12-tap filters a sample in f64, each tap's index taken modulo the
  history; now the four phases are one `#simd[4]f32` sum over a history
  written twice (so the last 12 samples are always in a row). 106 → 12 µs a
  block on ARM; the readings are the same.

- **The pads' strips**: after its inserts each pad ran four nodes, a mute
  gain, its fader, a meter and an output gain, each with its own graph
  bookkeeping; now one `dsp.Strip` (`fire.strip`) does all four, its
  outputs the strip's out and its pre- and post-fader taps.
- **The EQ** (each pad's): a bell or shelf at 0 dB is now skipped (it
  passes its input exactly), so a pad's flat EQ costs nothing. On ARM,
  the graph workers' time in the EQ, gains, meters and strips went from
  397 ms to 182 ms of the heavy run.

Synth effects went from 45% of the graph workers' time to 30%. What is
left, largest first: the synth's effects, its voices (oscillators,
filters: SIMD unison already), and the inserts.

In the UI (per frame, on an M-series core; ARM is four to five times
that): the API's change subscriptions built a snapshot of every topic
each frame, though Pads itself subscribes to none (47 µs; 89 µs on
ARM); now only topics someone subscribes to are looked at, and a topic's
first subscriber takes its snapshot (0.1 µs). What a frame gives the GPU
is modest (`pads --profile` prints it: 6,600 to 23,000 vertices, 90 to
315 draw commands), well within a Raspberry Pi's GPU. The rest is spread
out: the Mixer's strips (about 10 µs each), the device editor (60 µs),
the Sequence view (55 µs). For small machines **Settings > Appearance >
Frame rate** caps the frames a second (60 or 30): the UI's cost goes with
its frames.

## Smaller pieces

- `tools/synth_bench`: Synth 1's voices against their budget, with one
  thing taken away at a time.
- `tools/node_bench`: each engine node, and a mix of tracks.
- `pads --profile N`: the CPU time of N frames drawn flat out.
