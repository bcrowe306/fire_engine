package test_clip

import "core:fmt"
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
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

// Source frame i holds (i + 1) / 2^20 (a ramp), so the output's value says
// which source position is playing.
RAMP_SCALE :: f64(1 << 20)

// Writes (once) a float WAV at `rate` of `frames` frames: a ramp, or a 440
// Hz sine when `sine` is set. Returns its path.
source_file :: proc(name: string, rate: f64, frames: int, sine := false, channels := 1) -> string {
	@(static) mutex: sync.Mutex
	sync.guard(&mutex)
	dir := os.get_env("FIRE_ARTIFACTS_DIR", context.temp_allocator)
	if dir == "" do dir = "."
	sub, _ := filepath.join({dir, "audio_clips"}, context.temp_allocator)
	_ = os.make_directory_all(sub)
	path, _ := filepath.join({sub, name}, context.temp_allocator)
	if os.exists(path) do return path
	s := audiofile.default_writer_settings(rate, channels)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	chans := make([][]f32, channels, context.temp_allocator)
	for &c in chans do c = make([]f32, frames, context.temp_allocator)
	for i in 0 ..< frames {
		v := f32(0.5 * math.sin(math.TAU * 440 * f64(i) / rate)) if sine else f32(f64(i + 1) / RAMP_SCALE)
		for c, k in chans do c[i] = v * (1 if k == 0 else 0.5)
	}
	audiofile.writer_write(w, chans, frames)
	audiofile.writer_close(w)
	return path
}

Audio_Rig :: struct {
	clock:    ^transport.Clock,
	tl:       core.Timeline_Id,
	streamer: ^stream.Streamer,
	source:   ^stream.Source,
	node:     core.Node,
	player:   ^clip.Audio_Player,
	out:      [dynamic]f32, // channel 0, every frame rendered
	out2:     [dynamic]f32, // channel 1
	trap:     kit.Trap_Allocator,
}

audio_rig :: proc(path: string, bpm := 120.0, out_channels := 2, in_memory := true) -> ^Audio_Rig {
	r := new(Audio_Rig)
	cs := transport.default_settings(48_000)
	cs.bpm = bpm
	r.clock, _ = transport.create(cs)
	r.tl, _ = transport.add_timeline(r.clock)
	ss := stream.default_settings()
	if !in_memory do ss.ram_bytes = 0
	r.streamer, _ = stream.create(ss)
	r.source, _ = stream.source_open(r.streamer, path)
	s := clip.default_audio_player_settings(r.tl, r.streamer)
	s.channels = out_channels
	// The ramp's value is its position, so the resampler's gain ripple
	// (about 1e-5 at Medium) shows up as position error growing with the
	// position; High's (about 1e-6) keeps the probe below 0.2 frames.
	s.quality = .High
	r.node, r.player = clip.audio_player_create(s)
	core.node_prepare(&r.node, {sample_rate = 48_000, max_block = 4096, out_channels = out_channels})
	return r
}

audio_rig_destroy :: proc(r: ^Audio_Rig) {
	core.node_destroy(&r.node)
	stream.source_release(r.source)
	stream.destroy(r.streamer)
	transport.destroy(r.clock)
	delete(r.out)
	delete(r.out2)
	free(r)
}

// Waits until the player's clip is buffered.
audio_wait :: proc(t: ^testing.T, r: ^Audio_Rig) {
	start := time.tick_now()
	for !clip.audio_player_ready(r.player) {
		if time.tick_since(start) > 5 * time.Second {
			testing.expect(t, false, "audio clip never became ready")
			return
		}
		time.sleep(time.Millisecond)
	}
}

