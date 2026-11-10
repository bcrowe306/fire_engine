package test_pads_model

import "core:testing"

import pm "../../apps/pads/model"
import kit "fire:testkit"

// Renders `frames` frames in blocks, syncing the engine before each (as
// the app does every frame: the sequencer stops, the metronome follows).
@(private)
render_synced :: proc(r: ^Rig, frames: int, block := 2400) -> [2][]f32 {
	out := [2][]f32{make([]f32, frames, context.temp_allocator), make([]f32, frames, context.temp_allocator)}
	for at := 0; at < frames; at += block {
		n := min(block, frames - at)
		x := render(r, n)
		copy(out[0][at:], x[0])
		copy(out[1][at:], x[1])
	}
	return out
}

@(test)
loop_off_plays_a_sequence_once :: proc(t: ^testing.T) {
	r := blips(t, "tr_loop")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	tr := m.project.transport
	tr.loop = false
	pm.set_transport(m, .Loop, "Loop", tr)
	pm.play(&m.engine)
	out := render_synced(r, 48_000 * 4) // 8 beats: the sequence is 4
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 1, "once (%v)", got)
	_, playing := pm.position(&m.engine)
	testing.expect(t, !playing, "it stopped at its end")
}

@(test)
count_in_clicks_first_and_records_after :: proc(t: ^testing.T) {
	r := blips(t, "tr_count")
	defer rig_destroy(r)
	m := &r.m
	m.engine.metronome = true
	tr := m.project.transport
	tr.count_in, tr.metro_rec_only = 1, true
	pm.set_transport(m, .Count_In, "Count-in", tr)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine, count_in = true)
	render(r, 256) // the clock takes the locate on its next block
	beat, playing := pm.timeline_beat(&m.engine)
	testing.expect(t, playing && beat < 0, "counting in from before the top")
	// A bar of clicks (4 at 120 BPM: 2 s), then the sequence.
	out := render_synced(r, 48_000 * 2 - 256)
	got := onsets(out[0][:], 0.01)
	testing.expectf(t, len(got) == 4, "four clicks of count-in (%v)", got)
	// A hit while counting in isn't recorded; one after is, at the top.
	pm.hit(&m.engine, 0, true)
	render(r, 256)
	pm.capture_poll(m, &c)
	testing.expect_value(t, len(m.project.sequences[0].notes), 0)
	pm.hit(&m.engine, 0, false)
	render_synced(r, 4800)
	pm.hit(&m.engine, 0, true)
	render(r, 2400)
	pm.hit(&m.engine, 0, false)
	render(r, 2400)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	testing.expect_value(t, len(m.project.sequences[0].notes), 1)
	// Not recording, "only while recording" keeps it quiet (the sequence
	// emptied: its new note would sound).
	pm.clear_sequence(m, 0)
	pm.stop(&m.engine)
	pm.play(&m.engine)
	render_synced(r, 4800)
	quiet := render_synced(r, 48_000)
	testing.expectf(t, len(onsets(quiet[0][:], 0.01)) == 0, "no clicks when not recording")
}

