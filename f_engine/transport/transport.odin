/*
The engine's musical clock and its timelines.

One `Clock` keeps a beat grid that always advances at the current tempo.
Any number of timelines (an arrangement, launched clips, loopers, step
sequencer patterns) follow the grid, and each one plays, stops, loops and
jumps on its own, quantized to the grid. One timeline can lead: its tempo map
then sets the tempo and the bar lines.

Control the clock from the control thread; call `process` from the audio
callback. It splits each block at loop wraps, starts, stops and tempo or meter
changes, and runs your graph once per piece, so nodes always see continuous
time.

	clock, _ := transport.create(transport.default_settings(48_000))
	defer transport.destroy(clock)

	song, _ := transport.add_timeline(clock)
	transport.set_leader(clock, song)
	transport.set_loop(clock, song, 0, 16)  // a 4-bar loop
	transport.play(clock, song)

	clip, _ := transport.add_timeline(clock)
	transport.play(clock, clip, tb.Quantize.Bar)  // starts on the next downbeat

	// in the audio callback:
	transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
		graph.process((^graph.Graph)(user), seg)
	}, g, b.output_ns)

Nodes read the clock from `ctx.transport` (see `core.Transport`). See
/guides/transport/ for a walk-through and /design/transport/ for how it works.
*/
package transport

import "base:intrinsics"
import "core:mem"
import "core:slice"

import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// Clock-wide settings, fixed for the clock's lifetime. Start from
// `default_settings`.
Settings :: struct {
	sample_rate:   f64,      // Hz; create a new clock if the device rate changes
	bpm:           f64,      // initial live tempo
	meter:         tb.Meter, // initial live meter
	max_timelines: int,      // timelines that can exist at once
	max_scheduled: int,      // commands waiting for their beat (more are dropped and counted)
	command_queue: int,      // commands in flight from the control thread
	max_events:    int,      // input events per block when a block is split (more are dropped and counted)
}

// 120 BPM in 4/4, room for 64 timelines.
default_settings :: proc(sample_rate: f64) -> Settings {
	return {
		sample_rate   = sample_rate,
		bpm           = 120,
		meter         = {4, 4},
		max_timelines = 64,
		max_scheduled = 256,
		command_queue = 1024,
		max_events    = 1024,
	}
}

// When a command takes effect. `nil` is the start of the next block; a
// `tb.Quantize` value is the next boundary of that length on the bar grid
// (counted from the current bar's downbeat, so `.Bar` is the next downbeat
// and a command arriving exactly on a boundary takes effect there); `At_Beat`
// is an exact grid beat (a past beat means the next block).
When :: union {
	tb.Quantize,
	At_Beat,
}

// An exact position on the clock's grid, for `When`.
At_Beat :: distinct tb.Beats

// Shortest loop `set_loop` accepts, in beats.
MIN_LOOP :: tb.Beats(1.0 / 64)

// Tempo range accepted by `set_tempo`, in BPM.
MIN_BPM :: 1.0
// Tempo range accepted by `set_tempo`, in BPM.
MAX_BPM :: 999.0

// A clock. Create with `create`; all procs except `process` are control
// thread only (one thread). Fields are internal.
Clock :: struct {
	settings:  Settings,
	allocator: mem.Allocator,

	// Control thread.
	generations: []u32, // per slot: current generation, 0 = never used
	in_use:      []bool,
	maps:        [dynamic]^tb.Tempo_Map, // every map copy not yet freed
	seq:         u64,

	// Control → audio.
	commands: rt.Spsc_Queue(Command),
	// Audio → control.
	retired:  rt.Spsc_Queue(^tb.Tempo_Map),

	// Audio thread.
	using audio: Audio_State,

	// Written by the audio thread, read anywhere.
	status_frame:   i64, // atomic
	status_grid:    u64, // atomic; f64 bits
	status_tempo:   u64, // atomic; f64 bits
	status_bar:     i64, // atomic
	status_meter:   u64, // atomic: numerator << 32 | denominator
	status_timelines: []Timeline_Status_Atomic,
	dropped_commands: u64, // atomic
	dropped_events:   u64, // atomic
}

