package pads_model

import "base:intrinsics"
import "core:math"

import app "app:core"
import fc "fire:core"
import "fire:clip"
import "fire:dsp"
import "fire:graph"
import "fire:record"
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
	metro_db:  f32,  // its level, as sent
	recording: bool, // the capture is armed (the metronome may click only then)
	sig:       Time_Sig, // the meter the clock has
	resend:    bool, // send every pad's parameters again (automation moved them)
	stopped:   bool, // stopped by `stop`: automation is off until `play`
	plan:      Plan, // what the sequencer plays
	pending:   struct {
		active: bool,
		slot:   int,
		at:     f64, // timeline beat
	},
	mixer:     Mixer_Nodes,
	export_solo: Export_Solo, // while exporting a stem: what is heard
	export_once: bool,        // while exporting: what plays plays once
	mix_dirty: bool, // a bus or performance effect changed
	built_perform: Perform, // what the router's effects have
	perform_sent:  bool,
	preview:   Preview, // the browser's preview (straight to the output)
	armed:     [PADS]bool, // audio pads armed to record
	audio_dirty: bool,     // a clip changed: give the players theirs again
}

// What a pad has in the graph.
Pad_Nodes :: struct {
	live:    bool,
	voice:   graph.Node_Id, // the sampler
	eq:      graph.Node_Id,
	handle:  ^sampler.Sampler,
	built:   Pad, // the pad as the engine has it
	fader:   graph.Node_Id, // its volume: after its inserts (the mixer wires it)
	// Automation of the current sequence: a player into the sampler, one
	// into the EQ, one into the fader.
	auto_voice, auto_eq, auto_fader: graph.Node_Id,
	voice_player, eq_player, fader_player: ^clip.Automation_Player,
	automated: bool, // it has lanes now (its parameters are the sequence's while playing)
	// An audio pad: no sampler (`voice` sums what it plays), two clip
	// players taking turns, its input through a monitor gain, a recorder.
	audio:      bool,
	players:    [2]^clip.Audio_Player,
	player_ids: [2]graph.Node_Id,
	holds:      [2]Audio_Run, // what each player was given
	monitor_id: graph.Node_Id,
	rec_id:     graph.Node_Id,
	rec:        ^record.Audio_Recorder,
	rec_on, monitor_on: bool, // as sent
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
	keep := e.preview // the settings outlive the nodes
	preview_cancel(&e.preview)
	e.preview = {volume = keep.volume, auto_play = keep.auto_play, sync = keep.sync, path = keep.path}
	build_preview(e) or_return
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
	preview_destroy(&e.preview)
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
	preview_poll(e)
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
		audio := pad.kind == .Audio
		want := src != nil || audio
		// A pad that changes kind (or an audio pad its input) is built again.
		if n.live && (!want || n.audio != audio || (audio && n.built.input != pad.input)) {
			remove_pad_nodes(g, n)
			structural = true
		}
		if !want do continue
		if !n.live {
			voice: fc.Node
			if audio {
				voice = dsp.pan_create() // what the players and the monitor sum into (panned: a sampler's zone pans)
			} else {
				node, handle := sampler.sampler_create({voices = 8, quality = .Sinc_Low})
				n.handle, voice = handle, node
			}
			sid, err := graph.add_node(g, voice, 2 if audio else 0, 2)
			if err != .None do continue
			eid, err2 := graph.add_node(g, dsp.eq_create(3), 2, 2)
			if err2 != .None {
				graph.remove_node(g, sid)
				continue
			}
			fid, err3 := graph.add_node(g, dsp.gain_create(), 2, 2)
			if err3 != .None {
				graph.remove_node(g, sid)
				graph.remove_node(g, eid)
				continue
			}
			n.voice, n.eq, n.fader, n.live = sid, eid, fid, true
			graph.connect_events(g, e.router_id, sid)
			vnode, vp, _ := clip.automation_player_create({timeline = e.timeline})
			enode, ep, _ := clip.automation_player_create({timeline = e.timeline})
			fnode, fp, _ := clip.automation_player_create({timeline = e.timeline})
			n.voice_player, n.eq_player, n.fader_player = vp, ep, fp
			n.auto_voice, _ = graph.add_node(g, vnode, 0, 0)
			n.auto_eq, _ = graph.add_node(g, enode, 0, 0)
			n.auto_fader, _ = graph.add_node(g, fnode, 0, 0)
			graph.connect_events(g, n.auto_voice, sid)
			graph.connect_events(g, n.auto_eq, eid)
			graph.connect_events(g, n.auto_fader, fid)
			e.seq_dirty = true // its automation
			for c in 0 ..< 2 do graph.connect(g, sid, c, eid, c) // the EQ into the pad's strip (sync_mixer)
			if audio do build_audio(e, i, n, pad)
			structural = true
			n.built = {} // everything below is new
			n.built.sample = 0
			n.built.input = pad.input
		}
		if n.audio {
			fresh := n.built.kind != .Audio || e.resend
			if fresh || n.built.volume != pad.volume do graph.set_param(g, n.fader, dsp.GAIN_PARAM_DB, f64(pad.volume))
			if fresh || n.built.pan != pad.pan do graph.set_param(g, n.voice, dsp.PAN_PARAM_POSITION, f64(pad.pan))
			for b in 0 ..< 3 do if fresh || n.built.eq[b] != pad.eq[b] do graph.set_param(g, n.eq, dsp.eq_band_param(b, .Gain_Db), f64(pad.eq[b]))
			n.built = pad
			continue
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
		set(g, n.fader, dsp.GAIN_PARAM_DB, n.built.volume, pad.volume, fresh)
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
	// The metronome: on, and (with "only while recording") while recording
	// or counting in; at its level.
	tr := p.transport
	beat_now, playing_now, _ := transport.timeline_status(e.host.clock, e.timeline)
	counting := playing_now && f64(beat_now) < 0
	click := e.metronome && (!tr.metro_rec_only || e.recording || counting)
	if e.metro_on != click {
		graph.set_param(e.host.graph, e.metro_id, dsp.METRONOME_PARAM_ON, 1 if click else 0)
		e.metro_on = click
	}
	if e.metro_db != tr.metro_db {
		graph.set_param(e.host.graph, e.metro_id, dsp.METRONOME_PARAM_LEVEL_DB, f64(tr.metro_db))
		e.metro_db = tr.metro_db
	}
	// The time signature: the clock's meter (the metronome's accents).
	if e.sig != tr.time_sig && tr.time_sig.num > 0 && tr.time_sig.den > 0 {
		transport.set_meter(e.host.clock, {i32(tr.time_sig.num), i32(tr.time_sig.den)}, transport.When(nil))
		e.sig = tr.time_sig
	}
	e.router.midi_map = p.midi_map
	if !e.perform_sent || e.built_perform != p.perform {
		if rt.spsc_push(&e.router.settings, p.perform) do e.built_perform, e.perform_sent = p.perform, true
	}
	sequencer_tick(e)
	defer sync_audio(e)
	if !e.seq_dirty do return
	e.seq_dirty = false
	// What plays: the song, a sequence about to give way to another, or a
	// sequence looping; placed where it started on the timeline.
	at := e.plan.at
	if p.song_mode && p.song.count > 0 {
		e.plan = plan_song(p, at)
	} else if e.pending.active {
		e.plan = plan_switch(p, plan_pattern(p, e.plan.segs[0].slot if e.plan.count > 0 else p.slot, at), e.pending.slot, e.pending.at)
	} else {
		e.plan = plan_pattern(p, p.slot, at)
	}
	// Once, to its end: while exporting, or with the transport's loop off.
	if e.export_once || !p.transport.loop do e.plan.loop_start, e.plan.loop_end = 0, 0
	c := plan_clip(p, e.plan)
	loops := e.plan.loop_end > e.plan.loop_start
	placement := clip.Placement{at = tb.Beats(e.plan.at), loop = loops}
	if !loops do placement.length = tb.Beats(plan_end(e.plan) - e.plan.at)
	clip.midi_player_set(e.player, c, placement)
	if c != nil do clip.midi_clip_release(c)
	if !e.stopped do sync_automation(e)
}

// Each frame: a queued switch takes over once the playhead passes it, a
// song that doesn't loop stops at its end, and the slot shown follows the
// song.
@(private)
sequencer_tick :: proc(e: ^Engine) {
	p := e.project
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	beat := f64(pos)
	if e.pending.active && playing && beat >= e.pending.at {
		p.slot = e.pending.slot
		e.plan = plan_pattern(p, p.slot, e.pending.at)
		e.pending.active = false
		e.seq_dirty = true
	}
	if !playing do return
	// What doesn't loop stops at its end (not while exporting: the export
	// renders its tail).
	if end := plan_end(e.plan); end > 0 && beat >= end && !e.export_once {
		stop(e)
		return
	}
	if p.song_mode {
		if _, slot, _, ok := plan_locate(e.plan, beat); ok do p.slot = slot // the editor shows what plays
	}
}

// Picks sequence `slot`. Stopped, at once; playing, when the project's
// `switch_at` says (a bar, a beat, the end of what plays), exactly there.
queue_slot :: proc(e: ^Engine, slot: int) {
	p := e.project
	if slot < 0 || slot >= SLOTS do return
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	beat := f64(pos)
	if !playing || p.song_mode {
		p.slot = slot
		e.pending.active = false
		if !playing do e.plan.at = 0
		e.seq_dirty = true
		return
	}
	if slot == p.slot && !e.pending.active do return
	b := beat
	switch p.switch_at {
	case .Now:  b = beat + 1e-6
	case .Beat: b = math.floor(beat + 1e-9) + 1
	case .Bar:  b = (math.floor(beat / bar_beats(p) + 1e-9) + 1) * bar_beats(p)
	case .End:
		l := seq_beats(p, p.sequences[e.plan.segs[0].slot]) if e.plan.count > 0 else bar_beats(p)
		b = e.plan.at + (math.floor((beat - e.plan.at) / l + 1e-9) + 1) * l
	}
	if p.switch_at == .Now {
		p.slot = slot
		e.pending.active = false
		e.plan.at = b
	} else {
		e.pending = {active = true, slot = slot, at = b}
	}
	e.seq_dirty = true
}

// The sequence about to take over and when (in beats from now), if one is
// queued.
pending_switch :: proc(e: ^Engine) -> (slot: int, in_beats: f64, ok: bool) {
	if !e.pending.active do return
	pos, _, _ := transport.timeline_status(e.host.clock, e.timeline)
	return e.pending.slot, e.pending.at - f64(pos), true
}

// The song step playing (song mode), or -1.
song_step :: proc(e: ^Engine) -> int {
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	if !playing || !e.project.song_mode do return -1
	seg, _, _, ok := plan_locate(e.plan, f64(pos))
	if !ok do return -1
	return e.plan.segs[seg].step
}

// Each live pad's automation players get its lanes of what plays.
@(private)
sync_automation :: proc(e: ^Engine) {
	p := e.project
	loops := e.plan.loop_end > e.plan.loop_start
	placement := clip.Placement{at = tb.Beats(e.plan.at), loop = loops}
	if !loops do placement.length = tb.Beats(plan_end(e.plan) - e.plan.at)
	for &n, i in e.nodes {
		if !n.live do continue
		vc, ec, fc_ := plan_automation(p, e.plan, i)
		if n.audio && vc != nil { // an audio pad has no sampler to automate
			clip.automation_clip_release(vc)
			vc = nil
		}
		if vc == nil && ec == nil && fc_ == nil {
			if n.automated {
				clip.automation_player_set(n.voice_player, nil, {})
				clip.automation_player_set(n.eq_player, nil, {})
				clip.automation_player_set(n.fader_player, nil, {})
				n.automated = false
				e.resend = true // the pad's own values again
				mark(e, i)
			}
			continue
		}
		clip.automation_player_set(n.voice_player, vc, placement)
		clip.automation_player_set(n.eq_player, ec, placement)
		clip.automation_player_set(n.fader_player, fc_, placement)
		if vc != nil do clip.automation_clip_release(vc)
		if ec != nil do clip.automation_clip_release(ec)
		if fc_ != nil do clip.automation_clip_release(fc_)
		n.automated = true
	}
}

// How many times pad `index` has sounded, from any source (to light it).
struck :: proc(e: ^Engine, index: int) -> u32 {
	return intrinsics.atomic_load(&e.router.struck[index])
}

// Starts the sequencer from the top of the sequence; with `count_in`, the
// transport's count-in bars of click first (the playhead starts that far
// before the top, where nothing plays and nothing records).
play :: proc(e: ^Engine, count_in := false) {
	e.stopped = false
	e.pending.active = false
	e.plan.at = 0
	if e.project.song_mode && e.project.song.count > 0 do e.project.slot = int(e.project.song.steps[0].slot)
	e.seq_dirty = true
	sync_sequencer(e)
	from := 0.0
	if count_in do from = -f64(clamp(e.project.transport.count_in, 0, 2)) * bar_beats(e.project)
	place_audio(e, from) // the players have what plays from the top before it does
	transport.locate(e.host.clock, e.timeline, tb.Beats(from))
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
		clip.automation_player_set(n.fader_player, nil, {})
		n.automated = false
		e.resend = true
		mark(e, i)
	}
	e.stopped = true
	e.pending.active = false
	e.plan.at = 0
	e.seq_dirty = true
}

