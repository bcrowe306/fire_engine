---
title: Clock and timelines design
description: How fire:transport keeps one musical clock that linear arrangements, clip launchers, loopers and sequencers all follow, sample-accurately.
---

Fire Engine is not only a linear DAW. The same engine should drive an
arrangement, a grid of launchable clips, loopers, step sequencers and free
jamming, all at once and in time with each other. `fire:transport` gives them
one shared sense of musical time. The [transport guide](/guides/transport/)
shows how to use it.

Tracktion Engine's `PlayHead` (read for reference, not translated) maps a
free-running device frame count onto one timeline through a sync point, and
flags jumps and loop wraps per block. We keep that idea, a free-running
reference mapped onto musical positions, but generalise it to many timelines.

## Model

- **Clock.** One per engine. It counts *reference frames* from the moment it
  was created and never stops. It also keeps the **grid**: a beat position
  (`tb.Beats`, quarter notes) that advances at the current tempo whether or
  not anything is playing. Arpeggiators, synced LFOs and delays follow the
  grid, so they keep time while the arrangement is stopped.
- **Timelines.** Any number, created by the app (`add_timeline`). A timeline
  has a local position in beats, a play state, an optional loop, a rate
  (1 = in step with the grid, 0.5 = half time) and an optional tempo map.
  While playing, its position is a straight line against the grid:

  `local = anchor_local + (grid − anchor_grid) × rate`

  wrapped by its loop. A linear arrangement is one timeline. A clip launcher
  uses one timeline per playing clip or per track. A looper's loop is a
  timeline with a loop range. A step sequencer pattern is a looping timeline,
  and several of different lengths give polymeters.
- **Leader.** At most one timeline is the leader (`set_leader`). While the
  leader plays and has a tempo map, the map sets the tempo and meter, so
  tempo changes and ramps in an arrangement take effect everywhere. The
  leader always runs at rate 1.
- **Live tempo.** Otherwise the tempo is the *live tempo* (`set_tempo`): a
  knob, tap tempo, or an external clock. `set_tempo_override` makes the live
  tempo win even while the leader plays; the leader's meters still apply.
  When the leader stops, the live tempo and meter take over from where the
  leader left off, so nothing jumps.

Every source of tempo flows through the clock, so there is exactly one tempo
at any moment. Different speeds are expressed with timeline rates, not with
second clocks.

## Commands and quantization

All control is by command: `play`, `stop`, `locate`, `set_loop`, `set_rate`,
`set_tempo`, `set_meter`, `set_leader`, `set_tempo_map`. Each takes a `When`:

- `nil` (now): at the start of the next block;
- a `Quantize` value (`.Bar`, `.Bars_4`, `.Sixteenth_T`, ...): the next
  boundary of that length, counted from the current bar's downbeat;
- `At_Beat(b)`: an exact grid beat, for apps that compute their own times.

The control thread pushes commands on an SPSC queue. At the start of each
block the audio thread resolves each one to an exact grid beat and inserts it
into a sorted, fixed-capacity schedule. A command lands on the first frame
whose grid position reaches its beat. Positions keep sub-frame precision: a
timeline started at beat 16 is anchored at exactly 16, not at the frame's
rounded position, so long runs never drift.

**Bars.** Quantizing to bars needs a bar grid. While the leader plays, its
tempo map's bars are the bar grid. Otherwise the clock keeps its own bar grid
(the live meter, anchored where it last changed). When the leader stops, the
clock's bar grid continues the leader's bar lines.

## Blocks are split at every discontinuity

`transport.process(clock, ctx, run, user)` runs one device block. It calls
`run` once per *segment*, a run of frames in which:

- time is continuous for the grid and for every timeline (no loop wrap, jump,
  start or stop inside it);
- the tempo is constant, or follows one linear ramp from the leader's map;
- the meter does not change.

Segments end at scheduled commands, loop wraps, and the leader map's tempo
and meter points. A node therefore never handles a discontinuity mid-call: a
sampler sees a call that ends at the loop end, then a call flagged `Jumped`
that starts at the loop start. Blocks without such points are not split. The
cost is an extra `process` call for the whole graph at those frames only.

`run` gets a `Process_Context` with the inputs, outputs and `events_in`
sliced and rebased to the segment, and `ctx.transport` pointing at the
segment's snapshot. Events written to `events_out` are shifted back to block
offsets afterwards.

## What nodes see

`core.Transport` is the snapshot at frame 0 of the current call:

| Field | Meaning |
|-------|---------|
| `frame` | reference frames since the clock started |
| `host_ns` | presentation time of frame 0 (`rt.host_time_ns` clock), 0 if unknown |
| `grid`, `tempo_bpm`, `tempo_slope` | grid beat, tempo, and ramp (bpm per beat) |
| `meter`, `bar`, `bar_start` | the bar grid: meter, bar index, grid beat of its downbeat |
| `flags` | `Grid_Jumped`, `Tempo_Changed`, `Meter_Changed` since the previous call |
| `timelines` | one `Timeline_State` per timeline slot |
| `leader` | the leading timeline, or the zero ID |

A node that follows a timeline holds its `Timeline_Id` (set by the app, for
instance as a parameter) and calls `core.transport_timeline(t, id)`. Exact
positions inside the call come from `core.transport_grid_at(t, offset)` and
`core.timeline_position_at(t, tl, offset)`, which follow ramps exactly.

## Tempo maps

A timeline's tempo map is copied when it is set (`set_tempo_map`), and the
copy is immutable. Replacing or removing it retires the old copy to the
control thread, which frees it in `collect`, the same pattern as graph plans.
Apps edit their own `tb.Tempo_Map` freely and set it again.

Grid time under a map is computed from the map's seconds conversion, from an
anchor, rather than accumulated block by block, so there is no rounding drift
over hours.

## Status for the UI

At the end of each block the audio thread publishes the grid, tempo and each
timeline's position and play state with atomic stores. The control thread
reads them with `status` and `timeline_status`. Values may be one block old,
and fields can come from adjacent blocks.

## External sync

- **MIDI clock out**: `transport.Midi_Clock_Out` emits 24-PPQ clock, Start,
  Stop, Continue and Song Position Pointer as sample-accurate MIDI events,
  following the grid (clock) and a chosen timeline (start, stop and position).
- **Ableton Link**: an optional package `fire:link`, built against Ableton's
  `abl_link` C library, fetched and built by `scripts/link.sh`. Link is
  GPLv2+ unless you hold Ableton's commercial licence, and that applies to
  any app that links it. Nothing else in the engine depends on it.
- **Followers in general** implement `transport.Sync`: at each block start
  the sync source may set the tempo and correct the grid. Link is one such
  source; a plugin host or MIDI clock input would be others.

## Not covered (yet)

- Recording, punch and count-in belong to the recording layer, which will
  use timelines and quantized commands.
- Live tempo ramps (tempo glides over N beats). Map ramps work today.
- Reverse playback (negative rates) and scrubbing.
