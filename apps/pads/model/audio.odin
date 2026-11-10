package pads_model

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import "fire:record"

// Audio pads: tracks that record. Arm one (`arm_audio`) and record: while
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

// Arms (or disarms) audio pad `index` for recording. Not saved, not undone.
arm_audio :: proc(m: ^Model, index: int, on: bool) {
	if index < 0 || index >= PADS do return
	m.engine.armed[index] = on && m.project.pads[index].kind == .Audio
}

// Whether audio pad `index` is armed.
audio_armed :: proc(m: ^Model, index: int) -> bool {
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

// Folds take `t` of pad `pad` into its clip in the sequence it was played
// in: each frame lands where it was played within the sequence, over what
// was there (so of several passes, the last is heard).
fold_take :: proc(m: ^Model, pad: int, t: record.Take) -> fc.Error {
	if t.frames <= 0 || t.channels < 1 || !(t.sample_rate > 0) do return .Invalid_Argument
	p := &m.project
	_, slot, rel, ok := plan_locate(m.engine.plan, f64(t.start))
	if !ok do return .Invalid_Argument
	bpm := p.bpm
	fpb := t.sample_rate * 60 / bpm
	length := seq_beats(p, p.sequences[slot])
	total := int(math.round(length * fpb))
	if total <= 0 do return .Invalid_Argument
	ch := t.channels
	out := make([][]f32, ch, context.temp_allocator)
	for &c in out do c = make([]f32, total, context.temp_allocator)

	// What was there: the old clip, if it can be laid under the take.
	old := p.clips[slot][pad]
	if s := app.store_get(&p.samples, old.sample); s != nil && s.rate == t.sample_rate && old.bpm == bpm {
		if r, err := audiofile.open(s.path); err == .None {
			info := audiofile.info(r)
			buf := make([][]f32, info.channels, context.temp_allocator)
			for &b in buf do b = make([]f32, total, context.temp_allocator)
			got, _ := audiofile.read(r, buf, total)
			for c in 0 ..< ch do copy(out[c][:got], buf[min(c, info.channels - 1)][:got])
			audiofile.close(r)
		}
	}

	// The take, frame by frame where it was played.
	r, err := audiofile.open(t.path)
	if err != .None do return .Device_Error
	defer audiofile.close(r)
	at := int(math.round(rel * fpb)) % total
	CHUNK :: 4096
	buf := make([][]f32, ch, context.temp_allocator)
	for &b in buf do b = make([]f32, CHUNK, context.temp_allocator)
	for {
		n, rerr := audiofile.read(r, buf, CHUNK)
		if n <= 0 || rerr != .None do break
		for c in 0 ..< ch do for k in 0 ..< n do out[c][(at + k) % total] = buf[c][k]
		at = (at + n) % total
	}

	// A file of its own in the project, and the clip.
	dir, _ := filepath.join({p.dir, "samples"}, context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return .Device_Error
	name := fmt.tprintf("%s seq %d.wav", pad_name(&p.pads[pad]) if pad_name(&p.pads[pad]) != "" else pad_label(pad), slot + 1)
	dest := unique_path(dir, name)
	defer delete(dest)
	w, werr := audiofile.writer_create(dest, {format = .Wav, encoding = .Float32, sample_rate = t.sample_rate, channels = ch})
	if werr != .None do return .Device_Error
	audiofile.writer_write(w, out, total)
	if audiofile.writer_close(w) != .None do return .Device_Error
	app.begin(&m.history, "Record Audio")
	defer app.end(&m.history)
	id := add_sample(m, dest, {format = .Wav, encoding = .Float32, sample_rate = t.sample_rate, channels = ch, frames = i64(total)})
	set_clip(m, slot, pad, "Record Audio", {sample = id, bpm = bpm})
	return .None
}

// Empties pad `index`'s clip in the current sequence, undoably.
clear_clip :: proc(m: ^Model, index: int) {
	set_clip(m, m.project.slot, index, "Clear Clip", {})
	app.seal(&m.history)
}
