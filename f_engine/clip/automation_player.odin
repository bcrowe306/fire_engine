package clip

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// Settings for `automation_player_create`.
Automation_Player_Settings :: struct {
	timeline:     core.Timeline_Id, // the timeline it follows
	max_events:   int, // events per process call; 0 = 1024 (more are dropped and counted)
	max_lanes:    int, // lanes it plays, and parameters suspended at once; 0 = 64
	curve_frames: int, // longest ramp along a curved segment, or under a tempo ramp; 0 = 64
}

// Plays an `Automation_Clip` on a timeline as parameter changes. It is a
// graph node (0 audio channels): event-connect it to the node whose
// parameters it moves (`graph.connect_events`). Each lane's `param` is a
// parameter of that node.
//
// While the timeline plays, each lane is sent as `core.Param_Ramp` events:
// straight segments as one ramp per block, curved ones (and everything
// under a tempo ramp) as ramps of at most `curve_frames`. Jumps (steps,
// points at the same position, loop wraps, starts and locates) are
// zero-length ramps, so they land on their exact frame. While it is
// stopped, a locate or a new clip sends each lane's value at the new
// position as a `core.Param_Value`. Outside the placement nothing is sent,
// so parameters keep their last value.
//
// To let the user take over a parameter, suspend its lane
// (`automation_player_suspend`); resume it with a glide back to the curve.
//
// Fields are internal.
Automation_Player :: struct {
	settings:    Automation_Player_Settings,
	allocator:   mem.Allocator,
	// Control thread.
	live:        [dynamic]^Automation_Config, // configs not yet freed
	// Control → audio, and back.
	pending:     ^Automation_Config, // atomic
	retired:     rt.Spsc_Queue(^Automation_Config),
	commands:    rt.Spsc_Queue(Override_Command),
	// Audio thread.
	sample_rate: f64,
	config:      ^Automation_Config,
	lanes:       []Lane_State, // per lane of the config's clip
	suspended:   []core.Param_Id,
	suspended_count: int,
	scratch:     []core.Event,
	events:      int,
	continuous:  bool, // the previous call ran and nothing has jumped since
	dropped:     u64,  // atomic: events that did not fit, or lanes beyond max_lanes
}

@(private)
Automation_Config :: struct {
	clip:      ^Automation_Clip,
	placement: Placement,
}

@(private)
Lane_State :: struct {
	known:      bool, // the parameter is where this lane last sent it
	glide:      int,  // frames left of a glide back after a resume
	glide_from: bool, // a glide starts this call
	glide_len:  int,
}

@(private)
Override_Command :: struct {
	param:    core.Param_Id,
	suspend:  bool,
	glide_ms: f64,
}

// Control thread. Creates a player node and a handle for controlling it.
// Give the node to the graph (`graph.add_node(g, node, 0, 0)`); the handle
// stays valid until the graph destroys the node.
automation_player_create :: proc(settings: Automation_Player_Settings, allocator := context.allocator) -> (node: core.Node, player: ^Automation_Player, err: core.Error) {
	p := new(Automation_Player, allocator)
	if p == nil do return {}, nil, .Out_Of_Memory
	p.settings, p.allocator = settings, allocator
	if p.settings.max_events <= 0 do p.settings.max_events = 1024
	if p.settings.max_lanes <= 0 do p.settings.max_lanes = 64
	if p.settings.curve_frames <= 0 do p.settings.curve_frames = 64
	p.live = make([dynamic]^Automation_Config, allocator)
	if rt.spsc_init(&p.commands, 256, allocator) != nil {
		delete(p.live)
		free(p, allocator)
		return {}, nil, .Out_Of_Memory
	}
	return core.node_make(&automation_player_vtable, p, allocator), p, .None
}

// Control thread. Plays `clip` (nil: nothing) placed as `placement`, from
// the player's next block. The player keeps its own reference to the clip.
automation_player_set :: proc(p: ^Automation_Player, clip: ^Automation_Clip, placement: Placement) -> core.Error {
	automation_collect(p)
	pl := placement
	if clip != nil && pl.loop do pl.offset = clamp(pl.offset, 0, clip.loop_end - 1e-9)
	cfg := new(Automation_Config, p.allocator)
	if cfg == nil do return .Out_Of_Memory
	cfg^ = {clip = clip, placement = pl}
	automation_clip_retain(clip)
	append(&p.live, cfg)
	old := intrinsics.atomic_exchange(&p.pending, cfg)
	if old != nil do automation_retire_now(p, old) // never adopted
	return .None
}

