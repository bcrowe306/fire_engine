package transport

import "base:intrinsics"
import "core:math"

import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// Runs one segment of a block, such as `graph.process`. `ctx` covers just
// the segment: buffers and events are sliced and rebased, and
// `ctx.transport` describes its first frame.
Segment_Proc :: proc(user: rawptr, ctx: ^core.Process_Context)

// [rt] Advances the clock by `ctx.frames` and calls `run` once per segment:
// once for most blocks, more often when a loop wraps, a command takes
// effect, or the leader's tempo or meter changes inside the block. Within
// each segment time is continuous for the grid and every timeline. Events
// `run` writes to `ctx.events_out` are shifted back to block offsets.
// `host_ns` is the presentation time of the block's first frame
// (`backend.Io_Block.output_ns`); 0 if unknown. Audio thread only; never
// allocates.
process :: proc(c: ^Clock, ctx: ^core.Process_Context, run: Segment_Proc, user: rawptr, host_ns: u64 = 0) {
	frames := max(ctx.frames, 0)
	fire_due(c, c.frame)
	drain(c, grid_at_frame(c, f64(c.frame)))
	if c.sync.begin_block != nil do follow_sync(c, frames, host_ns)
	for pos := 0; pos < frames; {
		now := c.frame + i64(pos)
		fire_due(c, now)
		n := frames - pos
		if next, ok := next_boundary(c, now); ok do n = min(n, int(next - now))
		snapshot(c, now, host_ns, pos)
		run_segment(c, ctx, run, user, pos, n, frames)
		end_grid := c.transport.grid + tb.ramp_beats(c.transport.tempo_bpm, c.transport.tempo_slope, tb.Seconds(f64(n) / c.settings.sample_rate))
		c.last_tempo = c.transport.tempo_bpm + c.transport.tempo_slope * f64(end_grid - c.transport.grid)
		c.last_slope = c.transport.tempo_slope
		c.last_meter = c.transport.meter
		pos += n
	}
	c.frame += i64(frames)
	publish(c)
}

// --- audio-side state ------------------------------------------------------------------

@(private)
Timeline :: struct {
	state:        core.Timeline_State, // `position` is current only while stopped; `flags` pending for the next call
	anchor_grid:  tb.Beats,            // while playing: local = anchor_local + (grid − anchor_grid) × rate
	anchor_local: tb.Beats,
}

// Grid time as a function of reference frames, from an anchor, so it never
// accumulates rounding error.
@(private)
Tempo_Source :: struct {
	frame:   f64,           // reference frame of the anchor (fractional: commands land between frames)
	grid:    tb.Beats,      // grid at the anchor
	bpm:     f64,           // the tempo, when `tmap` is nil
	tmap:    ^tb.Tempo_Map, // the playing leader's map
	local:   tb.Beats,      // the leader's position at the anchor
	seconds: tb.Seconds,    // `tmap` time at `local`
}

@(private)
Bars :: struct {
	meter: tb.Meter,
	bar:   i64,
	start: tb.Beats, // grid beat of the downbeat
}

@(private)
Audio_State :: struct {
	frame:      i64, // reference frames at the start of the current block
	source:     Tempo_Source,
	live_bpm:   f64,
	override:   bool,
	sync:       Sync,
	// Local starts and stops of the sync's timeline (see `Sync_Block`).
	sync_toggles:    u64,
	sync_toggled_at: tb.Beats,
	leader:     core.Timeline_Id,
	// The clock's own bar grid, used while no leader plays: bar `bar_index`
	// starts at grid beat `bar_anchor`.
	live_meter: tb.Meter,
	bar_anchor: tb.Beats,
	bar_index:  i64,
	timelines:  []Timeline,
	snapshot:   []core.Timeline_State,
	schedule:   []Command, // sorted by (at, seq)
	scheduled:  int,
	events:     []core.Event, // rebased input events for one segment
	transport:  core.Transport,
	flags:      core.Transport_Flags, // pending for the next call
	last_tempo: f64, // where the previous call ended
	last_slope: f64,
	last_meter: tb.Meter,
	ins, outs:  [core.MAX_CHANNELS][]f32,
}

