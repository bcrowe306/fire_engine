package pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"

// The project, the engine that plays it and the history that edits it,
// together: what every command changes, and the context they run in.
Model :: struct {
	project: Project,
	engine:  Engine,
	history: app.History,
	defaults: Project_Defaults, // what a new project starts with (the app's settings)
	passes_to_tracks: bool, // recording audio: each loop pass after the first onto a track of its own (an app setting)
	pass_runs: [PADS]Pass_Run, // the tracks this recording's passes went to
}

// Where a recording's passes went (see `Model.passes_to_tracks`).
Pass_Run :: struct {
	run:    int,
	tracks: [MAX_TAKES]i16, // pass n's track (-1: not yet)
}

// What a new project starts with.
Project_Defaults :: struct {
	bpm:   f64,      // 0 = 120
	sig:   Time_Sig, // {0, 0} = 4/4
	bars:  int,      // each sequence's length; 0 = 1
	buses: int,      // 0 = DEFAULT_BUSES
	lanes: int,      // the launcher's; 0 = DEFAULT_LANES
}

// Puts `d` into a project just made (its tempo, time signature, sequences'
// length and buses).
apply_defaults :: proc(p: ^Project, d: Project_Defaults) {
	if d.bpm > 0 do p.bpm = clamp(d.bpm, 40, 300)
	if d.sig.num > 0 && d.sig.den > 0 do p.transport.time_sig = d.sig
	if d.bars > 0 do for &s in p.sequences do s.bars = clamp(d.bars, 1, MAX_BARS)
	if d.buses > 0 do p.bus_count = clamp(d.buses, 1, BUSES)
	if d.lanes > 0 do p.lanes = default_lanes(d.lanes)
}

// Which part of a pad an edit changes: consecutive edits of the same part
// of the same pad merge into one undo step (a dragged knob).
Pad_Field :: enum {
	Whole, // the pad replaced (a sample assigned, cleared, pasted)
	Name,
	Color,
	Mode,
	Region,
	Loop,
	Loop_Mode,
	Crossfade,
	Reverse,
	Attack,
	Release,
	Pitch,
	Volume,
	Pan,
	Choke,
	Eq_Low,
	Eq_Mid,
	Eq_High,
	Slices,
	Inserts,
	Insert_Param,
	Bus,
	Mute,
	Solo,
	Send_0, // a send's level (one field per bus, so drags of different sends don't merge)
	Send_1, Send_2, Send_3, Send_4, Send_5, Send_6, Send_7, Send_8,
	Send_9, Send_10, Send_11, Send_12, Send_13, Send_14, Send_15,
	Send_Pre,
	Fades,
	Kind,
	Midi_Fx, // its MIDI effects (note repeat, the arpeggiator)
	Input,
	Monitor,
	Midi_In,
	Midi_Out,
	Voice, // a field of the voice (see `set_voice`)
	Warp,
	Slicer, // a slicer's slices or settings (see `set_slicer`)
	Synth,  // a synth's patch (see `set_synth_value`)
	Instrument,       // a plug-in pad's instrument (see `set_instrument`)
	Instrument_Param, // one of its parameters (drags merge)
	Plugin_Lanes,     // which parameters its lanes move
	Frozen,           // frozen or not
	Cue,              // its cue send
}

// Changes one setting of pad `index`'s voice, undoably: `key` names the
// setting (drags of the same one merge into one step), `name` the step.
set_voice :: proc(m: ^Model, index: int, key: int, name: string, v: Voice) {
	if index < 0 || index >= PADS do return
	old := m.project.pads[index]
	if old.voice == v do return
	new := old
	new.voice = v
	app.set_value(&m.history, name, {app.Id(index + 1), int(Pad_Field.Voice) * 1000 + key}, old, new, apply_pad)
}

// Prepares the model for a project in `dir` on `host`.
model_init :: proc(m: ^Model, host: ^app.Host, dir: string, bus: ^app.Bus = nil) -> fc.Error {
	project_init(&m.project, dir)
	app.history_init(&m.history, m, bus = bus)
	m.engine.preview = {volume = -6, auto_play = true}
	return engine_init(&m.engine, host, &m.project)
}

// Frees the model.
model_destroy :: proc(m: ^Model) {
	engine_destroy(&m.engine)
	app.history_destroy(&m.history)
	project_destroy(&m.project)
}

