package pads_model

import "base:intrinsics"
import "core:math"

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
	resend:    bool, // send every pad's parameters again (automation moved them)
	stopped:   bool, // stopped by `stop`: automation is off until `play`
	mixer:     Mixer_Nodes,
	mix_dirty: bool, // a bus or performance effect changed
	built_perform: Perform, // what the router's effects have
	perform_sent:  bool,
}

// What a pad has in the graph.
Pad_Nodes :: struct {
	live:    bool,
	voice:   graph.Node_Id, // the sampler
	eq:      graph.Node_Id,
	handle:  ^sampler.Sampler,
	built:   Pad, // the pad as the engine has it
	// Automation of the current sequence: one player into the sampler, one
	// into the EQ.
	auto_voice, auto_eq: graph.Node_Id,
	voice_player, eq_player: ^clip.Automation_Player,
	automated: bool, // it has lanes now (its parameters are the sequence's while playing)
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
	graph.connect_events(g, e.router_id, graph.OUTPUT) // pads' MIDI out
	e.metro_id = graph.add_node(g, dsp.metronome_create({timeline = e.timeline}), 0, 2) or_return
	for c in 0 ..< 2 do graph.connect(g, e.metro_id, c, graph.OUTPUT, c)
	build_mixer(e) or_return
	e.bpm, e.metro_on = 0, true // the node starts on: sync sets what the project wants
	e.perform_sent = false
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
		e.router.midi_out[i] = pad.midi_out
		if src == nil {
			if n.live {
				graph.remove_node(g, n.voice)
				graph.remove_node(g, n.eq)
				graph.remove_node(g, n.auto_voice)
				graph.remove_node(g, n.auto_eq)
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
			vnode, vp, _ := clip.automation_player_create({timeline = e.timeline})
			enode, ep, _ := clip.automation_player_create({timeline = e.timeline})
			n.voice_player, n.eq_player = vp, ep
			n.auto_voice, _ = graph.add_node(g, vnode, 0, 0)
			n.auto_eq, _ = graph.add_node(g, enode, 0, 0)
			graph.connect_events(g, n.auto_voice, sid)
			graph.connect_events(g, n.auto_eq, eid)
			e.seq_dirty = true // its automation
			for c in 0 ..< 2 do graph.connect(g, sid, c, eid, c) // the EQ into the pad's strip (sync_mixer)
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
		fresh := n.built.sample == 0 || e.resend
		set(g, n.voice, sampler.SAMPLER_PARAM_GAIN_DB, n.built.volume, pad.volume, fresh)
		set(g, n.voice, sampler.SAMPLER_PARAM_TRANSPOSE, n.built.pitch, pad.pitch, fresh)
		set(g, n.voice, sampler.SAMPLER_PARAM_ATTACK, n.built.attack, pad.attack, fresh)
		set(g, n.voice, sampler.SAMPLER_PARAM_RELEASE, n.built.release, pad.release, fresh)
		for b in 0 ..< 3 do set(g, n.eq, dsp.eq_band_param(b, .Gain_Db), n.built.eq[b], pad.eq[b], fresh)
		n.built = pad
	}
	if sync_mixer(e) do structural = true
	if structural do graph.commit(g)
	e.resend = false
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
	e.router.midi_map = p.midi_map
	if !e.perform_sent || e.built_perform != p.perform {
		if rt.spsc_push(&e.router.settings, p.perform) do e.built_perform, e.perform_sent = p.perform, true
	}
	if !e.seq_dirty do return
	e.seq_dirty = false
	s := p.sequences[p.slot]
	c := build_clip(s)
	if c == nil do return
	clip.midi_player_set(e.player, c, {loop = true})
	clip.midi_clip_release(c)
	transport.set_loop(e.host.clock, e.timeline, 0, tb.Beats(seq_beats(s)))
	if !e.stopped do sync_automation(e, s)
}

// Each live pad's automation players get its lanes of sequence `s`.
@(private)
sync_automation :: proc(e: ^Engine, s: Sequence) {
	length := tb.Beats(seq_beats(s))
	for &n, i in e.nodes {
		if !n.live do continue
		has := false
		for p in s.points do if int(p.pad) == i do has = true
		if !has {
			if n.automated {
				clip.automation_player_set(n.voice_player, nil, {})
				clip.automation_player_set(n.eq_player, nil, {})
				n.automated = false
				e.resend = true // the pad's own values again
				mark(e, i)
			}
			continue
		}
		voice, eq: clip.Automation_Builder
		clip.automation_builder_init(&voice, length, context.temp_allocator)
		clip.automation_builder_init(&eq, length, context.temp_allocator)
		for p in s.points do if int(p.pad) == i && tb.Beats(p.beat) <= length {
			at := tb.Beats(p.beat)
			v := f64(p.value)
			switch p.param {
			case .Volume:  clip.automation_add_point(&voice, sampler.SAMPLER_PARAM_GAIN_DB, at, v)
			case .Pitch:   clip.automation_add_point(&voice, sampler.SAMPLER_PARAM_TRANSPOSE, at, math.round(v), .Step)
			case .Eq_Low:  clip.automation_add_point(&eq, dsp.eq_band_param(0, .Gain_Db), at, v)
			case .Eq_Mid:  clip.automation_add_point(&eq, dsp.eq_band_param(1, .Gain_Db), at, v)
			case .Eq_High: clip.automation_add_point(&eq, dsp.eq_band_param(2, .Gain_Db), at, v)
			}
		}
		for b in ([]^clip.Automation_Builder{&voice, &eq}) do clip.automation_set_loop(b, 0, length)
		vc, _ := clip.automation_build(&voice)
		ec, _ := clip.automation_build(&eq)
		clip.automation_player_set(n.voice_player, vc, {loop = true})
		clip.automation_player_set(n.eq_player, ec, {loop = true})
		if vc != nil do clip.automation_clip_release(vc)
		if ec != nil do clip.automation_clip_release(ec)
		clip.automation_builder_destroy(&voice)
		clip.automation_builder_destroy(&eq)
		n.automated = true
	}
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
		i := clip.add_note(&b, start, max(end - start, 1e-3), pad_key(int(n.pad)), n.velocity, channel = SEQ_CHANNEL, probability = n.probability)
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
	if e.stopped {
		e.stopped = false
		sync_automation(e, e.project.sequences[e.project.slot])
	}
	transport.locate(e.host.clock, e.timeline, 0)
	transport.play(e.host.clock, e.timeline)
}

// Stops it (and goes back to the top). Pads the automation moved get their
// own settings back.
stop :: proc(e: ^Engine) {
	transport.stop(e.host.clock, e.timeline)
	transport.locate(e.host.clock, e.timeline, 0)
	// Automation lets go of the pads (a locate would set them again), and
	// comes back with the next play.
	for &n, i in e.nodes do if n.automated {
		clip.automation_player_set(n.voice_player, nil, {})
		clip.automation_player_set(n.eq_player, nil, {})
		n.automated = false
		e.resend = true
		mark(e, i)
	}
	e.stopped = true
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

// Plays pad `index` (from the UI): `on` false releases it. A `keyboard`
// hit plays the pad `pitch` semitones from its own pitch, as one note of
// many (keyboard mode, chords); its release must give the same pitch.
hit :: proc(e: ^Engine, index: int, on: bool, velocity: f32 = 1, pitch: i8 = 0, keyboard := false) -> bool {
	return rt.spsc_push(&e.router.queue, Hit{u8(index), on, velocity, pitch, keyboard})
}

