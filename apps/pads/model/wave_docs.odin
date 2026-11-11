package pads_model

import "core:strings"
import "core:time"

import app "app:core"
import fc "fire:core"
import "fire:synth"

// The project's own wavetables, as the wavetable editor keeps them: each
// a `synth.Table_Doc` with a name and the sound its audio keyframes
// slice. An oscillator plays one through `Synth_Source.table`.

// A wavetable to edit.
Wave_Doc :: struct {
	name:   [32]u8,
	doc:    synth.Table_Doc,
	sample: app.Id, // the sound audio keyframes slice (0: none)
	gen:    u64,    // changed by every edit (not saved): what the engine rebuilds by
}

// Chunk tag of the project's wavetables.
WAVETABLES_TAG :: fc.Tag{'P', 'W', 'T', 'B'}

@(private)
wave_gen: u64

// Wavetable `id`'s name.
wave_doc_name :: proc(m: ^Model, id: app.Id) -> string {
	d := app.store_get(&m.project.wave_docs, id)
	if d == nil do return ""
	return strings.truncate_to_byte(string(d.name[:]), 0)
}

// Makes a wavetable for oscillator `osc` (0-based) of synth pad `index`
// and points the oscillator at it, as one undo step: the editor's first
// table (a sine to a saw), or (`from_current`) the table it plays now,
// as up to four drawn keyframes. Returns its id.
new_wave_doc :: proc(m: ^Model, index: int, osc: int, from_current := false) -> app.Id {
	p := &m.project
	app.begin(&m.history, "New Wavetable")
	defer app.end(&m.history)
	d: Wave_Doc
	d.doc = synth.table_doc_default()
	name := "Wavetable"
	if from_current {
		if t := synth_pad_table(&m.engine, index, osc); t != nil {
			name = t.name
			n := min(t.frames, 4)
			d.doc.count = n
			for k in 0 ..< n {
				f := k * (t.frames - 1) / max(n - 1, 1)
				key := synth.table_key_default(.Draw, f)
				for &v, i in key.draw do v = t.waves[f][i * synth.WAVE_SIZE / synth.DRAW_POINTS]
				d.doc.keys[k] = key
			}
			d.doc.blend = .Crossfade
		}
	}
	copy(d.name[:len(d.name) - 1], name)
	wave_gen += 1
	d.gen = wave_gen
	id := app.new_id(&p.ids)
	app.execute(&m.history, {vtable = &add_wave_doc_vtable, data = new_clone(Add_Wave_Doc{id, d}), name = "New Wavetable"})
	pad := p.pads[index]
	pad.synth.tables[osc] = {table = id}
	set_pad(m, index, .Synth, "New Wavetable", pad)
	return id
}

@(private)
Add_Wave_Doc :: struct {
	id:  app.Id,
	doc: Wave_Doc,
}

@(private)
add_wave_doc_vtable := app.Command_VTable {
	apply = proc(data: rawptr, ctx: rawptr) {
		c := (^Add_Wave_Doc)(data)
		app.store_add(&(^Model)(ctx).project.wave_docs, c.id, c.doc)
	},
	revert = proc(data: rawptr, ctx: rawptr) {
		app.store_remove(&(^Model)(ctx).project.wave_docs, (^Add_Wave_Doc)(data).id)
	},
}

// Wavetable `id` set to `d` (its edit named `name`: drags under one name
// merge into one undo step; seal the history when one ends).
set_wave_doc :: proc(m: ^Model, id: app.Id, d: Wave_Doc, name: string) {
	old := app.store_get(&m.project.wave_docs, id)
	if old == nil do return
	app.set_value(&m.history, name, {id, 1}, old^, d, proc(ctx: rawptr, k: app.Key, v: Wave_Doc) {
		x := app.store_get(&(^Model)(ctx).project.wave_docs, k.id)
		if x == nil do return
		x^ = v
		wave_gen += 1
		x.gen = wave_gen
		mark_table_users(&(^Model)(ctx).engine, k.id)
	})
}

