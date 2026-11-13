package pads_model

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"

import app "app:core"

import "fire:audiofile"
import "fire:stream"
import "fire:stretch"

// A pad's warp: its sample follows the tempo, made longer or shorter (not
// played faster or slower) as `mode` says, from its own tempo `bpm`.
// Rendered in the background into the project's `warped` folder (and kept
// there); the pad plays the rendering once it is ready, its sample until
// then.
Warp :: struct {
	on:        bool,
	mode:      stretch.Warp_Mode,
	bpm:       f64,               // the sample's own tempo (0: not known yet)
	grain:     stretch.Warp_Grain, // Beats: where it cuts
	fill_gaps: bool,              // Beats, slower: gaps filled by its tail
}

// Warp mode names, as the sampler shows them.
WARP_MODE_NAMES := [stretch.Warp_Mode]cstring{.Beats = "Beats", .Tones = "Tones", .Complex = "Complex", .Repitch = "Re-pitch"}
// Beats grain names.
WARP_GRAIN_NAMES := [stretch.Warp_Grain]cstring{.Transients = "Transients", .Sixteenth = "1/16", .Eighth = "1/8", .Quarter = "1/4"}

// The semitones a warped pad's rendering is transposed by, its timing kept
// (its Transpose and Fine: in Beats, Tones and Complex; Re-pitch plays
// faster or slower, so its pitch is the sampler's there). 0: none.
warp_transpose :: proc(pad: Pad) -> f64 {
	if !pad.warp.on || pad.warp.mode == .Repitch do return 0
	return f64(pad.pitch) + f64(pad.voice.fine) / 100
}

// How much longer pad `pad`'s sample plays at `tempo` BPM (1: as it is).
warp_ratio :: proc(pad: Pad, tempo: f64) -> f64 {
	if !pad.warp.on || pad.warp.bpm <= 0 || tempo <= 0 do return 1
	r := pad.warp.bpm / tempo
	return 1 if abs(r - 1) < 1e-4 else r
}

// A tempo for a sample `seconds` long: a whole number of beats (1, 2, 4...
// 64), the tempo nearest `near` between 70 and 180 BPM; 0 if none fits.
guess_bpm :: proc(seconds, near: f64) -> f64 {
	if seconds <= 0 do return 0
	best, dist := 0.0, max(f64)
	for beats := 1.0; beats <= 64; beats *= 2 {
		bpm := 60 * beats / seconds
		if bpm < 70 || bpm > 180 do continue
		if d := abs(bpm - near); d < dist do best, dist = bpm, d
	}
	return best
}

// Turns pad `index`'s warp on or off (on: guessing its sample's tempo, if
// it has none yet, from the length it plays).
set_warp :: proc(m: ^Model, index: int, w: Warp, name := "Warp") {
	p := m.project.pads[index]
	w := w
	if w.on && w.bpm <= 0 {
		if s := pad_sample(m, index); s != nil {
			end := p.end if p.end > 0 else s.frames
			w.bpm = guess_bpm(f64(end - p.start) / s.rate, m.project.bpm)
		}
		if w.bpm <= 0 do w.bpm = m.project.bpm
	}
	w.bpm = clamp(w.bpm, 20, 400) if w.bpm > 0 else 0
	p.warp = w
	set_pad(m, index, .Warp, name, p)
}

// Where pad `pad`'s rendering at `ratio` goes: named for the sample, the
// mode and the ratio, so each is made once.
@(private)
warp_path :: proc(p: ^Project, sample_path: string, w: Warp, ratio: f64, transpose := 0.0) -> string {
	base := strings.trim_suffix(filepath.base(sample_path), filepath.ext(sample_path))
	name := fmt.tprintf("%s.%v.%v.%d.%d.wav", base, w.mode, w.grain, 1 if w.fill_gaps else 0, int(math.round(ratio * 100_000)))
	if transpose != 0 do name = fmt.tprintf("%s.%v.%v.%d.%d.t%d.wav", base, w.mode, w.grain, 1 if w.fill_gaps else 0, int(math.round(ratio * 100_000)), int(math.round(transpose * 100)))
	path, _ := filepath.join({p.dir, "warped", name}, context.temp_allocator)
	return path
}

// A rendering in the background.
@(private)
Warp_Job :: struct {
	src_path, out_path: string, // (owned)
	pad:      int, // whose (one at a time a pad: a drag of its Transpose renders its last value)
	ratio:    f64,
	settings: stretch.Warp_Settings,
	done:     bool, // atomic
	ok:       bool,
	th:       ^thread.Thread,
}

