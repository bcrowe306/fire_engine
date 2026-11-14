package test_pads_api

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import app "app:core"
import pa "../../apps/pads/api"
import pc "../../apps/pads/core"

@(private)
Opened :: struct {
	count: int,
}

@(test)
new_save_as_rename_and_open_again :: proc(t: ^testing.T) {
	r := rig_make(t, "project_flow")
	defer rig_destroy(r)
	api := &r.api
	o: Opened
	r.core.hooks = {user = &o, opened = proc(user: rawptr) { (^Opened)(user).count += 1 }}
	// A new project: untitled, in the unsaved folder.
	testing.expect_value(t, pa.project_new(api, false), pa.Result.Ok)
	testing.expect_value(t, o.count, 1)
	ps, _ := pa.project_state(api)
	testing.expect(t, ps.untitled && !ps.dirty, "untitled, clean")
	name, _ := pa.project_name(api)
	testing.expect_value(t, name, "Untitled")
	dir, _ := pa.project_dir(api)
	untitled_dir := strings.clone(dir, context.temp_allocator)
	testing.expect(t, strings.has_prefix(dir, r.core.files.folders.unsaved), "in the unsaved folder")
	// Changes: leaving them is Busy unless they may go.
	pa.transport_set_tempo(api, 99)
	testing.expect_value(t, pa.project_new(api, false), pa.Result.Busy)
	why, _ := pa.last_error(api)
	testing.expect(t, strings.contains(why, "not saved"), "says why")
	// An untitled project's Save keeps it where it is; Rename wants a place first.
	testing.expect_value(t, pa.project_save(api), pa.Result.Ok)
	ps, _ = pa.project_state(api)
	testing.expect(t, ps.untitled && !ps.dirty, "saved, still untitled")
	testing.expect_value(t, pa.project_rename(api, "Beat"), pa.Result.Unsupported)
	// Save As: it moves out of the unsaved folder, which lets it go.
	to, _ := filepath.join({r.dir, "Songs", "Beat"}, context.temp_allocator)
	os.make_directory_all(filepath.dir(to))
	testing.expect_value(t, pa.project_save_as(api, to), pa.Result.Ok)
	dir, _ = pa.project_dir(api)
	testing.expect_value(t, dir, strings.concatenate({to, ".pads"}, context.temp_allocator))
	name, _ = pa.project_name(api)
	testing.expect_value(t, name, "Beat")
	testing.expect(t, !os.exists(untitled_dir), "the unsaved folder's copy gone")
	ps, _ = pa.project_state(api)
	testing.expect(t, !ps.untitled && ps.recent == 1, "saved somewhere, recent")
	// Not over another project.
	testing.expect_value(t, pa.project_save_as(api, to), pa.Result.Ok) // (itself: fine)
	other, _ := filepath.join({r.dir, "Songs", "Other.pads"}, context.temp_allocator)
	os.make_directory_all(other)
	testing.expect_value(t, pa.project_save_as(api, other), pa.Result.Invalid_Argument)
	why, _ = pa.last_error(api)
	testing.expect_value(t, why, "Other.pads is already there")
	testing.expect_value(t, pa.project_save_as(api, other, replace = true), pa.Result.Ok)
	testing.expect_value(t, pa.project_save_as(api, to, replace = true), pa.Result.Ok) // (back into Beat.pads, its earlier copy)
	// Rename: the folder beside it.
	testing.expect_value(t, pa.project_rename(api, "a/b"), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.project_rename(api, "Groove"), pa.Result.Ok)
	name, _ = pa.project_name(api)
	testing.expect_value(t, name, "Groove")
	groove, _ := pa.project_dir(api)
	groove = strings.clone(groove, context.temp_allocator)
	recent, _ := pa.project_recent(api, 0)
	testing.expect_value(t, recent, groove)
	_, res := pa.project_recent(api, 5)
	testing.expect_value(t, res, pa.Result.Not_Found)
	// Another new one, then Groove opened again: its tempo as it was saved.
	testing.expect_value(t, pa.project_new(api, false), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.bpm, 120)
	testing.expect_value(t, pa.project_open(api, "/no/such/place", false), pa.Result.Not_Found)
	testing.expect_value(t, pa.project_open(api, groove, false), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.bpm, 99)
	ps, _ = pa.project_state(api)
	testing.expect(t, !ps.untitled, "a saved project")
	testing.expect_value(t, o.count, 3)
}

