package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:transport"
import pm "../../apps/pads/model"

@(test)
song_clips_play_parts_muted_and_at_the_tempo_lane :: proc(t: ^testing.T) {
	r := blips(t, "song_clips")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1})
	pm.song_add(m, 0) // all of it: 4 beats
	k := pm.song_add(m, 0) // beats 2..3 only, twice (4 beats long)
	c := p.song.clips[k]
	c.start, c.part = 2, 2
	pm.set_song_clip(m, k, c, "Clip Part")
	k = pm.song_add(m, 0) // muted
	c = p.song.clips[k]
	c.mute = true
	pm.set_song_clip(m, k, c, "Mute Clip")
	testing.expect_value(t, pm.song_beats(p), 4 + 4 + 4)
	pl := pm.plan_song(p, 0)
	// Clip 2's first pass plays beats 2 and 3 of the sequence: located at
	// song beat 4.5, the sequence is at beat 2.5.
	_, slot, rel, ok := pm.plan_locate(pl, 4.5)
	testing.expect(t, ok && slot == 0 && abs(rel - 2.5) < 1e-9, "a part of the sequence")
	// The notes played: 4, then 2 + 2, then none (muted).
	p.song_mode = true
	m.engine.seq_dirty = true
	pm.play(&m.engine)
	out := render_synced(r, 48_000 * 6) // 12 beats at 120
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 8, "4 + 2 × 2, the muted clip silent (%v)", got)
	// A tempo point takes over where it is; the song's length in time.
	pm.stop(&m.engine)
	pm.tempo_point_add(m, {beat = 4, bpm = 60})
	testing.expect_value(t, p.song.tempo_count, 2) // (the project's at the start, then 60)
	secs := pm.song_seconds(p)
	testing.expectf(t, abs(secs - (2 + 8)) < 1e-9, "2 s, then 8 beats at 60 (%v)", secs)
	pm.play(&m.engine)
	render_synced(r, 48_000 * 2 + 2400) // past 4 beats at 120
	testing.expect_value(t, transport.status(m.engine.host.clock).tempo_bpm, 60)
}

@(test)
song_lanes_play_together_muted_soloed :: proc(t: ^testing.T) {
	r := blips(t, "song_lanes")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1}) // four
	pm.add_note(m, 1, {start = 0.5, length = 0.25, pad = 0, velocity = 1}) // one, off the beat
	pm.song_add(m, 0, repeats = 2) // lane 1: 8 beats
	pm.song_add(m, 1, lane = 1, at = 4, length = 2) // lane 2: beats 4..6 (the second sequence: 4 beats, cut short)
	testing.expect_value(t, pm.song_lanes(&p.song), 2)
	testing.expect_value(t, pm.song_beats(p), 8)
	count :: proc(r: ^Rig) -> int {
		m := &r.m
		pm.stop(&m.engine)
		m.project.song_mode = true
		m.engine.seq_dirty = true
		pm.play(&m.engine)
		out := render_synced(r, 48_000 * 4) // 8 beats at 120
		return len(onsets(out[0][:]))
	}
	testing.expect_value(t, count(r), 8 + 1) // together
	l := p.song.lanes[0]
	l.mute = true
	pm.lane_set(m, 0, l, "Mute Lane")
	testing.expect_value(t, count(r), 1) // lane 2 only
	l.mute = false
	pm.lane_set(m, 0, l, "Mute Lane")
	l = p.song.lanes[0]
	l.solo = true
	pm.lane_set(m, 0, l, "Solo Lane")
	testing.expect_value(t, count(r), 8) // lane 1 only
	// Where the playhead leads: the topmost heard lane.
	pl := pm.plan_song(p, 0)
	seg, _, _, _ := pm.plan_locate(pl, 5)
	testing.expect_value(t, pl.segs[seg].lane, 0)
	app.undo(&m.history)
	pl = pm.plan_song(p, 0)
	seg, _, _, _ = pm.plan_locate(pl, 5)
	testing.expect_value(t, pl.segs[seg].lane, 0) // (both heard: the top one)
}

