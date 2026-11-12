# Audio channels: choosing an interface's inputs and outputs

Status: built (see the Pads guide, Settings > Audio and the mixer). A
returning interface is switched back to on its own (with a message),
rather than offered. Not yet: Reassign inputs.

Settings > Audio lets you pick which of an interface's input and output
channels Pads opens, shows each one by the interface's own name (or an
alias you give it), and remembers the choice per interface. Main, a cue
mix and direct outs go to chosen output pairs, and audio tracks record
from physical input channels. When a saved interface or channel is
missing, Pads keeps going on what is there, says so, and puts it back
when it returns.

## What there is now

- The backend opens any set of a device's channels (`Channel_Mask`, up to
  64), non-adjacent too, on every driver (CoreAudio, WASAPI, ASIO, ALSA,
  JACK). Devices list their channel counts, but not channel names.
- The host asks for inputs 1..N (`Host_Settings.inputs`) and outputs 1–2.
  The graph's INPUT and OUTPUT channels are those, in order.
- Pads' audio tracks pick an input by position (`Audio_Input.channel`,
  mono or stereo). Main always plays on outputs 1–2. The metronome is
  wired straight to the output.
- If a saved device is gone, Pads falls back to the system's default
  device, then to the simulated one (5013508).

## Decisions (asked)

1. **Outputs**: main on a chosen output pair; any bus (and any pad) can be
   routed to another enabled pair (direct outs); and a **cue** pair, with
   its own mix, that the metronome can play on alone.
2. **Track inputs follow physical channels**: a track on In 5 stays on the
   interface's input 5, whatever else is enabled. If In 5 is not open, the
   track says so and records nothing until it is.
3. **Names**: each channel shows the driver's name where it has one
   (CoreAudio, ASIO, JACK), else its number, and you can give it an alias.
4. **Remembered per interface**: each interface keeps its channels,
   aliases, and main and cue pairs.

## The design

### Backend: channel names

- `Device_Info` gains `input_channel_names`, `output_channel_names:
  []string` ("" where the driver has none; freed by
  `device_infos_destroy`).
- CoreAudio: `kAudioObjectPropertyElementName` for each channel of each
  scope. ASIO: `ASIOGetChannelInfo` (already called). JACK: the port
  names. WASAPI, ALSA: none (the speaker positions on WASAPI, maybe later).
- The fake driver gains configurable devices (counts and names), so
  multi-channel interfaces can be tested without hardware.

### Host: masks, not counts

- `Host_Settings` gets `input_mask`, `output_mask: backend.Channel_Mask`;
  a zero mask means the old default (inputs: none; outputs: 1–2). The
  graph's INPUT and OUTPUT channels are the opened channels in device
  order (compact), and the host exposes the mapping
  (`host_input_channel(h, device_channel) -> graph channel or -1`, and the
  same for outputs).
- Opening asks for the saved mask intersected with what the device has
  now (channels past its count are dropped from the request and reported
  back, so the app can say which are missing).
- A change of mask rebuilds the graph like a sample-rate change (the
  engine rebuild path, which the graph fix in 436c1f9 made safe).

### Settings: per interface

```ini
[audio]
output = <device id>
input = <device id>
sample_rate = 0
buffer = 0

[audio.device.<device id>]
inputs = 1,2,5,6          ; physical channels, 1-based
outputs = 1,2,3,4,7,8
main = 1                  ; the output pair main plays on (1 = 1/2)
cue = 7                   ; the cue pair (0: none)
in.5 = Kick mic           ; aliases
out.3 = Monitor B
```

- An interface seen for the first time gets the defaults: inputs 1–2 (or
  the ones it has), outputs 1–2, main on 1/2, no cue.
- `inputs` and `outputs` replace the old "Input channels" count; an old
  `input_channels = N` becomes inputs 1..N on first read.

### The Audio page

