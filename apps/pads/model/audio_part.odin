package pads_model

import "core:math"
import "core:slice"

import app "app:core"
import fc "fire:core"

// An audio track's part in one sequence, edited without touching its
// files: the takes recorded (or pasted) into it, and regions of them
// placed in the sequence. Where regions overlap, the later one is heard
// (its fades cross into what is under it). The engine plays a rendering of
// it (see `comp_source`); `consolidate` writes one as a new take.
//
// A clip with no part (`Clip.part == 0`) plays its sample whole from the
// sequence's top: what recording made before parts, and what freezes and
// bounces make. The first edit gives it a part.

// Takes a part keeps (the oldest that no region plays goes first).
MAX_TAKES :: 16
// Regions a part has.
MAX_REGIONS :: 32
// Undo keys of parts: their ids from here (clear of pads', buses' and clips').
@(private)
PART_KEY :: app.Id(1 << 40)

// Fades new edges get (seconds): enough that a cut never clicks.
EDGE_FADE :: 0.002

// A region of a take placed in the sequence.
Region :: struct {
	take:     u8,   // which of the part's takes
	mute:     bool,
	reverse:  bool, // the region plays backwards
	at:       f64,  // where it starts: beats into the sequence
	start, end: i64, // the take's frames it plays
	fade_in, fade_out: f32, // seconds
	gain:     f32,  // dB
	pan:      f32,  // -1..1 (balance)
}

// How a clip follows the tempo when it isn't the one it was recorded at.
Clip_Warp :: enum u8 {
	Repitch, // faster or slower, its pitch with it
	Stretch, // its pitch kept (and `transpose` applies)
}

// An audio track's part in a sequence (see the top of this file). A value.
Audio_Part :: struct {
	takes:      [MAX_TAKES]app.Id,
	take_at:    [MAX_TAKES]f64, // where each take was recorded: beats into the sequence
	take_count: int,
	regions:    [MAX_REGIONS]Region,
	count:      int,
	warp:       Clip_Warp,
	transpose:  f32, // semitones (Stretch)
}

// The part of pad `pad` in sequence `slot`: its own, or (no part yet) the
// one its clip implies (its sample whole at the top), or empty.
part_of :: proc(p: ^Project, slot, pad: int) -> Audio_Part {
	c := p.clips[slot][pad]
	if c.part != 0 {
		if x := app.store_get(&p.parts, c.part); x != nil do return x^
	}
	out: Audio_Part
	if s := app.store_get(&p.samples, c.sample); s != nil {
		out.takes[0], out.take_count = c.sample, 1
		out.regions[0] = {take = 0, at = 0, start = 0, end = s.frames}
		out.count = 1
	}
	return out
}

// Whether part `x` is its first take whole from the top, as recorded: it
// plays that file as it is (no rendering).
part_plain :: proc(x: Audio_Part, take_frames: i64) -> bool {
	if x.count != 1 || x.take_count < 1 || x.transpose != 0 || x.warp != .Repitch do return false
	r := x.regions[0]
	return r.take == 0 && r.at == 0 && r.start == 0 && r.end == take_frames && !r.mute && !r.reverse && r.gain == 0 && r.pan == 0 && r.fade_in == 0 && r.fade_out == 0
}

// Sets pad `pad`'s part in sequence `slot` to `x` (giving its clip a part
// first), undoably as `name`. Its clip's sample is the latest take, and
// its tempo the sequence's when it had none.
put_part :: proc(m: ^Model, slot, pad: int, name: string, x: Audio_Part) {
	if slot < 0 || slot >= SLOTS || pad < 0 || pad >= PADS do return
	p := &m.project
	x := x
	prune_takes(&x)
	c := p.clips[slot][pad]
	if c.bpm <= 0 do c.bpm = sequence_tempo(p, slot)
	c.sample = x.takes[x.take_count - 1] if x.take_count > 0 else 0
	if c.part == 0 {
		c.part = app.new_id(&p.ids)
		empty: Audio_Part
		app.set_value_big(&m.history, name, {PART_KEY + c.part, 0}, &empty, &x, apply_part)
	} else if old := app.store_get(&p.parts, c.part); old != nil {
		was := old^
		app.set_value_big(&m.history, name, {PART_KEY + c.part, 0}, &was, &x, apply_part)
	}
	if x.take_count == 0 do c = {} // (nothing left: an empty clip)
	set_clip(m, slot, pad, name, c)
	m.engine.audio_dirty = true
}

