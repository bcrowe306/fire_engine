package pads_model

import app "app:core"
import fc "fire:core"
import "fire:graph"
import "fire:synth"

// The engine's side of synth pads: their wavetables and samples (made
// once, shared), and keeping each synth node up to date.

// Wavetables and samples synths play, made the first time asked for and
// kept while the engine lives (a patch handed to a node only points to
// them).
Synth_Cache :: struct {
	tables:  [synth.Builtin_Table]^synth.Wavetable,
	noise:   [synth.Builtin_Noise]^synth.Sample,
	imported_tables:  map[app.Id]^synth.Wavetable,
	imported_samples: map[app.Id]^synth.Sample,
}

// Frees what the cache made (once no synth node can be playing it).
synth_cache_destroy :: proc(c: ^Synth_Cache) {
	for t in c.tables do synth.wavetable_destroy(t)
	for s in c.noise do synth.sample_destroy(s)
	for _, t in c.imported_tables do synth.wavetable_destroy(t)
	for _, s in c.imported_samples do synth.sample_destroy(s)
	delete(c.imported_tables)
	delete(c.imported_samples)
	c^ = {}
}

// The wavetable a choice names (made now if it is new): a built-in, or
// a sample read as frames of 2048 (a shorter one stretched into one).
synth_table :: proc(e: ^Engine, src: Synth_Source) -> ^synth.Wavetable {
	c := &e.synth_cache
	if src.sample == 0 {
		b := synth.Builtin_Table(min(src.builtin, u8(max(synth.Builtin_Table))))
		if c.tables[b] == nil do c.tables[b], _ = synth.builtin_table(b)
		return c.tables[b]
	}
	if t, ok := c.imported_tables[src.sample]; ok do return t
	s := app.store_get(&e.project.samples, src.sample)
	if s == nil do return nil
	a, err := read_audio(s.path, context.temp_allocator)
	if err != .None || len(a.channels) == 0 do return nil
	t := table_from_audio(s.name, a)
	if t != nil do c.imported_tables[src.sample] = t
	return t
}

// A wavetable from audio: its mono sum cut into frames of 2048 (up to
// 256); shorter than a frame, stretched to one.
table_from_audio :: proc(name: string, a: Audio) -> ^synth.Wavetable {
	n := len(a.channels[0])
	mono := make([]f32, n, context.temp_allocator)
	for ch in a.channels do for v, i in ch do mono[i] += v / f32(len(a.channels))
	frames := clamp(n / synth.WAVE_SIZE, 0, synth.WAVE_FRAMES)
	keys := make([dynamic][]f32, context.temp_allocator)
	if frames == 0 {
		f := make([]f32, synth.WAVE_SIZE, context.temp_allocator)
		for &v, i in f {
			x := f64(i) * f64(n) / synth.WAVE_SIZE
			j := int(x)
			t := f32(x - f64(j))
			v = mono[j] + (mono[(j + 1) % n] - mono[j]) * t
		}
		append(&keys, f)
	} else {
		for k in 0 ..< frames do append(&keys, mono[k * synth.WAVE_SIZE:(k + 1) * synth.WAVE_SIZE])
	}
	t, _ := synth.wavetable_make(name, keys[:])
	return t
}

// The sample oscillator's sound a choice names: built-in noise, or a
// sample read whole.
synth_sample :: proc(e: ^Engine, src: Synth_Source) -> ^synth.Sample {
	c := &e.synth_cache
	if src.sample == 0 {
		b := synth.Builtin_Noise(min(src.builtin, u8(max(synth.Builtin_Noise))))
		if c.noise[b] == nil do c.noise[b], _ = synth.builtin_noise(b)
		return c.noise[b]
	}
	if s, ok := c.imported_samples[src.sample]; ok do return s
	smp := app.store_get(&e.project.samples, src.sample)
	if smp == nil do return nil
	a, err := read_audio(smp.path, context.temp_allocator)
	if err != .None || len(a.channels) == 0 do return nil
	s, _ := synth.sample_make(smp.name, a.channels[:min(len(a.channels), 2)], a.rate)
	if s != nil do c.imported_samples[src.sample] = s
	return s
}

// Brings synth pad `i`'s node up to date: the parameters that changed
// (all of them when `fresh`), and a new patch when its routes, shapes,
// tables or sample did.
sync_synth :: proc(e: ^Engine, i: int, n: ^Pad_Nodes, pad: ^Pad, fresh: bool) {
	g := e.host.graph
	was, now := &n.built.synth, &pad.synth
	// A few changed values go as parameter events; many (a new synth, a
	// pasted patch) go with a patch: the graph holds 64 changes a node.
	changed := 0
	if !fresh do for spec in synth.PARAMS do if was.values[spec.id] != now.values[spec.id] do changed += 1
	bulk := fresh || changed > 48
	if !bulk && changed > 0 do for spec in synth.PARAMS {
		id := spec.id
		if was.values[id] != now.values[id] do graph.set_param(g, n.voice, id, f64(now.values[id]))
	}
	if bulk || was.route_count != now.route_count || was.routes != now.routes || was.shapes != now.shapes || was.tables != now.tables || was.sample != now.sample {
		p := synth.patch_default()
		if bulk {
			p.values = now.values
			p.has_values = true
		}
		p.route_count = now.route_count
		p.routes = now.routes
		p.shapes = now.shapes
		for k in 0 ..< synth.OSCS do p.tables[k] = synth_table(e, now.tables[k])
		p.sample = synth_sample(e, now.sample)
		synth.synth_set_patch(n.synth, &p)
	}
	synth.synth_collect(n.synth)
}

// What synth pad `index` is doing now (its newest voice), for drawing.
synth_live :: proc(e: ^Engine, index: int) -> (synth.Synth_Live, bool) {
	n := &e.nodes[index]
	if !n.live || n.synth == nil do return {}, false
	return synth.synth_live(n.synth), true
}

// The wavetable oscillator `osc` (0-based) of pad `index` plays, for
// drawing (nil if none).
synth_pad_table :: proc(e: ^Engine, index: int, osc: int) -> ^synth.Wavetable {
	return synth_table(e, e.project.pads[index].synth.tables[osc])
}

_ :: fc.Param_Id
