# Audio & MIDI backends

Status: shared API, fake driver and CoreAudio driver implemented (macOS 11+).
CoreMIDI is next, then WASAPI, ALSA, JACK, ASIO.

## Decisions

| Topic | Decision |
|-------|----------|
| Devices | One duplex device at a time. Input and output may name different device IDs only if the driver can run them on one clock (WASAPI endpoints of one card); otherwise `open` returns `.Unsupported`. Multi-device drift compensation is future work behind the same API. |
| Drivers | Native only. Order: fake → CoreAudio/CoreMIDI → WASAPI/Windows MIDI → ALSA → JACK → ASIO. |
| Bindings | Raw foreign imports live in `fire:sys/<api>` (no logic). Drivers in `fire:backend/<name>` use them. Odin's `vendor:windows/wasapi` and `core:sys/windows` (WinMM) are reused. |
| Callback | The application hands the device one `Device_Callback`. It always sees planar f32, `0 < frames ≤ max_block`, and timestamps. The graph will plug in here. |
| Device events | Hot-plug, device loss, format changes and xruns are polled on the control thread with `device_poll_event`. No application code runs on OS threads. |
| MIDI | MIDI 1.0 bytes (`core.Midi_Raw`) plus native note events. Port/event types leave room for UMP. Virtual ports where the OS supports them. |

## Layers

```
  application / graph
        │  Device_Callback.process(user, ^Io_Block)      planar f32, ≤ max_block
  ┌─────┴──────────────────────────────────────────────┐
  │ fire:backend  (Device: the shared layer)           │
  │  • channel selection (Channel_Mask), silence on    │
  │    unselected outputs                              │
  │  • native format ⇄ f32 (f32, f64, i16, i24, i32,   │
  │    i24-in-32), any interleaving                    │
  │  • split driver buffers into ≤ max_block chunks    │
  │    (zero added latency)                            │
  │  • FTZ/DAZ, rt context allocator, timing, xruns    │
  │  • event queue for the control thread              │
  └─────┬──────────────────────────────────────────────┘
        │  driver_process(dev, ^Driver_Buffers)    [rt], any frame count
        │  driver_notify(dev, Device_Event)        driver notification thread
  ┌─────┴──────────┐
  │ Driver vtable  │  fake · coreaudio · wasapi · alsa · jack · asio
  └────────────────┘
```

### Driver contract

A driver is a thin wrapper over one OS API. It implements `Driver_VTable`:

- `enumerate` lists devices (`Device_Info`: stable ID, name, channel counts,
  supported rates and buffer sizes, defaults).
- `open` negotiates a `Device_Setup` and reports what it got (`Device_Format`),
  including `max_driver_frames`, the most frames one OS callback can deliver.
- `start` begins calling `driver_process` from the OS audio thread.
- `stop` must not return while a `driver_process` call is in flight, and must
  guarantee none starts afterwards.
- `close` releases the OS device.

`Driver_Buffers` describes the OS buffers without copying. Each direction is a
list of `Driver_Plane{data, channels}`: a plane holds `channels` interleaved
channels. This one shape covers CoreAudio's `AudioBufferList`, a WASAPI buffer
(one plane, N channels), ASIO (N planes, one channel each), and ALSA
interleaved or non-interleaved. Device channel `k` is the `k`th channel when
counting through the planes in order.

Drivers report discontinuities by setting `Driver_Buffers.xrun`. They post
non-realtime events (`Devices_Changed`, `Device_Lost`, `Format_Changed`) with
`driver_notify` from their own notification thread.

### Callback contract

```odin
Device_Callback :: struct {
	prepare: proc(user: rawptr, cfg: core.Prepare_Config) -> core.Error, // control thread
	process: proc(user: rawptr, block: ^Io_Block),                       // [rt]
	release: proc(user: rawptr),                                         // control thread
	user:    rawptr,
}
```

`Io_Block` carries `inputs`/`outputs` (planar f32, only the selected channels,
in ascending device-channel order), `frames`, `sample_time` (frames since
start, counting across chunks), `sample_rate`, the host-clock timestamps
`callback_ns`, `input_ns` (capture time of the first input frame) and `output_ns`
(presentation time of the first output frame), and `xrun` (a discontinuity
happened just before this block).

