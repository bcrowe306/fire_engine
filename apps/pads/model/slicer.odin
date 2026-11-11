package pads_model

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import app "app:core"
import fc "fire:core"
import "fire:dsp"
import "fire:stretch"

// The slicer device: a pad's sample sliced in place (see `Slicer`). Slices
// are kept in order of their starts, the first at the region's start.

// Changes pad `index`'s slicer to `sl`, undoably (`name`: the step; drags
// of one setting, named alike, merge).
set_slicer :: proc(m: ^Model, index: int, sl: Slicer, name: string) {
	pad := m.project.pads[index]
	pad.slicer = sl
	sort_slices(&pad.slicer)
	set_pad(m, index, .Slicer, name, pad)
}

// Makes pad `index` a slicer (a sampler's sample, region and voice kept);
// its slices as they were, or found at its transients if it has none.
make_slicer :: proc(m: ^Model, index: int) {
	app.begin(&m.history, "Slicer")
	defer app.end(&m.history)
	pad := m.project.pads[index]
	pad.kind = .Slicer
	set_pad(m, index, .Kind, "Slicer", pad)
	if pad.sample != 0 && pad.slicer.count == 0 do slice_pad(m, index, .Transients)
	app.seal(&m.history)
}

// Makes slicer `index` a sampler again (its slices kept for later).
make_sampler :: proc(m: ^Model, index: int) {
	pad := m.project.pads[index]
	if pad.kind != .Slicer do return
	pad.kind = .Sampler
	set_pad(m, index, .Kind, "Sampler", pad)
	app.seal(&m.history)
}

// An empty slicer on pad `index` (a sample dropped or recorded onto it
// later is sliced then).
empty_slicer :: proc(m: ^Model, index: int) {
	pad := default_pad()
	pad.kind = .Slicer
	set_pad_name(&pad, "Slicer")
	set_pad(m, index, .Whole, "Empty Slicer", pad)
	app.seal(&m.history)
}

// Loads `path` into a slicer on pad `index` (sliced at its transients),
// as one undo step.
load_slicer :: proc(m: ^Model, index: int, path: string) -> fc.Error {
	app.begin(&m.history, "Load into Slicer")
	defer app.end(&m.history)
	keep := m.project.pads[index].slicer // (its settings stay; its slices are made again)
	load_onto_pad(m, index, path) or_return
	pad := m.project.pads[index]
	pad.kind = .Slicer
	pad.slicer = keep
	pad.slicer.count = 0
	if pad.slicer.base == 0 do pad.slicer = default_slicer()
	set_pad(m, index, .Whole, "Load into Slicer", pad)
	slice_pad(m, index, pad.slicer.by if pad.slicer.by != .Manual else .Transients)
	return .None
}

// Slices pad `index` again `by` its setting: at its transients (its
// sensitivity), on a grid of its own tempo, or into equal parts. Manual
// leaves one slice, the whole region.
slice_pad :: proc(m: ^Model, index: int, by: Slice_By) {
	pad := m.project.pads[index]
	sl := pad.slicer
	sl.by = by
	starts := slice_starts(m, index, sl)
	sl.count = min(len(starts), MAX_SLICER_SLICES)
	for k in 0 ..< sl.count do sl.slices[k] = {start = starts[k]}
	set_slicer(m, index, sl, "Slice")
	app.seal(&m.history)
}

// Where slicer `index`'s slices start, sliced `sl.by` (temporary allocator).
@(private)
slice_starts :: proc(m: ^Model, index: int, sl: Slicer) -> []i64 {
	lo, hi := pad_region(m, index)
	out := make([dynamic]i64, context.temp_allocator)
	append(&out, lo)
	if hi <= lo do return out[:]
	switch sl.by {
	case .Manual:
	case .Equal:
		n := clamp(sl.parts, 1, MAX_SLICER_SLICES)
		for k in 1 ..< n do append(&out, lo + (hi - lo) * i64(k) / i64(n))
	case .Beats:
		s := pad_sample(m, index)
		if s == nil do break
		bpm := pad_bpm(m, index)
		beat := s.rate * 60 / bpm
		of := [stretch.Warp_Grain]f64{.Transients = 4, .Sixteenth = 0.25, .Eighth = 0.5, .Quarter = 1} // (Transients: a bar)
		step := beat * of[sl.grain]
		for x := f64(lo) + step; x < f64(hi) - step * 0.25 && len(out) < MAX_SLICER_SLICES; x += step do append(&out, i64(math.round(x)))
	case .Transients:
		a, ok := pad_audio(m, index)
		if !ok || len(a.channels) == 0 do break
		mono := make([]f32, int(hi - lo), context.temp_allocator)
		for ch in a.channels do for &v, k in mono do v += ch[int(lo) + k] / f32(len(a.channels))
		found, _ := dsp.detect_onsets(mono, a.rate, {sensitivity = f64(sl.sensitivity)}, context.temp_allocator)
		for f in found do if f > 0 && len(out) < MAX_SLICER_SLICES do append(&out, lo + f)
	}
	return out[:]
}

// The tempo pad `index`'s sample is at: its warp's, else one guessed from
// its length, else the project's.
pad_bpm :: proc(m: ^Model, index: int) -> f64 {
	pad := m.project.pads[index]
	if pad.warp.bpm > 0 do return pad.warp.bpm
	lo, hi := pad_region(m, index)
	if s := pad_sample(m, index); s != nil {
		if g := guess_bpm(f64(hi - lo) / s.rate, m.project.bpm); g > 0 do return g
	}
	return m.project.bpm
}

