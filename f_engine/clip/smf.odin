package clip

import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

import tb "fire:timebase"

// Result of reading or writing a MIDI file.
File_Error :: enum u8 {
	None,
	Not_Found,
	Io_Error,
	Corrupt,     // not a valid Standard MIDI File, or cut short
	Unsupported, // SMPTE time division, or format 2
	Out_Of_Memory,
}

// One track of a MIDI file, as a clip.
Midi_File_Track :: struct {
	name: string,      // the track's name, if it has one
	clip: ^Midi_Clip,  // its notes and controllers; may have no notes
}

// The contents of a Standard MIDI File. Free with `midi_file_destroy`.
Midi_File :: struct {
	tracks:    []Midi_File_Track, // one per track that has notes or controllers (format 0: one)
	tempo_map: tb.Tempo_Map,      // the file's tempo and time signature changes
	ppq:       int,               // the file's ticks per quarter note
	allocator: mem.Allocator,
}

// Reads a type 0 or 1 Standard MIDI File. Each track with notes or
// controllers becomes a clip (all channels kept, notes paired in order),
// as long as the longest track, rounded up to a whole bar. Tempo and time
// signature changes go into `tempo_map`. SysEx and other meta events are
// skipped.
midi_file_read :: proc(path: string, allocator := context.allocator) -> (mf: Midi_File, err: File_Error) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return {}, .Not_Found
	return midi_file_parse(data, allocator)
}

// Like `midi_file_read`, from bytes already in memory.
midi_file_parse :: proc(data: []u8, allocator := context.allocator) -> (mf: Midi_File, err: File_Error) {
	r := Byte_Reader{data = data}
	if string(take(&r, 4) or_return) != "MThd" do return {}, .Corrupt
	header_len := int(be32(&r) or_return)
	format := int(be16(&r) or_return)
	ntracks := int(be16(&r) or_return)
	division := int(be16(&r) or_return)
	take(&r, header_len - 6) or_return
	if division & 0x8000 != 0 do return {}, .Unsupported // SMPTE
	if format > 1 do return {}, .Unsupported
	if division == 0 do return {}, .Corrupt
	ppq := f64(division)

	mf.allocator, mf.ppq = allocator, division
	tb.tempo_map_init(&mf.tempo_map, 120, {4, 4}, allocator)
	tracks := make([dynamic]Midi_File_Track, allocator)
	builders := make([dynamic]Parsed_Track, context.temp_allocator)
	tempos := make([dynamic]Timed_Value, context.temp_allocator)
	meters := make([dynamic]Timed_Value, context.temp_allocator)
	song_end: tb.Beats

	for _ in 0 ..< ntracks {
		if r.pos + 8 > len(r.data) do break
		id := string(take(&r, 4) or_return)
		size := int(be32(&r) or_return)
		body := take(&r, size) or_return
		if id != "MTrk" do continue
		pt := parse_track(body, ppq, &tempos, &meters) or_return
		song_end = max(song_end, pt.end)
		append(&builders, pt)
	}

	// Tempo and meter changes, in order.
	slice.stable_sort_by(tempos[:], proc(a, b: Timed_Value) -> bool { return a.at < b.at })
	slice.stable_sort_by(meters[:], proc(a, b: Timed_Value) -> bool { return a.at < b.at })
	for tv in tempos do tb.tempo_map_set_tempo(&mf.tempo_map, tv.at, 60_000_000 / tv.value)
	for tv in meters {
		bbt := tb.beats_to_bbt(&mf.tempo_map, tv.at)
		bar := bbt.bar + (1 if bbt.beat != 0 || bbt.tick != 0 else 0) // changes take effect on a bar line
		tb.tempo_map_set_meter(&mf.tempo_map, bar, {i32(tv.value), tv.denominator})
	}
	// Every clip as long as the song, rounded up to a whole bar.
	length := song_end
	if length > 0 {
		bbt := tb.beats_to_bbt(&mf.tempo_map, length)
		if bbt.beat != 0 || bbt.tick != 0 do length = tb.bbt_to_beats(&mf.tempo_map, {bbt.bar + 1, 0, 0})
	} else {
		length = 4
	}
	for &pt in builders {
		defer midi_builder_destroy(&pt.builder)
		if len(pt.builder.notes) == 0 && len(pt.builder.controllers) == 0 do continue
		pt.builder.length, pt.builder.loop_start, pt.builder.loop_end = length, 0, length
		c, berr := midi_build(&pt.builder, allocator)
		if berr != .None {
			mf.tracks = tracks[:]
			midi_file_destroy(&mf)
			return {}, .Out_Of_Memory
		}
		append(&tracks, Midi_File_Track{strings.clone(pt.name, allocator), c})
	}
	mf.tracks = tracks[:]
	return mf, .None
}

