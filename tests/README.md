# Fire Engine tests

Each directory under `tests/` (except `golden/`) is an Odin test package.

```bash
./scripts/test.sh                       # everything, -o:none, with -vet -strict-style
FIRE_OPT=speed ./scripts/test.sh        # optimized
FIRE_OPT="none speed" ./scripts/test.sh # both at once (CI runs both)
./scripts/test.sh dsp                   # one package
```

All packages (and opt levels) build and run concurrently. Output is printed per
package when everything finishes: one summary line on success, the full log on
failure. Logs stay in `.test_artifacts/.run/`. `FIRE_TIMEOUT` (seconds, default
600) kills a hung package, which then fails.

| Package    | Covers |
|------------|--------|
| `testkit`  | The framework itself: generators, FFT, analyzers, WAV, trap allocator, NaN-sentinel detection, event delivery, and proof that the invariance check catches non-sample-accurate nodes |
| `timebase` | Sample/second/beat/tick/BBT conversions, tempo ramps, meter changes |
| `rt`       | Flush-to-zero, SPSC queue (including a 2-thread stress test) |
| `dsp`      | Smoother, gain, one-pole lowpass |
| `backend`  | Format conversion, block splitting, timestamps, channel selection, loopback through every format and plane layout, xrun/unplug/format events, rt allocations, threaded start/stop (all on the fake driver) |
| `coreaudio` | macOS only. SDK struct layouts, host clock vs CoreAudio, device listing; with BlackHole 2ch installed: loopback, start/stop, rate-change events (skipped without it) |

## Writing a DSP test

Always go through the null backend:

```odin
n := dsp.gain_create()
defer core.node_destroy(&n)

input := kit.buffer_make(2, 48_000, SR, context.temp_allocator)
kit.sine(input.channels[0], SR, 440, 0.5)
kit.buffer_mono_to_all(input)

cfg := kit.default_render_config()
cfg.blocks = kit.Random_Blocks{seed = 1, min = 0, max = cfg.max_block}
cfg.events = {{10_000, core.Param_Value{dsp.GAIN_PARAM_DB, -6}}}   // absolute frame

out, report := kit.render(&n, input, cfg, context.temp_allocator)
defer kit.render_report_destroy(&report)
kit.expect_clean_render(t, report)   // no rt allocs, every sample written & finite
```

Then assert behavior with analyzers: `tone_amplitude`, `response_db` (from an
impulse render), `thd_n_db`, `max_curvature` (clicks), `estimate_latency`,
`compare_buffers`. For any node that takes events, add `expect_block_invariant`
with `standard_block_patterns`.

## What `render` enforces on every `process` call

- `context.allocator` and `context.temp_allocator` are a **trap**: every allocation is counted, and the first call site is recorded.
- Output buffers are pre-filled with **NaN**, so any sample the node didn't write fails `expect_clean_render`.
- **FTZ/DAZ** is on, as on a real audio thread.
- Block sizes follow the configured pattern, including 0-frame blocks and sizes that change every call.
- Events are delivered sorted, with block-relative offsets. `Transport` advances with `sample_pos`, plus beats and tempo from `tempo_bpm` or a `Tempo_Map`.
- Each call is timed against its real-time budget (`report.timing`).

`testkit.Probe` is a pass-through node that records the events and transport it
saw. Use it to verify anything that claims to deliver events sample-accurately
(the graph, backends).

## Golden files

`kit.expect_golden(t, golden_dir(), "name", out)` compares against `tests/golden/name.wav`.
A missing or mismatched golden fails the test and writes `expected/actual/diff.wav`
plus `info.txt` into `.test_artifacts/<name>/`. `test.sh` then runs `scripts/plot.py`
to produce `plot.png` (waveform overlay, diff, and spectrum).

Regenerate on purpose only, and look at the plot first:

```bash
FIRE_UPDATE_GOLDEN=1 ./scripts/test.sh dsp
```
