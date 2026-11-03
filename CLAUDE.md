# Fire Engine

Realtime audio engine in Odin. See `ENGINE.md` for scope and `CONVENTIONS.md` for
rules. Read `CONVENTIONS.md` before writing code.

## Commands

```bash
./scripts/test.sh                 # all test packages
./scripts/test.sh dsp             # one package: tests/dsp
FIRE_UPDATE_GOLDEN=1 ./scripts/test.sh dsp   # regenerate golden WAVs (review diffs first)
python3 scripts/plot.py .test_artifacts/<name>   # render PNG of a failed audio comparison
```

Builds always need `-collection:fire=f_engine`.

## Non-negotiables

- Audio thread code (`// [rt]`): no allocation, locks, syscalls, logging or `fmt`.
- Planar f32 buffers. `process` frames vary from 0 to `max_block`.
- Test every DSP unit through `testkit.render` (null backend): finite output, zero
  rt allocations, block-size invariance, plus whatever behavior it promises.
- JUCE in `JUCE/` is a reference for design only. Never translate its code.
- When an audio test fails, look at the plot PNG in `.test_artifacts/` before changing code.