// Frees what `midi_file_read` returned, releasing its clips (clips retained
// elsewhere live on).
midi_file_destroy :: proc(mf: ^Midi_File) {
	for t in mf.tracks {
		delete(t.name, mf.allocator)
		midi_clip_release(t.clip)
	}
	delete(mf.tracks, mf.allocator)
	tb.tempo_map_destroy(&mf.tempo_map)
	mf^ = {}
}

// Writes a type 1 Standard MIDI File: a conductor track with the tempo
// map's tempos and time signatures (ramps written as steps every eighth
// note; nil: 120 BPM in 4/4), then one track per clip with its name, notes
// and controllers. Per-note expression has no MIDI 1.0 form and is not
// written. Times are rounded to `ppq` ticks per quarter note.
midi_file_write :: proc(path: string, tracks: []Midi_File_Track, tempo_map: ^tb.Tempo_Map = nil, ppq := 960) -> File_Error {
	if ppq <= 0 || ppq > 0x7FFF do return .Corrupt
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..transmute([]u8)string("MThd"))
	put32(&out, 6)
	put16(&out, 1)
	put16(&out, u16(len(tracks) + 1))
	put16(&out, u16(ppq))

	// Conductor track.
	events := make([dynamic]Out_Event, context.temp_allocator)
	tick :: proc(b: tb.Beats, ppq: int) -> i64 { return i64(math.round(f64(b) * f64(ppq))) }
	if tempo_map != nil {
		for p, i in tempo_map.tempos {
			next := tempo_map.tempos[i + 1].start if i + 1 < len(tempo_map.tempos) else p.start
			if p.bpm_end != p.bpm_start && next > p.start {
				for b := p.start; b < next; b += 0.5 do append(&events, tempo_event(tick(b, ppq), tb.tempo_at(tempo_map, b)))
			} else {
				append(&events, tempo_event(tick(p.start, ppq), p.bpm_start))
			}
		}
		for i in 0 ..< len(tempo_map.meters) {
			m := tempo_map.meters[i].meter
			dd := u8(0)
			for d := m.denominator; d > 1; d >>= 1 do dd += 1
			append(&events, Out_Event{tick(tempo_map.meter_beats[i], ppq), 1, {0xFF, 0x58, 4, u8(m.numerator), dd, 24, 8}, 7})
		}
	} else {
		append(&events, tempo_event(0, 120))
	}
	write_track(&out, "", events[:])

	for t in tracks {
		clear(&events)
		if t.clip != nil {
			for n in t.clip.notes {
				on := tick(n.start, ppq)
				off := max(tick(n.start + n.length, ppq), on + 1)
				append(&events, short_event(on, 3, {0x90 | n.channel, n.key, u8(clamp(math.round(f64(n.velocity) * 127), 1, 127))}, 3))
				append(&events, short_event(off, 2, {0x80 | n.channel, n.key, u8(math.round(f64(n.release) * 127))}, 3))
			}
			for c in t.clip.controllers {
				size := 2 if c.bytes[0] & 0xF0 == 0xC0 || c.bytes[0] & 0xF0 == 0xD0 else 3
				append(&events, short_event(tick(c.at, ppq), 2, c.bytes, size))
			}
		}
		write_track(&out, t.name, events[:])
	}
	if os.write_entire_file(path, out[:]) != nil do return .Io_Error
	return .None
}

// --- reading ---------------------------------------------------------------------------------

@(private)
Byte_Reader :: struct {
	data: []u8,
	pos:  int,
}

@(private)
take :: proc(r: ^Byte_Reader, n: int) -> (b: []u8, err: File_Error) {
	if n < 0 || r.pos + n > len(r.data) do return nil, .Corrupt
	b = r.data[r.pos:r.pos + n]
	r.pos += n
	return
}

@(private)
be16 :: proc(r: ^Byte_Reader) -> (v: u16, err: File_Error) {
	b := take(r, 2) or_return
	return u16(b[0]) << 8 | u16(b[1]), .None
}

@(private)
be32 :: proc(r: ^Byte_Reader) -> (v: u32, err: File_Error) {
	b := take(r, 4) or_return
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3]), .None
}

// MIDI variable-length quantity.
@(private)
vlq :: proc(r: ^Byte_Reader) -> (v: u32, err: File_Error) {
	for _ in 0 ..< 4 {
		b := take(r, 1) or_return
		v = v << 7 | u32(b[0] & 0x7F)
		if b[0] & 0x80 == 0 do return v, .None
	}
	return 0, .Corrupt
}

@(private)
Timed_Value :: struct {
	at:          tb.Beats,
	value:       f64, // µs per quarter (tempo) or numerator (meter)
	denominator: i32,
}

@(private)
Parsed_Track :: struct {
	name:    string,
	builder: Midi_Builder,
	end:     tb.Beats,
}

