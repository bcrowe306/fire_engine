package test_pads_model

import "core:log"
import "core:os"
import "core:time"
import "core:path/filepath"
import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"
import "fire:audiofile"
import "fire:dsp"
import fc "fire:core"
import kit "fire:testkit"

// A project worth saving: two pads, a sequence with automation, effects,
// a song.
@(private)
busy_project :: proc(r: ^Rig) {
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "kick.wav", 440, 0.08, decay = true))
	pm.load_onto_pad(m, 1, tone(r, "hat.wav", 880, 0.08, decay = true))
	pad := m.project.pads[1]
	pad.volume, pad.pan, pad.mode, pad.choke, pad.bus = -6, 0.25, .Gate, 2, 1
	pad.sends[2] = {level = 0.5, pre = true}
	pad.fade_in, pad.fade_out = 120, 240 // (project file v5)
	pm.set_pad(m, 1, .Whole, "Edit", pad)
	// A pad past the first 64 (banks E–H, project file v3), with its own colour.
	pm.load_onto_pad(m, 100, tone(r, "high.wav", 1320, 0.08, decay = true))
	hp := m.project.pads[100]
	hp.color = 0xc77dff
	pm.set_pad(m, 100, .Color, "Colour", hp)
	pad = m.project.pads[1]
	pm.set_pad(m, 1, .Whole, "Edit", pad)
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 0.9})
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 1, velocity = 0.5, pitch = 7, probability = 0.5})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 0, value = -12})
	pm.set_swing(m, 0, 0.3, .Eighth)
	pm.add_note(m, 2, {start = 0.5, length = 0.25, pad = 1, velocity = 1})
	lp := pm.new_effect(.Low_Pass)
	pm.slot_set(&lp, dsp.FILTER_PARAM_CUTOFF_HZ, 700)
	pm.set_insert(m, 0, 1, lp)
	b := m.project.buses[0]
	b.volume, b.slots[2] = -3, pm.new_effect(.Reverb)
	pm.set_bus(m, 0, 0, "Bus", b)
	pm.song_add(m, 0, repeats = 2)
	pm.song_add(m, 2)
	pm.learn_midi(m, 70, 1)
	m.project.bpm = 97
	p := m.project.perform
	p.arp.mode, p.arp.octaves = .Down, 3
	pm.set_perform(m, p)
}

@(test)
a_project_saves_and_loads_whole :: proc(t: ^testing.T) {
	r := rig_make(t, "proj_save")
	defer rig_destroy(r)
	m := &r.m
	busy_project(r)
	testing.expect(t, pm.model_dirty(m), "changed")
	t0 := time.tick_now()
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	saved := time.duration_milliseconds(time.tick_since(t0))
	testing.expect(t, !pm.model_dirty(m), "saved")
	path, _ := filepath.join({m.project.dir, pm.PROJECT_FILE}, context.temp_allocator)
	testing.expect(t, os.exists(path), "project.fire")
	before := m.project

	// Into another model: everything comes back.
	r2 := rig_make(t, "proj_load")
	defer rig_destroy(r2)
	t0 = time.tick_now()
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	log.infof("project: save %.2f ms, load %.2f ms", saved, time.duration_milliseconds(time.tick_since(t0)))
	p := &r2.m.project
	testing.expect_value(t, p.bpm, 97)
	testing.expect_value(t, app.store_len(&p.samples), 3)
	testing.expect_value(t, pm.pad_name(&p.pads[0]), "kick")
	testing.expect(t, p.pads[1] == before.pads[1], "pad 1 the same")
	testing.expect(t, p.pads[0] == before.pads[0], "pad 0 the same (with its insert)")
	testing.expect(t, p.pads[100] == before.pads[100] && p.pads[100].color == 0xc77dff, "pad 100 (G5) the same")
	s := p.sequences[0]
	testing.expect(t, len(s.notes) == 2 && s.notes[1].pitch == 7 && s.notes[1].probability == 0.5 && s.swing == 0.3 && s.swing_grid == .Eighth, "the sequence")
	testing.expect_value(t, len(s.points), 1)
	testing.expect(t, p.buses[0] == before.buses[0], "bus A")
	testing.expect(t, p.song == before.song, "the song")
	testing.expect_value(t, p.midi_map[70], 1)
	testing.expect(t, p.perform.arp.mode == .Down && p.perform.arp.octaves == 3, "the arpeggiator")
	testing.expect(t, !pm.model_dirty(&r2.m) && len(r2.m.history.undo) == 0, "a fresh history")
	// And it plays.
	pm.play(&r2.m.engine)
	out := render(r2, 24_000)
	testing.expect(t, kit.peak(out[0][:]) > 0.05, "plays")
}

