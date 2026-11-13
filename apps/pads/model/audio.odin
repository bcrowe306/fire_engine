package pads_model

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import "fire:record"

// Audio pads: tracks that record. Arm one (`arm_track`) and record: while
// the sequence plays, its input is recorded; when the recording stops the
// take is folded into the current sequence's clip for that pad, one
// sequence long, each pass over what was there before (the last pass
// wins), as one undo step. A clip loops with its sequence and follows the
// tempo.

// Ids of undo keys for clips start here (pads' keys are 1..PADS).
@(private)
CLIP_KEY :: 1 << 20

// Sets the clip of pad `pad` in sequence `slot`, undoably.
set_clip :: proc(m: ^Model, slot, pad: int, name: string, c: Clip) {
	if slot < 0 || slot >= SLOTS || pad < 0 || pad >= PADS do return
	old := m.project.clips[slot][pad]
	if old == c do return
	app.set_value(&m.history, name, {app.Id(CLIP_KEY + slot * PADS + pad), 0}, old, c, apply_clip)
}

@(private)
apply_clip :: proc(ctx: rawptr, key: app.Key, value: Clip) {
	m := (^Model)(ctx)
	k := int(key.id) - CLIP_KEY
	m.project.clips[k / PADS][k % PADS] = value
	m.engine.audio_dirty = true
}

// Makes pad `index` an audio pad (or a sampler again), undoably.
set_pad_kind :: proc(m: ^Model, index: int, kind: Pad_Kind) {
	pad := m.project.pads[index]
	if pad.kind == kind do return
	pad.kind = kind
	if kind == .Audio && pad.sample == 0 && pad_name(&pad) == "" do set_pad_name(&pad, fmt.tprintf("Audio %s", pad_label(index)))
	set_pad(m, index, .Kind, "Audio Track" if kind == .Audio else "Sampler Pad", pad)
	app.seal(&m.history)
}

// Arms (or disarms) track `index`: an audio track records while armed (and
// monitors its input), a sampler track's own MIDI input plays it. Not
// saved, not undone.
arm_track :: proc(m: ^Model, index: int, on: bool) {
	if index < 0 || index >= PADS do return
	m.engine.armed[index] = on
	m.engine.router.armed[index] = on
}

// Whether track `index` is armed.
track_armed :: proc(m: ^Model, index: int) -> bool {
	return m.engine.armed[index]
}

// The clip pad `index` has in the current sequence.
current_clip :: proc(m: ^Model, index: int) -> Clip {
	return m.project.clips[m.project.slot][index]
}

// Takes the audio pads' finished takes into their clips. Call once per
// frame (`capture_poll` does). True if a clip changed.
audio_poll :: proc(m: ^Model) -> (changed: bool) {
	e := &m.engine
	for &n, i in e.nodes {
		if !n.live || n.rec == nil do continue
		for take in record.audio_recorder_poll(n.rec) {
			t := take
			if fold_take(m, i, t) == .None do changed = true
			os.remove(t.path)
			record.take_destroy(&t)
		}
	}
	return
}

