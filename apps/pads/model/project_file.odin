package pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import fc "fire:core"
import "fire:perform"
import "fire:sampler"
import "fire:session"

// The project file in a project folder.
PROJECT_FILE :: "project.fire"
// Chunk tag of the samples a project holds.
SAMPLES_TAG :: fc.Tag{'P', 'S', 'M', 'P'}
// Chunk tag of the rest of a project.
PROJECT_TAG :: fc.Tag{'P', 'P', 'R', 'J'}
// Version of the project chunk this version writes.
PROJECT_VERSION :: 9 // 2: pads' sends; 3: 128 pads (the count is written); 4: the transport's settings; 5: pads' fades; 6: audio pads and their clips; 7: pads' voices; 8: sequences' names and tempos; 9: performance effects' intensity

// Saves the project into its folder: `project.fire` (a fire:session file
// whose app chunks hold the project; the samples are already in
// `samples/`). Marks the history saved.
model_save :: proc(m: ^Model) -> fc.Error {
	p := &m.project
	if os.make_directory_all(p.dir) != nil && !os.is_dir(p.dir) do return .Device_Error
	chunks := project_chunks(p)
	path, _ := filepath.join({p.dir, PROJECT_FILE}, context.temp_allocator)
	session.save({}, path, chunks) or_return
	app.mark_saved(&m.history)
	return .None
}

// Saves the project into folder `dir` instead (Save As): copies its
// samples there, then saves; from now on it is the project's folder.
model_save_as :: proc(m: ^Model, dir: string) -> fc.Error {
	p := &m.project
	samples, _ := filepath.join({dir, "samples"}, context.temp_allocator)
	if os.make_directory_all(samples) != nil && !os.is_dir(samples) do return .Device_Error
	for &it in p.samples.items {
		s := &it.value
		dest, _ := filepath.join({samples, filepath.base(s.path)}, context.temp_allocator)
		if dest != s.path {
			data, err := os.read_entire_file(s.path, context.temp_allocator)
			if err != nil do return .Device_Error
			if os.write_entire_file(dest, data) != nil do return .Device_Error
		}
		s.path = intern(p, dest)
	}
	p.dir = intern(p, dir)
	mark_all_sources_stale(&m.engine)
	return model_save(m)
}

// Loads the project in folder `dir` into `m`, replacing what it had (and
// its undo history): the engine is built again from it.
model_load :: proc(m: ^Model, dir: string) -> fc.Error {
	path, _ := filepath.join({dir, PROJECT_FILE}, context.temp_allocator)
	l, err := session.load({}, path, nil, context.temp_allocator)
	if err != .None do return err
	defer session.loaded_destroy(&l)
	fresh: Project
	project_init(&fresh, dir)
	if lerr := project_read(&fresh, l); lerr != .None {
		project_destroy(&fresh)
		return lerr
	}
	host, bus := m.engine.host, m.history.bus
	engine_clear(&m.engine)
	app.history_destroy(&m.history)
	project_destroy(&m.project)
	m.project = fresh
	app.history_init(&m.history, m, bus = bus)
	return engine_init(&m.engine, host, &m.project)
}

// Whether there are changes since the last save.
model_dirty :: proc(m: ^Model) -> bool {
	return app.is_dirty(&m.history)
}

// --- writing -------------------------------------------------------------------------------

@(private)
project_chunks :: proc(p: ^Project) -> []session.App_Chunk {
	out := make([dynamic]session.App_Chunk, context.temp_allocator)
	chunk :: proc(out: ^[dynamic]session.App_Chunk, write: proc(w: ^fc.State_Writer, p: ^Project), p: ^Project) {
		w: fc.State_Writer
		fc.state_writer_init(&w, context.temp_allocator)
		write(&w, p)
		data, _ := fc.state_writer_bytes(&w)
		// The writer made one chunk: hand its parts over.
		r := fc.state_reader(data)
		c, ok := fc.read_chunk(&r)
		if ok do append(out, session.App_Chunk{c.tag, c.version, c.data})
	}
	chunk(&out, proc(w: ^fc.State_Writer, p: ^Project) { app.document_save(w, &p.ids) }, p)
	chunk(&out, proc(w: ^fc.State_Writer, p: ^Project) {
		dir := p.dir
		@(static) project_dir: string
		project_dir = dir
		app.store_save(w, SAMPLES_TAG, 1, &p.samples, proc(w: ^fc.State_Writer, s: ^Sample) {
			rel, err := filepath.rel(project_dir, s.path, context.temp_allocator)
			fc.write_string(w, s.name)
			fc.write_string(w, rel if err == nil else s.path)
			fc.write_i64(w, s.frames)
			fc.write_f64(w, s.rate)
			fc.write_int(w, s.channels)
		})
	}, p)
	chunk(&out, write_project, p)
	return out[:]
}