// Control thread. Stops sending `param`'s lane from the next block, so the
// parameter follows whatever else sets it (the user, through
// `graph.set_param`). `.Out_Of_Memory` if the command queue is full.
automation_player_suspend :: proc(p: ^Automation_Player, param: core.Param_Id) -> core.Error {
	return .None if rt.spsc_push(&p.commands, Override_Command{param = param, suspend = true}) else .Out_Of_Memory
}

// Control thread. Sends `param`'s lane again, gliding from wherever the
// parameter is to the curve over `glide_ms` (0: a jump).
automation_player_resume :: proc(p: ^Automation_Player, param: core.Param_Id, glide_ms: f64 = 50) -> core.Error {
	return .None if rt.spsc_push(&p.commands, Override_Command{param = param, glide_ms = max(glide_ms, 0)}) else .Out_Of_Memory
}

// Any thread. Events dropped because `max_events` was full, plus lanes
// beyond `max_lanes` (counted each call).
automation_player_dropped :: proc "contextless" (p: ^Automation_Player) -> u64 {
	return intrinsics.atomic_load(&p.dropped)
}

// --- node ----------------------------------------------------------------------------------

@(private)
automation_player_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		p := (^Automation_Player)(self)
		p.sample_rate = cfg.sample_rate
		ae1, ae2, ae3: mem.Allocator_Error
		p.lanes, ae1 = make([]Lane_State, p.settings.max_lanes, a)
		p.suspended, ae2 = make([]core.Param_Id, p.settings.max_lanes, a)
		p.scratch, ae3 = make([]core.Event, p.settings.max_events, a)
		if ae1 != nil || ae2 != nil || ae3 != nil do return .Out_Of_Memory
		if rt.spsc_init(&p.retired, 64, a) != nil do return .Out_Of_Memory
		return .None
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		p := (^Automation_Player)(self)
		delete(p.lanes, a)
		delete(p.suspended, a)
		delete(p.scratch, a)
		rt.spsc_destroy(&p.retired, a)
		p.lanes, p.suspended, p.scratch = nil, nil, nil
	},
	reset = proc(self: rawptr) {
		p := (^Automation_Player)(self)
		p.continuous = false
	},
	process = automation_player_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {
		p := (^Automation_Player)(self)
		for cfg in p.live {
			automation_clip_release(cfg.clip)
			free(cfg, p.allocator)
		}
		delete(p.live)
		rt.spsc_destroy(&p.commands, p.allocator)
		free(p, a)
	},
}

@(private)
automation_collect :: proc(p: ^Automation_Player) {
	if p.retired.buffer == nil do return // not prepared yet
	for cfg in rt.spsc_pop(&p.retired) do automation_retire_now(p, cfg)
}

@(private)
automation_retire_now :: proc(p: ^Automation_Player, cfg: ^Automation_Config) {
	for c, i in p.live do if c == cfg {
		unordered_remove(&p.live, i)
		break
	}
	automation_clip_release(cfg.clip)
	free(cfg, p.allocator)
}

