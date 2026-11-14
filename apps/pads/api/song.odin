package pads_api

import "core:strings"

import pm "../model"

// The song now (the current arrangement's).
Song_State :: struct {
	clips:        i64, // song_clip 0..clips-1
	lanes:        i64, // its lanes
	tempo_points: i64, // its tempo lane (none: the project's tempo)
	meters:       i64, // its time signature lane
	markers:      i64,
	loop_on:      bool, // the loop goes round loop_start..loop_end, not the whole song
	loop_start:   f64,
	loop_end:     f64,
	beats:        f64, // how long it is
	seconds:      f64,
	cue:          f64, // where it starts playing (song beats)
	arrangements: i64,
	arrangement:  i64, // the current one
	playing_clip: i64, // the clip leading where it plays (-1: none, or the song isn't playing)
	beat:         f64, // where it plays (-1: the song isn't playing)
}

// A clip of the song: sequence `slot` on lane `lane` from beat `at` for
// `length` beats, going round its part of the sequence.
Song_Clip :: struct {
	slot:      i64,
	lane:      i64,
	at:        f64, // song beat it starts at
	length:    f64, // beats it plays
	start:     f64, // beats into the sequence its part starts at
	part:      f64, // its part's beats (0: from start to the sequence's end)
	phase:     f64, // beats into its part it begins at
	transpose: i64, // -24..24 semitones on its notes
	mute:      bool,
}

// A song lane.
Song_Lane :: struct {
	mute: bool,
	solo: bool,
}

// A point of the song's tempo lane.
Tempo_Point :: struct {
	beat: f64,
	bpm:  f64,  // 40..300
	ramp: bool, // it ramps to the next point (else it steps)
}

// A time signature from `beat` on.
Time_Signature :: struct {
	beat: f64,
	num:  i64,
	den:  i64,
}

// The song now.
song_state :: proc(api: ^Api) -> (Song_State, Result) {
	m := &api.core.m
	p := &m.project
	s := &p.song
	clip, _, beat := pm.song_progress(&m.engine)
	return {
		clips = i64(s.count), lanes = i64(pm.song_lanes(s)), tempo_points = i64(s.tempo_count), meters = i64(s.meter_count), markers = i64(s.marker_count),
		loop_on = s.loop_on, loop_start = s.loop_start, loop_end = s.loop_end, beats = pm.song_beats(p), seconds = pm.song_seconds(p), cue = m.engine.cue,
		arrangements = i64(p.arrangement_count), arrangement = i64(p.arrangement), playing_clip = i64(clip), beat = beat,
	}, .Ok
}

// Clip `index` of the song.
song_clip :: proc(api: ^Api, index: i64) -> (Song_Clip, Result) {
	if r := clip_ok(api, index); r != .Ok do return {}, r
	c := api.core.m.project.song.clips[index]
	return {slot = i64(c.slot), lane = i64(c.lane), at = c.at, length = c.length, start = c.start, part = c.part, phase = c.phase, transpose = i64(c.transpose), mute = c.mute}, .Ok
}

// Clip `index`'s label ("Verse"; "" none). Temporary.
song_clip_label :: proc(api: ^Api, index: i64) -> (string, Result) {
	if r := clip_ok(api, index); r != .Ok do return "", r
	return strings.clone(pm.clip_label(&api.core.m.project.song.clips[index]), context.temp_allocator), .Ok
}

// Adds sequence `slot` to the song on lane `lane`: at beat `at` (-1: after
// the lane's last clip), `length` beats long (0: the sequence `repeats`
// times). Its index. Undoably; Busy when the song is full.
song_add :: proc(api: ^Api, slot: i64, lane: i64 = 0, at: f64 = -1, length: f64 = 0, repeats: i64 = 1) -> (i64, Result) {
	if r := slot_ok(api, slot); r != .Ok do return -1, r
	if lane < 0 || lane >= pm.SONG_LANES do return -1, fail(api, .Invalid_Argument, "a song lane is 0..15")
	if length < 0 || repeats < 1 || repeats > 64 do return -1, fail(api, .Invalid_Argument, "a length of 0 or more, 1..64 repeats")
	i := pm.song_add(&api.core.m, int(slot), int(repeats), int(lane), at, length)
	if i < 0 do return -1, fail(api, .Busy, "the song is full")
	edited(api)
	return i64(i), .Ok
}

