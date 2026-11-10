package test_session

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:record"
import "fire:sampler"
import "fire:session"
import "fire:stream"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

// Everything a session needs around it.
Rig :: struct {
	clock:    ^transport.Clock,
	graph:    ^graph.Graph,
	streamer: ^stream.Streamer,
	disk:     ^record.Disk_Writer,
	env:      session.Environment,
	reg:      core.Node_Registry,
	trap:     kit.Trap_Allocator,
}

rig_make :: proc() -> ^Rig {
	r := new(Rig)
	r.clock, _ = transport.create(transport.default_settings(SR))
	r.graph = make_graph()
	r.streamer, _ = stream.create(stream.default_settings())
	stream.set_offline(r.streamer, true) // reads wait for the disk: renders are repeatable
	r.disk, _ = record.disk_writer_create({manual = true})
	r.env = {players = {streamer = r.streamer}, disk = r.disk}
	core.registry_init(&r.reg)
	session.register_builtin(&r.reg, &r.env)
	return r
}

rig_destroy :: proc(r: ^Rig) {
	graph.destroy(r.graph) // first: its clips and maps hold sources
	transport.destroy(r.clock)
	record.disk_writer_destroy(r.disk)
	stream.destroy(r.streamer)
	core.registry_destroy(&r.reg)
	free(r)
}

rig_session :: proc(r: ^Rig) -> session.Session {
	return {clock = r.clock, graph = r.graph}
}

