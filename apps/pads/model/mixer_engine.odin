package pads_model

import "core:math"

import fc "fire:core"
import "fire:fx"
import "fire:synth"
import "fire:clap"
import "fire:dsp"
import "fire:graph"

// What an effect slot needs in the graph: a node of this kind (a plug-in
// from this file). Settings changes don't need a new node; these do.
@(private)
Slot_Key :: struct {
	kind: Effect_Kind,
	path: string,
	id:   string,
	keyed:  bool, // it takes a key (four inputs)
	listen: bool,
}

@(private)
key_of :: proc(s: Effect_Slot) -> Slot_Key {
	keyed := keyable(s.kind) && s.key.kind != .None
	return {s.kind, s.plugin_path, s.plugin_id, keyed, keyed && s.listen}
}

// One effect slot in the graph.
Fx_Node :: struct {
	mix:     f32, // the wet mix it was given (performance effects' intensity)
	inner:   rawptr, // a compressor's, gate's or limiter's own state (for its gain reduction)
	kind:    Effect_Kind,
	has:     bool,
	id:      graph.Node_Id,
	key:     Slot_Key,
	applied: Effect_Slot, // the settings it has
	plugin:  ^clap.Plugin,
	failed:  bool, // a plug-in that would not load
	// Keyed: the key's high-pass (into inputs 3 and 4) and what feeds it.
	key_filter: graph.Node_Id,
	key_src:    graph.Node_Id,
	key_hpf:    f32, // as sent
}

// A pad's chain after its EQ, as a console's channel strip: its inserts,
// its mute and solo, its fader (the pad's own node), its meter, and its
// output; sends tap it before the fader (after the mute) or after the
// meter.
//
//	eq → inserts → gain (mute, solo) → fader → meter → out (export) → bus or main
//	                    └→ pre-fader sends       └→ post-fader sends → buses
Strip :: struct {
	built:   bool,
	from:    graph.Node_Id, // the EQ it was wired from
	fader:   graph.Node_Id, // and the fader
	inserts: [PAD_INSERTS]Fx_Node,
	gain:    graph.Node_Id,
	gain_db: f32,
	meter_id: graph.Node_Id,
	meter:   ^dsp.Meter,
	out:     graph.Node_Id,
	out_db:  f32,
	dest:    int, // the bus it goes to (0 = main)
	sends:   [BUSES]Send_Node,
	cue:     Send_Node, // its cue send
}

// A send of a strip in the graph (a gain into its bus), while it is on.
Send_Node :: struct {
	has: bool,
	id:  graph.Node_Id,
	pre: bool, // where it is wired from
	db:  f32, // what it was set to
}

// [control] Takes strip `st`'s nodes out of the graph.
@(private)
remove_strip :: proc(g: ^graph.Graph, st: ^Strip) {
	for f in st.inserts do if f.has {
		graph.remove_node(g, f.id)
		if f.key_filter != {} do graph.remove_node(g, f.key_filter)
	}
	for s in st.sends do if s.has do graph.remove_node(g, s.id)
	if st.cue.has do graph.remove_node(g, st.cue.id)
	graph.remove_node(g, st.gain)
	graph.remove_node(g, st.meter_id)
	graph.remove_node(g, st.out)
	st^ = {}
}

// A bus (or main) in the graph: a summing point, its effects, its fader,
// pan and meter.
Bus_Nodes :: struct {
	input:   graph.Node_Id, // where its sources sum
	slots:   [BUS_SLOTS]Fx_Node,
	perf:    [PERF_FX]Fx_Node, // main only
	fader:   graph.Node_Id,
	pan:     graph.Node_Id,
	meter_id: graph.Node_Id,
	meter:   ^dsp.Meter,
	built:   Bus, // the settings sent
	sent:    bool,
	dest:    int, // where its output is wired: 0 = main, 1..BUSES = a bus, OUT_DEST.. = a direct out (main itself: -1)
	chain_dirty: bool, // its effect chain must be wired again
	cue:     Send_Node, // its cue send (not main's)
}