// Sets clip `index` (its sequence, place, length, part, transpose, mute),
// undoably (a gesture's moves merge).
song_set_clip :: proc(api: ^Api, index: i64, c: Song_Clip) -> Result {
	if r := clip_ok(api, index); r != .Ok do return r
	if r := slot_ok(api, c.slot); r != .Ok do return r
	if c.lane < 0 || c.lane >= pm.SONG_LANES || c.at < 0 || !(c.length > 0) || c.start < 0 || c.part < 0 || c.phase < 0 || c.transpose < -24 || c.transpose > 24 {
		return fail(api, .Invalid_Argument, "a lane 0..15, a place and lengths of 0 or more (the length more), transpose -24..24")
	}
	old := api.core.m.project.song.clips[index]
	n := old
	n.slot, n.lane, n.at, n.length, n.start, n.part, n.phase, n.transpose, n.mute = u8(c.slot), u8(c.lane), c.at, c.length, c.start, c.part, c.phase, i8(c.transpose), c.mute
	// The step is named for what changed (as the Song view's).
	name := "Edit Clip"
	switch {
	case n.slot != old.slot:                                            name = "Clip Sequence"
	case n.mute != old.mute:                                            name = "Mute Clip"
	case n.start != old.start || n.part != old.part || n.phase != old.phase: name = "Clip Part"
	case n.length != old.length:                                        name = "Clip Length"
	case n.transpose != old.transpose:                                  name = "Transpose Clip"
	case n.at != old.at || n.lane != old.lane:                          name = "Move Clip"
	}
	pm.set_song_clip(&api.core.m, int(index), n, name)
	edited(api)
	return .Ok
}

// Removes the clips `indices`: one undo step.
song_remove_clips :: proc(api: ^Api, indices: []i64) -> Result {
	sel: pm.Clip_Set
	for i in indices {
		if r := clip_ok(api, i); r != .Ok do return r
		sel += {int(i)}
	}
	pm.song_remove_clips(&api.core.m, sel)
	edited(api)
	return .Ok
}

// Copies the clips `indices` right after themselves (the selection's span
// later): one undo step. How many were copied (as many as fit): they are
// the song's last clips now.
song_duplicate_clips :: proc(api: ^Api, indices: []i64) -> (i64, Result) {
	sel: pm.Clip_Set
	for i in indices {
		if r := clip_ok(api, i); r != .Ok do return 0, r
		sel += {int(i)}
	}
	added := pm.song_duplicate_clips(&api.core.m, sel)
	if added == {} do return 0, fail(api, .Busy, "the song is full")
	edited(api)
	return i64(card(added)), .Ok
}

// Empties the song (its clips; its lanes, tempo, meters and markers too),
// undoably.
song_clear :: proc(api: ^Api) -> Result {
	pm.set_song(&api.core.m, "Clear Song", {})
	edited(api)
	return .Ok
}

// Merges sequence `from`'s notes and automation into sequence `to` (as
// long as the longer), undoably.
song_merge_sequence :: proc(api: ^Api, from, to: i64) -> Result {
	if r := slot_ok(api, from); r != .Ok do return r
	if r := slot_ok(api, to); r != .Ok do return r
	if from == to do return fail(api, .Invalid_Argument, "a sequence into itself")
	pm.merge_sequences(&api.core.m, int(from), int(to))
	edited(api)
	return .Ok
}

// Moves the clips `indices` by `beats` and `lanes`: one undo step (the
// earliest stays at 0 or later, the top lane at 0 or lower).
song_move_clips :: proc(api: ^Api, indices: []i64, beats: f64, lanes: i64) -> Result {
	sel: pm.Clip_Set
	for i in indices {
		if r := clip_ok(api, i); r != .Ok do return r
		sel += {int(i)}
	}
	m := &api.core.m
	pm.song_move_clips(m, m.project.song, sel, beats, int(lanes))
	edited(api)
	return .Ok
}

// Song lane `lane`.
song_lane :: proc(api: ^Api, lane: i64) -> (Song_Lane, Result) {
	if lane < 0 || lane >= pm.SONG_LANES do return {}, fail(api, .Not_Found, "a song lane is 0..15")
	l := api.core.m.project.song.lanes[lane]
	return {mute = l.mute, solo = l.solo}, .Ok
}

// Song lane `lane`'s name (its own, else "Lane N"). Temporary.
song_lane_name :: proc(api: ^Api, lane: i64) -> (string, Result) {
	if lane < 0 || lane >= pm.SONG_LANES do return "", fail(api, .Not_Found, "a song lane is 0..15")
	return strings.clone(pm.lane_name(&api.core.m.project.song, int(lane)), context.temp_allocator), .Ok
}

