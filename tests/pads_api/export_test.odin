package test_pads_api

import "core:os"
import "core:path/filepath"
import "core:testing"

import pa "../../apps/pads/api"
import pc "../../apps/pads/core"

// Runs the export under way to its end (a slice a frame, as Pads does).
@(private)
finish_export :: proc(r: ^Rig) {
	for k := 0; k < 10_000 && r.core.job.busy; k += 1 do pc.export_frame(&r.core)
}

@(test)
exports_bounces_and_freezes :: proc(t: ^testing.T) {
	r := rig_make(t, "export")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	render(r, 256)
	pa.sequence_add_note(api, 0, {start = 0, length = 1, pad = 0, velocity = 1})
	// A mixdown, rendered a slice a frame.
	out, _ := filepath.join({r.dir, "mix.wav"}, context.temp_allocator)
	testing.expect_value(t, pa.export_start(api, {rate = 48_000, tail = 0}, out), pa.Result.Ok)
	s, _ := pa.export_state(api)
	testing.expect(t, s.busy, "under way")
	testing.expect_value(t, pa.export_start(api, {}, out), pa.Result.Busy)
	finish_export(r)
	s, _ = pa.export_state(api)
	testing.expect(t, !s.busy && !s.failed && s.files == 1, "one file")
	f, _ := pa.export_file(api, 0)
	testing.expect(t, os.exists(f), "written")
	testing.expect_value(t, pa.export_start(api, {rate = 22_050}, out), pa.Result.Invalid_Argument)
	// At once (as a script does).
	now, _ := filepath.join({r.dir, "now.wav"}, context.temp_allocator)
	n, res := pa.export_now(api, {format = .Int16}, now)
	testing.expect(t, res == .Ok && n == 1 && os.exists(now), "exported at once")
	// Resampled onto a pad; a bounce in place; frozen and back.
	testing.expect_value(t, pa.export_resample(api), pa.Result.Ok)
	finish_export(r)
	s, _ = pa.export_state(api)
	testing.expect(t, s.made_pad >= 1, "onto the next empty pad")
	testing.expect_value(t, pa.export_bounce_pads(api, {0}), pa.Result.Ok)
	finish_export(r)
	testing.expect_value(t, pa.export_bounce_bus(api, 0), pa.Result.Invalid_Argument) // (nothing on it)
	testing.expect_value(t, pa.export_freeze(api, 0), pa.Result.Ok)
	finish_export(r)
	ps, _ := pa.pad_state(api, 0)
	testing.expect(t, ps.frozen, "frozen")
	testing.expect_value(t, pa.export_unfreeze(api, 0), pa.Result.Ok)
	testing.expect_value(t, pa.export_unfreeze(api, 0), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.export_freeze(api, 0), pa.Result.Ok)
	finish_export(r)
	testing.expect_value(t, pa.export_flatten(api, 0), pa.Result.Ok)
	ps, _ = pa.pad_state(api, 0)
	testing.expect_value(t, ps.kind, pa.Pad_Kind.Audio)
	testing.expect_value(t, pa.export_bounce_in_place(api, 9), pa.Result.Invalid_Argument)
	// MIDI files: out and back in.
	pa.sequence_add_note(api, 2, {start = 0, length = 0.5, pad = 0, velocity = 1})
	pa.sequence_add_note(api, 2, {start = 1, length = 0.5, pad = 1, velocity = 1})
	mid, _ := filepath.join({r.dir, "seq.mid"}, context.temp_allocator)
	notes, mres := pa.export_midi(api, mid, 2)
	testing.expect(t, mres == .Ok && notes == 2, "two notes out")
	got, ires := pa.export_import_midi(api, mid, 3, .By_Map)
	testing.expect(t, ires == .Ok && got == 2, "two notes in")
	_, ires = pa.export_import_midi(api, "/no/such.mid", 3)
	testing.expect_value(t, ires, pa.Result.Io_Error)
}

