package test_pads_model

import "core:math"
import "core:testing"
import app "app:core"
import "fire:audiofile"
import pm "../../apps/pads/model"

// Records `frames` of the sequence playing with pad `track` armed, and
// returns its take's first channel (nil if none came).
@(private)
record_take :: proc(t: ^testing.T, r: ^Rig, track, frames: int) -> []f32 {
	m := &r.m
	pm.arm_track(m, track, true)
	render(r, 512)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	for done := 0; done < frames; done += 256 do render(r, 256)
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	render(r, 512)
	cl := poll_clip(r, &c, 0, track)
	s := app.store_get(&m.project.samples, cl.sample)
	if !testing.expect(t, s != nil, "a take") do return nil
	rd, err := audiofile.open(s.path, context.temp_allocator)
	if !testing.expect_value(t, err, audiofile.Error.None) do return nil
	defer audiofile.close(rd)
	take := make([]f32, int(s.frames), context.temp_allocator)
	other := make([]f32, int(s.frames), context.temp_allocator)
	audiofile.read(rd, {take, other}, len(take))
	return take
}

@(private)
first_above :: proc(x: []f32, from: int, level: f32 = 0.02) -> int {
	for v, i in x[from:] do if abs(v) > level do return from + i
	return -1
}

@(test)
resampling_main_lines_up_after_the_effects_latency :: proc(t: ^testing.T) {
	// Pad 0 plays two hits through a limiter (its look-ahead delays it);
	// pad 1, an audio track whose input is main, records them. Its take
	// has the hits on the frames the sequencer played them, not the
	// limiter's latency later.
	r := rig_make(t, "resample_main")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "hit.wav", 440, 0.05, decay = true))
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 2.5, length = 0.25, pad = 0, velocity = 1})
	pm.set_insert(m, 0, 0, pm.new_effect(.Limiter))
	pm.set_pad_kind(m, 1, .Audio)
	p := m.project.pads[1]
	p.input = {from = .Main}
	pm.set_pad(m, 1, .Input, "Set Input", p)
	render(r, 512)
	lat := pm.track_latency(&m.engine, 0)
	testing.expectf(t, lat > 0, "the limiter has latency (%d)", lat)
	take := record_take(t, r, 1, int(2 * SR))
	if take == nil do return
	testing.expect_value(t, pm.take_latency(&m.engine, 1), lat)
	// (The offline frames of these hits: they cross the threshold 6 in.)
	for want in ([]int{24_006, 60_006}) {
		got := first_above(take, want - 12_000)
		testing.expectf(t, got == want, "a hit at frame %d of the take (%d)", want, got)
	}
}

@(test)
resampling_a_track_takes_only_that_track :: proc(t: ^testing.T) {
	// Pads 0 and 2 both play; pad 1 takes pad 0 alone, then bus 1 with
	// only pad 2 on it.
	r := rig_make(t, "resample_track")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "a.wav", 440, 0.05, decay = true))
	pm.load_onto_pad(m, 2, tone(r, "b.wav", 440, 0.05, decay = true))
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 3, length = 0.25, pad = 2, velocity = 1})
	pm.set_pad_kind(m, 1, .Audio)
	p := m.project.pads[1]
	p.input = {from = .Pad, source = 0}
	pm.set_pad(m, 1, .Input, "Set Input", p)
	take := record_take(t, r, 1, int(2 * SR))
	if take == nil do return
	testing.expect_value(t, first_above(take, 0), 24_006)
	testing.expectf(t, first_above(take, 48_000) < 0, "pad 2 isn't in it (%d)", first_above(take, 48_000))

	// Bus 1: pad 2 alone.
	pm.set_clip(m, 0, 1, "Clear", {}) // (the next take is waited for)
	b := m.project.pads[2]
	b.bus = 1
	pm.set_pad(m, 2, .Bus, "Bus", b)
	p = m.project.pads[1]
	p.input = {from = .Bus, source = 0}
	pm.set_pad(m, 1, .Input, "Set Input", p)
	take = record_take(t, r, 1, int(2 * SR))
	if take == nil do return
	testing.expectf(t, first_above(take, 0) == 72_006, "only pad 2's hit, where it was played (%d)", first_above(take, 0))
}

// Renders an export to its end and finishes it.
@(private)
run_export :: proc(m: ^pm.Model, x: ^pm.Export) {
	for !x.finished && !x.failed do pm.export_step(m, x)
	pm.export_finish(m, x)
}

// The peak of a sample's first channel, and its length.
@(private)
sample_peak :: proc(t: ^testing.T, m: ^pm.Model, id: app.Id) -> (peak: f32, frames: i64) {
	s := app.store_get(&m.project.samples, id)
	if !testing.expect(t, s != nil, "a sample") do return
	rd, err := audiofile.open(s.path, context.temp_allocator)
	if !testing.expect_value(t, err, audiofile.Error.None) do return
	defer audiofile.close(rd)
	a := make([]f32, int(s.frames), context.temp_allocator)
	b := make([]f32, int(s.frames), context.temp_allocator)
	audiofile.read(rd, {a, b}, len(a))
	for v in a do peak = max(peak, abs(v))
	return peak, s.frames
}