@(test)
the_metronome_level_and_the_time_signature :: proc(t: ^testing.T) {
	r := rig_make(t, "tr_sig")
	defer rig_destroy(r)
	m := &r.m
	m.engine.metronome = true
	tr := m.project.transport
	tr.time_sig = {3, 4}
	tr.metro_db = -20
	pm.set_transport(m, .Time_Sig, "Time Signature", tr)
	testing.expect_value(t, pm.bar_beats(&m.project), 3)
	testing.expect_value(t, pm.seq_beats(&m.project, m.project.sequences[0]), 3) // a bar of 3/4
	pm.sync(&m.engine)
	render(r, 256)
	pm.play(&m.engine)
	out := render_synced(r, 48_000 * 3) // 6 beats: two bars of 3/4
	got := onsets(out[0][:], 0.005)
	testing.expectf(t, len(got) == 6, "a click a beat (%v)", got)
	// Quieter than the default, and accented on beats 1 and 4 (each bar's first).
	peak := kit.peak(out[0][:])
	testing.expectf(t, peak < 0.15, "-20 dB (%v)", peak)
	if len(got) == 6 {
		hz :: proc(x: []f32) -> f64 {
			n := 0
			for i in 1 ..< len(x) do if (x[i - 1] < 0) != (x[i] < 0) do n += 1
			return f64(n) / 2 / (f64(len(x)) / 48_000)
		}
		first, second, fourth := hz(out[0][got[0]:][:480]), hz(out[0][got[1]:][:480]), hz(out[0][got[3]:][:480])
		testing.expectf(t, first > second * 1.3 && fourth > second * 1.3, "bar starts higher (%v %v %v)", first, second, fourth)
	}
	// Bar.beat.sixteenth at 3/4 and 6/8.
	bar, beat, six := pm.position_of(&m.project, 3.25)
	testing.expect(t, bar == 2 && beat == 1 && six == 2, "beat 3.25 in 3/4: 2.1.2")
	m.project.transport.time_sig = {6, 8}
	bar, beat, six = pm.position_of(&m.project, 1.75)
	testing.expect(t, bar == 1 && beat == 4 && six == 2, "6/8: eighths are its beats (1.75 quarters: the 4th eighth, its 2nd sixteenth)")
}

@(test)
input_quantize_strength_and_swing :: proc(t: ^testing.T) {
	q := pm.Input_Quantize{on = true, grid = .Sixteenth, strength = 1}
	testing.expect_value(t, pm.input_quantize(q, 1.1), 1.0)
	q.strength = 0.5
	testing.expect_value(t, pm.input_quantize(q, 1.1), 1.05) // halfway
	q.strength, q.swing = 1, 1
	off := pm.input_quantize(q, 0.26) // the second sixteenth, swung later
	testing.expectf(t, off > 0.3, "swung (%v)", off)
	testing.expect_value(t, pm.input_quantize(q, 0.49), 0.5) // an on-beat stays put
	q.on = false
	testing.expect_value(t, pm.input_quantize(q, 1.1), 1.1)
}

@(test)
tap_tempo_averages_and_resets :: proc(t: ^testing.T) {
	tt: pm.Tap_Tempo
	testing.expect_value(t, pm.tap(&tt, 0), 0)
	b := pm.tap(&tt, 0.5)
	testing.expectf(t, abs(b - 120) < 0.01, "two taps half a second apart: 120 (%v)", b)
	pm.tap(&tt, 1.0)
	b = pm.tap(&tt, 1.5)
	testing.expectf(t, abs(b - 120) < 0.01, "steady (%v)", b)
	testing.expect_value(t, pm.tap(&tt, 5), 0) // after a pause: again
	b = pm.tap(&tt, 5.6)
	testing.expectf(t, abs(b - 100) < 0.01, "100 (%v)", b)
}

@(test)
the_fourth_tap_starts_a_beat_later :: proc(t: ^testing.T) {
	tt: pm.Tap_Tempo
	for k in 0 ..< 3 do pm.tap(&tt, f64(k) * 0.5)
	testing.expect(t, !pm.tap_start_due(&tt, 10), "not after three")
	b := pm.tap(&tt, 1.5) // the fourth: 120 BPM
	testing.expectf(t, abs(b - 120) < 0.01, "120 (%v)", b)
	testing.expect(t, !pm.tap_start_due(&tt, 1.9), "not yet")
	testing.expect(t, pm.tap_start_due(&tt, 2.0), "a beat after the fourth: where a fifth would be")
	testing.expect(t, !pm.tap_start_due(&tt, 2.1), "once")
	pm.tap(&tt, 2.0) // a fifth: no new start
	testing.expect(t, !pm.tap_start_due(&tt, 9), "only the fourth starts it")
}