// Renders `total` frames; with `pace` > 0, no faster than `pace` × real
// time (a streamed source can only be read so fast; a real device paces
// itself).
audio_run :: proc(r: ^Audio_Rig, total: int, blocks: []int = {512}, pace := 0.0) {
	bufs: [2][4096]f32
	for done, k := 0, 0; done < total; k += 1 {
		n := min(blocks[k % len(blocks)], total - done)
		outs := [][]f32{bufs[0][:n], bufs[1][:n]}[:r.node.config.out_channels]
		ctx := core.Process_Context{outputs = outs, frames = n}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Audio_Rig)(user).node, seg)
			}, r)
		}
		append(&r.out, ..bufs[0][:n])
		if len(outs) > 1 do append(&r.out2, ..bufs[1][:n])
		done += n
		if pace > 0 do time.sleep(time.Duration(f64(n) / 48_000 / pace * 1e9))
	}
}

ramp_clip :: proc(r: ^Audio_Rig, settings: clip.Audio_Clip_Settings) -> ^clip.Audio_Clip {
	s := settings
	if s.fade_in == 0 do s.fade_in = -1 // fades would scale the ramp
	if s.fade_out == 0 do s.fade_out = -1
	c, err := clip.audio_clip_create(r.source, s)
	assert(err == .None)
	return c
}

// Checks out[from:to] against `expected(frame)` (a source position);
// returns the worst error in frames.
worst_position_error :: proc(out: []f32, from, to: int, expected: proc(frame: int, user: rawptr) -> f64, user: rawptr) -> (worst: f64, at: int) {
	for i in from ..< min(to, len(out)) {
		got := f64(out[i]) * RAMP_SCALE - 1
		if e := abs(got - expected(i, user)); e > worst do worst, at = e, i
	}
	return
}

// Repitched to a tempo map with a step and a ramp, the clip stays locked to
// the timeline: every frame plays the source position its beat calls for.
@(test)
repitch_follows_tempo_changes :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := source_file("ramp_48k.wav", 48_000, 48_000 * 30)
	r := audio_rig(path, 120)
	defer audio_rig_destroy(r)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 8, 90, 150) // step to 90 at beat 8, ramping to 150 at beat 16
	tb.tempo_map_set_tempo(&m, 16, 150)
	transport.set_tempo_map(r.clock, r.tl, &m)
	transport.set_leader(r.clock, r.tl)

	c := ramp_clip(r, {bpm = 120, mode = .Repitch})
	defer clip.audio_clip_release(c)
	clip.audio_player_set(r.player, c, {})
	audio_wait(t, r)
	transport.play(r.clock, r.tl)
	audio_run(r, 48_000 * 10, {1, 7, 333, 4096, 512})

	// Expected source frame: the timeline's beat × frames per beat at 120 BPM.
	expected :: proc(frame: int, user: rawptr) -> f64 {
		m := (^tb.Tempo_Map)(user)
		return f64(tb.samples_to_beats(m, tb.Sample_Time(frame), 48_000)) * 24_000
	}
	worst, at := worst_position_error(r.out[:], 256, len(r.out), expected, &m)
	// Within a frame; the probe itself reads ±(1e-6 × position), 0.4 frames out here.
	testing.expectf(t, worst < 1, "%.3f frames off at frame %d", worst, at)
	testing.expect_value(t, r.trap.violations, 0)
}

// A 44.1 kHz source on a 48 kHz device: converted, still locked.
@(test)
sample_rate_conversion :: proc(t: ^testing.T) {
	path := source_file("ramp_44k.wav", 44_100, 44_100 * 6)
	r := audio_rig(path, 100)
	defer audio_rig_destroy(r)
	c := ramp_clip(r, {bpm = 100, mode = .Repitch})
	defer clip.audio_clip_release(c)
	clip.audio_player_set(r.player, c, {})
	audio_wait(t, r)
	transport.play(r.clock, r.tl)
	audio_run(r, 48_000 * 4)
	expected :: proc(frame: int, user: rawptr) -> f64 { return f64(frame) * 44_100 / 48_000 }
	worst, at := worst_position_error(r.out[:], 256, len(r.out), expected, nil)
	testing.expectf(t, worst < 0.5, "%.3f frames off at frame %d", worst, at)
}

