package pads_model

import "base:intrinsics"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"

import app "app:core"
import "fire:audiofile"
import "fire:stream"

// What an edited audio part plays: its regions mixed into one file a
// sequence long (each over what is under it, crossing through its fades;
// gain, pan, reversal applied), rendered in the background and named for
// what went into it, so each is made once. Until a new rendering is
// ready, the last one plays on.

// A rendering under way.
@(private)
Comp_Job :: struct {
	takes:    [MAX_TAKES]string, // (owned) the takes' files
	part:     Audio_Part,
	fpb:      f64, // frames per sequence beat, at `rate`
	rate:     f64,
	frames:   int, // the rendering's length (the sequence)
	loop:     f64, // the part goes round in this many beats (its track's loop; the sequence's: none)
	out_path: string, // (owned)
	key:      int,    // slot * PADS + pad
	done:     bool,   // atomic
	ok:       bool,
	th:       ^thread.Thread,
}

// The source pad `pad`'s clip in `slot` plays and its tempo: the clip's
// sample (no part, or a plain one), or its part's rendering (`ready`
// false while that is made: the last one meanwhile, or nil).
comp_source :: proc(e: ^Engine, slot, pad: int) -> (src: ^stream.Source, bpm: f64, ready: bool) {
	p := e.project
	c := p.clips[slot][pad]
	bpm = c.bpm
	if c.part == 0 do return source_of(e, c.sample), bpm, true
	x := part_of(p, slot, pad)
	if x.count == 0 || x.take_count == 0 do return nil, bpm, true
	s0 := app.store_get(&p.samples, x.takes[0])
	if s0 == nil do return nil, bpm, true
	looped := part_beats(p, slot, pad) < seq_beats(p, p.sequences[slot]) - 1e-9
	if !looped && part_plain(x, s0.frames) && length_frames(p, slot, pad) == s0.frames do return source_of(e, x.takes[0]), bpm, true
	path := comp_path(p, slot, pad, x)
	key := slot * PADS + pad
	if cs, ok := e.comp_sources[path]; ok {
		comp_use(e, key, cs)
		return cs, bpm, true
	}
	if os.exists(path) {
		if cs, err := stream.source_open(e.host.streamer, path); err == .None {
			e.comp_sources[strings.clone(path)] = cs
			comp_use(e, key, cs)
			return cs, bpm, true
		}
	}
	busy := false
	for j in e.comp_jobs do if j.out_path == path do busy = true
	if !busy do comp_start(e, slot, pad, x, path)
	return e.comp_last[key] if key in e.comp_last else nil, bpm, false
}

// Clip `key` plays rendering `cs` now: the one it played before is let go
// when no other clip plays it (players keep their own hold while they need it).
@(private)
comp_use :: proc(e: ^Engine, key: int, cs: ^stream.Source) {
	old, had := e.comp_last[key]
	e.comp_last[key] = cs
	if !had || old == cs do return
	for _, x in e.comp_last do if x == old do return
	for path, src in e.comp_sources do if src == old {
		delete_key(&e.comp_sources, path)
		delete(path)
		stream.source_release(src)
		return
	}
}

// The frames a sequence of pad `pad`'s clip in `slot` is (at its first take's rate).
@(private)
length_frames :: proc(p: ^Project, slot, pad: int) -> i64 {
	x := part_of(p, slot, pad)
	if x.take_count == 0 do return 0
	return i64(math.round(seq_beats(p, p.sequences[slot]) * frames_per_beat_of(p, slot, pad, x.takes[0])))
}

// Where part `x`'s rendering goes: named by a hash of everything in it.
@(private)
comp_path :: proc(p: ^Project, slot, pad: int, x: Audio_Part) -> string {
	x := x
	h := hash.fnv64a(transmute([]u8)fmt.tprintf("%v|%v|%v|%v", x.regions[:x.count], seq_beats(p, p.sequences[slot]), p.clips[slot][pad].bpm, part_beats(p, slot, pad)))
	for t in x.takes[:x.take_count] {
		if s := app.store_get(&p.samples, t); s != nil do h ~= hash.fnv64a(transmute([]u8)s.path) * 31
	}
	path, _ := filepath.join({project_folder(p.dir, .Comp), fmt.tprintf("comp %d %d %016x.wav", slot + 1, pad + 1, h)}, context.temp_allocator)
	return path
}

@(private)
comp_start :: proc(e: ^Engine, slot, pad: int, x: Audio_Part, path: string) {
	p := e.project
	j := new(Comp_Job)
	j.part = x
	for t, k in j.part.takes[:x.take_count] {
		if s := app.store_get(&p.samples, t); s != nil do j.takes[k] = strings.clone(s.path)
	}
	s0 := app.store_get(&p.samples, x.takes[0])
	j.rate = s0.rate
	j.fpb = frames_per_beat_of(p, slot, pad, x.takes[0])
	j.frames = int(length_frames(p, slot, pad))
	j.loop = part_beats(p, slot, pad)
	j.out_path = strings.clone(path)
	j.key = slot * PADS + pad
	j.th = thread.create_and_start_with_poly_data(j, comp_render)
	append(&e.comp_jobs, j)
}

