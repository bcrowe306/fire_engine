package test_stretch_port

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:stream"
import "fire:stretch"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

SR :: 48_000.0

// Writes (once) a float WAV: a 440 Hz sine, or a 5 ms 2 kHz click at the
// start of every beat at 120 BPM (every 24 000 frames).
source_file :: proc(name: string, frames: int, clicks: bool) -> string {
	@(static) mutex: sync.Mutex
	sync.guard(&mutex)
	dir := os.get_env("FIRE_ARTIFACTS_DIR", context.temp_allocator)
	if dir == "" do dir = "."
	_ = os.make_directory_all(dir)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if os.exists(path) do return path
	x := make([]f32, frames, context.temp_allocator)
	for &s, i in x {
		if clicks {
			k := i % 24_000
			s = f32(0.8 * math.sin(math.TAU * 2000 * f64(k) / SR)) if k < 240 else 0
		} else {
			s = f32(0.5 * math.sin(math.TAU * 440 * f64(i) / SR))
		}
	}
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, frames)
	audiofile.writer_close(w)
	return path
}

Rig :: struct {
	clock:    ^transport.Clock,
	tl:       core.Timeline_Id,
	streamer: ^stream.Streamer,
	source:   ^stream.Source,
	node:     core.Node,
	player:   ^clip.Audio_Player,
	clip:     ^clip.Audio_Clip,
	out:      [dynamic]f32,
	trap:     kit.Trap_Allocator,
}

rig_make :: proc(t: ^testing.T, path: string, bpm: f64, placement := clip.Placement{}, transpose := 0.0) -> ^Rig {
	r := new(Rig)
	cs := transport.default_settings(SR)
	cs.bpm = bpm
	r.clock, _ = transport.create(cs)
	r.tl, _ = transport.add_timeline(r.clock)
	r.streamer, _ = stream.create(stream.default_settings())
	r.source, _ = stream.source_open(r.streamer, path)
	s := clip.default_audio_player_settings(r.tl, r.streamer)
	s.channels = 1
	s.stretcher = &stretch.signalsmith
	r.node, r.player = clip.audio_player_create(s)
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 4096, out_channels = 1})
	r.clip, _ = clip.audio_clip_create(r.source, {bpm = 120, mode = .Stretch, transpose = transpose, fade_in = -1, fade_out = -1})
	testing.expect_value(t, clip.audio_player_set(r.player, r.clip, placement), core.Error.None)
	start := time.tick_now()
	for !clip.audio_player_ready(r.player) && time.tick_since(start) < 5 * time.Second do time.sleep(time.Millisecond)
	return r
}

rig_destroy :: proc(r: ^Rig) {
	core.node_destroy(&r.node)
	clip.audio_clip_release(r.clip)
	stream.source_release(r.source)
	stream.destroy(r.streamer)
	transport.destroy(r.clock)
	delete(r.out)
	free(r)
}

rig_run :: proc(r: ^Rig, total: int, block := 512) {
	buf: [4096]f32
	for done := 0; done < total; done += block {
		n := min(block, total - done)
		ctx := core.Process_Context{outputs = {buf[:n]}, frames = n}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Rig)(user).node, seg)
			}, r)
		}
		append(&r.out, ..buf[:n])
	}
}

// Frames where clicks begin: the first frame whose 1 ms energy passes half
// the loudest's, after a quiet stretch.
onsets :: proc(x: []f32) -> [dynamic]int {
	energy := make([]f32, len(x), context.temp_allocator)
	sum: f32
	for s, i in x {
		sum += s * s
		if i >= 48 do sum -= x[i - 48] * x[i - 48]
		energy[i] = sum
	}
	top: f32
	for e in energy do top = max(top, e)
	out := make([dynamic]int, context.temp_allocator)
	quiet := 0
	for e, i in energy {
		if e > top / 2 {
			if quiet > 4800 do append(&out, i - 48)
			quiet = 0
		} else {
			quiet += 1
		}
	}
	return out
}

// Played slower and faster than recorded, a 440 Hz tone stays at 440 Hz.
@(test)
pitch_is_kept :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := source_file("sine.wav", 48_000 * 20, false)
	for bpm in ([]f64{90, 150}) {
		r := rig_make(t, path, bpm)
		transport.play(r.clock, r.tl)
		rig_run(r, 48_000 * 3)
		steady := r.out[48_000:48_000 + 65_536]
		spec := kit.spectrum(steady, SR)
		_, hz, _ := kit.spectrum_peak(spec)
		kit.spectrum_destroy(&spec)
		testing.expectf(t, abs(hz - 440) < 2, "%v BPM: peak at %.1f Hz", bpm, hz)
		amp := kit.tone_amplitude(steady, SR, 440)
		testing.expectf(t, abs(kit.linear_to_db(amp / 0.5)) < 1.5, "%v BPM: 440 Hz at %.2f dB", bpm, kit.linear_to_db(amp / 0.5))
		n, _ := kit.count_non_finite(r.out[:])
		testing.expect_value(t, n, 0)
		testing.expect_value(t, r.trap.violations, 0)
		rig_destroy(r)
	}
}