// A fresh directory under the artifacts.
test_dir :: proc(name: string) -> string {
	root := kit.artifacts_root()
	dir, _ := filepath.join({root, "session", name}, context.temp_allocator)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

write_wav :: proc(path: string, frames: int, freq: f64) {
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	x := make([]f32, frames, context.temp_allocator)
	for &v, i in x do v = f32(0.4 * math.sin(math.TAU * freq * f64(i) / SR))
	chans := [][]f32{x}
	audiofile.writer_write(w, chans, frames)
	audiofile.writer_close(w)
}

// Waits until the file at `path`, which something already holds open, is
// in memory.
wait_ready :: proc(t: ^testing.T, r: ^Rig, path: string) {
	src, err := stream.source_open(r.streamer, path)
	testing.expect_value(t, err, audiofile.Error.None)
	defer stream.source_release(src)
	start := time.tick_now()
	for stream.source_state(src) == .Loading && time.tick_since(start) < 5 * time.Second do time.sleep(time.Millisecond)
	testing.expect_value(t, stream.source_state(src), stream.Source_State.Ready)
}

// Saved timeline IDs, for checks after loading.
Built :: struct {
	main, fast: core.Timeline_Id,
	gain:       graph.Node_Id,
}

// A session using every kind of saved state: two timelines (one with a
// tempo map, one at double rate looping), MIDI and automation players into a
// synth and a gain, a sampler with a zone on a file, an audio player on a
// file, a MIDI clock, and recorders.
build_session :: proc(t: ^testing.T, r: ^Rig, dir: string) -> (b: Built) {
	c := r.clock
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120, {4, 4}, context.temp_allocator)
	tb.tempo_map_set_tempo(&m, 8, 90)
	tb.tempo_map_set_meter(&m, 2, {3, 4})
	b.main, _ = transport.add_timeline(c, &m)
	b.fast, _ = transport.add_timeline(c)
	transport.set_rate(c, b.fast, 2)
	transport.set_loop(c, b.fast, 0, 4)
	transport.set_leader(c, b.main)
	transport.set_tempo(c, 100)

	audio_dir, _ := filepath.join({dir, "audio"}, context.temp_allocator)
	os.make_directory_all(audio_dir)
	sine, _ := filepath.join({audio_dir, "sine.wav"}, context.temp_allocator)
	tone, _ := filepath.join({audio_dir, "tone.wav"}, context.temp_allocator)
	write_wav(sine, 24_000, 440)
	write_wav(tone, 96_000, 220)

	g := r.graph
	// Notes into a synth.
	mb: clip.Midi_Builder
	clip.midi_builder_init(&mb, 4, context.temp_allocator)
	n := clip.add_note(&mb, 0, 1, 60, 0.8)
	clip.add_expression(&mb, n, 0.5, .Tuning, 2)
	clip.add_note(&mb, 1.5, 0.5, 67, 0.6, channel = 1)
	clip.add_controller(&mb, 2, {0xB0, 74, 90})
	clip.set_loop(&mb, 0, 4)
	notes, _ := clip.midi_build(&mb)
	mp_node, mp := clip.midi_player_create({timeline = b.main})
	mp_id := add(t, g, mp_node, 0, 0)
	clip.midi_player_set(mp, notes, {loop = true})
	clip.midi_clip_release(notes)
	synth := add(t, g, dsp.synth_create(8), 0, 2)
	graph.connect_events(g, mp_id, synth)
	b.gain = add(t, g, dsp.gain_create(), 2, 2)
	jump(t, g, b.gain, dsp.GAIN_PARAM_DB, -3)

	// Automation on the gain.
	ab: clip.Automation_Builder
	clip.automation_builder_init(&ab, 8, context.temp_allocator)
	clip.automation_add_point(&ab, dsp.GAIN_PARAM_DB, 0, -12)
	clip.automation_add_point(&ab, dsp.GAIN_PARAM_DB, 4, 0, .Curve, 0.5)
	clip.automation_add_point(&ab, dsp.GAIN_PARAM_DB, 6, -6, .Step)
	auto_clip, _ := clip.automation_build(&ab)
	ap_node, ap, _ := clip.automation_player_create({timeline = b.main})
	ap_id := add(t, g, ap_node, 0, 0)
	clip.automation_player_set(ap, auto_clip, {loop = true})
	clip.automation_clip_release(auto_clip)
	graph.connect_events(g, ap_id, b.gain)

	// A sampler on the fast timeline.
	src, _ := stream.source_open(r.streamer, sine)
	zones := []sampler.Sample_Zone{{source = src, root_key = 69, loop = true, loop_start = 1000, loop_end = 20_000, gain_db = -2, crossfade = 300, pan = 0.25}}
	smap, _ := sampler.sample_map_create(zones)
	stream.source_release(src)
	sm_node, sm := sampler.sampler_create({voices = 4, quality = .Sinc_Low})
	sm_id := add(t, g, sm_node, 0, 2)
	sampler.sampler_set_map(sm, smap)
	sampler.sample_map_release(smap)
	jump(t, g, sm_id, sampler.SAMPLER_PARAM_RELEASE, 0.05)
	sb: clip.Midi_Builder
	clip.midi_builder_init(&sb, 2, context.temp_allocator)
	clip.add_note(&sb, 0, 0.5, 72, 1)
	clip.add_note(&sb, 1, 0.75, 64, 0.5)
	fast_notes, _ := clip.midi_build(&sb)
	fp_node, fp := clip.midi_player_create({timeline = b.fast})
	fp_id := add(t, g, fp_node, 0, 0)
	clip.midi_player_set(fp, fast_notes, {loop = true})
	clip.midi_clip_release(fast_notes)
	graph.connect_events(g, fp_id, sm_id)

	// An audio clip, repitched, arranged at beat 1.
	tsrc, _ := stream.source_open(r.streamer, tone)
	ac, _ := clip.audio_clip_create(tsrc, {bpm = 100, mode = .Repitch, gain = 0.7})
	stream.source_release(tsrc)
	pl_node, pl := clip.audio_player_create(clip.default_audio_player_settings(b.main, r.streamer))
	pl_id := add(t, g, pl_node, 0, 2)
	testing.expect_value(t, clip.audio_player_set(pl, ac, {at = 1, length = 6}), core.Error.None)
	clip.audio_clip_release(ac)

	// A MIDI clock and recorders: saved by their settings.
	mc := add(t, g, transport.midi_clock_create({follow = b.main, port = 3}), 0, 0)
	graph.connect_events(g, mc, graph.OUTPUT)
	mr_node, _, _ := record.midi_recorder_create({timeline = b.main})
	mr := add(t, g, mr_node, 0, 0)
	graph.connect_events(g, graph.INPUT, mr)
	ar_node, _, _ := record.audio_recorder_create(r.disk, {timeline = b.main, channels = 2, directory = dir, name = "take"})
	ar := add(t, g, ar_node, 2, 0)

	for ch in 0 ..< 2 {
		graph.connect(g, synth, ch, b.gain, ch)
		graph.connect(g, sm_id, ch, b.gain, ch)
		graph.connect(g, pl_id, ch, graph.OUTPUT, ch)
		graph.connect(g, b.gain, ch, graph.OUTPUT, ch)
		graph.connect(g, b.gain, ch, ar, ch)
	}
	testing.expect_value(t, graph.commit(g), core.Error.None)
	// Now that the map and the clip hold the files open (waiting earlier
	// would close them again).
	wait_ready(t, r, sine)
	wait_ready(t, r, tone)
	return
}