// [worker thread]
@(private)
comp_render :: proc(j: ^Comp_Job) {
	defer intrinsics.atomic_store(&j.done, true)
	defer free_all(context.temp_allocator)
	out, ok := comp_mix(j.takes[:j.part.take_count], j.part, j.fpb, j.rate, j.frames, context.temp_allocator, j.loop)
	if !ok do return
	os.make_directory_all(filepath.dir(j.out_path))
	tmp := strings.concatenate({j.out_path, ".part"}, context.temp_allocator) // whole or not at all
	ws := audiofile.default_writer_settings(j.rate, 2)
	ws.encoding = .Float32
	w, err := audiofile.writer_create(tmp, ws)
	if err != .None do return
	audiofile.writer_write(w, out[:], j.frames)
	if audiofile.writer_close(w) != .None do return
	j.ok = os.rename(tmp, j.out_path) == nil
}

// Part `x` mixed: stereo, `frames` long at `rate` (`fpb` frames a beat),
// its regions in order, each over what is under it. Takes at another rate
// are read at this one (linear). With `loop` beats (a track's own loop,
// shorter than the sequence): its first `loop` beats again each time
// round, each pass starting on its exact frame (no drift). Any thread.
comp_mix :: proc(takes: []string, x: Audio_Part, fpb, rate: f64, frames: int, allocator := context.allocator, loop := 0.0) -> (out: [2][]f32, ok: bool) {
	if frames <= 0 do return
	defer if ok && loop > 0 {
		first := int(math.round(loop * fpb))
		if first > 0 && first < frames {
			for k := 1; ; k += 1 {
				at := int(math.round(f64(k) * loop * fpb))
				if at >= frames do break
				n := min(first, frames - at)
				for c in 0 ..< 2 do copy(out[c][at:][:n], out[c][:n])
			}
		}
	}
	for c in 0 ..< 2 do out[c] = make([]f32, frames, allocator)
	audio := make([]Audio, len(takes), context.temp_allocator)
	for path, k in takes {
		if path == "" do continue
		a, err := read_audio(path, context.temp_allocator)
		if err == .None do audio[k] = a
	}
	x := x
	for r in x.regions[:x.count] {
		if r.mute || int(r.take) >= len(audio) do continue
		a := audio[r.take]
		if len(a.channels) == 0 || !(a.rate > 0) do continue
		step := a.rate / rate // take frames an output frame
		n := int(f64(r.end - r.start) / step)
		o := int(math.round(r.at * fpb))
		amp := f32(math.pow(10, f64(r.gain) / 20))
		bal := [2]f32{min(1, 1 - r.pan), min(1, 1 + r.pan)}
		fi, fo := f64(r.fade_in) * rate, f64(r.fade_out) * rate
		for k in 0 ..< n {
			at := o + k
			if at < 0 do continue
			if at >= frames do break
			// The take's frame: forwards from start, or backwards from end.
			pos := f64(r.start) + f64(k) * step if !r.reverse else f64(r.end) - 1 - f64(k) * step
			i := int(pos)
			t := f32(pos - f64(i))
			env: f64 = 1
			if fi > 0 do env = min(env, (f64(k) + 0.5) / fi)
			if fo > 0 do env = min(env, (f64(n - k) - 0.5) / fo)
			g := f32(clamp(env, 0, 1))
			for c in 0 ..< 2 {
				ch := a.channels[min(c, len(a.channels) - 1)]
				if i < 0 || i >= len(ch) do continue
				v := ch[i]
				if t > 0 && i + 1 < len(ch) do v += (ch[i + 1] - v) * t
				out[c][at] = out[c][at] * (1 - g) + v * amp * bal[c] * g
			}
		}
	}
	return out, true
}

// Each sync: renderings that finished (the players get them).
@(private)
comp_poll :: proc(e: ^Engine) {
	for k := len(e.comp_jobs) - 1; k >= 0; k -= 1 {
		j := e.comp_jobs[k]
		if !intrinsics.atomic_load(&j.done) do continue
		comp_job_free(j)
		unordered_remove(&e.comp_jobs, k)
		e.audio_dirty = true
	}
}

// Whether a rendering is being made.
comp_busy :: proc(e: ^Engine) -> bool {
	return len(e.comp_jobs) > 0
}

@(private)
comp_job_free :: proc(j: ^Comp_Job) {
	thread.join(j.th)
	thread.destroy(j.th)
	for t in j.takes do delete(t)
	delete(j.out_path)
	free(j)
}

// Waits for every rendering and lets go of the sources.
@(private)
comp_clear :: proc(e: ^Engine) {
	for j in e.comp_jobs do comp_job_free(j)
	clear(&e.comp_jobs)
	for path, src in e.comp_sources {
		stream.source_release(src)
		delete(path)
	}
	clear(&e.comp_sources)
	clear(&e.comp_last)
}