@(test)
bouncing_pads_or_a_bus_makes_a_new_pad :: proc(t: ^testing.T) {
	// Pad 0 at -6 dB and pad 1 both play; main is turned down 12 dB. A
	// bounce of pad 0 is pad 0 alone, after its fader, before main's: on
	// the next empty pad (2), named, one undo step.
	r := blips(t, "bounce_pads")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 2, length = 0.25, pad = 1, velocity = 1})
	pd := p.pads[0]
	pd.volume = -6
	pm.set_pad(m, 0, .Volume, "Set Volume", pd)
	mb := p.main
	mb.volume = -12
	pm.set_bus(m, pm.BUSES, 0, "Set Volume", mb)
	app.seal(&m.history)
	render(r, 4800) // (faders glide to where they are set)
	x: pm.Export
	defer pm.export_destroy(&x)
	if !testing.expect(t, pm.bounce_pads(m, &x, {0})) do return
	run_export(m, &x)
	testing.expect_value(t, x.to_pad, 2)
	testing.expect(t, p.pads[2].sample != 0, "a sample on pad 3")
	testing.expect_value(t, pm.pad_name(&p.pads[2]), "Bounce A1")
	testing.expect_value(t, app.undo_name(&m.history), "Bounce to Pad")
	peak, frames := sample_peak(t, m, p.pads[2].sample)
	testing.expect_value(t, frames, i64(96_000)) // the sequence, once
	solo, _ := sample_peak(t, m, p.pads[0].sample)
	testing.expectf(t, abs(20 * math10(peak / solo) + 6) < 0.5, "pad 0 at its fader's -6 dB, main's -12 not in it (%v of %v)", peak, solo)
	// Nothing of pad 1 (its blip is at beat 2: frame 48 000 on).
	if s := app.store_get(&p.samples, p.pads[2].sample); s != nil {
		rd, _ := audiofile.open(s.path, context.temp_allocator)
		a := make([]f32, int(s.frames), context.temp_allocator)
		b := make([]f32, int(s.frames), context.temp_allocator)
		audiofile.read(rd, {a, b}, len(a))
		audiofile.close(rd)
		late: f32
		for v in a[48_000:] do late = max(late, abs(v))
		testing.expectf(t, late < 1e-4, "pad 1 isn't in it (%v)", late)
	}
	app.undo(&m.history)
	testing.expect_value(t, p.pads[2].sample, app.Id(0))

	// A bus: pad 1 on bus 1, through its fader (-6 dB).
	b1 := p.pads[1]
	b1.bus = 1
	pm.set_pad(m, 1, .Bus, "Bus", b1)
	bus := p.buses[0]
	bus.volume = -6
	pm.set_bus(m, 0, 0, "Set Volume", bus)
	app.seal(&m.history)
	render(r, 4800)
	pm.export_destroy(&x)
	if !testing.expect(t, pm.bounce_bus(m, &x, 0)) do return
	run_export(m, &x)
	testing.expect_value(t, x.to_pad, 2)
	bpk, _ := sample_peak(t, m, p.pads[2].sample)
	one, _ := sample_peak(t, m, p.pads[1].sample)
	testing.expectf(t, abs(20 * math10(bpk / one) + 6) < 0.5, "bus 1's pad at its -6 dB (%v of %v)", bpk, one)
	testing.expect(t, !pm.bounce_bus(m, &x, 3), "an empty bus has nothing to bounce")
}

@(test)
bouncing_in_place_makes_an_audio_track_that_sounds_the_same :: proc(t: ^testing.T) {
	r := blips(t, "bounce_in_place")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 1, velocity = 1})
	pd := p.pads[1]
	pd.volume = -9
	pd.pan = -0.5
	pm.set_pad(m, 1, .Volume, "Set Volume", pd)
	app.seal(&m.history)
	play_out :: proc(r: ^Rig) -> [2][]f32 {
		render(r, 4800)
		pm.play(&r.m.engine)
		out := render_synced(r, 48_000 * 2, 480)
		pm.stop(&r.m.engine)
		render(r, 480)
		return out
	}
	before := play_out(r)
	testing.expect(t, pm.can_bounce_in_place(p, 1) && !pm.can_bounce_in_place(p, 0), "pad 0 has no notes")
	x: pm.Export
	defer pm.export_destroy(&x)
	if !testing.expect(t, pm.bounce_in_place_begin(m, &x, 1)) do return
	run_export(m, &x)
	to := x.made
	testing.expect_value(t, to, 2) // the next empty pad after it
	testing.expect_value(t, app.undo_name(&m.history), "Bounce in Place")
	testing.expect(t, p.pads[1].mute && !p.pads[1].frozen, "the pad muted")
	testing.expect_value(t, p.pads[to].kind, pm.Pad_Kind.Audio)
	testing.expect_value(t, p.pads[to].volume, f32(-9))
	testing.expect(t, p.clips[0][to].sample != 0, "its take in sequence 1")
	testing.expect_value(t, pm.pad_name(&p.pads[to]), "blip2 (bounced)")
	for _ in 0 ..< 400 {
		render(r, 256)
		if pm.audio_ready(&m.engine) do break
	}
	after := play_out(r)
	for c in 0 ..< 2 {
		a, b: f32
		for v in before[c] do a = max(a, abs(v))
		for v in after[c] do b = max(b, abs(v))
		testing.expectf(t, a > 0.01 && abs(20 * math10(b / a)) < 0.5, "channel %d as loud as before (%v, %v)", c, a, b)
	}
	app.undo(&m.history)
	testing.expect(t, !p.pads[1].mute && !pm.pad_used(p, to), "undone")
}

@(private)
math10 :: proc(x: f32) -> f32 {
	return f32(math.log10(f64(max(x, 1e-9))))
}