// Plays both timelines and renders `frames` frames of the graph through the
// clock, in varying blocks; returns channel 0 and 1 interleaved by channel.
render_session :: proc(t: ^testing.T, r: ^Rig, frames: int, seed: u64) -> [2][dynamic]f32 {
	for used, i in r.clock.in_use do if used do transport.play(r.clock, {u32(i), r.clock.generations[i]})
	out: [2][dynamic]f32
	bufs: [2][MAX_BLOCK]f32
	rng := kit.Rng{state = seed}
	for done := 0; done < frames; {
		n := min(kit.rng_range(&rng, 0, MAX_BLOCK), frames - done)
		outs := [][]f32{bufs[0][:n], bufs[1][:n]}
		ctx := core.Process_Context{outputs = outs, frames = n}
		before := r.trap.violations
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				graph.process((^Rig)(user).graph, seg)
			}, r)
		}
		testing.expectf(t, r.trap.violations == before, "allocated on the audio thread at frame %d", done)
		record.disk_writer_service(r.disk)
		for ch in 0 ..< 2 do append(&out[ch], ..bufs[ch][:n])
		done += n
	}
	return out
}

// Saved to a file, moved with its audio to another directory and loaded
// into a new engine, a session renders the same, sample for sample.
@(test)
session_round_trip_through_a_moved_file :: proc(t: ^testing.T) {
	dir_a := test_dir("round_trip_a")
	dir_b := test_dir("round_trip_b")
	FRAMES :: 96_000

	a := rig_make()
	built := build_session(t, a, dir_a)
	path_a, _ := filepath.join({dir_a, "song.fire"}, context.temp_allocator)
	extra := []session.App_Chunk{{tag = {'T', 'R', 'K', 'S'}, version = 2, data = transmute([]u8)string("tracks")}}
	testing.expect_value(t, session.save(rig_session(a), path_a, extra), core.Error.None)
	want := render_session(t, a, FRAMES, 11)
	defer for ch in want do delete(ch)
	rig_destroy(a)

	// Move the session: its file and its audio folder.
	audio_b, _ := filepath.join({dir_b, "audio"}, context.temp_allocator)
	os.make_directory_all(audio_b)
	for name in ([]string{"sine.wav", "tone.wav"}) {
		from, _ := filepath.join({dir_a, "audio", name}, context.temp_allocator)
		to, _ := filepath.join({audio_b, name}, context.temp_allocator)
		data, _ := os.read_entire_file(from, context.temp_allocator)
		_ = os.write_entire_file(to, data)
		os.remove(from) // only the moved copy exists now
	}
	path_b, _ := filepath.join({dir_b, "song.fire"}, context.temp_allocator)
	data, _ := os.read_entire_file(path_a, context.temp_allocator)
	_ = os.write_entire_file(path_b, data)

	b := rig_make()
	defer rig_destroy(b)
	loaded, err := session.load(rig_session(b), path_b, &b.reg)
	defer session.loaded_destroy(&loaded)
	testing.expect_value(t, err, core.Error.None)
	testing.expect_value(t, len(loaded.nodes.missing), 0)
	testing.expect_value(t, len(loaded.timelines), 2)
	for m in loaded.nodes.missing do testing.expectf(t, false, "%s did not load: %v", m.type_id, m.err)
	if x, ok := session.find_extra(loaded, {'T', 'R', 'K', 'S'}); testing.expect(t, ok) {
		testing.expect_value(t, x.version, 2)
		testing.expect_value(t, string(x.data), "tracks")
	}
	_, ok := session.timeline(loaded, built.main)
	testing.expect(t, ok)
	_, ok = session.node(loaded, built.gain.index)
	testing.expect(t, ok)
	sine_b, _ := filepath.join({audio_b, "sine.wav"}, context.temp_allocator)
	tone_b, _ := filepath.join({audio_b, "tone.wav"}, context.temp_allocator)
	wait_ready(t, b, sine_b)
	wait_ready(t, b, tone_b)

	// The same blocks as the original: the comparison is exact, and tests
	// the save, not each node's block-size invariance (tested elsewhere).
	got := render_session(t, b, FRAMES, 11)
	defer for ch in got do delete(ch)
	for ch in 0 ..< 2 {
		cmp := kit.compare_slices(want[ch][:], got[ch][:])
		testing.expectf(t, cmp.max_abs_error == 0 && !cmp.frame_mismatch, "channel %d differs by up to %v at frame %d", ch, cmp.max_abs_error, cmp.max_error_at)
	}
	testing.expect(t, kit.rms(want[0][:]) > 0.01) // it made sound
}

