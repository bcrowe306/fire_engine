/*
The same drum loop (recorded at 100 BPM) played into a session that speeds
up from 90 to 140 BPM, twice: repitched (pitch rises with tempo) and
time-stretched (pitch stays). Prints the strongest frequency of a held tone
in each, early and late.

Needs the Signalsmith Stretch library: run ./scripts/stretch.sh first.

	odin run examples/stretched_loop -collection:fire=f_engine
*/
package stretched_loop

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:time"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:stream"
import "fire:stretch"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_stretched_loop", context.allocator)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "tone_100bpm.wav"}, context.allocator)
	defer delete(path)
	write_tone(path) // a held 440 Hz tone, one bar at 100 BPM

	streamer, _ := stream.create(stream.default_settings())
	defer stream.destroy(streamer)
	src, _ := stream.source_open(streamer, path)
	defer stream.source_release(src)

	for mode in ([]clip.Audio_Mode{.Repitch, .Stretch}) {
		// A clock whose tempo ramps from 90 to 140 BPM over eight bars.
		clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
		tl, _ := transport.add_timeline(clock)
		m: tb.Tempo_Map
		tb.tempo_map_init(&m, 90)
		tb.tempo_map_set_tempo(&m, 0, 90, ramp_to = 140)
		tb.tempo_map_set_tempo(&m, 32, 140)
		transport.set_tempo_map(clock, tl, &m)
		transport.set_leader(clock, tl)

		// The player; Stretch needs a stretcher (from fire:stretch).
		settings := clip.default_audio_player_settings(tl, streamer)
		settings.channels = 1
		settings.stretcher = &stretch.signalsmith
		node, player := clip.audio_player_create(settings)
		core.node_prepare(&node, {sample_rate = SAMPLE_RATE, max_block = 512, out_channels = 1})
		loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = mode})
		clip.audio_player_set(player, loop, {loop = true})
		for !clip.audio_player_ready(player) do time.sleep(time.Millisecond)

		transport.play(clock, tl)
		out := make([]f32, int(SAMPLE_RATE * 16))
		for at := 0; at < len(out); at += 512 {
			ctx := core.Process_Context{outputs = {out[at:at + 512]}, frames = 512}
			transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process((^core.Node)(user), seg)
			}, &node)
		}
		early := strongest_hz(out[int(SAMPLE_RATE * 1):][:8192])
		late := strongest_hz(out[int(SAMPLE_RATE * 14):][:8192])
		fmt.printf("%-8v at %3.0f BPM: %4.0f Hz   at %3.0f BPM: %4.0f Hz\n", mode,
			tb.tempo_at(&m, tb.samples_to_beats(&m, tb.Sample_Time(SAMPLE_RATE * 1), SAMPLE_RATE)), early,
			tb.tempo_at(&m, tb.samples_to_beats(&m, tb.Sample_Time(SAMPLE_RATE * 14), SAMPLE_RATE)), late)

		delete(out)
		clip.audio_clip_release(loop)
		core.node_destroy(&node)
		tb.tempo_map_destroy(&m)
		transport.destroy(clock)
	}
}

write_tone :: proc(path: string) {
	frames := int(4 * 60 / 100.0 * SAMPLE_RATE)
	x := make([]f32, frames)
	defer delete(x)
	for &s, i in x do s = f32(0.5 * math.sin(math.TAU * 440 * f64(i) / SAMPLE_RATE))
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SAMPLE_RATE, 1))
	audiofile.writer_write(w, {x}, frames)
	audiofile.writer_close(w)
}

// The frequency (Hz) whose DFT bin is loudest, searched in 1 Hz steps.
strongest_hz :: proc(x: []f32) -> f64 {
	best, best_hz := 0.0, 0.0
	for hz := 200.0; hz <= 1000; hz += 1 {
		re, im: f64
		for s, i in x {
			w := math.TAU * hz * f64(i) / SAMPLE_RATE
			re += f64(s) * math.cos(w)
			im += f64(s) * math.sin(w)
		}
		if p := re * re + im * im; p > best do best, best_hz = p, hz
	}
	return best_hz
}
