package pads_model

import "core:math"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"

import fc "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:stretch"

// --- the preview node ----------------------------------------------------------------------

// Audio the preview plays: decoded, at the file's own rate (the node
// reads it at the engine's), stereo.
Preview_Clip :: struct {
	data:   [2][]f32,
	frames: int,
	rate:   f64,
}

// Plays one clip from its start, once, straight to its outputs: the
// browser's preview. The control thread hands it clips through `pending`
// and frees the ones it gives back in `retired` (see `preview_poll`).
Preview_Node :: struct {
	pending:  ^Preview_Clip, // atomic: control → audio
	retired:  ^Preview_Clip, // atomic: audio → control
	current:  ^Preview_Clip,
	pos:      f64, // in the clip's frames
	rate:     f64, // the engine's
	stop:     bool, // atomic: fade out and stop
	fade:     f32,  // 1 while playing; falls to 0 when stopping
	playing:  bool, // atomic
	position: int,  // atomic: frames into the clip (for a playhead)
}

// Frames a stop fades over.
@(private) PREVIEW_FADE :: 256

@(private)
preview_vtable := fc.Node_VTable {
	prepare = proc(self: rawptr, cfg: fc.Prepare_Config, a: mem.Allocator) -> fc.Error {
		(^Preview_Node)(self).rate = cfg.sample_rate
		return .None
	},
	process = preview_process,
	reset   = proc(self: rawptr) {
		p := (^Preview_Node)(self)
		sync.atomic_store(&p.playing, false)
	},
	destroy = proc(self: rawptr, a: mem.Allocator) {
		p := (^Preview_Node)(self)
		clip_free(p.current)
		clip_free(sync.atomic_load(&p.pending))
		clip_free(sync.atomic_load(&p.retired))
		free(p, a)
	},
}

// Control thread. A preview node (0 inputs, 2 outputs).
preview_node_create :: proc(allocator := context.allocator) -> (fc.Node, ^Preview_Node) {
	p := new(Preview_Node, allocator)
	return fc.node_make(&preview_vtable, p, allocator), p
}

@(private)
clip_free :: proc(c: ^Preview_Clip) {
	if c == nil do return
	delete(c.data[0])
	if raw_data(c.data[1]) != raw_data(c.data[0]) do delete(c.data[1])
	free(c)
}

// [rt]
@(private)
preview_process :: proc(self: rawptr, ctx: ^fc.Process_Context) {
	p := (^Preview_Node)(self)
	out := ctx.outputs
	// A new clip, once the last one given back has been taken.
	// (Taken with a compare-exchange: the control thread may put a newer
	// one in meanwhile, which then waits for the next call.)
	if next := sync.atomic_load(&p.pending); next != nil && sync.atomic_load(&p.retired) == nil {
		if _, ok := sync.atomic_compare_exchange_strong(&p.pending, next, nil); ok {
			sync.atomic_store(&p.retired, p.current)
			p.current = next
			p.pos, p.fade = 0, 1
			sync.atomic_store(&p.stop, false)
			sync.atomic_store(&p.playing, true)
		}
	}
	c := p.current
	playing := sync.atomic_load(&p.playing)
	if c == nil || !playing {
		for ch in out do for &v in ch[:ctx.frames] do v = 0
		return
	}
	step := c.rate / p.rate if p.rate > 0 else 1
	stopping := sync.atomic_load(&p.stop)
	for i in 0 ..< ctx.frames {
		at := int(p.pos)
		if at + 1 >= c.frames || p.fade <= 0 {
			for ch in out do for &v in ch[i:ctx.frames] do v = 0
			sync.atomic_store(&p.playing, false)
			break
		}
		f := f32(p.pos - f64(at))
		for ch, k in out {
			src := c.data[min(k, 1)]
			ch[i] = (src[at] + (src[at + 1] - src[at]) * f) * p.fade
		}
		if stopping do p.fade -= 1.0 / PREVIEW_FADE
		p.pos += step
	}
	sync.atomic_store(&p.position, int(p.pos))
}

// --- the browser's preview -----------------------------------------------------------------

