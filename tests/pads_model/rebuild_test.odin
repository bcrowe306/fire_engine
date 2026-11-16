package test_pads_model

import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"
import "fire:graph"
import "fire:sampler"

// A new device at another rate (or with other channels) gives a new graph,
// and the engine is built again in it (`engine_rebuild`, as Pads does on
// `Host_Engine_Changed`). Nothing of the old graph may stay: automation's
// players, the MIDI CC lanes' player and a test tone still sounding were
// nodes of the old graph, freed with it. Kept, the engine wrote into the
// freed players (heap corruption: a node's buffers in the new graph
// overwritten, and Pads crashed on the audio thread), and removed nodes of
// the new graph by the old ids.
@(test)
a_new_graph_keeps_nothing_of_the_old :: proc(t: ^testing.T) {
	r := rig_make(t, "rebuild")
	defer rig_destroy(r)
	m := &r.m
	e := &m.engine
	pm.load_onto_pad(m, 0, tone(r, "kick.wav", 440, 0.05))
	cutoff := pm.Auto_Target{track = .Pad, index = 0, device = .Sound, param = sampler.SAMPLER_PARAM_FILTER_CUTOFF, lo = 20, hi = 20_000, log = true}
	pm.add_point(m, 0, {lane = {pad = 0, target = cutoff}, beat = 0, value = 200})
	pm.add_point(m, 0, {lane = {pad = 0, target = cutoff}, beat = 4, value = 4200})
	pm.add_cc(m, 0, {beat = 0, pad = 0, cc = 1, value = 10})
	pm.add_cc(m, 0, {beat = 2, pad = 0, cc = 1, value = 100})
	pm.play(e)
	render(r, 4096)
	testing.expect(t, len(e.auto_dests) > 0 && e.cc_player != nil, "automation and CC lanes have their players")
	testing.expect(t, pm.test_tone(e, 0), "a test tone")
	testing.expect(t, e.tone_id != {}, "the tone's node")

	// Another rate: a new graph, the engine built again in it.
	app.subscribe(&r.bus, app.Host_Engine_Changed, proc(user: rawptr, ev: ^app.Host_Engine_Changed) {
		pm.engine_rebuild((^pm.Engine)(user))
	}, e)
	old := r.host.graph
	r.host.settings.rebuild_on_rate_change = true
	r.host.settings.sample_rate = 44_100
	testing.expect_value(t, app.host_open(&r.host), nil)
	app.host_close(&r.host)
	testing.expect(t, r.host.graph != old, "a new graph")
	render(r, 4096)

	// Every player the engine holds is a node of the new graph, the node it
	// says it is.
	g := r.host.graph
	for d in e.auto_dests {
		n := graph.get_node(g, d.id)
		testing.expectf(t, n != nil && n.data == rawptr(d.player), "an automation player of the new graph (%v)", d.id)
	}
	testing.expect(t, len(e.auto_dests) > 0, "automation plays again")
	if e.cc_player != nil {
		n := graph.get_node(g, e.cc_id)
		testing.expect(t, n != nil && n.data == rawptr(e.cc_player), "the CC lanes' player is of the new graph")
	} else {
		testing.fail_now(t, "the CC lanes play again")
	}
	testing.expect(t, e.tone_id == {}, "the old graph's tone is gone with it")
	for x in e.input_meters do testing.expect(t, x.id == {} && x.meter == nil, "no input meters (no inputs)")
	// And the nodes the engine wired are all still there: none removed by
	// an old id.
	testing.expect(t, graph.get_node(g, e.metro_id) != nil && graph.get_node(g, e.player_id) != nil, "the engine's nodes")
	testing.expect(t, e.nodes[0].live && graph.get_node(g, e.nodes[0].voice) != nil, "the pad's sampler")
}
