---
title: Instruments
description: A polyphonic, MPE-aware synth and a multi-sample sampler, and the oscillators, envelopes and noise they are built from.
---

`fire:dsp` has instruments as nodes that play the notes they receive,
and as the primitives they are made of.

`examples/clip_launcher` and `examples/arrangement` play their MIDI clips
through the synth; `examples/sampler` plays a drum kit and a pluck from
generated samples.

## The synth

`synth_create(voices)` is a polyphonic subtractive synth. Each voice is two
band-limited oscillators, mixed into a resonant lowpass with its own
envelope and key tracking, and an amp envelope with velocity. Connect
notes into it: a clip player, the device's MIDI input, or anything that
sends `core.Note_On` and `core.Note_Off`.

```odin
synth, _ := graph.add_node(g, dsp.synth_create(16), 0, 2) // no audio in, stereo out
graph.connect_events(g, player, synth)                    // a MIDI clip player
graph.set_param(g, synth, dsp.SYNTH_PARAM_OSC1_SHAPE, f64(dsp.Osc_Shape.Saw))
graph.set_param(g, synth, dsp.SYNTH_PARAM_CUTOFF_HZ, 800)
graph.set_param(g, synth, dsp.SYNTH_PARAM_FILTER_ENV, 4)  // the envelope opens it 4 octaves
graph.set_param(g, synth, dsp.SYNTH_PARAM_AMP_SUSTAIN, 0) // plucked
```

- **Per-note expression** (MPE, MIDI 2.0, or `clip.add_expression`)
  moves one note without the others: `Tuning` bends it (in semitones),
  `Volume` and `Pan` place it, `Vibrato` adds a 5.5 Hz wobble of up to
  half a semitone, and `Brightness` and `Pressure` open its filter.
- **Voices.** A note matches the voice playing it by note id, or by
  channel and key when it has none. When every voice is busy, a new note
  takes the quietest voice that is releasing, or else the oldest note's,
  keeping its level so the envelope rises without a click.
- **Parameters** are the `SYNTH_PARAM_*` ids: oscillator shapes, detune
  and mix, cutoff, resonance, filter envelope reach and key tracking, both
  envelopes, velocity sensitivity, pulse width and gain. Envelope and
  shape changes apply to notes already sounding too.
- Cost on an Apple M1: about 26 ns per voice per frame, so 16 sounding
  voices are 2% of a 512-frame block.

## The sampler

`fire:sampler` plays recorded sounds. A `Sample_Map` is the instrument: a
list of zones, each a sample with the keys and velocities it answers.

```odin
kit, _ := sampler.sample_map_create({
	{source = kick, root_key = 36, key_lo = 36, key_hi = 36, one_shot = true},
	{source = piano_soft, root_key = 60, key_lo = 48, key_hi = 72, vel_hi = 0.6},
	{source = piano_hard, root_key = 60, key_lo = 48, key_hi = 72, vel_lo = 0.6001},
	{source = pad, root_key = 48, loop = true, loop_start = 12_000, loop_end = 96_000},
})
node, s := sampler.sampler_create({voices = 32})
id, _ := graph.add_node(g, node, 0, 2)
sampler.sampler_set_map(s, kit)
sampler.sample_map_release(kit) // the sampler keeps its own reference
```

- **Zones.** A note plays every zone whose key and velocity ranges hold
  it (so zones can be layered), pitched from the zone's `root_key`, with
  its `tune_cents` and `gain_db`. Unset ranges mean every key and every
  velocity.
- **Loops** are sustain loops: the sample plays from `start`, loops
  between `loop_start` and `loop_end` for as long as the note sounds
  (through its release too), and stops at `end` otherwise. A `one_shot`
  zone plays to its end whatever the note-off: drums. `loop_mode` is
  `Forward` or `Ping_Pong` (back and forth, the turning points played
  once), and `crossfade` (in frames, forward loops) blends the end of the
  loop into the audio before its start, so a loop with no zero crossing to
  cut at doesn't click.
- **Reverse and pan.** A `reverse` zone plays its region backwards (from
  `end` to `start`, loops mirrored); `pan` places it (−1..1, equal power),
  until a pan expression for the note replaces it.
- **Choke groups.** A `core.Note_Choke` event silences the notes on its
  channel (and key, unless `key < 0`) within `sampler.CHOKE_SECONDS`
  (3 ms), with no release: an open hi-hat cut by the closed one. The
  synth and CLAP plug-ins (`CLAP_EVENT_NOTE_CHOKE`) take it too.
- **Samples are held in memory.** The streamer decodes files up to its
  `ram_bytes` (16 MB by default) into memory when they're opened; wait
  for `stream.source_state` to be `Ready`. Larger files play silent.
- **Changing instruments.** `sampler_set_map` swaps maps at the next
  block. Notes already sounding finish on the old map, which is released
  once they have.
- **Expression and parameters:** per-note tuning, volume and pan; an amp
  ADSR, velocity sensitivity, transpose and gain (`SAMPLER_PARAM_*`).

**Finding the hits.** `dsp.detect_onsets` returns where new sounds start
in a sample (spectral flux against a running median, each onset moved back
to where its attack begins), for chopping a loop into slices:

```odin
hits, _ := dsp.detect_onsets(mono, 48_000, {sensitivity = 0.6})
defer delete(hits)
```

It runs on the control thread: about 75 ms for 30 seconds of audio.

Sample maps save as version 2 (the zone fields above); version 1 maps load
with their defaults.

**Quality.** `Sampler_Settings.quality` picks how a voice reads between
frames when it plays a sample at another pitch:

| `Sampler_Quality` | Method | Aliasing (6 kHz sample, up 5 semitones) | 32 voices, 512 frames (M1) |
|---|---|---|---|
| `Cubic` (default) | 4-point Hermite | −44 dB | 0.21 ms (1.9%) |
| `Sinc_Low` | `dsp.Resampler`, band-limited | −84 dB | 1.1 ms (10%) |
| `Sinc_Medium` | | −87 dB | 2.5 ms (23%) |
| `Sinc_High` | | −87 dB | 4.9 ms (46%) |

Cubic is fine for most material, and for anything played near its root
key; use a sinc mode for bright samples pitched far up, or for rendering.

## Oscillators, envelopes and noise

- **`Oscillator`**: sine, saw, square, triangle and pulse, from −1 to 1.
  Saw, square and pulse are band-limited with polyBLEP (Välimäki and
  Huovilainen, 2007): every jump is smoothed over two samples, which cuts
  aliasing by about 15 dB against a naive waveform (measured: −35 dB at
  440 Hz, −24 dB at 3.5 kHz). The triangle is the band-limited square,
  integrated.
- **`Adsr`**: a linear attack to 1 in `attack_s`, then exponential moves
  to the sustain level and, on release, to silence, each within 60 dB of
  its goal in its time. Gating on again rises from the current level.
- **`Noise`**: white (uniform) and pink (Paul Kellet's filter, −3 dB per
  octave).

```odin
o := dsp.Oscillator{shape = .Saw}
dsp.osc_set_freq(&o, 220, sample_rate)
env: dsp.Adsr
dsp.adsr_set(&env, 0.01, 0.2, 0.6, 0.5, sample_rate) // attack, decay, sustain, release
dsp.adsr_gate(&env, true)
for &x in out do x = f32(dsp.osc_next(&o) * dsp.adsr_next(&env))
```

## See also

- [Effects](/guides/effects/): filters, dynamics, delay, reverb
- [Clips](/guides/clips/): the notes that play them
- [`fire:dsp` reference](/reference/dsp/), [`fire:sampler` reference](/reference/sampler/)
