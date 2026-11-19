---
title: Effects
description: Filters, parametric EQ, dynamics (compressor, gate, lookahead limiter), delay and modulation (chorus, flanger, phaser), algorithmic reverb, zero-latency convolution and oversampled saturation, as primitives for your own nodes and as ready-made nodes with automatable parameters.
---

`fire:dsp` has effects in two forms:

- **Primitives**: plain structs and procedures (`svf_design`, `svf_tick`)
  to build into your own nodes. Coefficients are shared; each channel has
  its own small state struct.
- **Nodes**: ready to add to a graph, with stable parameter ids, smoothing,
  and sample-accurate automation (`filter_create`, `eq_create`).

`examples/effects` runs noise through a swept filter, an EQ, a ping-pong
delay, a reverb, saturation, a compressor and a limiter, offline, then
convolves the result with a room response.

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

## Delay and modulation

**`delay_create()`** is an echo: a delay with feedback, filtered inside the
loop so each repeat is thinner (`DELAY_PARAM_LOW_CUT_HZ`) and darker
(`DELAY_PARAM_HIGH_CUT_HZ`).

```odin
d, _ := graph.add_node(g, dsp.delay_create(), 2, 2)
graph.set_param(g, d, dsp.DELAY_PARAM_SYNC, 1)
graph.set_param(g, d, dsp.DELAY_PARAM_BEATS, 0.75) // a dotted eighth
graph.set_param(g, d, dsp.DELAY_PARAM_PING_PONG, 1)
```

- **Synced** to the tempo, it reads `ctx.transport` (so run the graph
  through the clock) and follows tempo changes.
- **Changing the time glides** there over about 100 ms, bending the
  echoes' pitch like tape instead of clicking.
- **Ping-pong** sends the mix of the inputs into the left line, and each
  echo to the other side.

**`chorus_create()`, `flanger_create()` and `phaser_create()`** share
their parameter ids (`MOD_PARAM_*`; each table lists the ones it uses).
Each channel's LFO is `spread` of a cycle apart, for width.

| Node | Is | Typical |
|---|---|---|
| Chorus | up to 4 copies per channel, delayed `delay` ± `depth` ms on spread LFO phases | 12 ms ± 3 ms at 0.8 Hz |
| Flanger | one short swept delay; mixed with the dry signal, moving comb notches; feedback sharpens them | 1–5 ms at 0.25 Hz, 50% feedback |
| Phaser | 2 to 12 first-order allpass stages swept on a log scale between `min` and `max`; every two stages make a notch | 200 Hz–3 kHz, 4 stages |

At 50% mix the flanger's and phaser's notches are complete: at rest, the
flanger at 1 ms cancels 500 Hz exactly, and a two-stage phaser at 1 kHz
cancels 1 kHz, as the tests check.

**Primitives** for your own nodes:

- `Delay_Line`: a ring buffer with fractional reads, none, linear or cubic
  (4-point Hermite, for anything modulated).
- `Lfo`: sine, triangle, saws, square and sample-and-hold, free-running
  or locked to beats with `lfo_sync`.

Costs per 512-frame stereo block on an Apple M1: delay 11 µs, chorus
27 µs, flanger 16 µs, phaser 40 µs (0.1% to 0.4% of the block).

## Reverb

**`reverb_create()`** is an algorithmic reverb: an 8-line feedback delay
network (Jot and Chaigne, 1991). Input is summed to mono, predelayed and
diffused by four allpass filters. The lines feed each other through a
Hadamard matrix, which mixes them without loss. Output is stereo, from two
orthogonal mixes of the lines, narrowed by `width`.

```odin
rv, _ := graph.add_node(g, dsp.reverb_create(), 2, 2)
graph.set_param(g, rv, dsp.REVERB_PARAM_DECAY_S, 2.5)   // RT60
graph.set_param(g, rv, dsp.REVERB_PARAM_HF_DECAY, 40)   // highs die in 40% of that
graph.set_param(g, rv, dsp.REVERB_PARAM_SIZE, 70)
graph.set_param(g, rv, dsp.REVERB_PARAM_MIX, 100)       // fully wet, for a send
```

