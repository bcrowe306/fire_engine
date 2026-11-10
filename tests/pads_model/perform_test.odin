package test_pads_model

import "core:log"
import "core:path/filepath"
import "core:time"
import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"
import "fire:clip"
import kit "fire:testkit"

@(test)
the_arpeggiator_plays_a_held_chord_on_the_grid :: proc(t: ^testing.T) {
	r := blips(t, "perf_arp")
	defer rig_destroy(r)
	m := &r.m
	p := m.project.perform
	p.arp_on, p.arp = true, {mode = .Up, rate = .Sixteenth}
	pm.set_perform(m, p)
	pm.sync(&m.engine)
	render(r, 512)
	// A keyboard chord on pad 0: C, E, G above its pitch.
	for pitch in ([]i8{0, 4, 7}) do pm.hit(&m.engine, 0, true, 0.9, pitch, keyboard = true)
	out := render(r, 48_000) // 8 sixteenths
	got := onsets(out[0][:])
	testing.expectf(t, len(got) >= 7 && len(got) <= 9, "a note a sixteenth (%v)", got)
	for i in 1 ..< len(got) do testing.expectf(t, abs(got[i] - got[i - 1] - 6000) <= 1, "6000 frames apart (%v)", got)
	// The third step is the fifth: 440 × 1.5 Hz.
	if len(got) >= 3 {
		seg := out[0][got[2]:][:2400]
		testing.expectf(t, kit.tone_amplitude(seg, SR, 660) > kit.tone_amplitude(seg, SR, 440), "the third note is G")
	}
	for pitch in ([]i8{0, 4, 7}) do pm.hit(&m.engine, 0, false, 0, pitch, keyboard = true)
	render(r, 12_000)
	quiet := render(r, 24_000)
	testing.expectf(t, kit.peak(quiet[0][:]) == 0, "stops when the keys are up")
}

@(test)
note_repeat_retriggers_a_held_pad :: proc(t: ^testing.T) {
	r := blips(t, "perf_repeat")
	defer rig_destroy(r)
	m := &r.m
	p := m.project.perform
	p.repeat_on, p.repeat = true, {rate = .Eighth}
	pm.set_perform(m, p)
	pm.sync(&m.engine)
	render(r, 512)
	pm.hit(&m.engine, 1, true)
	out := render(r, 48_000) // 4 eighths
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 4 || len(got) == 5, "an eighth apart (%v)", got)
	pm.hit(&m.engine, 1, false)
	p.repeat_on = false
	pm.set_perform(m, p)
	pm.sync(&m.engine)
	render(r, 12_000)
	quiet := render(r, 24_000)
	testing.expect_value(t, kit.peak(quiet[0][:]), 0)
}

@(test)
keyboard_hits_play_the_pad_pitched :: proc(t: ^testing.T) {
	r := rig_make(t, "perf_keys")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "a.wav", 440, 1))
	render(r, 256)
	pm.hit(&m.engine, 0, true, 1, 12, keyboard = true) // an octave up
	out := render(r, 9600)
	seg := out[0][4800:]
	testing.expectf(t, kit.tone_amplitude(seg, SR, 880) > 0.2 && kit.tone_amplitude(seg, SR, 440) < 0.05, "880 Hz")
	// Scales: the bottom-left pad is the root; major degrees; a triad.
	k := pm.Keys{scale = .Major}
	pitches: [4]int
	testing.expect_value(t, pm.keyboard_pitches(k, 12, &pitches)[0], 0)
	testing.expect_value(t, pm.keyboard_pitches(k, 13, &pitches)[0], 2)
	testing.expect_value(t, pm.keyboard_pitches(k, 8, &pitches)[0], 7) // second row from the bottom: degree 4
	testing.expect_value(t, pm.degree_pitch(k, 7), 12)
	k.chord = .Triad
	triad := pm.keyboard_pitches(k, 12, &pitches)
	testing.expect(t, len(triad) == 3 && triad[1] == 4 && triad[2] == 7, "C major")
	k.root, k.scale = 9, .Minor // A minor
	triad = pm.keyboard_pitches(k, 12, &pitches)
	testing.expect(t, triad[0] == 9 && triad[1] == 12 && triad[2] == 16, "A minor")
	testing.expect_value(t, pm.velocity_of_pad(12), 1.0 / 16)
	testing.expect_value(t, pm.velocity_of_pad(3), 1)
}

@(test)
midi_in_plays_pads_and_learns :: proc(t: ^testing.T) {
	r := blips(t, "perf_midi")
	defer rig_destroy(r)
	m := &r.m
	c: pm.Capture
	defer pm.capture_destroy(&c)
	app.host_midi_inject(&r.host, {0x90, 36, 100}) // key 36: A1
	out := render(r, 4800)
	testing.expect(t, kit.peak(out[0][:]) > 0.1, "key 36 plays A1")
	pm.capture_poll(m, &c)
	testing.expect_value(t, c.midi_key, 36)
	app.host_midi_inject(&r.host, {0x80, 36, 0})
	render(r, 9600)
	// Learn key 50 for pad 1 (an octave up): it plays it, undoably.
	pm.learn_midi(m, 50, 1)
	testing.expect_value(t, pm.midi_key_of(m, 1), 37) // its own key comes first
	pm.sync(&m.engine)
	app.host_midi_inject(&r.host, {0x90, 50, 100})
	out = render(r, 3000)
	testing.expectf(t, kit.tone_amplitude(out[0][:], SR, 880) > kit.tone_amplitude(out[0][:], SR, 440), "key 50 plays pad 1")
	app.undo(&m.history)
	testing.expect_value(t, m.project.midi_map[50], 50 - 36)
	// MIDI out: pad 0's hits go out as MIDI.
	pad := m.project.pads[0]
	pad.midi_out = {on = true, channel = 9, key = 42}
	pm.set_pad(m, 0, .Whole, "MIDI Out", pad)
	pm.sync(&m.engine)
	sent0, _ := app.host_midi_counts(&r.host)
	pm.hit(&m.engine, 0, true)
	render(r, 512)
	pm.hit(&m.engine, 0, false)
	render(r, 512)
	sent, received := app.host_midi_counts(&r.host)
	testing.expectf(t, sent - sent0 == 2, "a note-on and a note-off went out (%d)", sent - sent0)
	testing.expect(t, received >= 3, "and the MIDI came in")
}