@(test)
song_time_signature_lane_makes_its_bars :: proc(t: ^testing.T) {
	r := rig_make(t, "song_meters")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	pm.song_add(m, 0, repeats = 4) // 16 beats
	pm.meter_set(m, 5, {3, 4}) // in bar 2 (beats 4..8): from its start
	testing.expect_value(t, p.song.meters[0].beat, 4)
	bars := pm.song_bars(p)
	want := []f64{0, 4, 7, 10, 13, 16}
	testing.expectf(t, len(bars) == len(want), "bars: %v", bars)
	for b, i in want do if i < len(bars) do testing.expectf(t, abs(bars[i] - b) < 1e-9, "bar %d at %v (%v)", i, b, bars)
	testing.expect_value(t, pm.song_meter_at(p, 9), pm.Time_Sig{3, 4})
	testing.expect_value(t, pm.song_meter_at(p, 2), p.transport.time_sig)
	// Past the song: bars go on (for the grid).
	testing.expect(t, len(pm.song_bars(p, 40)) > len(bars), "bars to 40")
	pm.meter_remove(m, 0)
	testing.expect_value(t, p.song.meter_count, 0)
}

@(test)
arrangements_switch_undo_and_save :: proc(t: ^testing.T) {
	r := rig_make(t, "song_arr")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.song_add(m, 0)
	testing.expect_value(t, p.arrangement_count, 1)
	b := pm.add_arrangement(m, copy_of = 0)
	testing.expect_value(t, b, 1)
	testing.expect_value(t, p.song.count, 1) // the copy's song
	testing.expect_value(t, pm.arrangement_name(p, 1), "Song copy")
	pm.song_add(m, 0, lane = 2, at = 8)
	testing.expect_value(t, p.song.count, 2)
	pm.select_arrangement(m, 0)
	testing.expect_value(t, p.song.count, 1) // the first is as it was
	pm.select_arrangement(m, 1)
	testing.expect_value(t, p.song.count, 2) // the second kept its clip
	pm.rename_arrangement(m, 1, " Radio edit ")
	testing.expect_value(t, pm.arrangement_name(p, 1), "Radio edit")
	app.undo(&m.history)
	testing.expect_value(t, pm.arrangement_name(p, 1), "Song copy")
	app.redo(&m.history)
	// Saved and loaded: both, the current one, a clip's settings, lanes,
	// time signatures, colours, curves.
	c := p.song.clips[1]
	c.start, c.part, c.transpose, c.mute, c.length = 1, 2, -3, true, 6
	copy(c.label[:], "Drop")
	pm.set_song_clip(m, 1, c, "Clip")
	pm.lane_rename(m, 2, "Bass")
	l := p.song.lanes[1]
	l.solo = true
	pm.lane_set(m, 1, l, "Solo")
	pm.meter_set(m, 4, {7, 8})
	s := p.sequences[0]
	s.color = 0x123456
	pm.set_sequence(m, 0, .Name, "Colour", s)
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 0, value = -12, curve = 0.5})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 2, value = 0})
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "song_arr2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	q := &r2.m.project
	testing.expect_value(t, q.arrangement_count, 2)
	testing.expect_value(t, q.arrangement, 1)
	testing.expect_value(t, q.song.count, 2)
	qc := q.song.clips[1]
	testing.expect(t, qc.lane == 2 && qc.at == 8 && qc.length == 6 && qc.start == 1 && qc.part == 2 && qc.transpose == -3 && qc.mute, "the clip's settings")
	testing.expect_value(t, pm.clip_label(&q.song.clips[1]), "Drop")
	testing.expect_value(t, pm.lane_name(&q.song, 2), "Bass")
	testing.expect_value(t, pm.lane_name(&q.song, 0), "Lane 1")
	testing.expect(t, q.song.lanes[1].solo, "a lane's solo")
	testing.expect(t, q.song.meter_count == 1 && q.song.meters[0].sig == pm.Time_Sig{7, 8}, "the time signature lane")
	testing.expect_value(t, q.arrangements[0].song.count, 1)
	testing.expect_value(t, pm.sequence_color(q, 0), 0x123456)
	testing.expect_value(t, q.sequences[0].points[0].curve, 0.5)
	pm.delete_arrangement(&r2.m, 0)
	testing.expect_value(t, q.arrangement_count, 1)
	testing.expect_value(t, pm.arrangement_name(q, 0), "Radio edit")
}

