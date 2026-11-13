package pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import app "app:core"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:perform"
import "fire:sampler"
import "fire:session"
import "fire:stretch"
import "fire:synth"

// The project file in a project folder.
PROJECT_FILE :: "project.fire"
// Chunk tag of the samples a project holds.
SAMPLES_TAG :: fc.Tag{'P', 'S', 'M', 'P'}
// Chunk tag of the rest of a project.
PROJECT_TAG :: fc.Tag{'P', 'P', 'R', 'J'}
// Version of the project chunk this version writes.
PROJECT_VERSION :: 34 // 2: pads' sends; 3: 128 pads (the count is written); 4: the transport's settings; 5: pads' fades; 6: audio pads and their clips; 7: pads' voices; 8: sequences' names and tempos; 9: performance effects' intensity; 10: song steps' parts and settings, arrangements, sequences' colours, automation curves; 11: notes muted; 12: 16 buses (named, routed), sends to each, pads' warps; 13: tracks' MIDI in and out ports, audio inputs by channel; 14: slicers, velocity sensitivity; 15: synths; 16: synths' effects order; 17: the project's own wavetables; 18: synths' preset names; 19: samplers' voice modes and glide; 20: 64 sequences (their count written); 21: the sequence pads' Keys switch; 22: the metronome's sound and accent; 23: plug-ins' states, plug-in pads; 24: songs' tempo lanes, steps' time signatures, markers, loop ranges; 25: sidechain keys, groups; 26: frozen pads; 27: cue sends; 28: the Sequence view's tab; 29: automation of any parameter (points' targets), MIDI CC lanes; 30: songs as lanes of clips, time signature lanes; 31: pads' MIDI effects (note repeat, the arpeggiator: each pad its own); 32: the launcher's Continue; 33: four inserts a pad (two before), pads' EQ on or off; 34: an audio track's monitoring (Auto, In, Off)