@(test)
templates_are_saved_and_started_from :: proc(t: ^testing.T) {
	r := rig_make(t, "project_templates")
	defer rig_destroy(r)
	api := &r.api
	pa.transport_set_tempo(api, 87)
	testing.expect_value(t, pa.project_save_template(api, ""), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.project_save_template(api, "Slow Beat"), pa.Result.Ok)
	ps, _ := pa.project_state(api)
	testing.expect_value(t, ps.templates, 1)
	n, _ := pa.project_template_name(api, 0)
	testing.expect_value(t, n, "Slow Beat")
	_, res := pa.project_template_name(api, 1)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.project_new_from_template(api, "Nope", true), pa.Result.Not_Found)
	testing.expect_value(t, pa.project_new_from_template(api, "Slow Beat", true), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.bpm, 87)
	ps, _ = pa.project_state(api)
	testing.expect(t, ps.untitled, "a new, untitled project")
}

@(test)
a_backup_is_recovered_or_thrown_away :: proc(t: ^testing.T) {
	r := rig_make(t, "project_recover")
	defer rig_destroy(r)
	api := &r.api
	to, _ := filepath.join({r.dir, "Kept"}, context.temp_allocator)
	pa.project_save_as(api, to)
	kept, _ := pa.project_dir(api)
	kept = strings.clone(kept, context.temp_allocator)
	testing.expect_value(t, pa.project_recover(api, kept), pa.Result.Not_Found) // (no backup yet)
	// Changes autosaved (as Pads does every few minutes), then lost (as a
	// crash loses them): the backup brings them back, not yet saved.
	pa.transport_set_tempo(api, 140)
	pc.autosave(&r.core, 1, false)
	pa.history_undo(api)
	testing.expect_value(t, r.core.m.project.bpm, 120)
	testing.expect_value(t, pa.project_recover(api, kept), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.bpm, 140)
	ps, _ := pa.project_state(api)
	testing.expect(t, ps.dirty && !ps.untitled, "recovered: changed, not saved")
	testing.expect_value(t, pa.project_discard_backup(api, kept), pa.Result.Busy) // (it is open)
	// Leaving a project throws its backup away.
	pa.project_new(api, true)
	testing.expect_value(t, pa.project_recover(api, kept), pa.Result.Not_Found)
	testing.expect_value(t, pa.project_discard_backup(api, kept), pa.Result.Ok)
}

@(test)
clean_up_moves_what_nothing_uses :: proc(t: ^testing.T) {
	r := rig_make(t, "project_clean_up")
	defer rig_destroy(r)
	api := &r.api
	to, _ := filepath.join({r.dir, "Tidy"}, context.temp_allocator)
	pa.project_save_as(api, to)
	dir, _ := pa.project_dir(api)
	// A file in its samples folder nothing uses.
	samples, _ := filepath.join({dir, "samples"}, context.temp_allocator)
	os.make_directory_all(samples)
	stray, _ := filepath.join({samples, "stray.wav"}, context.temp_allocator)
	_ = os.write_entire_file(stray, make([]u8, 1000, context.temp_allocator))
	trash, _ := filepath.join({r.dir, "Trash"}, context.temp_allocator)
	app.trash_redirect(trash) // (not the user's)
	u, _ := pa.project_unused_files(api)
	testing.expect_value(t, u.unused, 1)
	testing.expect_value(t, u.unused_bytes, 1000)
	c, res := pa.project_clean_up(api, false, false)
	testing.expect_value(t, res, pa.Result.Ok)
	testing.expect_value(t, c.files, 1)
	testing.expect_value(t, c.bytes, 1000)
	testing.expect(t, !os.exists(stray), "moved to the Trash")
	u, _ = pa.project_unused_files(api)
	testing.expect_value(t, u.unused, 0)
}
