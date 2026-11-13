package test_pads_model

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:time"
import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"
import "fire:clip"
import fc "fire:core"
import kit "fire:testkit"

@(test)
the_arpeggiator_plays_a_held_chord_on_the_grid :: proc(t: ^testing.T) {
	r := blips(t, "perf_arp")
	defer rig_destroy(r)
	m := &r.m
	p := m.project.pads[0].midi_fx
	p.arp_on, p.arp = true, {mode = .Up, rate = .Sixteenth}
	pm.set_midi_fx(m, 0, p)
	pm.sync(&m.engine)
	render(r, 512)
	// A keyboard chord on pad 0: C, E, G above its pitch.
	for pitch in ([]i8{0, 4, 7}) do pm.hit(&m.engine, 0, true, 0.9, pitch, keyboard = true)
	out := render(r, 48_000) // 8 sixteenths
	got := onsets(out[0][:])
	testing.expectf(t, len(got) >= 7 && len(got) <= 9, "a note a sixteenth (%v)", got)
	// (Found by a level crossed: each pitch's waveform crosses it a frame or
	// two sooner or later after its envelope starts, on the grid.)
	for i in 1 ..< len(got) do testing.expectf(t, abs(got[i] - got[i - 1] - 6000) <= 3, "6000 frames apart (%v)", got)
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
	p := m.project.pads[1].midi_fx
	p.repeat_on, p.repeat = true, {rate = .Eighth}
	pm.set_midi_fx(m, 1, p)
	pm.sync(&m.engine)
	render(r, 512)
	pm.hit(&m.engine, 1, true)
	out := render(r, 48_000) // 4 eighths
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 4 || len(got) == 5, "an eighth apart (%v)", got)
	pm.hit(&m.engine, 1, false)
	render(r, 12_000)
	// Pad 0 has none: held, it plays once.
	pm.hit(&m.engine, 0, true)
	out = render(r, 48_000)
	pm.hit(&m.engine, 0, false)
	got = onsets(out[0][:])
	testing.expectf(t, len(got) == 1, "pad 0 is not repeated (%v)", got)
	p.repeat_on = false
	pm.set_midi_fx(m, 1, p)
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
	testing.expect_value(t, pm.keyboard_pitches(k, 0, &pitches)[0], 0) // pad 1, bottom left
	testing.expect_value(t, pm.keyboard_pitches(k, 1, &pitches)[0], 2)
	testing.expect_value(t, pm.keyboard_pitches(k, 4, &pitches)[0], 7) // second row from the bottom: degree 4
	testing.expect_value(t, pm.degree_pitch(k, 7), 12)
	k.chord = .Triad
	triad := pm.keyboard_pitches(k, 0, &pitches)
	testing.expect(t, len(triad) == 3 && triad[1] == 4 && triad[2] == 7, "C major")
	k.root, k.scale = 9, .Minor // A minor
	triad = pm.keyboard_pitches(k, 0, &pitches)
	testing.expect(t, triad[0] == 9 && triad[1] == 12 && triad[2] == 16, "A minor")
	testing.expect_value(t, pm.velocity_of_pad(0), 1.0 / 16) // pad 1, bottom left: softest
	testing.expect_value(t, pm.velocity_of_pad(15), 1)       // pad 16, top right
}

