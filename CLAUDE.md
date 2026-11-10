# Fire Engine

Realtime audio engine in Odin. See `ENGINE.md` for scope and `CONVENTIONS.md` for
rules. Read `CONVENTIONS.md` before writing code.

## Commands

```bash
./scripts/test.sh                 # all test packages, in parallel
FIRE_OPT="none speed" ./scripts/test.sh      # both optimization levels at once (do this before committing)
./scripts/test.sh dsp             # one package: tests/dsp
FIRE_UPDATE_GOLDEN=1 ./scripts/test.sh dsp   # regenerate golden WAVs (review diffs first)
python3 scripts/plot.py .test_artifacts/<name>   # render PNG of a failed audio comparison
```

Packages run concurrently; each package's full log is in `.test_artifacts/.run/<pkg>_<opt>.log`
(printed on failure). With several opt levels, artifacts go to `.test_artifacts/<opt>/<name>`.
A package that runs longer than `FIRE_TIMEOUT` seconds (default 600) is killed and fails.
Concurrent invocations need different `FIRE_ARTIFACTS_DIR`s.

### Taskfiles and the app layer

Every build procedure is also a Task (`task --list`; Taskfile.yml and
taskfiles/). The app layer (`app/`, apps in `apps/`) links SDL3 and Dear
ImGui statically:

```bash
task deps                 # once per machine: fetch + build static SDL3 and ImGui (into vendor/, gitignored)
task app:pads             # build .build/app/pads (collections: fire, app=app, deps=vendor)
task app:test             # tests/app_* (headless) + apps/ui_tests (UI cases with a window, main thread)
task app:pads-drive       # Pads driven by tests/app_ui/drive/pads*.txt (fake audio, headless; expect lines)
task app:e2e              # tests/e2e: Pads used by mouse and keys over --control (pytest); a crash fails with its report
task app:ctl              # Pads under remote control: type drive commands (click_item, drag_item, state...)
.build/app/pads --headless --drive tests/app_ui/drive/smoke.txt --out .build/app/shots   # scripted run + screenshots
```

Look at the screenshots after UI changes (layout, spacing, padding).
See docs/guides/building.md, docs/guides/app-layer.md and docs/guides/pads.md.

### Linux test machine (DigitalOcean)

```bash
./scripts/cloud/linux.sh up      # power on (or create) the Ubuntu x86 droplet: Odin, clang, snd-aloop
./scripts/cloud/linux.sh test    # copy the working tree (ignored files excluded) and run the suite
./scripts/cloud/linux.sh off     # power off at the end of the session (keep it; `down` destroys)
```

### ARM64 Linux test machine (AWS EC2 Graviton, us-east-2)

```bash
./scripts/cloud/arm.sh up      # start (or create: t4g.small, Ubuntu arm64, Odin, clang, jackd, miniaudio)
./scripts/cloud/arm.sh test    # copy the working tree and run the suite (two packages at a time: 2 GB)
./scripts/cloud/arm.sh off     # stop at the end of the session (`down` terminates)
```

It runs with unlimited CPU credits (standard mode throttles it to 20%, which
breaks timing tests). No `snd-aloop` on its kernel: ALSA loopback tests skip.

### Windows test machine (AWS EC2, us-east-2)

```bash
./scripts/cloud/windows.sh up     # start (or create: VS Build Tools, Git bash, Odin, VB-CABLE, loopMIDI, FlexASIO; ~30 min the first time)
./scripts/cloud/windows.sh test   # copy the working tree and run the suite
./scripts/cloud/windows.sh off    # stop at the end of the session (`down` terminates)
```

The AWS account allows EC2 only in us-east-2, and only Free-plan instance types
(hence m7i-flex.large rather than t3.large).

Credentials live in `secrets.env` (gitignored, never commit or print it).

### Docs and examples

```bash
./scripts/docs.sh            # regenerate docs/reference from doc comments (commit the result)
./scripts/docs.sh --check    # CI: reference current + every exported symbol documented
./scripts/examples.sh        # build and run examples/ headless (fake audio driver)
"$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"   # Linux only, once: miniaudio for fire:audiofile/codecs
./scripts/link.sh            # fetch + build Ableton Link (GPL, into gitignored third_party/) for fire:link; tests/link skips without it
./scripts/clap.sh            # build the CLAP test plug-ins (C, and Odin via fire:clap/sdk); tests/clap skips without them
./scripts/surface.sh         # build the C control-surface test script; tests/surface skips without it
```

Every exported symbol needs a doc comment; internals are `@(private)`. See the
Documentation section of CONVENTIONS.md. Docs are Starlight Markdown
(`docs/_integration.md`).

Builds always need `-collection:fire=f_engine`.

## Non-negotiables

- Audio thread code (`// [rt]`): no allocation, locks, syscalls, logging or `fmt`.
- Planar f32 buffers. `process` frames vary from 0 to `max_block`.
- Test every DSP unit through `testkit.render` (null backend): finite output, zero
  rt allocations, block-size invariance, plus whatever behavior it promises.
- JUCE in `JUCE/` is a reference for design only. Never translate its code.
- When an audio test fails, look at the plot PNG in `.test_artifacts/` before changing code.