// The engine must look again at every pad playing table `id`.
@(private)
mark_table_users :: proc(e: ^Engine, id: app.Id) {
	for &pad, i in e.project.pads do for src in pad.synth.tables do if src.table == id do mark(e, i)
}

// --- the engine's side ---------------------------------------------------------------------------

// A project wavetable as built for playing.
@(private)
Built_Doc :: struct {
	table: ^synth.Wavetable,
	gen:   u64,
	at:    time.Tick, // when it was built
}

// A table no patch plays any more, freed a while after it was replaced
// (once every node has taken the patch that replaced it).
@(private)
Retired_Table :: struct {
	table: ^synth.Wavetable,
	at:    time.Tick,
}

// Seconds between rebuilds of a table being edited (a drag rebuilds no
// more often than this).
@(private) REBUILD_SECONDS :: 0.08
// Seconds a replaced table is kept before it is freed.
@(private) RETIRE_SECONDS :: 2.0

// The wavetable project table `id` makes, built now if it is new, and
// again if it changed (but no sooner than `REBUILD_SECONDS` after the
// last build).
@(private)
doc_table :: proc(e: ^Engine, id: app.Id) -> ^synth.Wavetable {
	c := &e.synth_cache
	d := app.store_get(&e.project.wave_docs, id)
	b, had := &c.docs[id]
	if d == nil do return b.table if had else nil
	if had && b.gen == d.gen do return b.table
	if had && b.table != nil && time.duration_seconds(time.tick_since(b.at)) < REBUILD_SECONDS do return b.table
	audio: []f32
	if d.sample != 0 do audio = doc_audio(e, d.sample)
	t, err := synth.table_doc_build(strings.truncate_to_byte(string(d.name[:]), 0), &d.doc, audio)
	if err != .None do return b.table if had else nil
	if had && b.table != nil do append(&c.retired, Retired_Table{b.table, time.tick_now()})
	c.docs[id] = {t, d.gen, time.tick_now()}
	return t
}

// Whether project table `id` changed since it was last built, and
// whether it is due a rebuild yet.
@(private)
doc_stale :: proc(e: ^Engine, id: app.Id) -> (changed, due: bool) {
	d := app.store_get(&e.project.wave_docs, id)
	if d == nil do return false, false
	b, had := e.synth_cache.docs[id]
	if !had do return true, true
	changed = b.gen != d.gen
	return changed, changed && time.duration_seconds(time.tick_since(b.at)) >= REBUILD_SECONDS
}

// A sample's sound as one channel (read once, kept while the engine
// lives).
@(private)
doc_audio :: proc(e: ^Engine, id: app.Id) -> []f32 {
	c := &e.synth_cache
	if a, ok := c.doc_audio[id]; ok do return a
	s := app.store_get(&e.project.samples, id)
	if s == nil do return nil
	a, err := read_audio(s.path, context.temp_allocator)
	if err != .None || len(a.channels) == 0 do return nil
	mono := make([]f32, len(a.channels[0]))
	for ch in a.channels do for v, i in ch do mono[i] += v / f32(len(a.channels))
	c.doc_audio[id] = mono
	return mono
}

// The sound table `id`'s audio keyframes slice (one channel), or nil.
wave_doc_sound :: proc(e: ^Engine, id: app.Id) -> []f32 {
	d := app.store_get(&e.project.wave_docs, id)
	if d == nil || d.sample == 0 do return nil
	return doc_audio(e, d.sample)
}

// Frees the tables replaced more than `RETIRE_SECONDS` ago.
@(private)
free_retired_tables :: proc(e: ^Engine) {
	c := &e.synth_cache
	k := 0
	for r in c.retired {
		if time.duration_seconds(time.tick_since(r.at)) > RETIRE_SECONDS do synth.wavetable_destroy(r.table)
		else {
			c.retired[k] = r
			k += 1
		}
	}
	resize(&c.retired, k)
}
