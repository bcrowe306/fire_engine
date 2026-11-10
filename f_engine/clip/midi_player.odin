package clip

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// Where a clip sits on its timeline.
//
// - Launcher: `{loop = true}`: the clip starts at the timeline's beat 0 and
//   repeats its loop for as long as the timeline plays.
// - Arrangement: `{at = 32, length = 16, offset = 4}`: on the timeline from
//   beat 32 for 16 beats, starting 4 beats into the clip; add `loop` to
//   repeat the clip's loop within those 16 beats.
Placement :: struct {
	at:     tb.Beats, // timeline position where playback of the clip begins
	length: tb.Beats, // how long it plays on the timeline; 0 = no end
	offset: tb.Beats, // clip position played at `at`
	loop:   bool,     // after reaching the clip's loop end, repeat loop_start..loop_end
}

// Settings for `midi_player_create`.
Midi_Player_Settings :: struct {
	timeline:   core.Timeline_Id, // the timeline it follows
	max_notes:  int, // notes sounding at once; 0 = 256 (more are dropped and counted)
	max_events: int, // events per process call; 0 = 1024 (more are dropped and counted)
	seed:       u64, // for notes' `probability`: the same seed, the same choices (0 = a fixed default)
}

// Plays a `Midi_Clip` on a timeline as note and controller events. It is a
// graph node (0 audio channels): event-connect it to an instrument.
//
// Notes land on their exact frame. On a stop, every sounding note ends; on a
// start, jump, loop wrap or entry into the clip, notes already in progress
// start at once with what remains of them ("chasing"). Notes are cut at the
// clip's loop end and at the end of the placement. Each note gets its own
// `core.Note_Id`, which its expression events and note-off carry.
//
// Fields are internal.
Midi_Player :: struct {
	settings:  Midi_Player_Settings,
	allocator: mem.Allocator,
	// Control thread.
	live:      [dynamic]^Player_Config, // configs not yet freed
	// Control → audio, and back.
	pending:   ^Player_Config, // atomic
	retired:   rt.Spsc_Queue(^Player_Config),
	// Audio thread.
	config:     ^Player_Config,
	sounding:   []Sounding,
	count:      int,
	scratch:    []core.Event,
	events:     int,
	next_id:    core.Note_Id,
	rng:        u64, // probability rolls (xorshift64*), from `settings.seed` at each reset
	window_end: tb.Beats, // last timeline position handled (inclusive)
	continuous: bool,     // the previous call played and nothing has jumped since
	dropped:    u64,      // atomic: notes or events that did not fit
	// Control thread: a clip from a loader, set once prepared.
	deferred: Deferred(^Midi_Clip),
}

@(private)
Player_Config :: struct {
	clip:      ^Midi_Clip,
	placement: Placement,
}

@(private)
Sounding :: struct {
	id:      core.Note_Id,
	key:     u8,
	channel: u8,
	release: f32,
	start:   tb.Beats, // timeline position where the note (not its chased part) began
	end:     tb.Beats, // timeline position of its note-off
	expr:    int, // next expression point (index into the clip's), or -1
	expr_end: int,
}

// Control thread. Creates a player node and a handle for controlling it.
// Give the node to the graph (`graph.add_node(g, node, 0, 0)`); the handle
// stays valid until the graph destroys the node.
midi_player_create :: proc(settings: Midi_Player_Settings, allocator := context.allocator) -> (node: core.Node, player: ^Midi_Player) {
	p := new(Midi_Player, allocator)
	p.settings, p.allocator = settings, allocator
	if p.settings.max_notes <= 0 do p.settings.max_notes = 256
	if p.settings.max_events <= 0 do p.settings.max_events = 1024
	p.next_id = 1
	if p.settings.seed == 0 do p.settings.seed = 0x9E3779B97F4A7C15
	p.rng = p.settings.seed
	p.live = make([dynamic]^Player_Config, allocator)
	return core.node_make(&midi_player_vtable, p, allocator), p
}

// Control thread. Plays `clip` (nil: nothing) placed as `placement`, from
// the player's next block. The player keeps its own reference to the clip.
// Notes already sounding finish normally.
midi_player_set :: proc(p: ^Midi_Player, clip: ^Midi_Clip, placement: Placement) -> core.Error {
	collect(p)
	pl := placement
	if clip != nil && pl.loop {
		pl.offset = clamp(pl.offset, 0, clip.loop_end - 1e-9) // a loop needs a start before its end
	}
	cfg := new(Player_Config, p.allocator)
	if cfg == nil do return .Out_Of_Memory
	cfg^ = {clip = clip, placement = pl}
	midi_clip_retain(clip)
	append(&p.live, cfg)
	old := intrinsics.atomic_exchange(&p.pending, cfg)
	if old != nil do retire_now(p, old) // never adopted
	return .None
}