@(test)
save_as_copies_the_samples :: proc(t: ^testing.T) {
	r := rig_make(t, "proj_save_as")
	defer rig_destroy(r)
	m := &r.m
	busy_project(r)
	dir, _ := filepath.join({kit.artifacts_root(), "pads_model", "Copied.pads"}, context.temp_allocator)
	os.remove_all(dir)
	testing.expect_value(t, pm.model_save_as(m, dir), fc.Error.None)
	testing.expect_value(t, m.project.dir, dir)
	samples, _ := filepath.join({dir, "samples"}, context.temp_allocator)
	for it in m.project.samples.items {
		testing.expect(t, filepath.dir(it.value.path) == samples, "inside the new folder")
		testing.expect(t, os.exists(it.value.path), "copied")
	}
	pm.hit(&m.engine, 0, true)
	out := render(r, 4800)
	testing.expect(t, kit.peak(out[0][:]) > 0.05, "still plays")
}

@(test)
exports_mixdown_stems_and_to_a_pad :: proc(t: ^testing.T) {
	r := rig_make(t, "proj_export")
	defer rig_destroy(r)
	m := &r.m
	busy_project(r)
	m.project.bpm = 120
	render(r, 256) // syncs, and waits for the samples to load (a slow machine is still reading them)
	dir := m.project.dir
	// A mixdown of the sequence: 1 bar at 120 = 2 s, plus a 0.5 s tail, at 44.1 kHz, 24-bit.
	mix, _ := filepath.join({dir, "mix.wav"}, context.temp_allocator)
	x: pm.Export
	files := pm.export_all(m, {source = .Sequence, encoding = .Int24, rate = 44_100, tail = 0.5}, mix, &x)
	testing.expect_value(t, len(files), 1)
	pm.export_destroy(&x)
	rd, err := audiofile.open(mix)
	testing.expect_value(t, err, audiofile.Error.None)
	if err == .None {
		info := audiofile.info(rd)
		testing.expect_value(t, info.sample_rate, 44_100)
		testing.expectf(t, abs(info.frames - 110_250) < 20, "2.5 s (%d frames)", info.frames)
		audiofile.close(rd)
	}
	a, _ := pm.read_audio(mix)
	testing.expect(t, kit.peak(a.channels[0]) > 0.05, "not silent")
	// Stems: a file per pad with a sound.
	stems, _ := filepath.join({dir, "stems"}, context.temp_allocator)
	files = pm.export_all(m, {source = .Song, stems = .Pads, encoding = .Float32}, stems, &x)
	testing.expect_value(t, len(files), 3) // pads 0, 1 and 100
	if len(files) == 3 {
		k, _ := pm.read_audio(files[0]) // pad 0 only: 440 Hz
		testing.expect(t, kit.tone_amplitude(k.channels[0][:4800], 48_000, 880) < 0.01, "pad 0's stem has no hat")
	}
	pm.export_destroy(&x)
	// Resample the sequence onto the next empty pad (pad 2).
	testing.expect(t, pm.export_to_pad(m, &x), "started")
	for !x.finished do pm.export_step(m, &x)
	pm.export_finish(m, &x)
	pm.export_destroy(&x)
	testing.expect(t, m.project.pads[2].sample != 0, "a new sample on pad 2")
	testing.expect_value(t, app.undo_name(&m.history), "Resample to Pad")
	testing.expectf(t, abs(pm.pad_sample(m, 2).frames - 96_000) < 10, "one bar (%d)", pm.pad_sample(m, 2).frames)
}