// What the control thread can read about the clock (see `status`). Values are
// from the end of a recent block.
Status :: struct {
	frame:     tb.Sample_Time, // reference frames processed
	grid:      tb.Beats,       // grid position
	tempo_bpm: f64,            // current tempo
	bar:       i64,            // 0-based bar of the bar grid (the leader's, when one plays)
	meter:     tb.Meter,       // the meter of that bar
}

// Counters for things the audio thread dropped instead of allocating.
Stats :: struct {
	dropped_commands: u64, // quantized commands that did not fit in `max_scheduled`
	dropped_events:   u64, // input events beyond `max_events` in a split block
}

@(private)
Timeline_Status_Atomic :: struct {
	position:   u64, // atomic; f64 bits
	playing:    bool, // atomic
	looping:    bool, // atomic
	loop_start: u64, // atomic; f64 bits
	loop_end:   u64, // atomic; f64 bits
}

@(private)
Command_Kind :: enum u8 {
	Add,
	Remove,
	Set_Map,
	Play,
	Stop,
	Locate,
	Set_Loop,
	Clear_Loop,
	Set_Rate,
	Set_Tempo,
	Set_Meter,
	Set_Leader,
	Set_Override,
	Set_Sync,
}

@(private)
Command :: struct {
	kind:     Command_Kind,
	timeline: core.Timeline_Id,
	when_:    When,
	a, b:     tb.Beats,
	value:    f64,
	meter:    tb.Meter,
	tmap:     ^tb.Tempo_Map,
	flag:     bool,
	sync:     Sync,
	// Set by the audio thread when scheduling.
	at:       tb.Beats,
	seq:      u64,
}

// Control thread. Allocates a clock and everything it needs while running.
// Free with `destroy`.
create :: proc(settings: Settings, allocator := context.allocator) -> (c: ^Clock, err: core.Error) {
	s := settings
	if s.sample_rate <= 0 || s.bpm < MIN_BPM || s.bpm > MAX_BPM || s.max_timelines <= 0 ||
	   s.meter.numerator <= 0 || s.meter.denominator <= 0 {
		return nil, .Invalid_Argument
	}
	c = new(Clock, allocator)
	if c == nil do return nil, .Out_Of_Memory
	c.settings, c.allocator = s, allocator
	if err = init_all(c); err != .None {
		destroy(c)
		return nil, err
	}
	audio_init(c)
	return c, .None
}

@(private)
init_all :: proc(c: ^Clock) -> core.Error {
	s, a := c.settings, c.allocator
	ae: mem.Allocator_Error
	c.generations, ae = make([]u32, s.max_timelines, a)
	if ae != nil do return .Out_Of_Memory
	c.in_use, ae = make([]bool, s.max_timelines, a)
	if ae != nil do return .Out_Of_Memory
	c.maps, ae = make([dynamic]^tb.Tempo_Map, a)
	if ae != nil do return .Out_Of_Memory
	c.status_timelines, ae = make([]Timeline_Status_Atomic, s.max_timelines, a)
	if ae != nil do return .Out_Of_Memory
	c.timelines, ae = make([]Timeline, s.max_timelines, a)
	if ae != nil do return .Out_Of_Memory
	c.snapshot, ae = make([]core.Timeline_State, s.max_timelines, a)
	if ae != nil do return .Out_Of_Memory
	c.schedule, ae = make([]Command, max(s.max_scheduled, 1), a)
	if ae != nil do return .Out_Of_Memory
	c.events, ae = make([]core.Event, max(s.max_events, 1), a)
	if ae != nil do return .Out_Of_Memory
	if rt.spsc_init(&c.commands, max(s.command_queue, 16), a) != nil do return .Out_Of_Memory
	if rt.spsc_init(&c.retired, max(s.command_queue, 16) + s.max_timelines, a) != nil do return .Out_Of_Memory
	return .None
}

// Control thread. Frees the clock, its timelines and its tempo map copies.
// The audio thread must have stopped calling `process`.
destroy :: proc(c: ^Clock) {
	if c == nil do return
	a := c.allocator
	for m in c.maps do free_map(m, a)
	delete(c.maps)
	delete(c.generations, a)
	delete(c.in_use, a)
	delete(c.status_timelines, a)
	delete(c.timelines, a)
	delete(c.snapshot, a)
	delete(c.schedule, a)
	delete(c.events, a)
	rt.spsc_destroy(&c.commands, a)
	rt.spsc_destroy(&c.retired, a)
	free(c, a)
}

