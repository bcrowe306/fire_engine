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
}

// Prepares the model for a project in `dir` on `host`.
model_init :: proc(m: ^Model, host: ^app.Host, dir: string, bus: ^app.Bus = nil) -> fc.Error {
	project_init(&m.project, dir)
	app.history_init(&m.history, m, bus = bus)
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
	app.set_value(&m.history, name, {app.Id(index + 1), int(field)}, old, new, apply_pad)
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

// Empties pad `index`.
clear_pad :: proc(m: ^Model, index: int) {
	set_pad(m, index, .Whole, "Clear Pad", default_pad())
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

// Sets the live effects (the arpeggiator, note repeat). Not undoable: how
// you play, not what the project holds.
set_perform :: proc(m: ^Model, p: Perform) {
	m.project.perform = p
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
