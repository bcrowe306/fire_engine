package test_pads_model

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import pm "../../apps/pads/model"
import "fire:record"
import "fire:stream"
import kit "fire:testkit"

// A sine at `hz` into both inputs, `frames` long.
@(private)
sine_in :: proc(hz: f64, frames: int, from := 0) -> [2][]f32 {
	x := make([]f32, frames, context.temp_allocator)
	for &v, i in x do v = f32(0.4 * math.sin(math.TAU * hz * f64(from + i) / SR))
	return {x, x}
}

// Renders with `inputs`, syncing first (as `render`).
@(private)
render_in :: proc(r: ^Rig, inputs: [2][]f32) -> [2][]f32 {
	pm.sync(&r.m.engine)
	n := len(inputs[0])
	out := [2][]f32{make([]f32, n, context.temp_allocator), make([]f32, n, context.temp_allocator)}
	ins := inputs
	app.host_render(&r.host, out[:], n, ins[:])
	return out
}

// Cycles a second of `x` has (zero crossings / 2).
@(private)
hz_of :: proc(x: []f32) -> f64 {
	n := 0
	for i in 1 ..< len(x) do if (x[i - 1] < 0) != (x[i] < 0) do n += 1
	return f64(n) / 2 / (f64(len(x)) / SR)
}

// Waits for the take to come back and be folded into a clip.
@(private)
poll_clip :: proc(r: ^Rig, c: ^pm.Capture, slot, pad: int) -> pm.Clip {
	for _ in 0 ..< 200 {
		pm.capture_poll(&r.m, c)
		if cl := r.m.project.clips[slot][pad]; cl.sample != 0 do return cl
		time.sleep(5 * time.Millisecond)
	}
	return {}
}

@(test)
an_audio_pad_records_a_take_and_plays_it_with_the_sequence :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_rec", inputs = 2)
	defer rig_destroy(r)
	m := &r.m
	pm.set_pad_kind(m, 0, .Audio)
	testing.expect(t, pm.pad_used(&m.project, 0), "an audio pad is used")
	pm.arm_track(m, 0, true)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	// The sequence is a bar: 2 s at 120 BPM. A pass and a half: 440 Hz,
	// then 880 Hz over the first half again.
	bar := int(2 * SR)
	render_in(r, sine_in(440, bar))
	render_in(r, sine_in(880, bar / 2))
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	render(r, 512) // the recorder hears the stop
	cl := poll_clip(r, &c, 0, 0)
	testing.expect(t, cl.sample != 0, "a clip in sequence 1")
	testing.expect_value(t, app.undo_name(&m.history), "Record Audio")
	// A take a pass, placed where it was played: the part a sequence long.
	testing.expect(t, cl.part != 0, "a part")
	x := pm.part_of(&m.project, 0, 0)
	testing.expect_value(t, x.take_count, 2)
	whole, wok := pm.part_audio(m, 0, 0)
	if !testing.expect(t, wok, "its audio") do return
	testing.expect_value(t, len(whole.channels[0]), bar) // one sequence long

	// Played back with the sequence: the last pass first, then the first's end.
	// (Once the take's start is buffered, as the app's players are before a
	// play: they get what plays from the top while stopped.)
	for _ in 0 ..< 400 {
		render(r, 256)
		if pm.audio_ready(&m.engine) do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, pm.audio_ready(&m.engine), "the take is buffered")
	pm.play(&m.engine)
	out := render_in(r, {make([]f32, bar, context.temp_allocator), make([]f32, bar, context.temp_allocator)})
	first, second := hz_of(out[0][bar / 8:][:bar / 4]), hz_of(out[0][bar * 5 / 8:][:bar / 4])
	testing.expectf(t, abs(first - 880) < 20, "the second pass is heard where it was played (%v Hz)", first)
	testing.expectf(t, abs(second - 440) < 20, "the first pass where the second didn't reach (%v Hz)", second)
	// And round again.
	again := render_in(r, {make([]f32, bar / 2, context.temp_allocator), make([]f32, bar / 2, context.temp_allocator)})
	testing.expectf(t, abs(hz_of(again[0][bar / 8:][:bar / 4]) - 880) < 20, "it loops")
	pm.stop(&m.engine)

	// Undo takes the clip away; the pad is still an audio pad.
	app.undo(&m.history)
	testing.expect_value(t, m.project.clips[0][0].sample, app.Id(0))
	testing.expect_value(t, m.project.pads[0].kind, pm.Pad_Kind.Audio)
	app.redo(&m.history)
	testing.expect(t, m.project.clips[0][0].sample != 0, "redone")
}