@(private)
apply_part :: proc(ctx: rawptr, key: app.Key, value: Audio_Part) {
	m := (^Model)(ctx)
	id := key.id - PART_KEY
	if x := app.store_get(&m.project.parts, id); x != nil do x^ = value
	else do app.store_add(&m.project.parts, id, value)
	m.engine.audio_dirty = true
}

// Drops the takes no region plays, oldest first, while there are more
// than half of MAX_TAKES (recent ones stay to choose from), renumbering.
@(private)
prune_takes :: proc(x: ^Audio_Part) {
	used :: proc(x: ^Audio_Part, k: int) -> bool {
		for r in x.regions[:x.count] do if int(r.take) == k do return true
		return false
	}
	for x.take_count > MAX_TAKES / 2 {
		drop := -1
		for k in 0 ..< x.take_count - 1 do if !used(x, k) {
			drop = k
			break
		}
		if drop < 0 do break
		for k in drop ..< x.take_count - 1 {
			x.takes[k], x.take_at[k] = x.takes[k + 1], x.take_at[k + 1]
		}
		x.take_count -= 1
		x.takes[x.take_count], x.take_at[x.take_count] = 0, 0
		for &r in x.regions[:x.count] do if int(r.take) > drop do r.take -= 1
	}
}

// Take frames per sequence beat for part regions of pad `pad`'s clip in
// `slot` (its tempo; the take's rate).
frames_per_beat_of :: proc(p: ^Project, slot, pad: int, take: app.Id) -> f64 {
	s := app.store_get(&p.samples, take)
	bpm := p.clips[slot][pad].bpm
	if bpm <= 0 do bpm = sequence_tempo(p, slot)
	rate := s.rate if s != nil else 48_000
	return rate * 60 / bpm
}

// The beats pad `pad`'s part in `slot` goes round in: its track's loop,
// or the sequence.
part_beats :: proc(p: ^Project, slot, pad: int) -> f64 {
	return track_beats(p, p.sequences[slot], pad)
}

// Where region `r` ends: beats into the sequence.
region_end :: proc(p: ^Project, slot, pad: int, x: ^Audio_Part, r: Region) -> f64 {
	return r.at + f64(r.end - r.start) / frames_per_beat_of(p, slot, pad, x.takes[r.take])
}

// --- edits (each one undo step) ----------------------------------------------------------

// Adds take `id` (recorded at beat `at` of the sequence) to part `x`, and
// a region of it there on top, as far as the sequence's end.
// False when the part is full.
@(private)
part_add_take :: proc(p: ^Project, slot, pad: int, x: ^Audio_Part, id: app.Id, at: f64) -> bool {
	s := app.store_get(&p.samples, id)
	if s == nil do return false
	if x.take_count >= MAX_TAKES {
		prune_takes(x)
		if x.take_count >= MAX_TAKES do return false
	}
	k := x.take_count
	x.takes[k], x.take_at[k] = id, at
	x.take_count += 1
	length := part_beats(p, slot, pad)
	fpb := frames_per_beat_of(p, slot, pad, id)
	// Up to the sequence's end (a longer file: the rest isn't heard; trim
	// it in, or move it, to hear another part).
	first := min(s.frames, i64(math.round((length - at) * fpb)))
	place(p, slot, pad, x, {take = u8(k), at = at, start = 0, end = first})
	return true
}

// Puts region `r` on top of part `x`, dropping regions it hides wholly.
@(private)
place :: proc(p: ^Project, slot, pad: int, x: ^Audio_Part, r: Region) {
	if r.end <= r.start do return
	a, b := r.at, r.at + f64(r.end - r.start) / frames_per_beat_of(p, slot, pad, x.takes[r.take])
	n := 0
	for q in x.regions[:x.count] {
		qa, qb := q.at, region_end(p, slot, pad, x, q)
		if qa >= a - 1e-9 && qb <= b + 1e-9 do continue // hidden
		x.regions[n] = q
		n += 1
	}
	x.count = n
	if x.count >= MAX_REGIONS do remove_region(x, 0) // (the bottom one goes)
	x.regions[x.count] = r
	x.count += 1
}