// The sample frame pad `index` is playing (its newest voice), or false
// when it is silent: for a playhead over its waveform.
pad_playhead :: proc(e: ^Engine, index: int) -> (frame: i64, playing: bool) {
	n := &e.nodes[index]
	if !n.live || n.handle == nil do return -1, false
	return sampler.sampler_playhead(n.handle)
}

// Where the playhead is on the timeline (negative while counting in), and
// whether it plays.
timeline_beat :: proc(e: ^Engine) -> (beat: f64, playing: bool) {
	pos, on, _ := transport.timeline_status(e.host.clock, e.timeline)
	return f64(pos), on
}

// Where the sequencer is, in beats into the sequence that plays, and
// whether it plays.
position :: proc(e: ^Engine) -> (beat: f64, playing: bool) {
	pos, on, _ := transport.timeline_status(e.host.clock, e.timeline)
	if !on do return 0, false
	_, _, rel, ok := plan_locate(e.plan, f64(pos))
	return rel if ok else 0, true
}

// Whether the sample map must be rebuilt to go from `a` to `b`.
@(private)
zone_changed :: proc(a, b: Pad) -> bool {
	return a.sample != b.sample || a.start != b.start || a.end != b.end || a.mode != b.mode ||
		a.loop_start != b.loop_start || a.loop_end != b.loop_end || a.loop_mode != b.loop_mode ||
		a.crossfade != b.crossfade || a.reverse != b.reverse || a.pan != b.pan ||
		a.fade_in != b.fade_in || a.fade_out != b.fade_out
}

