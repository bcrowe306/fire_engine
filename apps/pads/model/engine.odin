package pads_model

import "base:intrinsics"
import "core:mem"

import app "app:core"
import fc "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:rt"
import "fire:sampler"
import "fire:stream"

// Keeps the engine's graph in step with the project: a sampler and a
// 3-band EQ for every pad with a sample, and the router that turns pad
// hits into notes. Call `sync` once per frame (after commands ran).
// Control thread.
Engine :: struct {
	host:    ^app.Host,
	project: ^Project,
	router:  ^Router,
	router_id: graph.Node_Id,
	nodes:   [PADS]Pad_Nodes,
	dirty:   [PADS]bool,
	sources: map[app.Id]^stream.Source, // opened samples (each retained once)
}

// What a pad has in the graph.
Pad_Nodes :: struct {
	live:    bool,
	voice:   graph.Node_Id, // the sampler
	eq:      graph.Node_Id,
	handle:  ^sampler.Sampler,
	built:   Pad, // the pad as the engine has it
}

// Adds the router to the host's graph and marks every pad to be built.
engine_init :: proc(e: ^Engine, host: ^app.Host, project: ^Project) -> fc.Error {
	e.host, e.project = host, project
	e.sources = make(map[app.Id]^stream.Source)
	node, r := router_create()
	e.router = r
	e.router_id = graph.add_node(host.graph, node, 0, 0) or_return
	graph.connect_events(host.graph, graph.INPUT, e.router_id) // MIDI in reaches the router
	for i in 0 ..< PADS do e.dirty[i] = true
	return graph.commit(host.graph)
}

// The host made a new graph (a new sample rate): build everything again in
// it from the model. Subscribe this to `app.Host_Engine_Changed`.
engine_rebuild :: proc(e: ^Engine) -> fc.Error {
	e.nodes = {}
	node, r := router_create()
	e.router = r
	g := e.host.graph
	e.router_id = graph.add_node(g, node, 0, 0) or_return
	graph.connect_events(g, graph.INPUT, e.router_id)
	mark_all(e)
	sync(e)
	return graph.commit(g)
}

// Releases the samples the engine opened (the graph frees its nodes).
engine_destroy :: proc(e: ^Engine) {
	for _, src in e.sources do stream.source_release(src)
	delete(e.sources)
}

// The engine must look at pad `index` again.
mark :: proc(e: ^Engine, index: int) {
	if index >= 0 && index < PADS do e.dirty[index] = true
}

// Every pad must be looked at again (after loading a project, say).
mark_all :: proc(e: ^Engine) {
	for i in 0 ..< PADS do e.dirty[i] = true
}

// The opened source for a sample (opening it the first time), or nil.
source_of :: proc(e: ^Engine, id: app.Id) -> ^stream.Source {
	if id == 0 do return nil
	if src, ok := e.sources[id]; ok do return src
	s := app.store_get(&e.project.samples, id)
	if s == nil do return nil
	src, err := stream.source_open(e.host.streamer, s.path)
	if err != .None do return nil
	e.sources[id] = src
	return src
}

// Brings every dirty pad up to date in the graph, in one commit if nodes
// were added or removed.
sync :: proc(e: ^Engine) {
	g := e.host.graph
	structural := false
	for i in 0 ..< PADS {
		if !e.dirty[i] do continue
		e.dirty[i] = false
		pad := e.project.pads[i]
		n := &e.nodes[i]
		src := source_of(e, pad.sample)
		e.router.groups[i] = pad.choke
		e.router.modes[i] = pad.mode
		if src == nil {
			if n.live {
				graph.remove_node(g, n.voice)
				graph.remove_node(g, n.eq)
				n^ = {}
				structural = true
			}
			continue
		}
		if !n.live {
			node, handle := sampler.sampler_create({voices = 8, quality = .Sinc_Low})
			n.handle = handle
			sid, err := graph.add_node(g, node, 0, 2)
			if err != .None do continue
			eid, err2 := graph.add_node(g, dsp.eq_create(3), 2, 2)
			if err2 != .None {
				graph.remove_node(g, sid)
				continue
			}
			n.voice, n.eq, n.live = sid, eid, true
			graph.connect_events(g, e.router_id, sid)
			for c in 0 ..< 2 {
				graph.connect(g, sid, c, eid, c)
				graph.connect(g, eid, c, graph.OUTPUT, c)
			}
			structural = true
			n.built = {} // everything below is new
			n.built.sample = 0
		}
		// The sample map: rebuilt when anything the zone holds changed.
		if zone_changed(n.built, pad) {
			m, err := sampler.sample_map_create({zone_of(pad, i, src)})
			if err == .None {
				sampler.sampler_set_map(n.handle, m)
				sampler.sample_map_release(m)
			}
		}
		// Parameters: smoothed changes.
		set :: proc(g: ^graph.Graph, id: graph.Node_Id, p: fc.Param_Id, old, new: f32, fresh: bool) {
			if fresh || old != new do graph.set_param(g, id, p, f64(new))
		}
		fresh := n.built.sample == 0
		set(g, n.voice, sampler.SAMPLER_PARAM_GAIN_DB, n.built.volume, pad.volume, fresh)
		set(g, n.voice, sampler.SAMPLER_PARAM_TRANSPOSE, n.built.pitch, pad.pitch, fresh)
		set(g, n.voice, sampler.SAMPLER_PARAM_ATTACK, n.built.attack, pad.attack, fresh)
		set(g, n.voice, sampler.SAMPLER_PARAM_RELEASE, n.built.release, pad.release, fresh)
		for b in 0 ..< 3 do set(g, n.eq, dsp.eq_band_param(b, .Gain_Db), n.built.eq[b], pad.eq[b], fresh)
		n.built = pad
	}
	if structural do graph.commit(g)
}