@(test)
song_clips_moved_copied_duplicated_removed :: proc(t: ^testing.T) {
	r := rig_make(t, "song_groups")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for k in 0 ..< 3 do pm.song_add(m, k) // clips at 0, 4, 8 on lane 1
	testing.expect(t, p.song.clips[2].at == 8, "after each other")
	// Clips 1 and 2 moved 2 beats later and a lane down: one undo step.
	from := p.song
	pm.song_move_clips(m, from, {1, 2}, 1, 1)
	pm.song_move_clips(m, from, {1, 2}, 2, 1)
	app.seal(&m.history)
	testing.expect(t, p.song.clips[1].at == 6 && p.song.clips[1].lane == 1 && p.song.clips[2].at == 10, "moved")
	testing.expect_value(t, pm.song_lanes(&p.song), 2)
	// Not before the song's start or above its first lane.
	pm.song_move_clips(m, p.song, {1}, -20, -3)
	app.seal(&m.history)
	testing.expect(t, p.song.clips[1].at == 0 && p.song.clips[1].lane == 0, "kept in the song")
	app.undo(&m.history)
	app.undo(&m.history)
	testing.expect(t, p.song.clips[1].at == 4 && p.song.clips[1].lane == 0, "one undo step a drag")
	// Duplicated after themselves.
	dup := pm.song_duplicate_clips(m, {1, 2})
	testing.expect(t, dup == {3, 4} && p.song.clips[3].at == 12 && p.song.clips[4].at == 16, "duplicated")
	pm.song_remove_clips(m, dup)
	testing.expect_value(t, p.song.count, 3)
	// Full: only as many as fit.
	for p.song.count < pm.SONG_CLIPS do pm.song_add(m, 0)
	testing.expect_value(t, pm.song_insert_clips(m, p.song.clips[:2], 4), pm.Clip_Set{})
}

@(test)
muted_notes_stay_silent :: proc(t: ^testing.T) {
	r := blips(t, "muted_notes")
	defer rig_destroy(r)
	m := &r.m
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1, muted = b % 2 == 1})
	pm.play(&m.engine)
	out := render_synced(r, 48_000 * 2) // 4 beats at 120
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 2, "two of four notes muted (%v)", got)
}

// A project saved before songs had lanes (v29: a chain of steps, a step
// in 3/4, a marker) opens as clips on the first lane, one after another,
// the step's time signature in the song's lane.
@(test)
an_old_song_chain_opens_as_clips :: proc(t: ^testing.T) {
	r := rig_make(t, "song_v29")
	defer rig_destroy(r)
	dir, _ := filepath.join({r.dir, "Old.pads"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(dir), nil)
	file, _ := filepath.join({dir, "project.fire"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, #load("fixtures/song_v29.pads/project.fire")) == nil, "the fixture copied")
	testing.expect_value(t, pm.model_load(&r.m, dir), fc.Error.None)
	p := &r.m.project
	s := &p.song
	// Sequence 1 twice (8 beats), sequence 2 once (4), sequence 1 once (4).
	testing.expect_value(t, s.count, 3)
	want := [3]pm.Song_Clip{{slot = 0, at = 0, length = 8}, {slot = 1, at = 8, length = 4}, {slot = 0, at = 12, length = 4}}
	for w, i in want {
		c := s.clips[i]
		testing.expectf(t, c.lane == 0 && c.slot == w.slot && c.at == w.at && c.length == w.length, "clip %d: %v", i, c)
	}
	testing.expect_value(t, pm.song_lanes(s), 1)
	testing.expect_value(t, pm.song_beats(p), 16)
	// The second step's 3/4, then the project's 4/4 again.
	testing.expectf(t, s.meter_count == 2 && s.meters[0].beat == 8 && s.meters[0].sig == pm.Time_Sig{3, 4} && s.meters[1].beat == 12, "meters: %v", s.meters[:s.meter_count])
	testing.expect_value(t, s.marker_count, 1)
	testing.expect_value(t, s.tempo_count, 0) // (every step at the project's tempo)
}