@(private)
audio_init :: proc(c: ^Clock) {
	c.live_bpm = c.settings.bpm
	c.live_meter = c.settings.meter
	c.source = {bpm = c.settings.bpm}
	c.last_tempo = c.settings.bpm
	c.last_meter = c.settings.meter
	publish(c)
}

// Commands landing within this many beats of a boundary count as on it.
@(private)
EPS :: 1e-9

// --- time ------------------------------------------------------------------------------

@(private)
grid_at_frame :: proc "contextless" (c: ^Clock, f: f64) -> tb.Beats {
	s := &c.source
	dt := tb.Seconds((f - s.frame) / c.settings.sample_rate)
	if s.tmap == nil do return s.grid + tb.Beats(f64(dt) * s.bpm / 60)
	return s.grid + (tb.seconds_to_beats(s.tmap, s.seconds + dt) - s.local)
}

@(private)
frame_at_grid :: proc "contextless" (c: ^Clock, g: tb.Beats) -> f64 {
	s := &c.source
	if s.tmap == nil do return s.frame + f64(g - s.grid) * 60 * c.settings.sample_rate / s.bpm
	return s.frame + f64(tb.beats_to_seconds(s.tmap, s.local + (g - s.grid)) - s.seconds) * c.settings.sample_rate
}

// The first whole frame at which the grid has reached `g`.
@(private)
due_frame :: proc "contextless" (c: ^Clock, g: tb.Beats) -> i64 {
	return i64(math.ceil(frame_at_grid(c, g) - 1e-6))
}

@(private)
tempo_at_grid :: proc "contextless" (c: ^Clock, g: tb.Beats) -> (bpm, slope: f64) {
	s := &c.source
	if s.tmap == nil do return s.bpm, 0
	l := s.local + (g - s.grid)
	return tb.tempo_at(s.tmap, l), tb.tempo_slope_at(s.tmap, l)
}

@(private)
local_at :: proc "contextless" (tl: ^Timeline, g: tb.Beats) -> tb.Beats {
	if !tl.state.playing do return tl.state.position
	return tl.anchor_local + tb.Beats(f64(g - tl.anchor_grid) * tl.state.rate)
}

@(private)
get :: proc "contextless" (c: ^Clock, id: core.Timeline_Id) -> ^Timeline {
	if id.generation == 0 || int(id.index) >= len(c.timelines) do return nil
	tl := &c.timelines[id.index]
	return tl if tl.state.id == id else nil
}

@(private)
playing_leader :: proc "contextless" (c: ^Clock) -> ^Timeline {
	tl := get(c, c.leader)
	return tl if tl != nil && tl.state.playing else nil
}

// The grid beat where a playing, looping timeline next reaches its loop end.
@(private)
wrap_beat :: proc "contextless" (tl: ^Timeline) -> (tb.Beats, bool) {
	s := &tl.state
	if !s.playing || !s.looping || tl.anchor_local >= s.loop_end do return 0, false
	return tl.anchor_grid + tb.Beats(f64(s.loop_end - tl.anchor_local) / s.rate), true
}

// --- bars and quantization -------------------------------------------------------------

@(private)
bars_at :: proc "contextless" (c: ^Clock, g: tb.Beats) -> Bars {
	if L := playing_leader(c); L != nil {
		l := local_at(L, g)
		meter, bar0, beat0 := c.live_meter, i64(0), tb.Beats(0)
		if L.state.tempo_map != nil do meter, bar0, beat0 = tb.meter_at_beat(L.state.tempo_map, l)
		bpb := tb.beats_per_bar(meter)
		k := i64(math.floor(f64(l - beat0) / bpb + EPS))
		return {meter, bar0 + k, g - (l - (beat0 + tb.Beats(f64(k) * bpb)))}
	}
	bpb := tb.beats_per_bar(c.live_meter)
	k := i64(math.floor(f64(g - c.bar_anchor) / bpb + EPS))
	return {c.live_meter, c.bar_index + k, c.bar_anchor + tb.Beats(f64(k) * bpb)}
}

// Grid beat of the downbeat of bar `m`, on the bar grid in effect at `g`.
@(private)
bar_start_grid :: proc "contextless" (c: ^Clock, g: tb.Beats, m: i64) -> tb.Beats {
	if L := playing_leader(c); L != nil {
		l := local_at(L, g)
		lm: tb.Beats
		if L.state.tempo_map != nil {
			lm = tb.bbt_to_beats(L.state.tempo_map, {m, 0, 0})
		} else {
			lm = tb.Beats(f64(m) * tb.beats_per_bar(c.live_meter))
		}
		return g + (lm - l)
	}
	return c.bar_anchor + tb.Beats(f64(m - c.bar_index) * tb.beats_per_bar(c.live_meter))
}

