# Audio recording, resampling and audio editing

Status: steps 1–3 (recording timing, drivers, sampler recording) built; the rest planned (decisions taken 2026-11-13).

## What there is now (surveyed)

- **Drivers.** Each platform's driver is fixed in the app layer:
  CoreAudio (macOS), WASAPI (Windows), ALSA (Linux). The engine also has
  **ASIO** and **JACK** backends (and the fake driver), but nothing chooses
  them. Settings > Audio lists one driver's devices (output, input,
  channels, rate, buffer).
- **CoreAudio with two devices** (a USB mic in, the built-in speakers out)
  is refused: `ca_open` returns `.Unsupported` ("separate devices need an
  aggregate device").
- **Recording into a sampler.** The circle on the Sample page (and the
  slicer's) records the first two inputs onto the pad, while it is on;
  the take replaces the pad's sample. The red dot on a pad is something
  else: an **audio track's record arm**.
- **Audio tracks** (a pad of kind Audio) record takes per sequence and
  play them with it; there is no clip editing (one take a sequence).
- **Freeze** renders a pad through its chain; **Export** renders the
  mix, stems, or to a pad.
- **Timing: neither recording path compensates latency.** Both create
  their recorder (`record.audio_recorder_create`) without
  `latency_frames`, so every take lands late by the interface's round
  trip (often 5–15 ms). The engine has what it needs
  (`backend.round_trip_latency_frames`, the recorder's compensation, the
  latency probe); Pads doesn't pass it. This is the first fix.

## How production DAWs keep recording sample-accurate

1. **Sample counters, never the wall clock.** The take's first sample is
   tied to a frame of the engine's clock; its timeline position comes from
   that frame. Loop passes are cut at exact frames.
2. **Round-trip compensation.** A take is moved earlier by input latency
   + output latency (what the performer heard came out that much after
   the engine made it, and the input reached the engine that much after
   it was played). On CoreAudio: the device and stream latencies, the
   safety offsets and the buffer, best read from the callback's timestamps.
3. **A manual recording offset** for interfaces that misreport, measured
   once with a loopback cable (Logic, Cubase, Reaper all have one).
4. **Plug-in delay compensation** for anything recorded from inside the
   mix (resampling a track through its effects), as playback compensates.
5. **One clock, no resampling in the path.** Two devices are joined by an
   aggregate (the OS's drift correction), not by guessing; files are
   written at the device's rate.

## Decisions (asked, 2026-11-13)

1. **Drivers.** A **Driver** dropdown above the devices: Windows
   **WASAPI and ASIO**; Linux **ALSA and JACK**; macOS CoreAudio only
   (no dropdown). Different input and output devices on macOS: the engine
   makes a **private aggregate device** with drift correction, unseen.
2. **Recording into a sampler: all four ways, chosen in the toolbar**
   (a Sample control): **Hold** (Cmd/Ctrl-press a pad: records while held,
   the release stops), **Arm then press** (the next pad pressed records
   while held: hardware pads, no modifier), **Threshold** (starts when the
   input passes a level), **Bars** (playing: starts on the next bar,
   records a set number of bars, so it loops in time). Not an audio
   track's take: the sample becomes the pad's.
3. **Resampling and bouncing, all three:** a track's **audio in** can be
   another pad/track, a bus or **main** (recorded live, aligned after
   their effects' latency); **offline bounce** of pads, a selection or a
   bus to a new pad; **bounce in place** to an audio clip on an audio track
   (the source muted).
4. **Audio clips: edits non-destructive and destructive.** A clip is a
   region of a file plus settings (start/end, fades, gain, pan, reverse,
   warp); cut, crop, split and fades never touch the file; **Consolidate**
   and **Process** write new files.
5. **Seen in the Sequence view both ways:** a third **Audio** tab (a large
   waveform editor of the selected audio track's clips, with its tools),
   and in the Notes grid an audio track's row as a **vertically condensed
   waveform**.
6. **Tools, first version:** **cut, crop, trim, move, copy, paste**;
   **fades, gain, pan** (Normalize, reverse, silence); **warp and pitch**.
   **Takes** come with loop recording (below).
7. **Takes to several tracks (doubling):** both a record setting ("each
   pass to a new track") and a command after ("Spread takes to tracks"):
   pass 1 stays, passes 2..n go to the next empty audio tracks, lined up.
8. **Per-track loops (polymeter):** each track in a sequence can loop its
   own part, **any length** (3 beats in a 4/4 bar drifts against it),
   reset at the sequence's start; **audio tracks too** (the loop point
   exact to the sample); **recording into a looped track** records into
   its range (each pass overdubs notes, or is an audio take).
9. **Timing:** driver latency + a manual offset; **plug-in latency**
   compensated for what is recorded from the mix.
10. **Monitoring: per track, In / Auto / Off** (Auto: you hear the input
    while armed or recording), through its effects, compensated.
11. **Vertical zoom** in the Sequence view (asked): rows taller or
    shorter (Cmd/Ctrl+wheel, and a drag), so more or fewer rows show.

## What I think was missing (to settle as we go)

- **Retrospective capture:** keep the last N seconds of input always, so
  a sample can be taken from what was just played (a "Capture" command).
  Cheap with the ring the recorder has.
- **Punch in/out** on the bar ruler for audio tracks, with count-in and
  pre-roll (the transport has both for notes).
- **Crossfades at clip edges and loop points** (a few ms, automatic), and
  edits snapped to zero crossings optionally, so no clicks.
- **Takes' files:** where they go, unused ones cleaned up (a "Remove
  unused recordings" command), disk space warned about before it runs out.
- **Recording format:** 24-bit or 32-bit float (Settings > Recording),
  at the device rate; a file at another rate is converted on import.
- **Glitches while recording:** an xrun (a dropped buffer) marked on the
  take and reported, not silently a click; a device unplugged keeps what
  was recorded.
- **Feedback loops in routing:** a track recording main while main
  includes it, or two tracks taking each other: shown, and the cycle
  refused (the graph cannot run it).
- **Licences:** ASIO's SDK is GPLv3 (Steinberg, 2025) as Pads is; JACK is
  LGPL. To check before shipping.
- **Clip tempo:** an audio clip follows the tempo (warped) or stays as
  recorded; tempo changes while recording are honoured by the take's
  start frame, not its beat count.

## The engine's part

- **Drivers.** `app:core` takes a driver choice (`Host_Settings.driver`):
  the platform's list (`host_drivers`), opened by name; device lists per
  driver. ASIO: one device at a time, its own buffer and rate (its control
  panel); JACK: its server's rate and buffer.
- **CoreAudio aggregate.** `fire:backend/coreaudio` creates a private
  aggregate (`AudioHardwareCreateAggregateDevice`, private, the output's
  clock the master, drift correction on the input) when in and out
  differ, and destroys it on close; its latencies are the sum the
  aggregate reports. Tested with the fake driver's two devices and, on a
  Mac, a USB device plus the built-in output.
- **Latency.** Every recorder gets the round trip (+ the manual offset);
  resampling taps get the graph's latency to their point. A test records
  a click through a loopback (fake, snd-aloop on Linux, BlackHole/VB-CABLE)
  and requires it land within a frame.
- **Taps.** A node anywhere in the mixer can feed a recorder (a pad's
  output, a bus, main) with its latency known: what resampling uses.
- **Per-track loops** in the plan: a track's segment repeats its own
  range inside the sequence's (notes and audio), on the sample.

## Order of work

1. **Recording timing** (built): both recorders take the round trip plus
   a recording offset (Settings > Recording > Timing, frames), set again
   at each take; live hits recorded earlier by the output latency; the
   simulated driver's latencies and loopback (`Host_Settings.fake_latency`,
   `fake_loopback`) for tests that run a cabled device and require takes
   and hits on their frame. (Plug-in latency for taps comes with taps, in
   step 4.)
2. **Drivers** (built): `app.host_drivers` / `Host_Settings.driver` /
   `host_set_driver`; the Driver dropdown in Settings > Audio (Windows,
   Linux), saved; a private CoreAudio aggregate when the input and output
   devices differ (tested opening BlackHole in and another device out).
3. **Sampler recording** (built): the toolbar's Sample control (Hold:
   Option/Alt-press, asked after Cmd-click turned out to select; Arm;
   Threshold: the start marker 5 ms before the level; Bars: a timeline
   recorder punched from the next bar), the pad's own input, `REC` on the
   pad, MIDI presses too; the recorder made ready for the selected pad
   ahead (one made at the press would lose the round trip of history);
   monitoring per audio track Auto / In / Off (project file v34).
4. **Resampling and bounces**: track inputs from pads, buses, main; offline
   bounce to a pad; bounce in place.
5. **Audio clips in the Sequence view**: the clip model (non-destructive),
   the Audio tab and the condensed rows, the tools, takes, takes to
   tracks, Consolidate.
6. **Per-track loops** (notes and audio, recording into them).
7. **Vertical zoom** in the Sequence view.

Each step: model tests, e2e tests, a drive script with screenshots, the
guides, then cloud tests (the timing step on every machine).
