package pads_api

import pc "../core"
import pm "../model"

// What an export renders.
Export_Source :: enum i32 {
	Sequence, // the current sequence, once
	Song,     // the song (its current arrangement), start to end
}

// A mixdown, or stems.
Export_Stems :: enum i32 {
	Mixdown, // one file
	Pads,    // a file per pad with a sound (`path` a folder)
	Buses,   // a file per bus, and main's (`path` a folder)
}

// An export's file format.
Export_Format :: enum i32 {
	Int16,
	Int24,
	Float32,
}

// How to export.
Export_Settings :: struct {
	source: Export_Source,
	stems:  Export_Stems,
	format: Export_Format,
	rate:   f64, // 44100, 48000 or 96000 (0: the engine's)
	tail:   f64, // seconds after the end, for reverb and echoes to ring out (0..10)
}

// The export under way, or the last one.
Export_State :: struct {
	busy:     bool, // under way (a slice a frame)
	progress: f64,  // 0..1
	failed:   bool, // the last one failed (a file couldn't be written)
	files:    i64,  // files the last one wrote (export_file)
	made_pad: i64,  // the pad the last bounce, resample or bounce in place made (-1: none)
}

// The export under way, or the last one.
export_state :: proc(api: ^Api) -> (Export_State, Result) {
	j := &api.core.job
	x := pc.job_result(api.core)
	pad := i64(-1)
	if x.made >= 0 do pad = i64(x.made)
	else if x.to_pad >= 0 do pad = i64(x.to_pad)
	return {busy = j.busy, progress = j.progress, failed = x.failed, files = i64(len(x.files)), made_pad = pad}, .Ok
}

// File `index` the last export wrote. Temporary.
export_file :: proc(api: ^Api, index: i64) -> (string, Result) {
	x := pc.job_result(api.core)
	if index < 0 || index >= i64(len(x.files)) do return "", fail(api, .Not_Found, "no such file")
	return x.files[index], .Ok
}

// Exports as `settings` say into `path` (a .wav file; with stems, a
// folder). It renders a slice a frame: export_state says how far. Busy
// while another is under way; Invalid_Argument with nothing to export.
export_start :: proc(api: ^Api, settings: Export_Settings, path: string) -> Result {
	ms, r := export_settings(api, settings, path)
	if r != .Ok do return r
	return result(api, pc.export_start(api.core, ms, path))
}

@(private)
export_settings :: proc(api: ^Api, settings: Export_Settings, path: string) -> (pm.Export_Settings, Result) {
	s := settings
	if s.source < min(Export_Source) || s.source > max(Export_Source) || s.stems < min(Export_Stems) || s.stems > max(Export_Stems) || s.format < min(Export_Format) || s.format > max(Export_Format) {
		return {}, fail(api, .Invalid_Argument, "no such source, stems or format")
	}
	if s.rate != 0 && s.rate != 44_100 && s.rate != 48_000 && s.rate != 96_000 do return {}, fail(api, .Invalid_Argument, "the rate is 44100, 48000 or 96000 (0: the engine's)")
	if !(s.tail >= 0 && s.tail <= 10) do return {}, fail(api, .Invalid_Argument, "the tail is 0..10 s")
	if path == "" do return {}, fail(api, .Invalid_Argument, "no path")
	return {source = pm.Export_Source(s.source), stems = pm.Export_Stems(s.stems), encoding = pm.Export_Encoding(s.format), rate = s.rate, tail = s.tail}, .Ok
}

// Exports as `settings` say into `path` at once, waiting for it (a script's
// export): the files written. Busy while another is under way.
export_now :: proc(api: ^Api, settings: Export_Settings, path: string) -> (i64, Result) {
	ms, r := export_settings(api, settings, path)
	if r != .Ok do return 0, r
	n, o := pc.export_now(api.core, ms, path)
	return i64(n), result(api, o)
}

// Resamples the current sequence (as it sounds from main) onto the next
// empty pad.
export_resample :: proc(api: ^Api) -> Result {
	return result(api, pc.export_resample(api.core))
}

// Bounces pads `pads` (what they play in the current sequence, after their
// faders) together onto the next empty pad.
export_bounce_pads :: proc(api: ^Api, pads: []i64) -> Result {
	set: bit_set[0 ..< pm.PADS; u128]
	for p in pads {
		if _, r := pad_of(api, p); r != .Ok do return r
		set += {int(p)}
	}
	if set == {} do return fail(api, .Invalid_Argument, "no pads to bounce")
	return result(api, pc.export_bounce_pads(api.core, set))
}

// Bounces bus `bus` onto the next empty pad.
export_bounce_bus :: proc(api: ^Api, bus: i64) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	return result(api, pc.export_bounce_bus(api.core, int(bus)))
}

// Bounces pad `pad` in place: an audio track of its sound, the pad muted.
export_bounce_in_place :: proc(api: ^Api, pad: i64) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	return result(api, pc.export_bounce_in_place(api.core, int(pad)))
}

// Freezes pad `pad`: its sound rendered in each sequence and played
// instead (its device and inserts rest).
export_freeze :: proc(api: ^Api, pad: i64) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	return result(api, pc.export_freeze(api.core, int(pad)))
}

// Unfreezes pad `pad` (its renderings kept, unused), undoably.
export_unfreeze :: proc(api: ^Api, pad: i64) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if !p.frozen do return fail(api, .Invalid_Argument, "that pad isn't frozen")
	pm.set_frozen(&api.core.m, int(pad), false)
	return .Ok
}

// Flattens frozen pad `pad`: an audio track whose takes are its
// renderings. One undo step.
export_flatten :: proc(api: ^Api, pad: i64) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if !p.frozen do return fail(api, .Invalid_Argument, "that pad isn't frozen")
	pm.flatten(&api.core.m, int(pad))
	return .Ok
}

// Writes sequence `slot` (-1: the song) as a Standard MIDI File at
// `path`: the notes it wrote. Io_Error if it can't be written.
export_midi :: proc(api: ^Api, path: string, slot: i64) -> (i64, Result) {
	if slot != -1 {
		if r := slot_ok(api, slot); r != .Ok do return 0, r
	}
	n := pm.export_midi(&api.core.m, path, int(slot))
	if n < 0 do return 0, fail(api, .Io_Error, "could not write the MIDI file")
	return i64(n), .Ok
}

// How a MIDI file's notes go onto pads.
Midi_Import :: enum i32 {
	Drums,  // General MIDI drums: key 36 (the kick) pad 0, 37 pad 1...; keys below 36 skipped
	By_Map, // each key the pad the MIDI map gives it
	On_Pad, // every note on pad `pad`, pitched (a melody, a bass line)
}

// Reads the Standard MIDI File at `path` into sequence `slot` (replacing
// what is there), its notes onto pads as `how` says: the notes read.
// Undoably.
export_import_midi :: proc(api: ^Api, path: string, slot: i64, how: Midi_Import = .Drums, pad: i64 = 0) -> (i64, Result) {
	if r := slot_ok(api, slot); r != .Ok do return 0, r
	if how < min(Midi_Import) || how > max(Midi_Import) do return 0, fail(api, .Invalid_Argument, "no such import")
	if _, r := pad_of(api, pad); r != .Ok do return 0, r
	n := pm.import_midi(&api.core.m, path, int(slot), pm.Midi_Import(how), int(pad))
	if n < 0 do return 0, fail(api, .Io_Error, "could not read the MIDI file")
	edited(api)
	return i64(n), .Ok
}