// The mixer's nodes: a strip per pad, the buses, main.
Mixer_Nodes :: struct {
	strips: [PADS]Strip,
	buses:  [BUSES + 1]Bus_Nodes, // the last is main
	built:  bool,
	any_solo, any_bus_solo: bool,
	freeze_tap: graph.Node_Id, // a freeze rendering: what feeds the output instead of main
	// The outputs: only these reach OUTPUT. Main's (main, the click, the
	// preview), the cue's (a copy of main, cue sends, the click), and a
	// direct out per output pair a bus or pad goes to.
	out_main, out_cue: graph.Node_Id,
	// The cue's meter, after its level (what the cue output takes).
	cue_meter_id: graph.Node_Id,
	cue_meter:    ^dsp.Meter,
	// Main's loudness meter and stereo analyser, after its meter (the
	// analyser the end of main's chain: what the outputs take).
	loud_id, stereo_id: graph.Node_Id,
	loud:      ^dsp.Loudness_Meter,
	stereo:    ^dsp.Stereo_Analyser,
	out_pairs: [OUT_PAIRS]graph.Node_Id,
	wired:     Out_Wiring, // what they are wired to now
}

// Where the outputs go (graph OUTPUT channels; -1: nowhere).
@(private)
Out_Wiring :: struct {
	main:      [2]int,
	cue:       [2]int,
	cue_db:    f32,
	click_main, click_cue: bool,
	pairs:     [OUT_PAIRS][2]int, // -2: into main
	set:       bool,
}

// [control] The node that plays an effect slot (wrapped for a click-free
// on/off), or false if it has none or would not load.
@(private)
effect_node :: proc(e: ^Engine, s: Effect_Slot) -> (node: fc.Node, plugin: ^clap.Plugin, ok: bool) {
	inner: fc.Node
	if e, twin := synth_twin(s.kind); twin {
		inner, _ = synth.effect_node_create(e)
		return dsp.wet_create(inner, 1 if s.on else 0), nil, true
	}
	#partial switch s.kind {
	case .None:       return {}, nil, false
	case .Low_Pass:   inner = dsp.filter_create(.Lowpass)
	case .High_Pass:  inner = dsp.filter_create(.Highpass)
	case .Band_Pass:  inner = dsp.filter_create(.Bandpass)
	case .Compressor: inner = dsp.compressor_create()
	case .Gate:       inner = dsp.gate_create()
	case .Limiter:    inner = dsp.limiter_create()
	case .Saturation: inner = dsp.saturation_create(2)
	case .Bitcrush:   inner = dsp.bitcrush_create()
	case .Delay:      inner = dsp.delay_create()
	case .Reverb:     inner = dsp.reverb_create()
	case .Chorus:     inner = dsp.chorus_create()
	case .Flanger:    inner = dsp.flanger_create()
	case .Phaser:     inner = dsp.phaser_create()
	case .Ring_Mod:   inner = dsp.ring_mod_create()
	case .Comb:       inner = dsp.comb_create()
	case .Pitch:      inner = dsp.pitch_shift_create()
	case .Cutter:     inner = dsp.cutter_create()
	case .Stutter:    return dsp.stutter_create(), nil, true // always listening: its switch is its own
	case .Plugin:
		n, p, pok := plugin_node(e, s)
		if !pok do return {}, nil, false
		inner, plugin = n, p
	}
	return dsp.wet_create(inner, 1 if s.on else 0), plugin, true
}

// [control] Sends what changed in slot `s` to its node.
@(private)
apply_slot :: proc(g: ^graph.Graph, f: ^Fx_Node, s: Effect_Slot, fresh: bool, mix: f32 = 1) {
	if !f.has do return
	s := s
	for p in s.params[:s.count] {
		old := slot_value(f.applied, p.id, max(f32))
		if fresh || old != p.value do graph.set_param(g, f.id, p.id, f64(p.value))
	}
	if f.applied.kind == s.kind do reset_dropped(g, f, s)
	if f.key_filter != {} && (fresh || f.key_hpf != s.key_hpf) {
		graph.set_param(g, f.key_filter, dsp.FILTER_PARAM_CUTOFF_HZ, f64(max(s.key_hpf, 10))) // (10 Hz: as good as none)
		f.key_hpf = s.key_hpf
	}
	if fresh || f.applied.on != s.on || f.mix != mix {
		if s.kind == .Stutter {
			graph.set_param(g, f.id, dsp.STUTTER_PARAM_ACTIVE, 1 if s.on else 0)
		} else {
			graph.set_param(g, f.id, dsp.WET_PARAM_MIX, f64(mix) if s.on else 0)
		}
	}
	f.applied, f.mix = s, mix
}

