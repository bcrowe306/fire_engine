---
title: Instruments
description: A polyphonic, MPE-aware synth node, and the oscillators, envelopes and noise it is built from.
---

`fire:dsp` has instruments as nodes that play the notes they receive,
and as the primitives they are made of.

`examples/clip_launcher` and `examples/arrangement` play their MIDI clips
through `synth_create`.

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
- [`fire:dsp` reference](/reference/dsp/)
