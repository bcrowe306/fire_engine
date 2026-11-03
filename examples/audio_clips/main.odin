/*
An audio loop recorded at 100 BPM and 44.1 kHz, launched on the next bar of
a 120 BPM session on a 48 kHz device: converted, repitched to the tempo, and
looped seamlessly. Renders four bars offline through a graph and saves the
result as a WAV file.

	odin run examples/audio_clips -collection:fire=f_engine
*/
package audio_clips

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:time"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:graph"
import "fire:stream"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_audio_clips", context.allocator)
	defer os.remove_all(dir)
	loop_path, _ := filepath.join({dir, "loop_100bpm.wav"}, context.allocator)
	bounce_path, _ := filepath.join({dir, "bounce_120bpm.wav"}, context.allocator)
	defer delete(loop_path)
	defer delete(bounce_path)
	write_loop(loop_path)

	// 1. Disk streaming, and the loop as a source (short: it loads into memory).
	streamer, _ := stream.create(stream.default_settings())
	defer stream.destroy(streamer)
	src, err := stream.source_open(streamer, loop_path)
	if err != .None {
		fmt.eprintln("source_open:", err)
		return
	}
	defer stream.source_release(src)

	// 2. The clip: one bar at 100 BPM, repitched to follow the session tempo.
	loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = .Repitch})
	defer clip.audio_clip_release(loop)
	fmt.printf("clip: %.0f beats at %.0f BPM, %.0f Hz\n", f64(clip.audio_clip_beats(loop)), loop.bpm, loop.sample_rate)

	// 3. A 120 BPM clock with a launcher timeline, and a graph with the player.
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	defer transport.destroy(clock)
	slot, _ := transport.add_timeline(clock)
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.workers = 0, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)
	node, player := clip.audio_player_create(clip.default_audio_player_settings(slot, streamer))
	id, _ := graph.add_node(g, node, 0, 2)
	graph.connect(g, id, 0, graph.OUTPUT, 0)
	graph.connect(g, id, 1, graph.OUTPUT, 1)
	graph.commit(g)
	clip.audio_player_set(player, loop, {loop = true})
	for !clip.audio_player_ready(player) do time.sleep(time.Millisecond) // preroll before launching

	// 4. Launch on the next bar, render four bars, bounce to WAV.
	transport.play(clock, slot, tb.Quantize.Bar)
	w, _ := audiofile.writer_create(bounce_path, audiofile.default_writer_settings(SAMPLE_RATE, 2))
	left, right: [BLOCK]f32
	frames := int(16 * 60 / 120.0 * SAMPLE_RATE)
	peak: f32
	for at := 0; at < frames; at += BLOCK {
		ctx := core.Process_Context{outputs = {left[:], right[:]}, frames = BLOCK}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		for s in left do peak = max(peak, abs(s))
		audiofile.writer_write(w, {left[:], right[:]}, BLOCK)
	}
	audiofile.writer_close(w)
	fmt.printf("bounced %d frames (four bars at 120 BPM), peak %.2f, underruns %d\n", frames, peak, stream.stats(streamer).underrun_frames)
}

// One bar at 100 BPM, 44.1 kHz: a decaying "kick" on each beat.
write_loop :: proc(path: string) {
	frames := int(4 * 60 / 100.0 * 44_100)
	mono := make([]f32, frames)
	defer delete(mono)
	beat := frames / 4
	for i in 0 ..< frames {
		t := f64(i % beat) / 44_100
		mono[i] = f32(0.8 * math.exp(-t * 18) * math.sin(math.TAU * 55 * t * (1 + 2 * math.exp(-t * 40))))
	}
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(44_100, 1))
	audiofile.writer_write(w, {mono}, frames)
	audiofile.writer_close(w)
}
