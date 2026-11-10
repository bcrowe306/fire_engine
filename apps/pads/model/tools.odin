package pads_model

import "core:math"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:record"
import "fire:stretch"

// A sample's audio, decoded: one slice per channel.
Audio :: struct {
	channels: [][]f32,
	rate:     f64,
}

// Decodes a whole file (allocated with `allocator`).
read_audio :: proc(path: string, allocator := context.allocator) -> (a: Audio, err: fc.Error) {
	r, e := audiofile.open(path)
	if e != .None do return {}, .Invalid_Data
	defer audiofile.close(r)
	info := audiofile.info(r)
	a.rate = info.sample_rate
	a.channels = make([][]f32, info.channels, allocator)
	for &c in a.channels do c = make([]f32, int(info.frames), allocator)
	n, re := audiofile.read(r, a.channels, int(info.frames))
	if re != .None && n == 0 do return {}, .Invalid_Data
	for &c in a.channels do c = c[:n]
	return a, .None
}

// The audio of the sample pad `index` plays, decoded (temp allocator).
pad_audio :: proc(m: ^Model, index: int) -> (Audio, bool) {
	s := pad_sample(m, index)
	if s == nil do return {}, false
	a, err := read_audio(s.path, context.temp_allocator)
	return a, err == .None
}

// Sample `id`'s audio, read whole (temp memory).
sample_audio :: proc(m: ^Model, id: app.Id) -> (Audio, bool) {
	s := app.store_get(&m.project.samples, id)
	if s == nil do return {}, false
	a, err := read_audio(s.path, context.temp_allocator)
	return a, err == .None
}

// The frames a pad plays: its region, resolved.
pad_region :: proc(m: ^Model, index: int) -> (start, end: i64) {
	pad := &m.project.pads[index]
	s := pad_sample(m, index)
	if s == nil do return 0, 0
	end = pad.end if pad.end > 0 else s.frames
	return clamp(pad.start, 0, s.frames), clamp(end, 0, s.frames)
}

// --- chopping ------------------------------------------------------------------------------

// How to chop.
Chop :: union {
	Chop_Transients, // at the hits
	Chop_Equal,      // into equal parts
}

// Slices at the transients found with `sensitivity` (0..1).
Chop_Transients :: struct {
	sensitivity: f64,
}

// `parts` equal slices.
Chop_Equal :: struct {
	parts: int,
}

// Where pad `index`'s region would be cut: slice starts, in sample frames
// (temp allocator).
slice_points :: proc(m: ^Model, index: int, how: Chop) -> []i64 {
	start, end := pad_region(m, index)
	if end <= start do return nil
	out := make([dynamic]i64, context.temp_allocator)
	switch c in how {
	case Chop_Equal:
		n := clamp(c.parts, 1, PADS)
		for k in 0 ..< n do append(&out, start + (end - start) * i64(k) / i64(n))
	case Chop_Transients:
		a, ok := pad_audio(m, index)
		if !ok do return nil
		mono := make([]f32, int(end - start), context.temp_allocator)
		for ch in a.channels do for &v, i in mono do v += ch[int(start) + i] / f32(len(a.channels))
		found, _ := dsp.detect_onsets(mono, a.rate, {sensitivity = c.sensitivity}, context.temp_allocator)
		for f in found do append(&out, start + f)
		if len(out) == 0 do append(&out, start)
	}
	return out[:]
}

// Chops pad `index` into slices placed on the next empty pads of its bank
// (and on, wrapping into the next banks), each playing its part of the same
// sample (nothing is rewritten). Returns how many pads it filled. One undo
// step.
chop_to_pads :: proc(m: ^Model, index: int, how: Chop) -> int {
	points := slice_points(m, index, how)
	if len(points) == 0 do return 0
	_, end := pad_region(m, index)
	source := m.project.pads[index]
	app.begin(&m.history, "Chop to Pads")
	defer app.end(&m.history)
	placed := 0
	target := index
	for p, k in points {
		// The first slice stays on the pad itself; the rest go to empty pads.
		if k > 0 {
			target = next_empty(m, target)
			if target < 0 do break
		}
		pad := source
		pad.start = p
		pad.end = points[k + 1] if k + 1 < len(points) else end
		pad.loop_start, pad.loop_end, pad.slice_count = 0, 0, 0
		name := strings.concatenate({pad_name(&source), " ", itoa(k + 1)}, context.temp_allocator)
		set_pad_name(&pad, name)
		set_pad(m, target, .Whole, "Chop to Pads", pad)
		placed += 1
	}
	return placed
}