@(test)
midi_in_plays_pads_and_learns :: proc(t: ^testing.T) {
	r := blips(t, "perf_midi")
	defer rig_destroy(r)
	m := &r.m
	c: pm.Capture
	defer pm.capture_destroy(&c)
	app.host_midi_inject(&r.host, {0x90, 0, 100}) // key 0: A1 (note N plays pad N)
	out := render(r, 4800)
	testing.expect(t, kit.peak(out[0][:]) > 0.1, "key 0 plays A1")
	pm.capture_poll(m, &c)
	testing.expect_value(t, c.midi_key, 0)
	app.host_midi_inject(&r.host, {0x80, 0, 0})
	render(r, 9600)
	// Learn key 50 for pad 1: it plays it, undoably.
	pm.learn_midi(m, 50, 1)
	testing.expect_value(t, pm.midi_key_of(m, 1), 1) // its own key comes first
	pm.sync(&m.engine)
	app.host_midi_inject(&r.host, {0x90, 50, 100})
	out = render(r, 3000)
	testing.expectf(t, kit.tone_amplitude(out[0][:], SR, 880) > kit.tone_amplitude(out[0][:], SR, 440), "key 50 plays pad 1")
	app.undo(&m.history)
	testing.expect_value(t, m.project.midi_map[50], 50) // pad 50's again
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
	if werr := clip.midi_file_write(path, {{name = "drums", clip = c}}); werr != .None {
		// Seen now and then on the Linux machine: say why the system refused.
		probe := os.write_entire_file(path, []u8{0})
		log.errorf("writing %s failed (%v); a plain write: %v; the folder exists: %v", path, werr, probe, os.is_dir(r.dir))
		testing.fail(t)
		return
	}
	testing.expect_value(t, pm.import_midi(m, path, 3), 2) // as General MIDI drums
	s := m.project.sequences[3]
	testing.expect_value(t, s.bars, 2)
	testing.expect(t, s.notes[0].pad == 0 && s.notes[1].pad == 2 && s.notes[1].start == 1, "on their pads")
	// By the MIDI map: key N is pad N (all three keys have a pad).
	testing.expect_value(t, pm.import_midi(m, path, 5, .By_Map), 3)
	testing.expect(t, m.project.sequences[5].notes[0].pad == 36, "key 36: pad 36 (C5)")
	// On one pad, pitched.
	testing.expect_value(t, pm.import_midi(m, path, 4, .On_Pad, 5), 3)
	n := m.project.sequences[4].notes[0]
	testing.expect(t, n.pad == 5 && n.pitch == 36 - 60, "pitched from C3")
	testing.expect_value(t, app.undo_name(&m.history), "Import MIDI")
}

// What the engine costs on the audio thread: 8 pads in a busy sequence,
// with automation, the arpeggiator, an insert on each pad, and reverb and
// a compressor on main (logged; the bound only catches
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
	p := m.project.pads[0].midi_fx
	p.arp_on = true
	pm.set_midi_fx(m, 0, p)
	// And effects: a low-pass on every pad, reverb and a compressor on main.
	for i in 0 ..< 8 do pm.set_insert(m, i, 0, pm.new_effect(.Low_Pass))
	b := m.project.main
	b.slots[0], b.slots[1] = pm.new_effect(.Reverb), pm.new_effect(.Compressor)
	pm.set_bus(m, pm.BUSES, 9, "Effects", b)
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
	// A measurement (logged): tests run in parallel on small shared
	// machines too, so only something badly wrong fails it. About 19× on
	// an M-series Mac.
	when ODIN_OPTIMIZATION_MODE != .None {
		testing.expectf(t, 10 / secs > 0.5, "at least half real time (%.1f×)", 10 / secs)
	}
}