// The browser's preview: what the engine plays, its volume, and the file
// being decoded (on a thread). Auto-play starts a file when it is
// selected; sync stretches a loop to the tempo while the sequencer plays.
Preview :: struct {
	id, gain_id: graph.Node_Id,
	node:      ^Preview_Node,
	volume:    f32, // dB
	sent_db:   f32,
	auto_play: bool,
	sync:      bool,
	path:      string, // the file played (or being decoded)
	loading:   ^Preview_Load,
	// The file's waveform (for the browser) and its length.
	wave:      [PREVIEW_WAVE][2]f32, // min and max per column
	frames:    int,
	rate:      f64,
	beats:     f64, // what sync stretched it to (0: played raw)
}

// Columns of a preview's waveform.
PREVIEW_WAVE :: 256

// A file being decoded for the preview.
Preview_Load :: struct {
	path:   string,
	bpm:    f64, // stretch to this tempo (0: raw)
	clip:   ^Preview_Clip,
	wave:   [PREVIEW_WAVE][2]f32,
	beats:  f64,
	done:   bool, // atomic
	cancel: bool, // atomic
	failed: bool,
	worker: ^thread.Thread,
}

// Longest file a preview decodes, in seconds (the rest is cut).
PREVIEW_MAX_SECONDS :: 600

// [control] Adds the preview's nodes to the graph: player → volume → output.
@(private)
build_preview :: proc(e: ^Engine) -> fc.Error {
	g := e.host.graph
	pv := &e.preview
	node, p := preview_node_create()
	pv.node = p
	pv.id = graph.add_node(g, node, 0, 2) or_return
	pv.gain_id = graph.add_node(g, dsp.gain_create(), 2, 2) or_return
	for c in 0 ..< 2 {
		graph.connect(g, pv.id, c, pv.gain_id, c)
		graph.connect(g, pv.gain_id, c, e.mixer.out_main if e.mixer.built else graph.OUTPUT, c) // (where main plays)
	}
	pv.sent_db = 1 // anything but what it will be
	return .None
}

// Previews file `path`: decodes it on a thread and plays it once it's
// ready (`preview_poll` each frame). With sync on and the sequencer
// playing, a loop is stretched to the tempo first.
preview_play :: proc(e: ^Engine, path: string) {
	pv := &e.preview
	preview_cancel(pv)
	delete(pv.path)
	pv.path = strings.clone(path)
	l := new(Preview_Load)
	l.path = strings.clone(path)
	if pv.sync {
		if _, playing := position(e); playing do l.bpm = e.project.bpm
	}
	pv.loading = l
	l.worker = thread.create_and_start_with_poly_data(l, preview_decode)
}

// Stops the preview (a short fade).
preview_stop :: proc(e: ^Engine) {
	pv := &e.preview
	preview_cancel(pv)
	if pv.node != nil do sync.atomic_store(&pv.node.stop, true)
}

// Whether the preview is playing (or about to: decoding).
preview_playing :: proc(e: ^Engine) -> bool {
	pv := &e.preview
	if pv.loading != nil do return true
	return pv.node != nil && (sync.atomic_load(&pv.node.playing) || sync.atomic_load(&pv.node.pending) != nil)
}

// How far the preview is through its file (0..1), or -1 when it isn't
// playing.
preview_progress :: proc(e: ^Engine) -> f64 {
	pv := &e.preview
	if pv.node == nil || !sync.atomic_load(&pv.node.playing) || pv.frames <= 0 do return -1
	return f64(sync.atomic_load(&pv.node.position)) / f64(pv.frames)
}

// Each frame: hands a decoded file to the node, frees the one it gave
// back, and sends the volume.
preview_poll :: proc(e: ^Engine) {
	pv := &e.preview
	if pv.node == nil do return
	if old := sync.atomic_exchange(&pv.node.retired, nil); old != nil do clip_free(old)
	if l := pv.loading; l != nil && sync.atomic_load(&l.done) {
		thread.join(l.worker)
		thread.destroy(l.worker)
		pv.loading = nil
		if !l.failed && l.clip != nil {
			pv.wave, pv.frames, pv.rate, pv.beats = l.wave, l.clip.frames, l.clip.rate, l.beats
			// One waiting clip at most: a newer one replaces it.
			if old := sync.atomic_exchange(&pv.node.pending, l.clip); old != nil do clip_free(old)
			l.clip = nil
		}
		load_free(l)
	}
	if pv.volume != pv.sent_db {
		graph.set_param(e.host.graph, pv.gain_id, dsp.GAIN_PARAM_DB, f64(pv.volume))
		pv.sent_db = pv.volume
	}
}