@(private)
remove_region :: proc(x: ^Audio_Part, i: int) {
	for k in i ..< x.count - 1 do x.regions[k] = x.regions[k + 1]
	x.count -= 1
	x.regions[x.count] = {}
}

// Region `r` cut at beat `b` (inside it): the part before and after, each
// with a short fade at the cut.
@(private)
cut_region :: proc(p: ^Project, slot, pad: int, x: ^Audio_Part, r: Region, b: f64) -> (left, right: Region) {
	fpb := frames_per_beat_of(p, slot, pad, x.takes[r.take])
	f := clamp(i64(math.round((b - r.at) * fpb)), 0, r.end - r.start)
	left, right = r, r
	if r.reverse {
		// (Backwards: the region's first beats are the take's last frames.)
		left.start = r.end - f
		right.end = r.end - f
	} else {
		left.end = r.start + f
		right.start = r.start + f
	}
	right.at = r.at + f64(f) / fpb
	left.fade_out = max(EDGE_FADE, 0)
	right.fade_in = max(EDGE_FADE, 0)
	return
}

// Splits every region of the part at beat `b`.
split_at :: proc(m: ^Model, slot, pad: int, b: f64) {
	app.seal(&m.history) // (a step of its own, not part of a drag before)
	p := &m.project
	x := part_of(p, slot, pad)
	if !split_part(p, slot, pad, &x, b) do return
	put_part(m, slot, pad, "Split", x)
	app.seal(&m.history)
}

@(private)
split_part :: proc(p: ^Project, slot, pad: int, x: ^Audio_Part, b: f64) -> bool {
	out: [MAX_REGIONS * 2]Region
	n := 0
	any := false
	for r in x.regions[:x.count] {
		if b > r.at + 1e-9 && b < region_end(p, slot, pad, x, r) - 1e-9 {
			l, rr := cut_region(p, slot, pad, x, r, b)
			out[n], out[n + 1] = l, rr
			n += 2
			any = true
		} else {
			out[n] = r
			n += 1
		}
	}
	if !any || n > MAX_REGIONS do return false
	copy(x.regions[:], out[:n])
	x.count = n
	return true
}

// Removes beats `a`..`b` of the part (what is there goes silent; nothing
// moves).
delete_range :: proc(m: ^Model, slot, pad: int, a, b: f64, name := "Delete") {
	app.seal(&m.history) // (a step of its own, not part of a drag before)
	p := &m.project
	x := part_of(p, slot, pad)
	if b <= a || !cut_part(p, slot, pad, &x, a, b, false) do return
	put_part(m, slot, pad, name, x)
	app.seal(&m.history)
}

// Keeps only beats `a`..`b` of the part.
crop_to :: proc(m: ^Model, slot, pad: int, a, b: f64) {
	app.seal(&m.history) // (a step of its own, not part of a drag before)
	p := &m.project
	x := part_of(p, slot, pad)
	if b <= a || !cut_part(p, slot, pad, &x, a, b, true) do return
	put_part(m, slot, pad, "Crop", x)
	app.seal(&m.history)
}

// Removes a..b from the part's regions (`keep`: removes all but a..b).
@(private)
cut_part :: proc(p: ^Project, slot, pad: int, x: ^Audio_Part, a, b: f64, keep: bool) -> bool {
	split_part(p, slot, pad, x, a)
	split_part(p, slot, pad, x, b)
	n := 0
	for r in x.regions[:x.count] {
		mid := (r.at + region_end(p, slot, pad, x, r)) / 2
		inside := mid > a && mid < b
		if inside != keep do continue
		x.regions[n] = r
		n += 1
	}
	changed := n != x.count
	for i in n ..< x.count do x.regions[i] = {}
	x.count = n
	return changed || keep
}

// Moves region `i` to start at beat `at` (on top of the others).
// `from`: the part as a drag began (moved from there each frame, so what
// the region passes over on the way stays).
move_region :: proc(m: ^Model, slot, pad, i: int, at: f64, from: ^Audio_Part = nil) {
	p := &m.project
	x := from^ if from != nil else part_of(p, slot, pad)
	if i < 0 || i >= x.count do return
	r := x.regions[i]
	length := part_beats(p, slot, pad)
	span := region_end(p, slot, pad, &x, r) - r.at
	r.at = clamp(at, 0, max(length - span, 0))
	remove_region(&x, i)
	place(p, slot, pad, &x, r)
	put_part(m, slot, pad, "Move Region", x)
}