// A track's own MIDI input: armed, notes from its port play it
// chromatically (and record, pitched), not the drum map's pad; unarmed,
// they don't; a track that takes no MIDI ignores the drum map too; and its
// activity is counted.
@(test)
a_tracks_midi_input_plays_it_when_armed :: proc(t: ^testing.T) {
	r := blips(t, "perf_track_midi")
	defer rig_destroy(r)
	m := &r.m
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pad := m.project.pads[1]
	pad.midi_in = {mode = .Port, port = "keys"}
	pm.set_pad(m, 1, .Midi_In, "MIDI In", pad)
	pm.sync(&m.engine)
	m.engine.router.in_port[1] = 2 // (the test host has no ports: say "keys" is input 2)
	// Not armed: port 2's E3 plays nothing (the drum map's pad 64 is empty).
	app.host_midi_inject(&r.host, {0x90, 64, 100}, port = 2)
	out := render(r, 4800)
	testing.expectf(t, kit.peak(out[0][:]) < 1e-3, "unarmed: silent (%v)", kit.peak(out[0][:]))
	app.host_midi_inject(&r.host, {0x80, 64, 0}, port = 2)
	render(r, 2400)
	// Armed: E3 plays pad 1 four semitones up (880 Hz × 2^(4/12)).
	pm.arm_track(m, 1, true)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	render(r, 2400)
	app.host_midi_inject(&r.host, {0x90, 64, 100}, port = 2)
	out = render(r, 3000)
	up := 880 * math.pow(2, 4.0 / 12)
	testing.expectf(t, kit.tone_amplitude(out[0][:], SR, up) > 4 * kit.tone_amplitude(out[0][:], SR, 880), "pad 1, pitched up")
	app.host_midi_inject(&r.host, {0x80, 64, 0}, port = 2)
	render(r, 2400)
	pm.capture_arm(m, &c, false)
	notes := m.project.sequences[0].notes
	testing.expectf(t, len(notes) == 1 && notes[0].pad == 1 && notes[0].pitch == 4, "recorded on pad 1, pitched: %v", notes)
	received, _ := pm.midi_activity(&m.engine, 1)
	testing.expect_value(t, received, 1)
	// Pad 0 takes no MIDI: the drum map's key 0 leaves it silent.
	p0 := m.project.pads[0]
	p0.midi_in.mode = .None
	pm.set_pad(m, 0, .Midi_In, "MIDI In", p0)
	pm.stop(&m.engine)
	pm.sync(&m.engine)
	render(r, 4800)
	app.host_midi_inject(&r.host, {0x90, 0, 100})
	out = render(r, 4800)
	testing.expectf(t, kit.peak(out[0][:]) < 1e-3, "no MIDI: silent (%v)", kit.peak(out[0][:]))
}

@(test)
automation_of_any_parameter_moves_main_and_is_saved :: proc(t: ^testing.T) {
	r := rig_make(t, "perf_target")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "long.wav", 440, 3))
	pm.add_note(m, 0, {start = 0, length = 4, pad = 0, velocity = 1})
	main := pm.Auto_Target{track = .Main, device = .Volume, lo = -60, hi = 6}
	pm.add_point(m, 0, {lane = {target = main}, beat = 0, value = -40})
	pm.add_point(m, 0, {lane = {target = main}, beat = 4, value = 0})
	points, _ := pm.lane_points_of(pm.current_sequence(m), {target = main})
	testing.expect_value(t, len(points), 2)
	// (Not a pad's own lane.)
	own, _ := pm.lane_points(pm.current_sequence(m), 0, .Volume)
	testing.expect_value(t, len(own), 0)
	pm.sync(&m.engine)
	render(r, 512)
	pm.play(&m.engine)
	out := render(r, 96_000) // 4 beats
	early := kit.peak(out[0][4800:][:4800])
	late := kit.peak(out[0][84_000:][:4800])
	testing.expectf(t, late > early * 20, "main rises 40 dB over the bar (%v → %v)", early, late)
	// Stopped, main has its own volume again.
	pm.stop(&m.engine)
	pm.sync(&m.engine)
	render(r, 48_000)
	pm.hit(&m.engine, 0, true)
	again := render(r, 9600)
	testing.expectf(t, abs(kit.peak(again[0][4800:]) - 0.5) < 0.05, "full level after the stop (%v)", kit.peak(again[0][4800:]))
	// Saved and opened: the target comes back.
	path, _ := filepath.join({r.dir, "Target.pads"}, context.temp_allocator)
	testing.expect_value(t, pm.model_save_as(m, path), fc.Error.None)
	r2 := rig_make(t, "perf_target_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, path), fc.Error.None)
	back, _ := pm.lane_points_of(r2.m.project.sequences[0], {target = main})
	testing.expect_value(t, len(back), 2)
	if len(back) == 2 do testing.expect(t, back[0].target.track == .Main && back[0].target.hi == 6 && back[1].value == 0, "the same target, range and values")
}

