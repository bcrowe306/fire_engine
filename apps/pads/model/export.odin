package pads_model

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import "fire:dsp"
import "fire:transport"

// What an export renders.
Export_Source :: enum u8 {
	Sequence, // the current sequence, once
	Song,     // the song, start to end
}

// Stems: one file per what.
Export_Stems :: enum u8 {
	None,  // a mixdown: one file
	Pads,  // a file per pad with a sound
	Buses, // a file per bus (and main: the pads that go straight there)
}

// Export file formats.
Export_Encoding :: enum u8 {
	Int16,
	Int24,
	Float32,
}

// How to export.
Export_Settings :: struct {
	source:   Export_Source,
	stems:    Export_Stems,
	encoding: Export_Encoding,
	rate:     f64, // 44100, 48000 or 96000 (0: the engine's)
	tail:     f64, // seconds after the end, for reverb and echoes to ring out
}

// One file of an export: whose sound, where it goes.
@(private)
Export_Pass :: struct {
	path:  string,
	solo:  Export_Solo,
}

// What a pass lets through the mixer.
Export_Solo :: struct {
	kind:  enum u8 {All, Pad, Bus},
	index: int, // the pad, or the bus (0 = what goes straight to main)
}

// An export under way: render a slice each frame with `export_step`
// (the device is closed until it ends).
Export :: struct {
	settings: Export_Settings,
	passes:   [dynamic]Export_Pass,
	pass:     int,
	frames:   int, // engine frames each pass renders
	done:     int, // of this pass
	writer:   ^audiofile.Writer,
	resampler: dsp.Resampler,
	speed:    f64,
	buf:      [2][]f32,
	out:      [2][]f32,
	was_open: bool,
	failed:   bool,
	finished: bool,
	files:    [dynamic]string, // written
	written:  int, // frames of this pass written (at the export rate)
	to_pad:   int, // resample to pad: where the result goes (-1: not that)
}

// Starts exporting to `path` (a .wav; for stems, a folder). Closes the
// device for the time it takes; `export_step` renders and writes,
// `export_finish` reopens the device. False if there is nothing to export.
export_begin :: proc(m: ^Model, x: ^Export, settings: Export_Settings, path: string) -> bool {
	p := &m.project
	e := &m.engine
	x^ = {settings = settings, to_pad = -1}
	if x.settings.rate <= 0 do x.settings.rate = e.host.graph.settings.sample_rate
	beats := song_beats(p) if settings.source == .Song else seq_beats(p, p.sequences[p.slot])
	if beats <= 0 do return false
	rate := e.host.graph.settings.sample_rate
	// (A song at its tempo lane's tempos; a sequence at its own.)
	secs := song_seconds(p) if settings.source == .Song else beats * 60 / sequence_tempo(p, p.slot)
	x.frames = int(math.ceil((secs + max(settings.tail, 0)) * rate))
	x.passes = make([dynamic]Export_Pass)
	x.files = make([dynamic]string)
	stem :: proc(x: ^Export, dir, name: string, solo: Export_Solo) {
		f, _ := filepath.join({dir, strings.concatenate({name, ".wav"}, context.temp_allocator)})
		append(&x.passes, Export_Pass{f, solo})
	}
	switch settings.stems {
	case .None:
		append(&x.passes, Export_Pass{strings.clone(path), {}})
	case .Pads:
		os.make_directory_all(path)
		for _, i in p.pads do if pad_used(p, i) {
			name := strings.concatenate({pad_label(i), " ", pad_name(&p.pads[i])}, context.temp_allocator)
			stem(x, path, name, {.Pad, i})
		}
	case .Buses:
		os.make_directory_all(path)
		stem(x, path, "Main", {.Bus, 0})
		for b in 1 ..= p.bus_count {
			used := false
			for pad, i in p.pads do if int(pad.bus) == b && pad_used(p, i) do used = true
			if used do stem(x, path, bus_name(p, b), {.Bus, b})
		}
	}
	if len(x.passes) == 0 do return false
	preview_stop(e) // not into the export
	x.was_open = e.host.running
	app.host_close(e.host)
	x.speed = rate / x.settings.rate
	dsp.resampler_init(&x.resampler, 2, .High, max(x.speed, 1) + 0.01, 4096)
	for c in 0 ..< 2 {
		x.buf[c] = make([]f32, e.host.settings.max_block)
		x.out[c] = make([]f32, int(f64(e.host.settings.max_block) / x.speed) + 64)
	}
	start_pass(m, x)
	return true
}

// Exports the current sequence once into a new sample on the next empty
// pad (resample): returns the pad, or -1.
export_to_pad :: proc(m: ^Model, x: ^Export) -> bool {
	p := &m.project
	empty := -1
	for _, i in p.pads do if !pad_used(p, i) {
		empty = i
		break
	}
	if empty < 0 do return false
	dir, _ := filepath.join({p.dir, "samples"}, context.temp_allocator)
	os.make_directory_all(dir)
	path := unique_path(dir, strings.concatenate({"Resampled ", itoa(m.project.slot + 1), ".wav"}, context.temp_allocator))
	defer delete(path)
	if !export_begin(m, x, {source = .Sequence, encoding = .Float32, tail = 0}, path) do return false
	x.to_pad = empty
	return true
}

