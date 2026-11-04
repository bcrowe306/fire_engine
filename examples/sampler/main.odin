/*
A sampler instrument from generated samples: a drum kit (one-shots on
their own keys) and a pluck played across the keyboard, with a soft and a
hard velocity layer. A MIDI clip plays a bar of drums and a bass line
through it; the program renders it offline and writes a WAV file.

	odin run examples/sampler -collection:fire=f_engine
*/
package sampler_example

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:time"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:graph"
import "fire:sampler"
import "fire:stream"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_sampler", context.allocator)
	defer os.remove_all(dir)

	// 1. Samples: files on disk, opened as sources (small: held in memory).
	streamer, _ := stream.create(stream.default_settings())
	defer stream.destroy(streamer)
	kick := open(streamer, dir, "kick.wav", proc(t: f64) -> f64 { return math.exp(-t * 18) * math.sin(math.TAU * 50 * t * (1 + 3 * math.exp(-t * 40))) }, 0.5)
	snare := open(streamer, dir, "snare.wav", proc(t: f64) -> f64 { return math.exp(-t * 25) * (0.6 * noise() + 0.4 * math.sin(math.TAU * 190 * t)) }, 0.4)
	hat := open(streamer, dir, "hat.wav", proc(t: f64) -> f64 { return 0.5 * math.exp(-t * 70) * noise() }, 0.15)
	soft := open(streamer, dir, "pluck_soft.wav", proc(t: f64) -> f64 { return math.exp(-t * 4) * math.sin(math.TAU * 130.81 * t) }, 2) // C3
	hard := open(streamer, dir, "pluck_hard.wav", proc(t: f64) -> f64 { return math.exp(-t * 4) * (math.sin(math.TAU * 130.81 * t) + 0.4 * math.sin(math.TAU * 3 * 130.81 * t)) }, 2)
	defer for s in ([]^stream.Source{kick, snare, hat, soft, hard}) do stream.source_release(s)

	// 2. The instrument: one-shot drums on C1, D1 and F#1 (General MIDI's
	//    kick, snare and hat), the pluck from C2 up, its hard layer above
	//    velocity 0.7.
	instrument, err := sampler.sample_map_create({
		{source = kick, root_key = 36, key_lo = 36, key_hi = 36, one_shot = true},
		{source = snare, root_key = 38, key_lo = 38, key_hi = 38, one_shot = true},
		{source = hat, root_key = 42, key_lo = 42, key_hi = 42, one_shot = true, gain_db = -4},
		{source = soft, root_key = 48, key_lo = 48, vel_hi = 0.7},
		{source = hard, root_key = 48, key_lo = 48, vel_lo = 0.7001},
	})
	if err != .None {
		fmt.eprintln("sample_map_create:", err)
		return
	}

	// 3. A clock, a graph: a MIDI clip player into the sampler, stereo out.
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	defer transport.destroy(clock)
	song, _ := transport.add_timeline(clock)
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.workers = 0, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)
	snode, s := sampler.sampler_create({voices = 16})
	sid, _ := graph.add_node(g, snode, 0, 2)
	graph.connect(g, sid, 0, graph.OUTPUT, 0)
	graph.connect(g, sid, 1, graph.OUTPUT, 1)
	sampler.sampler_set_map(s, instrument)
	sampler.sample_map_release(instrument) // the sampler keeps its own reference
	pnode, player := clip.midi_player_create({timeline = song})
	pid, _ := graph.add_node(g, pnode, 0, 0)
	graph.connect_events(g, pid, sid)
	graph.commit(g)

	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	for i in 0 ..< 8 do clip.add_note(&b, tb.Beats(f64(i) * 0.5), 0.1, 42, 0.6 if i % 2 == 0 else 0.4) // hats
	for at in ([]tb.Beats{0, 1.5, 2.5}) do clip.add_note(&b, at, 0.1, 36, 1)                     // kick
	for at in ([]tb.Beats{1, 3}) do clip.add_note(&b, at, 0.1, 38, 0.9)                          // snare
	for n, i in ([]u8{48, 48, 55, 51}) do clip.add_note(&b, tb.Beats(i), 0.9, n, 0.5 if i % 2 == 0 else 0.95) // bass, soft and hard
	beat, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	clip.midi_player_set(player, beat, {loop = true})
	clip.midi_clip_release(beat)

	// 4. Two bars, to a WAV file.
	path, _ := filepath.join({dir, "beat.wav"}, context.allocator)
	defer delete(path)
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SAMPLE_RATE, 2))
	transport.play(clock, song)
	left, right: [BLOCK]f32
	peak := f32(0)
	frames := int(8 * 60 / 120.0 * SAMPLE_RATE)
	for at := 0; at < frames; at += BLOCK {
		ctx := core.Process_Context{outputs = {left[:], right[:]}, frames = BLOCK}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		for x in left do peak = max(peak, abs(x))
		audiofile.writer_write(w, {left[:], right[:]}, BLOCK)
	}
	audiofile.writer_close(w)
	fmt.printf("rendered two bars through a 5-zone sampler, peak %.2f\n", peak)
}

// Writes `seconds` of `f` (t in seconds) at 48 kHz, and opens it.
open :: proc(streamer: ^stream.Streamer, dir, name: string, f: proc(t: f64) -> f64, seconds: f64) -> ^stream.Source {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	n := int(seconds * SAMPLE_RATE)
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x do v = f32(0.8 * f(f64(i) / SAMPLE_RATE))
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SAMPLE_RATE, 1))
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	src, _ := stream.source_open(streamer, path)
	for stream.source_state(src) == .Loading do time.sleep(time.Millisecond) // decoding into memory
	return src
}

noise_seed: u32 = 1

noise :: proc() -> f64 {
	noise_seed = noise_seed * 1664525 + 1013904223
	return f64(noise_seed >> 8) / f64(1 << 23) - 1
}
