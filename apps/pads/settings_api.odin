package pads

import "core:reflect"

import pc "core"
import pm "model"
import pf "fire:perform"

// Pads' settings, registered by name for the API (`settings_get_text`,
// `settings_set_number`...): each points at its field in `App_Settings`
// (or the core), named as settings.ini names it, with its range or
// choices and what applying it means (`settings_apply`). The Settings
// window edits the same fields.
settings_register :: proc(a: ^App) {
	s := &a.settings
	c := &a.core
	reg :: proc(c: ^pc.Core, x: pc.Setting) { pc.setting_register(c, x) }
	// Appearance.
	reg(c, {name = "appearance.zoom", kind = .Number, group = .Appearance, store = .F32, ptr = &s.zoom, min = 0.5, max = 3, about = "the size of everything (1: as designed)"})
	reg(c, {name = "appearance.pad_waveforms", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.pad_waves, about = "the pads show their sound's waveform"})
	reg(c, {name = "appearance.control_size", kind = .Choice, group = .Appearance, store = .U8, ptr = &s.control_size, choices = reflect.enum_field_names(Control_Size), about = "how large controls are"})
	reg(c, {name = "appearance.remember_layout", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.layout, about = "the window's panels as they were left"})
	reg(c, {name = "meters.scale", kind = .Choice, group = .Appearance, store = .U8, ptr = &s.meters.scale, choices = reflect.enum_field_names(Meter_Scale), about = "the level meters' scale (dBFS or a K-system's)"})
	reg(c, {name = "meters.rms_emphasis", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.meters.rms, about = "the RMS bar the bright one"})
	reg(c, {name = "meters.hold", kind = .Number, group = .Appearance, store = .F32, ptr = &s.meters.hold_s, min = 0, max = 10, about = "seconds a peak stays (0: none)"})
	reg(c, {name = "meters.fall", kind = .Number, group = .Appearance, store = .F32, ptr = &s.meters.fall_dbs, min = 3, max = 96, about = "how fast the meters fall (dB a second)"})
	reg(c, {name = "mixer.inserts", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.mixer_view.inserts, about = "the Mixer's strips show their inserts"})
	reg(c, {name = "mixer.eq", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.mixer_view.eq, about = "... their EQ"})
	reg(c, {name = "mixer.sends", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.mixer_view.sends, about = "... their sends"})
	reg(c, {name = "mixer.io", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.mixer_view.io, about = "... their inputs and outputs"})
	reg(c, {name = "mixer.narrow", kind = .Bool, group = .Appearance, store = .Bool, ptr = &s.mixer_view.narrow, about = "the Mixer's strips narrow"})
	// Audio (what Apply opens the device with: set, it reopens).
	reg(c, {name = "audio.driver", kind = .Text, group = .Audio, store = .String, ptr = &s.staged.driver, about = "the audio driver (\"\": the platform's)"})
	reg(c, {name = "audio.output", kind = .Text, group = .Audio, store = .String, ptr = &s.staged.output, about = "the output device's id (\"\": the system's default)"})
	reg(c, {name = "audio.input", kind = .Text, group = .Audio, store = .String, ptr = &s.staged.input, about = "the input device's id (\"\": the system's default)"})
	reg(c, {name = "audio.sample_rate", kind = .Number, group = .Audio, store = .F64, ptr = &s.staged.rate, min = 0, max = 384_000, about = "Hz (0: the device's)"})
	reg(c, {name = "audio.buffer", kind = .Int, group = .Audio, store = .Int, ptr = &s.staged.buffer, min = 0, max = 8192, about = "frames (0: the device's)"})
	reg(c, {name = "audio.cue_db", kind = .Number, group = .Audio, store = .F32, ptr = &s.staged.cue_db, min = -60, max = 6, about = "the cue mix's level (dB)"})
	reg(c, {name = "audio.click_on_cue_only", kind = .Bool, group = .Audio, store = .Bool, ptr = &s.staged.click_cue, about = "the metronome plays on the cue pair only"})
	// MIDI.
	reg(c, {name = "midi.enabled", kind = .Bool, group = .Midi, store = .Bool, ptr = &s.midi_on, about = "MIDI ports open"})
	reg(c, {name = "midi.output", kind = .Text, group = .Midi, store = .String, ptr = &s.midi_output, about = "the MIDI output port (\"\": none)"})
	reg(c, {name = "midi.input_offset_ms", kind = .Number, group = .Midi, store = .F32, ptr = &s.midi_offset_ms, min = -100, max = 100, about = "MIDI notes recorded this much earlier (a controller's latency)"})
	// Sync.
	reg(c, {name = "midi.sync", kind = .Choice, group = .Sync, store = .U8, ptr = &s.sync, choices = reflect.enum_field_names(Sync_Mode), about = "what the tempo, start and stop follow"})
	reg(c, {name = "midi.clock_out", kind = .Bool, group = .Sync, store = .Bool, ptr = &s.clock_out, about = "MIDI clock goes out of the output port"})
	reg(c, {name = "midi.link_start_stop", kind = .Bool, group = .Sync, store = .Bool, ptr = &s.link_start_stop, about = "Link shares start and stop"})
	// Recording.
	reg(c, {name = "recording.offset_frames", kind = .Int, group = .Recording, store = .Int, ptr = &s.record_offset, min = -RECORD_OFFSET_MAX, max = RECORD_OFFSET_MAX, about = "frames added to the device's round trip when recording audio"})
	reg(c, {name = "recording.passes_to_tracks", kind = .Bool, group = .Recording, store = .Bool, ptr = &s.passes_to_tracks, about = "each loop pass after the first onto a track of its own"})
	reg(c, {name = "recording.count_in_click", kind = .Bool, group = .Recording, store = .Bool, ptr = &s.count_in_click, about = "the count-in clicks"})
	reg(c, {name = "recording.arm_selected", kind = .Bool, group = .Recording, store = .Bool, ptr = &s.arm_selected, about = "the selected track is armed"})
	reg(c, {name = "recording.preroll", kind = .Choice, group = .Recording, store = .U8, ptr = &s.preroll, choices = reflect.enum_field_names(Preroll), about = "how early a hit before the downbeat still goes on it"})
	reg(c, {name = "sampling.method", kind = .Choice, group = .Recording, store = .U8, ptr = &s.sample_method, choices = reflect.enum_field_names(pm.Sampling), about = "how the Sample control records into a pad"})
	reg(c, {name = "sampling.threshold_db", kind = .Number, group = .Recording, store = .F32, ptr = &s.sample_threshold_db, min = -80, max = 0, about = "Threshold's level"})
	reg(c, {name = "sampling.bars", kind = .Int, group = .Recording, store = .Int, ptr = &s.sample_bars, min = 1, max = 16, about = "Bars' count"})
	reg(c, {name = "note_repeat.rate", kind = .Choice, group = .Recording, store = .U8, ptr = &s.repeat_rate, choices = reflect.enum_field_names(pf.Rate), about = "the toolbar's note repeat"})
	reg(c, {name = "note_repeat.gate", kind = .Number, group = .Recording, store = .F32, ptr = &s.repeat_gate, min = 0.05, max = 1, about = "its notes' length (of a step)"})
	// New projects.
	reg(c, {name = "project.tempo", kind = .Number, group = .Project, store = .F64, ptr = &s.default_bpm, min = 40, max = 300, about = "a new project's tempo"})
	reg(c, {name = "project.beats", kind = .Int, group = .Project, store = .Int, ptr = &s.default_sig[0], min = 1, max = 16, about = "... its beats a bar"})
	reg(c, {name = "project.beat_unit", kind = .Int, group = .Project, store = .Int, ptr = &s.default_sig[1], min = 1, max = 16, about = "... its beat (4: a quarter)"})
	reg(c, {name = "project.bars", kind = .Int, group = .Project, store = .Int, ptr = &s.default_bars, min = 1, max = pm.MAX_BARS, about = "... its sequences' bars"})
	reg(c, {name = "project.buses", kind = .Int, group = .Project, store = .Int, ptr = &s.default_buses, min = 1, max = pm.BUSES, about = "... its buses"})
	reg(c, {name = "project.lanes", kind = .Int, group = .Project, store = .Int, ptr = &s.default_lanes, min = 1, max = pm.MAX_LANES, about = "... its launcher's lanes"})
	reg(c, {name = "project.folder", kind = .Text, group = .Project, store = .String, ptr = &s.projects_folder, about = "where Save starts for a new project (\"\": Documents)"})
	reg(c, {name = "project.unsaved_folder", kind = .Text, group = .Project, store = .String, ptr = &a.files.unsaved_folder, about = "where new projects are until saved (\"\": Music/Pads/Unsaved)"})
	reg(c, {name = "project.autosave_minutes", kind = .Int, group = .Project, store = .Int, ptr = &s.autosave_min, min = 0, max = 60, about = "a backup every so many minutes (0: off)"})
	reg(c, {name = "project.open_last", kind = .Bool, group = .Project, store = .Bool, ptr = &s.open_last, about = "the last project opens on start"})
	reg(c, {name = "project.export_rate", kind = .Number, group = .Project, store = .F64, ptr = &s.export_rate, min = 8000, max = 384_000, about = "an export's sample rate"})
	reg(c, {name = "project.export_bits", kind = .Int, group = .Project, store = .Int, ptr = &s.export_bits, min = 16, max = 32, about = "16, 24 or 32 (float)"})
	// Plug-ins.
	reg(c, {name = "plugins.scan_on_start", kind = .Bool, group = .Plugins, store = .Bool, ptr = &s.scan_on_start, about = "plug-ins are looked for on start"})
	c.registry.changed, c.registry.user = settings_apply, a
}

// A setting the API set: applied where it acts (the device reopened, the
// ports, the sync, the look, a new project's defaults), and saved. False
// if it couldn't be applied (the audio device wouldn't open: back as it
// was).
settings_apply :: proc(user: rawptr, group: pc.Setting_Group) -> bool {
	a := (^App)(user)
	s := &a.settings
	switch group {
	case .Appearance: appearance_apply(a)
	case .Audio:
		audio_apply(a)
		if !s.keep.active do return false // (it wouldn't open: back to the one before, saved as it was)
		audio_keep(a) // (no one to ask "Keep these settings?": kept)
		return true
	case .Midi:       midi_apply(a)
	case .Sync:       sync_apply(a)
	case .Recording, .Plugins: // (read where they act, each frame)
	case .Project:    project_defaults_apply(a)
	}
	settings_save(a)
	return true
}
