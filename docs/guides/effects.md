---
title: Effects
description: Filters, parametric EQ and dynamics (compressor, gate, lookahead limiter), as primitives for your own nodes and as ready-made nodes with automatable parameters.
---

`fire:dsp` has effects in two forms:

- **Primitives**: plain structs and procedures (`svf_design`, `svf_tick`)
  to build into your own nodes. Coefficients are shared; each channel has
  its own small state struct.
- **Nodes**: ready to add to a graph, with stable parameter ids, smoothing,
  and sample-accurate automation (`filter_create`, `eq_create`).

`examples/effects` runs noise through a swept filter, an EQ, a compressor
and a limiter, offline.

## Filters

Two filter structures with the same responses:

| | `Svf` (state-variable) | `Biquad` |
|---|---|---|
| Design | `svf_design` (Simper's trapezoidal SVF) | `biquad_design` (RBJ cookbook) |
| Modulation | stable and smooth when changed every sample | fine when static; can click or blow up when changed quickly |
| Cost (Apple M1) | 8.9 ns per sample | 6.4 ns per sample |

Both are the analog prototype through the bilinear transform with the
cutoff prewarped, so their responses agree (to a millionth of a dB in the
tests). Use the SVF for anything that moves.

**Modes** (`Filter_Mode`): `Lowpass`, `Highpass`, `Bandpass` (0 dB at the
centre), `Notch`, `Peak` (a resonance), `Allpass`, `Bell`, `Low_Shelf` and
`High_Shelf`. `q` is 0.707 for a flat lowpass or highpass; `gain_db` is
for the bell and shelves, whose cutoff is where half the gain is reached.

```odin
c := dsp.svf_design(mode = .Bell, cutoff_hz = 2500, q = 2, gain_db = -6, sample_rate = sr)
states: [2]dsp.Svf_State
for ch in 0 ..< 2 do dsp.svf_process(&c, &states[ch], buffers[ch])
gain, phase := dsp.svf_response(&c, 1000, sr) // for drawing the curve
```

**The `Filter` node** is one SVF per channel with automatable mode,
cutoff, Q and gain (`FILTER_PARAM_*`). Cutoff, Q and gain are smoothed over
20 ms; automation ramps (`core.Param_Ramp`) are followed exactly.

## Parametric EQ

`eq_create(bands)` makes an EQ of up to 8 SVF bands in series and an
output gain. It starts flat: a low shelf, bells spread from 100 Hz to
8 kHz, and a high shelf. Each band's parameters have stable ids from
`eq_band_param(band, field)`:

```odin
eq, _ := graph.add_node(g, dsp.eq_create(4), 2, 2)
graph.set_param(g, eq, dsp.eq_band_param(0, .Gain_Db), 3)          // low shelf +3 dB
graph.set_param(g, eq, dsp.eq_band_param(2, .Mode), f64(dsp.Filter_Mode.Notch))
graph.set_param(g, eq, dsp.eq_band_param(2, .Freq_Hz), 60)         // hum
graph.set_param(g, eq, dsp.eq_band_param(3, .On), 0)               // bypass a band
```

`eq_response` gives the whole EQ's gain at a frequency, from the settings
in use, for drawing its curve. An 8-band stereo EQ costs 0.5% of a
512-frame block on an Apple M1.

## Dynamics

Three nodes, all stereo-linked (one gain for every channel, from the
loudest), with a gain-reduction meter readable from any thread:

| Node | Does | Meter |
|---|---|---|
| `compressor_create()` | turns down what is over the threshold, by the ratio, with a soft knee | `compressor_gain_reduction_db` |
| `gate_create()` | turns down what is under the threshold: a gate, or (at ratios of 2 to 4) an expander | `gate_reduction_db` |
| `limiter_create(lookahead_ms)` | keeps every sample under the ceiling | `limiter_gain_reduction_db` |

```odin
comp, _ := graph.add_node(g, dsp.compressor_create(), 2, 2)
graph.set_param(g, comp, dsp.COMPRESSOR_PARAM_THRESHOLD_DB, -24)
graph.set_param(g, comp, dsp.COMPRESSOR_PARAM_RATIO, 3)
graph.set_param(g, comp, dsp.COMPRESSOR_PARAM_MIX, 50) // parallel compression
```

- **The compressor** follows Giannoulis, Massberg and Reiss (2012): level
  in dB (peak, or RMS over 10 ms), a soft-knee static curve
  (`compressor_curve`), and attack and release applied to the gain
  reduction in dB. Attack and release are the times to cover 63% of a
  change.
- **Sidechain:** add a compressor or gate with more inputs than outputs
  (4 in, 2 out for stereo), and the extra inputs drive it instead of the
  signal: ducking under a voice, a gate keyed by a drum.
- **The gate** opens above its threshold and closes once the level is
  `hysteresis` below it and the hold time has passed, so it doesn't
  chatter. Range limits how far it turns down.
- **The limiter** guarantees its ceiling on every sample. It looks ahead
  (5 ms by default; reported as the node's latency, which the graph
  compensates), takes the smallest gain any sample in that window needs,
  and averages it over the same window. Every term of that average is a
  minimum over a window that includes the sample about to play, so the
  gain is never too high for it; a release then lets the gain recover
  smoothly. Below the ceiling it passes the signal through exactly. The
  ceiling is for samples: on dense material, inter-sample peaks after
  conversion can be about 0.5 dB higher, so leave that much headroom for
  masters.

For your own nodes, the parts are primitives: `compressor_curve`,
`expander_curve`, `Level_Detector`, `Gain_Smoother` and `time_coeff`.
On an Apple M1, per 512-frame stereo block: compressor 21 µs (0.2%),
gate 11 µs, limiter 8 µs.

## See also

- [`fire:dsp` reference](/reference/dsp/)
- [Writing a node](/guides/writing-a-node/): using the primitives in your own nodes