// Any thread. Notes or events dropped because `max_notes` or `max_events`
// was full.
midi_player_dropped :: proc "contextless" (p: ^Midi_Player) -> u64 {
	return intrinsics.atomic_load(&p.dropped)
}

// --- node ----------------------------------------------------------------------------------

@(private)
midi_player_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		p := (^Midi_Player)(self)
		ae: mem.Allocator_Error
		p.sounding, ae = make([]Sounding, p.settings.max_notes, a)
		if ae != nil do return .Out_Of_Memory
		p.scratch, ae = make([]core.Event, p.settings.max_events, a)
		if ae != nil do return .Out_Of_Memory
		if rt.spsc_init(&p.retired, 64, a) != nil do return .Out_Of_Memory
		if p.deferred.set {
			d := p.deferred
			p.deferred = {}
			err := midi_player_set(p, d.clip, d.placement)
			midi_clip_release(d.clip)
			return err
		}
		return .None
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		p := (^Midi_Player)(self)
		delete(p.sounding, a)
		delete(p.scratch, a)
		rt.spsc_destroy(&p.retired, a)
		p.sounding, p.scratch = nil, nil
	},
	reset = proc(self: rawptr) {
		p := (^Midi_Player)(self)
		p.count, p.continuous = 0, false
		p.rng = p.settings.seed
	},
	process = midi_player_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {
		p := (^Midi_Player)(self)
		if p.deferred.set do midi_clip_release(p.deferred.clip) // never prepared
		for cfg in p.live {
			midi_clip_release(cfg.clip)
			free(cfg, p.allocator)
		}
		delete(p.live)
		free(p, a)
	},
	type_id = MIDI_PLAYER_TYPE_ID,
	state_version = 1,
	save    = save_midi_player,
}

// Frees configs the audio thread has finished with.
@(private)
collect :: proc(p: ^Midi_Player) {
	if p.retired.buffer == nil do return // not prepared yet
	for cfg in rt.spsc_pop(&p.retired) do retire_now(p, cfg)
}

@(private)
retire_now :: proc(p: ^Midi_Player, cfg: ^Player_Config) {
	for c, i in p.live do if c == cfg {
		unordered_remove(&p.live, i)
		break
	}
	midi_clip_release(cfg.clip)
	free(cfg, p.allocator)
}

// [rt]
@(private)
midi_player_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	p := (^Midi_Player)(self)
	if intrinsics.atomic_load(&p.pending) != nil && rt.spsc_len(&p.retired) < rt.spsc_capacity(&p.retired) {
		cfg := intrinsics.atomic_exchange(&p.pending, nil)
		if cfg != nil {
			if p.config != nil do rt.spsc_push(&p.retired, p.config)
			p.config = cfg
			for &s in p.sounding[:p.count] do s.expr = -1 // their clip may go away
		}
	}
	p.events = 0
	defer flush(p, ctx)

	t := ctx.transport
	tl := core.transport_timeline(t, p.settings.timeline) if t != nil else nil
	if tl == nil || !tl.playing || ctx.frames <= 0 {
		all_off(p, 0)
		p.continuous = false
		return
	}
	fresh := !p.continuous || .Jumped in tl.flags || .Started in tl.flags
	if fresh do all_off(p, 0)
	lo := tl.position if fresh else p.window_end
	hi := core.timeline_position_at(t, tl, ctx.frames - 1)
	w := Window{t = t, tl = tl, frames = ctx.frames, lo = lo, hi = hi, lo_closed = fresh}

	// Notes sounding from before: their expression, then their ends, so
	// note-offs come before note-ons at the same frame.
	expressions(p, &w)
	ends(p, &w)
	if p.config != nil && p.config.clip != nil do walk(p, &w, p.config.clip, p.config.placement, fresh)
	// Notes that started in this window.
	expressions(p, &w)
	ends(p, &w)
	p.window_end = hi
	p.continuous = true
}

