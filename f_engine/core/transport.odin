package core

import "core:math"

import tb "fire:timebase"

// A timeline of the engine's clock (see `fire:transport`). The zero value
// means "none". Stays valid until the timeline is removed.
Timeline_Id :: struct {
	index:      u32,
	generation: u32,
}

// Changes since the previous `process` call, in `Transport.flags`.
Transport_Flag :: enum u8 {
	Grid_Jumped,   // the grid position is not continuous with the previous call (e.g. an external sync correction)
	Tempo_Changed, // the tempo or its ramp differs from where the previous call ended
	Meter_Changed, // the meter or bar grid changed
}

// Set of `Transport_Flag`.
Transport_Flags :: bit_set[Transport_Flag; u8]

// Changes to one timeline since the previous `process` call, in
// `Timeline_State.flags`.
Timeline_Flag :: enum u8 {
	Started, // began playing at frame 0 of this call
	Stopped, // stopped at frame 0 of this call
	Jumped,  // `position` is not continuous with the previous call: a locate or a loop wrap
	Wrapped, // the jump was a loop wrap (also sets `Jumped`)
}

// Set of `Timeline_Flag`.
Timeline_Flags :: bit_set[Timeline_Flag; u8]

// One timeline at frame 0 of the current call. Within a call a timeline never
// wraps, jumps, starts or stops: the clock splits blocks at those points.
Timeline_State :: struct {
	id:         Timeline_Id,   // zero for an unused slot
	playing:    bool,
	position:   tb.Beats,      // local position in quarter notes
	rate:       f64,           // local beats per grid beat while playing
	looping:    bool,
	loop_start: tb.Beats,      // loop range in local beats, when `looping`
	loop_end:   tb.Beats,
	tempo_map:  ^tb.Tempo_Map, // the timeline's own map (bars, meters); read-only, may be nil
	flags:      Timeline_Flags,
}

// The clock at the first frame of the current `process` call. Nodes read it
// through `Process_Context.transport`; it may be nil when a node runs without
// a clock. Within one call time is continuous and the meter is fixed; the
// tempo is constant or follows one linear ramp (`tempo_slope`).
Transport :: struct {
	sample_rate: f64,              // Hz
	frame:       tb.Sample_Time,   // reference frames since the clock started; never stops or jumps
	host_ns:     u64,              // presentation time of frame 0 (rt.host_time_ns clock); 0 = unknown
	grid:        tb.Beats,         // the clock's beat grid at frame 0; always advances
	tempo_bpm:   f64,              // tempo at frame 0
	tempo_slope: f64,              // bpm change per grid beat during this call (map ramps); usually 0
	meter:       tb.Meter,         // meter of the bar grid
	bar:         i64,              // 0-based index of the bar containing frame 0
	bar_start:   tb.Beats,         // grid beat of that bar's downbeat
	flags:       Transport_Flags,
	leader:      Timeline_Id,      // the timeline setting tempo and bars; zero = none
	timelines:   []Timeline_State, // one per slot; slots with a zero `id` are unused
}

// [rt] The grid beat `offset` frames into the call, following a tempo ramp
// exactly.
transport_grid_at :: proc "contextless" (t: ^Transport, offset: int) -> tb.Beats {
	return t.grid + tb.ramp_beats(t.tempo_bpm, t.tempo_slope, tb.Seconds(f64(offset) / t.sample_rate))
}

// [rt] The tempo `offset` frames into the call.
transport_tempo_at :: proc "contextless" (t: ^Transport, offset: int) -> f64 {
	return t.tempo_bpm + t.tempo_slope * f64(transport_grid_at(t, offset) - t.grid)
}

// [rt] The state of timeline `id`, or nil if it does not exist (removed, or
// never added). Cheap: an index and a generation check.
transport_timeline :: proc "contextless" (t: ^Transport, id: Timeline_Id) -> ^Timeline_State {
	if t == nil || id.generation == 0 || int(id.index) >= len(t.timelines) do return nil
	tl := &t.timelines[id.index]
	return tl if tl.id == id else nil
}

// [rt] Timeline `tl`'s local position `offset` frames into the call. Stopped
// timelines stay put.
timeline_position_at :: proc "contextless" (t: ^Transport, tl: ^Timeline_State, offset: int) -> tb.Beats {
	if !tl.playing do return tl.position
	return tl.position + tb.Beats(f64(transport_grid_at(t, offset) - t.grid) * tl.rate)
}

// [rt] The first frame offset in this call at which the grid reaches `beat`:
// 0 if it already has, and `frames` or more if it does not within the call.
transport_offset_of :: proc "contextless" (t: ^Transport, beat: tb.Beats) -> int {
	if beat <= t.grid do return 0
	secs := tb.ramp_seconds(t.tempo_bpm, t.tempo_slope, beat - t.grid)
	if math.is_nan(f64(secs)) do return max(int) // a slowing ramp that never gets there
	return int(math.ceil(f64(secs) * t.sample_rate - 1e-6))
}

// [rt] The first frame offset in this call at which playing timeline `tl`
// reaches local position `beat` (see `transport_offset_of`). A stopped
// timeline never moves: 0 if it is at or past `beat`, otherwise never.
timeline_offset_of :: proc "contextless" (t: ^Transport, tl: ^Timeline_State, beat: tb.Beats) -> int {
	if beat <= tl.position do return 0
	if !tl.playing do return max(int)
	return transport_offset_of(t, t.grid + tb.Beats(f64(beat - tl.position) / tl.rate))
}

// [rt] The first multiple of `step` beats on the grid that is due in this
// call or later. A beat is due on the first frame at or after it, so a beat
// that fell just after the previous call's last frame is due at frame 0 of
// this one. Pair with `transport_offset_of` to find its frame:
//
//	for b := core.transport_next_multiple(t, 1); ; b += 1 {
//		offset := core.transport_offset_of(t, b)
//		if offset >= ctx.frames do break
//		click(offset)
//	}
transport_next_multiple :: proc "contextless" (t: ^Transport, step: tb.Beats) -> tb.Beats {
	prev := f64(t.grid) - t.tempo_bpm / 60 / t.sample_rate // the grid one frame earlier
	return tb.Beats((math.floor(prev / f64(step) + 1e-9) + 1) * f64(step))
}

// [rt] Like `transport_next_multiple`, on playing timeline `tl`'s local
// beats; pair with `timeline_offset_of`.
timeline_next_multiple :: proc "contextless" (t: ^Transport, tl: ^Timeline_State, step: tb.Beats) -> tb.Beats {
	prev := f64(tl.position) - tl.rate * t.tempo_bpm / 60 / t.sample_rate
	if .Jumped in tl.flags || .Started in tl.flags do prev = f64(tl.position) - 1e-9 // nothing was due before the jump
	return tb.Beats((math.floor(prev / f64(step) + 1e-9) + 1) * f64(step))
}