// [control] Makes slot `s`'s node if the slot needs a new one. True if the
// graph changed.
@(private)
build_slot :: proc(e: ^Engine, f: ^Fx_Node, s: Effect_Slot) -> bool {
	k := key_of(s)
	if f.has && f.key == k do return false
	if !f.has && f.key == k && (k.kind == .None || f.failed) do return false
	g := e.host.graph
	if f.plugin != nil do clap.plugin_gui_close(f.plugin) // (before its window goes)
	if f.has do graph.remove_node(g, f.id)
	if f.key_filter != {} do graph.remove_node(g, f.key_filter)
	f^ = {key = k}
	node, plugin, ok := effect_node(e, s)
	if !ok {
		f.failed = s.kind != .None
		return true
	}
	id, err := graph.add_node(g, node, 4 if k.keyed else 2, 2)
	if err != .None {
		f.failed = true
		return true
	}
	f.has, f.id, f.plugin = true, id, plugin
	// Keyed: its key through a high-pass, into inputs 3 and 4.
	if k.keyed {
		if fid, ferr := graph.add_node(g, dsp.filter_create(.Highpass), 2, 2); ferr == .None {
			f.key_filter = fid
			for c in 0 ..< 2 do graph.connect(g, fid, c, id, c + 2)
			f.key_hpf = -1 // (sent by apply_slot)
		}
	}
	// Dynamics say how much they turn down (read by `slot_reduction`).
	#partial switch s.kind {
	case .Gate, .Limiter: f.inner, f.kind = (^dsp.Wet)(node.data).inner.data, s.kind
	case .Compressor, .Delay, .Reverb, .Chorus, .Flanger, .Phaser, .Distortion, .Eq, .Filter:
		f.inner, f.kind = (^dsp.Wet)(node.data).inner.data, s.kind // (a `synth.Effect_Node`)
	}
	apply_slot(g, f, s, true)
	return true
}

// [control] Wires `from` through the slots that have nodes into `to`.
@(private)
wire_chain :: proc(g: ^graph.Graph, from: graph.Node_Id, slots: []Fx_Node, to: graph.Node_Id) {
	at := from
	for f in slots do if f.has {
		for c in 0 ..< 2 do graph.connect(g, at, c, f.id, c)
		at = f.id
		// Listening: what follows hears the key (the effect still runs).
		if f.key.listen && f.key_filter != {} do at = f.key_filter
	}
	for c in 0 ..< 2 do graph.connect(g, at, c, to, c)
}

// [control] Takes every wire out of `from` into the slots and `to`
// (before wiring the chain again).
@(private)
unwire_chain :: proc(g: ^graph.Graph, from: graph.Node_Id, slots: []Fx_Node, to: graph.Node_Id) {
	nodes := make([dynamic]graph.Node_Id, context.temp_allocator)
	append(&nodes, from)
	for f in slots do if f.has {
		append(&nodes, f.id)
		if f.key_filter != {} do append(&nodes, f.key_filter)
	}
	append(&nodes, to)
	for a in 0 ..< len(nodes) do for b in a + 1 ..< len(nodes) do for c in 0 ..< 2 {
		graph.disconnect(g, nodes[a], c, nodes[b], c)
	}
}