// [rt]
@(private)
automation_player_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	p := (^Automation_Player)(self)
	adopted := false
	if intrinsics.atomic_load(&p.pending) != nil && rt.spsc_len(&p.retired) < rt.spsc_capacity(&p.retired) {
		cfg := intrinsics.atomic_exchange(&p.pending, nil)
		if cfg != nil {
			if p.config != nil do rt.spsc_push(&p.retired, p.config)
			p.config = cfg
			adopted = true
			for &l in p.lanes do l = {}
		}
	}
	for cmd in rt.spsc_pop(&p.commands) do apply_command(p, cmd)
	p.events = 0
	defer automation_flush(p, ctx)

	t := ctx.transport
	tl := core.transport_timeline(t, p.settings.timeline) if t != nil else nil
	if tl == nil || ctx.frames <= 0 {
		p.continuous = false
		return
	}
	fresh := adopted || !p.continuous || .Jumped in tl.flags || .Started in tl.flags
	p.continuous = true
	if p.config == nil || p.config.clip == nil do return
	c := p.config.clip
	if len(c.lanes) > len(p.lanes) do intrinsics.atomic_add(&p.dropped, u64(len(c.lanes) - len(p.lanes)))
	for &lane, i in c.lanes[:min(len(c.lanes), len(p.lanes))] {
		st := &p.lanes[i]
		if is_suspended(p, lane.param) do continue
		if fresh do st.known = false
		from := 0
		if st.glide_from {
			st.glide_from = false
			// Toward where the curve will be when the glide ends.
			ahead := tl.position
			if tl.playing do ahead += tb.Beats(f64(st.glide_len) * tl.rate * t.tempo_bpm / 60 / t.sample_rate)
			if v, inside := placed_value(p.config, &lane, ahead); inside {
				emit_param(p, 0, core.Param_Ramp{param = lane.param, target = v, frames = u32(st.glide_len)})
				st.known, st.glide = true, st.glide_len
			}
		}
		if st.glide > 0 {
			if st.glide >= ctx.frames {
				st.glide -= ctx.frames
				continue
			}
			from, st.glide = st.glide, 0
		}
		if !tl.playing {
			if !st.known {
				if v, inside := placed_value(p.config, &lane, tl.position); inside {
					emit_param(p, 0, core.Param_Value{param = lane.param, value = v})
					st.known = true
				}
			}
			continue
		}
		play_lane(p, t, tl, ctx.frames, &lane, st, from)
	}
}

@(private)
apply_command :: proc "contextless" (p: ^Automation_Player, cmd: Override_Command) {
	at := -1
	for q, i in p.suspended[:p.suspended_count] do if q == cmd.param do at = i
	lane := -1
	if p.config != nil && p.config.clip != nil {
		for &l, i in p.config.clip.lanes do if l.param == cmd.param && i < len(p.lanes) do lane = i
	}
	if cmd.suspend {
		if at < 0 && p.suspended_count < len(p.suspended) {
			p.suspended[p.suspended_count] = cmd.param
			p.suspended_count += 1
		}
		if lane >= 0 do p.lanes[lane] = {}
		return
	}
	if at >= 0 {
		p.suspended[at] = p.suspended[p.suspended_count - 1]
		p.suspended_count -= 1
	}
	if lane >= 0 {
		frames := int(math.round(cmd.glide_ms * 0.001 * p.sample_rate))
		p.lanes[lane] = {glide_from = frames > 0, glide_len = frames} // no glide: a jump, as after a locate
	}
}

@(private)
is_suspended :: proc "contextless" (p: ^Automation_Player, param: core.Param_Id) -> bool {
	for q in p.suspended[:p.suspended_count] do if q == param do return true
	return false
}

// A lane's value at timeline position `at`, if the placement covers it.
@(private)
placed_value :: proc "contextless" (cfg: ^Automation_Config, l: ^Automation_Lane, at: tb.Beats) -> (f64, bool) {
	c, pl := cfg.clip, cfg.placement
	if at < pl.at || (pl.length > 0 && at >= pl.at + pl.length) do return 0, false
	pos := pl.offset + (at - pl.at)
	loop_len := c.loop_end - c.loop_start
	if pl.loop && loop_len > 0 && pos >= c.loop_end {
		pos = c.loop_start + tb.Beats(math.mod(f64(pos - c.loop_start), f64(loop_len)))
	}
	return automation_value(l, pos), true
}

