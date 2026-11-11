package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:testing"

import app "app:core"
import "fire:clap"
import "fire:graph"
import pm "../../apps/pads/model"

SINE_ID :: "dev.fire-engine.test.sine"
SINE_LEVEL :: 9 // its level parameter (dB)

// The C test plug-ins' library (built by ./scripts/clap.sh), or false.
@(private)
test_clap :: proc(t: ^testing.T) -> (string, bool) {
	for p in ([]string{"../../.build/clap/FireTest.clap", ".build/clap/FireTest.clap"}) {
		path, _ := filepath.abs(p, context.temp_allocator)
		if os.exists(path) do return path, true
	}
	log_skip(t, "no test plug-ins (./scripts/clap.sh builds them)")
	return "", false
}

@(private)
peak_of :: proc(x: []f32) -> f32 {
	m: f32
	for v in x do m = max(m, abs(v))
	return m
}

@(test)
a_plugin_instrument_plays_a_pad :: proc(t: ^testing.T) {
	path, have := test_clap(t)
	if !have do return
	r := rig_make(t, "plugin_pad")
	defer rig_destroy(r)
	m := &r.m
	pm.make_plugin_pad(m, 0, path, SINE_ID, "Fire Test Sine")
	testing.expect_value(t, m.project.pads[0].kind, pm.Pad_Kind.Plugin)
	testing.expect_value(t, pm.pad_name(&m.project.pads[0]), "Fire Test Sine")
	render(r, 480)
	testing.expect(t, pm.pad_plugin(&m.engine, 0) != nil, "the plug-in loaded")
	// Chromatic: a key an octave up plays C4; the pad hit plays C3.
	pm.hit(&m.engine, 0, true, 1, 12, keyboard = true)
	x := render(r, 9600)
	testing.expectf(t, abs(hz_of(x[0][2400:]) - 523.25) < 4, "C4 (%v Hz)", hz_of(x[0][2400:]))
	testing.expectf(t, abs(peak_of(x[0][2400:]) - 0.5) < 0.05, "at its level, -6 dB (%v)", peak_of(x[0][2400:]))
	pm.hit(&m.engine, 0, false, 0, 12, keyboard = true)
	render(r, 2400)
	testing.expectf(t, peak_of(render(r, 2400)[0]) < 1e-4, "its note-off stops it (the same key as its note-on)")
	pm.hit(&m.engine, 0, true, 1)
	x = render(r, 9600)
	testing.expectf(t, abs(hz_of(x[0][2400:]) - 261.63) < 4, "the pad: C3 (%v Hz)", hz_of(x[0][2400:]))
	pm.hit(&m.engine, 0, false, 0)
	render(r, 2400)
	testing.expect(t, peak_of(render(r, 2400)[0]) < 1e-4, "and stops")
	// A parameter set from Pads (undoable).
	pm.set_instrument_param(m, 0, SINE_LEVEL, -20)
	app.seal(&m.history)
	pm.hit(&m.engine, 0, true, 1)
	x = render(r, 9600)
	testing.expectf(t, abs(peak_of(x[0][4800:]) - 0.1) < 0.01, "-20 dB (%v)", peak_of(x[0][4800:]))
	pm.hit(&m.engine, 0, false, 0)
	app.undo(&m.history)
	render(r, 480)
	v, _ := clap.plugin_param_value(pm.pad_plugin(&m.engine, 0), SINE_LEVEL)
	testing.expectf(t, v == -6, "undone (%v)", v)
}

@(test)
a_plugin_keeps_its_state_in_the_project :: proc(t: ^testing.T) {
	path, have := test_clap(t)
	if !have do return
	r := rig_make(t, "plugin_state")
	defer rig_destroy(r)
	m := &r.m
	pm.make_plugin_pad(m, 3, path, SINE_ID, "Sine")
	b := m.project.main
	b.slots[0] = pm.new_plugin_effect(&m.project, path, "dev.fire-engine.test.gain", "Gain")
	pm.set_bus(m, pm.BUSES, 10, "Add Plug-in", b)
	render(r, 480)
	// Set inside the plug-ins (as their own windows would): Pads doesn't
	// know these values; their state does.
	g := m.engine.host.graph
	graph.set_param(g, m.engine.nodes[3].inst.id, SINE_LEVEL, -33)
	graph.set_param(g, m.engine.mixer.buses[pm.BUSES].slots[0].id, 7, -9)
	render(r, 480)
	testing.expect_value(t, pm.model_save(m), nil)
	r2 := rig_make(t, "plugin_state_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), nil)
	render(r2, 480)
	q := &r2.m.project
	testing.expect_value(t, q.pads[3].kind, pm.Pad_Kind.Plugin)
	testing.expect_value(t, q.pads[3].instrument.plugin_id, SINE_ID)
	p := pm.pad_plugin(&r2.m.engine, 3)
	if !testing.expect(t, p != nil, "loaded again") do return
	v, _ := clap.plugin_param_value(p, SINE_LEVEL)
	testing.expectf(t, v == -33, "its state put back (%v)", v)
	fxp := pm.slot_plugin(&r2.m.engine, -1, pm.BUSES, 0)
	if !testing.expect(t, fxp != nil, "the effect loaded again") do return
	v, _ = clap.plugin_param_value(fxp, 7)
	testing.expectf(t, v == -9, "the effect's state too (%v)", v)
}

@(test)
plugin_lanes_move_the_parameters_given :: proc(t: ^testing.T) {
	path, have := test_clap(t)
	if !have do return
	r := rig_make(t, "plugin_lanes")
	defer rig_destroy(r)
	m := &r.m
	pm.make_plugin_pad(m, 0, path, SINE_ID, "Sine")
	render(r, 480)
	pm.set_plugin_lane(m, 0, 0, {id = SINE_LEVEL, min = -60, max = 0})
	testing.expect_value(t, pm.plugin_lane_of(&m.project, 0, SINE_LEVEL), 0)
	pm.add_point(m, 0, {pad = 0, param = .Plugin_1, beat = 0, value = 25}) // 25 %: -45 dB
	pm.play(&m.engine)
	render(r, 4800)
	v, _ := clap.plugin_param_value(pm.pad_plugin(&m.engine, 0), SINE_LEVEL)
	testing.expectf(t, abs(v - -45) < 0.01, "automated (%v dB)", v)
	// Kept by a save.
	testing.expect_value(t, pm.model_save(m), nil)
	r2 := rig_make(t, "plugin_lanes_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), nil)
	l := r2.m.project.pads[0].plugin_lanes[0]
	testing.expect(t, l.id == SINE_LEVEL && l.lo == -60 && l.hi == 0)
}

@(test)
a_missing_plugin_pad_says_so :: proc(t: ^testing.T) {
	r := rig_make(t, "plugin_missing")
	defer rig_destroy(r)
	m := &r.m
	pm.make_plugin_pad(m, 0, "/nowhere/missing.clap", "x", "Missing")
	render(r, 480)
	testing.expect(t, pm.pad_plugin(&m.engine, 0) == nil && pm.pad_plugin_failed(&m.engine, 0))
	x := render(r, 480)
	testing.expect(t, peak_of(x[0]) == 0)
}