@(test)
counting_in_and_song_mode_record_nothing_and_clips_save :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_count", inputs = 2)
	defer rig_destroy(r)
	m := &r.m
	pm.set_pad_kind(m, 3, .Audio)
	pm.arm_track(m, 3, true)
	tr := m.project.transport
	tr.count_in = 1
	pm.set_transport(m, .Count_In, "Count-in", tr)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine, count_in = true)
	bar := int(2 * SR)
	render_in(r, sine_in(440, bar)) // the count-in: not recorded
	render_in(r, sine_in(880, bar / 4))
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	render(r, 512)
	cl := poll_clip(r, &c, 0, 3)
	s := app.store_get(&m.project.samples, cl.sample)
	testing.expect(t, s != nil, "a clip")
	if s == nil do return
	a, ok := pm.part_audio(m, 0, 3)
	testing.expect(t, ok, "its audio")
	if ok {
		testing.expectf(t, abs(hz_of(a.channels[0][1000:][:bar / 8]) - 880) < 30, "from the top: what came after the count-in")
		testing.expectf(t, kit.peak(a.channels[0][bar / 2:]) == 0, "the rest is silent")
	}

	// Saved and loaded: the pad's kind and input, and the clip.
	pad := m.project.pads[3]
	pad.input, pad.monitor = {channel = 1}, .In
	pm.set_pad(m, 3, .Input, "Input", pad)
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "audio_count2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	p2 := &r2.m.project
	testing.expect_value(t, p2.pads[3].kind, pm.Pad_Kind.Audio)
	testing.expect_value(t, p2.pads[3].input, pm.Audio_Input{channel = 1})
	testing.expect_value(t, p2.pads[3].monitor, pm.Monitor.In)
	testing.expect_value(t, p2.clips[0][3].bpm, 120)
	testing.expect(t, app.store_get(&p2.samples, p2.clips[0][3].sample) != nil, "the clip's sample")
	render(r2, 4800) // builds the audio pad on a device without inputs
}

@(test)
audio_runs_hand_over_at_switches_and_song_clips :: proc(t: ^testing.T) {
	p := new(pm.Project) // (too big for a Windows thread's stack)
	defer free(p)
	pm.project_init(p, "")
	defer pm.project_destroy(p)
	p.sequences[1].bars = 2
	// A pattern: one run for ever.
	cur, next := pm.audio_runs(pm.plan_pattern(p, 0, 0), 9)
	testing.expect(t, cur.valid && cur.slot == 0 && cur.start == 0 && cur.end == math.INF_F64 && !next.valid, "pattern")
	// A switch at beat 8: sequence 1 until then, sequence 2 after, for ever.
	sw := pm.plan_switch(p, pm.plan_pattern(p, 0, 0), 1, 8)
	cur, next = pm.audio_runs(sw, 5)
	testing.expect(t, cur.slot == 0 && cur.end == 8 && next.slot == 1 && next.start == 8 && next.end == math.INF_F64, "switch")
	later, _ := pm.audio_runs(sw, 30)
	testing.expect(t, later == next, "the same run every cycle after it")
	// A song: 1, 1, 2 (the same one right after itself merges), looping.
	p.song.count = 3
	p.song.clips[0] = {slot = 0, at = 0, length = 4}
	p.song.clips[1] = {slot = 0, at = 4, length = 4}
	p.song.clips[2] = {slot = 1, at = 8, length = 8}
	song := pm.plan_song(p, 0)
	cur, next = pm.audio_runs(song, 1)
	testing.expect(t, cur.slot == 0 && cur.start == 0 && cur.end == 8 && next.slot == 1 && next.start == 8 && next.end == 16, "song")
	cur, next = pm.audio_runs(song, 10)
	testing.expect(t, cur.slot == 1 && next.slot == 0 && next.start == 16 && next.end == 24, "round to the top")
	// A clip on a lower lane over the second sequence: the top lane leads.
	p.song.count = 4
	p.song.clips[3] = {lane = 1, slot = 2, at = 6, length = 6}
	song = pm.plan_song(p, 0)
	cur, next = pm.audio_runs(song, 10)
	testing.expect(t, cur.slot == 1, "the top lane's")
	cur, _ = pm.audio_runs(song, 7)
	testing.expect(t, cur.slot == 0, "the top lane's before it")
}

