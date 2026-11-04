---
title: Fire Engine
description: A realtime audio engine library in Odin — devices, MIDI, a multithreaded audio graph, DSP and a test kit — for everything from embedded boxes to full DAWs.
---

Fire Engine is a realtime audio engine written in [Odin](https://odin-lang.org).
It is a library: you build your application (a plugin host, an instrument, a
DAW, a headless box on a single-board computer) on top of its packages.

## Packages

| Package | What it is |
|---------|------------|
| [`fire:core`](/reference/core/) | Shared types: nodes, events, parameters, transport, errors |
| [`fire:graph`](/reference/graph/) | The audio graph: nodes and connections, processed on many threads |
| [`fire:transport`](/reference/transport/) | The musical clock: tempo, bars, and timelines for arrangements, clips, loopers and sequencers; MIDI clock out |
| [`fire:link`](/reference/link/) | Optional [Ableton Link](https://www.ableton.com/link/) sync (GPLv2+; built separately) |
| [`fire:dsp`](/reference/dsp/) | DSP primitives and effect nodes: filters and parametric EQ, compressor, gate, limiter, delay, chorus, flanger, phaser, reverb, convolution, oversampled saturation, LFOs; a polyphonic synth with oscillators, envelopes and noise; gain, smoothing, resampling, FFT |
| [`fire:audiofile`](/reference/audiofile/) | Read and write WAV and AIFF; [FLAC, MP3 and Ogg](/reference/audiofile/codecs/) decoding |
| [`fire:clip`](/reference/clip/) | Clips on timelines: MIDI clips with per-note expression, tempo-following audio clips, parameter automation, players for launchers and arrangements, MIDI files |
| [`fire:record`](/reference/record/) | Recording: audio takes to disk, MIDI and automation recording, overdub and loop recording, latency compensation and measurement |
| [`fire:sampler`](/reference/sampler/) | A sampler: multi-sample instruments with key and velocity zones, loops and one-shots, band-limited pitch-shifting |
| [`fire:stretch`](/reference/stretch/) | Time-stretching for audio clips: Signalsmith Stretch, ported to Odin |
| [`fire:stream`](/reference/stream/) | Disk streaming: files read ahead on background threads, instant jumps to cue points |
| [`fire:backend`](/reference/backend/) | Audio devices: one API over [CoreAudio](/reference/backend/coreaudio/), [ALSA](/reference/backend/alsa/), [JACK](/reference/backend/jack/), [WASAPI](/reference/backend/wasapi/) and a [simulated driver](/reference/backend/fake/) |
| [`fire:midi`](/reference/midi/) | MIDI input and output: one API over [CoreMIDI](/reference/midi/coremidi/), the [ALSA sequencer](/reference/midi/alsa/) and [WinMM](/reference/midi/winmm/) |
| [`fire:timebase`](/reference/timebase/) | Samples, seconds, beats, ticks, bars; tempo maps |
| [`fire:rt`](/reference/rt/) | Realtime utilities: lock-free queues, flush-to-zero, thread priority, the host clock |
| [`fire:testkit`](/reference/testkit/) | Testing your own nodes: render without a device, trap allocations, analyse audio |

## Where to start

1. [Getting started](/guides/getting-started/): build setup and a first program.
2. [The audio graph](/guides/graph/): how to connect nodes and run them.
3. [Tempo and timelines](/guides/transport/): the clock, playing, looping and quantized launching.
   Then [clips](/guides/clips/): MIDI and audio that play on them, and
   [recording](/guides/recording/) them.
4. [Audio devices](/guides/devices/) and [MIDI](/guides/midi/): talking to hardware.
5. [Audio files and sample rates](/guides/audio-files/): reading, writing, recording, resampling.
6. [Effects](/guides/effects/): the filters, EQ, dynamics, delay, modulation, reverb and convolution in `fire:dsp`.
   And [instruments](/guides/instruments/): the synth and the sampler.
7. [Writing a node](/guides/writing-a-node/): your own DSP, and testing it.

The [design notes](/design/graph/) explain how the engine works inside and why.

## Rules that hold everywhere

- **The audio thread never allocates, locks or blocks.** Procedures safe to
  call there are marked *Realtime-safe* in the reference.
- **Everything else happens on a control thread** (your main or UI thread):
  creating things, editing the graph, opening devices.
- **Audio is planar `f32`**: one `[]f32` per channel. Blocks may be any size
  from 0 up to the `max_block` you prepared for.
