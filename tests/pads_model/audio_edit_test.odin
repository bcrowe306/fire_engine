package test_pads_model

import "core:math"
import "core:path/filepath"
import "core:testing"
import "core:time"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import pm "../../apps/pads/model"

// A take whose frame i is i / 100 000 (a ramp: where a frame came from
// shows), a sequence long (a bar at 120: 96 000 frames, 24 000 a beat),
// as pad `pad`'s clip in sequence 1.
@(private)
ramp_clip :: proc(r: ^Rig, pad: int, name := "ramp.wav") -> app.Id {
	m := &r.m
	path, _ := filepath.join({r.dir, name}, context.temp_allocator)
	n := 96_000
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x do v = f32(i) / 100_000
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	pm.set_pad_kind(m, pad, .Audio)
	id := pm.add_sample(m, path, {format = .Wav, encoding = .Float32, sample_rate = SR, channels = 1, frames = i64(n)})
	pm.set_clip(m, 0, pad, "Clip", {sample = id, bpm = 120})
	app.seal(&m.history)
	return id
}

@(private)
mix_of :: proc(t: ^testing.T, m: ^pm.Model, pad: int) -> []f32 {
	a, ok := pm.part_audio(m, 0, pad)
	if !testing.expect(t, ok, "the part's audio") do return nil
	return a.channels[0]
}

@(test)
cut_crop_split_move_and_trim_never_touch_the_file :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_edit")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	take := ramp_clip(r, 1)
	// A plain clip is its take whole.
	x := pm.part_of(p, 0, 1)
	testing.expect(t, x.count == 1 && x.take_count == 1 && x.takes[0] == take, "a part implied")
	// Split at beat 2: two regions, the sound the same (a short fade at the cut).
	pm.split_at(m, 0, 1, 2)
	x = pm.part_of(p, 0, 1)
	testing.expect_value(t, x.count, 2)
	testing.expect_value(t, app.undo_name(&m.history), "Split")
	mix := mix_of(t, m, 1)
	testing.expectf(t, abs(mix[10_000] - 0.1) < 1e-4 && abs(mix[70_000] - 0.7) < 1e-4, "split, as it was (%v, %v)", mix[10_000], mix[70_000])
	// Delete beat 1..2: silent there, the rest where it was.
	pm.delete_range(m, 0, 1, 1, 2)
	mix = mix_of(t, m, 1)
	testing.expectf(t, mix[30_000] == 0 && abs(mix[10_000] - 0.1) < 1e-4 && abs(mix[60_000] - 0.6) < 1e-4, "beat 2 silent (%v)", mix[30_000])
	// Undo: back as split; the take's file never changed.
	app.undo(&m.history)
	mix = mix_of(t, m, 1)
	testing.expectf(t, abs(mix[30_000] - 0.3) < 1e-4, "undone (%v)", mix[30_000])
	if a, ok := pm.sample_audio(m, take); ok do testing.expectf(t, abs(a.channels[0][30_000] - 0.3) < 1e-6, "the file as recorded")
	// Crop to beats 1..3.
	pm.crop_to(m, 0, 1, 1, 3)
	mix = mix_of(t, m, 1)
	testing.expectf(t, mix[10_000] == 0 && mix[80_000] == 0 && abs(mix[40_000] - 0.4) < 1e-4, "cropped (%v %v %v)", mix[10_000], mix[40_000], mix[80_000])
	// Move the region from beat 1 to beat 0 (it plays from frame 24 000 of the take).
	i := pm.region_at(p, 0, 1, 1.5)
	testing.expect(t, i >= 0, "a region at beat 1.5")
	pm.move_region(m, 0, 1, i, 0)
	app.seal(&m.history)
	mix = mix_of(t, m, 1)
	testing.expectf(t, abs(mix[1_000] - 0.25) < 1e-3, "moved: beat 0 plays what was at beat 1 (%v)", mix[1_000])
	// Trim its start in by half a beat.
	i = pm.region_at(p, 0, 1, 0.25)
	pm.trim_region(m, 0, 1, i, 0.5, false)
	app.seal(&m.history)
	mix = mix_of(t, m, 1)
	testing.expectf(t, mix[6_000] == 0 && abs(mix[13_000] - (0.24 + 0.13)) < 1e-3, "trimmed: silent before beat 0.5 (%v, %v)", mix[6_000], mix[13_000])
}