@(test)
a_cc_lane_goes_out_as_midi_while_playing :: proc(t: ^testing.T) {
	r := blips(t, "perf_cc")
	defer rig_destroy(r)
	m := &r.m
	pad := m.project.pads[0]
	pad.midi_out = {on = true, channel = 0, key = 36}
	pm.set_pad(m, 0, .Whole, "MIDI Out", pad)
	// CC 74 on pad 0: three steps.
	pm.add_cc(m, 0, {beat = 0, pad = 0, cc = 74, value = 10})
	pm.add_cc(m, 0, {beat = 1, pad = 0, cc = 74, value = 64})
	pm.add_cc(m, 0, {beat = 2, pad = 0, cc = 74, value = 127})
	events, _ := pm.cc_points(pm.current_sequence(m), 0, 74)
	testing.expect_value(t, len(events), 3)
	pm.sync(&m.engine)
	render(r, 512)
	sent0, _ := app.host_midi_counts(&r.host)
	pm.play(&m.engine)
	render(r, 72_000) // 3 beats at 120
	sent, _ := app.host_midi_counts(&r.host)
	testing.expectf(t, sent - sent0 >= 3, "the CC went out (%d messages)", sent - sent0)
	pm.stop(&m.engine)
	// Undone: gone.
	app.undo(&m.history)
	events, _ = pm.cc_points(pm.current_sequence(m), 0, 74)
	testing.expect_value(t, len(events), 2)
}

@(test)
note_repeat_records_every_repeat_on_the_sequences_grid :: proc(t: ^testing.T) {
	// Pad 0 repeats at 1/8 (12000 frames at 120 BPM: its blip has gone
	// quiet by the next). The transport's own grid runs ahead of the
	// sequence (played 7777 frames after the start), yet the repeats fall on
	// the sequence's 1/8s, and each is recorded where it played.
	r := blips(t, "perf_repeat_rec")
	defer rig_destroy(r)
	m := &r.m
	m.project.transport.quantize.on = false
	fx := m.project.pads[0].midi_fx
	fx.repeat_on, fx.repeat = true, {rate = .Eighth, gate = 0.5}
	pm.set_midi_fx(m, 0, fx)
	pm.sync(&m.engine)
	render(r, 7777)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	STEP :: 12000
	BEAT :: 24000.0
	// Pressed 1000 frames after the fifth step (late: it plays at once, the
	// next step a whole 11000 frames on, no stutter); let go 3 steps on.
	now := 4 * STEP + 1000
	render(r, now)
	pm.hit(&m.engine, 0, true, 0.8)
	held := render(r, 3 * STEP)
	pm.hit(&m.engine, 0, false)
	render(r, STEP)
	now += 4 * STEP
	got := onsets(held[0][:])
	want := []int{0, 11000, 23000, 35000}
	testing.expectf(t, len(got) == len(want), "a note at once, then each step (%v)", got)
	for w, i in want do if i < len(got) do testing.expectf(t, abs((got[i] - got[0]) - w) <= 2, "note %d at %d (%v)", i, w, got)
	// Pressed 1000 frames before a step (early: it is that step's note;
	// the step doesn't play it again a moment later).
	to := (now / STEP + 1) * STEP - 1000
	render(r, to - now)
	pm.hit(&m.engine, 0, true, 0.8)
	early := render(r, 2 * STEP)
	pm.hit(&m.engine, 0, false)
	render(r, STEP)
	got = onsets(early[0][:])
	testing.expectf(t, len(got) == 2 && abs((got[1] - got[0]) - (1000 + STEP)) <= 2, "at once, then the step after (%v)", got)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)

	// Recorded: every note the repeat played, where it played; each a gate
	// long (a quarter of a beat; the last, until the key was let go). (The
	// early press, on the next pass, falls before the first: overdubbed,
	// a note over another of its pad would cut it.)
	notes := m.project.sequences[0].notes
	pass := 4 * BEAT // the sequence: a bar
	at :: proc(frame: int, pass: f64) -> f64 { return math.mod(f64(frame), pass) / BEAT }
	want_at := []f64{at(4 * STEP + 1000, pass), 2.5, 3, 3.5, at(to, pass), at(to + 1000 + STEP, pass)}
	testing.expectf(t, len(notes) == len(want_at), "every repeat recorded (%v)", notes)
	for w in want_at {
		found := false
		for n in notes do if n.pad == 0 && abs(n.start - w) < 1e-3 do found = true
		testing.expectf(t, found, "a note at beat %v (%v)", w, notes)
	}
	for n in notes do if abs(n.start - 2.5) < 1e-3 do testing.expectf(t, abs(n.length - 0.25) < 1e-3, "a gate long (%v)", n.length)
	for n in notes do if abs(n.start - 3.5) < 1e-3 do testing.expectf(t, abs(n.length - 1000 / BEAT) < 1e-3, "until let go (%v)", n.length)
}

