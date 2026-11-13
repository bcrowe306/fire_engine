package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import app "app:core"
import "fire:audiofile"
import "fire:stream"
import "fire:backend"
import "fire:backend/fake"
import fc "fire:core"
import kit "fire:testkit"
import pm "../../apps/pads/model"

@(private)
interface_8x8 := []fake.Device_Spec{{
	id = "fake:8x8", name = "Eight", input_channels = 8, output_channels = 8,
	sample_rates = {48_000}, buffer_sizes = {256}, default_sample_rate = 48_000, default_buffer_frames = 256,
}}

// A rig on the 8-in/8-out interface, these channels open.
@(private)
rig_8 :: proc(t: ^testing.T, name: string, ins, outs: backend.Channel_Mask) -> ^Rig {
	r := new(Rig)
	app.bus_init(&r.bus)
	app.host_init(&r.host, {fake = true, sample_rate = SR, max_block = 256, fake_devices = interface_8x8, output_device = "fake:8x8", input_device = "fake:8x8", input_channels = ins, output_channels = outs}, &r.bus)
	app.host_open(&r.host)
	app.host_close(&r.host)
	r.dir, _ = filepath.join({kit.artifacts_root(), "pads_model", name})
	os.remove_all(r.dir)
	for k := 0; k < 100 && !os.is_dir(r.dir); k += 1 do os.make_directory_all(r.dir)
	testing.expect_value(t, pm.model_init(&r.m, &r.host, r.dir), fc.Error.None)
	return r
}

// Renders `frames` into as many outputs as the graph has (and `ins` in).
@(private)
render_all :: proc(r: ^Rig, frames: int, ins: [][]f32 = nil) -> [][]f32 {
	pm.sync(&r.m.engine)
	for _, src in r.m.engine.sources {
		for stream.source_state(src) == .Loading do time.sleep(time.Millisecond)
	}
	n := r.host.graph.settings.output_channels
	out := make([][]f32, n, context.temp_allocator)
	for &o in out do o = make([]f32, frames, context.temp_allocator)
	app.host_render(&r.host, out, frames, ins)
	return out
}

@(private)
pk :: proc(x: []f32) -> f64 { return kit.peak(x[len(x) / 2:]) }

@(test)
main_the_cue_and_direct_outs_play_on_their_pairs :: proc(t: ^testing.T) {
	// Outputs 1–8 open (graph channels 0..7, in order).
	r := rig_8(t, "outputs_pairs", {}, {0, 1, 2, 3, 4, 5, 6, 7})
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "t.wav", 1000, 4))
	// Main on outputs 3/4, the cue on 5/6.
	pm.set_outputs(&m.engine, {main = 2, cue = 4, cue_db = 0})
	pm.hit(&m.engine, 0, true)
	out := render_all(r, 9600)
	testing.expect(t, pk(out[0]) < 1e-6 && pk(out[2]) > 0.4 && pk(out[3]) > 0.4, "main on 3/4, not 1/2")
	testing.expectf(t, abs(pk(out[4]) - pk(out[2])) < 1e-3, "the cue: a copy of main (%v)", pk(out[4]))
	// A cue send at 0 dB: the cue has the pad twice.
	pm.set_pad_cue(m, 0, {level = 1})
	app.seal(&m.history)
	out = render_all(r, 9600)
	testing.expectf(t, abs(pk(out[4]) / pk(out[2]) - 2) < 0.02, "the cue send adds to it (%v)", pk(out[4]) / pk(out[2]))
	// A direct out: the pad on outputs 7/8, not in main (nor the cue's copy).
	pm.set_pad_bus(m, 0, pm.out_dest(3))
	out = render_all(r, 9600)
	testing.expect(t, pk(out[6]) > 0.4 && pk(out[2]) < 1e-6, "straight to 7/8")
	// Main's pair not open: main on the first open pair.
	pm.set_pad_bus(m, 0, 0)
	pm.set_outputs(&m.engine, {main = 10, cue = -1})
	out = render_all(r, 9600)
	testing.expect(t, pk(out[0]) > 0.4 && pk(out[4]) < 1e-6, "main back on 1/2, no cue")
}