- Output and input interface choosers, as now; then, for each, a channel
  list:
  - each channel: a switch, its number, its name (the driver's) and an
    alias field (empty: the name); `All`, `None` and `Pairs only` buttons;
  - stereo pairs are physical (1/2, 3/4...): a pair is offered to tracks,
    main, cue and direct outs only when both halves are on;
  - a live level meter beside each input, and a "test tone" button beside
    each output pair (a short sine there, to find which speaker it is).
- **Main output**: a choice of the enabled pairs. **Cue output**: none or
  a pair, with its level, and "metronome on the cue only".
- Apply as now (staged, then "keep these settings?" for 10 s, reverted if
  the device won't open).
- What is missing, shown in place: a saved channel the interface no
  longer has ("In 7: not on this interface"), a saved interface that is
  not connected ("Focusrite Scarlett 18i20: not connected, using the
  system's"), and a switch to forget it.

### Pads: inputs, outputs, cue

- `Audio_Input.channel` becomes the physical channel (it already is, with
  inputs 1..N; files keep their meaning). The engine maps it through the
  host; a track whose channel is not open shows "In 5 (not open)" in its
  input chooser and on its strip, monitors and records silence, and comes
  back when the channel does. The track's input list shows only open
  channels, named by alias.
- Routing gains outputs: a bus's (and a pad's) output can be main, a bus,
  or an **output pair** (a direct out: after its fader, not in main). Its
  output button lists the enabled pairs by name. A pair that goes away
  sends it to main (and the button says where it wanted to go).
- **Cue**: a mix of main (pre its fader), with its own level and the
  metronome's level, on the cue pair. Each bus and pad gets a **cue
  send** (a send to the cue mix, like the bus sends), for a performer's
  headphones mix. The metronome option "Click on the cue only" keeps it
  out of main.
- The project saves which pair it wanted (main, cue and direct outs) by
  physical channel; opening it on another interface falls back as above.

### Failing safely

| What is missing | What happens |
|---|---|
| The saved interface (unplugged) | The system's default device opens (as now); Settings and the status bar say which is missing; when it is plugged in again, Pads offers to switch back (or does, if the setting "use it when it is back" is on). |
| A saved channel (fewer channels now) | Opened without it; tracks and outs on it show it as not open; the settings keep it. |
| Main's pair | Main plays on the first enabled pair (1/2 if none), and says so. |
| The cue pair | No cue; the cue mix is still kept, unheard. |
| No output channel at all | Outputs 1–2 (a device must have output). |
| The device won't open with the mask | The default mask (1–2 out, no inputs), then the existing fallback. |

Nothing missing is ever removed from the settings or the project: it all
comes back when the hardware does.

## Gaps this covers that were not asked

- **Interfaces changing while Pads runs**: the device list refreshes on the
  system's device-change events (not only the refresh button), so a
  newly plugged interface appears without reopening Settings.
- **Separate input and output interfaces**: still allowed; their clocks
  drift unless the system joins them (an aggregate device on macOS).
  The page says so when they differ.
- **Latency**: the reported input and output latency (and the measured
  round trip, once it runs) show per interface, as now.
- **Meters**: the mixer's input meters and the status bar follow the
  open channels by name.
- **Projects moved between machines**: tracks and outs keep their
  physical channels; a "Reassign inputs" action in the track input menu
  maps missing ones onto open channels in one step.
- **Exports**: a mixdown renders main, so a bus sent to a direct out would
  be missing from it. While exporting, direct outs fold back into main (as
  if routed there), so the mixdown has everything; bus stems render each
  bus as now. The cue mix is never exported.
- **Tests**: the fake driver's multi-channel devices let the model, drive
  scripts and e2e tests cover channel selection, aliases, missing
  channels, missing interfaces, main, cue and direct-out routing, and the
  file format (old `input_channels` read as inputs 1..N).

## Order of work

1. Backend: channel names in `Device_Info` (CoreAudio, ASIO, JACK), the
   fake driver's configurable devices; tests.
2. Host: input and output masks, the device-to-graph channel mapping,
   missing channels reported; tests on the fake driver.
3. Settings: the per-interface sections, migration of `input_channels`,
   aliases; the Audio page's channel lists, main and cue pairs, test tone,
   missing-hardware messages; e2e tests.
4. Pads: physical-channel track inputs through the mapping, "not open"
   states, direct outs on buses and pads, the cue mix and cue sends, the
   metronome on the cue; project format; model and e2e tests.
5. Docs (the Pads guide's Audio settings, the backend reference), a drive
   script with screenshots, cloud tests on Linux, ARM and Windows (ASIO
   and WASAPI there).
