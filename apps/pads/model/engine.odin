package pads_model

import "base:intrinsics"
import "core:mem"

import app "app:core"
import fc "fire:core"
import "fire:clip"
import "fire:dsp"
import "fire:graph"
import "fire:rt"
import "fire:sampler"
import "fire:stream"
import tb "fire:timebase"
import "fire:transport"

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
	// The sequencer: a timeline, the player of the current sequence (into
	// the router), and the metronome.
	timeline:  fc.Timeline_Id,
	player:    ^clip.Midi_Player,
	player_id: graph.Node_Id,
	metro_id:  graph.Node_Id,
	seq_dirty: bool, // the current sequence (or the slot) changed
	bpm:       f64,  // the tempo the clock has
	metronome: bool, // the click is on (set it, then `sync`)
	metro_on:  bool, // what the metronome node has
}

// What a pad has in the graph.
Pad_Nodes :: struct {
	live:    bool,
	voice:   graph.Node_Id, // the sampler
	eq:      graph.Node_Id,
	handle:  ^sampler.Sampler,
	built:   Pad, // the pad as the engine has it
}

// Adds the router, the sequencer and the metronome to the host's graph and
// marks every pad to be built.
engine_init :: proc(e: ^Engine, host: ^app.Host, project: ^Project) -> fc.Error {
	e.host, e.project = host, project
	e.sources = make(map[app.Id]^stream.Source)
	return build_fixed(e)
}

// The host made a new graph (a new sample rate): build everything again in
// it from the model. Subscribe this to `app.Host_Engine_Changed`.
engine_rebuild :: proc(e: ^Engine) -> fc.Error {
	e.nodes = {}
	return build_fixed(e)
}

// The nodes every project has, then every pad.
@(private)
build_fixed :: proc(e: ^Engine) -> fc.Error {
	g := e.host.graph
	e.timeline = transport.add_timeline(e.host.clock) or_return
	node, r := router_create()
	e.router = r
	r.timeline = e.timeline
	e.router_id = graph.add_node(g, node, 0, 0) or_return
	graph.connect_events(g, graph.INPUT, e.router_id) // MIDI in reaches the router
	pnode, player := clip.midi_player_create({timeline = e.timeline})
	e.player = player
	e.player_id = graph.add_node(g, pnode, 0, 0) or_return
	graph.connect_events(g, e.player_id, e.router_id)
	e.metro_id = graph.add_node(g, dsp.metronome_create({timeline = e.timeline}), 0, 2) or_return
	for c in 0 ..< 2 do graph.connect(g, e.metro_id, c, graph.OUTPUT, c)
	e.bpm, e.metro_on = 0, true // the node starts on: sync sets what the project wants
	e.seq_dirty = true
	mark_all(e)
	graph.commit(g) or_return
	sync(e)
	return .None
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
	sync_sequencer(e)
}

// The tempo, the click and the current sequence.
@(private)
sync_sequencer :: proc(e: ^Engine) {
	p := e.project
	if e.bpm != p.bpm {
		transport.set_tempo(e.host.clock, p.bpm)
		e.bpm = p.bpm
	}
	if e.metro_on != e.metronome {
		graph.set_param(e.host.graph, e.metro_id, dsp.METRONOME_PARAM_ON, 1 if e.metronome else 0)
		e.metro_on = e.metronome
	}
	if !e.seq_dirty do return
	e.seq_dirty = false
	s := p.sequences[p.slot]
	c := build_clip(s)
	if c == nil do return
	clip.midi_player_set(e.player, c, {loop = true})
	clip.midi_clip_release(c)
	transport.set_loop(e.host.clock, e.timeline, 0, tb.Beats(seq_beats(s)))
}

// The clip that plays sequence `s`: its notes on the pads' keys, swung,
// with their chance and pitch.
build_clip :: proc(s: Sequence) -> ^clip.Midi_Clip {
	length := seq_beats(s)
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, tb.Beats(length))
	defer clip.midi_builder_destroy(&b)
	clip.set_loop(&b, 0, tb.Beats(length))
	g := tb.Beats(grid_beats(s.swing_grid))
	for n in s.notes {
		if n.start >= length || int(n.pad) >= PADS do continue
		start := clip.swing(tb.Beats(n.start), g, f64(s.swing))
		end := clip.swing(tb.Beats(min(n.start + n.length, length)), g, f64(s.swing))
		i := clip.add_note(&b, start, max(end - start, 1e-3), pad_key(int(n.pad)), n.velocity, probability = n.probability)
		if n.pitch != 0 do clip.add_expression(&b, i, 0, .Tuning, f64(n.pitch))
	}
	c, err := clip.midi_build(&b)
	return c if err == .None else nil
}

// How many times pad `index` has sounded, from any source (to light it).
struck :: proc(e: ^Engine, index: int) -> u32 {
	return intrinsics.atomic_load(&e.router.struck[index])
}

// Starts the sequencer from the top of the sequence.
play :: proc(e: ^Engine) {
	transport.locate(e.host.clock, e.timeline, 0)
	transport.play(e.host.clock, e.timeline)
}

// Stops it (and goes back to the top).
stop :: proc(e: ^Engine) {
	transport.stop(e.host.clock, e.timeline)
	transport.locate(e.host.clock, e.timeline, 0)
}

