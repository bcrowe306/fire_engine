package pads_model

import "core:math"

import fc "fire:core"
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
}

@(private)
key_of :: proc(s: Effect_Slot) -> Slot_Key {
	return {s.kind, s.plugin_path, s.plugin_id}
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
	for f in st.inserts do if f.has do graph.remove_node(g, f.id)
	for s in st.sends do if s.has do graph.remove_node(g, s.id)
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
	chain_dirty: bool, // its effect chain must be wired again
}

// The mixer's nodes: a strip per pad, the buses, main.
Mixer_Nodes :: struct {
	strips: [PADS]Strip,
	buses:  [BUSES + 1]Bus_Nodes, // the last is main
	built:  bool,
	any_solo, any_bus_solo: bool,
}

// [control] The node that plays an effect slot (wrapped for a click-free
// on/off), or false if it has none or would not load.
@(private)
effect_node :: proc(e: ^Engine, s: Effect_Slot) -> (node: fc.Node, plugin: ^clap.Plugin, ok: bool) {
	inner: fc.Node
	switch s.kind {
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
		lib, err := clap.library_open(s.plugin_path)
		if err != .None do return {}, nil, false
		n, p, perr := clap.plugin_create(lib, s.plugin_id, {timeline = e.timeline})
		clap.library_close(lib) // the plug-in keeps the library open
		if perr != .None do return {}, nil, false
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
	if f.has do graph.remove_node(g, f.id)
	f^ = {key = k}
	node, plugin, ok := effect_node(e, s)
	if !ok {
		f.failed = s.kind != .None
		return true
	}
	id, err := graph.add_node(g, node, 2, 2)
	if err != .None {
		f.failed = true
		return true
	}
	f.has, f.id, f.plugin = true, id, plugin
	// Dynamics say how much they turn down (read by `slot_reduction`).
	#partial switch s.kind {
	case .Compressor, .Gate, .Limiter: f.inner, f.kind = (^dsp.Wet)(node.data).inner.data, s.kind
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
	}
	for c in 0 ..< 2 do graph.connect(g, at, c, to, c)
}

// [control] Takes every wire out of `from` into the slots and `to`
// (before wiring the chain again).
@(private)
unwire_chain :: proc(g: ^graph.Graph, from: graph.Node_Id, slots: []Fx_Node, to: graph.Node_Id) {
	nodes := make([dynamic]graph.Node_Id, context.temp_allocator)
	append(&nodes, from)
	for f in slots do if f.has do append(&nodes, f.id)
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
	for c in 0 ..< 2 do graph.connect(g, main.meter_id, c, graph.OUTPUT, c)
	for b in e.mixer.buses[:BUSES] do for c in 0 ..< 2 do graph.connect(g, b.meter_id, c, main.input, c)
	e.mixer.built = true
	return .None
}

// [control] The input of where pad strips and buses go: bus `b` (1..BUSES)
// or main (0).
@(private)
dest_input :: proc(e: ^Engine, b: int) -> graph.Node_Id {
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
	for b in p.buses do if b.solo do mx.any_bus_solo = true

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
		changed := false
		for &f, k in st.inserts {
			old := f
			if build_slot(e, &f, pad.inserts[k]) {
				changed = true
				if old.has do structural = true
			}
			apply_slot(g, &f, pad.inserts[k], false)
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
		// Sends: a gain into the bus while on, wired from before the fader
		// or after it.
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
		muted := b.mute || (!is_main && mx.any_bus_solo && !b.solo)
		vol := f32(-96) if muted else b.volume
		if !bn.sent || bn.built.volume != vol do graph.set_param(g, bn.fader, dsp.GAIN_PARAM_DB, f64(vol))
		if !bn.sent || bn.built.pan != b.pan do graph.set_param(g, bn.pan, dsp.PAN_PARAM_POSITION, f64(b.pan))
		bn.built = b
		bn.built.volume = vol
		bn.sent = true
	}
	e.mix_dirty = false
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
	case .Low_Pass:
		c := slot_value(s, dsp.FILTER_PARAM_CUTOFF_HZ, 500)
		slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 20_000 * math.pow(c / 20_000, x))
	case .High_Pass:
		c := slot_value(s, dsp.FILTER_PARAM_CUTOFF_HZ, 2000)
		slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 20 * math.pow(c / 20, x))
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

// How much the effect in slot `t` turns its input down now, in dB (a
// compressor, gate or limiter), for a meter; false for others.
slot_reduction :: proc(e: ^Engine, t: Fx_Target) -> (db: f64, ok: bool) {
	f := target_node(e, t)
	if f == nil || !f.has || f.inner == nil do return 0, false
	#partial switch f.kind {
	case .Compressor: return dsp.compressor_gain_reduction_db((^dsp.Compressor)(f.inner)), true
	case .Gate:       return dsp.gate_reduction_db((^dsp.Gate)(f.inner)), true
	case .Limiter:    return dsp.limiter_gain_reduction_db((^dsp.Limiter)(f.inner)), true
	}
	return 0, false
}