// Trims region `i`'s start or end to beat `b` (within its take).
// (`from`: as for `move_region`.)
trim_region :: proc(m: ^Model, slot, pad, i: int, b: f64, end: bool, from: ^Audio_Part = nil) {
	p := &m.project
	x := from^ if from != nil else part_of(p, slot, pad)
	if i < 0 || i >= x.count do return
	r := &x.regions[i]
	s := app.store_get(&p.samples, x.takes[r.take])
	if s == nil do return
	fpb := frames_per_beat_of(p, slot, pad, x.takes[r.take])
	min_len := i64(fpb / 64) // (a 1/256 note at least)
	if end {
		f := r.start + i64(math.round((b - r.at) * fpb))
		r.end = clamp(f, r.start + min_len, s.frames)
	} else {
		d := i64(math.round((b - r.at) * fpb))
		ns := clamp(r.start + d, 0, r.end - min_len)
		r.at += f64(ns - r.start) / fpb
		r.start = ns
	}
	put_part(m, slot, pad, "Trim Region", x)
}

// Removes region `i` (what is under it plays again).
delete_region :: proc(m: ^Model, slot, pad, i: int) {
	app.seal(&m.history)
	x := part_of(&m.project, slot, pad)
	if i < 0 || i >= x.count do return
	remove_region(&x, i)
	put_part(m, slot, pad, "Delete Region", x)
	app.seal(&m.history)
}

// Changes region `i` to `r` (its fades, gain, pan, reverse, mute) as `name`.
set_region :: proc(m: ^Model, slot, pad, i: int, name: string, r: Region) {
	x := part_of(&m.project, slot, pad)
	if i < 0 || i >= x.count || x.regions[i] == r do return
	x.regions[i] = r
	put_part(m, slot, pad, name, x)
}

// Sets region `i`'s gain so its loudest frame is at 0 dB.
normalize_region :: proc(m: ^Model, slot, pad, i: int) {
	app.seal(&m.history) // (a step of its own, not part of a drag before)
	p := &m.project
	x := part_of(p, slot, pad)
	if i < 0 || i >= x.count do return
	r := x.regions[i]
	s := app.store_get(&p.samples, x.takes[r.take])
	if s == nil do return
	a, err := read_audio(s.path, context.temp_allocator)
	if err != .None do return
	peak: f32
	for c in a.channels do for v in c[clamp(int(r.start), 0, len(c)):clamp(int(r.end), 0, len(c))] do peak = max(peak, abs(v))
	if peak <= 1e-6 do return
	r.gain = -20 * f32(math.log10(f64(peak)))
	set_region(m, slot, pad, i, "Normalize", r)
	app.seal(&m.history)
}

// Sets the part's warp and transpose.
set_part_warp :: proc(m: ^Model, slot, pad: int, warp: Clip_Warp, transpose: f32) {
	x := part_of(&m.project, slot, pad)
	if x.count == 0 || (x.warp == warp && x.transpose == transpose) do return
	x.warp, x.transpose = warp, clamp(transpose, -24, 24)
	put_part(m, slot, pad, "Warp" if x.warp != warp else "Transpose", x)
}

// Plays take `k` for beats `a`..`b` (comping: the range from another
// pass), as far as the take reaches.
use_take :: proc(m: ^Model, slot, pad, k: int, a, b: f64) {
	app.seal(&m.history) // (a step of its own, not part of a drag before)
	p := &m.project
	x := part_of(p, slot, pad)
	if k < 0 || k >= x.take_count || b <= a do return
	s := app.store_get(&p.samples, x.takes[k])
	if s == nil do return
	fpb := frames_per_beat_of(p, slot, pad, x.takes[k])
	t0 := x.take_at[k]
	from := clamp(i64(math.round((a - t0) * fpb)), 0, s.frames)
	to := clamp(i64(math.round((b - t0) * fpb)), 0, s.frames)
	if to <= from do return
	at := t0 + f64(from) / fpb
	place(p, slot, pad, &x, {take = u8(k), at = at, start = from, end = to, fade_in = EDGE_FADE if from > 0 else 0, fade_out = EDGE_FADE if to < s.frames else 0})
	put_part(m, slot, pad, "Use Take", x)
	app.seal(&m.history)
}

