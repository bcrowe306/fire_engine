package test_pads_model

import "core:os"
import "core:strings"
import "core:testing"

import fc "fire:core"
import "fire:fx"
import pm "../../apps/pads/model"

// A ProVerb on a bus (its usual home): the tail rings after the pad stops;
// its Quality makes a new node; kept by a save.
@(test)
a_proverb_on_a_bus :: proc(t: ^testing.T) {
	r := tone_rig(t, "pv_bus")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Proverb)
	testing.expect(t, s.count == fx.PV_PARAMS, "every parameter kept")
	pm.slot_set(&s, fx.PV_PARAM_MIX, 1)
	pm.slot_set(&s, fx.PV_PARAM_DECAY_S, 3)
	target := pm.Fx_Target{.Bus, pm.BUSES, 0}
	pm.set_target_slot(m, target, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 9600)
	pv := pm.slot_proverb(&m.engine, target)
	testing.expect(t, pv != nil && fx.proverb_readout(pv).tail > 0.001, "ringing")
	pm.slot_set(&s, fx.PV_PARAM_QUALITY, 0)
	pm.set_target_slot(m, target, s, "Quality")
	render(r, 4800)
	eco := pm.slot_proverb(&m.engine, target)
	testing.expect(t, eco != nil && eco != pv && eco.settings.quality == .Eco, "a new node, Eco")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "pv_bus_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	q := r2.m.project.main.slots[0] // (main)
	testing.expect(t, q.kind == .Proverb && q.count == fx.PV_PARAMS, "the slot back")
	testing.expect_value(t, pm.slot_value(q, fx.PV_PARAM_QUALITY, 1), 0)
	testing.expect_value(t, pm.slot_value(q, fx.PV_PARAM_DECAY_S, 0), 3)
}

// Presets from an installed ValhallaRoom: its .vpreset files (here, two
// written in its shape) read from its folders, each mapped to ProVerb's
// settings, loaded into a slot.
@(test)
proverb_imports_installed_presets :: proc(t: ^testing.T) {
	r := tone_rig(t, "pv_import")
	defer rig_destroy(r)
	dir := strings.concatenate({r.dir, "/ValhallaRoom"}, context.temp_allocator)
	os.make_directory_all(strings.concatenate({dir, "/Halls"}, context.temp_allocator))
	write :: proc(path, name, decay, typ: string) {
		text := strings.concatenate({`<?xml version="1.0" encoding="UTF-8"?>` + "\r\n\r\n" + `<ValhallaRoom pluginVersion="1" presetName="`, name, `" mix="1" predelay="0.02"` + "\r\n" + `              decay="`, decay, `" HighCut="0.5302013" type="`, typ, `" lateSize="0.8"/>`}, context.temp_allocator)
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
	write(strings.concatenate({dir, "/Halls/Big One.vpreset"}, context.temp_allocator), "Big One", "0.049049", "0.75")
	write(strings.concatenate({dir, "/Tiny.vpreset"}, context.temp_allocator), "Tiny", "0.004004", "0.1")
	pm.proverb_import_dirs = {dir}
	defer {
		pm.proverb_import_dirs = nil
		pm.imported_presets_reload()
	}
	pm.imported_presets_reload()
	list := pm.imported_presets()
	testing.expect_value(t, len(list), 2)
	if len(list) != 2 do return
	testing.expect(t, list[0].folder == "" && list[0].name == "Tiny" && list[1].folder == "Halls" && list[1].name == "Big One", "sorted by folder, then name")
	big := list[1].values
	testing.expectf(t, abs(big[fx.PV_PARAM_DECAY_S] - 5) < 0.01 && big[fx.PV_PARAM_MODE] == 8 && abs(big[fx.PV_PARAM_LATE_SIZE] - 0.8) < 1e-6 && abs(big[fx.PV_PARAM_PREDELAY_MS] - 10) < 0.01,
		"its settings as ProVerb's (%v s, mode %v, size %v, %v ms)", big[fx.PV_PARAM_DECAY_S], big[fx.PV_PARAM_MODE], big[fx.PV_PARAM_LATE_SIZE], big[fx.PV_PARAM_PREDELAY_MS])
	s := pm.imported_preset_slot(list[1])
	testing.expect(t, s.kind == .Proverb && pm.slot_value(s, fx.PV_PARAM_DECAY_S, 0) == big[fx.PV_PARAM_DECAY_S], "a slot at its settings")
}
