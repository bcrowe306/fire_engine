---
title: Single-board computers
description: Running Fire Engine on ARM Linux boards such as the Raspberry Pi: building, audio and MIDI setup, realtime priority, and how much the nodes cost there.
---

Fire Engine runs on 64-bit ARM Linux (`linux_arm64`) as it does on x86
Linux: the same packages, with the ALSA and JACK backends and the ALSA
sequencer for MIDI. Every test package runs there in CI-like conditions
(see [testing on ARM](#testing-on-arm)). This page covers what is
different on a small board.

## Building

Install the [Odin](https://odin-lang.org) release for `linux-arm64` and
clang, then build as anywhere else:

```bash
sudo apt-get install -y clang libasound2-dev
odin build my_app -collection:fire=f_engine -o:speed
```

Build with `-o:speed` for anything that plays audio: unoptimized DSP
code runs several times slower (the test suite runs both levels).
`fire:audiofile/codecs` needs Odin's miniaudio, built once with
`$(odin root)/vendor/miniaudio/src/build_miniaudio.sh`.

Flush-to-zero (`rt.enable_flush_to_zero`, which the backends call on
their audio threads) sets the arm64 FPCR, so denormals cost nothing here
either.

## Audio and MIDI

- **ALSA** (`fire:backend/alsa`) talks to the board's sound card or a
  USB interface directly. List devices with `aplay -l`; open the `hw:`
  device for the lowest latency.
- **JACK** (`fire:backend/jack`) if other programs share the audio.
- **MIDI**: the ALSA sequencer backend (`fire:midi/alsa`) sees USB MIDI
  devices as they are plugged in.

## Realtime priority

The audio thread asks for `SCHED_FIFO` (`rt.set_realtime_priority`). On
Linux that needs permission: give your user an rtprio limit, and the
audio group, once:

```bash
echo '@audio - rtprio 95' | sudo tee /etc/security/limits.d/audio.conf
echo '@audio - memlock unlimited' | sudo tee -a /etc/security/limits.d/audio.conf
sudo usermod -aG audio "$USER"   # then log in again
```

Without it the engine still runs, at normal priority, and drops out as
soon as anything else on the board is busy. A `PREEMPT_RT` or
low-latency kernel helps further at small block sizes.

## How much fits

`tools/node_bench` measures each node, and a whole mix, on the machine
it runs on:

```bash
odin run tools/node_bench -collection:fire=f_engine -o:speed -- 64 16
```

The arguments are the block size and the number of tracks in the mix
(each a synth, a 4-band EQ, a compressor and a gain, into a reverb and a
limiter). Measured at 64-frame blocks (1.33 ms at 48 kHz), as a share of
that budget:

| Node | Graviton2, 2 cores | x86 cloud VM, 2 cores | Apple M-series |
|------|------:|------:|------:|
| gain | 0.04% | 0.08% | 0.02% |
| filter | 0.10% | 0.13% | 0.13% |
| EQ, 4 bands | 0.28% | 0.34% | 0.29% |
| compressor | 0.43% | 0.44% | 0.20% |
| limiter | 0.21% | 0.40% | 0.10% |
| delay | 0.35% | 0.34% | 0.11% |
| chorus | 0.95% | 0.89% | 0.27% |
| phaser | 1.03% | 1.06% | 0.38% |
| reverb | 1.75% | 1.56% | 0.54% |
| saturation, 4× oversampled | 1.98% | 1.84% | 0.75% |
| convolution, 1 s response | 2.66% | 2.89% | 0.94% |
| synth, 8 notes | 3.07% | 4.12% | 0.98% |
| **16-track mix** | **33%** | **50%** | **12%** |

The mix uses the graph's worker threads (one per core but one). These are
medians; leave headroom for the worst blocks, which on a busy board can
take several times as long. Graviton2 cores (Neoverse N1) are faster than a
Raspberry Pi 4's Cortex-A72 and slower than a Pi 5's Cortex-A76, so run the
benchmark on your board before you size a project.

Ways to fit more:

- **Larger blocks.** Per-block overhead (event handling, waking workers)
  is spread over more frames; 128 or 256 frames often doubles what fits,
  at the cost of latency.
- **Fewer oversampled and convolution nodes**: they are the expensive
  ones. Convolution cost grows with the response length.
- **Workers.** `graph.Settings.workers` defaults to one per core but one;
  a graph with few parallel paths may do better with fewer
  (`parallel_min_us` already keeps small graphs on one thread).
- **Synth voices.** Cost follows the notes sounding, not the voice count.

## Testing on ARM

The repository's own ARM test machine is an AWS Graviton instance
(`t4g.small`: 2 cores, 2 GB), set up like the x86 Linux droplet:

```bash
./scripts/cloud/arm.sh up     # start, or create (~5 min): Odin, clang, jackd, miniaudio
./scripts/cloud/arm.sh test   # copy the working tree and run the whole suite
./scripts/cloud/arm.sh off    # stop at the end of the session
```

Its kernel has no `snd-aloop`, so the ALSA tests that need a loopback
card skip; everything else runs. It is set to unlimited CPU credits:
burstable instances in standard mode run out of credits and are held to
20% of a core, which makes timing tests fail for reasons a real board
would not have.
