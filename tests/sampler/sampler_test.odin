package test_sampler

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:core"
import "fire:sampler"
import "fire:stream"
import tb "fire:timebase"
import kit "fire:testkit"

SR :: 48_000.0

Lab :: struct {
	streamer: ^stream.Streamer,
	dir:      string,
	sine:     ^stream.Source, // 440 Hz, 1 s at 44.1 kHz
	high:     ^stream.Source, // 1000 Hz, 1 s at 48 kHz
	short:    ^stream.Source, // 480 Hz, 0.1 s at 48 kHz: exactly 48 cycles, loopable
}

write_tone :: proc(dir, name: string, hz, rate, seconds: f64) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	n := int(rate * seconds)
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x do v = f32(0.5 * math.sin(math.TAU * hz * f64(i) / rate))
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(rate, 1))
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	return path
}

lab_make :: proc() -> ^Lab {
	l := new(Lab)
	l.streamer, _ = stream.create(stream.default_settings())
	l.dir, _ = os.make_directory_temp("", "fire_sampler", context.allocator)
	l.sine, _ = stream.source_open(l.streamer, write_tone(l.dir, "sine.wav", 440, 44_100, 1))
	l.high, _ = stream.source_open(l.streamer, write_tone(l.dir, "high.wav", 1000, 48_000, 1))
	l.short, _ = stream.source_open(l.streamer, write_tone(l.dir, "short.wav", 480, 48_000, 0.1))
	for src in ([]^stream.Source{l.sine, l.high, l.short}) {
		for stream.source_state(src) == .Loading do time.sleep(time.Millisecond)
	}
	return l
}

lab_destroy :: proc(l: ^Lab) {
	stream.source_release(l.sine)
	stream.source_release(l.high)
	stream.source_release(l.short)
	stream.destroy(l.streamer)
	os.remove_all(l.dir)
	delete(l.dir)
	free(l)
}

play :: proc(t: ^testing.T, zones: []sampler.Sample_Zone, frames: int, events: []kit.Timed_Event, quality := sampler.Sampler_Quality.Cubic) -> kit.Audio_Buffer {
	node, s := sampler.sampler_create({quality = quality})
	defer core.node_destroy(&node)
	m, err := sampler.sample_map_create(zones)
	if !testing.expect_value(t, err, core.Error.None) do return {}
	sampler.sampler_set_map(s, m)
	sampler.sample_map_release(m)
	cfg := kit.default_render_config()
	cfg.events = events
	out, r := kit.render(&node, kit.buffer_length_only(frames, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

cycles :: proc(x: []f32) -> int {
	n := 0
	for i in 1 ..< len(x) do if x[i - 1] < 0 && x[i] >= 0 do n += 1
	return n
}

on :: proc(at: int, key: u8, velocity: f32 = 1, id: core.Note_Id = core.NOTE_ID_ANY) -> kit.Timed_Event {
	return {tb.Sample_Time(at), core.Note_On{id = id, key = key, velocity = velocity}}
}

off :: proc(at: int, key: u8) -> kit.Timed_Event {
	return {tb.Sample_Time(at), core.Note_Off{id = core.NOTE_ID_ANY, key = key}}
}

@(test)
notes_play_at_their_pitch :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	zones := []sampler.Sample_Zone{{source = l.sine, root_key = 69}}
	for c in ([]struct{ key: u8, hz: f64 }{{69, 440}, {81, 880}, {57, 220}}) do for quality in ([]sampler.Sampler_Quality{.Cubic, .Sinc_Low}) {
		out := play(t, zones, 30_000, {on(0, c.key)}, quality)
		got := cycles(out.channels[0][2_400:21_600]) // 0.4 s, before an octave up runs out of the 1 s sample
		testing.expectf(t, abs(f64(got) - c.hz * 0.4) <= 1, "key %d: %d cycles in 0.4 s, want %.0f (the 44.1 kHz sample converted)", c.key, got, c.hz * 0.4)
	}
}

@(test)
zones_answer_their_keys_and_velocities :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	zones := []sampler.Sample_Zone{
		{source = l.sine, root_key = 69, key_lo = 60, key_hi = 72, vel_lo = 0, vel_hi = 0.5},
		{source = l.high, root_key = 69, key_lo = 60, key_hi = 72, vel_lo = 0.51, vel_hi = 1},
	}
	soft := play(t, zones, 30_000, {on(0, 69, 0.3)})
	loud := play(t, zones, 30_000, {on(0, 69, 0.9)})
	none := play(t, zones, 30_000, {on(0, 80, 0.9)})
	testing.expect(t, abs(cycles(soft.channels[0][4_800:28_800]) - 220) <= 1, "soft: the 440 Hz layer")
	testing.expect(t, abs(cycles(loud.channels[0][4_800:28_800]) - 500) <= 1, "loud: the 1 kHz layer")
	testing.expect_value(t, kit.peak(none.channels[0]), 0) // outside every key range
}

@(test)
loops_sustain_and_samples_end :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	looped := play(t, {{source = l.short, root_key = 69, loop = true}}, 72_000, {on(0, 69), off(48_000, 69)})
	plain := play(t, {{source = l.short, root_key = 69}}, 48_000, {on(0, 69)})
	shot := play(t, {{source = l.short, root_key = 69, one_shot = true}}, 48_000, {on(0, 69), off(100, 69)})
	testing.expect(t, kit.peak(looped.channels[0][40_000:47_000]) > 0.4, "held 1 s on a 0.1 s sample: the loop keeps it going")
	testing.expect_value(t, kit.peak(looped.channels[0][70_000:]), 0) // released at 1 s, 0.2 s release
	testing.expect_value(t, kit.peak(plain.channels[0][10_000:]), 0) // no loop: ends with the sample
	testing.expect(t, kit.peak(shot.channels[0][2_000:4_000]) > 0.4, "one-shot: the note-off doesn't stop it")
}