@(test)
an_audio_take_lines_up_with_what_was_heard :: proc(t: ^testing.T) {
	// A loopback, as a cable from an output to an input: what pad 0 plays
	// comes back on the inputs 300 frames later (the round trip). Pad 1,
	// an audio track, records it; with the round trip compensated (here the
	// recording offset: offline, the device reports none), its take has the
	// hit on the very frame it was played (where the sequencer put it).
	r := rig_make(t, "audio_loopback", inputs = 2)
	defer rig_destroy(r)
	m := &r.m
	LOOP :: 300
	pm.load_onto_pad(m, 0, tone(r, "hit.wav", 440, 0.05, decay = true))
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 2.5, length = 0.25, pad = 0, velocity = 1})
	pm.set_pad_kind(m, 1, .Audio)
	off := m.project.pads[1]
	off.monitor = .Off // (with a cable back to the input, monitoring would feed back)
	pm.set_pad(m, 1, .Monitor, "Monitor", off)
	pm.arm_track(m, 1, true)
	m.engine.record_offset = LOOP
	render(r, 512)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	bar := int(2 * SR)
	// Each block's inputs: the outputs LOOP frames before.
	heard := make([]f32, bar + LOOP, context.temp_allocator)
	BLOCK :: 256
	for at := 0; at < bar; at += BLOCK {
		n := min(BLOCK, bar - at)
		x := make([]f32, n, context.temp_allocator)
		for i in 0 ..< n do if at + i - LOOP >= 0 do x[i] = heard[at + i - LOOP]
		out := render_in(r, {x, x})
		copy(heard[at:][:n], out[0][:n])
	}
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	render(r, 512)
	cl := poll_clip(r, &c, 0, 1)
	s := app.store_get(&m.project.samples, cl.sample)
	if !testing.expect(t, s != nil, "a take on pad 1") do return
	rd, err := audiofile.open(s.path, context.temp_allocator)
	if !testing.expect_value(t, err, audiofile.Error.None) do return
	defer audiofile.close(rd)
	take := make([]f32, int(s.frames), context.temp_allocator)
	other := make([]f32, int(s.frames), context.temp_allocator)
	audiofile.read(rd, {take, other}, len(take))
	first :: proc(x: []f32, from: int) -> int {
		for v, i in x[from:] do if abs(v) > 0.02 do return from + i
		return -1
	}
	// The hits in what was played (the output), and in the take.
	for from in ([]int{0, int(2 * SR / 2)}) {
		played, taken := first(heard[:bar], from), first(take, from)
		testing.expectf(t, played > 0 && played == taken, "the hit after %d: played at %d, in the take at %d", from, played, taken)
	}
}

// A rig whose simulated interface runs as a device (callbacks,
// timestamps), reporting 200 frames in and 312 out, with a cable from its
// outputs back to its inputs 512 frames later (their sum: a real loop).
@(private)
rig_cabled :: proc(t: ^testing.T, name: string) -> ^Rig {
	r := new(Rig)
	app.bus_init(&r.bus)
	app.host_init(&r.host, {fake = true, sample_rate = SR, buffer_frames = 256, max_block = 256, inputs = 2, fake_latency = {200, 312}, fake_loopback = 512}, &r.bus)
	testing.expect_value(t, app.host_open(&r.host), fc.Error.None)
	r.dir, _ = filepath.join({kit.artifacts_root(), "pads_model", name})
	os.remove_all(r.dir)
	for k := 0; k < 100 && !os.is_dir(r.dir); k += 1 do os.make_directory_all(r.dir)
	testing.expect_value(t, pm.model_init(&r.m, &r.host, r.dir), fc.Error.None)
	return r
}

// Runs a cabled rig's device for `frames` (whole callbacks), syncing and
// writing takes as the app does each frame.
@(private)
run :: proc(r: ^Rig, frames: int) {
	for done := 0; done < frames; done += 256 {
		pm.sync(&r.m.engine)
		// (Samples loaded before they play, as `render` waits: a slow disk
		// would otherwise play silence.)
		for _, src in r.m.engine.sources do for stream.source_state(src) == .Loading do time.sleep(time.Millisecond)
		app.host_fake_run(&r.host, 1)
		record.disk_writer_service(r.host.disk)
	}
}