// Where the sequencer is, in beats into the sequence, and whether it plays.
position :: proc(e: ^Engine) -> (beat: f64, playing: bool) {
	pos, on, _ := transport.timeline_status(e.host.clock, e.timeline)
	return f64(pos), on
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

// Plays pad `index` (from the UI), `pitch` semitones from its own pitch:
// `on` false releases it.
hit :: proc(e: ^Engine, index: int, on: bool, velocity: f32 = 1, pitch: i8 = 0) -> bool {
	return rt.spsc_push(&e.router.queue, Hit{u8(index), on, velocity, pitch})
}

// --- the router ----------------------------------------------------------------------------

// A pad hit, from the UI thread to the router.
Hit :: struct {
	pad:      u8,
	on:       bool,
	velocity: f32,
	pitch:    i8, // semitones (keyboard mode)
}

// A hit as the router played it, back to the UI while capturing (for
// recording into a sequence): where the sequencer was when it sounded.
Taken :: struct {
	using hit: Hit,
	beat:    f64,  // the timeline's position at the hit
	playing: bool, // the sequencer was playing
}

// Turns pad hits into notes for the pads' samplers: key `pad_key(i)` for
// pad i. Hitting a pad chokes the other pads of its choke group; a Hold pad
// stops on its second hit; Gate and Loop pads stop on release. Notes from
// the sequencer and from MIDI in get the same choke groups and Hold, and
// pass through. Fields written by the control thread (`groups`, `modes`,
// `capture`) are read by the audio thread; a torn byte is harmless.
Router :: struct {
	queue:    rt.Spsc_Queue(Hit),
	taken:    rt.Spsc_Queue(Taken), // to the UI, while `capture`
	capture:  bool,
	timeline: fc.Timeline_Id,
	groups:   [PADS]u8,
	modes:    [PADS]Pad_Mode,
	holding:  [PADS]bool, // audio thread: Hold pads sounding
	next_id:  fc.Note_Id, // audio thread: ids for the UI's pitched notes
	sounding: [PADS][4]fc.Note_Id, // audio thread: the UI's pitched notes per pad, to release
	played:   u64, // atomic: hits played (for tests and meters)
	struck:   [PADS]u32, // atomic: times each pad has sounded (the UI lights pads when these move)
}

@(private)
router_vtable := fc.Node_VTable {
	prepare = proc(self: rawptr, cfg: fc.Prepare_Config, a: mem.Allocator) -> fc.Error { return .None },
	process = router_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {
		r := (^Router)(self)
		rt.spsc_destroy(&r.queue, a)
		rt.spsc_destroy(&r.taken, a)
		free(r, a)
	},
}

@(private)
router_create :: proc(allocator := context.allocator) -> (fc.Node, ^Router) {
	r := new(Router, allocator)
	rt.spsc_init(&r.queue, 256, allocator)
	rt.spsc_init(&r.taken, 1024, allocator)
	r.next_id = 1 << 30 // apart from the sequencer's ids
	return fc.node_make(&router_vtable, r, allocator), r
}

// The pad a key plays, or -1.
@(private)
pad_of_key :: proc "contextless" (key: u8) -> int {
	i := int(key) - PAD_KEY_BASE
	return i if i >= 0 && i < PADS else -1
}

// [rt] Before pad `i` sounds: choke its group. False if it should not sound
// (a Hold pad hit a second time stops instead).
@(private)
router_strike :: proc "contextless" (r: ^Router, out: ^fc.Event_Writer, offset: u32, i: int) -> bool {
	if r.modes[i] == .Hold && r.holding[i] {
		fc.event_writer_push(out, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = pad_key(i)}})
		r.holding[i] = false
		return false
	}
	if g := r.groups[i]; g != 0 {
		for other in 0 ..< PADS do if other != i && r.groups[other] == g {
			fc.event_writer_push(out, {offset, fc.Note_Choke{id = fc.NOTE_ID_ANY, key = pad_key(other)}})
			r.holding[other] = false
		}
	}
	if r.modes[i] == .Hold do r.holding[i] = true
	intrinsics.atomic_add(&r.played, 1)
	intrinsics.atomic_add(&r.struck[i], 1)
	return true
}

// [rt]
@(private)
router_process :: proc(self: rawptr, ctx: ^fc.Process_Context) {
	r := (^Router)(self)
	out := ctx.events_out
	if out == nil do return
	for e in ctx.events_in {
		if on, ok := e.payload.(fc.Note_On); ok {
			if i := pad_of_key(on.key); i >= 0 && !router_strike(r, out, e.offset, i) do continue
		}
		fc.event_writer_push(out, e) // the sequencer and MIDI in play pads by key
	}
	beat: f64
	playing := false
	if tl := fc.transport_timeline(ctx.transport, r.timeline); tl != nil {
		beat, playing = f64(tl.position), tl.playing
	}
	for h in rt.spsc_pop(&r.queue) {
		i := int(h.pad)
		if i >= PADS do continue
		key := pad_key(i)
		if h.on {
			if !router_strike(r, out, 0, i) do continue
			if h.pitch == 0 {
				fc.event_writer_push(out, {0, fc.Note_On{id = fc.NOTE_ID_ANY, key = key, velocity = h.velocity}})
			} else {
				// A pitched note gets its own id, so chords of one pad work.
				id := r.next_id
				r.next_id += 1
				fc.event_writer_push(out, {0, fc.Note_On{id = id, key = key, velocity = h.velocity}})
				fc.event_writer_push(out, {0, fc.Note_Expression{id = id, key = key, kind = .Tuning, value = f64(h.pitch)}})
				slots := &r.sounding[i]
				copy(slots[1:], slots[:3])
				slots[0] = id
			}
		} else if r.modes[i] == .Gate || r.modes[i] == .Loop {
			if h.pitch == 0 {
				fc.event_writer_push(out, {0, fc.Note_Off{id = fc.NOTE_ID_ANY, key = key}})
			} else {
				for &id in r.sounding[i] do if id != 0 {
					fc.event_writer_push(out, {0, fc.Note_Off{id = id, key = key}})
					id = 0
				}
			}
		}
		if r.capture do rt.spsc_push(&r.taken, Taken{hit = h, beat = beat, playing = playing})
	}
}