@(test)
expression_and_map_swaps :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	// Tuning bends one note an octave.
	bent := play(t, {{source = l.sine, root_key = 69, loop = true, loop_start = 4410, loop_end = 44_100}}, 60_000, {on(0, 69, 1, 3), {30_000, core.Note_Expression{id = 3, key = 69, kind = .Tuning, value = 12}}})
	testing.expect(t, abs(cycles(bent.channels[0][32_000:56_000]) - 440) <= 1, "bent an octave up")

	// A new map while a note sounds: the note finishes on the old one,
	// new notes use the new one, and the old map is released after.
	node, s := sampler.sampler_create({})
	defer core.node_destroy(&node)
	a, _ := sampler.sample_map_create({{source = l.sine, root_key = 69}})
	b, _ := sampler.sample_map_create({{source = l.high, root_key = 69}})
	sampler.sampler_set_map(s, a)
	core.node_prepare(&node, {sample_rate = SR, max_block = 512, out_channels = 2})
	left, right := make([]f32, 512, context.temp_allocator), make([]f32, 512, context.temp_allocator)
	run :: proc(n: ^core.Node, l, r: []f32, events: []core.Event) {
		ctx := core.Process_Context{outputs = {l, r}, frames = 512, events_in = events}
		core.node_process(n, &ctx)
	}
	run(&node, left, right, {{0, core.Note_On{id = core.NOTE_ID_ANY, key = 69, velocity = 1}}})
	sampler.sampler_set_map(s, b)
	for _ in 0 ..< 10 do run(&node, left, right, nil)
	testing.expect(t, cycles(left) >= 4, "the old note goes on") // 440 Hz: about 4.7 cycles a block
	run(&node, left, right, {{0, core.Note_Off{id = core.NOTE_ID_ANY, key = 69}}})
	for _ in 0 ..< 40 do run(&node, left, right, nil) // past the 0.2 s release
	testing.expect_value(t, a.refs, 2) // ours, and the retired one waiting to be collected
	sampler.sampler_set_map(s, b) // collects
	testing.expect_value(t, a.refs, 1)
	sampler.sample_map_release(a)
	sampler.sample_map_release(b)
}

Factory_Args :: struct {
	lab:     ^Lab,
	quality: sampler.Sampler_Quality,
}

sampler_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node {
	a := (^Factory_Args)(user)
	l := a.lab
	node, s := sampler.sampler_create({voices = 4, quality = a.quality})
	m, _ := sampler.sample_map_create({{source = l.sine, root_key = 69, loop = true, loop_start = 1000, loop_end = 40_000}, {source = l.short, root_key = 60, key_lo = 30, key_hi = 64}})
	sampler.sampler_set_map(s, m)
	sampler.sample_map_release(m)
	return node
}}

@(test)
sampler_is_block_invariant :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	cfg := kit.default_render_config()
	cfg.events = {on(0, 69), on(1_000, 62, 0.4), {5_000, core.Param_Ramp{sampler.SAMPLER_PARAM_GAIN_DB, -6, 3000}}, on(7_000, 50), on(9_000, 76), on(9_100, 70), off(12_000, 69), {14_000, core.Param_Value{sampler.SAMPLER_PARAM_TRANSPOSE, 5}}, on(15_000, 40)}
	patterns := kit.standard_block_patterns(cfg.max_block)
	for quality in ([]sampler.Sampler_Quality{.Cubic, .Sinc_Medium}) {
		args := Factory_Args{l, quality}
		factory := sampler_factory
		factory.user = &args
		kit.expect_block_invariant(t, factory, kit.buffer_length_only(30_000, SR), cfg, patterns[:], 0, "sampler")
	}
}
