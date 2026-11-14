package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

@(test)
buses_are_added_routed_named_and_deleted :: proc(t: ^testing.T) {
	r := rig_make(t, "mixer_buses")
	defer rig_destroy(r)
	api := &r.api
	st, _ := pa.mixer_state(api)
	n0 := st.buses
	b, res := pa.mixer_add_bus(api)
	testing.expect(t, res == .Ok && b == n0, "the next bus")
	name, _ := pa.mixer_bus_name(api, b)
	testing.expect(t, len(name) == 5 && name[:4] == "Bus ", "named by its letter")
	testing.expect_value(t, pa.mixer_rename_bus(api, b, "Drums"), pa.Result.Ok)
	name, _ = pa.mixer_bus_name(api, b)
	testing.expect_value(t, name, "Drums")
	testing.expect_value(t, pa.mixer_rename_bus(api, b, "a name too long for it"), pa.Result.Invalid_Argument)
	mn, _ := pa.mixer_bus_name(api, pa.MAIN)
	testing.expect_value(t, mn, "Main")
	// Routed: to bus 0, never round to itself.
	testing.expect_value(t, pa.mixer_set_bus_output(api, b, {kind = .Bus, index = 0}), pa.Result.Ok)
	bs, _ := pa.mixer_bus_state(api, b)
	testing.expect(t, bs.output.kind == .Bus && bs.output.index == 0, "to bus 0")
	testing.expect_value(t, pa.mixer_set_bus_output(api, 0, {kind = .Bus, index = b}), pa.Result.Invalid_Argument) // (a loop)
	testing.expect_value(t, pa.mixer_set_bus_output(api, b, {kind = .Bus, index = b}), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.mixer_set_bus_output(api, b, {kind = .Pair, index = 1}), pa.Result.Ok)
	bs, _ = pa.mixer_bus_state(api, b)
	testing.expect(t, bs.output.kind == .Pair && bs.output.index == 1, "to outputs 3/4")
	testing.expect_value(t, pa.mixer_set_bus_output(api, pa.MAIN, {}), pa.Result.Unsupported)
	// Its fader, pan, mute, solo; main's.
	testing.expect_value(t, pa.mixer_set_bus_volume(api, b, -9), pa.Result.Ok)
	testing.expect_value(t, pa.mixer_set_bus_pan(api, b, 0.25), pa.Result.Ok)
	testing.expect_value(t, pa.mixer_set_bus_mute(api, b, true), pa.Result.Ok)
	testing.expect_value(t, pa.mixer_set_bus_solo(api, b, true), pa.Result.Ok)
	bs, _ = pa.mixer_bus_state(api, b)
	testing.expect(t, bs.volume == -9 && bs.pan == 0.25 && bs.mute && bs.solo, "set")
	testing.expect_value(t, pa.mixer_set_bus_volume(api, pa.MAIN, -2), pa.Result.Ok)
	testing.expect_value(t, pa.mixer_set_bus_solo(api, pa.MAIN, true), pa.Result.Unsupported)
	ms, _ := pa.mixer_bus_state(api, pa.MAIN)
	testing.expect_value(t, ms.volume, -2)
	_, res = pa.mixer_bus_state(api, 15)
	testing.expect_value(t, res, pa.Result.Not_Found)
	// A pad to it.
	testing.expect_value(t, pa.mixer_set_pad_output(api, 4, {kind = .Bus, index = b}), pa.Result.Ok)
	o, _ := pa.mixer_pad_output(api, 4)
	testing.expect(t, o.kind == .Bus && o.index == b, "pad 4 to it")
	testing.expect_value(t, pa.mixer_set_pad_output(api, 4, {kind = .Bus, index = 15}), pa.Result.Not_Found)
	// Deleted: what went to it goes to main.
	testing.expect_value(t, pa.mixer_delete_bus(api, b), pa.Result.Ok)
	o, _ = pa.mixer_pad_output(api, 4)
	testing.expect_value(t, o.kind, pa.Output_Kind.Main)
	st, _ = pa.mixer_state(api)
	testing.expect_value(t, st.buses, n0)
	for st.buses > 1 {
		pa.mixer_delete_bus(api, st.buses - 1)
		st, _ = pa.mixer_state(api)
	}
	testing.expect_value(t, pa.mixer_delete_bus(api, 0), pa.Result.Busy)
	testing.expect_value(t, pa.mixer_delete_bus(api, pa.MAIN), pa.Result.Unsupported)
}