- **The decay time is what you set.** Each line has an absorption filter
  that sets its loss at low and high frequencies from its length, so the
  measured RT60 is within 2% of `decay` at any size and modulation, and
  highs decay in `hf_decay` percent of it.
- **Modulation** wobbles the lines slowly against metallic ringing. The
  lines are read through allpass interpolation, which loses nothing, so it
  doesn't shorten the decay.
- **Size** scales the lines from a quarter to twice their length, gliding
  when changed while playing.
- Cost: 58 µs per 512-frame stereo block on an Apple M1 (0.5%).

## Convolution

**`convolution_create(ir)`** convolves with a recorded impulse response:
a real room, a speaker cabinet, any long FIR filter. There is no latency:
the first 64 taps run directly, and the rest in FFT partitions sized so
each one is finished before its output is due.

```odin
ir := your_load_ir("hall.wav") // planar [][]f32 at the graph's sample rate (audiofile, then Resampler)
v, _ := graph.add_node(g, dsp.convolution_create(ir), 2, 2) // a stereo IR: one channel each
graph.set_param(g, v, dsp.CONVOLUTION_PARAM_MIX, 30)
```

- An impulse response with one channel is used for every output; with
  several, output channel i uses channel i.
- Long responses don't cost spikes. Partitions after the first 2048 taps
  are 1024 frames long and their work is spread over the 1024 frames after
  each block arrives, so every frame costs about the same. On an Apple M1,
  with 64-frame blocks, one channel of a 2 s response averages 0.6% of a
  block (worst 3%), and a 10 s response 1.9% (worst 4.3%).
- The result matches direct convolution (within 2 × 10⁻⁶ of the peak in
  the tests) and doesn't depend on block sizes.

The primitive is `Convolver` (`convolver_init`, `convolver_process`): one
channel, any length per call, also useful offline.

## Saturation

**`saturation_create(oversample)`** drives the signal into a curve, then
blocks DC and sets the output level, mixed with the dry signal:

| `Saturation_Shape` | Curve | Sound |
|---|---|---|
| `Soft` | tanh | smooth, odd harmonics |
| `Hard` | a clip at ±1 | bright, buzzy |
| `Tube` | tanh, harder on the negative side | even harmonics too |
| `Fold` | a sine wavefolder | past full scale the wave folds back |
| `Cubic` | x − 4x³/27, flat from ±1.5 | the gentlest |

**Oversampling.** A curve makes harmonics far above the input, and at the
base rate those above Nyquist fold back as aliasing: inharmonic tones
that sound harsh and digital. Run 2, 4 or 8 times faster, they have
room. Hard-clipping a 6.3 kHz sine at +12 dB:

| Oversampling | Aliasing | Latency at 48 kHz | Cost (stereo, 512 frames, M1) |
|---|---|---|---|
| 1× | −16 dB | 0 | 14 µs |
| 2× | −33 dB | 31 frames | 65 µs |
| 4× | −42 dB | 39 frames | 115 µs |
| 8× | −46 dB | 41 frames | 171 µs |

The oversampling is fixed when the node is made, and its latency is
reported, so the graph keeps parallel paths aligned; the node delays its
own dry signal to match.

**The primitive** is `Oversampler`: `oversampler_up` returns the block at
the high rate, you process it, and `oversampler_down` brings it back. Its
2× stages are linear-phase halfband FIRs (63, 31 and 19 taps), and the
round trip is a pure delay of `oversampler_latency` frames within 10⁻⁴
below 10 kHz.

## Effects for playing live

Six effects made for a sampler's performance pads (stereo; the cutter and
stutter follow the clock's grid, 120 BPM without one):

| Node | What it does | Parameters |
|------|--------------|------------|
| `bitcrush_create` | fewer bits, a lower sample rate | bits, downsample, mix |
| `ring_mod_create` | multiplies by a sine: metallic sidebands | frequency, mix |
| `comb_create` | a short delay fed back: rings at its pitch | frequency, feedback, mix |
| `pitch_shift_create` | pitch without changing length (two crossfaded read heads, a grainy texture) | semitones, window, mix |
| `cutter_create` | a trance gate on the grid, with 2 ms edges | rate (beats), duty, depth |
| `stutter_create` | always listening; switched on, loops the slice that just went by | length (beats), active |