// Control thread. Frees tempo map copies the audio thread no longer uses.
// Call it now and then (say, once per UI frame).
collect :: proc(c: ^Clock) {
	for m in rt.spsc_pop(&c.retired) {
		if i, found := slice.linear_search(c.maps[:], m); found do unordered_remove(&c.maps, i)
		free_map(m, c.allocator)
	}
}

// --- timelines -------------------------------------------------------------------------

// Control thread. Adds a stopped timeline at position 0, rate 1, no loop. If
// `tempo_map` is given, a copy is made (see `set_tempo_map`). Takes effect at
// the next block. Fails with `.Out_Of_Memory` when `max_timelines` exist or
// the command queue is full.
add_timeline :: proc(c: ^Clock, tempo_map: ^tb.Tempo_Map = nil) -> (id: core.Timeline_Id, err: core.Error) {
	slot := -1
	for used, i in c.in_use do if !used {
		slot = i
		break
	}
	if slot < 0 do return {}, .Out_Of_Memory
	copy_ := copy_map(c, tempo_map) or_return
	c.generations[slot] += 1
	if c.generations[slot] == 0 do c.generations[slot] = 1
	id = {u32(slot), c.generations[slot]}
	if !push(c, {kind = .Add, timeline = id, tmap = copy_}) {
		c.generations[slot] -= 1
		return {}, .Out_Of_Memory
	}
	c.in_use[slot] = true
	return id, .None
}

// Control thread. Removes a timeline at the next block; its ID becomes
// invalid at once. Removing the leader leaves the clock without one.
remove_timeline :: proc(c: ^Clock, id: core.Timeline_Id) -> core.Error {
	check(c, id) or_return
	if !push(c, {kind = .Remove, timeline = id}) do return .Out_Of_Memory
	c.in_use[id.index] = false
	return .None
}

// Control thread. Gives a timeline its own tempo map: its tempos (when it
// leads) and its meters and bars. The map is copied, so keep editing yours
// and set it again; nil removes it. Takes effect at the next block.
set_tempo_map :: proc(c: ^Clock, id: core.Timeline_Id, tempo_map: ^tb.Tempo_Map) -> core.Error {
	check(c, id) or_return
	copy_ := copy_map(c, tempo_map) or_return
	if !push(c, {kind = .Set_Map, timeline = id, tmap = copy_}) do return .Out_Of_Memory
	return .None
}

// Control thread. Starts a timeline from its current position. No effect if
// it is already playing.
play :: proc(c: ^Clock, id: core.Timeline_Id, at: When = nil) -> core.Error {
	return command(c, {kind = .Play, timeline = id, when_ = at})
}

// Control thread. Stops a timeline, keeping its position.
stop :: proc(c: ^Clock, id: core.Timeline_Id, at: When = nil) -> core.Error {
	return command(c, {kind = .Stop, timeline = id, when_ = at})
}

// Control thread. Moves a timeline to local position `beat`. A playing
// timeline keeps playing from there; a stopped one starts there when played.
locate :: proc(c: ^Clock, id: core.Timeline_Id, beat: tb.Beats, at: When = nil) -> core.Error {
	return command(c, {kind = .Locate, timeline = id, when_ = at, a = beat})
}

// Control thread. Loops a timeline between local beats `start` and `end`
// (at least `MIN_LOOP` apart). A timeline already past `end` plays on and
// does not wrap until it is located back inside.
set_loop :: proc(c: ^Clock, id: core.Timeline_Id, start, end: tb.Beats, at: When = nil) -> core.Error {
	if end - start < MIN_LOOP do return .Invalid_Argument
	return command(c, {kind = .Set_Loop, timeline = id, when_ = at, a = start, b = end})
}

// Control thread. Stops a timeline looping.
clear_loop :: proc(c: ^Clock, id: core.Timeline_Id, at: When = nil) -> core.Error {
	return command(c, {kind = .Clear_Loop, timeline = id, when_ = at})
}

// Control thread. Sets how many local beats a timeline advances per grid
// beat (> 0): 2 is double time, 0.5 half time. Ignored for the leader, which
// always runs at 1.
set_rate :: proc(c: ^Clock, id: core.Timeline_Id, rate: f64, at: When = nil) -> core.Error {
	if !(rate > 0) do return .Invalid_Argument
	return command(c, {kind = .Set_Rate, timeline = id, when_ = at, value = rate})
}