@(test)
groups_cue_and_the_mixer_topic :: proc(t: ^testing.T) {
	r := rig_make(t, "mixer_groups")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	pa.pad_load_sample(api, 1, tone(r, "b.wav"))
	h: Heard
	sub, _ := pa.subscribe(api, .Mixer, -1, proc "c" (api: ^pa.Api, topic: pa.Topic, index: i64, user: rawptr) { (^Heard)(user).transport += 1 }, &h)
	defer pa.unsubscribe(api, sub)
	g, res := pa.mixer_group_pads(api, []i64{0, 1}, "Kit")
	testing.expect_value(t, res, pa.Result.Ok)
	name, _ := pa.mixer_bus_name(api, g)
	testing.expect_value(t, name, "Kit")
	bs, _ := pa.mixer_bus_state(api, g)
	testing.expect(t, bs.group, "a group")
	o, _ := pa.mixer_pad_output(api, 1)
	testing.expect(t, o.kind == .Bus && o.index == g, "its pads go to it")
	undo, _ := pa.history_undo_name(api)
	testing.expect_value(t, undo, "Group Pads")
	_, res = pa.mixer_group_pads(api, nil, "")
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.mixer_set_group_folded(api, g, true), pa.Result.Ok)
	bs, _ = pa.mixer_bus_state(api, g)
	testing.expect(t, bs.folded, "folded")
	testing.expect_value(t, pa.mixer_set_group_folded(api, 0, true), pa.Result.Invalid_Argument) // (not a group)
	frame(r)
	testing.expect(t, h.transport >= 1, "the Mixer topic heard it")
	// Cue sends.
	testing.expect_value(t, pa.mixer_set_pad_cue(api, 0, -6, true), pa.Result.Ok)
	testing.expect(t, r.core.m.project.pads[0].cue.pre && r.core.m.project.pads[0].cue.level > 0.49, "the pad's cue")
	testing.expect_value(t, pa.mixer_set_bus_cue(api, g, -60, false), pa.Result.Ok)
	bs, _ = pa.mixer_bus_state(api, g)
	testing.expect_value(t, bs.cue_db, -60)
	testing.expect_value(t, pa.mixer_set_pad_cue(api, 0, 9, false), pa.Result.Invalid_Argument)
	// Ungrouped: its pads where it went.
	testing.expect_value(t, pa.mixer_ungroup(api, g), pa.Result.Ok)
	o, _ = pa.mixer_pad_output(api, 1)
	testing.expect_value(t, o.kind, pa.Output_Kind.Main)
	testing.expect_value(t, pa.mixer_ungroup(api, 0), pa.Result.Invalid_Argument)
	h.transport = 0
	frame(r)
	frame(r)
	testing.expect_value(t, h.transport, 1) // (once for the frame's changes, then nothing)
}

@(test)
meters_loudness_and_latency_are_polled :: proc(t: ^testing.T) {
	r := rig_make(t, "mixer_meters")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	render(r, 256) // (its sample in memory)
	pa.pad_play(api, 0, true)
	render(r, 8192)
	m, res := pa.mixer_pad_meter(api, 0)
	testing.expect(t, res == .Ok && m.peak_l > 0.1, "the pad's meter moved")
	mm, _ := pa.mixer_bus_meter(api, pa.MAIN)
	testing.expect(t, mm.peak_l > 0.1, "main's")
	_, res = pa.mixer_cue_meter(api)
	testing.expect_value(t, res, pa.Result.Ok)
	_, res = pa.mixer_input_meter(api, 0)
	testing.expect_value(t, res, pa.Result.Ok)
	_, res = pa.mixer_input_meter(api, 16)
	testing.expect_value(t, res, pa.Result.Not_Found)
	l, _ := pa.mixer_loudness(api)
	testing.expect(t, l.momentary > -70, "loud enough to measure")
	testing.expect_value(t, pa.mixer_loudness_reset(api), pa.Result.Ok)
	lat, _ := pa.mixer_pad_latency(api, 0)
	testing.expect_value(t, lat, 0)
	_, res = pa.mixer_pad_latency(api, 128)
	testing.expect_value(t, res, pa.Result.Not_Found)
}
