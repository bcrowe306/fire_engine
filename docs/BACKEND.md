# Audio & MIDI backends

Status: shared API, fake driver, CoreAudio + CoreMIDI (macOS 11+) and ALSA
(Linux) drivers implemented. Next: WASAPI + Windows MIDI, ALSA MIDI, JACK, ASIO.

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
advance by `frames / sample_rate`. All timestamps use `rt.host_time_ns()`,
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
  `AudioConvertHostTimeToNanos`. `rt.host_time_ns` uses the same clock
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

## ALSA (`fire:backend/alsa`)

- **Devices.** Hardware PCMs are listed as `hw:CARD=<id>,DEV=<n>`. That name
  survives reboots, unlike card numbers. Any ALSA PCM name (`default`,
  `plughw:0`, `…,SUBDEV=0`) also works as a device ID.
- **Duplex.** Playback and capture are separate PCMs. Input and output may name
  different devices on the same card (one clock), which covers `snd-aloop`:
  device 0 playback comes back as device 1 capture. Different cards return
  `.Unsupported`.
- **Format.** RW interleaved, exact rate (no ALSA resampling). The format is the
  first the device supports of f32, s32, packed s24, s24-in-32 and s16; the
  shared layer converts. Period = `buffer_frames`. Playback keeps 2 periods,
  which sets latency. Capture keeps 4, which is free slack.
- **Thread.** The driver runs its own audio thread and asks for SCHED_FIFO 80 with
  `rt.set_realtime_priority`. That needs CAP_SYS_NICE or an rtprio limit;
  `alsa.has_realtime_priority` reports whether it was granted. Streams open
  non-blocking and every wait is at most 100 ms, so `stop` never hangs on a
  stalled device.
- **Pacing.** Each cycle waits for a period of playback space, then reads the
  matching capture period. Pacing on capture alone fails on `snd-aloop`: it
  signals capture periods late, and playback underruns while we wait. The
  streams are not `snd_pcm_link`ed, because linking `snd-aloop`'s two devices
  left capture silent.
- **Timestamps.** Measured each cycle as now ± `snd_pcm_delay`, then smoothed
  like JACK's DLL: predict one period ahead and pull 5% toward the measurement.
  Raw readings jitter by the thread's wake-up latency and could make
  `output_ns` go backwards.
- **Xruns.** `-EPIPE` or `-ESTRPIPE` restarts the streams (prepare, refill
  playback with silence, start) and flags the next block. `-ENODEV` posts
  `Device_Lost`, then the thread idles until stopped.
- **Not yet done:** hot-plug and format-change notifications (udev), and
  ALSA MIDI.
- **On a VM:** the DigitalOcean test droplet's host stalls it for 20–35 ms at
  times. A plain C loop sees xruns there below 1024-frame periods, so the
  exact-loopback test uses 1024. Small periods need real hardware and a
  quiet machine.

## MIDI (`fire:midi`, `fire:midi/coremidi`)

- **Messages.** The engine sees MIDI 1.0 bytes (`core.Midi_Raw`). Drivers that
  speak UMP convert at the edge with `ump_to_short` / `ump_from_short` and the
  SysEx packet helpers. MIDI 2.0 voice messages are counted as `ignored` until
  the engine grows MIDI 2.0 events.
- **Input.** All drivers deliver to one `Midi_Input`, tagging each message with
  the port index chosen at open (0–15). Driver threads push under a mutex that
  the audio thread never takes. Each audio block calls `input_process`
  (`[rt]`): an event received at host time `t` is placed at
  `t + latency_ns`. With `suggested_latency_ns` (callback-to-presentation gap
  plus one driver period) placement is exact and jitter-free. Late events go to
  offset 0 and are counted; future ones wait for their block.
- **SysEx.** Complete messages go to the control thread through `Sysex_Queue`
  (a byte ring plus descriptors) and are read with `sysex_pop`. They are not
  sample-accurate. Each port has its own reassembly buffer
  (`max_sysex_len`, 8 KiB by default); longer messages are dropped and counted.
- **Output.** The audio thread pushes timestamped short messages into
  `Midi_Output` (`output_push`, `[rt]`). A sender thread passes them to the
  driver, which schedules them (CoreMIDI) or sends them at once. SysEx is sent
  from the control thread with `midi.send`.
- **Ports.** `enumerate` lists sources (`.Input`) and destinations (`.Output`).
  Virtual ports: `create_virtual_input` (a destination other apps send to) and
  `create_virtual_output` (a source other apps receive from).

CoreMIDI specifics:

- Uses the UMP event-list API with the MIDI 1.0 protocol. All sources connect
  to one input port, so input arrives on one CoreMIDI thread.
- Port IDs are CoreMIDI unique IDs, which persist across runs.
- The receive block is a hand-built global Clang block literal (`Receive_Block`
  in `fire:sys/coremidi`). Odin's `NSBlock` helper only supports one parameter.
- Received packets can be longer than the declared `words[64]`, so always read
  `wordCount` words. SysEx over 186 bytes arrives that way.
- One send is limited to about 1.5 KB of SysEx; larger messages return
  `.Invalid_Argument`.
- Not yet done: hot-plug notifications. CoreMIDI delivers them on the run loop
  of the thread that created the client, so they need a dedicated run-loop
  thread.

## Testing

- **CI (no sound hardware):** `fire:backend/fake` simulates devices. It can run
  callbacks on the calling thread (`fake_run`, deterministic) or on its own
  thread. It supports jittery callback sizes, every native format and plane
  layout, loopback with a fixed latency, and injected xruns, device loss and
  format changes.
- **macOS, no hardware:** `tests/coremidi` loops MIDI through virtual ports the
  driver creates itself (named with the process ID so concurrent runs don't
  collide).
- **Linux:** `scripts/cloud/linux.sh` manages an Ubuntu x86 droplet (kept,
  powered off between sessions) with `snd-aloop`, a virtual ALSA loopback card.
  `tests/alsa` runs there; on CI, which has no `snd-aloop`, the device tests skip.
- **Local only:** `tests/coreaudio` uses BlackHole 2ch to check loopback (a
  constant-gain copy at the measured latency, bit-exact when BlackHole's volume
  is 100%), allocations, timestamps, start/stop cycles and rate-change events.
  Without BlackHole (as on CI) those tests pass as skipped. They take a
  cross-process lock, so concurrent runs never share the device.
