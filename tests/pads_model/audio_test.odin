package test_pads_model

import "core:math"
import "core:testing"
import "core:time"

import app "app:core"
import fc "fire:core"
import pm "../../apps/pads/model"
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
	s := app.store_get(&m.project.samples, cl.sample)
	if s == nil do return
	testing.expect_value(t, s.frames, i64(bar)) // one sequence long

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
	a, ok := pm.sample_audio(m, cl.sample)
	testing.expect(t, ok, "its audio")
	if ok {
		testing.expectf(t, abs(hz_of(a.channels[0][1000:][:bar / 8]) - 880) < 30, "from the top: what came after the count-in")
		testing.expectf(t, kit.peak(a.channels[0][bar / 2:]) == 0, "the rest is silent")
	}

	// Saved and loaded: the pad's kind and input, and the clip.
	pad := m.project.pads[3]
	pad.input, pad.monitor = {channel = 1}, true
	pm.set_pad(m, 3, .Input, "Input", pad)
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "audio_count2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	p2 := &r2.m.project
	testing.expect_value(t, p2.pads[3].kind, pm.Pad_Kind.Audio)
	testing.expect_value(t, p2.pads[3].input, pm.Audio_Input{channel = 1})
	testing.expect(t, p2.pads[3].monitor, "monitor")
	testing.expect_value(t, p2.clips[0][3].bpm, 120)
	testing.expect(t, app.store_get(&p2.samples, p2.clips[0][3].sample) != nil, "the clip's sample")
	render(r2, 4800) // builds the audio pad on a device without inputs
}

@(test)
audio_runs_hand_over_at_switches_and_song_steps :: proc(t: ^testing.T) {
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
	// A song: 1, 1, 2 (repeats merge), looping.
	p.song.count = 3
	p.song.steps[0] = {slot = 0, repeats = 1}
	p.song.steps[1] = {slot = 0, repeats = 1}
	p.song.steps[2] = {slot = 1, repeats = 1}
	song := pm.plan_song(p, 0)
	cur, next = pm.audio_runs(song, 1)
	testing.expect(t, cur.slot == 0 && cur.start == 0 && cur.end == 8 && next.slot == 1 && next.start == 8 && next.end == 16, "song")
	cur, next = pm.audio_runs(song, 10)
	testing.expect(t, cur.slot == 1 && next.slot == 0 && next.start == 16 && next.end == 24, "round to the top")
}
