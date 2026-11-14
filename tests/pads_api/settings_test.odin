package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"
import pc "../../apps/pads/core"

// Settings as an app keeps them, registered as Pads registers its own.
@(private)
Fake_Settings :: struct {
	tempo:   f64,
	bars:    int,
	level:   f32,
	on:      bool,
	sync:    u8,
	folder:  string,
	applied: [pc.Setting_Group]int,
	refuse:  bool, // the next apply fails (a device that won't open)
}

@(private)
SYNC_NAMES := [?]string{"Internal", "Midi_Clock", "Link"}

@(private)
fake_register :: proc(r: ^Rig, f: ^Fake_Settings) {
	c := &r.core
	f.tempo, f.bars, f.level, f.on = 120, 1, -6, true
	pc.setting_register(c, {name = "project.tempo", kind = .Number, group = .Project, store = .F64, ptr = &f.tempo, min = 40, max = 300, about = "a new project's tempo"})
	pc.setting_register(c, {name = "project.bars", kind = .Int, group = .Project, store = .Int, ptr = &f.bars, min = 1, max = 64})
	pc.setting_register(c, {name = "audio.cue_db", kind = .Number, group = .Audio, store = .F32, ptr = &f.level, min = -60, max = 6})
	pc.setting_register(c, {name = "midi.clock_out", kind = .Bool, group = .Sync, store = .Bool, ptr = &f.on})
	pc.setting_register(c, {name = "midi.sync", kind = .Choice, group = .Sync, store = .U8, ptr = &f.sync, choices = SYNC_NAMES[:]})
	pc.setting_register(c, {name = "project.folder", kind = .Text, group = .Project, store = .String, ptr = &f.folder})
	c.registry.user = f
	c.registry.changed = proc(user: rawptr, g: pc.Setting_Group) -> bool {
		f := (^Fake_Settings)(user)
		f.applied[g] += 1
		if f.refuse {
			f.refuse = false
			return false
		}
		return true
	}
}

@(test)
settings_are_listed_read_set_and_applied :: proc(t: ^testing.T) {
	r := rig_make(t, "settings")
	defer rig_destroy(r)
	api := &r.api
	f: Fake_Settings
	defer delete(f.folder)
	fake_register(r, &f)
	n, _ := pa.settings_count(api)
	testing.expect_value(t, n, 6)
	name, _ := pa.settings_name(api, 0)
	testing.expect_value(t, name, "project.tempo")
	_, res := pa.settings_name(api, 6)
	testing.expect_value(t, res, pa.Result.Not_Found)
	info, _ := pa.settings_info(api, "project.tempo")
	testing.expect(t, info.kind == .Number && info.group == .Project && info.min == 40 && info.max == 300, "its range")
	about, _ := pa.settings_about(api, "project.tempo")
	testing.expect_value(t, about, "a new project's tempo")
	_, res = pa.settings_info(api, "no.such")
	testing.expect_value(t, res, pa.Result.Not_Found)
	// Numbers: checked, set, applied by their group.
	testing.expect_value(t, pa.settings_set_number(api, "project.tempo", 400), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.settings_set_number(api, "project.bars", 2.5), pa.Result.Invalid_Argument)
	testing.expect_value(t, f.applied[.Project], 0)
	testing.expect_value(t, pa.settings_set_number(api, "project.tempo", 96), pa.Result.Ok)
	testing.expect_value(t, pa.settings_set_number(api, "project.bars", 4), pa.Result.Ok)
	testing.expect_value(t, f.tempo, 96)
	testing.expect_value(t, f.bars, 4)
	testing.expect_value(t, f.applied[.Project], 2)
	v, _ := pa.settings_get_number(api, "project.tempo")
	testing.expect_value(t, v, 96)
	// Text: by name for a choice, true/false, words.
	testing.expect_value(t, pa.settings_set_text(api, "midi.sync", "midi_clock"), pa.Result.Ok)
	testing.expect_value(t, f.sync, 1)
	txt, _ := pa.settings_get_text(api, "midi.sync")
	testing.expect_value(t, txt, "Midi_Clock")
	k, _ := pa.settings_choice(api, "midi.sync", 2)
	testing.expect_value(t, k, "Link")
	_, res = pa.settings_choice(api, "midi.sync", 3)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.settings_set_text(api, "midi.sync", "Tape"), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.settings_set_text(api, "midi.clock_out", "off"), pa.Result.Ok)
	testing.expect(t, !f.on, "off")
	testing.expect_value(t, pa.settings_set_text(api, "project.folder", "/Music/Beats"), pa.Result.Ok)
	txt, _ = pa.settings_get_text(api, "project.folder")
	testing.expect_value(t, txt, "/Music/Beats")
	testing.expect_value(t, pa.settings_set_number(api, "project.folder", 1), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.settings_set_text(api, "project.tempo", "101.5"), pa.Result.Ok)
	testing.expect_value(t, f.tempo, 101.5)
	// One that couldn't be applied: Io_Error, and why.
	f.refuse = true
	testing.expect_value(t, pa.settings_set_number(api, "audio.cue_db", -12), pa.Result.Io_Error)
	why, _ := pa.last_error(api)
	testing.expect_value(t, why, "audio.cue_db couldn't be applied: it is back as it was")
}

@(test)
sync_and_clock_out_are_the_transports :: proc(t: ^testing.T) {
	r := rig_make(t, "settings_sync")
	defer rig_destroy(r)
	api := &r.api
	// No such settings registered: Unsupported.
	testing.expect_value(t, pa.transport_set_sync(api, .Midi_Clock), pa.Result.Unsupported)
	testing.expect_value(t, pa.transport_set_clock_out(api, true), pa.Result.Unsupported)
	f: Fake_Settings
	fake_register(r, &f)
	h: Heard
	sub, _ := pa.subscribe(api, .Settings, -1, proc "c" (api: ^pa.Api, topic: pa.Topic, index: i64, user: rawptr) {
		(^Heard)(user).history += 1
	}, &h)
	defer pa.unsubscribe(api, sub)
	testing.expect_value(t, pa.transport_set_sync(api, .Midi_Clock), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_clock_out(api, false), pa.Result.Ok)
	testing.expect_value(t, f.applied[.Sync], 2)
	s, _ := pa.transport_state(api)
	testing.expect(t, s.sync == .Midi_Clock && !s.clock_out, "the transport says so")
	testing.expect_value(t, pa.transport_set_sync(api, pa.Sync(7)), pa.Result.Invalid_Argument)
	frame(r)
	testing.expect_value(t, h.history, 1) // (the Settings topic: once)
}