// Folds take `t` of pad `pad` into its part in the sequence it was
// played in: a take of the part (a file of what was recorded, a sequence
// at most each: a longer one is a take a pass), placed where it was played
// on top of what was there (so of several passes, the last is heard, and
// a punch replaces only what it covers). One undo step, "Record Audio".
fold_take :: proc(m: ^Model, armed: int, t: record.Take) -> fc.Error {
	if t.frames <= 0 || t.channels < 1 || !(t.sample_rate > 0) do return .Invalid_Argument
	p := &m.project
	_, slot, rel, ok := plan_locate(m.engine.plan, f64(t.start), editing_slot(m))
	if !ok do return .Invalid_Argument
	length := part_beats(p, slot, armed) // (a looped track: its loop, each pass a take)
	first := part_of(p, slot, armed)
	bpm := p.clips[slot][armed].bpm if first.take_count > 0 && p.clips[slot][armed].bpm > 0 else sequence_tempo(p, slot)
	fpb := t.sample_rate * 60 / bpm
	total := i64(math.round(length * fpb))
	if total <= 0 do return .Invalid_Argument
	a, err := read_audio(t.path, context.temp_allocator)
	if err != .None do return .Device_Error
	frames := i64(len(a.channels[0]))
	dir, _ := filepath.join({p.dir, "samples"}, context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return .Device_Error
	app.begin(&m.history, "Record Audio")
	defer app.end(&m.history)
	// The parts this take goes into (passes to tracks: one a pass).
	Into :: struct { pad: int, part: Audio_Part }
	into := make([dynamic]Into, context.temp_allocator)
	part_for :: proc(m: ^Model, into: ^[dynamic]Into, slot, pad: int, bpm: f64) -> ^Audio_Part {
		for &x in into do if x.pad == pad do return &x.part
		p := &m.project
		x := part_of(p, slot, pad)
		if p.clips[slot][pad].bpm <= 0 || x.take_count == 0 {
			c := p.clips[slot][pad]
			c.bpm = bpm
			set_clip(m, slot, pad, "Record Audio", c)
		}
		append(into, Into{pad, x})
		return &into[len(into) - 1].part
	}
	// A take a pass: up to the sequence's end, then a sequence each.
	at := math.mod(rel, length)
	done: i64
	pass := t.pass
	for done < frames {
		room := total - i64(math.round(at * fpb))
		if room <= 0 do room = total
		n := min(room, frames - done)
		pad := pass_track(m, armed, t.run, pass)
		x := part_for(m, &into, slot, pad, bpm)
		views := make([][]f32, len(a.channels), context.temp_allocator)
		for c, k in a.channels do views[k] = c[done:][:n]
		name := fmt.tprintf("%s seq %d.wav", pad_name(&p.pads[pad]) if pad_name(&p.pads[pad]) != "" else pad_label(pad), slot + 1)
		dest := unique_path(dir, name)
		defer delete(dest)
		w, werr := audiofile.writer_create(dest, {format = .Wav, encoding = .Float32, sample_rate = t.sample_rate, channels = len(a.channels)})
		if werr != .None do return .Device_Error
		audiofile.writer_write(w, views, int(n))
		if audiofile.writer_close(w) != .None do return .Device_Error
		id := add_sample(m, dest, {format = .Wav, encoding = .Float32, sample_rate = t.sample_rate, channels = len(a.channels), frames = n})
		part_add_take(p, slot, pad, x, id, at)
		done += n
		pass += 1 // (each cut is the sequence's top: a pass begins)
		at = 0
	}
	for x in into do put_part(m, slot, x.pad, "Record Audio", x.part)
	return .None
}

// The track pass `pass` of recording `run` on pad `pad` goes to: the pad,
// or (passes to tracks) the first pass the pad and each later one the
// next empty pad, made an audio track as the pad is (its input, its
// routing), named for the pass.
@(private)
pass_track :: proc(m: ^Model, pad: int, run, pass: int) -> int {
	if !m.passes_to_tracks || pass <= 0 || pass >= MAX_TAKES do return pad
	pr := &m.pass_runs[pad]
	if pr.run != run + 1 {
		pr.run = run + 1
		for &x in pr.tracks do x = -1
	}
	if k := pr.tracks[pass]; k >= 0 do return int(k)
	to := next_empty_pad(&m.project, pad)
	if to < 0 do return pad
	src := m.project.pads[pad]
	tr := default_pad()
	tr.kind = .Audio
	tr.input, tr.monitor, tr.bus, tr.volume, tr.pan, tr.color = src.input, .Off, src.bus, src.volume, src.pan, src.color
	set_pad_name(&tr, fmt.tprintf("%s pass %d", pad_name(&src) if pad_name(&src) != "" else pad_label(pad), pass + 1))
	set_pad(m, to, .Whole, "Record Audio", tr)
	pr.tracks[pass] = i16(to)
	return to
}

// Empties pad `index`'s clip in the current sequence, undoably.
clear_clip :: proc(m: ^Model, index: int) {
	set_clip(m, m.project.slot, index, "Clear Clip", {})
	app.seal(&m.history)
}

// How long the audio file at `path` is, in seconds, from its header (a WAV
// or AIFF; -1 for anything else, or a file that won't open). Cheap: no
// audio is read.
audio_seconds :: proc(path: string) -> f64 {
	r, err := audiofile.open(path, context.temp_allocator)
	if err != .None do return -1
	defer audiofile.close(r)
	info := audiofile.info(r)
	if info.sample_rate <= 0 do return -1
	return f64(info.frames) / info.sample_rate
}