@(test)
the_drivers_round_trip_is_compensated :: proc(t: ^testing.T) {
	// The simulated interface reports 200 frames in and 312 out, and a
	// cable takes its outputs back to its inputs 512 frames later (their
	// sum: what a real loop does). Run as a device (callbacks, timestamps),
	// with no recording offset: the take still has pad 0's hits on the
	// frames they were played.
	r := rig_cabled(t, "audio_round_trip")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "hit.wav", 440, 0.05, decay = true))
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 2.5, length = 0.25, pad = 0, velocity = 1})
	pm.set_pad_kind(m, 1, .Audio)
	off := m.project.pads[1]
	off.monitor = .Off // (with a cable back to the input, monitoring would feed back)
	pm.set_pad(m, 1, .Monitor, "Monitor", off)
	pm.arm_track(m, 1, true)
	run(r, 4096)
	_, _, round_trip := app.host_latency(&r.host)
	testing.expect_value(t, round_trip, 512)
	testing.expect_value(t, pm.record_latency(&m.engine), 512)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	run(r, int(2 * SR))
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	run(r, 2048)
	cl: pm.Clip
	for _ in 0 ..< 200 {
		pm.capture_poll(&r.m, &c)
		if x := r.m.project.clips[0][1]; x.sample != 0 {
			cl = x
			break
		}
		run(r, 256)
	}
	s := app.store_get(&m.project.samples, cl.sample)
	if !testing.expect(t, s != nil, "a take on pad 1") do return
	rd, err := audiofile.open(s.path, context.temp_allocator)
	if !testing.expect_value(t, err, audiofile.Error.None) do return
	defer audiofile.close(rd)
	take := make([]f32, int(s.frames), context.temp_allocator)
	other := make([]f32, int(s.frames), context.temp_allocator)
	audiofile.read(rd, {take, other}, len(take))
	first :: proc(x: []f32, from: int) -> int {
		for v, i in x[from:] do if abs(v) > 0.02 do return from + i
		return -1
	}
	// Where the sequencer played them (the offline test's frames: the hit
	// crosses the threshold 6 frames in).
	for want in ([]int{24_006, 60_006}) {
		got := first(take, want - 12_000)
		testing.expectf(t, got == want, "a hit at frame %d of the take (%d)", want, got)
	}
}

@(test)
hits_are_recorded_where_they_were_heard :: proc(t: ^testing.T) {
	// Played along with what came out 312 frames after the engine made it:
	// a hit is recorded 312 frames earlier than it reached the engine.
	r := rig_cabled(t, "hits_heard")
	defer rig_destroy(r)
	m := &r.m
	m.project.transport.quantize.on = false
	pm.load_onto_pad(m, 0, tone(r, "hit.wav", 440, 0.05, decay = true))
	run(r, 2048)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	run(r, 48 * 256) // 12288 frames: the hit reaches the engine at the next callback
	pm.hit(&m.engine, 0, true, 0.9)
	run(r, 256 * 8)
	pm.hit(&m.engine, 0, false)
	run(r, 256 * 4)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	notes := m.project.sequences[0].notes
	if !testing.expect_value(t, len(notes), 1) do return
	want := f64(48 * 256 - 312) / 24_000
	testing.expectf(t, abs(notes[0].start - want) < 1e-6, "at %v beats (%v)", want, notes[0].start)
}

@(test)
each_pass_onto_a_track_of_its_own :: proc(t: ^testing.T) {
	// Passes to tracks on: two passes of pad 0 make pad 0's take (440 Hz)
	// and pad 1's (880 Hz, an audio track named for the pass), lined up.
	r := rig_make(t, "audio_passes", inputs = 2)
	defer rig_destroy(r)
	m := &r.m
	m.passes_to_tracks = true
	pm.set_pad_kind(m, 0, .Audio)
	pm.arm_track(m, 0, true)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	bar := int(2 * SR)
	render_in(r, sine_in(440, bar))
	render_in(r, sine_in(880, bar))
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	render(r, 512)
	poll_clip(r, &c, 0, 0)
	poll_clip(r, &c, 0, 1)
	p := &m.project
	testing.expect_value(t, p.pads[1].kind, pm.Pad_Kind.Audio)
	testing.expect_value(t, pm.pad_name(&p.pads[1]), "Audio A1 pass 2")
	a, aok := pm.part_audio(m, 0, 0)
	b, bok := pm.part_audio(m, 0, 1)
	if !testing.expect(t, aok && bok, "both parts") do return
	testing.expectf(t, abs(hz_of(a.channels[0][bar / 4:][:bar / 2]) - 440) < 20, "pass 1 on pad 0")
	testing.expectf(t, abs(hz_of(b.channels[0][bar / 4:][:bar / 2]) - 880) < 20, "pass 2 on pad 1")
}
