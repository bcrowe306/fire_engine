/*
Saving and reopening a session: a synth playing a looped clip through an
EQ, with its tempo and parameter settings, is saved to a file with a chunk
of the app's own (track names), loaded into a new clock and graph, and
rendered again. The program prints what it loaded and whether both
renders match.

	odin run examples/session -collection:fire=f_engine
*/
package session_example

import "core:fmt"
import "core:os"
import "core:path/filepath"

import "fire:clip"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:session"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 256
FRAMES :: 192 * BLOCK

// The app's own chunk: here, just the track names, one per line.
TRACKS_TAG :: core.Tag{'T', 'R', 'K', 'S'}

Engine :: struct {
	clock: ^transport.Clock,
	graph: ^graph.Graph,
}

engine_make :: proc() -> Engine {
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.workers = 0, 0
	g, _ := graph.create(settings)
	return {clock, g}
}

engine_destroy :: proc(e: Engine) {
	graph.destroy(e.graph)
	transport.destroy(e.clock)
}

main :: proc() {
	// 1. A song: a timeline at 96 BPM and a looped clip into a synth and an EQ.
	a := engine_make()
	song, _ := transport.add_timeline(a.clock)
	transport.set_leader(a.clock, song)
	transport.set_tempo(a.clock, 96)
	build_song(a.graph, song)

	// 2. Save it with the app's chunk next to it.
	dir, _ := os.make_directory_temp("", "fire_session", context.allocator)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "song.fire"}, context.allocator)
	defer delete(path)
	tracks := "Synth\n"
	if err := session.save({a.clock, a.graph}, path, {{TRACKS_TAG, 1, transmute([]u8)tracks}}); err != .None {
		fmt.eprintln("save:", err)
		return
	}
	want := render(a, song)
	defer delete(want)
	engine_destroy(a)

	// 3. A new engine: register the node types the file may name, and load.
	b := engine_make()
	defer engine_destroy(b)
	reg: core.Node_Registry
	core.registry_init(&reg)
	defer core.registry_destroy(&reg)
	env: session.Environment // no streamer: this song has no audio files
	session.register_builtin(&reg, &env)
	loaded, err := session.load({b.clock, b.graph}, path, &reg)
	if err != .None {
		fmt.eprintln("load:", err)
		return
	}
	defer session.loaded_destroy(&loaded)
	info, _ := os.stat(path, context.allocator)
	defer os.file_info_delete(info, context.allocator)
	fmt.printf("loaded %d bytes: %d nodes, %d timeline(s), %d placeholder(s)\n",
		info.size, len(loaded.nodes.nodes), len(loaded.timelines), len(loaded.nodes.missing))
	if x, ok := session.find_extra(loaded, TRACKS_TAG); ok do fmt.printf("app chunk: tracks %q\n", string(x.data))

	// 4. It sounds the same. IDs change on loading: look them up.
	song_now, _ := session.timeline(loaded, song)
	got := render(b, song_now)
	defer delete(got)
	worst: f32
	for x, i in want do worst = max(worst, abs(x - got[i]))
	fmt.printf("rendered %d frames twice: largest difference %v\n", FRAMES, worst)
	if worst != 0 do os.exit(1)
}

build_song :: proc(g: ^graph.Graph, song: core.Timeline_Id) {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	defer clip.midi_builder_destroy(&b)
	for key, i in ([]u8{57, 60, 64, 67}) do clip.add_note(&b, tb.Beats(i), 0.75, key, 0.8)
	notes, _ := clip.midi_build(&b)
	defer clip.midi_clip_release(notes)

	player_node, player := clip.midi_player_create({timeline = song})
	clip.midi_player_set(player, notes, {loop = true})
	p, _ := graph.add_node(g, player_node, 0, 0)
	synth, _ := graph.add_node(g, dsp.synth_create(8), 0, 2)
	eq, _ := graph.add_node(g, dsp.eq_create(3), 2, 2)
	graph.set_param_ramp(g, synth, dsp.SYNTH_PARAM_CUTOFF_HZ, 1800, 0) // ramps of 0 frames: jumps,
	graph.set_param_ramp(g, eq, dsp.eq_band_param(1, .Gain_Db), 6, 0)  // so both renders start alike
	graph.connect_events(g, p, synth)
	for c in 0 ..< 2 {
		graph.connect(g, synth, c, eq, c)
		graph.connect(g, eq, c, graph.OUTPUT, c)
	}
	graph.commit(g)
}

// Plays `song` and renders FRAMES frames; channel 0.
render :: proc(e: Engine, song: core.Timeline_Id) -> []f32 {
	transport.play(e.clock, song)
	out := make([]f32, FRAMES)
	right: [BLOCK]f32
	for at := 0; at < FRAMES; at += BLOCK {
		outs := [][]f32{out[at:][:BLOCK], right[:]}
		ctx := core.Process_Context{outputs = outs, frames = BLOCK}
		transport.process(e.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, e.graph)
	}
	return out
}