@(private)
resolve :: proc "contextless" (c: ^Clock, w: When, g: tb.Beats) -> tb.Beats {
	switch v in w {
	case At_Beat:
		return max(tb.Beats(v), g)
	case tb.Quantize:
		bars, beats := tb.quantize_length(v)
		if bars == 0 && beats == 0 do return g
		b := bars_at(c, g)
		on_downbeat := g - b.start < EPS
		if bars > 0 {
			n := i64(bars)
			if on_downbeat && b.bar %% n == 0 do return g
			return bar_start_grid(c, g, (b.bar - b.bar %% n) + n)
		}
		next := b.start + tb.Beats(math.ceil(f64(g - b.start) / f64(beats) - EPS) * f64(beats))
		return max(g, min(next, bar_start_grid(c, g, b.bar + 1)))
	}
	return g
}

// --- commands --------------------------------------------------------------------------

@(private)
drain :: proc(c: ^Clock, g0: tb.Beats) {
	for cmd in rt.spsc_pop(&c.commands) {
		cmd := cmd
		switch cmd.kind {
		case .Add, .Remove, .Set_Map:
			apply(c, &cmd, g0)
		case .Play, .Stop, .Locate, .Set_Loop, .Clear_Loop, .Set_Rate, .Set_Tempo, .Set_Meter, .Set_Leader, .Set_Override, .Set_Sync:
			// Commands due now apply at once, so later commands in the same
			// batch quantize against their effect (play the song, then
			// launch a clip on its next bar).
			cmd.at = resolve(c, cmd.when_, g0)
			if due_frame(c, cmd.at) <= c.frame {
				apply(c, &cmd, cmd.at)
			} else {
				insert(c, cmd)
			}
		}
	}
}

@(private)
insert :: proc "contextless" (c: ^Clock, cmd: Command) {
	if c.scheduled >= len(c.schedule) {
		intrinsics.atomic_add_explicit(&c.dropped_commands, 1, .Relaxed)
		return
	}
	i := c.scheduled
	for i > 0 && (c.schedule[i - 1].at > cmd.at || (c.schedule[i - 1].at == cmd.at && c.schedule[i - 1].seq > cmd.seq)) {
		c.schedule[i] = c.schedule[i - 1]
		i -= 1
	}
	c.schedule[i] = cmd
	c.scheduled += 1
}

// Applies everything due at reference frame `now`, earliest beat first (a
// loop wrap before a command at the same beat).
@(private)
fire_due :: proc(c: ^Clock, now: i64) {
	for _ in 0 ..< 4096 { // bound: a pathological schedule cannot hang the audio thread
		wrap: ^Timeline
		wrap_at: tb.Beats
		for &tl in c.timelines {
			if b, ok := wrap_beat(&tl); ok && due_frame(c, b) <= now && (wrap == nil || b < wrap_at) {
				wrap, wrap_at = &tl, b
			}
		}
		has_cmd := c.scheduled > 0 && due_frame(c, c.schedule[0].at) <= now
		if wrap != nil && (!has_cmd || wrap_at <= c.schedule[0].at) {
			do_wrap(c, wrap, wrap_at)
		} else if has_cmd {
			cmd := c.schedule[0]
			copy(c.schedule[:c.scheduled - 1], c.schedule[1:c.scheduled])
			c.scheduled -= 1
			apply(c, &cmd, cmd.at)
		} else {
			return
		}
	}
}

@(private)
do_wrap :: proc(c: ^Clock, tl: ^Timeline, b: tb.Beats) {
	edit := begin_edit(c, b)
	tl.anchor_local = tl.state.loop_start
	tl.anchor_grid = b
	tl.state.flags += {.Jumped, .Wrapped}
	if tl.state.id == c.leader do end_edit(c, edit)
}

// The bar grid and tempo just before an edit at grid beat `b`, so that
// `end_edit` can carry them over when the leader stops leading.
@(private)
Edit :: struct {
	at:        tb.Beats,
	frame:     f64,
	bars:      Bars,
	tempo:     f64,
	authority: bool, // a leader was playing
}

