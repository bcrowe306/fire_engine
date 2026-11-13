package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import app "app:core"
import fc "fire:core"
import pm "../../apps/pads/model"

@(private = "file")
under :: proc(path, folder: string) -> bool {
	return filepath.dir(path) == folder
}

@(private = "file")
file_bytes :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@(test)
new_files_go_to_their_folders :: proc(t: ^testing.T) {
	r := rig_make(t, "paths_folders")
	defer rig_destroy(r)
	m := &r.m
	dir := m.project.dir
	// Brought in: Samples/Imported, twice the same name side by side.
	src := tone(r, "kick.wav", 440, 0.05)
	a, aerr := pm.import_sample(m, src)
	b, berr := pm.import_sample(m, src)
	testing.expect_value(t, aerr, fc.Error.None)
	testing.expect_value(t, berr, fc.Error.None)
	sa, sb := app.store_get(&m.project.samples, a), app.store_get(&m.project.samples, b)
	if !testing.expect(t, sa != nil && sb != nil, "both imported") do return
	testing.expect(t, under(sa.path, pm.project_folder(dir, .Imported)), "in Samples/Imported")
	testing.expect(t, sa.path != sb.path, "each its own file")
	// An edit's result: Samples/Processed.
	pm.load_onto_pad(m, 0, src)
	testing.expect_value(t, pm.edit_audio(m, 0, .Reverse), fc.Error.None)
	s := pm.pad_sample(m, 0)
	if !testing.expect(t, s != nil, "the edit on the pad") do return
	testing.expect(t, under(s.path, pm.project_folder(dir, .Processed)), "in Samples/Processed")
	// Warp renderings go under cache/.
	testing.expect(t, strings.has_prefix(pm.project_folder(dir, .Warp), filepath.join({dir, pm.CACHE_FOLDER}, context.temp_allocator) or_else ""), "warps are a cache")
	// A name with a separator in it (a sequence called "A/B") stays one file.
	n := pm.project_new_file(dir, .Processed, "Bounce A/B.wav")
	defer delete(n)
	testing.expect(t, under(n, pm.project_folder(dir, .Processed)), "not a folder of its own")
}

@(test)
paths_are_stored_portably :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		dir := "C:\\Music\\Song.pads"
		inside := "C:\\Music\\Song.pads\\Samples\\Recorded\\A1 seq 1.wav"
		outside := "D:\\Library\\kick.wav"
	} else {
		dir := "/Music/Song.pads"
		inside := "/Music/Song.pads/Samples/Recorded/A1 seq 1.wav"
		outside := "/Library/kick.wav"
	}
	testing.expect_value(t, pm.stored_path(dir, inside), "Samples/Recorded/A1 seq 1.wav")
	testing.expect_value(t, pm.stored_path(dir, outside), outside) // (outside: absolute, not ../..)
	testing.expect_value(t, pm.loaded_path(dir, "Samples/Recorded/A1 seq 1.wav"), inside)
	testing.expect_value(t, pm.loaded_path(dir, "Samples\\Recorded\\A1 seq 1.wav"), inside) // written on Windows
	testing.expect_value(t, pm.loaded_path(dir, outside), outside)
}