@(private)
write_slot :: proc(w: ^fc.State_Writer, s: Effect_Slot) {
	s := s
	fc.write_u8(w, u8(s.kind))
	fc.write_bool(w, s.on)
	fc.write_int(w, s.count)
	for sp in s.params[:s.count] {
		fc.write_u32(w, u32(sp.id))
		fc.write_f32(w, sp.value)
	}
	fc.write_string(w, s.plugin_path)
	fc.write_string(w, s.plugin_id)
	fc.write_string(w, s.plugin_name)
}

@(private)
write_bus :: proc(w: ^fc.State_Writer, b: Bus) {
	b := b
	fc.write_f32(w, b.volume)
	fc.write_f32(w, b.pan)
	fc.write_bool(w, b.mute)
	fc.write_bool(w, b.solo)
	for s in b.slots do write_slot(w, s)
}

@(private)
write_project :: proc(w: ^fc.State_Writer, p: ^Project) {
	fc.begin_chunk(w, PROJECT_TAG, PROJECT_VERSION)
	defer fc.end_chunk(w)
	fc.write_f64(w, p.bpm)
	fc.write_int(w, p.slot)
	fc.write_bool(w, p.song_mode)
	fc.write_u8(w, u8(p.switch_at))
	// Pads: how many, then each.
	fc.write_int(w, PADS)
	for &pad in p.pads {
		fc.write_string(w, pad_name(&pad))
		fc.write_u32(w, pad.color)
		fc.write_u64(w, u64(pad.sample))
		fc.write_i64(w, pad.start)
		fc.write_i64(w, pad.end)
		fc.write_u8(w, u8(pad.mode))
		fc.write_i64(w, pad.loop_start)
		fc.write_i64(w, pad.loop_end)
		fc.write_u8(w, u8(pad.loop_mode))
		fc.write_i64(w, pad.crossfade)
		fc.write_bool(w, pad.reverse)
		for v in ([?]f32{pad.attack, pad.release, pad.pitch, pad.volume, pad.pan, pad.eq[0], pad.eq[1], pad.eq[2]}) do fc.write_f32(w, v)
		fc.write_u8(w, pad.choke)
		fc.write_u8(w, pad.bus)
		fc.write_int(w, pad.slice_count)
		for sl in pad.slices[:pad.slice_count] do fc.write_i64(w, sl)
		fc.write_bool(w, pad.midi_out.on)
		fc.write_u8(w, pad.midi_out.channel)
		fc.write_u8(w, pad.midi_out.key)
		for s in pad.inserts do write_slot(w, s)
		fc.write_bool(w, pad.mute)
		fc.write_bool(w, pad.solo)
		for s in pad.sends {
			fc.write_f32(w, s.level)
			fc.write_bool(w, s.pre)
		}
		fc.write_i64(w, pad.fade_in)
		fc.write_i64(w, pad.fade_out)
		fc.write_u8(w, u8(pad.kind))
		fc.write_u8(w, u8(pad.input))
		fc.write_bool(w, pad.monitor)
		write_voice(w, pad.voice)
	}
	// Sequences.
	for s in p.sequences {
		fc.write_int(w, s.bars)
		fc.write_f32(w, s.swing)
		fc.write_u8(w, u8(s.swing_grid))
		fc.write_int(w, len(s.notes))
		for n in s.notes {
			fc.write_f64(w, n.start)
			fc.write_f64(w, n.length)
			fc.write_u8(w, n.pad)
			fc.write_u8(w, u8(n.pitch))
			fc.write_f32(w, n.velocity)
			fc.write_f32(w, n.probability)
		}
		fc.write_int(w, len(s.points))
		for pt in s.points {
			fc.write_u8(w, pt.pad)
			fc.write_u8(w, u8(pt.param))
			fc.write_f64(w, pt.beat)
			fc.write_f32(w, pt.value)
		}
	}
	// MIDI, playing, the mixer, the song.
	for k in p.midi_map do fc.write_u32(w, u32(i32(k)))
	pf := p.perform
	fc.write_bool(w, pf.arp_on)
	fc.write_u8(w, u8(pf.arp.mode))
	fc.write_u8(w, u8(pf.arp.rate))
	fc.write_int(w, pf.arp.octaves)
	fc.write_f32(w, pf.arp.gate)
	fc.write_bool(w, pf.arp.latch)
	fc.write_bool(w, pf.repeat_on)
	fc.write_u8(w, u8(pf.repeat.rate))
	fc.write_f32(w, pf.repeat.gate)
	for b in p.buses do write_bus(w, b)
	write_bus(w, p.main)
	for s in p.perf_fx do write_slot(w, s)
	fc.write_bool(w, p.transport.loop) // (before v4: the song's own loop)
	fc.write_int(w, p.song.count)
	for st in p.song.steps[:p.song.count] {
		fc.write_u8(w, st.slot)
		fc.write_u8(w, st.repeats)
	}
	// The transport (v4).
	tr := p.transport
	fc.write_int(w, tr.count_in)
	fc.write_f32(w, tr.metro_db)
	fc.write_bool(w, tr.metro_rec_only)
	fc.write_int(w, tr.time_sig.num)
	fc.write_int(w, tr.time_sig.den)
	fc.write_bool(w, tr.quantize.on)
	fc.write_u8(w, u8(tr.quantize.grid))
	fc.write_f32(w, tr.quantize.strength)
	fc.write_f32(w, tr.quantize.swing)
	// Audio pads' clips (v6): how many, then each with where it is.
	n := 0
	for row in p.clips do for c in row do if c.sample != 0 do n += 1
	fc.write_int(w, n)
	for row, slot in p.clips do for c, pad in row do if c.sample != 0 {
		fc.write_u8(w, u8(slot))
		fc.write_u8(w, u8(pad))
		fc.write_u64(w, u64(c.sample))
		fc.write_f64(w, c.bpm)
	}
	// Sequences' names and tempos (v8).
	for &s in p.sequences {
		fc.write_string(w, strings.truncate_to_byte(string(s.name[:]), 0))
		fc.write_f64(w, s.bpm)
	}
	for x in p.perf_intensity do fc.write_f32(w, x) // (v9)
}