// The source pad `index` plays: its warped rendering when that is ready
// (how much longer it is, and whether it has the pad's transpose in it:
// then the sampler doesn't transpose it again), else its sample (a
// rendering is started, one at a time a pad).
@(private)
warp_source :: proc(e: ^Engine, index: int, pad: Pad, src: ^stream.Source) -> (out: ^stream.Source, scale: f64, transposed: bool) {
	r := warp_ratio(pad, e.warp_bpm)
	tr := warp_transpose(pad)
	if (r == 1 && tr == 0) || src == nil do return src, 1, false
	s := app_sample(e, pad.sample)
	if s == nil do return src, 1, false
	path := warp_path(e.project, s.path, pad.warp, r, tr)
	if ws, ok := e.warp_sources[path]; ok do return ws, r, tr != 0
	if os.exists(path) {
		if ws, err := stream.source_open(e.host.streamer, path); err == .None {
			e.warp_sources[strings.clone(path)] = ws
			return ws, r, tr != 0
		}
	}
	for j in e.warp_jobs do if j.out_path == path || j.pad == index do return src, 1, false // rendering (when it ends, the pad looks again)
	beat := s.rate * 60 / pad.warp.bpm
	j := new(Warp_Job)
	j^ = {src_path = strings.clone(s.path), out_path = strings.clone(path), pad = index, ratio = r,
		settings = {mode = pad.warp.mode, grain = pad.warp.grain, beat_frames = beat, fill_gaps = pad.warp.fill_gaps, transpose = tr}}
	j.th = thread.create_and_start_with_poly_data(j, render_warp)
	append(&e.warp_jobs, j)
	return src, 1, false
}

// [worker thread] Renders a job: reads the sample, warps it, writes it.
@(private)
render_warp :: proc(j: ^Warp_Job) {
	defer intrinsics.atomic_store(&j.done, true)
	defer free_all(context.temp_allocator)
	a, err := read_audio(j.src_path, context.temp_allocator)
	if err != .None do return
	out, werr := stretch.warp(a.channels, a.rate, j.ratio, j.settings, context.temp_allocator)
	if werr != .None do return
	os.make_directory_all(filepath.dir(j.out_path))
	tmp := strings.concatenate({j.out_path, ".part"}, context.temp_allocator) // whole or not at all
	ws := audiofile.default_writer_settings(a.rate, len(out))
	ws.encoding = .Float32
	w, e := audiofile.writer_create(tmp, ws)
	if e != .None do return
	audiofile.writer_write(w, out, len(out[0]))
	if audiofile.writer_close(w) != .None do return
	j.ok = os.rename(tmp, j.out_path) == nil
}

// Each sync: renderings that finished (their pads look again); every pad
// that warps when the tempo moved.
@(private)
warp_poll :: proc(e: ^Engine) {
	tempo := e.bpm if e.bpm > 0 else e.project.bpm
	changed := tempo != e.warp_bpm
	e.warp_bpm = tempo
	for k := len(e.warp_jobs) - 1; k >= 0; k -= 1 {
		j := e.warp_jobs[k]
		if !intrinsics.atomic_load(&j.done) do continue
		thread.join(j.th)
		thread.destroy(j.th)
		delete(j.src_path)
		delete(j.out_path)
		free(j)
		unordered_remove(&e.warp_jobs, k)
		changed = true
	}
	if changed do for pad, i in e.project.pads do if pad.warp.on do e.dirty[i] = true
}

// Whether pad `index` is waiting for its warp's rendering.
warp_rendering :: proc(e: ^Engine, index: int) -> bool {
	pad := e.project.pads[index]
	r := warp_ratio(pad, e.warp_bpm)
	n := &e.nodes[index]
	return (r != 1 && abs(n.warp_scale - r) > 1e-9) || (warp_transpose(pad) != 0 && !n.warp_transposed)
}

// Waits for every rendering and lets go of the warped sources.
@(private)
warp_clear :: proc(e: ^Engine) {
	for j in e.warp_jobs {
		thread.join(j.th)
		thread.destroy(j.th)
		delete(j.src_path)
		delete(j.out_path)
		free(j)
	}
	clear(&e.warp_jobs)
	for path, src in e.warp_sources {
		stream.source_release(src)
		delete(path)
	}
	clear(&e.warp_sources)
}

@(private)
app_sample :: proc(e: ^Engine, id: app.Id) -> ^Sample {
	return app.store_get(&e.project.samples, id)
}
