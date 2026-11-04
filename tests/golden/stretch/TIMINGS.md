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