// --- reading -------------------------------------------------------------------------------

@(private)
project_read :: proc(p: ^Project, l: session.Loaded) -> fc.Error {
	if c, ok := session.find_extra(l, app.DOCUMENT_TAG); ok {
		app.document_load({c.tag, c.version, c.data}, &p.ids) or_return
	}
	if c, ok := session.find_extra(l, SAMPLES_TAG); ok {
		@(static) project: ^Project
		project = p
		app.store_load({c.tag, c.version, c.data}, &p.samples, proc(r: ^fc.State_Reader, version: u32, s: ^Sample) -> bool {
			p := project
			s.name = intern(p, fc.read_string(r))
			path := fc.read_string(r)
			if !filepath.is_abs(path) {
				full, _ := filepath.join({p.dir, path}, context.temp_allocator)
				path = full
			}
			s.path = intern(p, path)
			s.frames = fc.read_i64(r)
			s.rate = fc.read_f64(r)
			s.channels = fc.read_int(r)
			return s.frames >= 0 && s.channels >= 1
		}) or_return
	}
	c, ok := session.find_extra(l, PROJECT_TAG)
	if !ok do return .Invalid_Data
	if c.version > PROJECT_VERSION do return .Unsupported
	r := fc.chunk_reader({c.tag, c.version, c.data})
	read_project(&r, p, c.version)
	return .Invalid_Data if r.err != .None else .None
}