@(private)
next_empty :: proc(m: ^Model, after: int) -> int {
	for i in after + 1 ..< PADS do if !pad_used(&m.project, i) do return i
	return -1
}

// --- edits that write audio --------------------------------------------------------------

// Writes `a` as a new WAV in the project (named after `name`), adds it, and
// puts it on pad `index` with the pad's settings, region reset. Part of the
// caller's undo step.
@(private)
replace_audio :: proc(m: ^Model, index: int, a: Audio, name: string, step: string) -> fc.Error {
	dir, _ := filepath.join({m.project.dir, "samples"}, context.temp_allocator)
	path := unique_path(dir, strings.concatenate({name, ".wav"}, context.temp_allocator))
	defer delete(path)
	s := audiofile.default_writer_settings(a.rate, len(a.channels))
	s.encoding = .Float32
	w, err := audiofile.writer_create(path, s)
	if err != .None do return .Device_Error
	frames := len(a.channels[0]) if len(a.channels) > 0 else 0
	audiofile.writer_write(w, a.channels, frames)
	if audiofile.writer_close(w) != .None do return .Device_Error
	info := audiofile.Info{sample_rate = a.rate, channels = len(a.channels), frames = i64(frames)}
	id := add_sample(m, path, info)
	pad := m.project.pads[index]
	pad.sample = id
	pad.start, pad.end, pad.loop_start, pad.loop_end, pad.slice_count = 0, 0, 0, 0, 0
	set_pad(m, index, .Whole, step, pad)
	return .None
}

// What `edit_audio` does to the selected frames (or the whole region).
Audio_Edit :: enum {
	Crop,       // keep only the selection
	Delete,     // remove the selection
	Silence,    // make the selection silent
	Normalize,  // peak to 0 dBFS
	Fade_In,    // a linear fade over the selection
	Fade_Out,
	Reverse,    // the audio itself reversed
	Trim,       // silence (below -60 dB) removed from both ends
}

// Applies `edit` to pad `index`'s audio over `selection` (frames of the
// sample; {0, 0} = the pad's region), writing a new sample. One undo step;
// undo returns to the old sample (both files stay in the project).
edit_audio :: proc(m: ^Model, index: int, edit: Audio_Edit, selection: [2]i64 = {}) -> fc.Error {
	a, ok := pad_audio(m, index)
	if !ok do return .Invalid_Data
	rs, re := pad_region(m, index)
	a0, a1 := selection[0], selection[1]
	if a1 <= a0 do a0, a1 = rs, re
	n := len(a.channels[0])
	a0, a1 = clamp(a0, 0, i64(n)), clamp(a1, 0, i64(n))
	out := Audio{rate = a.rate, channels = make([][]f32, len(a.channels), context.temp_allocator)}
	for ch, c in a.channels {
		x := ch
		switch edit {
		case .Crop:
			x = ch[a0:a1]
		case .Delete:
			y := make([]f32, n - int(a1 - a0), context.temp_allocator)
			copy(y, ch[:a0])
			copy(y[a0:], ch[a1:])
			x = y
		case .Silence:
			for &v in x[a0:a1] do v = 0
		case .Normalize:
			peak: f32 = 0
			for other in a.channels do for v in other[a0:a1] do peak = max(peak, abs(v))
			if peak > 0 do for &v in x[a0:a1] do v /= peak
		case .Fade_In, .Fade_Out:
			span := max(a1 - a0, 1)
			for &v, i in x[a0:a1] {
				g := f32(i) / f32(span)
				v *= g if edit == .Fade_In else 1 - g
			}
		case .Reverse:
			seg := x[a0:a1]
			for i in 0 ..< len(seg) / 2 do seg[i], seg[len(seg) - 1 - i] = seg[len(seg) - 1 - i], seg[i]
		case .Trim:
			first, last := i64(-1), i64(-1)
			for other in a.channels do for v, i in other {
				if abs(v) > 0.001 {
					if first < 0 || i64(i) < first do first = i64(i)
					if i64(i) > last do last = i64(i)
				}
			}
			if first < 0 do return .Invalid_Data // all silence
			x = ch[first:last + 1]
		}
		out.channels[c] = x
	}
	names := [Audio_Edit]string{.Crop = "Crop", .Delete = "Delete", .Silence = "Silence", .Normalize = "Normalize", .Fade_In = "Fade In", .Fade_Out = "Fade Out", .Reverse = "Reverse", .Trim = "Trim"}
	app.begin(&m.history, names[edit])
	defer app.end(&m.history)
	return replace_audio(m, index, out, strings.concatenate({pad_name(&m.project.pads[index]), " ", names[edit]}, context.temp_allocator), names[edit])
}

