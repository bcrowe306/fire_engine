package test_pads_model

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:time"

import pm "../../apps/pads/model"
import fc "fire:core"
import kit "fire:testkit"

// A folder tree to browse: Drums/Kicks/kick.wav, Drums/snare.wav,
// Loops/loop.wav, a link to Loops, and a text file (not listed).
@(private)
sample_tree :: proc(r: ^Rig) -> (root: string, linked: bool) {
	root, _ = filepath.join({r.dir, "tree"}, context.temp_allocator)
	for d in ([]string{"Drums/Kicks", "Loops", ".hidden"}) {
		p, _ := filepath.join({root, d}, context.temp_allocator)
		os.make_directory_all(p)
	}
	put :: proc(r: ^Rig, root, rel: string) {
		src := tone(r, "src.wav", 220, 0.1)
		dst, _ := filepath.join({root, rel}, context.temp_allocator)
		data, _ := os.read_entire_file(src, context.temp_allocator)
		_ = os.write_entire_file(dst, data)
	}
	put(r, root, "Drums/Kicks/Kick 808.wav")
	put(r, root, "Drums/snare.WAV")
	put(r, root, "Loops/loop.wav")
	put(r, root, ".hidden/kick secret.wav")
	notes, _ := filepath.join({root, "notes.txt"}, context.temp_allocator)
	_ = os.write_entire_file(notes, transmute([]u8)string("not audio"))
	loops, _ := filepath.join({root, "Loops"}, context.temp_allocator)
	link, _ := filepath.join({root, "Linked Loops"}, context.temp_allocator)
	linked = os.symlink(loops, link) == nil // Windows may not allow it
	return
}

@(test)
the_browser_navigates_a_tree_with_history :: proc(t: ^testing.T) {
	r := rig_make(t, "browser_nav")
	defer rig_destroy(r)
	root, linked := sample_tree(r)
	b: pm.Browser
	pm.browser_init(&b, "")
	defer pm.browser_destroy(&b)
	// A new browser starts in Documents, and has a tab for the project.
	testing.expect_value(t, len(b.favorites), 2)
	testing.expect(t, b.favorites[1].project, "the project's tab")

	pm.browser_go(&b, root)
	rows := pm.browser_rows(&b)
	names := make([dynamic]string, context.temp_allocator)
	for e in rows do append(&names, e.name)
	// Folders first (the link to a folder too), then audio; no hidden or text files.
	if linked {
		testing.expectf(t, len(rows) == 3 && rows[0].name == "Drums" && rows[1].name == "Linked Loops" && rows[1].is_dir && rows[2].name == "Loops", "the root: %v", names)
	} else {
		testing.expectf(t, len(rows) == 2 && rows[0].name == "Drums" && rows[1].name == "Loops", "the root (no link): %v", names)
	}

	// Into Drums, then up: the root again (up used to read freed memory).
	drums := rows[0].path
	pm.browser_go(&b, drums)
	testing.expect_value(t, filepath.base(b.root), "Drums")
	testing.expect(t, pm.browser_up(&b), "up")
	testing.expect_value(t, b.root, root)
	// Back to Drums, back to the root, forward to Drums.
	testing.expect(t, pm.browser_back(&b), "back")
	testing.expect_value(t, filepath.base(b.root), "Drums")
	testing.expect(t, pm.browser_back(&b), "back again")
	testing.expect_value(t, b.root, root)
	testing.expect(t, pm.browser_forward(&b), "forward")
	testing.expect_value(t, filepath.base(b.root), "Drums")
	// The path, as clickable parts, ends with the root.
	crumbs := pm.browser_crumbs(&b)
	testing.expect(t, len(crumbs) >= 2 && crumbs[len(crumbs) - 1].name == "Drums" && crumbs[len(crumbs) - 2].name == "tree", "crumbs")

	// The tree: open Drums and Kicks in place; the keyboard walks the rows.
	pm.browser_go(&b, root)
	pm.browser_expand(&b, drums, true)
	kicks, _ := filepath.join({drums, "Kicks"}, context.temp_allocator)
	pm.browser_expand(&b, kicks, true)
	rows = pm.browser_rows(&b)
	clear(&names)
	for e in rows do append(&names, e.name)
	testing.expectf(t, len(rows) == (6 if linked else 5), "open folders show inside: %v", names)
	testing.expect(t, rows[1].name == "Kicks" && rows[1].depth == 1 && rows[2].name == "Kick 808.wav" && rows[2].depth == 2 && rows[3].name == "snare.WAV", "indented")
	e, _ := pm.browser_step(&b, rows, 1)
	testing.expect_value(t, e.name, "Drums") // nothing was selected: the first
	e, _ = pm.browser_step(&b, rows, 2)
	testing.expect_value(t, e.name, "Kick 808.wav")
	e, _ = pm.browser_step(&b, rows, 100)
	testing.expect_value(t, e.name, "Loops") // stops at the end
	pm.browser_toggle(&b, drums)
	testing.expect_value(t, len(pm.browser_rows(&b)), 3 if linked else 2)
}