// Saves the project into its folder: `project.fire` (a fire:session file
// whose app chunks hold the project; the samples are already in
// `samples/`). Marks the history saved.
model_save :: proc(m: ^Model) -> fc.Error {
	capture_plugin_states(m) // (the plug-ins' own settings)
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

// Saves a copy of the project into folder `dir` (a template, say): its
// samples copied there; the project itself, its folder and whether it
// has unsaved changes stay as they are.
model_save_copy :: proc(m: ^Model, dir: string) -> fc.Error {
	capture_plugin_states(m)
	p := &m.project
	samples, _ := filepath.join({dir, "samples"}, context.temp_allocator)
	if os.make_directory_all(samples) != nil && !os.is_dir(samples) do return .Device_Error
	old_paths := make([]string, len(p.samples.items), context.temp_allocator)
	for &it, k in p.samples.items {
		s := &it.value
		old_paths[k] = s.path
		dest, _ := filepath.join({samples, filepath.base(s.path)}, context.temp_allocator)
		data, err := os.read_entire_file(s.path, context.temp_allocator)
		if err != nil do continue // (a sample missing: left out)
		if os.write_entire_file(dest, data) != nil do return .Device_Error
		s.path = strings.clone(dest, context.temp_allocator)
	}
	old_dir := p.dir
	p.dir = dir
	path, _ := filepath.join({dir, PROJECT_FILE}, context.temp_allocator)
	err := session.save({}, path, project_chunks(p))
	p.dir = old_dir
	for &it, k in p.samples.items do it.value.path = old_paths[k]
	return err
}

// Copies project folder `from` (a template) to a new folder `to` and
// loads it: a new project like it (its undo history empty).
model_new_from :: proc(m: ^Model, from, to: string) -> fc.Error {
	samples_from, _ := filepath.join({from, "samples"}, context.temp_allocator)
	samples_to, _ := filepath.join({to, "samples"}, context.temp_allocator)
	if os.make_directory_all(samples_to) != nil && !os.is_dir(samples_to) do return .Device_Error
	if h, err := os.open(samples_from); err == nil {
		infos, _ := os.read_dir(h, -1, context.temp_allocator)
		os.close(h)
		for fi in infos {
			src, _ := filepath.join({samples_from, fi.name}, context.temp_allocator)
			dst, _ := filepath.join({samples_to, fi.name}, context.temp_allocator)
			data, rerr := os.read_entire_file(src, context.temp_allocator)
			if rerr == nil do _ = os.write_entire_file(dst, data)
		}
	}
	src, _ := filepath.join({from, PROJECT_FILE}, context.temp_allocator)
	dst, _ := filepath.join({to, PROJECT_FILE}, context.temp_allocator)
	data, rerr := os.read_entire_file(src, context.temp_allocator)
	if rerr != nil do return .Device_Error
	if os.write_entire_file(dst, data) != nil do return .Device_Error
	return model_load(m, to)
}

// Moves the project's folder to `dir` (a rename): its samples go with it.
// Saves it there.
model_move :: proc(m: ^Model, dir: string) -> fc.Error {
	p := &m.project
	old := p.dir
	if os.rename(old, dir) != nil do return .Device_Error
	for &it in p.samples.items {
		s := &it.value
		if strings.has_prefix(s.path, old) do s.path = intern(p, strings.concatenate({dir, s.path[len(old):]}, context.temp_allocator))
	}
	p.dir = intern(p, dir)
	mark_all_sources_stale(&m.engine)
	return model_save(m)
}

// The folder in a project's folder its backups (autosaves) go in.
BACKUP_DIR :: ".autosave"

// Where project folder `dir`'s backup is.
model_backup_path :: proc(dir: string) -> string {
	p, _ := filepath.join({dir, BACKUP_DIR, PROJECT_FILE}, context.temp_allocator)
	return p
}

// Saves a backup of the project (an autosave) beside it, in its folder's
// `.autosave/`: the project itself, and whether it has unsaved changes,
// stay as they are.
model_save_backup :: proc(m: ^Model) -> fc.Error {
	capture_plugin_states(m) // (the plug-ins' own settings)
	p := &m.project
	dir, _ := filepath.join({p.dir, BACKUP_DIR}, context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return .Device_Error
	return session.save({}, model_backup_path(p.dir), project_chunks(p))
}

// Whether project folder `dir` has a backup newer than its project (what
// an app that stopped without saving left).
model_backup_newer :: proc(dir: string) -> bool {
	b, berr := os.stat(model_backup_path(dir), context.temp_allocator)
	if berr != nil do return false
	main, _ := filepath.join({dir, PROJECT_FILE}, context.temp_allocator)
	f, ferr := os.stat(main, context.temp_allocator)
	if ferr != nil do return true
	return time.diff(f.modification_time, b.modification_time) > 0
}

// Throws project folder `dir`'s backup away.
model_discard_backup :: proc(dir: string) {
	b, _ := filepath.join({dir, BACKUP_DIR}, context.temp_allocator)
	os.remove_all(b)
}

// Loads project folder `dir` from its backup: as it was when last
// autosaved, its changes unsaved (save to keep them).
model_load_backup :: proc(m: ^Model, dir: string) -> fc.Error {
	load_from(m, dir, model_backup_path(dir)) or_return
	m.history.saved = -1 // (unsaved: the project file is older)
	app.changed_history(&m.history)
	return .None
}

// Loads the project in folder `dir` into `m`, replacing what it had (and
// its undo history): the engine is built again from it.
model_load :: proc(m: ^Model, dir: string) -> fc.Error {
	path, _ := filepath.join({dir, PROJECT_FILE}, context.temp_allocator)
	return load_from(m, dir, path)
}

@(private)
load_from :: proc(m: ^Model, dir, path: string) -> fc.Error {
	l, err := session.load({}, path, nil, context.temp_allocator)
	if err != .None do return err
	defer session.loaded_destroy(&l)
	fresh := new(Project) // big: not on the stack
	defer free(fresh)
	project_init(fresh, dir)
	if lerr := project_read(fresh, l); lerr != .None {
		project_destroy(fresh)
		return lerr
	}
	host, bus := m.engine.host, m.history.bus
	engine_clear(&m.engine)
	app.history_destroy(&m.history)
	project_destroy(&m.project)
	m.project = fresh^
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
	chunk(&out, proc(w: ^fc.State_Writer, p: ^Project) {
		app.store_save(w, WAVETABLES_TAG, 1, &p.wave_docs, write_wave_doc)
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
		fc.write_u8(w, legacy_input(pad.input)) // (v6-12's; v13 has more, at the end)
		fc.write_bool(w, pad.monitor != .Off) // (before v34: on or off; v34's, at the end)
		write_voice(w, pad.voice)
	}
	// Sequences (how many first: v20).
	fc.write_int(w, SLOTS)
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
			fc.write_bool(w, n.muted)
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
	fc.write_int(w, 0) // (the song's steps before v30: none; its clips are at the end)
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
	// v10: sequences' colours and their automation's curves; every
	// arrangement (the current one's song as edited), each step whole.
	for &s in p.sequences {
		fc.write_u32(w, s.color)
		for pt in s.points do fc.write_f32(w, pt.curve)
	}
	// (Each from the project, the current one's song as edited: no copy of
	// them all, 200 KB, on the stack.)
	fc.write_int(w, p.arrangement_count)
	fc.write_int(w, p.arrangement)
	for k in 0 ..< p.arrangement_count {
		a := &p.arrangements[k]
		fc.write_string(w, strings.truncate_to_byte(string(a.name[:]), 0))
		fc.write_int(w, 0) // (steps before v30)
	}
	// v12: how many buses, and each one's name and where it goes; each
	// pad's warp.
	fc.write_int(w, p.bus_count)
	for &b in p.buses {
		fc.write_string(w, strings.truncate_to_byte(string(b.name[:]), 0))
		fc.write_u8(w, b.dest)
	}
	for pad in p.pads {
		fc.write_bool(w, pad.warp.on)
		fc.write_u8(w, u8(pad.warp.mode))
		fc.write_f64(w, pad.warp.bpm)
		fc.write_u8(w, u8(pad.warp.grain))
		fc.write_bool(w, pad.warp.fill_gaps)
	}
	// v13: each track's MIDI in and out ports, its audio input by channel.
	for pad in p.pads {
		fc.write_u8(w, u8(pad.midi_in.mode))
		fc.write_string(w, pad.midi_in.port)
		fc.write_u8(w, pad.midi_in.channel)
		fc.write_string(w, pad.midi_out.port)
		fc.write_u8(w, pad.input.channel)
		fc.write_bool(w, pad.input.stereo)
	}
	// v14: each pad's slicer and velocity sensitivity.
	for pad in p.pads {
		sl := pad.slicer
		fc.write_f32(w, pad.voice.velocity)
		fc.write_u8(w, sl.base)
		fc.write_bool(w, sl.mono)
		fc.write_bool(w, sl.thru)
		fc.write_bool(w, sl.gate)
		fc.write_f32(w, sl.fade_in_ms)
		fc.write_f32(w, sl.fade_out_ms)
		fc.write_u8(w, u8(sl.by))
		fc.write_f32(w, sl.sensitivity)
		fc.write_u8(w, u8(sl.grain))
		fc.write_int(w, sl.parts)
		fc.write_int(w, sl.count)
		for s in sl.slices[:sl.count] {
			fc.write_i64(w, s.start)
			fc.write_f32(w, s.gain_db)
			fc.write_f32(w, s.pitch)
			fc.write_f32(w, s.pan)
			fc.write_bool(w, s.reverse)
		}
	}
	// v15: each pad's synth patch (if it ever was a synth).
	for &pad in p.pads {
		sy := &pad.synth
		fc.write_bool(w, sy.set)
		if !sy.set do continue
		write_synth_patch(w, sy)
	}
	fc.write_bool(w, p.launch_hold) // v20
	v := p.view // how the app was left (v20)
	fc.write_u8(w, u8(v.play_mode))
	fc.write_u8(w, u8(v.keys.scale))
	fc.write_int(w, v.keys.root)
	fc.write_int(w, v.keys.octave)
	fc.write_u8(w, u8(v.keys.chord))
	fc.write_int(w, v.bank)
	fc.write_int(w, v.selected)
	fc.write_int(w, v.seq_bank)
	fc.write_bool(w, v.seq_keys) // v21
	fc.write_u8(w, u8(p.transport.click)) // v22
	fc.write_bool(w, p.transport.no_accent)
	// v23: every slot's plug-in state (in the order the slots were
	// written), then each pad's instrument (its state too) and lanes.
	for pad in p.pads do for sl in pad.inserts do fc.write_string(w, sl.state)
	for b in p.buses do for sl in b.slots do fc.write_string(w, sl.state)
	for sl in p.main.slots do fc.write_string(w, sl.state)
	for sl in p.perf_fx do fc.write_string(w, sl.state)
	for pad in p.pads {
		write_slot(w, pad.instrument)
		fc.write_string(w, pad.instrument.state)
		for l in pad.plugin_lanes {
			fc.write_u32(w, u32(l.id))
			fc.write_f32(w, l.lo)
			fc.write_f32(w, l.hi)
		}
	}
	// v24: each arrangement's song time (the current one's as it is).
	for k in 0 ..< p.arrangement_count {
		sg := p.song if k == p.arrangement else p.arrangements[k].song
		fc.write_int(w, sg.tempo_count)
		for pt in sg.tempo[:sg.tempo_count] {
			fc.write_f64(w, pt.beat)
			fc.write_f64(w, pt.bpm)
			fc.write_bool(w, pt.ramp)
		}
		fc.write_int(w, sg.marker_count)
		for &mk in sg.markers[:sg.marker_count] {
			fc.write_f64(w, mk.beat)
			fc.write_string(w, marker_name(&mk))
		}
		fc.write_bool(w, sg.loop_on)
		fc.write_f64(w, sg.loop_start)
		fc.write_f64(w, sg.loop_end)
		fc.write_int(w, 0) // (steps' time signatures before v30)
	}
	// v25: every slot's sidechain key (the slots in the order above).
	key :: proc(w: ^fc.State_Writer, sl: Effect_Slot) {
		fc.write_u8(w, u8(sl.key.kind))
		fc.write_int(w, sl.key.index)
		fc.write_f32(w, sl.key_hpf)
		fc.write_bool(w, sl.listen)
	}
	for pad in p.pads do for sl in pad.inserts do key(w, sl)
	for b in p.buses do for sl in b.slots do key(w, sl)
	for sl in p.main.slots do key(w, sl)
	for b in p.buses { // (and which buses are groups)
		fc.write_bool(w, b.group)
		fc.write_bool(w, b.folded)
	}
	// v26: frozen pads, and every pad's renderings (as the clips are).
	for pad in p.pads do fc.write_bool(w, pad.frozen)
	nf := 0
	for row in p.freezes do for c in row do if c.sample != 0 do nf += 1
	fc.write_int(w, nf)
	for row, slot in p.freezes do for c, pad in row do if c.sample != 0 {
		fc.write_u8(w, u8(slot))
		fc.write_u8(w, u8(pad))
		fc.write_u64(w, u64(c.sample))
		fc.write_f64(w, c.bpm)
	}
	// v27: cue sends (pads', buses').
	for pad in p.pads {
		fc.write_f32(w, pad.cue.level)
		fc.write_bool(w, pad.cue.pre)
	}
	for b in p.buses {
		fc.write_f32(w, b.cue.level)
		fc.write_bool(w, b.cue.pre)
	}
	// v28: the Sequence view's tab.
	fc.write_u8(w, u8(p.view.seq_mode))
	// v29: every point's target (in each sequence's order).
	for s in p.sequences {
		fc.write_int(w, len(s.points))
		for pt in s.points {
			t := pt.target
			fc.write_u8(w, u8(t.track))
			fc.write_u8(w, t.index)
			fc.write_u8(w, u8(t.device))
			fc.write_u8(w, t.slot)
			fc.write_u32(w, u32(t.param))
			fc.write_f32(w, t.lo)
			fc.write_f32(w, t.hi)
			fc.write_bool(w, t.stepped)
			fc.write_bool(w, t.log)
		}
		// Its CC lanes.
		fc.write_int(w, len(s.ccs))
		for c in s.ccs {
			fc.write_f64(w, c.beat)
			fc.write_u8(w, c.pad)
			fc.write_u8(w, c.cc)
			fc.write_u8(w, c.value)
		}
	}
	// v30: each arrangement's lanes, clips and time signature lane (the
	// current one's as it is).
	for k in 0 ..< p.arrangement_count {
		sg := p.song if k == p.arrangement else p.arrangements[k].song
		fc.write_int(w, sg.lane_count)
		for &l in sg.lanes[:sg.lane_count] {
			fc.write_string(w, strings.truncate_to_byte(string(l.name[:]), 0))
			fc.write_bool(w, l.mute)
			fc.write_bool(w, l.solo)
		}
		fc.write_int(w, sg.count)
		for &c in sg.clips[:sg.count] {
			fc.write_u8(w, c.lane)
			fc.write_u8(w, c.slot)
			fc.write_f64(w, c.at)
			fc.write_f64(w, c.length)
			fc.write_f64(w, c.start)
			fc.write_f64(w, c.part)
			fc.write_f64(w, c.phase)
			fc.write_u8(w, u8(c.transpose))
			fc.write_bool(w, c.mute)
			fc.write_string(w, clip_label(&c))
		}
		fc.write_int(w, sg.meter_count)
		for mt in sg.meters[:sg.meter_count] {
			fc.write_f64(w, mt.beat)
			fc.write_int(w, mt.sig.num)
			fc.write_int(w, mt.sig.den)
		}
	}
	// v31: each pad's MIDI effects.
	for &pad in p.pads {
		fx := pad.midi_fx
		fc.write_bool(w, fx.repeat_on)
		fc.write_u8(w, u8(fx.repeat.rate))
		fc.write_f32(w, fx.repeat.gate)
		fc.write_bool(w, fx.arp_on)
		fc.write_u8(w, u8(fx.arp.mode))
		fc.write_u8(w, u8(fx.arp.rate))
		fc.write_int(w, fx.arp.octaves)
		fc.write_f32(w, fx.arp.gate)
		fc.write_bool(w, fx.arp.latch)
	}
	fc.write_bool(w, p.launch_continue) // v32
	for pad in p.pads do fc.write_bool(w, pad.eq_on) // v33
	for pad in p.pads do fc.write_u8(w, u8(pad.monitor)) // v34
}

// How many inserts a pad has in a file of `version` (two before v33).
@(private)
inserts_in :: proc(version: u32) -> int {
	return PAD_INSERTS if version >= 33 else 2
}

// --- reading -------------------------------------------------------------------------------

@(private)
project_read :: proc(p: ^Project, l: session.Loaded) -> fc.Error {
	if c, ok := session.find_extra(l, app.DOCUMENT_TAG); ok {
		app.document_load({c.tag, c.version, c.data}, &p.ids) or_return
	}
	if c, ok := session.find_extra(l, WAVETABLES_TAG); ok {
		app.store_load({c.tag, c.version, c.data}, &p.wave_docs, proc(r: ^fc.State_Reader, version: u32, d: ^Wave_Doc) -> bool {
			read_wave_doc(r, d)
			return true
		}) or_return
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
	return convert_slot(s) // (the app's old effects as the synth's)
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

// A song as files before v30 kept it: a chain of steps.
@(private)
Legacy_Step :: struct {
	slot:      u8,
	repeats:   u8,
	start:     f64,
	length:    f64,
	mute:      bool,
	transpose: i8,
	bpm:       f64,
	label:     [16]u8,
	meter:     Time_Sig,
}

@(private)
Legacy_Song :: struct {
	steps: [64]Legacy_Step,
	count: int,
}

@(private)
read_project :: proc(r: ^fc.State_Reader, p: ^Project, version: u32) {
	legacy := make([]Legacy_Song, ARRANGEMENTS, context.temp_allocator)
	read_project_body(r, p, version, legacy)
	if version < 30 do for &a, k in p.arrangements[:p.arrangement_count] do song_from_steps(p, &a.song, &legacy[k])
	// Before v31 note repeat and the arpeggiator were the project's, for
	// every pad: each pad has them now.
	if version < 31 do for &pad in p.pads do pad.midi_fx = p.perform
	// Before v33 a pad's EQ was always in: on where it isn't flat.
	if version < 33 do for &pad in p.pads do pad.eq_on = pad.eq != {}
	p.song = p.arrangements[p.arrangement].song
}

// Song `s` from a chain of steps: each a clip on the first lane, one after
// another, as long as its repeats; the steps' tempos (their own, their
// sequences') in its tempo lane when it has none and any differs, and
// their time signatures in its time signature lane.
@(private)
song_from_steps :: proc(p: ^Project, s: ^Song, l: ^Legacy_Song) {
	s.count, s.meter_count = 0, 0
	at := 0.0
	tempos := make([dynamic]Tempo_Point, context.temp_allocator)
	cur := p.transport.time_sig
	for st in l.steps[:clamp(l.count, 0, len(l.steps))] {
		if s.count >= SONG_CLIPS do break
		c := Song_Clip{slot = st.slot, at = at, start = st.start, part = st.length, transpose = st.transpose, mute = st.mute, label = st.label}
		period := clip_period(p, c)
		c.length = period * f64(max(st.repeats, 1))
		if c.length <= 0 do continue
		s.clips[s.count] = c
		s.count += 1
		bpm := st.bpm if st.bpm > 0 else sequence_tempo(p, int(st.slot))
		if len(tempos) == 0 || tempos[len(tempos) - 1].bpm != bpm do append(&tempos, Tempo_Point{at, bpm, false})
		want := st.meter if st.meter.num > 0 && st.meter.den > 0 else p.transport.time_sig
		if want != cur && s.meter_count < MAX_METERS {
			s.meters[s.meter_count] = {at, want}
			s.meter_count += 1
			cur = want
		}
		at += c.length
	}
	s.lane_count = 1 if s.count > 0 else 0
	differs := false
	for pt in tempos do if pt.bpm != p.bpm do differs = true
	if s.tempo_count == 0 && differs do for pt in tempos[:min(len(tempos), MAX_TEMPO_POINTS)] {
		s.tempo[s.tempo_count] = pt
		s.tempo_count += 1
	}
}

@(private)
read_project_body :: proc(r: ^fc.State_Reader, p: ^Project, version: u32, legacy: []Legacy_Song) {
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
		for &s in pad.inserts[:inserts_in(version)] do s = read_slot(r, p)
		pad.mute = fc.read_bool(r)
		pad.solo = fc.read_bool(r)
		if version >= 2 do for &s in pad.sends[:BUSES if version >= 12 else 4] {
			s.level = clamp(fc.read_f32(r), 0, SEND_MAX)
			s.pre = fc.read_bool(r)
		}
		if version >= 5 {
			pad.fade_in = max(fc.read_i64(r), 0)
			pad.fade_out = max(fc.read_i64(r), 0)
		}
		if version >= 6 {
			pad.kind = Pad_Kind(min(fc.read_u8(r), u8(max(Pad_Kind))))
			switch fc.read_u8(r) { // inputs 1 + 2, input 1, input 2 (v13: at the end)
			case 1: pad.input = {channel = 0}
			case 2: pad.input = {channel = 1}
			case:   pad.input = {channel = 0, stereo = true}
			}
			pad.monitor = .Auto if fc.read_bool(r) else .Off // (v34: Auto, In or Off, at the end)
		}
		if version >= 7 do pad.voice = read_voice(r, version)
	}
	// How many sequences the file has (32 before v20).
	seqs := 32
	if version >= 20 do seqs = clamp(fc.read_int(r), 0, SLOTS)
	for &s in p.sequences[:seqs] {
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
			if version >= 11 do x.muted = fc.read_bool(r)
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
	for &b in p.buses[:BUSES if version >= 12 else 4] do b = read_bus(r, p)
	p.main = read_bus(r, p)
	for &s in p.perf_fx {
		s = read_slot(r, p)
		s.on = false // held, not saved on
	}
	loop := fc.read_bool(r) // the song's before v4 (patterns always looped)
	p.transport.loop = loop if version >= 4 || p.song_mode else true
	first := &legacy[0]
	first.count = clamp(fc.read_int(r), 0, len(first.steps))
	for &st in first.steps[:first.count] {
		st.slot = min(fc.read_u8(r), SLOTS - 1)
		st.repeats = clamp(fc.read_u8(r), 1, 16)
	}
	p.arrangement_count, p.arrangement = 1, 0
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
		for &s in p.sequences[:seqs] {
			s.name = {}
			copy(s.name[:len(s.name) - 1], fc.read_string(r))
			b := fc.read_f64(r)
			s.bpm = clamp(b, 40, 300) if b > 0 else 0
		}
	}
	if version >= 9 do for &x in p.perf_intensity do x = clamp(fc.read_f32(r), 0, 1)
	if version >= 10 {
		for &s in p.sequences[:seqs] {
			s.color = fc.read_u32(r) & 0xffffff
			for &pt in s.points do pt.curve = clamp(fc.read_f32(r), -1, 1)
		}
		p.arrangement_count = clamp(fc.read_int(r), 1, ARRANGEMENTS)
		p.arrangement = clamp(fc.read_int(r), 0, p.arrangement_count - 1)
		for &a, k in p.arrangements[:p.arrangement_count] {
			a = {}
			copy(a.name[:len(a.name) - 1], fc.read_string(r))
			lg := &legacy[k]
			lg^ = {}
			lg.count = clamp(fc.read_int(r), 0, len(lg.steps))
			for &st in lg.steps[:lg.count] {
				st.slot = min(fc.read_u8(r), SLOTS - 1)
				st.repeats = clamp(fc.read_u8(r), 1, 16)
				st.start = max(fc.read_f64(r), 0)
				st.length = max(fc.read_f64(r), 0)
				st.mute = fc.read_bool(r)
				st.transpose = i8(clamp(i32(i8(fc.read_u8(r))), -48, 48))
				b := fc.read_f64(r)
				st.bpm = clamp(b, 40, 300) if b > 0 else 0
				copy(st.label[:len(st.label) - 1], fc.read_string(r))
			}
		}
	}
	if version >= 12 {
		p.bus_count = clamp(fc.read_int(r), 1, BUSES)
		for &b in p.buses {
			copy(b.name[:len(b.name) - 1], fc.read_string(r))
			b.dest = fc.read_u8(r)
		}
		// Nothing goes round in a loop, or to a bus not in use.
		for &b, i in p.buses do if !bus_dest_ok(p, i + 1, int(b.dest)) do b.dest = 0
		for &pad in p.pads do if int(pad.bus) > p.bus_count && !is_out_dest(int(pad.bus)) do pad.bus = 0
		for &pad in p.pads {
			pad.warp.on = fc.read_bool(r)
			pad.warp.mode = stretch.Warp_Mode(min(fc.read_u8(r), u8(max(stretch.Warp_Mode))))
			pad.warp.bpm = clamp(fc.read_f64(r), 0, 400)
			pad.warp.grain = stretch.Warp_Grain(min(fc.read_u8(r), u8(max(stretch.Warp_Grain))))
			pad.warp.fill_gaps = fc.read_bool(r)
		}
		if version >= 13 do for &pad in p.pads {
			pad.midi_in.mode = Midi_In_Mode(min(fc.read_u8(r), u8(max(Midi_In_Mode))))
			pad.midi_in.port = intern(p, fc.read_string(r))
			pad.midi_in.channel = min(fc.read_u8(r), 16)
			pad.midi_out.port = intern(p, fc.read_string(r))
			pad.input.channel = min(fc.read_u8(r), 63)
			pad.input.stereo = fc.read_bool(r)
		}
		if version >= 14 do for &pad in p.pads {
			sl := &pad.slicer
			pad.voice.velocity = clamp(fc.read_f32(r), 0, 1)
			sl.base = min(fc.read_u8(r), 127)
			sl.mono = fc.read_bool(r)
			sl.thru = fc.read_bool(r)
			sl.gate = fc.read_bool(r)
			sl.fade_in_ms = clamp(fc.read_f32(r), 0, 1000)
			sl.fade_out_ms = clamp(fc.read_f32(r), 0, 1000)
			sl.by = Slice_By(min(fc.read_u8(r), u8(max(Slice_By))))
			sl.sensitivity = clamp(fc.read_f32(r), 0, 1)
			sl.grain = stretch.Warp_Grain(min(fc.read_u8(r), u8(max(stretch.Warp_Grain))))
			sl.parts = clamp(fc.read_int(r), 1, MAX_SLICER_SLICES)
			sl.count = clamp(fc.read_int(r), 0, MAX_SLICER_SLICES)
			for &s in sl.slices[:sl.count] {
				s.start = max(fc.read_i64(r), 0)
				s.gain_db = clamp(fc.read_f32(r), -60, 12)
				s.pitch = clamp(fc.read_f32(r), -48, 48)
				s.pan = clamp(fc.read_f32(r), -1, 1)
				s.reverse = fc.read_bool(r)
			}
		}
		if version >= 15 do for &pad in p.pads {
			if !fc.read_bool(r) do continue
			sy := &pad.synth
			read_synth_patch(r, version, p, sy)
		}
		if version >= 20 {
			p.launch_hold = fc.read_bool(r)
			v := &p.view
			v.play_mode = Play_Mode(min(fc.read_u8(r), u8(max(Play_Mode))))
			v.keys.scale = Scale(min(fc.read_u8(r), u8(max(Scale))))
			v.keys.root = clamp(fc.read_int(r), 0, 11)
			v.keys.octave = clamp(fc.read_int(r), -3, 3)
			v.keys.chord = Chord(min(fc.read_u8(r), u8(max(Chord))))
			v.bank = clamp(fc.read_int(r), 0, PADS / PADS_PER_BANK - 1)
			v.selected = clamp(fc.read_int(r), 0, PADS - 1)
			v.seq_bank = clamp(fc.read_int(r), 0, 3)
			if version >= 21 do v.seq_keys = fc.read_bool(r)
			if version >= 22 {
				p.transport.click = dsp.Click_Sound(min(fc.read_u8(r), u8(max(dsp.Click_Sound))))
				p.transport.no_accent = fc.read_bool(r)
			}
		}
		if version >= 23 {
			for &pad in p.pads do for &sl in pad.inserts[:inserts_in(version)] do sl.state = intern(p, fc.read_string(r))
			for &b in p.buses do for &sl in b.slots do sl.state = intern(p, fc.read_string(r))
			for &sl in p.main.slots do sl.state = intern(p, fc.read_string(r))
			for &sl in p.perf_fx do sl.state = intern(p, fc.read_string(r))
			for &pad in p.pads {
				pad.instrument = read_slot(r, p)
				pad.instrument.state = intern(p, fc.read_string(r))
				for &l in pad.plugin_lanes {
					l.id = fc.Param_Id(fc.read_u32(r))
					l.lo = fc.read_f32(r)
					l.hi = fc.read_f32(r)
				}
			}
		}
		if version >= 24 {
			for &a, ak in p.arrangements[:p.arrangement_count] {
				sg := &a.song
				sg.tempo_count = clamp(fc.read_int(r), 0, MAX_TEMPO_POINTS)
				for &pt in sg.tempo[:sg.tempo_count] {
					pt.beat = max(fc.read_f64(r), 0)
					pt.bpm = clamp(fc.read_f64(r), 40, 300)
					pt.ramp = fc.read_bool(r)
				}
				sg.marker_count = clamp(fc.read_int(r), 0, MAX_MARKERS)
				for &mk in sg.markers[:sg.marker_count] {
					mk.beat = max(fc.read_f64(r), 0)
					copy(mk.name[:len(mk.name) - 1], fc.read_string(r))
				}
				sg.loop_on = fc.read_bool(r)
				sg.loop_start = max(fc.read_f64(r), 0)
				sg.loop_end = max(fc.read_f64(r), 0)
				n := clamp(fc.read_int(r), 0, 64)
				for k in 0 ..< n {
					ts := Time_Sig{clamp(fc.read_int(r), 0, 16), fc.read_int(r)}
					if ts.den != 2 && ts.den != 4 && ts.den != 8 && ts.den != 16 do ts = {}
					if k < legacy[ak].count do legacy[ak].steps[k].meter = ts
				}
			}
		}
		if version >= 25 {
			key :: proc(r: ^fc.State_Reader, sl: ^Effect_Slot) {
				sl.key.kind = Key_Kind(min(fc.read_u8(r), u8(max(Key_Kind))))
				sl.key.index = clamp(fc.read_int(r), 0, PADS - 1)
				if sl.key.kind == .Bus do sl.key.index = min(sl.key.index, BUSES - 1)
				sl.key_hpf = clamp(fc.read_f32(r), 0, 2000)
				sl.listen = fc.read_bool(r)
			}
			for &pad in p.pads do for &sl in pad.inserts[:inserts_in(version)] do key(r, &sl)
			for &b in p.buses do for &sl in b.slots do key(r, &sl)
			for &sl in p.main.slots do key(r, &sl)
			for &b in p.buses {
				b.group = fc.read_bool(r)
				b.folded = fc.read_bool(r)
			}
		}
		if version >= 26 {
			for &pad in p.pads do pad.frozen = fc.read_bool(r)
			n := fc.read_int(r)
			if n < 0 || n > SLOTS * PADS do return
			for _ in 0 ..< n {
				slot, pad := int(fc.read_u8(r)), int(fc.read_u8(r))
				c := Clip{sample = app.Id(fc.read_u64(r)), bpm = fc.read_f64(r)}
				if slot >= SLOTS || pad >= PADS || app.store_get(&p.samples, c.sample) == nil || !(c.bpm > 0) do continue
				p.freezes[slot][pad] = c
			}
		}
		if version >= 27 {
			for &pad in p.pads {
				pad.cue.level = clamp(fc.read_f32(r), 0, SEND_MAX)
				pad.cue.pre = fc.read_bool(r)
			}
			for &b in p.buses {
				b.cue.level = clamp(fc.read_f32(r), 0, SEND_MAX)
				b.cue.pre = fc.read_bool(r)
			}
		}
		if version >= 28 do p.view.seq_mode = Seq_Mode(min(fc.read_u8(r), u8(max(Seq_Mode))))
		if version >= 29 do for &s in p.sequences[:seqs] {
			k := fc.read_int(r)
			if k != len(s.points) do return // (a file that doesn't agree with itself: the targets are not read)
			for &pt in s.points {
				t := &pt.target
				t.track = Auto_Track(min(fc.read_u8(r), u8(max(Auto_Track))))
				t.index = fc.read_u8(r)
				t.device = Auto_Device(min(fc.read_u8(r), u8(max(Auto_Device))))
				t.slot = fc.read_u8(r)
				t.param = fc.Param_Id(fc.read_u32(r))
				t.lo, t.hi = fc.read_f32(r), fc.read_f32(r)
				t.stepped = fc.read_bool(r)
				t.log = fc.read_bool(r)
				if t.track == .Pad do t.index = min(t.index, PADS - 1)
			}
			n := fc.read_int(r)
			if n < 0 || n > 1 << 20 do return
			s.ccs = make([]Seq_Cc, n)
			for &c in s.ccs {
				c.beat = fc.read_f64(r)
				c.pad = min(fc.read_u8(r), PADS - 1)
				c.cc, c.value = min(fc.read_u8(r), 127), min(fc.read_u8(r), 127)
			}
		}
		if version >= 30 do for &a in p.arrangements[:p.arrangement_count] {
			sg := &a.song
			sg.lane_count = clamp(fc.read_int(r), 0, SONG_LANES)
			for &l in sg.lanes[:sg.lane_count] {
				l = {}
				copy(l.name[:len(l.name) - 1], fc.read_string(r))
				l.mute = fc.read_bool(r)
				l.solo = fc.read_bool(r)
			}
			sg.count = clamp(fc.read_int(r), 0, SONG_CLIPS)
			for &c in sg.clips[:sg.count] {
				c = {}
				c.lane = min(fc.read_u8(r), SONG_LANES - 1)
				c.slot = min(fc.read_u8(r), SLOTS - 1)
				c.at = fc.read_f64(r)
				c.length = fc.read_f64(r)
				c.start = fc.read_f64(r)
				c.part = fc.read_f64(r)
				c.phase = fc.read_f64(r)
				c.transpose = i8(clamp(i32(i8(fc.read_u8(r))), -48, 48))
				c.mute = fc.read_bool(r)
				copy(c.label[:len(c.label) - 1], fc.read_string(r))
				c = clip_fit(c)
			}
			sg.meter_count = clamp(fc.read_int(r), 0, MAX_METERS)
			for &mt in sg.meters[:sg.meter_count] {
				mt.beat = max(fc.read_f64(r), 0)
				mt.sig = {clamp(fc.read_int(r), 1, 16), fc.read_int(r)}
				if mt.sig.den != 2 && mt.sig.den != 4 && mt.sig.den != 8 && mt.sig.den != 16 do mt.sig.den = 4
			}
		}
		if version >= 31 do for &pad in p.pads {
			fx := &pad.midi_fx
			fx.repeat_on = fc.read_bool(r)
			fx.repeat.rate = perform.Rate(min(fc.read_u8(r), u8(max(perform.Rate))))
			fx.repeat.gate = clamp(fc.read_f32(r), 0, 1)
			fx.arp_on = fc.read_bool(r)
			fx.arp.mode = perform.Arp_Mode(min(fc.read_u8(r), u8(max(perform.Arp_Mode))))
			fx.arp.rate = perform.Rate(min(fc.read_u8(r), u8(max(perform.Rate))))
			fx.arp.octaves = clamp(fc.read_int(r), 1, 4)
			fx.arp.gate = clamp(fc.read_f32(r), 0, 1)
			fx.arp.latch = fc.read_bool(r)
		}
		if version >= 32 do p.launch_continue = fc.read_bool(r)
		if version >= 33 do for &pad in p.pads do pad.eq_on = fc.read_bool(r)
		if version >= 34 do for &pad in p.pads do pad.monitor = Monitor(min(fc.read_u8(r), u8(max(Monitor))))
	} else {
		p.bus_count = DEFAULT_BUSES
	}
}

_ :: strings.clone

// An audio input as v6-12 wrote it: inputs 1 + 2, input 1, input 2.
@(private)
legacy_input :: proc(x: Audio_Input) -> u8 {
	if x.stereo do return 0
	return 2 if x.channel == 1 else 1
}

// Replaces the model with a new, empty project in folder `dir` (and a new
// history); the engine is built again.
model_new :: proc(m: ^Model, dir: string) -> fc.Error {
	host, bus := m.engine.host, m.history.bus
	engine_clear(&m.engine)
	app.history_destroy(&m.history)
	project_destroy(&m.project)
	project_init(&m.project, dir)
	apply_defaults(&m.project, m.defaults)
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
	fc.write_u8(w, u8(v.mode)) // v19
	fc.write_f32(w, v.glide)
	fc.write_bool(w, v.glide_always)
	fc.write_bool(w, v.glide_octaves)
}

@(private)
read_voice :: proc(r: ^fc.State_Reader, version: u32) -> (v: Voice) {
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
	if version >= 19 {
		v.mode = sampler.Voice_Mode(min(fc.read_u8(r), u8(max(sampler.Voice_Mode))))
		v.glide = clamp(fc.read_f32(r), 0, 5)
		v.glide_always = fc.read_bool(r)
		v.glide_octaves = fc.read_bool(r)
	}
	// The envelopes' times and sustains, in range.
	for adsr in ([]^[4]f32{&v.filter_adsr, &v.pitch_adsr}) {
		adsr[0] = clamp(adsr[0], 0.0005, 10)
		adsr[1] = clamp(adsr[1], 0.005, 10)
		adsr[2] = clamp(adsr[2], 0, 1)
		adsr[3] = clamp(adsr[3], 0.005, 20)
	}
	return
}

// Writes a synth patch (all but whether it is set), as projects and
// presets hold it.
@(private)
write_synth_patch :: proc(w: ^fc.State_Writer, sy: ^Synth_Patch) {
	// Parameters as id and value, so ones added later read as their defaults.
	fc.write_int(w, len(synth.PARAMS))
	for spec in synth.PARAMS {
		fc.write_u32(w, u32(spec.id))
		fc.write_f32(w, sy.values[spec.id])
	}
	fc.write_int(w, sy.route_count)
	for r in sy.routes[:sy.route_count] {
		fc.write_u8(w, u8(r.source))
		fc.write_u32(w, u32(r.dest))
		fc.write_f32(w, r.amount)
		fc.write_f32(w, r.power)
		fc.write_bool(w, r.bipolar)
		fc.write_bool(w, r.stereo)
		fc.write_bool(w, r.bypass)
	}
	for sh in sy.shapes {
		fc.write_int(w, sh.count)
		fc.write_bool(w, sh.smooth)
		for k in 0 ..< sh.count {
			fc.write_f32(w, sh.points[k][0])
			fc.write_f32(w, sh.points[k][1])
			fc.write_f32(w, sh.powers[k])
		}
	}
	for t in sy.tables {
		fc.write_u8(w, t.builtin)
		fc.write_u64(w, u64(t.sample))
		fc.write_u64(w, u64(t.table)) // v17
	}
	fc.write_u8(w, sy.sample.builtin)
	fc.write_u64(w, u64(sy.sample.sample))
	for &name in sy.macro_names do fc.write_string(w, strings.truncate_to_byte(string(name[:]), 0))
	for e in sy.fx_order do fc.write_u8(w, u8(e)) // v16
	fc.write_string(w, strings.truncate_to_byte(string(sy.preset[:]), 0)) // v18
}

// Reads a synth patch as `write_synth_patch` wrote it at project version
// `version` (its samples checked against `p`'s; none without one).
@(private)
read_synth_patch :: proc(r: ^fc.State_Reader, version: u32, p: ^Project, sy: ^Synth_Patch) {
	sy^ = default_synth_patch()
	n := clamp(fc.read_int(r), 0, synth.PARAM_SLOTS)
	for _ in 0 ..< n {
		id := fc.Param_Id(fc.read_u32(r))
		v := fc.read_f32(r)
		if spec := synth.param_spec(id); spec != nil do sy.values[id] = clamp(v, spec.min, spec.max)
	}
	sy.route_count = clamp(fc.read_int(r), 0, synth.MAX_ROUTES)
	for &x in sy.routes[:sy.route_count] {
		x.source = synth.Mod_Source(min(fc.read_u8(r), u8(max(synth.Mod_Source))))
		x.dest = fc.Param_Id(fc.read_u32(r))
		if synth.param_spec(x.dest) == nil do x.source = .None
		x.amount = clamp(fc.read_f32(r), -1, 1)
		x.power = clamp(fc.read_f32(r), -20, 20)
		x.bipolar = fc.read_bool(r)
		x.stereo = fc.read_bool(r)
		x.bypass = fc.read_bool(r)
	}
	for &sh in sy.shapes {
		sh = {}
		sh.count = clamp(fc.read_int(r), 0, synth.LFO_MAX_POINTS)
		sh.smooth = fc.read_bool(r)
		for k in 0 ..< sh.count {
			sh.points[k] = {clamp(fc.read_f32(r), 0, 1), clamp(fc.read_f32(r), 0, 1)}
			sh.powers[k] = clamp(fc.read_f32(r), -20, 20)
		}
	}
	read_source :: proc(r: ^fc.State_Reader, p: ^Project) -> (s: Synth_Source) {
		s.builtin = fc.read_u8(r)
		s.sample = app.Id(fc.read_u64(r))
		if s.sample != 0 && (p == nil || app.store_get(&p.samples, s.sample) == nil) do s.sample = 0
		return
	}
	for &t in sy.tables {
		t = read_source(r, p)
		if version >= 17 do t.table = app.Id(fc.read_u64(r))
	}
	sy.sample = read_source(r, p)
	for &name in sy.macro_names {
		name = {}
		copy(name[:len(name) - 1], fc.read_string(r))
	}
	if version >= 16 {
		for &e in sy.fx_order do e = fx.Effect(fc.read_u8(r))
		if !fx.chain_order_valid(sy.fx_order) do sy.fx_order = fx.CHAIN_ORDER
	}
	if version >= 18 {
		sy.preset = {}
		copy(sy.preset[:len(sy.preset) - 1], fc.read_string(r))
	}
}

// Writes a project wavetable (as projects and presets hold it).
@(private)
write_wave_doc :: proc(w: ^fc.State_Writer, d: ^Wave_Doc) {
	fc.write_string(w, strings.truncate_to_byte(string(d.name[:]), 0))
	fc.write_u64(w, u64(d.sample))
	fc.write_u8(w, u8(d.doc.blend))
	fc.write_int(w, d.doc.count)
	for &k in d.doc.keys[:clamp(d.doc.count, 0, synth.TABLE_KEYS)] {
		fc.write_int(w, k.position)
		fc.write_u8(w, u8(k.source))
		for v in k.draw do fc.write_f32(w, v)
		fc.write_int(w, k.point_count)
		for q in 0 ..< synth.LINE_POINTS {
			fc.write_f32(w, k.points[q][0])
			fc.write_f32(w, k.points[q][1])
			fc.write_f32(w, k.powers[q])
		}
		for v in k.levels do fc.write_f32(w, v)
		for v in k.phases do fc.write_f32(w, v)
		fc.write_f32(w, k.audio_at)
	}
}

// Reads a project wavetable as `write_wave_doc` wrote it.
@(private)
read_wave_doc :: proc(r: ^fc.State_Reader, d: ^Wave_Doc) {
	copy(d.name[:len(d.name) - 1], fc.read_string(r))
	d.sample = app.Id(fc.read_u64(r))
	d.doc.blend = synth.Table_Blend(min(fc.read_u8(r), u8(max(synth.Table_Blend))))
	d.doc.count = clamp(fc.read_int(r), 1, synth.TABLE_KEYS)
	for &k in d.doc.keys[:d.doc.count] {
		k.position = clamp(fc.read_int(r), 0, synth.WAVE_FRAMES - 1)
		k.source = synth.Key_Source(min(fc.read_u8(r), u8(max(synth.Key_Source))))
		for &v in k.draw do v = clamp(fc.read_f32(r), -1, 1)
		k.point_count = clamp(fc.read_int(r), 1, synth.LINE_POINTS)
		for q in 0 ..< synth.LINE_POINTS {
			k.points[q] = {clamp(fc.read_f32(r), 0, 1), clamp(fc.read_f32(r), -1, 1)}
			k.powers[q] = clamp(fc.read_f32(r), -20, 20)
		}
		for &v in k.levels do v = clamp(fc.read_f32(r), 0, 1)
		for &v in k.phases do v = clamp(fc.read_f32(r), 0, 1)
		k.audio_at = clamp(fc.read_f32(r), 0, 1)
	}
	wave_gen += 1
	d.gen = wave_gen
}