// Pad `pad`'s part in `slot` as it plays: mixed now, a sequence long
// (its first take's rate). False when it has nothing.
part_audio :: proc(m: ^Model, slot, pad: int, allocator := context.temp_allocator) -> (a: Audio, ok: bool) {
	p := &m.project
	x := part_of(p, slot, pad)
	if x.take_count == 0 || x.count == 0 do return
	s0 := app.store_get(&p.samples, x.takes[0])
	if s0 == nil do return
	takes := make([]string, x.take_count, context.temp_allocator)
	for t, k in x.takes[:x.take_count] do if s := app.store_get(&p.samples, t); s != nil do takes[k] = s.path
	out := comp_mix(takes, x, frames_per_beat_of(p, slot, pad, x.takes[0]), s0.rate, int(length_frames(p, slot, pad)), allocator, part_beats(p, slot, pad)) or_return
	a.rate = s0.rate
	a.channels = make([][]f32, 2, allocator)
	a.channels[0], a.channels[1] = out[0], out[1]
	return a, true
}

// Writes pad `pad`'s part in `slot` as it plays into a new take (a file
// in the project's samples) and makes that the part: one region, the
// whole sequence (the older takes kept to go back to). One undo step,
// "Consolidate". False if it has nothing.
consolidate :: proc(m: ^Model, slot, pad: int) -> bool {
	p := &m.project
	a, ok := part_audio(m, slot, pad)
	if !ok do return false
	name := fmt.tprintf("%s seq %d consolidated.wav", pad_name(&p.pads[pad]) if pad_name(&p.pads[pad]) != "" else pad_label(pad), slot + 1)
	dest := project_new_file(p.dir, .Processed, name)
	defer delete(dest)
	if dest == "" do return false
	ws := audiofile.default_writer_settings(a.rate, 2)
	ws.encoding = .Float32
	w, err := audiofile.writer_create(dest, ws)
	if err != .None do return false
	frames := len(a.channels[0])
	audiofile.writer_write(w, a.channels, frames)
	if audiofile.writer_close(w) != .None do return false
	app.seal(&m.history)
	app.begin(&m.history, "Consolidate")
	defer app.end(&m.history)
	id := add_sample(m, dest, {format = .Wav, encoding = .Float32, sample_rate = a.rate, channels = 2, frames = i64(frames)})
	x := part_of(p, slot, pad)
	if x.take_count >= MAX_TAKES {
		// (The oldest goes: room for the new one.)
		for k in 0 ..< MAX_TAKES - 1 do x.takes[k], x.take_at[k] = x.takes[k + 1], x.take_at[k + 1]
		x.take_count -= 1
	}
	k := x.take_count
	x.takes[k], x.take_at[k] = id, 0
	x.take_count += 1
	x.regions = {}
	x.regions[0] = {take = u8(k), at = 0, start = 0, end = i64(frames)}
	x.count = 1
	put_part(m, slot, pad, "Consolidate", x)
	return true
}

// Spreads pad `pad`'s takes in `slot` onto tracks (doubling): the first
// stays (all of it, where it was recorded), each later one onto the next
// empty pad, an audio track as this one is, lined up where it was played.
// One undo step, "Spread Takes". The tracks made (temp allocator).
spread_takes :: proc(m: ^Model, slot, pad: int) -> []int {
	p := &m.project
	x := part_of(p, slot, pad)
	if x.take_count < 2 do return nil
	made := make([dynamic]int, context.temp_allocator)
	app.seal(&m.history)
	app.begin(&m.history, "Spread Takes")
	defer app.end(&m.history)
	src := p.pads[pad]
	c := p.clips[slot][pad]
	whole :: proc(p: ^Project, slot, pad: int, id: app.Id, at: f64) -> (y: Audio_Part) {
		part_add_take(p, slot, pad, &y, id, at)
		return
	}
	for k in 1 ..< x.take_count {
		to := next_empty_pad(p, pad)
		if to < 0 do break
		tr := default_pad()
		tr.kind = .Audio
		tr.input, tr.monitor, tr.bus, tr.volume, tr.pan, tr.color = src.input, .Off, src.bus, src.volume, src.pan, src.color
		set_pad_name(&tr, fmt.tprintf("%s take %d", pad_name(&src) if pad_name(&src) != "" else pad_label(pad), k + 1))
		set_pad(m, to, .Whole, "Spread Takes", tr)
		set_clip(m, slot, to, "Spread Takes", {bpm = c.bpm})
		put_part(m, slot, to, "Spread Takes", whole(p, slot, to, x.takes[k], x.take_at[k]))
		append(&made, to)
	}
	put_part(m, slot, pad, "Spread Takes", whole(p, slot, pad, x.takes[0], x.take_at[0]))
	return made[:]
}