// Stretches pad `index`'s region to `beats` beats at the project's tempo,
// keeping its pitch (Signalsmith Stretch), into a new sample. One undo step.
stretch_to_beats :: proc(m: ^Model, index: int, beats: f64) -> fc.Error {
	a, ok := pad_audio(m, index)
	if !ok || beats <= 0 do return .Invalid_Data
	rs, re := pad_region(m, index)
	in_frames := int(re - rs)
	out_frames := int(beats * 60 / m.project.bpm * a.rate + 0.5)
	if in_frames < 64 || out_frames < 64 do return .Invalid_Argument
	s: stretch.Stretch
	stretch.stretch_preset_default(&s, len(a.channels), f32(a.rate), allocator = context.temp_allocator) or_return
	defer stretch.stretch_destroy(&s)
	input := make([][]f32, len(a.channels), context.temp_allocator)
	for ch, c in a.channels do input[c] = ch[rs:re]
	out := Audio{rate = a.rate, channels = make([][]f32, len(a.channels), context.temp_allocator)}
	for &c in out.channels do c = make([]f32, out_frames, context.temp_allocator)
	if !stretch.stretch_exact(&s, input, in_frames, out.channels, out_frames) do return .Invalid_Argument
	app.begin(&m.history, "Stretch")
	defer app.end(&m.history)
	name := strings.concatenate({pad_name(&m.project.pads[index]), " ", itoa(int(beats)), " beats"}, context.temp_allocator)
	return replace_audio(m, index, out, name, "Stretch")
}

// Puts `selection` of pad `index` on the next empty pad (the same sample,
// that region). Returns the new pad, or -1 if none is empty.
bounce_to_pad :: proc(m: ^Model, index: int, selection: [2]i64) -> int {
	target := next_empty(m, index)
	if target < 0 || selection[1] <= selection[0] do return -1
	pad := m.project.pads[index]
	pad.start, pad.end, pad.loop_start, pad.loop_end, pad.slice_count = selection[0], selection[1], 0, 0, 0
	set_pad_name(&pad, strings.concatenate({pad_name(&m.project.pads[index]), " cut"}, context.temp_allocator))
	set_pad(m, target, .Whole, "Bounce to Pad", pad)
	return target
}

// --- recording -----------------------------------------------------------------------------

// Records the input onto a pad: arm with `record_start`, stop with
// `record_stop`; `record_poll` (once per frame) puts the take on the pad.
Recording :: struct {
	node:    graph.Node_Id,
	handle:  ^record.Audio_Recorder,
	pad:     int,
	active:  bool,
	waiting: bool, // stopped; the take is being finished
}

// Starts recording the host's first two inputs for pad `index`.
record_start :: proc(m: ^Model, rec: ^Recording, index: int) -> fc.Error {
	h := m.engine.host
	if h.settings.inputs <= 0 do return .Unsupported
	if rec.handle == nil {
		dir, _ := filepath.join({m.project.dir, "samples"}, context.temp_allocator)
		node, r, err := record.audio_recorder_create(h.disk, {channels = min(h.settings.inputs, 2), directory = dir, name = "Recording", encoding = .Float32})
		if err != .None do return err
		id := graph.add_node(h.graph, node, min(h.settings.inputs, 2), 0) or_return
		for c in 0 ..< min(h.settings.inputs, 2) do graph.connect(h.graph, graph.INPUT, c, id, c)
		graph.commit(h.graph)
		rec.node, rec.handle = id, r
	}
	rec.pad = index
	rec.active = true
	return record.audio_recorder_arm(rec.handle, true)
}

// Stops recording; the take arrives at a later `record_poll`.
record_stop :: proc(rec: ^Recording) {
	if !rec.active do return
	record.audio_recorder_arm(rec.handle, false)
	rec.active, rec.waiting = false, true
}

// Puts a finished take on the pad it was recorded for (one undo step).
// True when it did.
record_poll :: proc(m: ^Model, rec: ^Recording) -> bool {
	if rec.handle == nil do return false
	take, ok := record.audio_recorder_poll(rec.handle)
	if !ok do return false
	defer record.take_destroy(&take)
	rec.waiting = false
	if take.frames <= 0 do return false
	app.begin(&m.history, "Record")
	defer app.end(&m.history)
	id := add_sample(m, take.path, {sample_rate = take.sample_rate, channels = take.channels, frames = take.frames})
	assign_sample(m, rec.pad, id)
	return true
}

@(private)
_ :: math.PI