// Regions copied: their takes with them (pasted into any audio track).
Audio_Clipboard :: struct {
	regions: [MAX_REGIONS]Region, // `at` from the copied range's start
	takes:   [MAX_REGIONS]app.Id, // each region's take
	count:   int,
	length:  f64, // the range copied, beats
	bpm:     f64, // its tempo
}

// Copies beats `a`..`b` of the part (the regions there, cut to it).
copy_range :: proc(m: ^Model, slot, pad: int, a, b: f64) -> (cb: Audio_Clipboard) {
	p := &m.project
	x := part_of(p, slot, pad)
	if b <= a do return
	cut_part(p, slot, pad, &x, a, b, true)
	for r in x.regions[:x.count] {
		if cb.count >= MAX_REGIONS do break
		q := r
		q.at -= a
		cb.regions[cb.count], cb.takes[cb.count] = q, x.takes[r.take]
		cb.count += 1
	}
	cb.length = b - a
	cb.bpm = p.clips[slot][pad].bpm
	return
}

// Pastes `cb` at beat `at` of pad `pad`'s part (on top, cut at the
// sequence's end). False if nothing went in.
paste_at :: proc(m: ^Model, slot, pad: int, cb: Audio_Clipboard, at: f64) -> bool {
	app.seal(&m.history) // (a step of its own, not part of a drag before)
	p := &m.project
	x := part_of(p, slot, pad)
	length := part_beats(p, slot, pad)
	any := false
	for i in 0 ..< cb.count {
		r := cb.regions[i]
		k := -1
		for t, j in x.takes[:x.take_count] do if t == cb.takes[i] do k = j
		if k < 0 {
			if x.take_count >= MAX_TAKES do continue
			k = x.take_count
			x.takes[k], x.take_at[k] = cb.takes[i], at + r.at
			x.take_count += 1
		}
		r.take = u8(k)
		r.at += at
		if r.at >= length do continue
		place(p, slot, pad, &x, r)
		any = true
	}
	if !any do return false
	cut_part(p, slot, pad, &x, length, length + 1e6, false) // (nothing past the end)
	put_part(m, slot, pad, "Paste", x)
	app.seal(&m.history)
	return true
}

// Region `i` at beat `b` of pad `pad`'s part, the topmost (-1: none).
region_at :: proc(p: ^Project, slot, pad: int, b: f64) -> int {
	x := part_of(p, slot, pad)
	for i := x.count - 1; i >= 0; i -= 1 {
		r := x.regions[i]
		if b >= r.at && b < region_end(p, slot, pad, &x, r) do return i
	}
	return -1
}

// Copies pad `from`'s clip in `from_slot` to pad `to` in `to_slot`: its
// part copied, not shared (one undo step, `name`).
copy_clip :: proc(m: ^Model, from_slot, from, to_slot, to: int, name: string) {
	c := m.project.clips[from_slot][from]
	if c.part == 0 {
		set_clip(m, to_slot, to, name, c)
		return
	}
	x := part_of(&m.project, from_slot, from)
	nc := c
	nc.part = 0
	set_clip(m, to_slot, to, name, nc)
	put_part(m, to_slot, to, name, x)
}

_ :: slice.contains

// Adds the audio file at `path` (imported into the project) to audio
// track `pad`'s part in `slot` as a take at beat `at`, on top (cut at the
// sequence's end). One undo step, "Add Take".
add_take_file :: proc(m: ^Model, slot, pad: int, path: string, at := 0.0) -> fc.Error {
	p := &m.project
	if slot < 0 || slot >= SLOTS || pad < 0 || pad >= PADS || p.pads[pad].kind != .Audio do return .Invalid_Argument
	app.seal(&m.history)
	app.begin(&m.history, "Add Take")
	defer app.end(&m.history)
	id := import_sample(m, path) or_return
	x := part_of(p, slot, pad)
	if p.clips[slot][pad].bpm <= 0 || x.take_count == 0 {
		c := p.clips[slot][pad]
		c.bpm = sequence_tempo(p, slot)
		set_clip(m, slot, pad, "Add Take", c)
	}
	if !part_add_take(p, slot, pad, &x, id, clamp(at, 0, part_beats(p, slot, pad))) do return .Out_Of_Memory
	put_part(m, slot, pad, "Add Take", x)
	return .None
}