@(private)
read_slot :: proc(r: ^fc.State_Reader, p: ^Project) -> (s: Effect_Slot) {
	s.kind = Effect_Kind(min(fc.read_u8(r), u8(max(Effect_Kind))))
	s.on = fc.read_bool(r)
	s.count = clamp(fc.read_int(r), 0, MAX_EFFECT_PARAMS)
	for i in 0 ..< s.count do s.params[i] = {fc.Param_Id(fc.read_u32(r)), fc.read_f32(r)}
	s.plugin_path = intern(p, fc.read_string(r))
	s.plugin_id = intern(p, fc.read_string(r))
	s.plugin_name = intern(p, fc.read_string(r))
	return
}

@(private)
read_bus :: proc(r: ^fc.State_Reader, p: ^Project) -> (b: Bus) {
	b.volume = fc.read_f32(r)
	b.pan = fc.read_f32(r)
	b.mute = fc.read_bool(r)
	b.solo = fc.read_bool(r)
	for &s in b.slots do s = read_slot(r, p)
	return
}

@(private)
read_project :: proc(r: ^fc.State_Reader, p: ^Project, version: u32) {
	p.bpm = clamp(fc.read_f64(r), 40, 300)
	p.slot = clamp(fc.read_int(r), 0, SLOTS - 1)
	p.song_mode = fc.read_bool(r)
	p.switch_at = Switch_At(min(fc.read_u8(r), u8(max(Switch_At))))
	// Pads: 64 before version 3, then as many as were written.
	count := 64 if version < 3 else clamp(fc.read_int(r), 0, PADS)
	for &pad in p.pads[count:] do pad = default_pad()
	for &pad in p.pads[:count] {
		pad = default_pad()
		set_pad_name(&pad, fc.read_string(r))
		pad.color = fc.read_u32(r)
		pad.sample = app.Id(fc.read_u64(r))
		if app.store_get(&p.samples, pad.sample) == nil do pad.sample = 0
		pad.start = fc.read_i64(r)
		pad.end = fc.read_i64(r)
		pad.mode = Pad_Mode(min(fc.read_u8(r), u8(max(Pad_Mode))))
		pad.loop_start = fc.read_i64(r)
		pad.loop_end = fc.read_i64(r)
		pad.loop_mode = auto_cast min(fc.read_u8(r), 1)
		pad.crossfade = fc.read_i64(r)
		pad.reverse = fc.read_bool(r)
		vals: [8]f32
		for &v in vals do v = fc.read_f32(r)
		pad.attack, pad.release, pad.pitch, pad.volume, pad.pan = vals[0], vals[1], vals[2], vals[3], vals[4]
		pad.eq = {vals[5], vals[6], vals[7]}
		pad.choke = min(fc.read_u8(r), CHOKE_GROUPS)
		pad.bus = min(fc.read_u8(r), BUSES)
		pad.slice_count = clamp(fc.read_int(r), 0, MAX_SLICES)
		for i in 0 ..< pad.slice_count do pad.slices[i] = fc.read_i64(r)
		pad.midi_out.on = fc.read_bool(r)
		pad.midi_out.channel = fc.read_u8(r) & 15
		pad.midi_out.key = fc.read_u8(r) & 127
		for &s in pad.inserts do s = read_slot(r, p)
		pad.mute = fc.read_bool(r)
		pad.solo = fc.read_bool(r)
		if version >= 2 do for &s in pad.sends {
			s.level = clamp(fc.read_f32(r), 0, SEND_MAX)
			s.pre = fc.read_bool(r)
		}
		if version >= 5 {
			pad.fade_in = max(fc.read_i64(r), 0)
			pad.fade_out = max(fc.read_i64(r), 0)
		}
		if version >= 6 {
			pad.kind = Pad_Kind(min(fc.read_u8(r), u8(max(Pad_Kind))))
			pad.input = Audio_Input(min(fc.read_u8(r), u8(max(Audio_Input))))
			pad.monitor = fc.read_bool(r)
		}
		if version >= 7 do pad.voice = read_voice(r)
	}
	for &s in p.sequences {
		s.bars = clamp(fc.read_int(r), 1, MAX_BARS)
		s.swing = clamp(fc.read_f32(r), 0, 1)
		s.swing_grid = Grid(min(fc.read_u8(r), u8(max(Grid))))
		n := fc.read_int(r)
		if n < 0 || n > 1 << 20 do return
		s.notes = make([]Seq_Note, n)
		for &x in s.notes {
			x.start, x.length = fc.read_f64(r), fc.read_f64(r)
			x.pad = min(fc.read_u8(r), PADS - 1)
			x.pitch = i8(fc.read_u8(r))
			x.velocity, x.probability = fc.read_f32(r), fc.read_f32(r)
		}
		k := fc.read_int(r)
		if k < 0 || k > 1 << 20 do return
		s.points = make([]Auto_Point, k)
		for &pt in s.points {
			pt.pad = min(fc.read_u8(r), PADS - 1)
			pt.param = Lane_Param(min(fc.read_u8(r), u8(max(Lane_Param))))
			pt.beat, pt.value = fc.read_f64(r), fc.read_f32(r)
		}
	}
	for &k in p.midi_map do k = i16(clamp(i32(fc.read_u32(r)), -1, PADS - 1))
	pf := &p.perform
	pf.arp_on = fc.read_bool(r)
	pf.arp.mode = perform.Arp_Mode(min(fc.read_u8(r), u8(max(perform.Arp_Mode))))
	pf.arp.rate = perform.Rate(min(fc.read_u8(r), u8(max(perform.Rate))))
	pf.arp.octaves = clamp(fc.read_int(r), 1, 4)
	pf.arp.gate = fc.read_f32(r)
	pf.arp.latch = fc.read_bool(r)
	pf.repeat_on = fc.read_bool(r)
	pf.repeat.rate = perform.Rate(min(fc.read_u8(r), u8(max(perform.Rate))))
	pf.repeat.gate = fc.read_f32(r)
	for &b in p.buses do b = read_bus(r, p)
	p.main = read_bus(r, p)
	for &s in p.perf_fx {
		s = read_slot(r, p)
		s.on = false // held, not saved on
	}
	loop := fc.read_bool(r) // the song's before v4 (patterns always looped)
	p.transport.loop = loop if version >= 4 || p.song_mode else true
	p.song.count = clamp(fc.read_int(r), 0, SONG_STEPS)
	for &st in p.song.steps[:p.song.count] {
		st.slot = min(fc.read_u8(r), SLOTS - 1)
		st.repeats = clamp(fc.read_u8(r), 1, 16)
	}
	if version >= 4 {
		tr := &p.transport
		tr.count_in = clamp(fc.read_int(r), 0, 2)
		tr.metro_db = clamp(fc.read_f32(r), -60, 6)
		tr.metro_rec_only = fc.read_bool(r)
		tr.time_sig.num = clamp(fc.read_int(r), 1, 16)
		tr.time_sig.den = fc.read_int(r)
		if tr.time_sig.den != 2 && tr.time_sig.den != 4 && tr.time_sig.den != 8 && tr.time_sig.den != 16 do tr.time_sig.den = 4
		tr.quantize.on = fc.read_bool(r)
		tr.quantize.grid = Grid(min(fc.read_u8(r), u8(max(Grid))))
		tr.quantize.strength = clamp(fc.read_f32(r), 0, 1)
		tr.quantize.swing = clamp(fc.read_f32(r), 0, 1)
	}
	if version >= 6 {
		n := fc.read_int(r)
		if n < 0 || n > SLOTS * PADS do return
		for _ in 0 ..< n {
			slot, pad := int(fc.read_u8(r)), int(fc.read_u8(r))
			c := Clip{sample = app.Id(fc.read_u64(r)), bpm = fc.read_f64(r)}
			if slot >= SLOTS || pad >= PADS || app.store_get(&p.samples, c.sample) == nil || !(c.bpm > 0) do continue
			p.clips[slot][pad] = c
		}
	}
	if version >= 8 {
		for &s in p.sequences {
			s.name = {}
			copy(s.name[:len(s.name) - 1], fc.read_string(r))
			b := fc.read_f64(r)
			s.bpm = clamp(b, 40, 300) if b > 0 else 0
		}
	}
	if version >= 9 do for &x in p.perf_intensity do x = clamp(fc.read_f32(r), 0, 1)
}