@(test)
the_browser_walks_folders_and_keeps_favourites :: proc(t: ^testing.T) {
	r := rig_make(t, "browser")
	defer rig_destroy(r)
	api := &r.api
	pc_browser_init(r)
	lib, _ := filepath.join({r.dir, "Library"}, context.temp_allocator)
	kicks, _ := filepath.join({lib, "Kicks"}, context.temp_allocator)
	os.make_directory_all(kicks)
	k, _ := filepath.join({kicks, "boom.wav"}, context.temp_allocator)
	_ = os.write_entire_file(k, []u8{0})
	testing.expect_value(t, pa.browser_go(api, lib), pa.Result.Ok)
	testing.expect_value(t, pa.browser_go(api, "/no/such/folder"), pa.Result.Not_Found)
	folder, _ := pa.browser_folder(api)
	testing.expect_value(t, folder, lib)
	s, _ := pa.browser_state(api)
	testing.expect(t, s.rows == 1 && s.can_back, "the Kicks folder")
	row, _ := pa.browser_row(api, 0)
	name, _ := pa.browser_row_name(api, 0)
	testing.expect(t, row.is_dir && name == "Kicks", "a folder")
	testing.expect_value(t, pa.browser_toggle(api, kicks), pa.Result.Ok)
	s, _ = pa.browser_state(api)
	testing.expect_value(t, s.rows, 2) // (opened: its file under it)
	p1, _ := pa.browser_row_path(api, 1)
	testing.expect_value(t, p1, k)
	testing.expect_value(t, pa.browser_expand(api, kicks, false), pa.Result.Ok)
	testing.expect_value(t, pa.browser_select(api, k), pa.Result.Ok)
	sel, _ := pa.browser_selected(api)
	testing.expect_value(t, sel, k)
	testing.expect_value(t, pa.browser_up(api), pa.Result.Ok)
	testing.expect_value(t, pa.browser_back(api), pa.Result.Ok)
	testing.expect_value(t, pa.browser_forward(api), pa.Result.Ok)
	testing.expect_value(t, pa.browser_refresh(api), pa.Result.Ok)
	// Favourites, saved with the preferences.
	n0 := s.favorites
	i, _ := pa.browser_add_favorite(api, lib, "Lib")
	fname, _ := pa.browser_favorite_name(api, i)
	ffolder, _ := pa.browser_favorite_folder(api, i)
	testing.expect(t, fname == "Lib" && ffolder == lib, "added")
	testing.expect_value(t, pa.browser_rename_favorite(api, i, "Library"), pa.Result.Ok)
	testing.expect_value(t, pa.browser_set_tab(api, i), pa.Result.Ok)
	if i > 0 do testing.expect_value(t, pa.browser_move_favorite(api, i, 0), pa.Result.Ok)
	saved, _ := filepath.join({r.core.files.folders.prefs, "favorites.txt"}, context.temp_allocator)
	testing.expect(t, os.exists(saved), "saved")
	testing.expect_value(t, pa.browser_remove_favorite(api, 0 if i > 0 else i), pa.Result.Ok)
	s, _ = pa.browser_state(api)
	testing.expect_value(t, s.favorites, n0)
	// A search (on its own thread), the preview's settings.
	pa.browser_go(api, lib)
	testing.expect_value(t, pa.browser_search(api, "boom"), pa.Result.Ok)
	for k2 := 0; k2 < 500; k2 += 1 {
		s, _ = pa.browser_state(api)
		if !s.searching do break
		frame(r)
	}
	s, _ = pa.browser_state(api)
	testing.expect_value(t, s.results, 1)
	res, _ := pa.browser_result(api, 0)
	rp, _ := pa.browser_result_path(api, 0)
	testing.expect(t, !res.is_dir && rp == k, "found")
	pa.browser_search(api, "")
	testing.expect_value(t, pa.browser_set_preview_settings(api, {auto_play = false, sync = true, volume_db = -12}), pa.Result.Ok)
	ps, _ := pa.browser_preview_settings(api)
	testing.expect(t, !ps.auto_play && ps.sync && ps.volume_db == -12, "set")
	testing.expect_value(t, pa.browser_set_preview_settings(api, {volume_db = 20}), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.browser_preview(api, tone(r)), pa.Result.Ok)
	testing.expect_value(t, pa.browser_preview_stop(api), pa.Result.Ok)
	testing.expect_value(t, pa.browser_preview(api, ""), pa.Result.Invalid_Argument)
}

@(test)
midi_map_and_pads_midi :: proc(t: ^testing.T) {
	r := rig_make(t, "midi")
	defer rig_destroy(r)
	api := &r.api
	n, _ := pa.midi_port_count(api)
	testing.expect(t, n >= 0, "ports listed")
	_, res := pa.midi_port(api, n)
	testing.expect_value(t, res, pa.Result.Not_Found)
	_, res = pa.midi_port_name(api, n)
	testing.expect_value(t, res, pa.Result.Not_Found)
	_, res = pa.midi_port_id(api, n)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.midi_learn(api, 2, 5), pa.Result.Ok) // (key 5 plays it too: the default map)
	key, _ := pa.midi_key_of(api, 5)
	testing.expect_value(t, key, 2) // (the lowest)
	testing.expect_value(t, pa.midi_learn(api, 200, 5), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.midi_set_pad_input(api, 5, .Port, "port-1", 3), pa.Result.Ok)
	testing.expect_value(t, pa.midi_set_pad_input(api, 5, .Port, "", 3), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.midi_set_pad_output(api, 5, true, 9, 36, ""), pa.Result.Ok)
	pmidi, _ := pa.midi_pad(api, 5)
	testing.expect(t, pmidi.in_mode == .Port && pmidi.in_channel == 3 && pmidi.out && pmidi.out_channel == 9 && pmidi.out_key == 36, "set")
	u, _ := pa.history_undo_name(api)
	testing.expect_value(t, u, "MIDI Out")
	testing.expect_value(t, pa.midi_send(api, 0x90, 60, 100), pa.Result.Ok)
	testing.expect_value(t, pa.midi_send(api, 0x10, 60, 100), pa.Result.Invalid_Argument)
	// A pad's audio input.
	testing.expect_value(t, pa.pad_set_input(api, 5, {from = .Interface, channel = 2, stereo = true}), pa.Result.Ok)
	in_, _ := pa.pad_input(api, 5)
	testing.expect(t, in_.from == .Interface && in_.channel == 2 && in_.stereo, "inputs 3/4")
	testing.expect_value(t, pa.pad_set_input(api, 5, {from = .Pad, source = 5}), pa.Result.Invalid_Argument)
}