@(test)
the_arpeggiators_notes_are_recorded :: proc(t: ^testing.T) {
	// A keyboard chord held on pad 0, arpeggiated up at 1/8 while recording:
	// the sequence gets each note it played, its pitch, on the sequence's
	// 1/8s (not the chord itself).
	r := blips(t, "perf_arp_rec")
	defer rig_destroy(r)
	m := &r.m
	m.project.transport.quantize.on = false
	fx := m.project.pads[0].midi_fx
	fx.arp_on, fx.arp = true, {mode = .Up, rate = .Eighth, gate = 0.5}
	pm.set_midi_fx(m, 0, fx)
	pm.sync(&m.engine)
	render(r, 5555)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	render(r, 12_000 + 3000) // just after the second 1/8
	for pitch in ([]i8{0, 4, 7}) do pm.hit(&m.engine, 0, true, 0.9, pitch, keyboard = true)
	render(r, 4 * 12_000)
	for pitch in ([]i8{0, 4, 7}) do pm.hit(&m.engine, 0, false, 0, pitch, keyboard = true)
	render(r, 12_000)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	notes := m.project.sequences[0].notes
	testing.expectf(t, len(notes) == 4, "the four steps it played (%v)", notes)
	pitches := []i8{0, 4, 7, 0}
	for n, i in notes do if i < 4 {
		testing.expectf(t, abs(n.start - (1 + 0.5 * f64(i))) < 1e-3, "note %d on the 1/8 (%v)", i, notes)
		testing.expectf(t, n.pitch == pitches[i], "note %d up the chord (%v)", i, notes)
	}
}

@(test)
the_toolbars_repeat_records_on_its_own_grid :: proc(t: ^testing.T) {
	// The toolbar's note repeat at 1/32 for every pad (pad 0 has none of its
	// own), input quantize on at 1/16: the press, 1000 frames after a 1/32
	// step, goes onto that step (not the 1/16's), and every repeat is kept
	// where it played, none pulled onto the 1/16s (where they'd merge).
	r := blips(t, "perf_repeat_all")
	defer rig_destroy(r)
	m := &r.m
	m.project.transport.quantize = {on = true, grid = .Sixteenth, strength = 1}
	m.engine.repeat_all = true
	m.engine.repeat_all_settings = {rate = .Thirty_Second, gate = 0.5}
	pm.sync(&m.engine)
	render(r, 256)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	STEP :: 3000 // a 1/32 at 120 BPM
	render(r, 9 * STEP + 1000) // (9 × 1/32: between two 1/16s)
	pm.hit(&m.engine, 0, true, 0.8)
	render(r, 4 * STEP)
	pm.hit(&m.engine, 0, false)
	render(r, STEP)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	notes := m.project.sequences[0].notes
	b :: proc(steps: int) -> f64 { return f64(steps) * 0.125 }
	want := []f64{b(9), b(10), b(11), b(12), b(13)}
	testing.expectf(t, len(notes) == len(want), "every repeat (%v)", notes)
	for w in want {
		found := false
		for n in notes do if abs(n.start - w) < 1e-3 do found = true
		testing.expectf(t, found, "a note at beat %v (%v)", w, notes)
	}
	// Quantize uses the repeat's grid while it is on.
	testing.expect_value(t, pm.quantize_grid(&m.engine, .Sixteenth), pm.Grid.Thirty_Second)
	m.engine.repeat_all = false
	testing.expect_value(t, pm.quantize_grid(&m.engine, .Sixteenth), pm.Grid.Sixteenth)
}