@(test)
automation_moves_a_pads_volume_over_the_sequence :: proc(t: ^testing.T) {
	r := rig_make(t, "perf_auto")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "long.wav", 440, 3))
	pm.add_note(m, 0, {start = 0, length = 4, pad = 0, velocity = 1})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 0, value = -40})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 4, value = 0})
	points, _ := pm.lane_points(pm.current_sequence(m), 0, .Volume)
	testing.expect_value(t, len(points), 2)
	pm.sync(&m.engine)
	render(r, 512)
	pm.play(&m.engine)
	out := render(r, 96_000) // 4 beats
	early := kit.peak(out[0][4800:][:4800])
	late := kit.peak(out[0][84_000:][:4800])
	testing.expectf(t, late > early * 20, "rises 40 dB over the bar (%v → %v)", early, late)
	// Stopped, the pad has its own volume again.
	pm.stop(&m.engine)
	pm.sync(&m.engine)
	render(r, 48_000)
	pm.hit(&m.engine, 0, true)
	again := render(r, 9600)
	testing.expectf(t, abs(kit.peak(again[0][4800:]) - 0.5) < 0.05, "full level after the stop (%v)", kit.peak(again[0][4800:]))
	app.undo(&m.history)
	points, _ = pm.lane_points(pm.current_sequence(m), 0, .Volume)
	testing.expect_value(t, len(points), 1)
}

@(test)
a_midi_file_becomes_a_sequence :: proc(t: ^testing.T) {
	r := rig_make(t, "perf_import")
	defer rig_destroy(r)
	m := &r.m
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 8)
	clip.add_note(&b, 0, 0.5, 36, 0.9) // A1
	clip.add_note(&b, 1, 0.5, 38, 0.7) // A3
	clip.add_note(&b, 6, 0.5, 20, 0.7) // below the pads: skipped
	c, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	defer clip.midi_clip_release(c)
	path, _ := filepath.join({r.dir, "beat.mid"}, context.temp_allocator)
	testing.expect_value(t, clip.midi_file_write(path, {{name = "drums", clip = c}}), clip.File_Error.None)
	testing.expect_value(t, pm.import_midi(m, path, 3), 2)
	s := m.project.sequences[3]
	testing.expect_value(t, s.bars, 2)
	testing.expect(t, s.notes[0].pad == 0 && s.notes[1].pad == 2 && s.notes[1].start == 1, "on their pads")
	// On one pad, pitched.
	testing.expect_value(t, pm.import_midi(m, path, 4, .On_Pad, 5), 3)
	n := m.project.sequences[4].notes[0]
	testing.expect(t, n.pad == 5 && n.pitch == 36 - 60, "pitched from C3")
	testing.expect_value(t, app.undo_name(&m.history), "Import MIDI")
}

// What the engine costs on the audio thread: 8 pads in a busy sequence,
// with automation and the arpeggiator on (logged; the bound only catches
// something gone badly wrong).
@(test)
engine_timing :: proc(t: ^testing.T) {
	r := rig_make(t, "perf_timing")
	defer rig_destroy(r)
	m := &r.m
	for i in 0 ..< 8 do pm.load_onto_pad(m, i, tone(r, "t.wav", 220 + 55 * f64(i), 0.3, decay = true))
	for k in 0 ..< 64 do pm.add_note(m, 0, {start = f64(k) * 0.25, length = 0.2, pad = u8(k % 8), velocity = 0.8})
	pm.set_bars(m, 0, 4)
	for i in 0 ..< 8 do pm.add_point(m, 0, {pad = u8(i), param = .Volume, beat = 0, value = -6})
	p := m.project.perform
	p.arp_on = true
	pm.set_perform(m, p)
	pm.sync(&m.engine)
	render(r, 512)
	pm.play(&m.engine)
	pm.hit(&m.engine, 0, true, 1, 0, keyboard = true)
	pm.hit(&m.engine, 0, true, 1, 7, keyboard = true)
	frames := 48_000 * 10
	t0 := time.tick_now()
	render(r, frames)
	secs := time.duration_seconds(time.tick_since(t0))
	log.infof("engine: 10 s rendered in %.1f ms (%.0f× real time; %.1f%% of one core)", secs * 1000, 10 / secs, secs * 10)
	// Faster than real time even on a small, busy test machine (tests run
	// in parallel); about 30× on an M-series Mac.
	when ODIN_OPTIMIZATION_MODE != .None {
		testing.expectf(t, 10 / secs > 1.5, "faster than real time (%.1f×)", 10 / secs)
	}
}