@(private)
parse_track :: proc(body: []u8, ppq: f64, tempos, meters: ^[dynamic]Timed_Value) -> (pt: Parsed_Track, err: File_Error) {
	midi_builder_init(&pt.builder, 1, context.temp_allocator)
	r := Byte_Reader{data = body}
	ticks: u64
	status: u8
	Open :: struct {
		key:      u8,
		channel:  u8,
		velocity: f32,
		start:    tb.Beats,
	}
	open := make([dynamic]Open, context.temp_allocator)
	for r.pos < len(r.data) {
		ticks += u64(vlq(&r) or_return)
		at := tb.Beats(f64(ticks) / ppq)
		pt.end = max(pt.end, at)
		first := (take(&r, 1) or_return)[0]
		if first & 0x80 != 0 {
			status = first
		} else {
			if status == 0 do return pt, .Corrupt // running status with nothing to run
			r.pos -= 1
		}
		switch {
		case status == 0xFF: // meta
			kind := (take(&r, 1) or_return)[0]
			size := int(vlq(&r) or_return)
			b := take(&r, size) or_return
			switch kind {
			case 0x03: if pt.name == "" do pt.name = string(b)
			case 0x51: if size == 3 do append(tempos, Timed_Value{at, f64(u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2])), 0})
			case 0x58: if size >= 2 do append(meters, Timed_Value{at, f64(b[0]), i32(1) << b[1]})
			case 0x2F: r.pos = len(r.data) // end of track
			}
			status = 0 // meta and SysEx cancel running status
		case status == 0xF0 || status == 0xF7: // SysEx: skipped
			take(&r, int(vlq(&r) or_return)) or_return
			status = 0
		case:
			ch := status & 0x0F
			size := 1 if status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0 else 2
			b := take(&r, size) or_return
			kind := status & 0xF0
			switch {
			case kind == 0x90 && b[1] > 0:
				append(&open, Open{b[0], ch, f32(b[1]) / 127, at})
			case kind == 0x80 || kind == 0x90: // note-off, or note-on with velocity 0
				release := f32(b[1]) / 127 if kind == 0x80 else 0.5
				for o, i in open do if o.key == b[0] && o.channel == ch {
					add_note(&pt.builder, o.start, at - o.start, o.key, o.velocity, o.channel, release)
					ordered_remove(&open, i)
					break
				}
			case:
				bytes := [3]u8{status, b[0], b[1] if size == 2 else 0}
				add_controller(&pt.builder, at, bytes)
			}
		}
	}
	for o in open do add_note(&pt.builder, o.start, max(pt.end - o.start, 1e-3), o.key, o.velocity, o.channel) // never released: end with the track
	return pt, .None
}

// --- writing ---------------------------------------------------------------------------------

// An event to write: its tick, an order for events on the same tick
// (tempo and meter, note-offs, then note-ons), and its bytes.
@(private)
Out_Event :: struct {
	tick:  i64,
	order: int,
	bytes: [7]u8,
	len:   int,
}

@(private)
short_event :: proc(tick: i64, order: int, b: [3]u8, size: int) -> Out_Event {
	return {tick, order, {b[0], b[1], b[2], 0, 0, 0, 0}, size}
}

@(private)
tempo_event :: proc(tick: i64, bpm: f64) -> Out_Event {
	us := u32(math.round(60_000_000 / bpm))
	return {tick, 0, {0xFF, 0x51, 3, u8(us >> 16), u8(us >> 8), u8(us), 0}, 6}
}

// Writes one MTrk chunk: the track name (if any), then the events in time
// order (stable, by `order` within a tick), then End of Track.
@(private)
write_track :: proc(out: ^[dynamic]u8, name: string, events: []Out_Event) {
	slice.stable_sort_by(events, proc(a, b: Out_Event) -> bool {
		return a.tick < b.tick || (a.tick == b.tick && a.order < b.order)
	})
	body := make([dynamic]u8, context.temp_allocator)
	if name != "" {
		putvlq(&body, 0)
		append(&body, 0xFF, 0x03)
		putvlq(&body, u32(len(name)))
		append(&body, ..transmute([]u8)name)
	}
	last: i64
	for &e in events {
		putvlq(&body, u32(max(e.tick - last, 0)))
		last = max(e.tick, last)
		append(&body, ..e.bytes[:e.len])
	}
	putvlq(&body, 0)
	append(&body, 0xFF, 0x2F, 0x00)
	append(out, ..transmute([]u8)string("MTrk"))
	put32(out, u32(len(body)))
	append(out, ..body[:])
}

@(private)
put16 :: proc(out: ^[dynamic]u8, v: u16) {
	append(out, u8(v >> 8), u8(v))
}

@(private)
put32 :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private)
putvlq :: proc(out: ^[dynamic]u8, v: u32) {
	buf: [5]u8
	x := v
	buf[0] = u8(x & 0x7F)
	n := 1
	for x >>= 7; x > 0; x >>= 7 {
		buf[n] = u8(x & 0x7F) | 0x80
		n += 1
	}
	for i := n - 1; i >= 0; i -= 1 do append(out, buf[i])
}