@(test)
favorites_are_tabs_that_persist :: proc(t: ^testing.T) {
	r := rig_make(t, "browser_favs")
	defer rig_destroy(r)
	root, _ := sample_tree(r)
	file, _ := filepath.join({r.dir, "favorites.txt"}, context.temp_allocator)
	loops, _ := filepath.join({root, "Loops"}, context.temp_allocator)
	{
		b: pm.Browser
		pm.browser_init(&b, file)
		defer pm.browser_destroy(&b)
		i := pm.favorite_add(&b, loops)
		testing.expect_value(t, b.favorites[i].name, "Loops")
		testing.expect_value(t, pm.favorite_add(&b, loops), i) // once
		testing.expect(t, pm.is_favorite(&b, loops), "a favourite")
		pm.favorite_rename(&b, i, "My loops")
		pm.favorite_move(&b, i, 0)
		pm.browser_set_tab(&b, 0)
		testing.expect_value(t, b.root, loops)
		testing.expect_value(t, len(pm.browser_rows(&b)), 1)
		// The project tab follows the project.
		pm.browser_set_project(&b, r.dir)
		samples, _ := filepath.join({r.dir, "samples"}, context.temp_allocator)
		testing.expect_value(t, pm.favorite_dir(&b, 2), samples)
		testing.expect(t, pm.favorites_save(&b, file), "saved")
	}
	b: pm.Browser
	pm.browser_init(&b, file)
	defer pm.browser_destroy(&b)
	testing.expect_value(t, len(b.favorites), 3)
	testing.expect(t, b.favorites[0].name == "My loops" && b.favorites[0].path == loops, "the order and names come back")
	testing.expect(t, b.favorites[2].project, "the project tab too")
	pm.favorite_remove(&b, 0)
	testing.expect_value(t, len(b.favorites), 2)
	pm.favorite_remove(&b, 0)
	pm.favorite_remove(&b, 0) // the last one stays
	testing.expect_value(t, len(b.favorites), 1)
}

@(test)
search_finds_files_in_every_folder_under_the_tab :: proc(t: ^testing.T) {
	r := rig_make(t, "browser_search")
	defer rig_destroy(r)
	root, _ := sample_tree(r)
	b: pm.Browser
	pm.browser_init(&b, "")
	defer pm.browser_destroy(&b)
	pm.favorite_add(&b, root)
	pm.browser_set_tab(&b, 2)
	pm.browser_search(&b, "KICK")
	deadline := time.tick_now()
	for !pm.search_done(&b.search) && time.tick_since(deadline) < 5 * time.Second do time.sleep(time.Millisecond)
	res := pm.search_results(&b.search)
	testing.expectf(t, len(res) == 1 && filepath.base(res[0].path) == "Kick 808.wav", "one kick, not the hidden one (%v)", len(res))
	if len(res) == 1 {
		rel, _ := filepath.join({"Drums", "Kicks", "Kick 808.wav"}, context.temp_allocator)
		testing.expect_value(t, res[0].name, rel)
	}
	testing.expect(t, sync.atomic_load(&b.search.scanned) > 0, "it looked")
	// A new query replaces it; "" stops it.
	pm.browser_search(&b, "loop")
	for !pm.search_done(&b.search) && time.tick_since(deadline) < 5 * time.Second do time.sleep(time.Millisecond)
	testing.expect_value(t, len(pm.search_results(&b.search)), 1) // the link isn't followed twice
	pm.browser_search(&b, "")
	testing.expect_value(t, len(pm.search_results(&b.search)), 0)
	// How fast it looks: the engine's sources (thousands of files, no audio).
	cwd, _ := os.get_working_directory(context.temp_allocator)
	src, _ := filepath.join({cwd, "f_engine"}, context.temp_allocator)
	if os.is_dir(src) {
		pm.browser_go(&b, src)
		t0 := time.tick_now()
		pm.browser_search(&b, "nothing-is-called-this")
		for !pm.search_done(&b.search) && time.tick_since(t0) < 20 * time.Second do time.sleep(time.Millisecond)
		ms := time.duration_milliseconds(time.tick_since(t0))
		n := sync.atomic_load(&b.search.scanned)
		log.infof("search: %d files and folders in %.1f ms (%.0f per ms)", n, ms, f64(n) / max(ms, 0.001))
		testing.expect(t, pm.search_done(&b.search) && n > 100, "it got through them")
	}
}