// Sends one lane through this call, from frame `from`, piece by piece as
// the MIDI player walks a clip: the part before the loop, then each loop
// iteration, anchored at exact positions.
@(private)
play_lane :: proc "contextless" (p: ^Automation_Player, t: ^core.Transport, tl: ^core.Timeline_State, frames: int, l: ^Automation_Lane, st: ^Lane_State, from: int) {
	if len(l.points) == 0 do return
	c, pl := p.config.clip, p.config.placement
	p0 := core.timeline_position_at(t, tl, from)
	p1 := core.timeline_position_at(t, tl, frames)
	region_end := pl.at + pl.length if pl.length > 0 else tb.Beats(math.F64_MAX)
	loop_len := c.loop_end - c.loop_start
	looping := pl.loop && loop_len > 0
	first_end := c.loop_end if looping else c.length
	loops_from := pl.at + (first_end - pl.offset)
	straight := t.tempo_slope == 0

	pos := max(p0, pl.at)
	for guard := 0; guard < 100_000 && pos < p1 && pos < region_end; guard += 1 {
		pa, ca, cb: tb.Beats
		if !looping || pos < loops_from {
			pa, ca, cb = pl.at, pl.offset, first_end
		} else {
			k := math.floor(f64(pos - loops_from) / f64(loop_len))
			pa = loops_from + tb.Beats(k * f64(loop_len))
			if pa + loop_len <= pos do pa += loop_len // rounding at a boundary
			ca, cb = c.loop_start, c.loop_end
		}
		pb := min(pa + (cb - ca), region_end)
		if pb <= pos do break // a degenerate piece; can't advance
		if pos == pa do st.known = false // entering the clip, or a loop wrap (even on this call's first frame)

		// Segment by segment through this piece's part of the call.
		piece_end := min(p1, pb)
		cs, ce := ca + (pos - pa), ca + (piece_end - pa)
		for guard2 := 0; guard2 < 100_000 && cs < ce; guard2 += 1 {
			i := segment_at(l, cs)
			seg_end := ce
			if i + 1 < len(l.points) && l.points[i + 1].at < seg_end do seg_end = l.points[i + 1].at
			fa := from if pa + (cs - ca) <= p0 else frame_at(t, tl, pa + (cs - ca), from, frames)
			fb := frames if seg_end == ce && piece_end == p1 else frame_at(t, tl, pa + (seg_end - ca), from, frames)
			// A jump where the curve isn't continuous.
			if !st.known || (i >= 0 && cs == l.points[i].at && left_value(l, cs) != l.points[i].value) {
				if fa < frames {
					emit_param(p, fa, core.Param_Ramp{param = l.param, target = at_frame(t, tl, l, i, pa, ca, cs, seg_end, fa), frames = 0})
					st.known = true
				}
			}
			moving := i >= 0 && i + 1 < len(l.points) && l.points[i].shape != .Step
			if moving && fb > fa {
				if l.points[i].shape == .Linear && straight {
					emit_param(p, fa, core.Param_Ramp{param = l.param, target = at_frame(t, tl, l, i, pa, ca, cs, seg_end, fb), frames = u32(fb - fa)})
				} else {
					for f := fa; f < fb; f += p.settings.curve_frames {
						f2 := min(f + p.settings.curve_frames, fb)
						emit_param(p, f, core.Param_Ramp{param = l.param, target = at_frame(t, tl, l, i, pa, ca, cs, seg_end, f2), frames = u32(f2 - f)})
					}
				}
			}
			if seg_end <= cs do break
			cs = seg_end
		}
		pos = pb
	}
}

// Segment `i`'s value at frame `f` of this call, kept within [lo, hi] (the
// part of the segment being sent).
@(private)
at_frame :: proc "contextless" (t: ^core.Transport, tl: ^core.Timeline_State, l: ^Automation_Lane, i: int, pa, ca, lo, hi: tb.Beats, f: int) -> f64 {
	return segment_value(l, i, clamp(ca + (core.timeline_position_at(t, tl, f) - pa), lo, hi))
}

// The value just before `at`: the end of the segment leading into it.
@(private)
left_value :: proc "contextless" (l: ^Automation_Lane, at: tb.Beats) -> f64 {
	lo, hi := 0, len(l.points)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.points[mid].at < at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return segment_value(l, lo - 1, at)
}

// The first frame (within [from, frames]) at or after timeline position `b`.
@(private)
frame_at :: #force_inline proc "contextless" (t: ^core.Transport, tl: ^core.Timeline_State, b: tb.Beats, from, frames: int) -> int {
	return clamp(core.timeline_offset_of(t, tl, b), from, frames)
}

@(private)
emit_param :: proc "contextless" (p: ^Automation_Player, offset: int, payload: core.Event_Payload) {
	if p.events == len(p.scratch) {
		intrinsics.atomic_add(&p.dropped, 1)
		return
	}
	p.scratch[p.events] = {u32(offset), payload}
	p.events += 1
}

// Sorts this call's events by offset (stable, so each lane's stay in
// order) and hands them on.
@(private)
automation_flush :: proc "contextless" (p: ^Automation_Player, ctx: ^core.Process_Context) {
	ev := p.scratch[:p.events]
	for i in 1 ..< len(ev) {
		e := ev[i]
		j := i
		for j > 0 && ev[j - 1].offset > e.offset {
			ev[j] = ev[j - 1]
			j -= 1
		}
		ev[j] = e
	}
	if ctx.events_out != nil do for e in ev do core.event_writer_push(ctx.events_out, e)
}