@(test)
save_as_keeps_the_layout_and_overwrites_nothing :: proc(t: ^testing.T) {
	r := rig_make(t, "paths_save_as")
	defer rig_destroy(r)
	m := &r.m
	dir := m.project.dir
	// Inside: an import (Samples/Imported/kick.wav) and an older project's
	// samples/old.wav. Outside: another kick.wav, different audio.
	pm.load_onto_pad(m, 0, tone(r, "kick.wav", 440, 0.05))
	old_dir, _ := filepath.join({dir, "samples"}, context.temp_allocator)
	os.make_directory_all(old_dir)
	old, _ := filepath.join({old_dir, "old.wav"}, context.temp_allocator)
	_ = os.write_entire_file(old, transmute([]u8)file_bytes(pm.pad_sample(m, 0).path))
	old_id := pm.add_sample(m, old, {sample_rate = SR, channels = 1, frames = 2400})
	elsewhere, _ := filepath.join({dir, "..", "paths_save_as_elsewhere"}, context.temp_allocator)
	os.remove_all(elsewhere)
	os.make_directory_all(elsewhere)
	defer os.remove_all(elsewhere)
	r2 := tone(r, "other.wav", 880, 0.07)
	outside, _ := filepath.join({elsewhere, "kick.wav"}, context.temp_allocator)
	_ = os.write_entire_file(outside, transmute([]u8)file_bytes(r2))
	out_id := pm.add_sample(m, outside, {sample_rate = SR, channels = 1, frames = 3360})
	kick := pm.pad_sample(m, 0)
	kick_bytes := file_bytes(kick.path)
	to, _ := filepath.join({dir, "..", "paths_save_as_copy.pads"}, context.temp_allocator)
	os.remove_all(to)
	defer os.remove_all(to)
	testing.expect_value(t, pm.model_save_as(m, to), fc.Error.None)
	// Each inside file at its own place in the new folder.
	kick = pm.pad_sample(m, 0)
	testing.expect_value(t, pm.stored_path(to, kick.path), "Samples/Imported/kick.wav")
	testing.expect_value(t, file_bytes(kick.path), kick_bytes)
	o := app.store_get(&m.project.samples, old_id)
	testing.expect_value(t, pm.stored_path(to, o.path), "samples/old.wav")
	testing.expect(t, os.exists(o.path), "the older folder's file copied")
	// The outside kick.wav: into Samples/Imported, another name, its own audio.
	x := app.store_get(&m.project.samples, out_id)
	testing.expect(t, under(x.path, pm.project_folder(to, .Imported)), "brought in")
	testing.expect(t, x.path != kick.path, "not over the inside kick.wav")
	testing.expect_value(t, file_bytes(x.path), file_bytes(outside))
	// Opened again: the same files.
	testing.expect_value(t, pm.model_load(m, to), fc.Error.None)
	testing.expect_value(t, pm.pad_sample(m, 0).path, kick.path)
}

@(test)
a_template_copies_its_folders_but_not_its_cache :: proc(t: ^testing.T) {
	r := rig_make(t, "paths_template")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "kick.wav", 440, 0.05))
	tpl, _ := filepath.join({m.project.dir, "..", "paths_template_tpl.pads"}, context.temp_allocator)
	os.remove_all(tpl)
	defer os.remove_all(tpl)
	testing.expect_value(t, pm.model_save_copy(m, tpl), fc.Error.None)
	// The template has a cache and a backup of its own: not copied.
	cache := pm.project_folder_make(tpl, .Warp)
	junk, _ := filepath.join({cache, "x.wav"}, context.temp_allocator)
	_ = os.write_entire_file(junk, {1, 2, 3})
	bak, _ := filepath.join({tpl, pm.BACKUP_DIR}, context.temp_allocator)
	os.make_directory_all(bak)
	to, _ := filepath.join({m.project.dir, "..", "paths_template_new.pads"}, context.temp_allocator)
	os.remove_all(to)
	defer os.remove_all(to)
	testing.expect_value(t, pm.model_new_from(m, tpl, to), fc.Error.None)
	s := pm.pad_sample(m, 0)
	if !testing.expect(t, s != nil, "the template's sample") do return
	testing.expect_value(t, pm.stored_path(to, s.path), "Samples/Imported/kick.wav")
	testing.expect(t, os.exists(s.path), "copied")
	not_cache, _ := filepath.join({to, pm.CACHE_FOLDER}, context.temp_allocator)
	not_bak, _ := filepath.join({to, pm.BACKUP_DIR}, context.temp_allocator)
	testing.expect(t, !os.exists(not_cache), "no cache")
	testing.expect(t, !os.exists(not_bak), "no backup")
}