// [control] The fixed part of the mixer: the buses and main (their
// effects come with sync). Called by build_fixed.
@(private)
build_mixer :: proc(e: ^Engine) -> fc.Error {
	g := e.host.graph
	e.mixer = {}
	for &b, i in e.mixer.buses {
		b.input = graph.add_node(g, dsp.gain_create(), 2, 2) or_return
		b.fader = graph.add_node(g, dsp.gain_create(), 2, 2) or_return
		b.pan = graph.add_node(g, dsp.pan_create(), 2, 2) or_return
		mn, meter := dsp.meter_create()
		b.meter_id = graph.add_node(g, mn, 2, 2) or_return
		b.meter = meter
		for c in 0 ..< 2 {
			graph.connect(g, b.fader, c, b.pan, c)
			graph.connect(g, b.pan, c, b.meter_id, c)
		}
		b.chain_dirty = true
		_ = i
	}
	main := &e.mixer.buses[BUSES]
	main.dest = -1
	e.mixer.out_main = graph.add_node(g, dsp.gain_create(), 2, 2) or_return
	e.mixer.out_cue = graph.add_node(g, dsp.gain_create(), 2, 2) or_return
	cmn, cm := dsp.meter_create()
	e.mixer.cue_meter_id = graph.add_node(g, cmn, 2, 2) or_return
	e.mixer.cue_meter = cm
	for c in 0 ..< 2 do graph.connect(g, e.mixer.out_cue, c, e.mixer.cue_meter_id, c)
	ln, loud := dsp.loudness_create()
	e.mixer.loud_id = graph.add_node(g, ln, 2, 2) or_return
	sn, stereo := dsp.stereo_create()
	e.mixer.stereo_id = graph.add_node(g, sn, 2, 2) or_return
	e.mixer.loud, e.mixer.stereo = loud, stereo
	for c in 0 ..< 2 {
		graph.connect(g, main.meter_id, c, e.mixer.loud_id, c)
		graph.connect(g, e.mixer.loud_id, c, e.mixer.stereo_id, c)
		graph.connect(g, e.mixer.stereo_id, c, e.mixer.out_main, c)
		graph.connect(g, e.mixer.stereo_id, c, e.mixer.out_cue, c) // (the cue: a copy of main, and more)
	}
	for &b in e.mixer.buses[:BUSES] {
		for c in 0 ..< 2 do graph.connect(g, b.meter_id, c, main.input, c)
		b.dest = 0 // (sync wires it where its bus goes)
	}
	e.mixer.built = true
	return .None
}

// [control] The input of where pad strips and buses go: bus `b` (1..BUSES)
// or main (0).
@(private)
dest_input :: proc(e: ^Engine, b: int) -> graph.Node_Id {
	if is_out_dest(b) do return out_pair_node(e, b - OUT_DEST)
	return e.mixer.buses[b - 1].input if b >= 1 && b <= BUSES else e.mixer.buses[BUSES].input
}