// Whether the sample map must be rebuilt to go from `a` to `b`.
@(private)
zone_changed :: proc(a, b: Pad) -> bool {
	return a.sample != b.sample || a.start != b.start || a.end != b.end || a.mode != b.mode ||
		a.loop_start != b.loop_start || a.loop_end != b.loop_end || a.loop_mode != b.loop_mode ||
		a.crossfade != b.crossfade || a.reverse != b.reverse || a.pan != b.pan
}

// The sampler zone that plays `pad`.
zone_of :: proc(pad: Pad, index: int, src: ^stream.Source) -> sampler.Sample_Zone {
	key := pad_key(index)
	loop := pad.mode == .Loop || pad.mode == .Hold
	return {
		source = src, root_key = key, key_lo = key, key_hi = key,
		start = pad.start, end = pad.end,
		loop = loop, loop_start = pad.loop_start if pad.loop_end > 0 else pad.start, loop_end = pad.loop_end,
		loop_mode = pad.loop_mode, crossfade = pad.crossfade,
		one_shot = pad.mode == .One_Shot || pad.mode == .Hold,
		reverse = pad.reverse, pan = f64(pad.pan),
	}
}

// Plays pad `index` (from the UI): `on` false releases it.
hit :: proc(e: ^Engine, index: int, on: bool, velocity: f32 = 1) -> bool {
	return rt.spsc_push(&e.router.queue, Hit{u8(index), on, velocity})
}

// --- the router ----------------------------------------------------------------------------

// A pad hit, from the UI thread to the router.
Hit :: struct {
	pad:      u8,
	on:       bool,
	velocity: f32,
}

// Turns pad hits into notes for the pads' samplers: key `pad_key(i)` for
// pad i. Hitting a pad chokes the other pads of its choke group; a Hold pad
// stops on its second hit; Gate and Loop pads stop on release. Notes from
// the graph's input (MIDI) pass through. Fields written by the control
// thread (`groups`, `modes`) are read by the audio thread; a torn byte is
// harmless.
Router :: struct {
	queue:   rt.Spsc_Queue(Hit),
	groups:  [PADS]u8,
	modes:   [PADS]Pad_Mode,
	holding: [PADS]bool, // audio thread: Hold pads sounding
	played:  u64, // atomic: hits played (for tests and meters)
}

@(private)
router_vtable := fc.Node_VTable {
	prepare = proc(self: rawptr, cfg: fc.Prepare_Config, a: mem.Allocator) -> fc.Error { return .None },
	process = router_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {
		r := (^Router)(self)
		rt.spsc_destroy(&r.queue, a)
		free(r, a)
	},
}

@(private)
router_create :: proc(allocator := context.allocator) -> (fc.Node, ^Router) {
	r := new(Router, allocator)
	rt.spsc_init(&r.queue, 256, allocator)
	return fc.node_make(&router_vtable, r, allocator), r
}

// [rt]
@(private)
router_process :: proc(self: rawptr, ctx: ^fc.Process_Context) {
	r := (^Router)(self)
	out := ctx.events_out
	if out == nil do return
	for e in ctx.events_in do fc.event_writer_push(out, e) // MIDI in plays pads by key
	for h in rt.spsc_pop(&r.queue) {
		i := int(h.pad)
		if i >= PADS do continue
		key := pad_key(i)
		if h.on {
			if r.modes[i] == .Hold && r.holding[i] {
				fc.event_writer_push(out, {0, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = key}})
				r.holding[i] = false
				continue
			}
			if g := r.groups[i]; g != 0 {
				for other in 0 ..< PADS do if other != i && r.groups[other] == g {
					fc.event_writer_push(out, {0, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = pad_key(other)}})
					r.holding[other] = false
				}
			}
			fc.event_writer_push(out, {0, fc.Note_On{id = fc.NOTE_ID_ANY, key = key, velocity = h.velocity}})
			if r.modes[i] == .Hold do r.holding[i] = true
			intrinsics.atomic_add(&r.played, 1)
		} else if r.modes[i] == .Gate || r.modes[i] == .Loop {
			fc.event_writer_push(out, {0, fc.Note_Off{id = fc.NOTE_ID_ANY, key = key}})
		}
	}
}