// The sampler zone that plays `pad`.
zone_of :: proc(pad: Pad, index: int, src: ^stream.Source) -> sampler.Sample_Zone {
	key := pad_key(index)
	loop := pad.mode == .Loop || pad.mode == .Hold
	return {
		source = src, root_key = key, key_lo = key, key_hi = key, exact_keys = true, // pad 1 is key 0: only key 0
		start = pad.start, end = pad.end,
		loop = loop, loop_start = pad.loop_start if pad.loop_end > 0 else pad.start, loop_end = pad.loop_end,
		loop_mode = pad.loop_mode, crossfade = pad.crossfade,
		one_shot = pad.mode == .One_Shot || pad.mode == .Hold,
		reverse = pad.reverse, pan = f64(pad.pan),
		fade_in = pad.fade_in, fade_out = pad.fade_out,
	}
}

// Plays pad `index` (from the UI): `on` false releases it. A `keyboard`
// hit plays the pad `pitch` semitones from its own pitch, as one note of
// many (keyboard mode, chords); its release must give the same pitch.
hit :: proc(e: ^Engine, index: int, on: bool, velocity: f32 = 1, pitch: i8 = 0, keyboard := false) -> bool {
	return rt.spsc_push(&e.router.queue, Hit{u8(index), on, velocity, pitch, keyboard})
}