// A looping placement wraps seamlessly at the clip's loop points.
@(test)
loops_are_seamless :: proc(t: ^testing.T) {
	path := source_file("ramp_48k.wav", 48_000, 48_000 * 30)
	for in_memory in ([]bool{true, false}) {
		r := audio_rig(path, 120, in_memory = in_memory)
		c := ramp_clip(r, {start = 10_000, end = 200_000, loop_start = 24_000, loop_end = 60_000, bpm = 120, mode = .Repitch})
		clip.audio_player_set(r.player, c, {loop = true})
		audio_wait(t, r)
		transport.play(r.clock, r.tl)
		audio_run(r, 48_000 * 4, {512, 100, 4096}, pace = 0 if in_memory else 4)
		expected :: proc(frame: int, user: rawptr) -> f64 {
			p := 10_000 + f64(frame)
			if p >= 60_000 do p = 24_000 + math.mod(p - 60_000, 36_000)
			return p
		}
		// Away from each seam (the filter sees the jump in the ramp there).
		worst := 0.0
		for i := 256; i < len(r.out); i += 1 {
			p := 10_000 + f64(i)
			d := math.mod(p - 60_000, 36_000) if p >= 60_000 else p - 60_000
			if abs(d) < 128 || abs(d - 36_000) < 128 do continue // the High filter reaches 81 frames
			got := f64(r.out[i]) * RAMP_SCALE - 1
			worst = max(worst, abs(got - expected(i, nil)))
		}
		testing.expectf(t, worst < 0.5, "in memory %v: %.3f frames off", in_memory, worst)
		testing.expectf(t, stream.stats(r.streamer).underrun_frames == 0, "in memory %v: underruns", in_memory)
		clip.audio_clip_release(c)
		audio_rig_destroy(r)
	}
}

// Original mode ignores tempo: one source frame per output frame.
@(test)
original_mode_ignores_tempo :: proc(t: ^testing.T) {
	path := source_file("ramp_48k.wav", 48_000, 48_000 * 30)
	r := audio_rig(path, 77)
	defer audio_rig_destroy(r)
	c := ramp_clip(r, {mode = .Original})
	defer clip.audio_clip_release(c)
	clip.audio_player_set(r.player, c, {})
	audio_wait(t, r)
	transport.play(r.clock, r.tl)
	audio_run(r, 48_000 * 2)
	transport.set_tempo(r.clock, 160)
	audio_run(r, 48_000 * 2)
	expected :: proc(frame: int, user: rawptr) -> f64 { return f64(frame) }
	worst, at := worst_position_error(r.out[:], 256, len(r.out), expected, nil)
	testing.expectf(t, worst < 0.5, "%.3f frames off at frame %d", worst, at)
}

// Starting, stopping and jumping never click: the output never steps by
// more than a 440 Hz sine can between two frames.
@(test)
starts_stops_and_jumps_are_declicked :: proc(t: ^testing.T) {
	path := source_file("sine_48k.wav", 48_000, 48_000 * 10, sine = true)
	r := audio_rig(path, 120)
	defer audio_rig_destroy(r)
	c, _ := clip.audio_clip_create(r.source, {bpm = 120, mode = .Repitch})
	defer clip.audio_clip_release(c)
	clip.audio_player_set(r.player, c, {})
	audio_wait(t, r)
	transport.play(r.clock, r.tl)
	audio_run(r, 30_000)
	transport.locate(r.clock, r.tl, 0.0137) // a jump to an odd phase
	audio_run(r, 30_000)
	transport.stop(r.clock, r.tl)
	audio_run(r, 2_000)
	max_slope := 0.5 * math.TAU * 440 / 48_000 // a full-scale 440 Hz sine's steepest step
	step, at := kit.max_step(r.out[:])
	testing.expectf(t, step < max_slope * 1.05, "a step of %v at frame %d (a sine's steepest is %v)", step, at, max_slope)
	testing.expectf(t, kit.peak(r.out[len(r.out) - 1000:]) == 0, "still sounding after the stop")
}