@(private)
begin_edit :: proc "contextless" (c: ^Clock, b: tb.Beats) -> Edit {
	tempo, _ := tempo_at_grid(c, b)
	return {b, frame_at_grid(c, b), bars_at(c, b), tempo, playing_leader(c) != nil}
}

// Re-anchors grid time after an edit that may change the tempo source or the
// bar grid.
@(private)
end_edit :: proc "contextless" (c: ^Clock, e: Edit) {
	L := playing_leader(c)
	if e.authority && L == nil {
		// The clock's bar grid carries on the leader's bar lines.
		c.live_meter, c.bar_anchor, c.bar_index = e.bars.meter, e.bars.start, e.bars.bar
		c.flags += {.Meter_Changed}
	} else if !e.authority && L != nil {
		c.flags += {.Meter_Changed}
	}
	if L != nil && L.state.tempo_map != nil && !c.override && c.sync.begin_block == nil {
		l := local_at(L, e.at)
		c.source = {frame = e.frame, grid = e.at, tmap = L.state.tempo_map, local = l, seconds = tb.beats_to_seconds(L.state.tempo_map, l)}
	} else {
		if c.source.tmap != nil && !c.override && c.sync.begin_block == nil do c.live_bpm = e.tempo // carry on at the map's tempo
		c.source = {frame = e.frame, grid = e.at, bpm = c.live_bpm}
	}
}

@(private)
apply :: proc(c: ^Clock, cmd: ^Command, b: tb.Beats) {
	tl := get(c, cmd.timeline)
	edit := begin_edit(c, b)
	affects_clock := false
	switch cmd.kind {
	case .Add:
		c.timelines[cmd.timeline.index] = {state = {id = cmd.timeline, rate = 1, tempo_map = cmd.tmap}}
	case .Remove:
		if tl == nil do return
		retire(c, tl.state.tempo_map)
		affects_clock = cmd.timeline == c.leader
		if affects_clock do c.leader = {}
		tl^ = {}
	case .Set_Map:
		if tl == nil {
			retire(c, cmd.tmap)
			return
		}
		retire(c, tl.state.tempo_map)
		tl.state.tempo_map = cmd.tmap
		affects_clock = cmd.timeline == c.leader
	case .Play:
		if tl == nil || tl.state.playing do return
		tl.state.playing = true
		tl.anchor_local, tl.anchor_grid = tl.state.position, b
		tl.state.flags += {.Started}
		affects_clock = cmd.timeline == c.leader
		toggled(c, cmd, b)
	case .Stop:
		if tl == nil || !tl.state.playing do return
		tl.state.position = local_at(tl, b)
		tl.state.playing = false
		tl.state.flags += {.Stopped}
		affects_clock = cmd.timeline == c.leader
		toggled(c, cmd, b)
	case .Locate:
		if tl == nil do return
		if tl.state.playing {
			tl.anchor_local, tl.anchor_grid = cmd.a, b
		} else {
			tl.state.position = cmd.a
		}
		tl.state.flags += {.Jumped}
		affects_clock = cmd.timeline == c.leader
	case .Set_Loop:
		if tl == nil do return
		tl.state.looping, tl.state.loop_start, tl.state.loop_end = true, cmd.a, cmd.b
	case .Clear_Loop:
		if tl == nil do return
		tl.state.looping = false
	case .Set_Rate:
		if tl == nil || cmd.timeline == c.leader do return
		set_rate_at(tl, cmd.value, b)
	case .Set_Tempo:
		c.live_bpm = cmd.value
		affects_clock = true
	case .Set_Meter:
		if playing_leader(c) == nil {
			// A new bar starts here (normally already a downbeat).
			if b - edit.bars.start < EPS {
				c.bar_anchor, c.bar_index = edit.bars.start, edit.bars.bar
			} else {
				c.bar_anchor, c.bar_index = b, edit.bars.bar + 1
			}
		}
		c.live_meter = cmd.meter
		c.flags += {.Meter_Changed}
	case .Set_Leader:
		if cmd.timeline != {} && tl == nil do return
		c.leader = cmd.timeline
		if tl != nil do set_rate_at(tl, 1, b)
		affects_clock = true
	case .Set_Override:
		c.override = cmd.flag
		affects_clock = true
	case .Set_Sync:
		if c.sync.begin_block == nil && cmd.sync.begin_block != nil && playing_leader(c) == nil {
			c.bar_anchor, c.bar_index = 0, 0
			c.flags += {.Meter_Changed}
		}
		c.sync = cmd.sync
		affects_clock = true
	}
	if affects_clock do end_edit(c, edit)
}