// The timeline span this call covers, (lo, hi] (or [lo, hi] after a jump).
@(private)
Window :: struct {
	t:         ^core.Transport,
	tl:        ^core.Timeline_State,
	frames:    int,
	lo, hi:    tb.Beats,
	lo_closed: bool,
}

@(private)
in_window :: #force_inline proc "contextless" (w: ^Window, b: tb.Beats) -> bool {
	return (b > w.lo || (w.lo_closed && b >= w.lo)) && b <= w.hi
}

@(private)
offset_of :: #force_inline proc "contextless" (w: ^Window, b: tb.Beats) -> int {
	return clamp(core.timeline_offset_of(w.t, w.tl, b), 0, w.frames - 1)
}

// Plays the clip through the window, piece by piece. A piece is a stretch
// where clip time runs straight: the part before the loop, then each loop
// iteration. Pieces are anchored at exact positions computed from the
// iteration number, never from the window, so every call maps a note to the
// same timeline position.
@(private)
walk :: proc "contextless" (p: ^Midi_Player, w: ^Window, c: ^Midi_Clip, pl: Placement, fresh: bool) {
	region_end := pl.at + pl.length if pl.length > 0 else tb.Beats(math.F64_MAX)
	loop_len := c.loop_end - c.loop_start
	looping := pl.loop && loop_len > 0
	// The straight part: from `at` (clip `offset`) up to the loop end, or the clip end.
	first_end := c.loop_end if looping else c.length
	loops_from := pl.at + (first_end - pl.offset) // timeline position of loop iteration 0

	pos := max(w.lo, pl.at)
	chase_at := w.lo if fresh else tb.Beats(-math.F64_MAX) // chase only at discontinuities
	if w.lo < pl.at do chase_at = pl.at                    // entering the clip
	for guard := 0; guard < 100_000 && pos <= w.hi && pos < region_end; guard += 1 {
		pa, ca, cb, floor: tb.Beats
		if !looping || pos < loops_from {
			pa, ca, cb = pl.at, pl.offset, first_end // floor 0: a trimmed start chases notes begun before it
		} else {
			k := math.floor(f64(pos - loops_from) / f64(loop_len))
			pa = loops_from + tb.Beats(k * f64(loop_len))
			if pa + loop_len <= pos do pa += loop_len // rounding at a boundary
			ca, cb, floor = c.loop_start, c.loop_end, c.loop_start
			if pa > w.lo && pa <= w.hi do chase_at = pa // a wrap inside this call
		}
		pb := min(pa + (cb - ca), region_end)
		if chase_at >= pa && chase_at < pb && in_window(w, chase_at) {
			chase(p, w, c, pa, ca, chase_at, pb, floor)
		}
		starts(p, w, c, pa, ca, cb, pb)
		controllers(p, w, c, pa, ca, cb, pb)
		if pb <= pos do break // a degenerate piece; can't advance
		pos = pb
		chase_at = pos if looping && pos < region_end else tb.Beats(-math.F64_MAX)
	}
}

// Note-ons for notes starting in clip span [ca, cb), placed from `pa`.
@(private)
starts :: proc "contextless" (p: ^Midi_Player, w: ^Window, c: ^Midi_Clip, pa, ca, cb, pb: tb.Beats) {
	// Notes are sorted by start: find the first at or after `ca`.
	lo_i, hi_i := 0, len(c.notes)
	for lo_i < hi_i {
		mid := (lo_i + hi_i) / 2
		if c.notes[mid].start < ca {
			lo_i = mid + 1
		} else {
			hi_i = mid
		}
	}
	for i in lo_i ..< len(c.notes) {
		n := &c.notes[i]
		if n.start >= cb do break
		b := pa + (n.start - ca)
		if b > w.hi do break
		if b >= pb || !in_window(w, b) do continue
		note_on(p, w, c, i, b, min(b + n.length, pb), b)
	}
}

// Notes in progress at `at` (clip span [ca, cb) placed from `pa`) start now.
// Only notes from `floor` on count: in a loop iteration, the loop's own
// notes (`floor` = loop start), not ones that began before the loop.
@(private)
chase :: proc "contextless" (p: ^Midi_Player, w: ^Window, c: ^Midi_Clip, pa, ca, at, pb, floor: tb.Beats) {
	clip_at := ca + (at - pa)
	for &n, i in c.notes {
		if n.start >= clip_at do break
		if n.start < floor || n.start + n.length <= clip_at do continue
		start := pa + (n.start - ca) // where it began on the timeline (may be before the piece)
		end := min(start + n.length, pb)
		if end <= at do continue
		note_on(p, w, c, i, at, end, start)
	}
}