Chunks inside one driver callback share `callback_ns`; `input_ns`/`output_ns`
advance by `frames / sample_rate`. All timestamps use `backend.host_time_ns()`,
the same clock MIDI timestamps will be converted to.

### Threads and memory

- Inside `driver_process`, the context's `allocator` and `temp_allocator` are
  `Device.rt_allocator` (a nil allocator by default; tests install
  `testkit.trap_allocator`). FTZ/DAZ is set on entry and restored on exit,
  because the OS owns the thread.
- `Device_Stats` (callbacks, frames, xruns, overloads, last/peak load) are
  atomics written only by the audio thread.
- Device events from the audio thread (xruns) are counters; the poll turns
  them into `Xrun` events. Events from driver notification threads go through a
  small mutex-guarded ring, which is fine because those threads are not
  realtime.
- Realtime priority: CoreAudio, WASAPI (MMCSS) and ASIO threads arrive with it.
  Drivers that create their own threads (ALSA, JACK, fake in threaded mode) will
  call `rt.set_realtime_priority` (to be added with the ALSA driver).

### Lifecycle

```
device_init → device_open(setup, max_block) → device_start(callback) → device_stop → device_close → device_destroy
                     ↑                                                   │
                     └──────────── reopen on Format_Changed / device change ┘
```

`device_start` calls `callback.prepare` first. If it fails, the driver is not
started. `device_stop` stops the driver first, then calls `callback.release`.
On `Device_Lost` the application calls `device_stop` and `device_close` from
the control thread; the layer never tears itself down.

## CoreAudio (`fire:backend/coreaudio`)

- HAL `AudioDeviceIOProc` on the device itself. IOProc buffers are canonical
  f32, one `AudioBuffer` per stream, which become one plane each.
- Opening at a different rate or buffer size changes the device (system-wide)
  and leaves it changed. The rate change is asynchronous, so `open` waits until
  the device reports it.
- Input and output must be the same device. Separate devices return
  `.Unsupported`; the user can make an aggregate device in Audio MIDI Setup.
- Timestamps come from the IOProc's `AudioTimeStamp`s, converted with
  `AudioConvertHostTimeToNanos`. `backend.host_time_ns` uses the same clock
  (`CLOCK_UPTIME_RAW`). `core:time` uses `CLOCK_MONOTONIC_RAW`, which keeps
  counting during sleep and drifts from CoreAudio after the first sleep.
- Xruns: a jump in the output `mSampleTime`, or the HAL's processor-overload
  notification.
- Listeners (on the HAL's own notification thread):
  - device list → `Devices_Changed`
  - default input/output → `Default_Device_Changed`
  - `DeviceIsAlive` → `Device_Lost`
  - nominal rate → `Format_Changed`
- `stop` calls `AudioDeviceStop`, then waits for any callback still past its
  entry check to return.
- Reported latency excludes the buffer: device latency + safety offset + stream
  latency. BlackHole reports 0 and measures a 512-frame round trip at 256-frame buffers.

## MIDI (next, with CoreMIDI)

- `fire:midi` defines `Midi_Port_Info`, input and output ports, and virtual
  ports (CoreMIDI, ALSA seq, Windows MIDI Services; `.Unsupported` elsewhere).
- Input arrives on an OS thread with an OS timestamp, converted to
  `host_time_ns`, and is pushed into an SPSC queue. At the start of each audio
  block, events are placed at `offset = (t + latency - block_time) · sr`,
  clamped to the block. Fixed latency of one driver buffer gives jitter-free
  timing; events too late for that are placed at offset 0 and counted.
- Output is timestamped; where the OS cannot schedule (WinMM), a sender thread
  does it.

## Testing

- **CI (no sound hardware):** `fire:backend/fake` simulates devices. It can run
  callbacks on the calling thread (`fake_run`, deterministic) or on its own
  thread. It supports jittery callback sizes, every native format and plane
  layout, loopback with a fixed latency, and injected xruns, device loss and
  format changes.
- **Local only:** `tests/coreaudio` uses BlackHole 2ch to check loopback (a
  constant-gain copy at the measured latency, bit-exact when BlackHole's volume
  is 100%), allocations, timestamps, start/stop cycles and rate-change events.
  Without BlackHole (as on CI) those tests pass as skipped. They take a
  cross-process lock, so concurrent runs never share the device.
