package transport

import "core:mem"

import "fire:core"
import tb "fire:timebase"

// Chunk tag of a saved clock.
CLOCK_TAG :: core.Tag{'C', 'L', 'C', 'K'}

// Saved-state ID of `midi_clock_create` nodes.
MIDI_CLOCK_TYPE_ID :: "fire.midi_clock"

@(private)
CLOCK_VERSION :: 1

// Control thread. Writes the clock as a CLOCK_TAG chunk: the live tempo and
// meter, the leader and tempo override, and every timeline with its tempo
// map, rate, position and loop, as last asked for (commands still waiting
// for their beat included). Positions are the timelines' current ones.
// A `Sync` is not saved.
save :: proc(c: ^Clock, w: ^core.State_Writer) -> core.Error {
	core.begin_chunk(w, CLOCK_TAG, CLOCK_VERSION)
	core.write_f64(w, c.set.tempo)
	core.write_u32(w, u32(c.set.meter.numerator))
	core.write_u32(w, u32(c.set.meter.denominator))
	core.write_bool(w, c.set.override)
	write_timeline(w, c.set.leader)
	count := 0
	for used in c.in_use do if used do count += 1
	core.write_int(w, count)
	for used, i in c.in_use {
		if !used do continue
		id := core.Timeline_Id{u32(i), c.generations[i]}
		l := c.lines_set[i]
		position := l.position
		if p, _, ok := timeline_status(c, id); ok do position = p
		write_timeline(w, id)
		core.write_f64(w, l.rate)
		core.write_f64(w, f64(position))
		core.write_bool(w, l.looping)
		core.write_f64(w, f64(l.loop_start))
		core.write_f64(w, f64(l.loop_end))
		write_map(w, l.tmap)
	}
	core.end_chunk(w)
	return w.err
}

// Control thread. Restores a clock saved by `save` into `c`, which should
// have no timelines yet (see `clear`): adds the timelines, stopped at their
// saved positions, and sets the tempo, meter, leader and override, all at
// the next block. Returns how saved timeline IDs map to the new ones (for
// `core.Load_Context.timelines`), allocated with `allocator`.
// `.Invalid_Data` for a malformed chunk; `.Out_Of_Memory` if the timelines
// do not fit in `max_timelines` or the command queue.
load :: proc(c: ^Clock, chunk: core.Chunk, allocator := context.allocator) -> (remap: []core.Timeline_Remap, err: core.Error) {
	if chunk.tag != CLOCK_TAG do return nil, .Invalid_Data
	r := core.chunk_reader(chunk)
	tempo := core.read_f64(&r)
	meter := tb.Meter{i32(core.read_u32(&r)), i32(core.read_u32(&r))}
	override := core.read_bool(&r)
	leader := read_timeline(&r)
	count := core.read_int(&r)
	if r.err != .None || count < 0 || count > len(c.in_use) do return nil, .Invalid_Data
	out := make([dynamic]core.Timeline_Remap, allocator)
	defer if err != .None {
		for m in out do remove_timeline(c, m.now)
		delete(out)
	}
	for _ in 0 ..< count {
		saved := read_timeline(&r)
		rate := core.read_f64(&r)
		position := tb.Beats(core.read_f64(&r))
		looping := core.read_bool(&r)
		loop_start, loop_end := tb.Beats(core.read_f64(&r)), tb.Beats(core.read_f64(&r))
		m, has_map := read_map(&r)
		defer if has_map do tb.tempo_map_destroy(&m)
		if r.err != .None do return nil, .Invalid_Data
		id := add_timeline(c, &m if has_map else nil) or_return
		append(&out, core.Timeline_Remap{saved, id})
		if rate > 0 && rate != 1 do set_rate(c, id, rate) or_return
		if position != 0 do locate(c, id, position) or_return
		if looping do set_loop(c, id, loop_start, loop_end) or_return
	}
	if r.err != .None do return nil, .Invalid_Data
	if tempo >= MIN_BPM && tempo <= MAX_BPM do set_tempo(c, tempo) or_return
	if meter.numerator > 0 && meter.denominator > 0 do set_meter(c, meter, nil) or_return
	set_tempo_override(c, override) or_return
	for m in out do if m.saved == leader do set_leader(c, m.now) or_return
	return out[:], .None
}

