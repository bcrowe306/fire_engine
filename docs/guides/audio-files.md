---
title: Audio files and sample rates
description: Read WAV, AIFF, FLAC, MP3 and Ogg Vorbis; write crash-safe WAV and AIFF; stream from disk with instant cue jumps; convert sample rates and play at any speed.
---

Three packages cover files and rate conversion:

- `fire:audiofile` reads and writes WAV and AIFF. It is pure Odin, with no C
  code.
- `fire:audiofile/codecs` adds FLAC, MP3 and Ogg Vorbis decoding, using
  `vendor:miniaudio`, which ships with Odin.
- `dsp.Resampler` changes sample rate and plays at any speed.

`examples/audio_files` uses all three.

## Reading

```odin
r, err := codecs.open("loop.flac") // or audiofile.open for WAV/AIFF only
if err != .None do return
defer audiofile.close(r)

info := audiofile.info(r) // format, encoding, sample_rate, channels, frames
left := make([]f32, 4096)
right := make([]f32, 4096)
n, _ := audiofile.read(r, {left, right}, 4096) // planar f32, -1..1
audiofile.seek(r, 48_000)                      // sample-exact, any format
```

- `codecs.open` recognises a file by its first bytes, not by its extension.
- Reading never allocates: the reader's buffers are made when it opens. It
  does block on the disk, so read on a background thread, never the audio
  thread. Clip streaming does this for you.
- MP3 and Ogg decode gaplessly: encoder delay and padding are removed, so
  loops stay seamless.

**Supported:**

| Format | Read | Write |
|--------|------|-------|
| WAV, RF64/BW64, WAVE_FORMAT_EXTENSIBLE | 8-bit unsigned, 16/24/32-bit int, 32/64-bit float | 16/24/32-bit int, 32/64-bit float |
| AIFF / AIFC | 8/16/24/32-bit int (big- or little-endian), 32/64-bit float | 16/24/32-bit int, 32/64-bit float |
| FLAC, MP3, Ogg Vorbis | yes (`codecs`) | no |

On Linux, build Odin's miniaudio once before using `codecs`. It comes
prebuilt on macOS and Windows:

```bash
"$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"
```

## Writing (and recording)

```odin
settings := audiofile.default_writer_settings(48_000, 2) // 24-bit WAV
w, err := audiofile.writer_create("take.wav", settings)
audiofile.writer_write(w, {left, right}, frames) // repeatedly, from a disk thread
audiofile.writer_close(w)
```

Writers are built for long recordings:

- **Crash-safe.** The header is rewritten every `header_interval` frames
  (one second by default). If the app dies mid-take, the file still opens.
  The reader also recovers audio written after the last header update and
  sets `info.recovered`.
- **No 4 GB limit for WAV.** A WAV grows into RF64 in place when it passes
  4 GB. AIFF can't, so its writer returns `.Too_Large` at the limit.
- **Dither:** 16-bit output gets TPDF dither unless `dither` is off. Integer
  encodings clip at full scale.

## Streaming from disk

Audio threads must never touch the disk. `fire:stream` reads ahead on
background threads, so the audio thread just copies:

```odin
settings := stream.default_settings()
settings.open = codecs.open // to stream FLAC, MP3 and Ogg as well
s, _ := stream.create(settings)
defer stream.destroy(s)

src, _ := stream.source_open(s, "song.flac") // shared: same path, same source
defer stream.source_release(src)
st, _ := stream.stream_create(s, src, cues = {0, loop_start})
defer stream.stream_destroy(st)

// Control thread, before a quantized launch: wait for stream.stream_ready(st).

// Audio thread:
stream.stream_read(st, out, frames) // planar f32 at the file's sample rate
stream.stream_seek(st, loop_start)  // a cue: plays on from memory at once
```

- **Small files load into memory.** Files that decode to at most
  `ram_bytes` (16 MB by default, about 45 s of stereo at 48 kHz) are
  decoded once in the background and shared by every stream that plays
  them.
- **Longer files are streamed.** Each stream keeps `buffer_seconds` read
  ahead. The disk threads serve whichever stream has the least buffered.
- **Cues** are the positions a stream jumps to: a clip's start and loop
  start, slice points. Each has `cue_seconds` decoded in memory, so a jump
  is instant while the disk refills from after the cue. A jump anywhere else
  plays silence until the data arrives.
- **The audio thread never waits.** Missing data plays as silence and is
  counted (`stream_underruns`, `stats`). `stream_ready` tells the control
  thread when a stream can start without a dropout.
- **Offline renders wait instead.** A bounce runs as fast as the CPU allows,
  far ahead of the disk. Call `stream.set_offline(streamer, true)` first: then
  `stream_read` waits for missing data rather than playing silence (up to
  `stream.OFFLINE_TIMEOUT` per read, so a failing disk can't hang it). Turn it
  off again before playing live, since waiting on a device's audio thread
  would glitch.

## Converting sample rates

`dsp.Resampler` uses bandlimited interpolation. `speed` is input frames per
output frame:

- 44.1 → 48 kHz is `44_100.0 / 48_000`;
- an octave down in pitch is `0.5`.

The speed can change on every call, which is what varispeed and repitching
clips need.

```odin
rs: dsp.Resampler
dsp.resampler_init(&rs, channels = 2, quality = .Medium, max_speed = 4)
defer dsp.resampler_destroy(&rs)

// Pull style: read exactly what the next `frames` outputs need.
need := dsp.resampler_input_needed(&rs, frames, speed)
// ... fill `input` with `need` frames ...
dsp.resampler_process(&rs, input, output, speed) // realtime-safe
```

| Quality | Taps per sample (speed ≤ 1) | Flat to | Aliasing | Use for |
|---------|-----------------------------|---------|----------|---------|
| `.Low` | 32 | 0.75 × Nyquist | < −60 dB | previews, many voices on small machines |
| `.Medium` | 80 | 0.85 × Nyquist | < −90 dB | clip playback |
| `.High` | 160 | 0.90 × Nyquist | < −120 dB | offline conversion, bounces |

Output frame *k* is the input at time *k × speed* exactly, with no added
latency. The filter only needs to look ahead, which `resampler_input_needed`
accounts for. The output is bit-identical however you split the input.

## See also

- [`fire:stream`](/reference/stream/),
  [`fire:audiofile`](/reference/audiofile/),
  [`fire:audiofile/codecs`](/reference/audiofile/codecs/) and
  [`dsp.Resampler`](/reference/dsp/#resampler)