// Takes everything the engine put in the graph out again, and lets go of
// its samples (before loading another project into the model).
engine_clear :: proc(e: ^Engine) {
	g := e.host.graph
	for &n in e.nodes do if n.live do remove_pad_nodes(g, &n)
	for &st in e.mixer.strips do if st.built do remove_strip(g, &st)
	for b in e.mixer.buses {
		for f in b.slots do if f.has do graph.remove_node(g, f.id)
		for f in b.perf do if f.has do graph.remove_node(g, f.id)
		graph.remove_node(g, b.input)
		graph.remove_node(g, b.fader)
		graph.remove_node(g, b.pan)
		graph.remove_node(g, b.meter_id)
	}
	graph.remove_node(g, e.router_id)
	graph.remove_node(g, e.player_id)
	graph.remove_node(g, e.metro_id)
	graph.remove_node(g, e.preview.id)
	graph.remove_node(g, e.preview.gain_id)
	graph.commit(g)
	transport.remove_timeline(e.host.clock, e.timeline)
	engine_destroy(e)
	host := e.host
	pv := e.preview // its settings stay (they are the user's, not the project's)
	e^ = {}
	e.host = host
	e.preview = {volume = pv.volume, auto_play = pv.auto_play, sync = pv.sync}
}

// The samples' files moved (Save As): open them again from their new
// paths.
mark_all_sources_stale :: proc(e: ^Engine) {
	for _, src in e.sources do stream.source_release(src)
	clear(&e.sources)
	for &n in e.nodes do n.built.sample = 0 // their zones again
	mark_all(e)
}
