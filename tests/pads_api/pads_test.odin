package test_pads_api

import "core:math"
import "core:path/filepath"
import "core:testing"

import pa "../../apps/pads/api"
import pm "../../apps/pads/model"
import "fire:audiofile"

// A WAV of a second of a 220 Hz sine, outside the project.
@(private)
tone :: proc(r: ^Rig, name := "tone.wav") -> string {
	path, _ := filepath.join({r.dir, name}, context.temp_allocator)
	n := int(SR)
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x do v = f32(0.5 * math.sin(math.TAU * 220 * f64(i) / SR))
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	return path
}

@(test)
a_pad_is_loaded_shaped_and_cleared :: proc(t: ^testing.T) {
	r := rig_make(t, "pads")
	defer rig_destroy(r)
	api := &r.api
	_, res := pa.pad_state(api, 128)
	testing.expect_value(t, res, pa.Result.Not_Found)
	s, _ := pa.pad_state(api, 3)
	testing.expect(t, !s.used && s.kind == .Sampler, "empty")
	testing.expect_value(t, pa.pad_load_sample(api, 3, "/no/such.wav"), pa.Result.Io_Error)
	testing.expect_value(t, pa.pad_load_sample(api, 3, tone(r)), pa.Result.Ok)
	s, _ = pa.pad_state(api, 3)
	testing.expect(t, s.used, "a sound")
	name, _ := pa.pad_name(api, 3)
	testing.expect_value(t, name, "tone")
	label, _ := pa.pad_label(api, 3)
	testing.expect_value(t, label, "A4")
	// Its settings, each a step of its own; out of range refused.
	testing.expect_value(t, pa.pad_set_name(api, 3, "Kick"), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_color(api, 3, 0xff0000), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_mode(api, 3, .Gate), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_volume(api, 3, -12), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_pan(api, 3, 0.5), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_pitch(api, 3, 7), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_mute(api, 3, true), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_solo(api, 3, true), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_choke(api, 3, 2), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_monitor(api, 3, .In), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_volume(api, 3, 12), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.pad_set_pitch(api, 3, 30), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.pad_set_choke(api, 3, 7), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.pad_set_color(api, 3, 0x1000000), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.pad_set_name(api, 3, "a name far too long to fit in a pad's name"), pa.Result.Invalid_Argument)
	s, _ = pa.pad_state(api, 3)
	testing.expect(t, s.mode == .Gate && s.color == 0xff0000 && s.volume == -12 && s.pan == 0.5 && s.pitch == 7, "set")
	testing.expect(t, s.mute && s.solo && s.choke == 2 && s.monitor == .In, "set")
	name, _ = pa.pad_name(api, 3)
	testing.expect_value(t, name, "Kick")
	h, _ := pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 11) // (the load, then ten settings)
	// Copied, duplicated, cleared.
	testing.expect_value(t, pa.pad_copy_to(api, 3, 10), pa.Result.Ok)
	n10, _ := pa.pad_name(api, 10)
	testing.expect_value(t, n10, "Kick")
	to, res2 := pa.pad_duplicate(api, 3)
	testing.expect(t, res2 == .Ok && to == 4, "onto the next empty pad")
	testing.expect_value(t, pa.pad_clear(api, 3), pa.Result.Ok)
	s, _ = pa.pad_state(api, 3)
	testing.expect(t, !s.used && s.volume == 0, "cleared")
	pa.history_undo(api)
	s, _ = pa.pad_state(api, 3)
	testing.expect(t, s.used && s.volume == -12, "undone")
}

@(test)
a_pad_changes_kind_plays_and_arms :: proc(t: ^testing.T) {
	r := rig_make(t, "pads_kind")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	testing.expect_value(t, pa.pad_set_kind(api, 0, .Slicer), pa.Result.Ok)
	s, _ := pa.pad_state(api, 0)
	testing.expect_value(t, s.kind, pa.Pad_Kind.Slicer)
	testing.expect_value(t, pa.pad_set_kind(api, 0, .Sampler), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_kind(api, 1, .Synth), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_kind(api, 1, .Plugin), pa.Result.Unsupported)
	s, _ = pa.pad_state(api, 1)
	testing.expect(t, s.kind == .Synth && s.used, "a synth")
	// Armed: an instrument for its MIDI, an audio track for its input.
	testing.expect_value(t, pa.pad_set_armed(api, 0, true), pa.Result.Ok)
	s, _ = pa.pad_state(api, 0)
	testing.expect(t, s.armed, "an instrument armed")
	testing.expect_value(t, pa.pad_set_kind(api, 2, .Audio), pa.Result.Ok)
	testing.expect_value(t, pa.pad_set_kind(api, 2, .Slicer), pa.Result.Unsupported)
	testing.expect_value(t, pa.pad_set_armed(api, 2, true), pa.Result.Ok)
	s, _ = pa.pad_state(api, 2)
	testing.expect(t, s.kind == .Audio && s.armed, "armed")
	// Played: it sounds.
	testing.expect_value(t, pa.pad_play(api, 0, true, 2), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.pad_play(api, 0, true), pa.Result.Ok)
	render(r, 2048)
	_, playing := pm.pad_playhead(&r.core.m.engine, 0)
	testing.expect(t, playing, "it plays")
	testing.expect_value(t, pa.pad_play(api, 0, false), pa.Result.Ok)
}