_ :: strings.clone

// Replaces the model with a new, empty project in folder `dir` (and a new
// history); the engine is built again.
model_new :: proc(m: ^Model, dir: string) -> fc.Error {
	host, bus := m.engine.host, m.history.bus
	engine_clear(&m.engine)
	app.history_destroy(&m.history)
	project_destroy(&m.project)
	project_init(&m.project, dir)
	app.history_init(&m.history, m, bus = bus)
	return engine_init(&m.engine, host, &m.project)
}

@(private)
write_voice :: proc(w: ^fc.State_Writer, v: Voice) {
	fc.write_f32(w, v.decay)
	fc.write_f32(w, v.sustain)
	fc.write_u8(w, u8(v.filter))
	fc.write_bool(w, v.steep)
	for x in ([?]f32{v.cutoff, v.resonance, v.key_track, v.vel_cutoff, v.filter_env}) do fc.write_f32(w, x)
	for x in v.filter_adsr do fc.write_f32(w, x)
	fc.write_f32(w, v.pitch_env)
	for x in v.pitch_adsr do fc.write_f32(w, x)
	for x in ([?]f32{v.vel_pitch, v.pitch_track, v.fine}) do fc.write_f32(w, x)
	for l in v.lfos {
		fc.write_u8(w, u8(l.shape))
		fc.write_u8(w, u8(l.mode))
		fc.write_f32(w, l.rate)
		fc.write_u8(w, l.sync)
		fc.write_f32(w, l.fade)
		fc.write_f32(w, l.phase)
	}
	for r in v.routes {
		fc.write_u8(w, u8(r.source))
		fc.write_u8(w, u8(r.dest))
		fc.write_f32(w, r.amount)
	}
	fc.write_int(w, v.voices)
}