// A clip with fades ramps in and out at its own start and end.
@(test)
clip_fades :: proc(t: ^testing.T) {
	path := source_file("sine_48k.wav", 48_000, 48_000 * 10, sine = true)
	r := audio_rig(path, 120, out_channels = 1)
	defer audio_rig_destroy(r)
	c, _ := clip.audio_clip_create(r.source, {start = 0, end = 24_000, mode = .Original, fade_in = 0.1, fade_out = 0.1})
	defer clip.audio_clip_release(c)
	clip.audio_player_set(r.player, c, {})
	audio_wait(t, r)
	transport.play(r.clock, r.tl)
	audio_run(r, 30_000)
	first := kit.peak(r.out[200:1000])
	middle := kit.peak(r.out[10_000:14_000])
	last := kit.peak(r.out[23_000:23_900])
	testing.expectf(t, first < 0.5 * 1000 / 4800 * 1.2, "fade-in too fast: %v", first)
	testing.expectf(t, middle > 0.49, "middle: %v", middle)
	testing.expectf(t, last < 0.5 * 1000 / 4800 * 1.2, "fade-out too slow: %v", last)
	testing.expect_value(t, kit.peak(r.out[24_000:]), 0)
}

// Mono plays on both outputs; stereo averages into a mono output.
@(test)
channel_mapping :: proc(t: ^testing.T) {
	mono := source_file("ramp_mono.wav", 48_000, 48_000, channels = 1)
	stereo := source_file("ramp_stereo.wav", 48_000, 48_000, channels = 2)
	{
		r := audio_rig(mono, 120, out_channels = 2)
		c := ramp_clip(r, {mode = .Original})
		clip.audio_player_set(r.player, c, {})
		audio_wait(t, r)
		transport.play(r.clock, r.tl)
		audio_run(r, 4000)
		testing.expect_value(t, kit.compare_slices(r.out[:], r.out2[:]).max_abs_error, 0)
		clip.audio_clip_release(c)
		audio_rig_destroy(r)
	}
	{
		r := audio_rig(stereo, 120, out_channels = 1)
		c := ramp_clip(r, {mode = .Original})
		clip.audio_player_set(r.player, c, {})
		audio_wait(t, r)
		transport.play(r.clock, r.tl)
		audio_run(r, 4000)
		// Channel 1 holds half of channel 0: the average is 0.75 of the ramp.
		got := f64(r.out[3000]) * RAMP_SCALE
		kit.expect_near(t, got, 0.75 * 3001, 0.5, fmt.tprintf("averaged"))
		clip.audio_clip_release(c)
		audio_rig_destroy(r)
	}
}

@(test)
bad_audio_clips :: proc(t: ^testing.T) {
	path := source_file("ramp_mono.wav", 48_000, 48_000, channels = 1)
	r := audio_rig(path)
	defer audio_rig_destroy(r)
	_, err := clip.audio_clip_create(r.source, {mode = .Repitch}) // no bpm
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = clip.audio_clip_create(r.source, {end = 100_000})
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = clip.audio_clip_create(r.source, {loop_start = 500, loop_end = 400})
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = clip.audio_clip_create(r.source, {bpm = 120, mode = .Repitch, transpose = 2}) // only Stretch transposes
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	// A Stretch clip is fine; a player without a stretcher refuses it.
	c, serr := clip.audio_clip_create(r.source, {bpm = 120, mode = .Stretch})
	testing.expect_value(t, serr, core.Error.None)
	testing.expect_value(t, clip.audio_player_set(r.player, c, {}), core.Error.Unsupported)
	clip.audio_clip_release(c)
}