@(private)
note_on :: proc "contextless" (p: ^Midi_Player, w: ^Window, c: ^Midi_Clip, index: int, at, end, began: tb.Beats) {
	if p.count == len(p.sounding) {
		intrinsics.atomic_add(&p.dropped, 1)
		return
	}
	n := &c.notes[index]
	if n.probability < 1 && roll(p) >= n.probability do return // not this time round
	id := p.next_id
	p.next_id = p.next_id + 1 if p.next_id < max(core.Note_Id) else 1
	offset := offset_of(w, at)
	emit(p, offset, core.Note_On{id = id, channel = n.channel, key = n.key, velocity = n.velocity})
	s := Sounding{id = id, key = n.key, channel = n.channel, release = n.release, start = began, end = end,
		expr = n.expression[0], expr_end = n.expression[0] + n.expression[1]}
	// A chased note takes the latest value of each expression up to now.
	if at > began {
		latest: [core.Note_Expression_Kind]int
		for &l in latest do l = -1
		for s.expr < s.expr_end && began + c.expression[s.expr].at <= at {
			latest[c.expression[s.expr].kind] = s.expr
			s.expr += 1
		}
		for k, kind in latest do if k >= 0 {
			emit(p, offset, core.Note_Expression{id = id, channel = n.channel, key = n.key, kind = kind, value = c.expression[k].value})
		}
	}
	p.sounding[p.count] = s
	p.count += 1
}

// A uniform number in [0, 1).
@(private)
roll :: proc "contextless" (p: ^Midi_Player) -> f32 {
	x := p.rng
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	p.rng = x
	return f32((x * 0x2545F4914F6CDD1D) >> 40) / f32(1 << 24)
}

// Note-offs for sounding notes that end in this window.
@(private)
ends :: proc "contextless" (p: ^Midi_Player, w: ^Window) {
	for i := 0; i < p.count; {
		s := &p.sounding[i]
		if s.end <= w.hi {
			emit(p, offset_of(w, s.end), core.Note_Off{id = s.id, channel = s.channel, key = s.key, velocity = s.release})
			p.sounding[i] = p.sounding[p.count - 1]
			p.count -= 1
			continue
		}
		i += 1
	}
}

// Expression points due in this window, for notes still sounding.
@(private)
expressions :: proc "contextless" (p: ^Midi_Player, w: ^Window) {
	if p.config == nil || p.config.clip == nil do return
	c := p.config.clip
	for &s in p.sounding[:p.count] {
		if s.expr < 0 do continue
		for s.expr < s.expr_end {
			e := c.expression[s.expr]
			b := s.start + e.at
			if b > w.hi do break
			s.expr += 1
			if b >= s.end || !in_window(w, b) do continue
			emit(p, offset_of(w, b), core.Note_Expression{id = s.id, channel = s.channel, key = s.key, kind = e.kind, value = e.value})
		}
	}
}

// Controller events in clip span [ca, cb) placed from `pa`.
@(private)
controllers :: proc "contextless" (p: ^Midi_Player, w: ^Window, c: ^Midi_Clip, pa, ca, cb, pb: tb.Beats) {
	for e in c.controllers {
		if e.at < ca do continue
		if e.at >= cb do break
		b := pa + (e.at - ca)
		if b >= pb || !in_window(w, b) do continue
		emit(p, offset_of(w, b), core.Midi_Raw{bytes = e.bytes})
	}
}

@(private)
all_off :: proc "contextless" (p: ^Midi_Player, offset: int) {
	for s in p.sounding[:p.count] {
		emit(p, offset, core.Note_Off{id = s.id, channel = s.channel, key = s.key, velocity = s.release})
	}
	p.count = 0
}

@(private)
emit :: proc "contextless" (p: ^Midi_Player, offset: int, payload: core.Event_Payload) {
	if p.events == len(p.scratch) {
		intrinsics.atomic_add(&p.dropped, 1)
		return
	}
	p.scratch[p.events] = {u32(offset), payload}
	p.events += 1
}

// Sorts this call's events by offset (stable: note-offs that were due come
// before note-ons at the same frame) and hands them on.
@(private)
flush :: proc "contextless" (p: ^Midi_Player, ctx: ^core.Process_Context) {
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