@(test)
loops_are_measured_in_beats :: proc(t: ^testing.T) {
	testing.expect_value(t, pm.loop_beats(2, 120), 4)   // one bar
	testing.expect_value(t, pm.loop_beats(2.2, 120), 4) // close enough
	testing.expect_value(t, pm.loop_beats(4, 120), 8)
	testing.expect_value(t, pm.loop_beats(0.2, 120), 0) // a one-shot
	testing.expect_value(t, pm.loop_beats(3, 120), 0)   // 6 beats: no power of two near it
}

// A preview node with a clip of a 441 Hz sine at 44.1 kHz waiting.
@(private)
make_preview :: proc(_: rawptr) -> fc.Node {
	node, p := pm.preview_node_create()
	c := new(pm.Preview_Clip)
	c.rate, c.frames = 44_100, 44_100
	c.data = {make([]f32, c.frames), make([]f32, c.frames)}
	for i in 0 ..< c.frames {
		v := f32(0.5 * math.sin(math.TAU * 441 * f64(i) / 44_100))
		c.data[0][i], c.data[1][i] = v, -v
	}
	p.pending = c
	return node
}

@(test)
the_preview_node_plays_a_clip_once_at_the_engine_rate :: proc(t: ^testing.T) {
	cfg := kit.default_render_config()
	cfg.tail_frames = 60_000
	cfg.out_channels = 2
	node := make_preview(nil)
	defer fc.node_destroy(&node)
	out, rep := kit.render(&node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
	kit.expect_clean_render(t, rep)
	x := out.channels[0]
	// One second of it at 48 kHz, its pitch kept; then silence.
	amp := kit.tone_amplitude(x[4_800:][:24_000], 48_000, 441)
	testing.expectf(t, abs(amp - 0.5) < 0.02, "441 Hz at 48 kHz (%v)", amp)
	testing.expectf(t, kit.peak(x[48_100:]) == 0, "it ends after its second")
	testing.expectf(t, abs(f64(out.channels[1][1000]) + f64(x[1000])) < 1e-6, "stereo kept")
	kit.expect_block_invariant(t, {create = make_preview}, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg,
		{kit.Fixed_Blocks{512}, kit.Fixed_Blocks{1}, kit.Random_Blocks{seed = 3, min = 0, max = 512}})
}

@(test)
the_browser_preview_plays_stops_and_syncs :: proc(t: ^testing.T) {
	r := rig_make(t, "browser_preview")
	defer rig_destroy(r)
	e := &r.m.engine
	testing.expect(t, e.preview.auto_play && e.preview.volume == -6, "auto-play on, at -6 dB")
	path := tone(r, "loop.wav", 500, 2.2) // 2.2 s: 4 beats at 120 BPM, near enough
	wait :: proc(r: ^Rig) {
		for i := 0; i < 2000 && r.m.engine.preview.loading != nil; i += 1 {
			pm.sync(&r.m.engine)
			time.sleep(time.Millisecond)
		}
	}
	pm.preview_play(e, path)
	testing.expect(t, pm.preview_playing(e), "playing (decoding)")
	wait(r)
	out := render(r, 9600)
	testing.expectf(t, abs(kit.peak(out[0][4800:]) - 0.25) < 0.02, "at -6 dB, straight out (%v)", kit.peak(out[0][4800:]))
	testing.expect(t, pm.preview_progress(e) > 0, "a playhead")
	testing.expectf(t, abs(e.preview.frames - int(2.2 * SR)) < 2, "raw: its own length (%v)", e.preview.frames)
	// Louder, then stopped (a short fade).
	e.preview.volume = 0
	render(r, 4800)
	out = render(r, 4800)
	testing.expectf(t, abs(kit.peak(out[0][:]) - 0.5) < 0.02, "at 0 dB (%v)", kit.peak(out[0][:]))
	pm.preview_stop(e)
	render(r, 1024)
	out = render(r, 4800)
	testing.expect(t, kit.peak(out[0][:]) == 0 && !pm.preview_playing(e), "stopped")
	// Synced while the sequencer plays at 100 BPM: stretched to its 4 beats.
	r.m.project.bpm = 100
	e.preview.sync = true
	pm.play(e)
	render(r, 256)
	pm.preview_play(e, path)
	wait(r)
	testing.expect_value(t, e.preview.beats, 4)
	testing.expectf(t, abs(e.preview.frames - int(2.4 * SR)) < 2, "4 beats at 100 BPM (%v)", e.preview.frames)
	pm.stop(e)
}