// Adds a song lane at the bottom: its number. Busy at 16.
song_add_lane :: proc(api: ^Api) -> (i64, Result) {
	l := pm.lane_add(&api.core.m)
	if l < 0 do return -1, fail(api, .Busy, "there are 16 song lanes already")
	edited(api)
	return i64(l), .Ok
}

// Mutes or solos song lane `lane`, undoably.
song_set_lane :: proc(api: ^Api, lane: i64, l: Song_Lane) -> Result {
	if lane < 0 || lane >= pm.SONG_LANES do return fail(api, .Not_Found, "a song lane is 0..15")
	old := api.core.m.project.song.lanes[lane]
	n := old
	n.mute, n.solo = l.mute, l.solo
	pm.lane_set(&api.core.m, int(lane), n, "Mute Lane" if n.mute != old.mute else "Solo Lane")
	edited(api)
	return .Ok
}

// Names song lane `lane` (up to 15 bytes), undoably.
song_rename_lane :: proc(api: ^Api, lane: i64, name: string) -> Result {
	if lane < 0 || lane >= pm.SONG_LANES do return fail(api, .Not_Found, "a song lane is 0..15")
	if len(strings.trim_space(name)) > 15 do return fail(api, .Invalid_Argument, "a lane's name is up to 15 bytes")
	pm.lane_rename(&api.core.m, int(lane), name)
	edited(api)
	return .Ok
}

// Tempo point `index` of the song's tempo lane.
song_tempo_point :: proc(api: ^Api, index: i64) -> (Tempo_Point, Result) {
	s := &api.core.m.project.song
	if index < 0 || index >= i64(s.tempo_count) do return {}, fail(api, .Not_Found, "no such tempo point")
	t := s.tempo[index]
	return {beat = t.beat, bpm = t.bpm, ramp = t.ramp}, .Ok
}

// Adds a point to the song's tempo lane (one at its beat replaced),
// undoably.
song_add_tempo_point :: proc(api: ^Api, t: Tempo_Point) -> Result {
	if t.beat < 0 || !(t.bpm >= 40 && t.bpm <= 300) do return fail(api, .Invalid_Argument, "a beat of 0 or more, 40..300 BPM")
	if api.core.m.project.song.tempo_count >= pm.MAX_TEMPO_POINTS do return fail(api, .Busy, "the tempo lane is full")
	pm.tempo_point_add(&api.core.m, {beat = t.beat, bpm = t.bpm, ramp = t.ramp})
	edited(api)
	return .Ok
}

// Removes tempo point `index` (the first only when it is the last left),
// undoably.
song_remove_tempo_point :: proc(api: ^Api, index: i64) -> Result {
	s := &api.core.m.project.song
	if index < 0 || index >= i64(s.tempo_count) do return fail(api, .Not_Found, "no such tempo point")
	if index == 0 && s.tempo_count > 1 do return fail(api, .Busy, "the first point goes last")
	pm.tempo_point_remove(&api.core.m, int(index))
	edited(api)
	return .Ok
}

// Time signature change `index` of the song.
song_meter :: proc(api: ^Api, index: i64) -> (Time_Signature, Result) {
	s := &api.core.m.project.song
	if index < 0 || index >= i64(s.meter_count) do return {}, fail(api, .Not_Found, "no such time signature change")
	x := s.meters[index]
	return {beat = x.beat, num = i64(x.sig.num), den = i64(x.sig.den)}, .Ok
}

// Changes the song's time signature from `beat` on, undoably.
song_set_meter :: proc(api: ^Api, beat: f64, num: i64, den: i64) -> Result {
	if beat < 0 || num < 1 || num > 16 || (den != 2 && den != 4 && den != 8 && den != 16) do return fail(api, .Invalid_Argument, "a beat of 0 or more; 1..16 beats of 1/2, 1/4, 1/8 or 1/16")
	pm.meter_set(&api.core.m, beat, {int(num), int(den)})
	edited(api)
	return .Ok
}

// Removes time signature change `index`, undoably.
song_remove_meter :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= i64(api.core.m.project.song.meter_count) do return fail(api, .Not_Found, "no such time signature change")
	pm.meter_remove(&api.core.m, int(index))
	edited(api)
	return .Ok
}

// Marker `index`'s beat.
song_marker :: proc(api: ^Api, index: i64) -> (f64, Result) {
	s := &api.core.m.project.song
	if index < 0 || index >= i64(s.marker_count) do return 0, fail(api, .Not_Found, "no such marker")
	return s.markers[index].beat, .Ok
}