// [control] Builds and updates the mixer from the project: each live
// pad's strip, then the buses and main. True if the graph changed.
@(private)
sync_mixer :: proc(e: ^Engine) -> (structural: bool) {
	if !e.mixer.built do return false
	g := e.host.graph
	p := e.project
	mx := &e.mixer
	mx.any_solo = false
	for pad, i in p.pads do if pad.solo && pad_used(p, i) do mx.any_solo = true
	mx.any_bus_solo = false
	for b in p.buses[:p.bus_count] do if b.solo do mx.any_bus_solo = true

	// Pads.
	for &st, i in mx.strips {
		n := &e.nodes[i]
		pad := &p.pads[i]
		if !n.live {
			if st.built {
				remove_strip(g, &st)
				structural = true
			}
			continue
		}
		if !st.built || st.from != n.eq || st.fader != n.fader {
			if st.built do remove_strip(g, &st)
			st.gain, _ = graph.add_node(g, dsp.gain_create(), 2, 2)
			mn, meter := dsp.meter_create()
			st.meter_id, _ = graph.add_node(g, mn, 2, 2)
			st.meter = meter
			st.out, _ = graph.add_node(g, dsp.gain_create(), 2, 2)
			st.from, st.fader, st.built, st.dest = n.eq, n.fader, true, -1
			for c in 0 ..< 2 {
				graph.disconnect(g, n.eq, c, graph.OUTPUT, c)
				graph.connect(g, st.gain, c, n.fader, c)
				graph.connect(g, n.fader, c, st.meter_id, c)
				graph.connect(g, st.meter_id, c, st.out, c)
			}
			st.gain_db, st.out_db = 1, 1 // anything but what they will be
			structural = true
		}
		// Inserts: new nodes when their kind changed, then the chain again.
		// (Frozen: none; they are in its renderings.)
		inserts := pad.inserts
		if pad.frozen do inserts = {}
		changed := false
		for &f, k in st.inserts {
			old := f
			if build_slot(e, &f, inserts[k]) {
				changed = true
				if old.has do structural = true
			}
			apply_slot(g, &f, inserts[k], false)
		}
		if changed || st.dest < 0 {
			unwire_chain(g, n.eq, st.inserts[:], st.gain)
			wire_chain(g, n.eq, st.inserts[:], st.gain)
			structural = true
		}
		// Where it goes.
		if int(pad.bus) != st.dest {
			if st.dest >= 0 do for c in 0 ..< 2 do graph.disconnect(g, st.out, c, dest_input(e, st.dest), c)
			st.dest = int(pad.bus)
			for c in 0 ..< 2 do graph.connect(g, st.out, c, dest_input(e, st.dest), c)
			structural = true
		}
		// Mute and solo (before the sends: a muted pad sends nothing), and a
		// stem's export (it lets through only what goes to the stem's bus).
		db: f32 = 0
		if pad.mute || (mx.any_solo && !pad.solo) do db = -96
		if e.export_solo.kind == .Pad && i != e.export_solo.index do db = -96
		if e.export_solo.kind == .Pads && i not_in e.export_solo.pads do db = -96
		if db != st.gain_db {
			graph.set_param(g, st.gain, dsp.GAIN_PARAM_DB, f64(db))
			st.gain_db = db
		}
		out_db: f32 = 0
		if e.export_solo.kind == .Bus && int(pad.bus) != e.export_solo.index do out_db = -96
		if out_db != st.out_db {
			graph.set_param(g, st.out, dsp.GAIN_PARAM_DB, f64(out_db))
			st.out_db = out_db
		}
		// Its cue send (into the cue mix), then sends: a gain into the bus
		// while on, wired from before the fader or after it.
		if sync_send(e, &st.cue, pad.cue, st.gain, st.meter_id, mx.out_cue) do structural = true
		for &sn, k in st.sends {
			s := pad.sends[k]
			on := s.level > 0
			if e.export_solo.kind == .Bus && e.export_solo.index != k + 1 do on = false
			if sn.has && (!on || sn.pre != s.pre) {
				graph.remove_node(g, sn.id)
				sn = {}
				structural = true
			}
			if on && !sn.has {
				id, err := graph.add_node(g, dsp.gain_create(), 2, 2)
				if err != .None do continue
				src := st.gain if s.pre else st.meter_id
				for c in 0 ..< 2 {
					graph.connect(g, src, c, id, c)
					graph.connect(g, id, c, dest_input(e, k + 1), c)
				}
				sn = {has = true, id = id, pre = s.pre, db = 1}
				structural = true
			}
			if sn.has {
				sdb := send_db(s)
				if sdb != sn.db {
					graph.set_param(g, sn.id, dsp.GAIN_PARAM_DB, f64(sdb))
					sn.db = sdb
				}
			}
		}
	}

	// Buses and main.
	for &bn, i in mx.buses {
		is_main := i == BUSES
		b := p.main if is_main else p.buses[i]
		changed := bn.chain_dirty
		for &f, k in bn.slots {
			old := f
			if build_slot(e, &f, b.slots[k]) {
				changed = true
				if old.has do structural = true
			}
			apply_slot(g, &f, b.slots[k], false)
		}
		if is_main do for &f, k in bn.perf {
			old := f
			if build_slot(e, &f, p.perf_fx[k]) {
				changed = true
				if old.has do structural = true
			}
			s, mix := perf_effective(p, k, e.perf_live[k])
			apply_slot(g, &f, s, false, mix)
		}
		if changed {
			// The chain: input → slots → (main: performance effects) → fader.
			chain := make([dynamic]Fx_Node, context.temp_allocator)
			append(&chain, ..bn.slots[:])
			if is_main do append(&chain, ..bn.perf[:])
			unwire_chain(g, bn.input, chain[:], bn.fader)
			wire_chain(g, bn.input, chain[:], bn.fader)
			bn.chain_dirty = false
			structural = true
		}
		// Where it goes: main, or another bus (never round: the model sees to that).
		if !is_main {
			want := int(b.dest) if (int(b.dest) <= p.bus_count || is_out_dest(int(b.dest))) && bus_dest_ok(p, i + 1, int(b.dest)) else 0
			if want != bn.dest {
				for c in 0 ..< 2 do graph.disconnect(g, bn.meter_id, c, dest_input(e, bn.dest), c)
				for c in 0 ..< 2 do graph.connect(g, bn.meter_id, c, dest_input(e, want), c)
				bn.dest = want
				structural = true
			}
			if sync_send(e, &bn.cue, b.cue, bn.input, bn.meter_id, mx.out_cue) do structural = true
		}
		muted := b.mute || (!is_main && mx.any_bus_solo && !b.solo)
		vol := f32(-96) if muted else b.volume
		if !bn.sent || bn.built.volume != vol do graph.set_param(g, bn.fader, dsp.GAIN_PARAM_DB, f64(vol))
		if !bn.sent || bn.built.pan != b.pan do graph.set_param(g, bn.pan, dsp.PAN_PARAM_POSITION, f64(b.pan))
		bn.built = b
		bn.built.volume = vol
		bn.sent = true
	}
	if sync_keys(e) do structural = true
	if sync_taps(e) do structural = true
	if sync_freeze_tap(e) do structural = true
	if sync_outputs(e) do structural = true
	e.mix_dirty = false
	return
}