@(private)
read_voice :: proc(r: ^fc.State_Reader) -> (v: Voice) {
	v = default_voice()
	v.decay = clamp(fc.read_f32(r), 0.005, 10)
	v.sustain = clamp(fc.read_f32(r), 0, 1)
	v.filter = sampler.Voice_Filter(min(fc.read_u8(r), u8(max(sampler.Voice_Filter))))
	v.steep = fc.read_bool(r)
	v.cutoff = clamp(fc.read_f32(r), 20, 20_000)
	v.resonance = clamp(fc.read_f32(r), 0, 1)
	v.key_track = clamp(fc.read_f32(r), 0, 1)
	v.vel_cutoff = clamp(fc.read_f32(r), -1, 1)
	v.filter_env = clamp(fc.read_f32(r), -1, 1)
	for &x in v.filter_adsr do x = fc.read_f32(r)
	v.pitch_env = clamp(fc.read_f32(r), -48, 48)
	for &x in v.pitch_adsr do x = fc.read_f32(r)
	v.vel_pitch = clamp(fc.read_f32(r), -24, 24)
	v.pitch_track = clamp(fc.read_f32(r), 0, 1)
	v.fine = clamp(fc.read_f32(r), -100, 100)
	for &l in v.lfos {
		l.shape = sampler.Lfo_Shape(min(fc.read_u8(r), u8(max(sampler.Lfo_Shape))))
		l.mode = sampler.Lfo_Mode(min(fc.read_u8(r), u8(max(sampler.Lfo_Mode))))
		l.rate = clamp(fc.read_f32(r), 0.01, 40)
		l.sync = min(fc.read_u8(r), u8(len(sampler.LFO_SYNC_BEATS) - 1))
		l.fade = clamp(fc.read_f32(r), 0, 10)
		l.phase = clamp(fc.read_f32(r), 0, 360)
	}
	for &rt in v.routes {
		rt.source = sampler.Mod_Source(min(fc.read_u8(r), u8(max(sampler.Mod_Source))))
		rt.dest = sampler.Mod_Dest(min(fc.read_u8(r), u8(max(sampler.Mod_Dest))))
		rt.amount = clamp(fc.read_f32(r), -1, 1)
	}
	v.voices = clamp(fc.read_int(r), 1, 32)
	// The envelopes' times and sustains, in range.
	for adsr in ([]^[4]f32{&v.filter_adsr, &v.pitch_adsr}) {
		adsr[0] = clamp(adsr[0], 0.0005, 10)
		adsr[1] = clamp(adsr[1], 0.005, 10)
		adsr[2] = clamp(adsr[2], 0, 1)
		adsr[3] = clamp(adsr[3], 0.005, 20)
	}
	return
}