// Changes pad `index` to `new`, undoably, as an edit of `field` named
// `name` ("Set Volume").
set_pad :: proc(m: ^Model, index: int, field: Pad_Field, name: string, new: Pad) {
	if index < 0 || index >= PADS do return
	old := m.project.pads[index]
	if old == new do return
	// A pad given its first sound gets a colour of its own (unless this
	// edit sets one).
	new := new
	if !pad_in_use(old) && pad_in_use(new) && new.color == old.color do new.color = next_pad_color(&m.project, index)
	app.set_value(&m.history, name, {app.Id(index + 1), int(field)}, old, new, apply_pad)
}

// Whether a pad (not yet in a project) has a sound.
@(private)
pad_in_use :: proc(pad: Pad) -> bool {
	return pad.sample != 0 || pad.kind == .Audio || pad.kind == .Slicer || pad.kind == .Synth || pad.kind == .Plugin
}

// The colours new pads take, in turn.
PAD_COLORS := [12]u32{0xff5f57, 0xff9f43, 0xffe066, 0x7bd88f, 0x3fc7c4, 0x58a6ff, 0x7c6cff, 0xc77dff, 0xff6fae, 0xd4a373, 0x5ad1a5, 0x4fc3f7}

// The colour for pad `index`'s first sound: the one fewest pads have
// (and, of those, unlike the pads beside it), starting where its place
// in the grid falls in the palette.
next_pad_color :: proc(p: ^Project, index: int) -> u32 {
	n := len(PAD_COLORS)
	uses: [len(PAD_COLORS)]int
	for k in 0 ..< PADS do if k != index && pad_used(p, k) {
		for c, j in PAD_COLORS do if p.pads[k].color == c do uses[j] += 1
	}
	neighbour :: proc(p: ^Project, index: int, c: u32) -> bool {
		for d in ([]int{-1, 1, -4, 4}) {
			k := index + d
			if k >= 0 && k < PADS && k / PADS_PER_BANK == index / PADS_PER_BANK && pad_used(p, k) && p.pads[k].color == c do return true
		}
		return false
	}
	best, score := index % n, max(int)
	for o in 0 ..< n {
		j := (index + o) % n
		s := uses[j] * 2 + (1 if neighbour(p, index, PAD_COLORS[j]) else 0)
		if s < score do best, score = j, s
	}
	return PAD_COLORS[best]
}

@(private)
apply_pad :: proc(ctx: rawptr, key: app.Key, value: Pad) {
	m := (^Model)(ctx)
	i := int(key.id) - 1
	m.project.pads[i] = value
	mark(&m.engine, i)
}