// [control] While a freeze renders pad `export_solo.index`, the output is
// that pad's sound before its fader (after its last insert), not main's;
// while a bounce renders, main's input (before its effects and fader).
// True if wires changed.
@(private)
sync_freeze_tap :: proc(e: ^Engine) -> bool {
	g := e.host.graph
	mx := &e.mixer
	main := mx.stereo_id // (the end of main's chain)
	out := mx.out_main
	want: graph.Node_Id
	if e.export_solo.kind == .Freeze {
		i := e.export_solo.index
		if i >= 0 && i < PADS && mx.strips[i].built {
			want = e.nodes[i].eq
			for f in mx.strips[i].inserts do if f.has do want = f.key_filter if f.key.listen && f.key_filter != {} else f.id
		}
	} else if e.export_solo.dry {
		want = mx.buses[BUSES].input
	}
	if want == mx.freeze_tap do return false
	if mx.freeze_tap != {} {
		for c in 0 ..< 2 do graph.disconnect(g, mx.freeze_tap, c, out, c)
	} else {
		for c in 0 ..< 2 do graph.disconnect(g, main, c, out, c)
	}
	src := want if want != {} else main
	for c in 0 ..< 2 do graph.connect(g, src, c, out, c)
	mx.freeze_tap = want
	return true
}

// [control] Each keyed slot's key wired from its source's output (after
// its fader), when that changed (a source made again, another chosen);
// one that would loop, or is gone, hears nothing. True if wires changed.
@(private)
sync_keys :: proc(e: ^Engine) -> (changed: bool) {
	g := e.host.graph
	p := e.project
	mx := &e.mixer
	source :: proc(e: ^Engine, t: Fx_Target, s: Effect_Slot) -> graph.Node_Id {
		mx := &e.mixer
		if !key_allowed(e.project, t, s.key) do return {}
		#partial switch s.key.kind {
		case .Pad: if mx.strips[s.key.index].built do return mx.strips[s.key.index].out
		case .Bus: if s.key.index < BUSES do return mx.buses[s.key.index].meter_id
		}
		return {}
	}
	visit :: proc(g: ^graph.Graph, f: ^Fx_Node, want: graph.Node_Id) -> bool {
		if f.key_filter == {} || f.key_src == want do return false
		if f.key_src != {} do for c in 0 ..< 2 do graph.disconnect(g, f.key_src, c, f.key_filter, c)
		f.key_src = {}
		if want != {} {
			ok := true
			for c in 0 ..< 2 do ok &&= graph.connect(g, want, c, f.key_filter, c) == .None
			if ok do f.key_src = want
			else do for c in 0 ..< 2 do graph.disconnect(g, want, c, f.key_filter, c)
		}
		return true
	}
	for &st, i in mx.strips do if st.built {
		for &f, k in st.inserts do changed |= visit(g, &f, source(e, {.Pad, i, k}, p.pads[i].inserts[k]))
	}
	for &bn, i in mx.buses {
		b := p.main if i == BUSES else p.buses[i]
		for &f, k in bn.slots do changed |= visit(g, &f, source(e, {.Bus, i, k}, b.slots[k]))
	}
	return
}

// Levels since the last call, for meters: pad `i`'s strip.
pad_level :: proc(e: ^Engine, i: int) -> (peak, rms: [2]f32) {
	st := &e.mixer.strips[i]
	if !st.built || st.meter == nil do return
	return dsp.meter_read(st.meter)
}