// Control thread. Removes every timeline and clears the leader, ready for
// `load`.
clear :: proc(c: ^Clock) -> core.Error {
	for used, i in c.in_use do if used {
		remove_timeline(c, {u32(i), c.generations[i]}) or_return
	}
	return set_leader(c, {})
}

@(private)
write_timeline :: proc(w: ^core.State_Writer, id: core.Timeline_Id) {
	core.write_u32(w, id.index)
	core.write_u32(w, id.generation)
}

@(private)
read_timeline :: proc(r: ^core.State_Reader) -> core.Timeline_Id {
	return {core.read_u32(r), core.read_u32(r)}
}

@(private)
write_map :: proc(w: ^core.State_Writer, m: ^tb.Tempo_Map) {
	core.write_bool(w, m != nil)
	if m == nil do return
	core.write_int(w, len(m.tempos))
	for p in m.tempos {
		core.write_f64(w, f64(p.start))
		core.write_f64(w, p.bpm_start)
		core.write_f64(w, p.bpm_end)
	}
	core.write_int(w, len(m.meters))
	for p in m.meters {
		core.write_i64(w, p.bar)
		core.write_u32(w, u32(p.meter.numerator))
		core.write_u32(w, u32(p.meter.denominator))
	}
}

// Reads a map written by `write_map` into a new map (temp allocator).
@(private)
read_map :: proc(r: ^core.State_Reader) -> (m: tb.Tempo_Map, ok: bool) {
	if !core.read_bool(r) do return {}, false
	tempos := core.read_int(r)
	if tempos <= 0 || tempos > len(r.data) / 24 {
		r.err = .Invalid_Data
		return {}, false
	}
	a := context.temp_allocator
	m.tempos = make([dynamic]tb.Tempo_Point, 0, tempos, a)
	for _ in 0 ..< tempos do append(&m.tempos, tb.Tempo_Point{tb.Beats(core.read_f64(r)), core.read_f64(r), core.read_f64(r)})
	meters := core.read_int(r)
	if meters <= 0 || meters > len(r.data) / 16 {
		r.err = .Invalid_Data
		return {}, false
	}
	m.meters = make([dynamic]tb.Meter_Point, 0, meters, a)
	for _ in 0 ..< meters do append(&m.meters, tb.Meter_Point{core.read_i64(r), {i32(core.read_u32(r)), i32(core.read_u32(r))}})
	if r.err != .None do return {}, false
	for p in m.tempos do if !(p.bpm_start >= MIN_BPM && p.bpm_start <= MAX_BPM) {
		r.err = .Invalid_Data
		return {}, false
	}
	for p in m.meters do if p.meter.numerator <= 0 || p.meter.denominator <= 0 {
		r.err = .Invalid_Data
		return {}, false
	}
	m.seconds_at = make([dynamic]tb.Seconds, a)
	m.meter_beats = make([dynamic]tb.Beats, a)
	tb.tempo_map_rebuild(&m)
	return m, true
}

// --- MIDI clock node -----------------------------------------------------------------------

// Registers this package's node types (the MIDI clock), so saved state can
// name them. Control thread.
register_types :: proc(reg: ^core.Node_Registry) -> core.Error {
	return core.register_type(reg, {id = MIDI_CLOCK_TYPE_ID, load = load_midi_clock})
}

@(private)
save_midi_clock :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	s := (^Midi_Clock)(self).settings
	write_timeline(w, s.follow)
	core.write_u8(w, s.port)
	core.write_bool(w, s.send_while_stopped)
	return .None
}

@(private)
load_midi_clock :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Midi_Clock_Settings
	s.follow = read_timeline(r)
	if s.follow != {} do s.follow = core.load_timeline(ctx, s.follow)
	s.port = core.read_u8(r)
	s.send_while_stopped = core.read_bool(r)
	return midi_clock_create(s, allocator), .None
}