// Counts a start or stop of the sync's timeline that the sync didn't ask for
// (its own commands carry `flag`).
@(private)
toggled :: proc "contextless" (c: ^Clock, cmd: ^Command, b: tb.Beats) {
	if cmd.timeline == c.sync.timeline && !cmd.flag {
		c.sync_toggles += 1
		c.sync_toggled_at = b
	}
}

// Lets the sync source set this block's tempo and grid position, and start
// or stop its timeline.
@(private)
follow_sync :: proc(c: ^Clock, frames: int, host_ns: u64) {
	g := grid_at_frame(c, f64(c.frame))
	desired := c.live_bpm
	if L := playing_leader(c); L != nil && L.state.tempo_map != nil && !c.override {
		desired = tb.tempo_at(L.state.tempo_map, local_at(L, g))
	}
	b := Sync_Block {
		frame = tb.Sample_Time(c.frame), frames = frames, sample_rate = c.settings.sample_rate,
		host_ns = host_ns, grid = g, desired_bpm = desired,
		toggles = c.sync_toggles, toggled_at = c.sync_toggled_at,
	}
	tl := get(c, c.sync.timeline)
	if tl != nil do b.playing = tl.state.playing
	c.sync.begin_block(c.sync.user, &b)
	if !b.ok || !(b.bpm >= MIN_BPM && b.bpm <= MAX_BPM) do return
	delta := b.beat - g
	if abs(delta) > SYNC_JUMP {
		// Keep playing timelines and scheduled commands where they were
		// relative to the music, not to the old grid numbers.
		for &tl in c.timelines do if tl.state.playing do tl.anchor_grid += delta
		for &cmd in c.schedule[:c.scheduled] do cmd.at += delta
		c.flags += {.Grid_Jumped}
	}
	c.live_bpm = b.bpm
	c.source = {frame = f64(c.frame), grid = b.beat, bpm = b.bpm}
	if tl != nil && b.start_stop != .None {
		cmd := Command{kind = .Play if b.start_stop == .Start else .Stop, timeline = c.sync.timeline, flag = true, at = b.start_stop_at}
		if due_frame(c, cmd.at) <= c.frame {
			apply(c, &cmd, cmd.at)
		} else {
			insert(c, cmd)
		}
	}
}

@(private)
set_rate_at :: proc "contextless" (tl: ^Timeline, rate: f64, b: tb.Beats) {
	if tl.state.playing {
		tl.anchor_local = local_at(tl, b)
		tl.anchor_grid = b
	}
	tl.state.rate = rate
}

@(private)
retire :: proc "contextless" (c: ^Clock, m: ^tb.Tempo_Map) {
	// If the queue is full the copy stays in `maps` and `destroy` frees it.
	if m != nil do rt.spsc_push(&c.retired, m)
}

// --- segments --------------------------------------------------------------------------

// The next reference frame after `now` at which something must happen.
@(private)
next_boundary :: proc "contextless" (c: ^Clock, now: i64) -> (next: i64, ok: bool) {
	consider :: proc "contextless" (c: ^Clock, now: i64, b: tb.Beats, next: ^i64, ok: ^bool) -> bool {
		f := due_frame(c, b)
		if f <= now do return false
		if !ok^ || f < next^ do next^, ok^ = f, true
		return true
	}
	if c.scheduled > 0 do consider(c, now, c.schedule[0].at, &next, &ok)
	for &tl in c.timelines {
		if b, wraps := wrap_beat(&tl); wraps do consider(c, now, b, &next, &ok)
	}
	if L := playing_leader(c); L != nil && L.state.tempo_map != nil {
		g := grid_at_frame(c, f64(now))
		l := local_at(L, g)
		for _ in 0 ..< 4 {
			change := tb.next_change_after(L.state.tempo_map, l) or_break
			if consider(c, now, g + (change - l), &next, &ok) do break
			l = change // within rounding of `now`: look past it
		}
	}
	return
}