// Frees the preview (control side; the graph frees its node).
preview_destroy :: proc(pv: ^Preview) {
	preview_cancel(pv)
	delete(pv.path)
	pv.path = ""
}

@(private)
preview_cancel :: proc(pv: ^Preview) {
	l := pv.loading
	if l == nil do return
	sync.atomic_store(&l.cancel, true)
	thread.join(l.worker)
	thread.destroy(l.worker)
	load_free(l)
	pv.loading = nil
}

@(private)
load_free :: proc(l: ^Preview_Load) {
	clip_free(l.clip)
	delete(l.path)
	free(l)
}

// The beats a loop of `seconds` is at `bpm`: the nearest power of two (1
// to 64), if it is within a third of that; 0 for a one-shot or anything
// that doesn't fit.
loop_beats :: proc(seconds, bpm: f64) -> f64 {
	if seconds <= 0 || bpm <= 0 do return 0
	beats := seconds * bpm / 60
	if beats < 0.75 do return 0
	best := math.pow(2, math.round(math.log2(beats)))
	if best < 1 || best > 64 do return 0
	ratio := beats / best
	return best if ratio > 0.75 && ratio < 1.34 else 0
}

// [decode thread] Reads the file, stretches a loop to the tempo if asked,
// and draws its waveform.
@(private)
preview_decode :: proc(l: ^Preview_Load) {
	defer sync.atomic_store(&l.done, true)
	a, err := read_audio(l.path)
	if err != .None || len(a.channels) == 0 || len(a.channels[0]) < 2 {
		for c in a.channels do delete(c)
		delete(a.channels)
		l.failed = true
		return
	}
	defer {
		for c in a.channels do delete(c)
		delete(a.channels)
	}
	if sync.atomic_load(&l.cancel) do return
	frames := min(len(a.channels[0]), int(PREVIEW_MAX_SECONDS * a.rate))
	src := [2][]f32{a.channels[0][:frames], a.channels[min(1, len(a.channels) - 1)][:frames]}
	c := new(Preview_Clip)
	c.rate = a.rate
	// Synced: a loop stretched to its length in beats at the tempo.
	if beats := loop_beats(f64(frames) / a.rate, l.bpm); beats > 0 {
		out_frames := int(beats * 60 / l.bpm * a.rate + 0.5)
		s: stretch.Stretch
		if stretch.stretch_preset_default(&s, 2, f32(a.rate)) == .None {
			defer stretch.stretch_destroy(&s)
			out := [2][]f32{make([]f32, out_frames), make([]f32, out_frames)}
			if stretch.stretch_exact(&s, src[:], frames, out[:], out_frames) {
				c.data, c.frames, l.beats = out, out_frames, beats
			} else {
				delete(out[0])
				delete(out[1])
			}
		}
	}
	if c.frames == 0 {
		c.data = {make([]f32, frames), make([]f32, frames)}
		copy(c.data[0], src[0])
		copy(c.data[1], src[1])
		c.frames = frames
	}
	if sync.atomic_load(&l.cancel) {
		clip_free(c)
		return
	}
	// The waveform: each column's lowest and highest (of both channels).
	per := max(c.frames / PREVIEW_WAVE, 1)
	for col in 0 ..< PREVIEW_WAVE {
		lo, hi: f32 = 0, 0
		start := col * c.frames / PREVIEW_WAVE
		for i in start ..< min(start + per, c.frames) {
			for ch in c.data {
				lo = min(lo, ch[i])
				hi = max(hi, ch[i])
			}
		}
		l.wave[col] = {lo, hi}
	}
	l.clip = c
}
