---
title: Audio devices
description: Opening an audio device on any platform, running a callback, and handling device events.
---

[`fire:backend`](/reference/backend/) gives one API over each platform's audio
system. A *driver* talks to the OS; a `Device` (the shared layer) turns
whatever the OS hands over into planar `f32` blocks of at most `max_block`
frames for your callback.

| Platform | Driver | Create |
|----------|--------|--------|
| macOS | CoreAudio | `coreaudio.create()` |
| Linux | ALSA | `alsa.create()` |
| Linux | JACK (if installed) | `jack.create(jack.default_options())` |
| Windows | WASAPI (shared mode) | `wasapi.create()` |
| Any | Simulated, for tests and headless runs | `fake.driver(fake.create(fake.default_config()))` |

Driver packages exist only on their platform, so import them from files with
build tags (`#+build darwin` and so on). `examples/play_device` shows the
pattern.

## Open, start, stop

```odin
dev: backend.Device
backend.device_init(&dev, driver)
defer backend.device_destroy(&dev)

// The default device, stereo out, its current rate and buffer size.
if err := backend.device_open(&dev, {output_channels = {0, 1}}, 512); err != .None {
	// .Unsupported: the device can't do what was asked
}
fmt.println(dev.format.sample_rate, dev.format.buffer_frames)

callback := backend.Device_Callback{process = my_process, user = my_state}
backend.device_start(&dev, callback)
// ... later
backend.device_stop(&dev) // no callback runs after this returns
```

- `Device_Setup` picks devices by ID (from `backend.driver_enumerate`; empty
  means the default), channels as bit sets, and optionally a sample rate and
  buffer size. CoreAudio changes the device's rate if asked; WASAPI shared mode
  and JACK report `.Unsupported` instead of resampling.
- Your callback receives an `Io_Block`: `inputs` and `outputs` (planar, only
  the channels you selected), `frames`, and timestamps on the host clock
  (`rt.host_time_ns`): `input_ns` (when the first input frame was captured)
  and `output_ns` (when the first output frame will be heard).
- The callback runs on the audio thread: no allocation, locks or system
  calls. The layer installs a nil allocator there, so a stray allocation fails
  instead of reaching the heap.

## Device events

Poll on your control thread:

```odin
for e in backend.device_poll_event(&dev) {
	switch e.kind {
	case .Device_Lost:            // unplugged: stop and close, then reopen another
	case .Devices_Changed:        // re-enumerate
	case .Default_Device_Changed: // the user picked a new default
	case .Format_Changed:         // reopen to follow the new rate
	case .Xrun:                   // e.count dropouts since the last poll
	case .Error:
	}
}
```

The engine never tears a device down by itself: you decide what to do.
`backend.device_stats` reports callbacks, xruns and CPU load (load 1.0 = the
whole block's time spent in your callback), and the round trip the
timestamps imply (`round_trip_frames`). For recording, use
`backend.round_trip_latency_frames(&dev)` once the device runs, or measure
it: see [Recording](/guides/recording/#latency).

## See also

- [`fire:backend` reference](/reference/backend/) and each driver's page
- [Design: backends](/design/backend/), for how each OS is driven and tested