@(test)
the_click_can_play_on_the_cue_only :: proc(t: ^testing.T) {
	r := rig_8(t, "outputs_click", {}, {0, 1, 2, 3})
	defer rig_destroy(r)
	m := &r.m
	m.engine.metronome = true
	pm.set_outputs(&m.engine, {main = 0, cue = 2, click_cue = true})
	pm.play(&m.engine)
	out := render_all(r, 48_000)
	testing.expect(t, kit.peak(out[2]) > 0.05 && kit.peak(out[0]) < 1e-6, "the click on the cue only")
	pm.set_outputs(&m.engine, {main = 0, cue = 2, click_cue = false})
	out = render_all(r, 48_000)
	testing.expect(t, kit.peak(out[2]) > 0.05 && kit.peak(out[0]) > 0.05, "and in main")
}

@(test)
an_export_folds_direct_outs_into_main :: proc(t: ^testing.T) {
	r := rig_8(t, "outputs_export", {}, {0, 1, 2, 3})
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "t.wav", 1000, 4))
	pm.add_note(m, 0, {start = 0, length = 2, pad = 0, velocity = 1})
	pm.set_pad_bus(m, 0, pm.out_dest(1)) // outputs 3/4
	render_all(r, 256) // (the sample loaded)
	x: pm.Export
	path, _ := filepath.join({r.dir, "mix.wav"}, context.temp_allocator)
	files := pm.export_all(m, {source = .Sequence, encoding = .Float32}, path, &x)
	defer pm.export_destroy(&x)
	testing.expect_value(t, len(files), 1)
	if len(files) == 0 do return
	a, err := audio_file_peak(files[0])
	testing.expect(t, err && a > 0.3, "the direct out is in the mixdown")
}

@(test)
an_audio_track_records_from_its_physical_input :: proc(t: ^testing.T) {
	// Inputs 1, 2 and 6 open: input 6 is the graph's channel 2.
	r := rig_8(t, "outputs_input", {0, 1, 5}, {0, 1})
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, app.host_input_channel(&r.host, 5), 2)
	pm.set_pad_kind(m, 3, .Audio)
	pad := m.project.pads[3]
	pad.input, pad.monitor = {channel = 5}, .Auto
	pm.set_pad(m, 3, .Whole, "Input", pad)
	app.seal(&m.history)
	pm.arm_track(m, 3, true)
	testing.expect(t, pm.input_open(&m.engine, 3))
	ins := [][]f32{make([]f32, 9600, context.temp_allocator), make([]f32, 9600, context.temp_allocator), make([]f32, 9600, context.temp_allocator)}
	kit.sine(ins[2], SR, 440, 0.5)
	render_all(r, 9600, ins)
	out := render_all(r, 9600, ins)
	testing.expectf(t, pk(out[0]) > 0.2, "monitored from input 6 (%v)", pk(out[0]))
	// Input 7 isn't open: the track says so, and hears nothing.
	pad.input = {channel = 6}
	pm.set_pad(m, 3, .Whole, "Input", pad)
	app.seal(&m.history)
	testing.expect(t, !pm.input_open(&m.engine, 3))
	render_all(r, 9600, ins)
	out = render_all(r, 9600, ins)
	testing.expect(t, pk(out[0]) < 1e-6, "input 7: not open")
}

// The loudest sample of an audio file (and whether it opened).
@(private)
audio_file_peak :: proc(path: string) -> (f64, bool) {
	rd, err := audiofile.open(path)
	if err != .None do return 0, false
	defer audiofile.close(rd)
	info := audiofile.info(rd)
	buf := kit.buffer_make(info.channels, int(info.frames), info.sample_rate, context.temp_allocator)
	audiofile.read(rd, buf.channels, int(info.frames))
	return kit.peak(buf.channels[0]), true
}

@(test)
a_test_tone_plays_on_its_pair_alone :: proc(t: ^testing.T) {
	r := rig_8(t, "outputs_tone", {}, {0, 1, 4, 5})
	defer rig_destroy(r)
	m := &r.m
	testing.expect(t, !pm.test_tone(&m.engine, 2), "outputs 3/4 aren't open")
	testing.expect(t, pm.test_tone(&m.engine, 4), "outputs 5/6 are (graph channels 2, 3)")
	out := render_all(r, 9600)
	testing.expect(t, kit.peak(out[2]) > 0.2 && kit.peak(out[3]) > 0.2 && kit.peak(out[0]) < 1e-6, "on 5/6 only")
	out = render_all(r, 48_000)
	testing.expectf(t, kit.peak(out[2][40_000:]) < 1e-6, "a second, then silence")
}