// A transposed clip moves pitch, not timing: +7 semitones at 90 BPM puts
// the 440 Hz tone at 659 Hz.
@(test)
transpose_moves_pitch :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := source_file("sine.wav", 48_000 * 20, false)
	r := rig_make(t, path, 90, transpose = 7)
	defer rig_destroy(r)
	transport.play(r.clock, r.tl)
	rig_run(r, 48_000 * 3)
	spec := kit.spectrum(r.out[48_000:48_000 + 65_536], SR)
	_, hz, _ := kit.spectrum_peak(spec)
	kit.spectrum_destroy(&spec)
	want := 440 * math.pow(2, 7.0 / 12)
	testing.expectf(t, abs(hz - want) < 3, "peak at %.1f Hz, not %.1f", hz, want)
	testing.expect_value(t, r.trap.violations, 0)
}

// Clicks recorded on each beat at 120 BPM land on the timeline's beats at
// 100 BPM, and after a change to 80 BPM, without drifting.
@(test)
stretched_audio_stays_on_the_beat :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := source_file("clicks.wav", 48_000 * 30, true)
	r := rig_make(t, path, 100)
	defer rig_destroy(r)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 100)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 12, 80)
	transport.set_tempo_map(r.clock, r.tl, &m)
	transport.set_leader(r.clock, r.tl)
	transport.play(r.clock, r.tl)
	rig_run(r, 48_000 * 14, 333)

	got := onsets(r.out[:])
	testing.expectf(t, len(got) >= 18, "only %d clicks", len(got))
	worst, first, last := 0, 0, 0
	for o, k in got {
		beat := math.round(f64(tb.samples_to_beats(&m, tb.Sample_Time(o), SR)))
		want := int(tb.beats_to_samples(&m, tb.Beats(beat), SR))
		err := o - want
		if k == 0 do first = err
		last = err
		worst = max(worst, abs(err))
	}
	log.infof("%d clicks; worst %d frames (%.2f ms) off the beat; first %d, last %d", len(got), worst, f64(worst) / 48, first, last)
	// A phase vocoder smears a click over a few milliseconds; what matters is
	// that clicks stay on the beat and the error doesn't grow.
	testing.expectf(t, worst < 240, "a click is %d frames (%.1f ms) off its beat", worst, f64(worst) / 48)
	testing.expectf(t, abs(last - first) < 96, "drift: first click %d frames off, last %d", first, last)
}

// A looping stretched clip keeps every repetition on the beat.
@(test)
stretched_loops_stay_on_the_beat :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := source_file("clicks.wav", 48_000 * 30, true)
	r := rig_make(t, path, 135, {loop = true})
	defer rig_destroy(r)
	clip.audio_clip_release(r.clip)
	r.clip, _ = clip.audio_clip_create(r.source, {bpm = 120, mode = .Stretch, loop_start = 0, loop_end = 96_000, fade_in = -1, fade_out = -1}) // one bar
	clip.audio_player_set(r.player, r.clip, {loop = true})
	for !clip.audio_player_ready(r.player) do time.sleep(time.Millisecond)
	transport.play(r.clock, r.tl)
	rig_run(r, 48_000 * 10)
	got := onsets(r.out[:])
	frames_per_beat := SR * 60 / 135
	worst := 0.0
	for o in got do worst = max(worst, abs(f64(o) - math.round(f64(o) / frames_per_beat) * frames_per_beat))
	log.infof("loop: %d clicks; worst %.0f frames off the beat", len(got), worst)
	testing.expectf(t, len(got) >= 20, "only %d clicks", len(got))
	testing.expectf(t, worst < 240, "a click is %.0f frames off its beat", worst)
}

@(test)
stretch_needs_a_stretcher :: proc(t: ^testing.T) {
	path := source_file("sine.wav", 48_000 * 20, false)
	ss, _ := stream.create(stream.default_settings())
	defer stream.destroy(ss)
	src, _ := stream.source_open(ss, path)
	defer stream.source_release(src)
	c, _ := clip.audio_clip_create(src, {bpm = 120, mode = .Stretch})
	defer clip.audio_clip_release(c)
	tl := core.Timeline_Id{0, 1}

	node, player := clip.audio_player_create(clip.default_audio_player_settings(tl, ss))
	defer core.node_destroy(&node)
	core.node_prepare(&node, {sample_rate = SR, max_block = 512, out_channels = 2})
	testing.expect_value(t, clip.audio_player_set(player, c, {}), core.Error.Unsupported)

	s := clip.default_audio_player_settings(tl, ss)
	s.stretcher = &stretch.signalsmith
	node2, player2 := clip.audio_player_create(s)
	defer core.node_destroy(&node2)
	testing.expect_value(t, clip.audio_player_set(player2, c, {}), core.Error.Invalid_State) // not prepared yet
}