@(test)
fades_gain_pan_reverse_and_normalize :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_shape")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	ramp_clip(r, 1)
	x := pm.part_of(p, 0, 1)
	g := x.regions[0]
	g.fade_in = 0.5 // 24 000 frames
	pm.set_region(m, 0, 1, 0, "Fade In", g)
	app.seal(&m.history)
	mix := mix_of(t, m, 1)
	testing.expectf(t, abs(mix[12_000] - 0.12 * 0.5) < 1e-3, "half way up its fade (%v)", mix[12_000])
	// -6 dB, panned right: the left side quieter.
	g.fade_in = 0
	g.gain, g.pan = -6.0206, 0.5
	pm.set_region(m, 0, 1, 0, "Gain", g)
	a, _ := pm.part_audio(m, 0, 1)
	testing.expectf(t, abs(a.channels[1][50_000] - 0.25) < 1e-3 && abs(a.channels[0][50_000] - 0.125) < 1e-3, "-6 dB, the left half again (%v, %v)", a.channels[0][50_000], a.channels[1][50_000])
	// Reversed: the take's end first.
	g.gain, g.pan, g.reverse = 0, 0, true
	pm.set_region(m, 0, 1, 0, "Reverse", g)
	mix = mix_of(t, m, 1)
	testing.expectf(t, abs(mix[0] - 0.95999) < 1e-3 && mix[95_000] < 0.02, "backwards (%v .. %v)", mix[0], mix[95_000])
	// Normalized: the loudest frame (0.96) at 0 dB.
	pm.normalize_region(m, 0, 1, 0)
	mix = mix_of(t, m, 1)
	peak: f32
	for v in mix do peak = max(peak, abs(v))
	testing.expectf(t, abs(peak - 1) < 1e-3, "normalized (%v)", peak)
	testing.expect_value(t, app.undo_name(&m.history), "Normalize")
}

@(test)
copy_paste_and_comping_takes :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_comp")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	ramp_clip(r, 1)
	// Beat 0..1 copied onto pad 2 at beat 3.
	pm.set_pad_kind(m, 2, .Audio)
	cb := pm.copy_range(m, 0, 1, 0, 1)
	testing.expect_value(t, cb.count, 1)
	testing.expect(t, pm.paste_at(m, 0, 2, cb, 3), "pasted")
	mix := mix_of(t, m, 2)
	testing.expectf(t, mix[24_000] == 0 && abs(mix[72_000 + 12_000] - 0.12) < 1e-3, "beat 3 plays the copied beat (%v)", mix[84_000])
	// A second take on pad 1 (a different ramp, half as steep), comped in for beat 2..3.
	x := pm.part_of(p, 0, 1)
	path, _ := filepath.join({r.dir, "ramp2.wav"}, context.temp_allocator)
	n := 96_000
	v := make([]f32, n, context.temp_allocator)
	for &s, i in v do s = -f32(i) / 200_000
	ws := audiofile.default_writer_settings(SR, 1)
	ws.encoding = .Float32
	w, _ := audiofile.writer_create(path, ws)
	audiofile.writer_write(w, {v}, n)
	audiofile.writer_close(w)
	id := pm.add_sample(m, path, {format = .Wav, encoding = .Float32, sample_rate = SR, channels = 1, frames = i64(n)})
	x.takes[1], x.take_at[1], x.take_count = id, 0, 2
	pm.put_part(m, 0, 1, "Take", x)
	pm.use_take(m, 0, 1, 1, 2, 3)
	mix = mix_of(t, m, 1)
	testing.expectf(t, abs(mix[60_000] + 0.3) < 1e-3 && abs(mix[30_000] - 0.3) < 1e-3 && abs(mix[80_000] - 0.8) < 1e-3, "beat 2 from take 2, the rest from take 1 (%v %v %v)", mix[30_000], mix[60_000], mix[80_000])
	testing.expect_value(t, app.undo_name(&m.history), "Use Take")

	// Saved and opened: the same.
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "audio_comp_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	again := mix_of(t, &r2.m, 1)
	if again != nil do testing.expectf(t, abs(again[60_000] + 0.3) < 1e-3 && abs(again[80_000] - 0.8) < 1e-3, "loaded as saved")
	pasted := mix_of(t, &r2.m, 2)
	if pasted != nil do testing.expectf(t, abs(pasted[84_000] - 0.12) < 1e-3, "the pasted part too")
}