// A failed load leaves the session as it was; a good one replaces it.
@(test)
load_replaces_or_leaves_alone :: proc(t: ^testing.T) {
	dir := test_dir("replace")
	r := rig_make()
	defer rig_destroy(r)
	build_session(t, r, dir)
	s := rig_session(r)
	data, err := session.save_bytes(s, dir, allocator = context.temp_allocator)
	testing.expect_value(t, err, core.Error.None)
	nodes_before := len(graph.nodes(r.graph, context.temp_allocator))

	// Truncated: nothing changes.
	for cut in ([]int{len(data) - 1, len(data) / 2, 20}) {
		l, e := session.load_bytes(s, data[:cut], &r.reg, dir)
		testing.expectf(t, e == .Invalid_Data, "cut at %d: %v", cut, e)
		session.loaded_destroy(&l)
		testing.expect_value(t, len(graph.nodes(r.graph, context.temp_allocator)), nodes_before)
	}
	// Not a session, and from a newer engine.
	_, e := session.load_bytes(s, {1, 2, 3}, &r.reg)
	testing.expect_value(t, e, core.Error.Invalid_Data)
	newer := make([]u8, len(data), context.temp_allocator)
	copy(newer, data)
	newer[4] = session.FORMAT_VERSION + 1
	_, e = session.load_bytes(s, newer, &r.reg)
	testing.expect_value(t, e, core.Error.Unsupported)

	// A good load into the same, running session: the old nodes and
	// timelines go, the new ones arrive, and the audio thread never allocates.
	before := render_session(t, r, 4096, 1)
	for ch in before do delete(ch)
	l, e2 := session.load_bytes(s, data, &r.reg, dir)
	defer session.loaded_destroy(&l)
	testing.expect_value(t, e2, core.Error.None)
	out := render_session(t, r, 4096, 2)
	defer for ch in out do delete(ch)
	testing.expect_value(t, len(graph.nodes(r.graph, context.temp_allocator)), nodes_before)
	lines := 0
	for used in r.clock.in_use do if used do lines += 1
	testing.expect_value(t, lines, 2)
	testing.expect_value(t, session.clear(s), core.Error.None)
	testing.expect_value(t, len(graph.nodes(r.graph, context.temp_allocator)), 0)
}