// A slice starting at `frame` in slicer `index` (where it lands among
// them); false if there are as many as can be, or one starts there.
add_slice :: proc(m: ^Model, index: int, frame: i64) -> bool {
	sl := m.project.pads[index].slicer
	lo, hi := pad_region(m, index)
	if sl.count >= MAX_SLICER_SLICES || frame <= lo || frame >= hi do return false
	for s in sl.slices[:sl.count] do if s.start == frame do return false
	sl.slices[sl.count] = {start = frame}
	sl.count += 1
	sl.by = .Manual
	set_slicer(m, index, sl, "Add Slice")
	app.seal(&m.history)
	return true
}

// Takes slice `k` away (the one before runs on to the next); the first
// stays (it holds the region's start).
remove_slice :: proc(m: ^Model, index: int, k: int) {
	sl := m.project.pads[index].slicer
	if k <= 0 || k >= sl.count do return
	copy(sl.slices[k:sl.count - 1], sl.slices[k + 1:sl.count])
	sl.count -= 1
	sl.slices[sl.count] = {}
	sl.by = .Manual
	set_slicer(m, index, sl, "Remove Slice")
	app.seal(&m.history)
}

// Moves slice `k`'s start to `frame`, between its neighbours (drags merge).
move_slice :: proc(m: ^Model, index: int, k: int, frame: i64) {
	sl := m.project.pads[index].slicer
	if k <= 0 || k >= sl.count do return
	lo := sl.slices[k - 1].start + 1
	_, end := pad_region(m, index)
	hi := sl.slices[k + 1].start - 1 if k + 1 < sl.count else end - 1
	sl.slices[k].start = clamp(frame, lo, hi)
	sl.by = .Manual
	set_slicer(m, index, sl, "Move Slice")
}

// Slice `k`'s own settings (level, pitch, pan, reverse) changed (drags merge).
set_slice :: proc(m: ^Model, index: int, k: int, s: Slice, name := "Slice") {
	sl := m.project.pads[index].slicer
	if k < 0 || k >= sl.count do return
	start := sl.slices[k].start
	sl.slices[k] = s
	sl.slices[k].start = start
	set_slicer(m, index, sl, name)
}

// Where slice `k` of slicer `index` ends (the next one's start, or the
// region's end).
slice_end :: proc(m: ^Model, index: int, k: int) -> i64 {
	sl := m.project.pads[index].slicer
	if k + 1 < sl.count do return sl.slices[k + 1].start
	_, hi := pad_region(m, index)
	return hi
}

@(private)
sort_slices :: proc(sl: ^Slicer) {
	slice.sort_by(sl.slices[:sl.count], proc(a, b: Slice) -> bool { return a.start < b.start })
}

// Slice `k` of slicer `index` onto the next empty pad, as a sampler of
// that part alone (its level, pitch, pan and direction with it). Returns
// the pad, or -1 if none is empty.
slice_to_pad :: proc(m: ^Model, index: int, k: int) -> int {
	pad := m.project.pads[index]
	if k < 0 || k >= pad.slicer.count do return -1
	to := next_empty(m, index)
	if to < 0 do return -1
	s := pad.slicer.slices[k]
	np := pad
	np.kind = .Sampler
	np.start, np.end = s.start, slice_end(m, index, k)
	np.loop_start, np.loop_end, np.slice_count = 0, 0, 0
	np.pitch += s.pitch
	np.pan = clamp(np.pan + s.pan, -1, 1)
	np.volume += s.gain_db
	np.reverse = s.reverse
	np.mode = .One_Shot
	np.slicer = default_slicer()
	set_pad_name(&np, strings.concatenate({pad_name(&pad), " ", itoa(k + 1)}, context.temp_allocator))
	set_pad(m, to, .Whole, "Slice to Pad", np)
	app.seal(&m.history)
	return to
}

// A sequence that plays slicer `index`'s slices in order, where they fall
// (at the sample's tempo), each as long as it is: in the next empty slot,
// which becomes the current one. Returns the slot, or -1 if none is empty.
slices_to_sequence :: proc(m: ^Model, index: int) -> int {
	pad := m.project.pads[index]
	sl := pad.slicer
	s := pad_sample(m, index)
	if sl.count == 0 || s == nil do return -1
	slot := next_empty_slot(m, m.project.slot)
	if slot < 0 do return -1
	bpm := pad_bpm(m, index) if pad.warp.on else m.project.bpm // (warped, its beats are the project's)
	beats_of :: proc(frames: i64, rate, bpm: f64) -> f64 { return f64(frames) / rate * bpm / 60 }
	lo := sl.slices[0].start
	notes := make([dynamic]Seq_Note, 0, sl.count, context.temp_allocator)
	last := 0.0
	for k in 0 ..< sl.count {
		start := beats_of(sl.slices[k].start - lo, s.rate, bpm)
		end := beats_of(slice_end(m, index, k) - lo, s.rate, bpm)
		start = math.round(start * 64) / 64 // (on a 1/64 grid: no drift)
		append(&notes, Seq_Note{start = start, length = max(end - start, 1.0 / 16), pad = u8(index), pitch = i8(k), velocity = 0.8, probability = 1})
		last = max(last, end)
	}
	bar := bar_beats(&m.project)
	q := m.project.sequences[slot]
	q.bars = clamp(int(math.ceil(last / bar - 1e-6)), 1, MAX_BARS)
	q.notes = notes[:]
	copy(q.name[:len(q.name) - 1], fmt.tprintf("%s slices", pad_name(&pad)))
	app.begin(&m.history, "Slices to Sequence")
	defer app.end(&m.history)
	set_sequence(m, slot, .Notes, "Slices to Sequence", q)
	select_slot(m, slot)
	return slot
}