@(private)
start_pass :: proc(m: ^Model, x: ^Export) {
	e := &m.engine
	pass := x.passes[x.pass]
	e.export_solo = pass.solo
	e.mix_dirty = true
	s := audiofile.default_writer_settings(x.settings.rate, 2)
	switch x.settings.encoding {
	case .Int16:   s.encoding, s.dither = .Int16, true
	case .Int24:   s.encoding = .Int24
	case .Float32: s.encoding = .Float32
	}
	w, err := audiofile.writer_create(pass.path, s)
	if err != .None {
		x.failed = true
		return
	}
	x.writer = w
	x.done, x.written = 0, 0
	dsp.resampler_reset(&x.resampler)
	// From the top: the song, or the current sequence.
	prev := e.project.song_mode
	e.project.song_mode = x.settings.source == .Song
	e.export_once = true // a sequence plays once, a song to its end
	stop(e)
	sync(e)
	settle := [2][]f32{x.buf[0][:1], x.buf[1][:1]}
	app.host_render(e.host, settle[:], 1) // the stop and the mixer take effect
	play(e)
	e.project.song_mode = prev
}

// Renders and writes up to `budget` engine frames. Returns how far the
// whole export is (0..1); `x.finished` once it is done.
export_step :: proc(m: ^Model, x: ^Export, budget := 48_000) -> f64 {
	if x.finished || x.failed do return 1
	e := &m.engine
	block := e.host.settings.max_block
	left := budget
	for left > 0 && x.done < x.frames {
		n := min(block, x.frames - x.done, left)
		views := [2][]f32{x.buf[0][:n], x.buf[1][:n]}
		app.host_render(e.host, views[:], n)
		write_resampled(x, views[:], false)
		x.done += n
		left -= n
	}
	if x.done >= x.frames {
		write_resampled(x, nil, true)
		audiofile.writer_close(x.writer)
		x.writer = nil
		append(&x.files, strings.clone(x.passes[x.pass].path))
		x.pass += 1
		if x.pass < len(x.passes) do start_pass(m, x)
		else do x.finished = true
	}
	total := f64(len(x.passes) * x.frames)
	return (f64(x.pass * x.frames) + (0 if x.finished else f64(x.done))) / max(total, 1)
}

// Writes `input` (engine rate) at the export rate; `flush` pushes the
// resampler's last frames out with silence.
@(private)
write_resampled :: proc(x: ^Export, input: [][]f32, flush: bool) {
	if x.writer == nil do return
	if x.speed == 1 {
		if !flush do audiofile.writer_write(x.writer, input, len(input[0]))
		return
	}
	in_ := input
	silence: [2][]f32
	if flush {
		// Enough silence to bring the resampler's history out.
		for c in 0 ..< 2 {
			silence[c] = x.buf[c][:min(len(x.buf[c]), 512)]
			for &v in silence[c] do v = 0
		}
		in_ = silence[:]
	}
	for len(in_[0]) > 0 {
		outs := [2][]f32{x.out[0], x.out[1]}
		used, made := dsp.resampler_process(&x.resampler, in_, outs[:], x.speed)
		// Exactly the pass's length at the export rate (the flush's extra is cut).
		want := int(math.round(f64(x.frames) / x.speed))
		keep := clamp(want - x.written, 0, made)
		if keep > 0 {
			views := [2][]f32{x.out[0][:keep], x.out[1][:keep]}
			audiofile.writer_write(x.writer, views[:], keep)
			x.written += keep
		}
		if used == 0 && made == 0 do break
		in_ = {in_[0][used:], in_[1][used:]}
	}
}

// Ends an export: puts a resample on its pad, gives the mixer back, and
// reopens the device. Returns the files written (the export's: freed with
// it).
export_finish :: proc(m: ^Model, x: ^Export) -> []string {
	e := &m.engine
	if x.writer != nil do audiofile.writer_close(x.writer)
	x.writer = nil
	stop(e)
	e.export_solo, e.export_once = {}, false
	e.mix_dirty = true
	sync(e)
	if x.to_pad >= 0 && !x.failed && len(x.files) > 0 {
		path := x.files[0]
		r, err := audiofile.open(path)
		if err == .None {
			info := audiofile.info(r)
			audiofile.close(r)
			app.begin(&m.history, "Resample to Pad")
			id := add_sample(m, path, info)
			assign_sample(m, x.to_pad, id)
			app.end(&m.history)
			sync(e)
		}
	}
	dsp.resampler_destroy(&x.resampler)
	for c in 0 ..< 2 {
		delete(x.buf[c])
		delete(x.out[c])
	}
	if x.was_open do app.host_open(e.host)
	return x.files[:]
}

// Frees an export's lists.
export_destroy :: proc(x: ^Export) {
	for p in x.passes do delete(p.path)
	delete(x.passes)
	for f in x.files do delete(f)
	delete(x.files)
	x^ = {}
}

// Exports start to end at once (tests, scripts): begin, step until done,
// finish. The files written, or nil.
export_all :: proc(m: ^Model, settings: Export_Settings, path: string, x: ^Export) -> []string {
	if !export_begin(m, x, settings, path) do return nil
	for !x.finished && !x.failed do export_step(m, x, 1 << 30)
	return export_finish(m, x)
}

_ :: fc.Error
_ :: transport.Clock
