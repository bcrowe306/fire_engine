---
title: Signalsmith Stretch reference timings
description: Speed of the C++ Signalsmith Stretch 1.4.0 on the reference cases, the baseline for the Odin port.
---

Recorded by `tools/stretch_golden` on Apple M1, Darwin/arm64, 2026-11-04.
The C++ was built by `scripts/stretch.sh` (CMake Release). Times are the best of 3 runs.

| Case | Channels | Output (s) | CPU (ms) | × real time |
|---|---|---|---|---|
| `sweep_rate_1` | 1 | 1.00 | 6.72 | 149 |
| `sweep_rate_0p8` | 1 | 1.25 | 7.12 | 176 |
| `sweep_rate_1p25` | 1 | 0.80 | 4.40 | 182 |
| `sweep_rate_0p5` | 1 | 2.00 | 10.24 | 195 |
| `sweep_rate_2` | 1 | 0.50 | 2.82 | 178 |
| `drums_rate_0p75` | 1 | 1.33 | 6.66 | 200 |
| `drums_rate_1p5` | 1 | 0.67 | 3.54 | 188 |
| `drums_rate_3_random` | 1 | 0.33 | 2.01 | 166 |
| `voice_rate_0p4_random` | 1 | 2.50 | 13.50 | 185 |
| `voice_up_7` | 1 | 1.00 | 6.36 | 157 |
| `voice_down_12` | 1 | 1.00 | 5.83 | 172 |
| `voice_up_7_tonality` | 1 | 1.00 | 6.43 | 156 |
| `drums_up_3_slower` | 1 | 1.20 | 7.75 | 155 |
| `voice_formant_1p25_compensated` | 1 | 1.00 | 7.71 | 130 |
| `voice_up_7_formant_kept` | 1 | 1.00 | 8.97 | 112 |
| `voice_formant_base_120` | 1 | 1.00 | 8.76 | 114 |
| `voice_freq_map` | 1 | 1.00 | 6.49 | 154 |
| `drums_cheaper` | 1 | 1.00 | 3.17 | 315 |
| `sweep_split` | 1 | 1.00 | 4.98 | 201 |
| `drums_split_0p8` | 1 | 1.25 | 6.64 | 188 |
| `drums_stereo_1p25` | 2 | 0.80 | 7.17 | 112 |
| `voice_44k_0p9` | 1 | 1.11 | 6.15 | 181 |
| `sweep_odd_chunks` | 1 | 1.25 | 6.68 | 187 |
| `sweep_flush` | 1 | 1.08 | 4.86 | 223 |
| `drums_seek` | 1 | 1.00 | 4.54 | 220 |
| `voice_exact_1p5` | 1 | 1.50 | 7.96 | 188 |

**Benchmark:** 10 s of stereo drums at 48 kHz, default preset, rate 1, 512-frame chunks: 70.5 ms of CPU (142× real time, 0.70% of one core).

## The Odin port

Same benchmark, same Mac, `-o:speed`, run alone (best of 5):

| Version | ms | × real time |
|---|---|---|
| First port (scalar) | 130.5 | 77 |
| Optimised (bit-identical output) | 70.7 | 141 |

Profiled with spall zones around each stage (one per `run_step`, plus the FFT calls), the first port spent 37% of its time in FFTs and 46% in the phase-vocoder loops. The changes, none of which alters a single output bit:

- **FFT stages in `#simd[4]f32`** (two transforms per vector, the scalar arithmetic operation for operation): 2.9× faster, 26.7 µs per forward + inverse pair at 6144 points against Linear's 39.3 µs. `tests/dsp` checks it bit for bit against the scalar stages.
- **Per-band phase rotations precomputed** at configure time (the same multiply chain the C++ runs every block): 9.1 → 2.3 ms.
- **STFT windowing in runs** that neither wrap the ring buffer nor cross the window's centre, so they vectorise: analysis and synthesis windowing 11.9 → 5 ms.
- **Cheaper exact forms** of `math.floor`, scaling by `complex(k, 0)` and dividing by it.

What remains is mostly the phase-locked prediction (about 24 ms), a chain from each band's output to the next through a division and a square root, and (when pitch-shifting) the energy smoothing, a recursive filter across bands. Both are inherently serial and kept exactly as in the C++.

`port_speed` in `tests/stretch_port` logs this benchmark too, but runs alongside the package's other tests, so it reads higher.