## SuperFilter

`fx.super_filter_create` (in `fire:fx`) is an auto filter: one filter,
moved by an LFO and an envelope follower, with a drive and clip stage.

- **Types:** Low, High, Band, Notch, Peak, Morph (low → band → high →
  notch on one knob), DJ (low-pass to the left of its knob, high-pass to
  the right, flat in the middle), Comb, Vowel and Phaser.
- **Circuits:** Clean, Analog, Dirty, Ladder and Diode, each `fx` filter
  model with its own colour. Diode makes Low only; another type on it
  plays on Analog (`super_filter_circuit_has`). The slope (12 or 24 dB)
  is for Low, High, Band and Morph (`super_filter_has_slope`).
- **LFO** (`fx.lfo_render`, usable alone): seven waves with a Morph each
  (skew, curve, pulse width, glide); its rate in Hz, a tempo division
  (straight, dotted, triplet) or sixteenths. Synced, it follows the
  timeline, so it is at the same place in its cycle wherever play starts.
  The right side runs ahead by a phase, or faster (Spin). It can restart
  each beat, each bar or when play starts, and be smoothed.
- **Envelope** (`fx.follower_render`, usable alone): attack, release,
  Hold (it stays up through a drum's body) and sample-and-hold on a
  division. Its level is in dB over 48 dB, so a quiet key still moves it.
  Added with four inputs, the node follows inputs 3 and 4 (a sidechain
  key) instead of its own.
- **The cutoff** moves in octaves: the LFO's and the envelope's amounts
  are each up to ±5 octaves, per frame and per side.
- **Output:** a soft clip (never over full scale), output gain and
  Dry/Wet.
- **Latency:** it filters in 32-frame pieces, each gathered whole, so its
  output is the same at any block size: 32 frames late, which it reports
  (`latency`). A parameter change lands at the start of the piece it falls
  in, or the next.
- **For drawing it:** `super_filter_readout` gives the modulated cutoff of
  each side, the LFO, the envelope and the peaks in and out, from any
  thread. `super_filter_impulse` renders the filter stage's impulse
  response at settings you give, to measure the curve it makes.

```odin
node, sf := fx.super_filter_create({})
graph.add_node(g, node, 4, 2) // (two inputs: it follows itself)
graph.set_param(g, id, fx.SF_PARAM_TYPE, f64(fx.Sf_Type.Band))
graph.set_param(g, id, fx.SF_PARAM_ENV_AMOUNT, 0.5)
cut := fx.super_filter_readout(sf).cutoff_hz // where it is now
```

One stereo instance, the LFO and envelope moving, takes 0.3 to 1.2 % of a
core on an Apple-silicon Mac at `-o:speed` (Phaser the dearest).

## ProEq

`fx.pro_eq_create` (in `fire:fx`) is an eight-band parametric EQ with two
sets of bands, A and B.

- **Band types:** low and high cut (12, 24, 36, 48 or 96 dB an octave,
  Butterworth, the steepest section carrying the band's Q), low and high
  shelf, bell, notch, band-pass (0 dB at its peak) and tilt (first order,
  half its gain each way). `pro_eq_band_param(set, band, field)` gives a
  band setting's id.
- **The filters:** every section is designed to match its analog shape's
  magnitude at DC, Nyquist and the band's frequency (a matched
  second-order design), so a bell at 16 kHz keeps its width. Each runs as
  a state-variable filter with the same response, which stays well
  behaved while its settings move.
- **Modes:** Stereo (A on both sides), L/R (A the left, B the right) and
  M/S (A the mid, B the side).
- **Adaptive Q** narrows a bell as its gain grows; **Scale** multiplies
  every shelf's, bell's and tilt's gain (−2 to 2); **Gain** is the
  output.
- **Timing:** settings move on a 16-frame grid counted from the reset,
  smoothed over 12 ms, so the output is the same at any block size with
  no latency. Before the first grid point they jump.
- **Oversampling** (`Pro_Eq_Settings.oversample`, 2×) is chosen when the
  node is made: it makes the node 31 frames late, and a graph reads a
  node's latency only as it builds.
- **For drawing it:** `pro_eq_curve` gives a set's response (or one
  band's) at the frequencies you ask, designed as the node designs it;
  `pro_eq_read_input` the last frames it took in, for a spectrum;
  `pro_eq_readout` its peaks. `pro_eq_audition` makes it play only what
  one band touches.

```odin
node, eq, _ := fx.pro_eq_create({})
graph.add_node(g, node, 2, 2)
graph.set_param(g, id, fx.pro_eq_band_param(0, 2, .Freq_Hz), 300)
graph.set_param(g, id, fx.pro_eq_band_param(0, 2, .Gain_Db), -4)
```

One stereo instance with all eight bands on (48 dB cuts at both ends)
takes 0.66 % of a core on an Apple-silicon Mac at `-o:speed`, 1.8 %
oversampled.

## ProComp

`fx.pro_comp_create` (in `fire:fx`) is a clean compressor:
feed-forward, stereo-linked.

- **Detection:** Peak, RMS (10 ms) or Expand (a downward expander:
  below the threshold, down by the ratio).
- **The curve:** Threshold, Ratio (1:1 to ∞:1, `PC_RATIO_INF`; in Expand
  ∞ is a gate) and a quadratic Knee. `pro_comp_curve` gives it for
  drawing.
- **The envelope:** Attack and Release on the gain reduction, in dB (Log)
  or linear gain (Lin). In Expand, Attack is the opening. **Auto** release
  blends a quick release after a short peak with a slow one after a long
  squeeze.
- **Lookahead** (`Pro_Comp_Settings.lookahead`: 0, 1 or 10 ms) delays the
  sound so the detector hears it early; the node reports it as its
  latency.
- **Makeup** raises the compressed signal by what the curve takes off a
  full-scale level. Then Output and Dry/Wet.
- **The key:** added with four inputs and `PC_PARAM_KEYED` set, inputs 3
  and 4 are its key, mixed with its own input by Key Mix, through Key
  Gain and an EQ (low-pass, band-pass, high-pass, notch, peak, shelves).
  `PC_PARAM_LISTEN` puts out what the detector hears.
- **For drawing it:** `pro_comp_readout` (the levels in and out, the
  detector's level, the reduction) and `pro_comp_history` (the last 1024
  moments of 256 frames: peaks in and out, the deepest reduction), from
  any thread.

```odin
node, pc := fx.pro_comp_create({lookahead = .Ms_1})
graph.add_node(g, node, 2, 2)
graph.set_param(g, id, fx.PC_PARAM_THRESHOLD_DB, -24)
graph.set_param(g, id, fx.PC_PARAM_RATIO, 4)
```

One stereo instance takes 0.2 to 0.35 % of a core on an Apple-silicon Mac
at `-o:speed`.

## ProSaturator

`fx.pro_saturator_create` (in `fire:fx`) is a waveshaping saturator.

- **Curves:** Analog Clip, Soft Sine, Bass Shaper, Medium Curve, Hard
  Curve, Sinoid Fold, Digital Clip, Tube (asymmetric: even harmonics),
  Tape (soft, its treble falling as it is driven) and the Waveshaper
  (Drive, Lin, Curve, Damp, Depth, Period). Every curve but the
  Waveshaper passes a quiet signal at its level.
- **Drive** into the curve (±36 dB); **Color**, an EQ before it (a low
  shelf, Base, and a bell, Freq, Width, Depth) and its opposite after, so
  it changes which frequencies saturate; **DC** (a 10 Hz high-pass);
  Output, Dry/Wet; **Soft Clip** at the end.
- **Quality** (`Pro_Saturator_Settings.quality`: Off, 2×, 4×)
  oversamples the curve; the node reports the latency.
- **For drawing it:** `pro_saturator_curve` (the curve at the settings,
  steepening with Drive), `pro_saturator_color_response`,
  `pro_saturator_readout` (the peaks), `pro_saturator_signal` (what went
  into the curve, a point every 8 frames) and `pro_saturator_read_taps`
  (its input and output, for the harmonics), from any thread.

```odin
node, ps, _ := fx.pro_saturator_create({quality = .X2})
graph.add_node(g, node, 2, 2)
graph.set_param(g, id, fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Tube))
graph.set_param(g, id, fx.PS_PARAM_DRIVE_DB, 9)
```

One stereo instance takes 0.2 to 0.5 % of a core on an Apple-silicon Mac
at `-o:speed`, up to 1.7 % at 4×.

## ProVerb

`fx.proverb_create` (in `fire:fx`) is an algorithmic room reverb: a
predelay, an early section (a pattern of taps, each side its own, into
two short diffusers) and a late feedback delay network (4, 8 or 16 lines
as Quality says, mixed by a Householder matrix, every line modulated).

- **Decay** (0.1–100 s) is the middle's RT60; below Bass Xover the tail
  lasts Decay × Bass Mult, above High Xover Decay × High Mult (a shelf of
  each in every line's loop). `proverb_rt60` gives the decay at any
  frequency, as the node sets it.
- **The early section:** Early Size (its span, about 6 to 95 ms), Early
  Cross, Early Mod Rate and Depth, Early Send (into the late tail).
- **The late tail:** Late Size (its first arrival, about 6 to 57 ms),
  Late Cross, Late Mod Rate and Depth (a pitch deviation: the smear
  doesn't grow with the rate), Diffusion.
- **Depth** sets early against late (equal power), **High Cut** filters
  the wet, **Mix** sets the wet against the dry (no latency).
- **Modes:** twelve, each a structure of its own, tuned against
  measurements of a reference reverb (`scripts/proverb_probe`: its output
  rendered and measured as a black box).
- **Quality** (`Proverb_Settings.quality`): Eco (4 lines), Normal (8),
  High (16).
- **For drawing it:** `proverb_readout` (the peaks, the tail's level),
  `proverb_read_wet` (the wet, for a picture of the tail),
  `proverb_early_taps` (the early pattern), `proverb_rt60`.

```odin
node, pv, _ := fx.proverb_create({quality = .Normal})
graph.add_node(g, node, 2, 2)
graph.set_param(g, id, fx.PV_PARAM_DECAY_S, 3)
graph.set_param(g, id, fx.PV_PARAM_MIX, 1) // (on a send: all wet)
```

One stereo instance takes 0.6 % of a core (Eco), 1 % (Normal) and 1.8 %
(High) on an Apple-silicon Mac at `-o:speed`.

## Switching effects in and out

`wet_create(inner)` wraps any effect node with a dry/wet mix,
`WET_PARAM_MIX` (0 the input untouched, 1 the effect alone), faded over
15 ms on its exact frame, so an effect switches in and out without a
click. Every other parameter goes to the effect, and its parameter table
is the effect's plus the mix. Fully dry, the effect isn't run at all; it is
reset when switched back in, so it starts clean (no old echoes). The dry
signal is delayed by the effect's latency (a limiter's lookahead,
SuperFilter's 32 frames, a plug-in's), so a late effect fades in and out
without combing and stays in time switched off.

```odin
node := dsp.wet_create(dsp.reverb_create(), mix = 0) // in the graph, off
graph.set_param(g, id, dsp.WET_PARAM_MIX, 1)         // on, smoothly
graph.set_param(g, id, dsp.REVERB_PARAM_DECAY_S, 4)  // the reverb's own
```

## Metering and panning

- `meter_create()` passes audio through and returns a handle: `meter_read`
  gives each channel's peak and RMS since the last read, from any thread,
  for level meters.
- `loudness_create()` measures loudness as EBU R128 has it (ITU-R
  BS.1770: K-weighting, 100 ms blocks): `loudness_read` gives the
  momentary (400 ms), short-term (3 s) and integrated loudness in LUFS
  (gated: under -70 LUFS left out, then what is 10 LU under the rest) and
  the true peak (4× oversampled) since `loudness_reset`. A stereo 1 kHz
  sine at -23 dBFS reads -23 LUFS.
- `stereo_create()` measures the stereo image: `stereo_correlation` (-1
  to +1, over about 300 ms) and `stereo_points`, the latest left/right
  pairs (every 4th frame) for a goniometer.
- `pan_create()` is an equal-power stereo balance (`PAN_PARAM_POSITION`,
  -1..1): unity in the centre, so a centred pan passes audio unchanged.

## See also

- [`fire:dsp` reference](/reference/dsp/)
- [Writing a node](/guides/writing-a-node/): using the primitives in your own nodes
