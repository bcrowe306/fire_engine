package pads_api

import pm "../model"

// How an audio track's part follows a tempo it wasn't recorded at.
Audio_Warp :: enum i32 {
	Repitch, // faster or slower, its pitch with it
	Stretch, // its pitch kept (transpose applies)
}

// Audio track `pad`'s part in sequence `slot`: its takes, the regions
// that play them, how it follows the tempo.
Part_State :: struct {
	regions:   i64, // audio_region 0..regions-1 (in order along the sequence)
	takes:     i64, // takes recorded or added
	beats:     f64, // how long it plays (its own loop, or the sequence)
	warp:      Audio_Warp,
	transpose: f32, // semitones (Stretch)
}

// A region: part of a take, placed in the sequence.
Region :: struct {
	take:     i64,  // which of the part's takes it plays
	at:       f64,  // where it starts: beats into the sequence
	start:    i64,  // the take's frames it plays: from
	end:      i64,  // ... to
	gain_db:  f32,
	pan:      f32,  // -1..1
	fade_in:  f32,  // seconds
	fade_out: f32,  // seconds
	mute:     bool,
	reverse:  bool,
}

// Audio track `pad`'s part in sequence `slot`. Unsupported for a pad that
// isn't an audio track.
audio_part :: proc(api: ^Api, slot: i64, pad: i64) -> (Part_State, Result) {
	if r := audio_ok(api, slot, pad); r != .Ok do return {}, r
	p := &api.core.m.project
	x := pm.part_of(p, int(slot), int(pad))
	return {regions = i64(x.count), takes = i64(x.take_count), beats = pm.part_beats(p, int(slot), int(pad)), warp = Audio_Warp(x.warp), transpose = x.transpose}, .Ok
}

// Region `index` of audio track `pad`'s part in sequence `slot`.
audio_region :: proc(api: ^Api, slot: i64, pad: i64, index: i64) -> (Region, Result) {
	if r := audio_ok(api, slot, pad); r != .Ok do return {}, r
	x := pm.part_of(&api.core.m.project, int(slot), int(pad))
	if index < 0 || index >= i64(x.count) do return {}, fail(api, .Not_Found, "no such region")
	g := x.regions[index]
	return {take = i64(g.take), at = g.at, start = g.start, end = g.end, gain_db = g.gain, pan = g.pan, fade_in = g.fade_in, fade_out = g.fade_out, mute = g.mute, reverse = g.reverse}, .Ok
}

// Adds the audio file at `path` as a take of audio track `pad` in sequence
// `slot`, at beat `at` (on top of what is there). Undoably; Io_Error if
// it can't be read.
audio_add_take :: proc(api: ^Api, slot: i64, pad: i64, path: string, at: f64 = 0) -> Result {
	if r := audio_ok(api, slot, pad); r != .Ok do return r
	if at < 0 do return fail(api, .Invalid_Argument, "a take starts at a beat of 0 or more")
	if pm.add_take_file(&api.core.m, int(slot), int(pad), path, at) != .None do return failf(api, .Io_Error, "could not add the take ", path)
	edited(api)
	return .Ok
}

// Splits the region under beat `beat`, undoably.
audio_split :: proc(api: ^Api, slot: i64, pad: i64, beat: f64) -> Result {
	if r := audio_ok(api, slot, pad); r != .Ok do return r
	if pm.region_at(&api.core.m.project, int(slot), int(pad), beat) < 0 do return fail(api, .Not_Found, "no region there")
	pm.split_at(&api.core.m, int(slot), int(pad), beat)
	edited(api)
	return .Ok
}

// Deletes beats `from`..`to` of the part (silence there), undoably.
audio_delete_range :: proc(api: ^Api, slot: i64, pad: i64, from, to: f64) -> Result {
	if r := range_ok(api, slot, pad, from, to); r != .Ok do return r
	pm.delete_range(&api.core.m, int(slot), int(pad), from, to)
	edited(api)
	return .Ok
}

// Keeps only beats `from`..`to` of the part, undoably.
audio_crop :: proc(api: ^Api, slot: i64, pad: i64, from, to: f64) -> Result {
	if r := range_ok(api, slot, pad, from, to); r != .Ok do return r
	pm.crop_to(&api.core.m, int(slot), int(pad), from, to)
	edited(api)
	return .Ok
}

// Moves region `index` to start at beat `at`, undoably (a gesture's
// moves merge).
audio_move_region :: proc(api: ^Api, slot: i64, pad: i64, index: i64, at: f64) -> Result {
	if r := region_ok(api, slot, pad, index); r != .Ok do return r
	if at < 0 do return fail(api, .Invalid_Argument, "a region starts at a beat of 0 or more")
	pm.move_region(&api.core.m, int(slot), int(pad), int(index), at)
	edited(api)
	return .Ok
}

