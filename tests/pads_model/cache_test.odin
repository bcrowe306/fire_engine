package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import fc "fire:core"
import pm "../../apps/pads/model"

// A file of `size` bytes in `dir`, made `age` ago.
@(private = "file")
junk :: proc(dir, name: string, size: int, age: time.Duration) -> string {
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	_ = os.write_entire_file(path, make([]u8, size, context.temp_allocator))
	at := time.time_add(time.now(), -age)
	_ = os.change_times(path, at, at)
	return path
}

// What the project plays stays; of the rest the newest, up to the budget;
// half-made renderings and an older project's caches go.
@(test)
the_cache_keeps_what_plays_and_the_newest_of_the_rest :: proc(t: ^testing.T) {
	r := rig_make(t, "cache_trim")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, clicks(r, "loop100.wav", 100, 4))
	render(r, 256)
	pm.set_warp(m, 0, {on = true, mode = .Beats})
	testing.expect(t, warp_ready(r, 0), "rendered")
	warp := pm.project_folder(m.project.dir, .Warp)
	entries, _ := os.read_all_directory_by_path(warp, context.temp_allocator)
	if !testing.expect_value(t, len(entries), 1) do return
	playing, _ := filepath.join({warp, entries[0].name}, context.temp_allocator)
	newer := junk(warp, "undone tones.wav", 1000, time.Hour)
	older := junk(warp, "undone complex.wav", 1000, 48 * time.Hour)
	comp_old := junk(pm.project_folder(m.project.dir, .Comp), "comp 1 1 0.wav", 1000, 72 * time.Hour)
	half := junk(warp, "stopped.wav.part", 500, 0)
	spool := junk(pm.project_folder(m.project.dir, .Spool), "A1-1.wav", 100, 99 * time.Hour)
	legacy, _ := filepath.join({m.project.dir, "warped"}, context.temp_allocator)
	junk(legacy, "x.wav", 10, 0)
	removed := pm.cache_trim(&m.project, keep = 1500)
	testing.expect(t, os.exists(playing), "what plays now kept")
	testing.expect(t, os.exists(newer), "the newest of the rest kept")
	testing.expect(t, !os.exists(older), "past the budget: the older gone")
	testing.expect(t, !os.exists(comp_old), "and the oldest comp")
	testing.expect(t, !os.exists(half), "a half-made rendering gone")
	testing.expect(t, !os.exists(legacy), "an older project's warped/ gone")
	testing.expect(t, os.exists(spool), "takes being recorded left alone")
	testing.expect_value(t, removed, i64(1000 + 1000 + 500 + 10))
}

// Opened again, a warped pad finds its rendering where it was (closing
// trims, but keeps what the project plays).
@(test)
a_reopened_project_keeps_its_renderings :: proc(t: ^testing.T) {
	r := rig_make(t, "cache_reopen")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, clicks(r, "loop100.wav", 100, 4))
	render(r, 256)
	pm.set_warp(m, 0, {on = true, mode = .Beats})
	testing.expect(t, warp_ready(r, 0), "rendered")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	warp := pm.project_folder(m.project.dir, .Warp)
	before, _ := os.read_all_directory_by_path(warp, context.temp_allocator)
	dir := strings.clone(m.project.dir, context.temp_allocator) // (the project's own goes with it)
	testing.expect_value(t, pm.model_load(m, dir), fc.Error.None)
	after, _ := os.read_all_directory_by_path(warp, context.temp_allocator)
	testing.expect_value(t, len(after), len(before))
	render(r, 256)
	testing.expect(t, !pm.warp_rendering(&m.engine, 0), "played at once, not rendered again")
}