// Marker `index`'s name. Temporary.
song_marker_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	s := &api.core.m.project.song
	if index < 0 || index >= i64(s.marker_count) do return "", fail(api, .Not_Found, "no such marker")
	return strings.clone(pm.marker_name(&s.markers[index]), context.temp_allocator), .Ok
}

// Adds a marker named `name` at `beat`: its index (markers are in order).
// Undoably; Busy when there are 32.
song_add_marker :: proc(api: ^Api, beat: f64, name: string) -> (i64, Result) {
	if beat < 0 do return -1, fail(api, .Invalid_Argument, "a beat of 0 or more")
	i := pm.marker_add(&api.core.m, beat, name)
	if i < 0 do return -1, fail(api, .Busy, "there are 32 markers already")
	edited(api)
	return i64(i), .Ok
}

// Renames marker `index`, undoably.
song_rename_marker :: proc(api: ^Api, index: i64, name: string) -> Result {
	if index < 0 || index >= i64(api.core.m.project.song.marker_count) do return fail(api, .Not_Found, "no such marker")
	pm.marker_rename(&api.core.m, int(index), name)
	edited(api)
	return .Ok
}

// Removes marker `index`, undoably.
song_remove_marker :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= i64(api.core.m.project.song.marker_count) do return fail(api, .Not_Found, "no such marker")
	pm.marker_remove(&api.core.m, int(index))
	edited(api)
	return .Ok
}

// Loops beats `start`..`end` of the song (`on`), or the whole song,
// undoably.
song_set_loop :: proc(api: ^Api, on: bool, start, end: f64) -> Result {
	if on && (start < 0 || !(end > start)) do return fail(api, .Invalid_Argument, "a loop is from a beat (0 or more) to a later one")
	pm.set_song_loop(&api.core.m, on, start, end)
	edited(api)
	return .Ok
}

// Song mode: plays from song beat `beat` (playing), or makes it where
// play starts (stopped).
song_jump :: proc(api: ^Api, beat: f64) -> Result {
	if beat < 0 do return fail(api, .Invalid_Argument, "a beat of 0 or more")
	pm.song_jump(&api.core.m.engine, beat)
	return .Ok
}

// Arrangement `index`'s name. Temporary.
song_arrangement_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	if r := arrangement_ok(api, index); r != .Ok do return "", r
	return strings.clone(pm.arrangement_name(&api.core.m.project, int(index)), context.temp_allocator), .Ok
}

// Makes arrangement `index` the song, undoably.
song_select_arrangement :: proc(api: ^Api, index: i64) -> Result {
	if r := arrangement_ok(api, index); r != .Ok do return r
	pm.select_arrangement(&api.core.m, int(index))
	edited(api)
	return .Ok
}

// A new arrangement (empty, or a copy of `copy_of`), made the song: its
// index. Busy when there are as many as can be.
song_add_arrangement :: proc(api: ^Api, copy_of: i64 = -1) -> (i64, Result) {
	if copy_of != -1 {
		if r := arrangement_ok(api, copy_of); r != .Ok do return -1, r
	}
	i := pm.add_arrangement(&api.core.m, int(copy_of))
	if i < 0 do return -1, fail(api, .Busy, "there are as many arrangements as can be")
	edited(api)
	return i64(i), .Ok
}

// Renames arrangement `index`, undoably.
song_rename_arrangement :: proc(api: ^Api, index: i64, name: string) -> Result {
	if r := arrangement_ok(api, index); r != .Ok do return r
	pm.rename_arrangement(&api.core.m, int(index), name)
	edited(api)
	return .Ok
}

// Deletes arrangement `index`, undoably. Busy for the last one left.
song_delete_arrangement :: proc(api: ^Api, index: i64) -> Result {
	if r := arrangement_ok(api, index); r != .Ok do return r
	if api.core.m.project.arrangement_count <= 1 do return fail(api, .Busy, "a song keeps one arrangement at least")
	pm.delete_arrangement(&api.core.m, int(index))
	edited(api)
	return .Ok
}

@(private)
clip_ok :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= i64(api.core.m.project.song.count) do return fail(api, .Not_Found, "no such song clip")
	return .Ok
}

@(private)
arrangement_ok :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= i64(api.core.m.project.arrangement_count) do return fail(api, .Not_Found, "no such arrangement")
	return .Ok
}