// Levels since the last call: bus `b` (0..BUSES-1), or main (BUSES).
bus_level :: proc(e: ^Engine, b: int) -> (peak, rms: [2]f32) {
	bn := &e.mixer.buses[clamp(b, 0, BUSES)]
	if bn.meter == nil do return
	return dsp.meter_read(bn.meter)
}

// Levels since the last call: the cue mix (after its level; silent while
// no output takes it).
cue_level :: proc(e: ^Engine) -> (peak, rms: [2]f32) {
	if e.mixer.cue_meter == nil do return
	return dsp.meter_read(e.mixer.cue_meter)
}

// The plug-in in an effect slot's node, if it holds one (for its
// parameters' names and ranges): a pad's insert, or a bus's slot.
slot_plugin :: proc(e: ^Engine, pad: int, bus: int, slot: int) -> ^clap.Plugin {
	if pad >= 0 {
		if pad < PADS && slot < PAD_INSERTS do return e.mixer.strips[pad].inserts[slot].plugin
		return nil
	}
	if bus >= 0 && bus <= BUSES && slot < BUS_SLOTS do return e.mixer.buses[bus].slots[slot].plugin
	return nil
}

// Whether an effect slot's node would not load (a plug-in that is gone).
slot_failed :: proc(e: ^Engine, pad: int, bus: int, slot: int) -> bool {
	if pad >= 0 && pad < PADS && slot < PAD_INSERTS do return e.mixer.strips[pad].inserts[slot].failed
	if pad < 0 && bus >= 0 && bus <= BUSES && slot < BUS_SLOTS do return e.mixer.buses[bus].slots[slot].failed
	return false
}

// The node of the slot `t` points at, if it has one.
target_node :: proc(e: ^Engine, t: Fx_Target) -> ^Fx_Node {
	switch t.kind {
	case .None:
	case .Pad:
		if t.index >= 0 && t.index < PADS && t.slot >= 0 && t.slot < PAD_INSERTS do return &e.mixer.strips[t.index].inserts[t.slot]
	case .Bus:
		if t.index >= 0 && t.index <= BUSES && t.slot >= 0 && t.slot < BUS_SLOTS do return &e.mixer.buses[t.index].slots[t.slot]
	case .Perf:
		if t.index >= 0 && t.index < PERF_FX do return &e.mixer.buses[BUSES].perf[t.index]
	case .Instrument:
		if t.index >= 0 && t.index < PADS do return &e.nodes[t.index].inst
	}
	return nil
}

// The parameters the slot `t` points at shows: its effect's (a plug-in's
// own, once loaded), without the ones the slot itself sets (the on/off
// mix, a filter's mode, a stutter's switch).
target_params :: proc(e: ^Engine, t: Fx_Target, allocator := context.temp_allocator) -> []fc.Param_Info {
	f := target_node(e, t)
	if f == nil || !f.has do return nil
	n := graph.get_node(e.host.graph, f.id)
	if n == nil do return nil
	out := make([dynamic]fc.Param_Info, allocator)
	for p in fc.node_params(n) {
		if p.id == dsp.WET_PARAM_MIX || .Hidden in p.flags do continue
		if f.key.kind == .Stutter && p.id == dsp.STUTTER_PARAM_ACTIVE do continue
		if (f.key.kind == .Low_Pass || f.key.kind == .High_Pass || f.key.kind == .Band_Pass) && (p.id == dsp.FILTER_PARAM_MODE || p.id == dsp.FILTER_PARAM_GAIN_DB) do continue
		append(&out, p)
	}
	return out[:]
}