@(test)
an_edited_part_plays_its_rendering :: proc(t: ^testing.T) {
	// The engine plays what part_audio mixes (a rendering made in the
	// background): beat 1..2 deleted is silence while it plays.
	r := rig_make(t, "audio_play_edit")
	defer rig_destroy(r)
	m := &r.m
	ramp_clip(r, 1)
	pm.delete_range(m, 0, 1, 1, 2)
	for _ in 0 ..< 400 {
		render(r, 256)
		if pm.audio_ready(&m.engine) do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, pm.audio_ready(&m.engine), "rendered and buffered")
	pm.play(&m.engine)
	out := render_synced(r, 96_000, 256)
	pm.stop(&m.engine)
	// (Through the pad's strip: its pan law, its fader; compare shapes.)
	at :: proc(x: []f32, i: int) -> f32 { return abs(x[i]) }
	testing.expectf(t, at(out[0], 36_000) < 1e-4, "beat 2 silent (%v)", at(out[0], 36_000))
	testing.expectf(t, at(out[0], 12_000) > 0.05 && at(out[0], 60_000) > 0.3, "the rest plays (%v, %v)", at(out[0], 12_000), at(out[0], 60_000))
	_ = math.PI
}

@(test)
consolidate_and_spread_takes :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_consolidate")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	ramp_clip(r, 1)
	pm.delete_range(m, 0, 1, 1, 2)
	before := mix_of(t, m, 1)
	testing.expect(t, pm.consolidate(m, 0, 1), "consolidated")
	testing.expect_value(t, app.undo_name(&m.history), "Consolidate")
	x := pm.part_of(p, 0, 1)
	testing.expect(t, x.count == 1 && x.take_count == 2, "one region of a new take, the old one kept")
	after := mix_of(t, m, 1)
	if before != nil && after != nil {
		testing.expectf(t, after[30_000] == 0 && abs(after[60_000] - before[60_000]) < 1e-6, "as it played")
	}
	// Two takes spread: the second onto the next empty pad (pad 0 is
	// empty: it wraps round to it after the last).
	path, _ := filepath.join({r.dir, "ramp2.wav"}, context.temp_allocator)
	_ = path
	ramp_clip(r, 2, "other.wav")
	y := pm.part_of(p, 0, 2)
	y.takes[1], y.take_at[1], y.take_count = x.takes[0], 0, 2
	pm.put_part(m, 0, 2, "Take", y)
	made := pm.spread_takes(m, 0, 2)
	testing.expect_value(t, len(made), 1)
	if len(made) == 1 {
		to := made[0]
		testing.expect_value(t, p.pads[to].kind, pm.Pad_Kind.Audio)
		z := pm.part_of(p, 0, to)
		testing.expect(t, z.take_count == 1 && z.takes[0] == x.takes[0], "its take")
		testing.expect_value(t, pm.part_of(p, 0, 2).take_count, 1)
	}
	testing.expect_value(t, app.undo_name(&m.history), "Spread Takes")
	app.undo(&m.history)
	testing.expect_value(t, pm.part_of(p, 0, 2).take_count, 2)
}

@(test)
pasting_past_the_end_is_cut_there :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_paste_end")
	defer rig_destroy(r)
	m := &r.m
	ramp_clip(r, 1)
	cb := pm.copy_range(m, 0, 1, 0, 4)
	testing.expect(t, pm.paste_at(m, 0, 1, cb, 2), "pasted")
	mix := mix_of(t, m, 1)
	if mix != nil do testing.expectf(t, abs(mix[48_000 + 1000] - 0.01) < 1e-3 && abs(mix[10_000] - 0.1) < 1e-3, "beat 2 on: the take from its top (%v)", mix[49_000])
}

@(test)
a_loop_file_copied_and_pasted :: proc(t: ^testing.T) {
	r := rig_make(t, "audio_paste_loop")
	defer rig_destroy(r)
	m := &r.m
	pm.set_pad_kind(m, 1, .Audio)
	path, _ := filepath.abs("tests/app_ui/fixtures/loop.wav", context.temp_allocator)
	testing.expect_value(t, pm.add_take_file(m, 0, 1, path), fc.Error.None)
	x := pm.part_of(&m.project, 0, 1)
	testing.expect_value(t, x.count, 1)
	cb := pm.copy_range(m, 0, 1, 0, 4)
	testing.expect(t, pm.paste_at(m, 0, 1, cb, 2), "pasted")
	mix_of(t, m, 1)
	render(r, 4800)
}