// Control thread. Sets the live tempo (`MIN_BPM` to `MAX_BPM`). It is the
// tempo unless a leader with a tempo map is playing, or always while
// `set_tempo_override` is on.
set_tempo :: proc(c: ^Clock, bpm: f64, at: When = nil) -> core.Error {
	if !(bpm >= MIN_BPM && bpm <= MAX_BPM) do return .Invalid_Argument
	return push_command(c, {kind = .Set_Tempo, when_ = at, value = bpm})
}

// Control thread. Sets the live meter, which makes the bar grid while no
// leader is playing. A new bar starts where it takes effect (by default the
// next downbeat).
set_meter :: proc(c: ^Clock, meter: tb.Meter, at: When = tb.Quantize.Bar) -> core.Error {
	if meter.numerator <= 0 || meter.denominator <= 0 do return .Invalid_Argument
	return push_command(c, {kind = .Set_Meter, when_ = at, meter = meter})
}

// Control thread. Makes `id` the leader (the zero ID: no leader). While the
// leader plays, its bars are the bar grid and, if it has a tempo map, the
// map sets the tempo. When it stops, the live tempo and meter carry on from
// where it was.
set_leader :: proc(c: ^Clock, id: core.Timeline_Id, at: When = nil) -> core.Error {
	if id != {} do check(c, id) or_return
	return push_command(c, {kind = .Set_Leader, timeline = id, when_ = at})
}

// Control thread. While on, the live tempo wins over the leader's tempo map
// (its meters still apply): for tap tempo or an external clock.
set_tempo_override :: proc(c: ^Clock, on: bool, at: When = nil) -> core.Error {
	return push_command(c, {kind = .Set_Override, when_ = at, flag = on})
}

// An outside clock the engine follows, such as Ableton Link (`fire:link`).
// At the start of every block the clock calls `begin_block`, which may take
// over the tempo and the grid position. While a sync is set, its tempo wins
// over tempo maps and the live tempo (meters still apply); report local tempo
// changes to the outside clock from `begin_block` (see
// `Sync_Block.desired_bpm`).
Sync :: struct {
	begin_block: proc(user: rawptr, b: ^Sync_Block), // [rt]
	user:        rawptr,
}

// What `Sync.begin_block` sees and returns.
Sync_Block :: struct {
	// In.
	frame:       tb.Sample_Time, // reference frame of the block's first frame
	frames:      int,            // frames in the block
	sample_rate: f64,
	host_ns:     u64,            // presentation time of the first frame; 0 = unknown
	grid:        tb.Beats,       // where the clock would be without correction
	// The tempo the clock would use without sync: the live tempo, or the
	// playing leader's map. It differs from the `bpm` returned last block
	// only after a local change (`set_tempo`, a map tempo point); push it to
	// the outside clock then.
	desired_bpm: f64,
	// Out. Leave `ok` false to change nothing this block.
	ok:          bool,
	bpm:         f64,      // the tempo for this block
	beat:        tb.Beats, // the grid position at the first frame
}

// Grid corrections larger than this (in beats) count as a jump: playing
// timelines are shifted with the grid so they continue smoothly, and
// `core.Transport_Flag.Grid_Jumped` is set. Smaller ones are followed silently.
SYNC_JUMP :: tb.Beats(1.0 / 96)

// Control thread. Makes the clock follow `sync` from the next block; a zero
// `Sync` stops following, and the live tempo carries on from the outside
// clock's. When a sync starts, the clock's bar grid restarts at grid beat 0,
// so bars line up with peers that agree on grid phase (as Link's quantum does).
set_sync :: proc(c: ^Clock, sync: Sync) -> core.Error {
	return push_command(c, {kind = .Set_Sync, sync = sync})
}

// --- status ----------------------------------------------------------------------------