// Performance effect `k` at its intensity: `live` while its pad is held
// (where it is pressed), else its own (`Project.perf_intensity`). Filters
// sweep toward their cutoff, stutters and cutters go faster, pitch shifts
// go further; the rest blend in (the mix).
perf_effective :: proc(p: ^Project, k: int, live: f32) -> (s: Effect_Slot, mix: f32) {
	s = p.perf_fx[k]
	x := clamp(live if live >= 0 else p.perf_intensity[k], 0, 1)
	mix = 1
	#partial switch s.kind {
	case .Filter:
		// A low-pass closes from the top toward its cutoff, a high-pass
		// opens from the bottom toward it; a band-pass blends in.
		cut_id := synth.effect_param(.Filter, synth.Fx_Filter_Field.Cutoff)
		c := slot_value(s, cut_id, 60)
		b := slot_value(s, synth.effect_param(.Filter, synth.Fx_Filter_Field.Blend), 0)
		if b < 0.5 do slot_set(&s, cut_id, 136 + (c - 136) * x)
		else if b > 1.5 do slot_set(&s, cut_id, 8 + (c - 8) * x)
		else do mix = x
	case .Stutter:
		b := slot_value(s, dsp.STUTTER_PARAM_BEATS, 0.25)
		slot_set(&s, dsp.STUTTER_PARAM_BEATS, b * math.pow(2, math.round((1 - x) * 2)))
	case .Cutter:
		b := slot_value(s, dsp.CUTTER_PARAM_BEATS, 0.25)
		slot_set(&s, dsp.CUTTER_PARAM_BEATS, b * math.pow(2, math.round((1 - x) * 2)))
	case .Pitch:
		st := slot_value(s, dsp.PITCH_PARAM_SEMITONES, 12)
		slot_set(&s, dsp.PITCH_PARAM_SEMITONES, st * x)
	case:
		mix = x
	}
	return
}

// The latency (frames) pad `index`'s inserts add (a plug-in's, a
// look-ahead's): what the graph delays the other tracks by to line them up.
track_latency :: proc(e: ^Engine, index: int) -> int {
	g := e.host.graph
	total := 0
	for f in e.mixer.strips[index].inserts do if f.has {
		if n := graph.get_node(g, f.id); n != nil do total += fc.node_latency(n)
	}
	return total
}

// The latency (frames) the whole graph has after compensation (its output
// behind its input).
total_latency :: proc(e: ^Engine) -> int {
	return graph.latency(e.host.graph)
}

// The synth effect slot `t` plays, as it runs (for drawing its sweeps
// and meters; read while it plays), or nil.
slot_chain :: proc(e: ^Engine, t: Fx_Target) -> ^fx.Chain {
	f := target_node(e, t)
	if f == nil || !f.has || f.inner == nil do return nil
	if _, ok := synth_twin(f.kind); !ok do return nil
	return &(^synth.Effect_Node)(f.inner).chain
}

// How much the effect in slot `t` turns its input down now, in dB (a
// compressor, gate or limiter), for a meter; false for others.
slot_reduction :: proc(e: ^Engine, t: Fx_Target) -> (db: f64, ok: bool) {
	f := target_node(e, t)
	if f == nil || !f.has || f.inner == nil do return 0, false
	#partial switch f.kind {
	case .Compressor:
		// The synth's: its middle band's level in against out (all one band, as converted ones are).
		lv := (^synth.Effect_Node)(f.inner).chain.compressor.levels[1]
		return 10 * math.log10(max(f64(lv[0]), 1e-12) / max(f64(lv[1]), 1e-12)), true
	case .Gate:       return dsp.gate_reduction_db((^dsp.Gate)(f.inner)), true
	case .Limiter:    return dsp.limiter_gain_reduction_db((^dsp.Limiter)(f.inner)), true
	}
	return 0, false
}

// Main's loudness (EBU R128): momentary, short-term and integrated in LUFS
// (`dsp.LOUDNESS_SILENT` for none), and its true peak since the last
// reset (linear).
main_loudness :: proc(e: ^Engine) -> (momentary, short_term, integrated, true_peak: f32) {
	if e.mixer.loud == nil do return dsp.LOUDNESS_SILENT, dsp.LOUDNESS_SILENT, dsp.LOUDNESS_SILENT, 0
	return dsp.loudness_read(e.mixer.loud)
}

// Starts main's integrated loudness and true peak again.
main_loudness_reset :: proc(e: ^Engine) {
	if e.mixer.loud != nil do dsp.loudness_reset(e.mixer.loud)
}

// Main's phase correlation (-1..+1), and its latest (left, right) points
// into `points` (how many: up to `dsp.STEREO_POINTS`).
main_stereo :: proc(e: ^Engine, points: [][2]f32) -> (correlation: f32, n: int) {
	if e.mixer.stereo == nil do return 0, 0
	return dsp.stereo_correlation(e.mixer.stereo), dsp.stereo_points(e.mixer.stereo, points)
}