@(private)
snapshot :: proc "contextless" (c: ^Clock, now: i64, host_ns: u64, pos: int) {
	sr := c.settings.sample_rate
	g := grid_at_frame(c, f64(now))
	tempo, slope := tempo_at_grid(c, g)
	bars := bars_at(c, g)
	flags := c.flags
	if abs(tempo - c.last_tempo) > 1e-9 || slope != c.last_slope do flags += {.Tempo_Changed}
	if bars.meter != c.last_meter do flags += {.Meter_Changed}
	c.transport = {
		sample_rate = sr,
		frame       = tb.Sample_Time(now),
		host_ns     = host_ns + u64(f64(pos) * 1e9 / sr) if host_ns != 0 else 0,
		grid        = g,
		tempo_bpm   = tempo,
		tempo_slope = slope,
		meter       = bars.meter,
		bar         = bars.bar,
		bar_start   = bars.start,
		flags       = flags,
		leader      = c.leader,
		timelines   = c.snapshot,
	}
	c.flags = {}
	for &tl, i in c.timelines {
		s := tl.state
		if s.playing do s.position = local_at(&tl, g)
		c.snapshot[i] = s
		tl.state.flags = {}
	}
}

@(private)
run_segment :: proc(c: ^Clock, ctx: ^core.Process_Context, run: Segment_Proc, user: rawptr, pos, n, frames: int) {
	sub := ctx^
	sub.transport = &c.transport
	if pos == 0 && n == frames {
		run(user, &sub)
		return
	}
	sub.frames = n
	sub.inputs = slice_channels(c.ins[:], ctx.inputs, pos, n)
	sub.outputs = slice_channels(c.outs[:], ctx.outputs, pos, n)
	k := 0
	for e in ctx.events_in {
		if int(e.offset) < pos || int(e.offset) >= pos + n do continue
		if k == len(c.events) {
			intrinsics.atomic_add_explicit(&c.dropped_events, 1, .Relaxed)
			continue
		}
		c.events[k] = e
		c.events[k].offset -= u32(pos)
		k += 1
	}
	sub.events_in = c.events[:k]
	written := ctx.events_out.count if ctx.events_out != nil else 0
	run(user, &sub)
	if ctx.events_out != nil {
		for &e in ctx.events_out.buffer[written:ctx.events_out.count] do e.offset += u32(pos)
	}
}

@(private)
slice_channels :: proc "contextless" (dst: [][]f32, src: [][]f32, pos, n: int) -> [][]f32 {
	count := min(len(src), len(dst))
	for i in 0 ..< count {
		ch := src[i]
		dst[i] = ch[min(pos, len(ch)):min(pos + n, len(ch))]
	}
	return dst[:count]
}

@(private)
publish :: proc "contextless" (c: ^Clock) {
	g := grid_at_frame(c, f64(c.frame))
	tempo, _ := tempo_at_grid(c, g)
	intrinsics.atomic_store_explicit(&c.status_frame, c.frame, .Relaxed)
	intrinsics.atomic_store_explicit(&c.status_grid, transmute(u64)f64(g), .Relaxed)
	intrinsics.atomic_store_explicit(&c.status_tempo, transmute(u64)tempo, .Relaxed)
	bars := bars_at(c, g)
	intrinsics.atomic_store_explicit(&c.status_bar, bars.bar, .Relaxed)
	intrinsics.atomic_store_explicit(&c.status_meter, u64(bars.meter.numerator) << 32 | u64(u32(bars.meter.denominator)), .Relaxed)
	for &tl, i in c.timelines {
		s := &c.status_timelines[i]
		intrinsics.atomic_store_explicit(&s.position, transmute(u64)f64(local_at(&tl, g)), .Relaxed)
		intrinsics.atomic_store_explicit(&s.playing, tl.state.playing, .Relaxed)
		intrinsics.atomic_store_explicit(&s.looping, tl.state.looping, .Relaxed)
		intrinsics.atomic_store_explicit(&s.loop_start, transmute(u64)f64(tl.state.loop_start), .Relaxed)
		intrinsics.atomic_store_explicit(&s.loop_end, transmute(u64)f64(tl.state.loop_end), .Relaxed)
	}
}