// Any thread. The clock as of a recent block end.
status :: proc "contextless" (c: ^Clock) -> Status {
	return {
		frame     = tb.Sample_Time(intrinsics.atomic_load_explicit(&c.status_frame, .Relaxed)),
		grid      = tb.Beats(transmute(f64)intrinsics.atomic_load_explicit(&c.status_grid, .Relaxed)),
		tempo_bpm = transmute(f64)intrinsics.atomic_load_explicit(&c.status_tempo, .Relaxed),
		bar       = intrinsics.atomic_load_explicit(&c.status_bar, .Relaxed),
		meter     = unpack_meter(intrinsics.atomic_load_explicit(&c.status_meter, .Relaxed)),
	}
}

@(private)
unpack_meter :: proc "contextless" (v: u64) -> tb.Meter {
	if v == 0 do return {4, 4} // before the first block
	return {i32(v >> 32), i32(v & 0xFFFF_FFFF)}
}

// Control thread. A timeline's position and play state as of a recent block
// end. ok = false for an unknown ID, or one added so recently that no block
// has run since.
timeline_status :: proc(c: ^Clock, id: core.Timeline_Id) -> (position: tb.Beats, playing: bool, ok: bool) {
	if check(c, id) != .None do return
	s := &c.status_timelines[id.index]
	position = tb.Beats(transmute(f64)intrinsics.atomic_load_explicit(&s.position, .Relaxed))
	playing = intrinsics.atomic_load_explicit(&s.playing, .Relaxed)
	return position, playing, true
}

// Control thread. Whether a timeline loops, and between which local beats,
// as of a recent block end (`ok` as for `timeline_status`). For displays:
// start and end are read separately, so a change can show half-applied
// for one read.
timeline_loop :: proc(c: ^Clock, id: core.Timeline_Id) -> (looping: bool, start, end: tb.Beats, ok: bool) {
	if check(c, id) != .None do return
	s := &c.status_timelines[id.index]
	looping = intrinsics.atomic_load_explicit(&s.looping, .Relaxed)
	start = tb.Beats(transmute(f64)intrinsics.atomic_load_explicit(&s.loop_start, .Relaxed))
	end = tb.Beats(transmute(f64)intrinsics.atomic_load_explicit(&s.loop_end, .Relaxed))
	return looping, start, end, true
}

// Any thread. Counts of things dropped on the audio thread.
stats :: proc "contextless" (c: ^Clock) -> Stats {
	return {
		dropped_commands = intrinsics.atomic_load_explicit(&c.dropped_commands, .Relaxed),
		dropped_events   = intrinsics.atomic_load_explicit(&c.dropped_events, .Relaxed),
	}
}

// --- internals -------------------------------------------------------------------------

@(private)
check :: proc(c: ^Clock, id: core.Timeline_Id) -> core.Error {
	if int(id.index) >= len(c.in_use) || !c.in_use[id.index] || c.generations[id.index] != id.generation {
		return .Invalid_Argument
	}
	return .None
}

@(private)
command :: proc(c: ^Clock, cmd: Command) -> core.Error {
	check(c, cmd.timeline) or_return
	return push_command(c, cmd)
}

@(private)
push_command :: proc(c: ^Clock, cmd: Command) -> core.Error {
	return .None if push(c, cmd) else .Out_Of_Memory // queue full: the audio thread is not running or far behind
}

@(private)
push :: proc(c: ^Clock, cmd: Command) -> bool {
	cmd := cmd
	c.seq += 1
	cmd.seq = c.seq
	return rt.spsc_push(&c.commands, cmd)
}

@(private)
copy_map :: proc(c: ^Clock, src: ^tb.Tempo_Map) -> (m: ^tb.Tempo_Map, err: core.Error) {
	if src == nil do return nil, .None
	a := c.allocator
	m = new(tb.Tempo_Map, a)
	if m == nil do return nil, .Out_Of_Memory
	e1, e2, e3, e4: mem.Allocator_Error
	m.tempos, e1 = slice.clone_to_dynamic(src.tempos[:], a)
	m.meters, e2 = slice.clone_to_dynamic(src.meters[:], a)
	m.seconds_at, e3 = slice.clone_to_dynamic(src.seconds_at[:], a)
	m.meter_beats, e4 = slice.clone_to_dynamic(src.meter_beats[:], a)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || append(&c.maps, m) == 0 {
		free_map(m, a)
		return nil, .Out_Of_Memory
	}
	return m, .None
}

@(private)
free_map :: proc(m: ^tb.Tempo_Map, a: mem.Allocator) {
	tb.tempo_map_destroy(m)
	free(m, a)
}