// Copies the audio file at `path` into the project's samples folder and
// adds it to the project, undoably. Returns its id.
import_sample :: proc(m: ^Model, path: string) -> (id: app.Id, err: fc.Error) {
	r, aerr := audiofile.open(path)
	if aerr != .None do return 0, .Invalid_Data
	info := audiofile.info(r)
	audiofile.close(r)
	dir, _ := filepath.join({m.project.dir, "samples"}, context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return 0, .Device_Error // existing is fine
	dest := unique_path(dir, filepath.base(path))
	defer delete(dest) // the project keeps its own copy of the path
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return 0, .Device_Error
	if os.write_entire_file(dest, data) != nil do return 0, .Device_Error
	return add_sample(m, dest, info), .None
}

// Adds a sample already in the project's folder (a recording, an edit's
// result), undoably. Returns its id.
add_sample :: proc(m: ^Model, path: string, info: audiofile.Info) -> app.Id {
	p := &m.project
	id := app.new_id(&p.ids)
	s := Sample{
		name = intern(p, strings.trim_suffix(filepath.base(path), filepath.ext(path))),
		path = intern(p, path), frames = info.frames, rate = info.sample_rate, channels = info.channels,
	}
	app.execute(&m.history, {vtable = &add_sample_vtable, data = new_clone(Add_Sample{id, s}), name = "Add Sample"})
	return id
}

@(private)
Add_Sample :: struct {
	id:     app.Id,
	sample: Sample,
}

@(private)
add_sample_vtable := app.Command_VTable {
	apply = proc(data: rawptr, ctx: rawptr) {
		c := (^Add_Sample)(data)
		app.store_add(&(^Model)(ctx).project.samples, c.id, c.sample)
	},
	revert = proc(data: rawptr, ctx: rawptr) {
		app.store_remove(&(^Model)(ctx).project.samples, (^Add_Sample)(data).id)
	},
}

// Puts sample `id` on pad `index` (keeping the pad's settings, resetting
// its region), named after the sample. One undo step.
assign_sample :: proc(m: ^Model, index: int, id: app.Id) {
	s := app.store_get(&m.project.samples, id)
	if s == nil do return
	pad := m.project.pads[index]
	pad.sample = id
	pad.start, pad.end, pad.loop_start, pad.loop_end = 0, 0, 0, 0
	pad.slice_count = 0
	set_pad_name(&pad, s.name)
	set_pad(m, index, .Whole, "Assign Sample", pad)
}

// Imports `path` and puts it on pad `index`, as one undo step.
load_onto_pad :: proc(m: ^Model, index: int, path: string) -> fc.Error {
	app.begin(&m.history, "Load Sample")
	defer app.end(&m.history)
	id := import_sample(m, path) or_return
	assign_sample(m, index, id)
	return .None
}

// Copies pad `index` (its sample, settings, voice and, for an audio pad,
// its takes) onto the next empty pad after it: one undo step. Returns that
// pad, or -1 when none is free.
duplicate_pad :: proc(m: ^Model, index: int) -> int {
	to := -1
	for k in 1 ..< PADS do if i := (index + k) % PADS; !pad_used(&m.project, i) {
		to = i
		break
	}
	if to < 0 do return -1
	app.begin(&m.history, "Duplicate Pad")
	defer app.end(&m.history)
	set_pad(m, to, .Whole, "Duplicate Pad", m.project.pads[index])
	for slot in 0 ..< SLOTS do if c := m.project.clips[slot][index]; c.sample != 0 do copy_clip(m, slot, index, slot, to, "Duplicate Pad")
	app.seal(&m.history)
	return to
}

// Empties pad `index`.
clear_pad :: proc(m: ^Model, index: int) {
	app.begin(&m.history, "Clear Pad")
	defer app.end(&m.history)
	set_pad(m, index, .Whole, "Clear Pad", default_pad())
	for slot in 0 ..< SLOTS do set_clip(m, slot, index, "Clear Pad", {}) // an audio pad's takes
	m.engine.armed[index] = false
}

// The sample a pad plays, or nil.
pad_sample :: proc(m: ^Model, index: int) -> ^Sample {
	return app.store_get(&m.project.samples, m.project.pads[index].sample)
}

// `dir/name`, or `dir/name 2.ext`, `dir/name 3.ext`... whichever is free.
@(private)
unique_path :: proc(dir, name: string) -> string {
	p, _ := filepath.join({dir, name})
	if !os.exists(p) do return p
	ext := filepath.ext(name)
	stem := strings.trim_suffix(name, ext)
	for n := 2; ; n += 1 {
		delete(p)
		p, _ = filepath.join({dir, strings.concatenate({stem, " ", itoa(n), ext}, context.temp_allocator)})
		if !os.exists(p) do return p
	}
}

// Sets the project's tempo, undoably (drags merge).
set_bpm :: proc(m: ^Model, bpm: f64) {
	new := clamp(bpm, 40, 300)
	if new == m.project.bpm do return
	app.set_value(&m.history, "Set Tempo", {0, 1}, m.project.bpm, new, proc(ctx: rawptr, key: app.Key, value: f64) {
		(^Model)(ctx).project.bpm = value
	})
}

// Sets pad `pad`'s MIDI effects (note repeat, the arpeggiator), undoably
// (drags of one setting merge: seal when they end).
set_midi_fx :: proc(m: ^Model, pad: int, fx: Perform, name := "MIDI Effect") {
	if pad < 0 || pad >= PADS do return
	p := m.project.pads[pad]
	if p.midi_fx == fx do return
	p.midi_fx = fx
	set_pad(m, pad, .Midi_Fx, name, p)
}

// Makes MIDI key `key` play pad `pad` (-1: nothing), undoably. Another key
// that played `pad` keeps playing it.
learn_midi :: proc(m: ^Model, key: int, pad: int) {
	if key < 0 || key > 127 do return
	old := m.project.midi_map[key]
	new := i16(clamp(pad, -1, PADS - 1))
	if old == new do return
	app.set_value(&m.history, "MIDI Learn", {0, 100 + key}, old, new, proc(ctx: rawptr, k: app.Key, v: i16) {
		(^Model)(ctx).project.midi_map[k.field - 100] = v
	})
	app.seal(&m.history)
}

// The MIDI key that plays pad `pad` (the lowest, if several), or -1.
midi_key_of :: proc(m: ^Model, pad: int) -> int {
	for p, k in m.project.midi_map do if int(p) == pad do return k
	return -1
}