// Moves region `index`'s start (or its end, with `end`) to beat `beat`,
// undoably.
audio_trim_region :: proc(api: ^Api, slot: i64, pad: i64, index: i64, beat: f64, end: bool) -> Result {
	if r := region_ok(api, slot, pad, index); r != .Ok do return r
	if beat < 0 do return fail(api, .Invalid_Argument, "a beat of 0 or more")
	pm.trim_region(&api.core.m, int(slot), int(pad), int(index), beat, end)
	edited(api)
	return .Ok
}

// Deletes region `index`, undoably.
audio_delete_region :: proc(api: ^Api, slot: i64, pad: i64, index: i64) -> Result {
	if r := region_ok(api, slot, pad, index); r != .Ok do return r
	pm.delete_region(&api.core.m, int(slot), int(pad), int(index))
	edited(api)
	return .Ok
}

// Sets region `index`'s gain, pan, fades, mute and reversing (its take,
// place and frames as they are), undoably.
audio_set_region :: proc(api: ^Api, slot: i64, pad: i64, index: i64, region: Region) -> Result {
	if res := region_ok(api, slot, pad, index); res != .Ok do return res
	if !(region.gain_db >= -60 && region.gain_db <= 24) || !(region.pan >= -1 && region.pan <= 1) || region.fade_in < 0 || region.fade_out < 0 do return fail(api, .Invalid_Argument, "gain -60..24 dB, pan -1..1, fades of 0 s or more")
	g := pm.part_of(&api.core.m.project, int(slot), int(pad)).regions[index]
	g.gain, g.pan, g.fade_in, g.fade_out, g.mute, g.reverse = region.gain_db, region.pan, region.fade_in, region.fade_out, region.mute, region.reverse
	pm.set_region(&api.core.m, int(slot), int(pad), int(index), "Region", g)
	edited(api)
	return .Ok
}

// Raises region `index` so its loudest is full scale, undoably.
audio_normalize_region :: proc(api: ^Api, slot: i64, pad: i64, index: i64) -> Result {
	if r := region_ok(api, slot, pad, index); r != .Ok do return r
	pm.normalize_region(&api.core.m, int(slot), int(pad), int(index))
	edited(api)
	return .Ok
}

// Plays take `take` over beats `from`..`to` (comping: the best of each
// pass), undoably.
audio_use_take :: proc(api: ^Api, slot: i64, pad: i64, take: i64, from, to: f64) -> Result {
	if r := range_ok(api, slot, pad, from, to); r != .Ok do return r
	if take < 0 || take >= i64(pm.part_of(&api.core.m.project, int(slot), int(pad)).take_count) do return fail(api, .Not_Found, "no such take")
	pm.use_take(&api.core.m, int(slot), int(pad), int(take), from, to)
	edited(api)
	return .Ok
}

// Renders the part to one take (its regions, fades and gains as it
// plays), undoably. Busy while it can't yet (a take still being rendered).
audio_consolidate :: proc(api: ^Api, slot: i64, pad: i64) -> Result {
	if r := audio_ok(api, slot, pad); r != .Ok do return r
	if !pm.consolidate(&api.core.m, int(slot), int(pad)) do return fail(api, .Busy, "it can't be consolidated now (nothing to, or still rendering)")
	edited(api)
	return .Ok
}

// How the part follows a tempo it wasn't recorded at, and its transpose
// (-24..24 semitones; Stretch), undoably.
audio_set_warp :: proc(api: ^Api, slot: i64, pad: i64, warp: Audio_Warp, transpose: f32) -> Result {
	if r := audio_ok(api, slot, pad); r != .Ok do return r
	if warp < min(Audio_Warp) || warp > max(Audio_Warp) || !(transpose >= -24 && transpose <= 24) do return fail(api, .Invalid_Argument, "Repitch or Stretch, transpose -24..24")
	pm.set_part_warp(&api.core.m, int(slot), int(pad), pm.Clip_Warp(warp), transpose)
	edited(api)
	return .Ok
}

// Clears audio track `pad`'s take in the current sequence, undoably.
audio_clear :: proc(api: ^Api, pad: i64) -> Result {
	if r := audio_ok(api, i64(api.core.m.project.slot), pad); r != .Ok do return r
	pm.clear_clip(&api.core.m, int(pad))
	edited(api)
	return .Ok
}

@(private)
audio_ok :: proc(api: ^Api, slot: i64, pad: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if p.kind != .Audio do return fail(api, .Unsupported, "that pad isn't an audio track")
	return .Ok
}

@(private)
range_ok :: proc(api: ^Api, slot: i64, pad: i64, from, to: f64) -> Result {
	if r := audio_ok(api, slot, pad); r != .Ok do return r
	if from < 0 || !(to > from) do return fail(api, .Invalid_Argument, "a range is from a beat (0 or more) to a later one")
	return .Ok
}

@(private)
region_ok :: proc(api: ^Api, slot: i64, pad: i64, index: i64) -> Result {
	if r := audio_ok(api, slot, pad); r != .Ok do return r
	if index < 0 || index >= i64(pm.part_of(&api.core.m.project, int(slot), int(pad)).count) do return fail(api, .Not_Found, "no such region")
	return .Ok
}
