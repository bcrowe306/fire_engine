package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"

@(private = "file")
binned: [dynamic]string

@(private = "file")
fake_trash :: proc(path: string) -> bool {
	if !os.exists(path) do return false
	append(&binned, path)
	return (os.remove_all(path) if os.is_dir(path) else os.remove(path)) == nil
}

@(private = "file")
find :: proc(files: []pm.Unused_File, kind: pm.Unused_Kind) -> (pm.Unused_File, bool) {
	for f in files do if f.kind == kind do return f, true
	return {}, false
}

// Offered: a file no sample is (ticked by the dialog), a sample only undo
// would bring back, the cache; what plays never. Cleaned up: the project
// saved, undo forgotten when it had to be.
@(test)
clean_up_offers_what_the_project_does_not_use :: proc(t: ^testing.T) {
	r := rig_make(t, "cleanup")
	defer rig_destroy(r)
	defer delete(binned)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "kick.wav", 440, 0.05))
	kick := pm.pad_sample(m, 0).path
	pm.load_onto_pad(m, 1, tone(r, "hat.wav", 880, 0.05))
	pm.load_onto_pad(m, 1, tone(r, "snare.wav", 660, 0.05)) // (hat.wav replaced: only undo uses it now)
	stray := pm.project_new_file(m.project.dir, .Recorded, "Recording-9.wav")
	defer delete(stray)
	_ = os.write_entire_file(stray, {1, 2, 3, 4})
	ds, _ := filepath.join({pm.project_folder(m.project.dir, .Imported), ".DS_Store"}, context.temp_allocator)
	_ = os.write_entire_file(ds, {1})
	junk_cache := pm.project_folder_make(m.project.dir, .Comp)
	jc, _ := filepath.join({junk_cache, "comp.wav"}, context.temp_allocator)
	_ = os.write_entire_file(jc, {1, 2})
	files := pm.unused_files(m)
	testing.expect_value(t, len(files), 3)
	unused, u_ok := find(files, .Unused)
	undo, d_ok := find(files, .Undo_Only)
	_, c_ok := find(files, .Cache)
	testing.expect(t, u_ok && unused.path == stray && unused.size == 4, "the stray file")
	testing.expect(t, d_ok && filepath.base(undo.path) == "hat.wav", "the replaced sample")
	testing.expect(t, c_ok, "the cache")
	for f in files do testing.expect(t, f.path != kick, "what plays is never offered")
	// The stray file alone: undo kept (but not redo).
	n, bytes := pm.clean_up(m, {unused}, fake_trash)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, bytes, i64(4))
	testing.expect(t, !os.exists(stray), "trashed")
	testing.expect(t, app.undo_name(&m.history) != "", "undo kept")
	testing.expect(t, !pm.model_dirty(m), "saved")
	// The replaced sample: gone from the project, undo forgotten.
	n, _ = pm.clean_up(m, {undo}, fake_trash)
	testing.expect_value(t, n, 1)
	testing.expect(t, app.store_get(&m.project.samples, undo.sample) == nil, "no longer the project's")
	testing.expect_value(t, app.undo_name(&m.history), "")
	testing.expect(t, os.exists(kick), "what plays stays")
	testing.expect(t, os.exists(ds), "system files left alone")
	pm.hit(&m.engine, 0, true)
	out := render(r, 4800)
	testing.expect(t, abs(out[0][100]) + abs(out[0][2000]) > 0, "still plays")
}
