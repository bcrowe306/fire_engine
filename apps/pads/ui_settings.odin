package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:backend"
import padslink "padslink:."

// The app's settings (File > Settings…, Cmd+,), the same for every project,
// kept in settings.ini: beside the app for a portable install (when one is
// already there), else in the user's configuration folder (see
// `app.settings_file_path`; --prefs puts it in that folder instead). What
// a person wrote in the file that Pads doesn't know is kept when it is
// written back.
App_Settings :: struct {
	path:      string, // the settings.ini in use
	portable:  bool,   // beside the app
	ini:       app.Ini,
	open:      bool,
	page:      Settings_Page,
	// Appearance.
	theme:     ui.Theme,          // in use: a preset, with its colours as edited
	presets:   [dynamic]ui.Theme, // the user's own (names owned)
	zoom:      f32,
	pad_waves: bool,
	control_size: Control_Size, // how large controls are
	layout:    bool, // remember the window layout (layout2.ini beside settings.ini)
	meters:    Meter_Settings, // how the level meters read
	mixer_view: Mixer_View, // the Mixer's strips: their sections shown, narrow or wide
	preset_name: [32]u8, // "Save as preset"
	// Audio: what the device opens with; what the page has (Apply opens it);
	// a change waiting to be kept.
	audio:     Audio_Config,
	staged:    Audio_Config,
	keep:      struct { active: bool, until: f64, prev: Audio_Config },
	devices:   []backend.Device_Info,
	// MIDI.
	midi_on:   bool,
	midi_off:  [dynamic]string, // input ports left closed
	midi_output: string,
	clock_out: bool,      // send MIDI clock to the output port
	sync:      Sync_Mode, // what the tempo and start follow
	link_start_stop: bool,
	midi_offset_ms: f32, // MIDI notes recorded this much earlier (a controller's latency)
	// Recording.
	arm_selected: bool, // the selected track is armed
	count_in_click: bool,
	preroll:   Preroll,
	// New projects.
	default_bpm: f64,
	default_sig: [2]int,
	default_bars: int,
	default_buses: int,
	projects_folder: string, // where Save starts for a new project ("" = Documents)
	autosave_min: int,       // 0 = off
	open_last: bool,         // open the last project on start
	export_rate: f64,
	export_bits: int,        // 16, 24 or 32 (float)
	// Plug-ins.
	plugin_folders: [dynamic]string, // besides the system's
	scan_on_start: bool,
	blocked:   [dynamic]string, // plug-in paths not loaded
	// Keyboard: shortcuts that differ from the defaults.
	keys:      [dynamic]Key_Override,
	defaults:  [dynamic]Key_Override, // every action's own (filled once)
	recording: string, // the action whose new shortcut is being pressed
	key_filter: [64]u8,
	// Link, when built in.
	link:      padslink.State,
}

// What the audio device opens with.
Audio_Config :: struct {
	output, input: string, // device ids ("" = the system default)
	rate:   f64, // 0 = the device's
	buffer: int, // frames; 0 = the device's
	inputs: int, // input channels (before interfaces had their own: read once into them)
	interfaces: [dynamic]Interface_Config, // each interface's channels (see audio_channels.odin)
	cue_db:     f32,  // the cue mix's level
	click_cue:  bool, // the metronome plays on the cue pair only (not in main)
}

// A shortcut changed from an action's own.
Key_Override :: struct {
	id:    string,
	chord: im.KeyChord, // 0 = none
}

// The settings window's pages, down its left.
Settings_Page :: enum u8 {
	Appearance,
	Audio,
	Midi,
	Recording,
	Project,
	Plugins,
	Keyboard,
}

@(private)
PAGE_NAMES := [Settings_Page]cstring{.Appearance = "Appearance", .Audio = "Audio", .Midi = "MIDI & Sync", .Recording = "Recording", .Project = "Projects", .Plugins = "Plug-ins", .Keyboard = "Keyboard"}
@(private)
PAGE_ICONS := [Settings_Page]string{.Appearance = ui.ICON_PALETTE, .Audio = ui.ICON_AUDIO_WAVEFORM, .Midi = ui.ICON_MUSIC, .Recording = ui.ICON_CIRCLE_DOT, .Project = ui.ICON_FOLDER, .Plugins = ui.ICON_LAYOUT_GRID, .Keyboard = ui.ICON_COMMAND}

// What the tempo, start and stop follow.
Sync_Mode :: enum u8 {
	Internal,   // the app's own tempo
	Midi_Clock, // an outside MIDI clock (its tempo, Start, Stop, position)
	Link,       // an Ableton Link session (when built in)
}

// How early a hit before a sequence's downbeat still goes on it while
// recording.
Preroll :: enum u8 {
	Off,
	Thirty_Second,
	Sixteenth,
	Eighth,
}

@(private)
PREROLL_NAMES := [Preroll]cstring{.Off = "Off", .Thirty_Second = "A 1/32 before", .Sixteenth = "A 1/16 before", .Eighth = "An 1/8 before"}

// The pre-roll in beats.
preroll_beats :: proc(p: Preroll) -> f64 {
	switch p {
	case .Off:           return 0
	case .Thirty_Second: return 0.125
	case .Sixteenth:     return 0.25
	case .Eighth:        return 0.5
	}
	return 0
}

// --- loading and saving -------------------------------------------------------------------------

// The folder settings.ini (and the other preferences) are in.
settings_folder :: proc(a: ^App) -> string {
	return filepath.dir(a.settings.path)
}

// Finds settings.ini and reads it (missing values keep their defaults;
// settings.txt from before is read once, if there is no settings.ini yet).
settings_load :: proc(a: ^App) {
	s := &a.settings
	if a.prefs != "" {
		s.path, _ = filepath.join({a.prefs, "settings.ini"})
	} else {
		s.path, s.portable = app.settings_file_path("Pads", "settings.ini")
	}
	ini, _ := app.ini_load(s.path)
	s.ini = ini
	ini_ := &s.ini
	g :: proc(ini: ^app.Ini, sec, key, def: string) -> string { v, ok := app.ini_get(ini, sec, key); return v if ok else def }
	// Appearance.
	s.theme = ui.theme_dark()
	preset := g(ini_, "appearance", "theme", "Dark")
	for &sec in ini_.sections do if strings.has_prefix(sec.name, "theme.") {
		t := ui.theme_dark()
		t.name = strings.clone(sec.name[len("theme."):])
		read_colors(ini_, sec.name, &t)
		append(&s.presets, t)
	}
	if t, ok := find_preset(s, preset); ok do s.theme = t
	read_colors(ini_, "appearance.colors", &s.theme) // its edits
	s.zoom = f32(app.ini_f64(ini_, "appearance", "zoom", 1))
	s.pad_waves = app.ini_bool(ini_, "appearance", "pad_waveforms", true)
	s.control_size = control_size_parse(app.ini_get(ini_, "appearance", "control_size") or_else "auto")
	s.layout = app.ini_bool(ini_, "appearance", "remember_layout", true)
	s.meters = {
		scale    = meter_scale_parse(g(ini_, "meters", "scale", "dbfs")),
		rms      = app.ini_bool(ini_, "meters", "rms_emphasis", false),
		hold_s   = f32(clamp(app.ini_f64(ini_, "meters", "hold", 2), 0, 10)),
		fall_dbs = f32(clamp(app.ini_f64(ini_, "meters", "fall", 24), 3, 96)),
	}
	s.mixer_view = {
		inserts = app.ini_bool(ini_, "mixer", "inserts", true),
		eq      = app.ini_bool(ini_, "mixer", "eq", true),
		sends   = app.ini_bool(ini_, "mixer", "sends", true),
		io      = app.ini_bool(ini_, "mixer", "io", true),
		narrow  = app.ini_bool(ini_, "mixer", "narrow", false),
	}
	// Audio.
	s.audio = {
		output = strings.clone(g(ini_, "audio", "output", "")),
		input  = strings.clone(g(ini_, "audio", "input", "")),
		rate   = app.ini_f64(ini_, "audio", "sample_rate", 0),
		buffer = app.ini_int(ini_, "audio", "buffer", 0),
		inputs = app.ini_int(ini_, "audio", "input_channels", 2),
		cue_db = f32(app.ini_f64(ini_, "audio", "cue_db", 0)),
		click_cue = app.ini_bool(ini_, "audio", "click_on_cue_only", false),
	}
	s.audio.interfaces = make([dynamic]Interface_Config)
	interfaces_load(&s.audio, ini_)
	// (From before interfaces had their own channels: the input count.)
	if interface_find(&s.audio, s.audio.input) == nil {
		if _, had := app.ini_get(ini_, "audio", "input_channels"); had {
			f := interface_for(&s.audio, s.audio.input)
			f.inputs = {}
			for c in 0 ..< clamp(s.audio.inputs, 0, 64) do f.inputs += {c}
		}
	}
	s.staged = audio_clone(s.audio)
	// MIDI.
	s.midi_on = app.ini_bool(ini_, "midi", "enabled", true)
	read_list(ini_, "midi", "inputs_off", &s.midi_off)
	s.midi_output = strings.clone(g(ini_, "midi", "output", ""))
	s.clock_out = app.ini_bool(ini_, "midi", "clock_out", false)
	switch g(ini_, "midi", "sync", "internal") {
	case "midi_clock": s.sync = .Midi_Clock
	case "link":       s.sync = .Link if padslink.AVAILABLE else .Internal
	case:              s.sync = .Internal
	}
	s.link_start_stop = app.ini_bool(ini_, "midi", "link_start_stop", true)
	s.midi_offset_ms = f32(app.ini_f64(ini_, "midi", "input_offset_ms", 0))
	// Recording (settings.txt's, the first time).
	s.count_in_click = app.ini_bool(ini_, "recording", "count_in_click", true)
	s.arm_selected = app.ini_bool(ini_, "recording", "arm_selected", true)
	s.preroll = Preroll(clamp(app.ini_int(ini_, "recording", "preroll", int(Preroll.Sixteenth)), 0, int(max(Preroll))))
	if _, has := app.ini_get(ini_, "recording", "preroll"); !has do migrate_settings_txt(a)
	// New projects.
	s.default_bpm = clamp(app.ini_f64(ini_, "project", "tempo", 120), 40, 300)
	s.default_sig = {clamp(app.ini_int(ini_, "project", "beats", 4), 1, 16), clamp(app.ini_int(ini_, "project", "beat_unit", 4), 1, 16)}
	s.default_bars = clamp(app.ini_int(ini_, "project", "bars", 1), 1, pm.MAX_BARS)
	s.default_buses = clamp(app.ini_int(ini_, "project", "buses", pm.DEFAULT_BUSES), 1, pm.BUSES)
	s.projects_folder = strings.clone(g(ini_, "project", "folder", ""))
	s.autosave_min = clamp(app.ini_int(ini_, "project", "autosave_minutes", 1), 0, 60)
	s.open_last = app.ini_bool(ini_, "project", "open_last", false)
	s.export_rate = app.ini_f64(ini_, "project", "export_rate", 48_000)
	s.export_bits = app.ini_int(ini_, "project", "export_bits", 24)
	// Plug-ins.
	read_list(ini_, "plugins", "folders", &s.plugin_folders)
	read_list(ini_, "plugins", "blocked", &s.blocked)
	s.scan_on_start = app.ini_bool(ini_, "plugins", "scan_on_start", false)
	// Keyboard: read once the actions exist (`keys_apply`).
}

// Writes settings.ini (with what was in it that Pads doesn't know).
settings_save :: proc(a: ^App) {
	s := &a.settings
	ini := &s.ini
	app.ini_set(ini, "appearance", "theme", s.theme.name)
	if base, ok := find_preset(s, s.theme.name); ok {
		write_colors(ini, "appearance.colors", s.theme, base)
	}
	for t in s.presets do write_colors(ini, fmt.tprintf("theme.%s", t.name), t, {})
	app.ini_set_f64(ini, "appearance", "zoom", f64(s.zoom))
	app.ini_set_bool(ini, "appearance", "pad_waveforms", s.pad_waves)
	app.ini_set(ini, "appearance", "control_size", CONTROL_SIZE_NAMES[s.control_size])
	app.ini_set_bool(ini, "appearance", "remember_layout", s.layout)
	app.ini_set(ini, "meters", "scale", METER_SCALE_KEYS[s.meters.scale])
	app.ini_set_bool(ini, "meters", "rms_emphasis", s.meters.rms)
	app.ini_set_f64(ini, "meters", "hold", f64(s.meters.hold_s))
	app.ini_set_f64(ini, "meters", "fall", f64(s.meters.fall_dbs))
	app.ini_set_bool(ini, "mixer", "inserts", s.mixer_view.inserts)
	app.ini_set_bool(ini, "mixer", "eq", s.mixer_view.eq)
	app.ini_set_bool(ini, "mixer", "sends", s.mixer_view.sends)
	app.ini_set_bool(ini, "mixer", "io", s.mixer_view.io)
	app.ini_set_bool(ini, "mixer", "narrow", s.mixer_view.narrow)
	app.ini_set(ini, "audio", "output", s.audio.output)
	app.ini_set(ini, "audio", "input", s.audio.input)
	app.ini_set_f64(ini, "audio", "sample_rate", s.audio.rate)
	app.ini_set_int(ini, "audio", "buffer", s.audio.buffer)
	app.ini_set_f64(ini, "audio", "cue_db", f64(s.audio.cue_db))
	app.ini_set_bool(ini, "audio", "click_on_cue_only", s.audio.click_cue)
	interfaces_save(&s.audio, ini)
	app.ini_set_bool(ini, "midi", "enabled", s.midi_on)
	app.ini_set(ini, "midi", "inputs_off", strings.join(s.midi_off[:], "|", context.temp_allocator))
	app.ini_set(ini, "midi", "output", s.midi_output)
	app.ini_set_bool(ini, "midi", "clock_out", s.clock_out)
	sync_names := [Sync_Mode]string{.Internal = "internal", .Midi_Clock = "midi_clock", .Link = "link"}
	app.ini_set(ini, "midi", "sync", sync_names[s.sync])
	app.ini_set_bool(ini, "midi", "link_start_stop", s.link_start_stop)
	app.ini_set_f64(ini, "midi", "input_offset_ms", f64(s.midi_offset_ms))
	app.ini_set_bool(ini, "recording", "count_in_click", s.count_in_click)
	app.ini_set_bool(ini, "recording", "arm_selected", s.arm_selected)
	app.ini_set_int(ini, "recording", "preroll", int(s.preroll))
	app.ini_set_f64(ini, "project", "tempo", s.default_bpm)
	app.ini_set_int(ini, "project", "beats", s.default_sig[0])
	app.ini_set_int(ini, "project", "beat_unit", s.default_sig[1])
	app.ini_set_int(ini, "project", "bars", s.default_bars)
	app.ini_set_int(ini, "project", "buses", s.default_buses)
	app.ini_set(ini, "project", "folder", s.projects_folder)
	app.ini_set_int(ini, "project", "autosave_minutes", s.autosave_min)
	app.ini_set_bool(ini, "project", "open_last", s.open_last)
	app.ini_set_f64(ini, "project", "export_rate", s.export_rate)
	app.ini_set_int(ini, "project", "export_bits", s.export_bits)
	app.ini_set(ini, "plugins", "folders", strings.join(s.plugin_folders[:], "|", context.temp_allocator))
	app.ini_set(ini, "plugins", "blocked", strings.join(s.blocked[:], "|", context.temp_allocator))
	app.ini_set_bool(ini, "plugins", "scan_on_start", s.scan_on_start)
	for k in s.defaults do app.ini_remove(ini, "keys", k.id)
	for k in s.keys do app.ini_set(ini, "keys", k.id, chord_name(k.chord) if k.chord != 0 else "none")
	if !app.ini_save(ini, s.path) do ui.toast(&a.ws.toasts, .Error, "Could not save the settings")
}

// Frees the settings.
settings_destroy :: proc(s: ^App_Settings) {
	app.ini_destroy(&s.ini)
	delete(s.path)
	for t in s.presets do delete(t.name)
	delete(s.presets)
	audio_free(&s.audio)
	audio_free(&s.staged)
	audio_free(&s.keep.prev)
	if s.devices != nil do backend.device_infos_destroy(s.devices)
	for x in s.midi_off do delete(x)
	delete(s.midi_off)
	delete(s.midi_output)
	delete(s.projects_folder)
	for x in s.plugin_folders do delete(x)
	delete(s.plugin_folders)
	for x in s.blocked do delete(x)
	delete(s.blocked)
	for k in s.keys do delete(k.id)
	delete(s.keys)
	for k in s.defaults do delete(k.id)
	delete(s.defaults)
	delete(s.recording)
}

// The old settings.txt (before settings.ini), read once.
@(private)
migrate_settings_txt :: proc(a: ^App) {
	path := prefs_file(a, "settings.txt")
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		kv := strings.split_n(strings.trim_space(line), "=", 2, context.temp_allocator)
		if len(kv) != 2 do continue
		n, _ := strconv.parse_int(kv[1])
		switch kv[0] {
		case "count_in_click": a.settings.count_in_click = n != 0
		case "preroll":        a.settings.preroll = Preroll(clamp(n, 0, int(max(Preroll))))
		}
	}
}

@(private)
read_list :: proc(ini: ^app.Ini, sec, key: string, out: ^[dynamic]string) {
	v, ok := app.ini_get(ini, sec, key)
	if !ok do return
	for x in strings.split(v, "|", context.temp_allocator) do if strings.trim_space(x) != "" do append(out, strings.clone(strings.trim_space(x)))
}

@(private)
read_colors :: proc(ini: ^app.Ini, sec: string, t: ^ui.Theme) {
	for c in ui.theme_colors(t) {
		v, ok := app.ini_get(ini, sec, c.name)
		if !ok do continue
		v = strings.trim_prefix(v, "#")
		if hex, hok := strconv.parse_u64_of_base(v, 16); hok do c.color^ = ui.rgb(u32(hex))
	}
}

// Writes `t`'s colours to `sec` (only those unlike `base`'s, when one is
// given; all of them else).
@(private)
write_colors :: proc(ini: ^app.Ini, sec: string, t: ui.Theme, base: ui.Theme) {
	t, base := t, base
	tc, bc := ui.theme_colors(&t), ui.theme_colors(&base)
	has_base := base.name != ""
	for c, i in tc {
		if has_base && c.color^ == bc[i].color^ {
			app.ini_remove(ini, sec, c.name)
			continue
		}
		app.ini_set(ini, sec, c.name, hex_of(c.color^))
	}
}

@(private)
hex_of :: proc(c: ui.Color) -> string {
	to :: proc(x: f32) -> u32 { return u32(clamp(x, 0, 1) * 255 + 0.5) }
	return fmt.tprintf("#%02x%02x%02x", to(c.r), to(c.g), to(c.b))
}

// Whether `name` is one of the presets Pads comes with.
@(private)
builtin_preset :: proc(name: string) -> bool {
	for t in ui.theme_presets() do if t.name == name do return true
	return false
}

// The preset named `name`: built in, or the user's.
@(private)
find_preset :: proc(s: ^App_Settings, name: string) -> (ui.Theme, bool) {
	for t in ui.theme_presets() do if t.name == name do return t, true
	for t in s.presets do if t.name == name do return t, true
	return {}, false
}

@(private)
audio_clone :: proc(c: Audio_Config) -> Audio_Config {
	c := c
	c.output, c.input = strings.clone(c.output), strings.clone(c.input)
	c.interfaces = interfaces_clone(c.interfaces)
	return c
}

@(private)
audio_free :: proc(c: ^Audio_Config) {
	delete(c.output)
	delete(c.input)
	interfaces_free(&c.interfaces)
	c^ = {}
}

@(private)
set_string :: proc(s: ^string, v: string) {
	if s^ == v do return
	delete(s^)
	s^ = strings.clone(v)
}

// --- applying -----------------------------------------------------------------------------------

// How large controls are, as chosen in Settings: Auto lets the layout
// decide.
Control_Size :: enum u8 {
	Auto,
	Compact,
	Comfortable,
	Touch,
}

// How each control size is written in settings.ini.
CONTROL_SIZE_NAMES := [Control_Size]string{.Auto = "auto", .Compact = "compact", .Comfortable = "comfortable", .Touch = "touch"}

// A control size from its name in settings.ini (Auto if unknown).
control_size_parse :: proc(s: string) -> Control_Size {
	for n, k in CONTROL_SIZE_NAMES do if n == s do return k
	return .Auto
}

// The density a control size gives (Auto: Comfortable, the size of the
// default layout).
density_for :: proc(c: Control_Size) -> ui.Density {
	switch c {
	case .Compact:     return .Compact
	case .Touch:       return .Touch
	case .Comfortable, .Auto: return .Comfortable
	}
	return .Comfortable
}

// The appearance where it shows: the theme, the zoom, the pads' waveforms.
appearance_apply :: proc(a: ^App) {
	s := &a.settings
	ui.set_theme(&a.platform, s.theme)
	ui.set_zoom(&a.platform, s.zoom)
	ui.set_density(&a.platform, density_for(a.control_size if a.control_size != .Auto else s.control_size))
	a.dark = ui.theme_is_dark(s.theme)
	a.pad_waves = s.pad_waves
}

// The host settings the audio and MIDI settings make.
host_settings :: proc(a: ^App, fake: bool) -> app.Host_Settings {
	s := &a.settings
	hs := app.Host_Settings{
		fake = fake, max_block = 512, ram_bytes = 512 << 20, rebuild_on_rate_change = true,
		output_device = s.audio.output, input_device = s.audio.input,
		sample_rate = s.audio.rate, buffer_frames = s.audio.buffer,
		midi = s.midi_on, midi_output = s.midi_output, midi_inputs_off = s.midi_off[:],
		fake_devices = fake_interfaces[:] if a.fake_interface else nil,
	}
	hs.input_channels, hs.output_channels = channels_wanted(&s.audio)
	return hs
}

// The channels the interfaces in use say to open: their inputs; their
// outputs, with main's pair and the cue pair always.
channels_wanted :: proc(c: ^Audio_Config) -> (inputs, outputs: backend.Channel_Mask) {
	if f := interface_find(c, c.input); f != nil do inputs = f.inputs
	else do inputs = {0, 1}
	f := interface_find(c, c.output)
	if f == nil do return inputs, {0, 1}
	outputs = f.outputs + {f.main, f.main + 1}
	if f.cue >= 0 do outputs += {f.cue, f.cue + 1}
	return
}

// Opens the device with the staged audio settings; kept if `keep` is
// pressed within 10 s, else (or if it fails) the ones before come back.
audio_apply :: proc(a: ^App) {
	s := &a.settings
	audio_free(&s.keep.prev)
	s.keep.prev = audio_clone(s.audio)
	audio_free(&s.audio)
	s.audio = audio_clone(s.staged)
	if !audio_reopen(a) {
		ui.toast(&a.ws.toasts, .Error, "That device would not open: back to the one before")
		audio_revert(a)
		return
	}
	s.keep.active, s.keep.until = true, a.transport.clock + 10
}

// Keeps the audio settings just applied.
audio_keep :: proc(a: ^App) {
	a.settings.keep.active = false
	settings_save(a)
}

// Back to the audio settings before the last Apply.
audio_revert :: proc(a: ^App) {
	s := &a.settings
	s.keep.active = false
	audio_free(&s.audio)
	s.audio = audio_clone(s.keep.prev)
	audio_free(&s.staged)
	s.staged = audio_clone(s.audio)
	audio_reopen(a)
}

// Closes the device and opens it with the settings now (the engine moves
// to a new sample rate if it has one).
@(private)
audio_reopen :: proc(a: ^App) -> bool {
	h := &a.host
	app.host_close(h)
	hs := host_settings(a, h.settings.fake)
	h.settings.output_device, h.settings.input_device = hs.output_device, hs.input_device
	h.settings.sample_rate, h.settings.buffer_frames = hs.sample_rate, hs.buffer_frames
	h.settings.input_channels, h.settings.output_channels = hs.input_channels, hs.output_channels
	ok := app.host_open(h) == .None
	outputs_apply(a)
	return ok
}

// Tells the engine where main, the cue and the click play (from the
// output interface's settings), and that the channels may have changed.
outputs_apply :: proc(a: ^App) {
	s := &a.settings
	o := pm.Outputs{main = 0, cue = -1, cue_db = s.audio.cue_db, click_cue = s.audio.click_cue}
	if f := interface_find(&s.audio, s.audio.output); f != nil do o.main, o.cue = f.main, f.cue
	pm.set_outputs(&a.m.engine, o)
	pm.io_changed(&a.m.engine)
}

// The MIDI settings where they act: the ports, the clock out, what the
// tempo follows.
midi_apply :: proc(a: ^App) {
	s := &a.settings
	h := &a.host
	if !h.settings.fake {
		h.settings.midi, h.settings.midi_output, h.settings.midi_inputs_off = s.midi_on, s.midi_output, s.midi_off[:]
		app.host_midi_reopen(h)
	}
	pm.midi_ports_changed(&a.m.engine) // (the ports' numbers changed)
	sync_apply(a)
}

// What the tempo follows, and the MIDI clock sent.
sync_apply :: proc(a: ^App) {
	s := &a.settings
	e := &a.m.engine
	pm.set_clock_out(e, s.clock_out)
	want := s.sync
	if want == .Link && !padslink.AVAILABLE do want = .Internal
	if want != .Link do padslink.stop(&s.link, a.host.clock)
	switch want {
	case .Internal:   pm.follow_midi_clock(e, nil)
	case .Midi_Clock: pm.follow_midi_clock(e, app.host_block_midi(&a.host))
	case .Link:
		pm.follow_midi_clock(e, nil)
		if !padslink.start(&s.link, a.host.clock, e.timeline, a.m.project.bpm, pm.bar_beats(&a.m.project)) {
			ui.toast(&a.ws.toasts, .Error, "Link would not start")
			s.sync = .Internal
		}
		padslink.set_start_stop(&s.link, s.link_start_stop)
	}
}

// Each frame: the settings where they act now (the engine's count-in
// click, the recording's pre-roll and MIDI offset), a change of audio
// waiting to be kept, and the window when it is open.
draw_settings :: proc(a: ^App) {
	s := &a.settings
	a.m.engine.count_in_click = s.count_in_click
	a.capture.preroll = preroll_beats(s.preroll)
	a.capture.midi_offset = f64(s.midi_offset_ms) / 1000
	if s.keep.active && a.transport.clock >= s.keep.until do audio_revert(a)
	if !s.open {
		if s.keep.active do draw_keep(a)
		return
	}
	// A modal window over the app (it dims behind it), sized to the app's.
	// (The whole window's size, not the work area's: the Library and the
	// pads area take theirs out of that.)
	vp := im.GetMainViewport()
	im.SetNextWindowSize({min(1040, vp.Size.x - 80), min(max(680, vp.Size.y * 0.85), vp.Size.y - 40)}, .Appearing) // (tall: an interface's channel lists)
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y / 2}, .Appearing, {0.5, 0.5})
	if !im.IsPopupOpen("Settings###settings") do im.OpenPopup("Settings###settings")
	if im.BeginPopupModal("Settings###settings", &s.open, {.NoCollapse}) {
		if im.IsWindowAppearing() do refresh_devices(a)
		changed := false
		// The pages, down the left.
		if im.BeginChild("##pages", {190, 0}) {
			for p in Settings_Page {
				if im.Selectable(fmt.ctprintf("%s  %s###page%d", PAGE_ICONS[p], PAGE_NAMES[p], int(p)), s.page == p, {}, {0, 30}) do s.page = p
				ui.name(string(PAGE_NAMES[p]))
			}
			im.Dummy({0, 8})
			im.TextDisabled("%s", cstring("Portable: beside the app") if s.portable else cstring("Kept in"))
			im.PushTextWrapPos(0)
			im.TextDisabled("%s", fmt.ctprintf("%s", s.path))
			im.PopTextWrapPos()
		}
		im.EndChild()
		im.SameLine(0, 12)
		// The page, filling the rest; it scrolls.
		if im.BeginChild("##page", {0, 0}, {}, {}) {
			im.PushFontFloat(a.platform.fonts.semibold, 20)
			im.Text("%s", PAGE_NAMES[s.page])
			im.PopFont()
			im.Separator()
			im.Spacing()
			switch s.page {
			case .Appearance: changed = page_appearance(a)
			case .Audio:      changed = page_audio(a)
			case .Midi:       changed = page_midi(a)
			case .Recording:  changed = page_recording(a)
			case .Project:    changed = page_project(a)
			case .Plugins:    changed = page_plugins(a)
			case .Keyboard:   changed = page_keyboard(a)
			}
		}
		im.EndChild()
		if changed do settings_save(a)
		if s.keep.active do draw_keep(a) // (inside: a popup at the root would close this one)
		im.EndPopup()
	}
	if !s.open {
		delete(s.recording)
		s.recording = "" // (a shortcut being pressed: abandoned)
	}
}

// "Keep these audio settings?": until pressed (or 10 s pass, when they go
// back).
@(private)
draw_keep :: proc(a: ^App) {
	s := &a.settings
	im.OpenPopup("Keep these settings?")
	if im.BeginPopupModal("Keep these settings?", nil, {.AlwaysAutoResize}) {
		left := max(int(s.keep.until - a.transport.clock + 0.99), 0)
		im.Text("%s", fmt.ctprintf("The device is open with the new settings.\nThey go back in %d s unless you keep them.", left))
		im.Spacing()
		if im.Button("Keep") {
			audio_keep(a)
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Go back") {
			audio_revert(a)
			im.CloseCurrentPopup()
		}
		if !s.keep.active do im.CloseCurrentPopup()
		im.EndPopup()
	}
}

@(private)
refresh_devices :: proc(a: ^App) {
	s := &a.settings
	if s.devices != nil do backend.device_infos_destroy(s.devices)
	s.devices = nil
	if d, err := app.host_devices(&a.host); err == .None do s.devices = d
}

// --- the pages ----------------------------------------------------------------------------------

@(private)
label :: proc(text: cstring, width: f32 = 200) {
	im.AlignTextToFramePadding()
	im.TextUnformatted(text)
	im.SameLine(width)
}

@(private)
hint :: proc(text: cstring) {
	im.Indent(200)
	im.PushTextWrapPos(0)
	im.TextDisabled("%s", text)
	im.PopTextWrapPos()
	im.Unindent(200)
	im.Spacing()
}

@(private)
page_appearance :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	label("Theme")
	im.SetNextItemWidth(220)
	if ui.combo("##preset", fmt.ctprintf("%s", s.theme.name)) {
		pick :: proc(a: ^App, t: ui.Theme) {
			a.settings.theme = t
			appearance_apply(a)
		}
		for t in ui.theme_presets() do if im.Selectable(fmt.ctprintf("%s###p%s", t.name, t.name), t.name == s.theme.name) {
			pick(a, t)
			changed = true
		}
		if len(s.presets) > 0 do im.Separator()
		for t in s.presets do if im.Selectable(fmt.ctprintf("%s###u%s", t.name, t.name), t.name == s.theme.name) {
			pick(a, t)
			changed = true
		}
		im.EndCombo()
	}
	im.SameLine()
	if ui.icon_button(ui.ICON_ROTATE_CCW, "Back to the preset's own colours") {
		if base, ok := find_preset(s, s.theme.name); ok {
			s.theme = base
			appearance_apply(a)
			changed = true
		}
	}
	hint("Dark, Light, Midnight, Graphite and Paper come with Pads; your own presets follow.")
	// Every colour.
	label("Colours")
	im.BeginGroup()
	t := &s.theme
	for c, i in ui.theme_colors(t) {
		if i % 2 == 1 do im.SameLine(200)
		col := [3]f32{c.color.r, c.color.g, c.color.b}
		if im.ColorEdit3(fmt.ctprintf("%s##col", c.name), &col, {.NoInputs}) {
			c.color^ = {col[0], col[1], col[2], 1}
			appearance_apply(a)
		}
		if im.IsItemDeactivatedAfterEdit() do changed = true
	}
	im.EndGroup()
	hint("Click a swatch to change it. bg is behind everything, surface the panels, inset the middle tabs, raised the controls; accent marks what is on or chosen.")
	label("Save as preset")
	im.SetNextItemWidth(220)
	im.InputTextWithHint("##presetname", "Name", cstring(&s.preset_name[0]), len(s.preset_name))
	im.SameLine()
	name := strings.trim_space(strings.truncate_to_byte(string(s.preset_name[:]), 0))
	if im.Button("Save") && name != "" {
		if builtin_preset(name) {
			ui.toast(&a.ws.toasts, .Error, "That name is one of Pads' own")
		} else {
			nt := s.theme
			nt.name = strings.clone(name)
			replaced := false
			for &p in s.presets do if p.name == name {
				delete(p.name)
				p = nt
				replaced = true
			}
			if !replaced do append(&s.presets, nt)
			s.theme.name = nt.name
			s.preset_name = {}
			changed = true
		}
	}
	if !builtin_preset(s.theme.name) {
		im.SameLine()
		if im.Button("Delete preset") {
			for p, i in s.presets do if p.name == s.theme.name {
				app.ini_remove_section(&s.ini, fmt.tprintf("theme.%s", p.name))
				delete(p.name)
				ordered_remove(&s.presets, i)
				break
			}
			s.theme = ui.theme_dark()
			appearance_apply(a)
			changed = true
		}
	}
	im.Spacing()
	label("Zoom")
	zoom := f64(s.zoom * 100)
	e := ui.number_drag("zoom", &zoom, 50, 300, 5, 1, "%.0f%%", 120)
	if e.changed {
		s.zoom = f32(zoom) / 100
		appearance_apply(a)
	}
	if e.ended do changed = true
	im.SameLine()
	for z in ([]f32{0.9, 1, 1.25, 1.5}) {
		if im.SmallButton(fmt.ctprintf("%.0f%%", z * 100)) {
			s.zoom = z
			appearance_apply(a)
			changed = true
		}
		im.SameLine()
	}
	im.NewLine()
	hint("Everything drawn larger or smaller, as a browser zooms.")
	label("Control size")
	size := int(s.control_size)
	if ui.segmented("control size", {"Auto", "Compact", "Comfortable", "Touch"}, &size) {
		s.control_size = Control_Size(size)
		appearance_apply(a)
		changed = true
	}
	ui.name("control size")
	hint("Auto: as the layout suits (Comfortable in this one, Touch on a touch screen).")
	label("Pad waveforms")
	if ui.toggle("Show each pad's sound on it", &s.pad_waves) {
		appearance_apply(a)
		changed = true
	}
	label("Layout")
	if ui.toggle("Remember where panels are", &s.layout) do changed = true
	im.SameLine(0, 16)
	if im.Button("Reset layout") do ui.workspace_reset_layout(&a.ws)
	hint("Remembered in layout2.ini beside settings.ini (from the next start).")
	label("Meters")
	mt := &s.meters
	sc := int(mt.scale)
	if ui.segmented("meter scale", {"dBFS", "K-12", "K-14", "K-20"}, &sc) {
		mt.scale = Meter_Scale(sc)
		changed = true
	}
	ui.name("meter scale")
	im.SameLine(0, 12)
	if ui.toggle("RMS emphasis", &mt.rms) do changed = true
	if im.IsItemHovered() do im.SetTooltip("The RMS (average) bar bright and the peak dim, instead of the other way round")
	hold := f64(mt.hold_s)
	if he := ui.number_drag("meter hold", &hold, 0, 10, 0.5, 0.1, "Peak hold %.1f s", 150); he.changed || he.ended {
		mt.hold_s = f32(hold)
		changed = changed || he.ended
	}
	im.SameLine(0, 6)
	fall := f64(mt.fall_dbs)
	if fe := ui.number_drag("meter fall", &fall, 3, 96, 1, 0.5, "Fall %.0f dB/s", 140); fe.changed || fe.ended {
		mt.fall_dbs = f32(fall)
		changed = changed || fe.ended
	}
	hint("dBFS: -60 to +6, 0 the top of the digital scale. K-12, K-14, K-20 (Bob Katz's): 0 on the scale that far under full scale, for mixing to a loudness. Hold: how long the held peak stays (0: none); fall: how fast the bars come down.")
	return
}

// How the level meters read (Settings > Appearance).
Meter_Settings :: struct {
	scale:    Meter_Scale,
	rms:      bool, // the RMS bar the bright one
	hold_s:   f32,  // how long a held peak stays (0: none)
	fall_dbs: f32,  // how fast the bars fall (dB a second)
}

// A meter's scale: dBFS, or one of the K-system's (0 that many dB under
// full scale).
Meter_Scale :: enum u8 {
	Dbfs,
	K12,
	K14,
	K20,
}

// How a scale is written in settings.ini.
METER_SCALE_KEYS := [Meter_Scale]string{.Dbfs = "dbfs", .K12 = "k12", .K14 = "k14", .K20 = "k20"}

@(private)
meter_scale_parse :: proc(s: string) -> Meter_Scale {
	for k, sc in METER_SCALE_KEYS do if k == s do return sc
	return .Dbfs
}

// The Mixer's strips: which sections show, and their width (the Mixer's
// bar toggles them; kept in settings.ini).
Mixer_View :: struct {
	inserts, eq, sends, io: bool,
	narrow:                 bool,
}

@(private)
page_audio :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	h := &a.host
	st := &s.staged
	device_name :: proc(s: ^App_Settings, id: string, output: bool) -> string {
		if id == "" do return "System default"
		for d in s.devices do if d.id == id do return d.name
		return id
	}
	if h.settings.fake {
		im.TextColored(transmute(im.Vec4)ui.theme().warn, "Running with the simulated device (--fake): its own devices are listed; the others apply on a normal start.")
		im.Spacing()
	}
	// The interfaces.
	label("Output")
	im.SetNextItemWidth(360)
	if ui.combo("##out", fmt.ctprintf("%s", device_name(s, st.output, true))) {
		if im.Selectable("System default", st.output == "") do set_string(&st.output, "")
		for d in s.devices do if d.output_channels > 0 {
			if im.Selectable(fmt.ctprintf("%s###o%s", d.name, d.id), d.id == st.output) do set_string(&st.output, d.id)
		}
		im.EndCombo()
	}
	ui.name("output interface")
	label("Input")
	im.SetNextItemWidth(360)
	if ui.combo("##in", fmt.ctprintf("%s", device_name(s, st.input, false))) {
		if im.Selectable("System default", st.input == "") do set_string(&st.input, "")
		for d in s.devices do if d.input_channels > 0 {
			if im.Selectable(fmt.ctprintf("%s###i%s", d.name, d.id), d.id == st.input) do set_string(&st.input, d.id)
		}
		im.EndCombo()
	}
	ui.name("input interface")
	im.SameLine()
	if ui.icon_button(ui.ICON_REFRESH_CW, "Look for devices again") do refresh_devices(a)
	// What is not there, and what can't be.
	warn :: proc(text: string) {
		im.Dummy({200, 0})
		im.SameLine(200)
		im.TextColored(transmute(im.Vec4)ui.theme().warn, "%s", fmt.ctprintf("%s", text))
	}
	out_dev := find_device(s, st.output, true)
	in_dev := find_device(s, st.input, false)
	if st.output != "" && out_dev == nil do warn(fmt.tprintf("%s is not connected: the system's output plays until it is back.", device_name(s, st.output, true)))
	if st.input != "" && in_dev == nil do warn(fmt.tprintf("%s is not connected: the system's input is used until it is back.", device_name(s, st.input, false)))
	when ODIN_OS == .Darwin {
		if st.input != "" && st.output != "" && st.input != st.output do warn("Separate input and output interfaces need an aggregate device on macOS (Audio MIDI Setup).")
	}
	// What the output device offers.
	dev := out_dev
	label("Sample rate")
	im.SetNextItemWidth(200)
	if ui.combo("##rate", fmt.ctprintf("%s", "The device's" if st.rate == 0 else fmt.tprintf("%.0f Hz", st.rate))) {
		if im.Selectable("The device's", st.rate == 0) do st.rate = 0
		rates := []f64{44_100, 48_000, 88_200, 96_000, 176_400, 192_000}
		if dev != nil && len(dev.sample_rates) > 0 do rates = dev.sample_rates
		for r in rates do if im.Selectable(fmt.ctprintf("%.0f Hz", r), r == st.rate) do st.rate = r
		im.EndCombo()
	}
	label("Buffer size")
	im.SetNextItemWidth(200)
	if ui.combo("##buffer", fmt.ctprintf("%s", "The device's" if st.buffer == 0 else fmt.tprintf("%d frames", st.buffer))) {
		if im.Selectable("The device's", st.buffer == 0) do st.buffer = 0
		sizes := []int{32, 64, 128, 256, 512, 1024, 2048}
		if dev != nil && len(dev.buffer_sizes) > 0 do sizes = dev.buffer_sizes
		rate := h.format.sample_rate if h.format.sample_rate > 0 else 48_000
		for n in sizes do if im.Selectable(fmt.ctprintf("%d frames (%.1f ms)", n, f64(n) * 1000 / rate), n == st.buffer) do st.buffer = n
		im.EndCombo()
	}
	hint("Smaller is quicker to answer a pad, but asks more of the computer; raise it if you hear crackles.")
	// Each interface's channels, and where main and the cue play.
	// (Side by side: inputs, outputs.)
	if im.BeginTable("##channels", 2, {.SizingStretchSame}) {
		im.TableNextColumn()
		channel_list(a, st, in_dev, false)
		im.TableNextColumn()
		channel_list(a, st, out_dev, true)
		im.EndTable()
	}
	of := interface_for(st, st.output)
	pairs := mask_pairs(of.outputs + {of.main, of.main + 1})
	label("Main output")
	im.SetNextItemWidth(260)
	if ui.combo("##mainout", fmt.ctprintf("%s", pair_label(of, out_dev, true, of.main))) {
		for p in pairs do if im.Selectable(fmt.ctprintf("%s###mp%d", pair_label(of, out_dev, true, p), p), p == of.main) do of.main = p
		im.EndCombo()
	}
	ui.name("main output")
	label("Cue output")
	im.SetNextItemWidth(260)
	if ui.combo("##cueout", fmt.ctprintf("%s", "None" if of.cue < 0 else pair_label(of, out_dev, true, of.cue))) {
		if im.Selectable("None", of.cue < 0) do of.cue = -1
		for p in pairs do if p != of.main && im.Selectable(fmt.ctprintf("%s###cp%d", pair_label(of, out_dev, true, p), p), p == of.cue) do of.cue = p
		im.EndCombo()
	}
	ui.name("cue output")
	if of.cue >= 0 {
		im.SameLine()
		cue := f64(st.cue_db)
		if ui.number_drag("cue level", &cue, -60, 6, 0.5, 0.1, "%.1f dB", 110).changed do st.cue_db = f32(cue)
		im.SameLine()
		ui.toggle("Click on the cue only", &st.click_cue)
	}
	hint("The cue output is a headphones mix: each track's cue send, and the click.")
	// Apply: staged until then.
	pending := st.output != s.audio.output || st.input != s.audio.input || st.rate != s.audio.rate || st.buffer != s.audio.buffer || st.cue_db != s.audio.cue_db || st.click_cue != s.audio.click_cue || !interfaces_equal(st.interfaces, s.audio.interfaces)
	im.Dummy({200, 0})
	im.SameLine(200)
	im.BeginDisabled(!pending)
	if im.Button("Apply") do audio_apply(a)
	im.SameLine()
	if im.Button("Undo changes") {
		audio_free(st)
		s.staged = audio_clone(s.audio)
	}
	im.EndDisabled()
	if pending {
		im.SameLine()
		im.TextColored(transmute(im.Vec4)ui.theme().warn, "Not applied yet")
	}
	// What the device left out (asked for, not there).
	if h.missing_inputs != {} || h.missing_outputs != {} {
		warn(fmt.tprintf("Not on this interface: %s%s%s", fmt.tprintf("inputs %s", mask_text(h.missing_inputs)) if h.missing_inputs != {} else "", "; " if h.missing_inputs != {} && h.missing_outputs != {} else "", fmt.tprintf("outputs %s", mask_text(h.missing_outputs)) if h.missing_outputs != {} else ""))
	}
	// What it runs at, and how it is doing.
	im.Spacing()
	im.SeparatorText("The engine now")
	f := h.format
	rate := f.sample_rate if f.sample_rate > 0 else 1
	ms :: proc(frames: int, rate: f64) -> f64 { return f64(frames) * 1000 / rate }
	i, o, rt := app.host_latency(h)
	rows := [?][2]string{
		{"Device", fmt.tprintf("%s%s", device_name(s, s.audio.output, true), " (simulated)" if h.settings.fake else "")},
		{"Sample rate", fmt.tprintf("%.0f Hz", f.sample_rate)},
		{"Buffer", fmt.tprintf("%d frames, %.1f ms", f.buffer_frames, ms(f.buffer_frames, rate))},
		{"Latency", fmt.tprintf("in %.1f ms, out %.1f ms, round trip %.1f ms (%d frames)", ms(i, rate), ms(o, rate), ms(rt, rate), rt)},
		{"Engine block", fmt.tprintf("up to %d frames", h.settings.max_block)},
		{"Channels", fmt.tprintf("%d out, %d in", h.settings.outputs, h.settings.inputs)},
		{"Dropouts", fmt.tprintf("%d since start", h.xruns)},
	}
	for r in rows {
		label(fmt.ctprintf("%s", r[0]))
		im.TextUnformatted(fmt.ctprintf("%s", r[1]))
	}
	label("Load")
	load := app.host_load(h)
	t := ui.theme()
	c := t.ok if load < 0.6 else (t.warn if load < 0.9 else t.danger)
	im.PushStyleColorVec4(.PlotHistogram, transmute(im.Vec4)c)
	im.ProgressBar(min(load, 1), {260, 0}, fmt.ctprintf("%.0f%% of each buffer's time", load * 100))
	im.PopStyleColor()
	hint("How much of the time each buffer lasts the engine takes to make it: above 100% it can't keep up and you hear dropouts.")
	return
}

@(private)
page_midi :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	h := &a.host
	label("MIDI")
	if ui.toggle("Use MIDI devices", &s.midi_on) {
		midi_apply(a)
		changed = true
	}
	ports := app.host_midi_ports(h, context.temp_allocator)
	label("Inputs")
	im.BeginGroup()
	any_in := false
	for p in ports do if p.direction == .Input {
		any_in = true
		on := true
		for x in s.midi_off do if x == p.id do on = false
		if ui.toggle(fmt.ctprintf("%s###in%s", p.name, p.id), &on) {
			if on {
				for x, k in s.midi_off do if x == p.id {
					delete(x)
					ordered_remove(&s.midi_off, k)
					break
				}
			} else {
				append(&s.midi_off, strings.clone(p.id))
			}
			midi_apply(a)
			changed = true
		}
	}
	if !any_in do im.TextDisabled("%s", cstring("No MIDI inputs") if s.midi_on else cstring("MIDI is off"))
	im.EndGroup()
	label("Output")
	im.SetNextItemWidth(300)
	out_name := "None"
	for p in ports do if p.direction == .Output && p.id == s.midi_output do out_name = p.name
	if ui.combo("##midiout", fmt.ctprintf("%s", out_name)) {
		if im.Selectable("None", s.midi_output == "") {
			set_string(&s.midi_output, "")
			midi_apply(a)
			changed = true
		}
		for p in ports do if p.direction == .Output {
			if im.Selectable(fmt.ctprintf("%s###mo%s", p.name, p.id), p.id == s.midi_output) {
				set_string(&s.midi_output, p.id)
				midi_apply(a)
				changed = true
			}
		}
		im.EndCombo()
	}
	hint("Pads' MIDI out (a pad's hits) and the clock go here.")
	sent, received := app.host_midi_counts(h)
	label("Activity")
	im.TextUnformatted(fmt.ctprintf("%d in, %d out", received, sent))
	label("Input offset")
	off := f64(s.midi_offset_ms)
	e := ui.number_drag("midi offset", &off, -100, 100, 1, 0.1, "%.1f ms", 120)
	if e.changed do s.midi_offset_ms = f32(off)
	if e.ended do changed = true
	hint("MIDI notes are recorded this much earlier (positive) to make up for a controller's own delay.")
	im.SeparatorText("Sync")
	label("Tempo follows")
	im.SetNextItemWidth(220)
	names := [Sync_Mode]cstring{.Internal = "Pads (its own tempo)", .Midi_Clock = "MIDI clock in", .Link = "Ableton Link"}
	if ui.combo("##sync", names[s.sync]) {
		for m in Sync_Mode {
			if m == .Link && !padslink.AVAILABLE {
				im.BeginDisabled()
				im.Selectable("Ableton Link (not built in)", false)
				im.EndDisabled()
				continue
			}
			if im.Selectable(names[m], m == s.sync) {
				s.sync = m
				sync_apply(a)
				changed = true
			}
		}
		im.EndCombo()
	}
	switch s.sync {
	case .Internal: hint("Pads keeps its own tempo.")
	case .Midi_Clock:
		f := pm.midi_clock_heard(&a.m.engine)
		hint(fmt.ctprintf("The tempo, Start, Stop and position come from the MIDI clock at the inputs: %s.", fmt.tprintf("%.1f BPM, %s", f.bpm, "running" if f.running else "stopped") if f.bpm > 0 else "none heard yet"))
	case .Link:
		label("Start and stop")
		if ui.toggle("With the session", &s.link_start_stop) {
			padslink.set_start_stop(&s.link, s.link_start_stop)
			changed = true
		}
		hint(fmt.ctprintf("%d other app%s in the session.", padslink.peers(&s.link), "" if padslink.peers(&s.link) == 1 else "s"))
	}
	if !padslink.AVAILABLE && s.sync != .Link do hint("Ableton Link isn't in this build: run ./scripts/link.sh (or task deps), then build Pads again.")
	label("Clock out")
	if ui.toggle("Send MIDI clock to the output", &s.clock_out) {
		sync_apply(a)
		changed = true
	}
	hint("24 ticks a beat, with Start, Stop and Song Position, for drum machines and sequencers to follow.")
	im.SeparatorText("Control surfaces")
	im.TextDisabled("Coming: loading a surface script and giving it MIDI ports (see TODO.md).")
	return
}

@(private)
page_recording :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	label("Arming")
	if ui.toggle("Arm the selected track", &s.arm_selected) do changed = true
	hint("Selecting a track arms it (and the one before goes back, unless you armed it yourself). Cmd-click an arm button to arm more than one. Armed audio tracks record their input; armed sampler tracks play and record their own MIDI input.")
	label("Count-in")
	if ui.toggle("Count-in clicks with the metronome off", &s.count_in_click) do changed = true
	hint("The bars counted in before recording always click.")
	label("Early hits")
	im.SetNextItemWidth(200)
	if ui.combo("##preroll", PREROLL_NAMES[s.preroll]) {
		for p in Preroll do if im.Selectable(PREROLL_NAMES[p], p == s.preroll) {
			s.preroll = p
			changed = true
		}
		im.EndCombo()
	}
	hint("A hit this much before a sequence's first beat (at the end of the loop, or of the count-in) is recorded on it.")
	return
}

@(private)
page_project :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	im.TextDisabled("What a new project starts with, and how projects are kept.")
	im.Spacing()
	label("Tempo")
	bpm := s.default_bpm
	if e := ui.number_drag("default tempo", &bpm, 40, 300, 1, 0.1, "%.1f BPM", 140); e.changed {
		s.default_bpm = bpm
		changed = true
	}
	label("Time signature")
	beats, unit := f64(s.default_sig[0]), f64(s.default_sig[1])
	if ui.number_drag("default beats", &beats, 1, 16, 1, 1, "%.0f", 60).changed {
		s.default_sig[0] = int(beats)
		changed = true
	}
	im.SameLine()
	im.TextUnformatted("/")
	im.SameLine()
	im.SetNextItemWidth(80)
	if ui.combo("##unit", fmt.ctprintf("%d", s.default_sig[1])) {
		for u in ([]int{2, 4, 8, 16}) do if im.Selectable(fmt.ctprintf("%d", u), u == s.default_sig[1]) {
			s.default_sig[1] = u
			changed = true
		}
		im.EndCombo()
	}
	_ = unit
	label("Sequence length")
	bars := f64(s.default_bars)
	if ui.number_drag("default bars", &bars, 1, f64(pm.MAX_BARS), 1, 1, "%.0f bars", 120).changed {
		s.default_bars = int(bars)
		changed = true
	}
	label("Buses")
	buses := f64(s.default_buses)
	if ui.number_drag("default buses", &buses, 1, f64(pm.BUSES), 1, 1, "%.0f", 120).changed {
		s.default_buses = int(buses)
		changed = true
	}
	im.Spacing()
	label("Projects folder")
	im.TextUnformatted(fmt.ctprintf("%s", s.projects_folder if s.projects_folder != "" else "Documents"))
	im.SameLine()
	if im.SmallButton("Choose…") do choose_folder(a, .Projects)
	if s.projects_folder != "" {
		im.SameLine()
		if im.SmallButton("Documents") {
			set_string(&s.projects_folder, "")
			changed = true
		}
	}
	hint("Where Save starts for a new project.")
	label("Autosave (a backup)")
	im.SetNextItemWidth(160)
	if ui.combo("##autosave", fmt.ctprintf("%s", "Off" if s.autosave_min == 0 else fmt.tprintf("Every %d min", s.autosave_min))) {
		for m in ([]int{0, 1, 2, 5, 10}) do if im.Selectable(fmt.ctprintf("%s", "Off" if m == 0 else fmt.tprintf("Every %d min", m)), m == s.autosave_min) {
			s.autosave_min = m
			changed = true
		}
		im.EndCombo()
	}
	hint("A copy of unsaved changes beside the project, for if Pads stops without closing; the project itself saves only when you save.")
	label("On start")
	if ui.toggle("Open the last project", &s.open_last) do changed = true
	im.SeparatorText("Export")
	label("Sample rate")
	im.SetNextItemWidth(160)
	if ui.combo("##exrate", fmt.ctprintf("%.0f Hz", s.export_rate)) {
		for r in ([]f64{44_100, 48_000, 88_200, 96_000}) do if im.Selectable(fmt.ctprintf("%.0f Hz", r), r == s.export_rate) {
			s.export_rate = r
			changed = true
		}
		im.EndCombo()
	}
	label("Bit depth")
	im.SetNextItemWidth(160)
	if ui.combo("##exbits", fmt.ctprintf("%s", "32-bit float" if s.export_bits == 32 else fmt.tprintf("%d-bit", s.export_bits))) {
		for b in ([]int{16, 24, 32}) do if im.Selectable(fmt.ctprintf("%s", "32-bit float" if b == 32 else fmt.tprintf("%d-bit", b)), b == s.export_bits) {
			s.export_bits = b
			changed = true
		}
		im.EndCombo()
	}
	if changed do project_defaults_apply(a)
	return
}

// What a new project starts with, and how exports and autosaves go, from
// the settings.
project_defaults_apply :: proc(a: ^App) {
	s := &a.settings
	a.m.defaults = {bpm = s.default_bpm, sig = {s.default_sig[0], s.default_sig[1]}, bars = s.default_bars, buses = s.default_buses}
	a.proj.settings.rate = s.export_rate
	a.proj.settings.encoding = .Int16 if s.export_bits == 16 else (.Float32 if s.export_bits == 32 else .Int24)
}

// A folder the settings ask for (the system's dialog; it comes back on the bus).
Folder_Chosen :: struct {
	what: enum u8 {Projects, Plugins},
	path: string,
}

// The device listed under `id` ("": the system's default input or output).
@(private)
find_device :: proc(s: ^App_Settings, id: string, output: bool) -> ^backend.Device_Info {
	for &d in s.devices do if d.id == id || (id == "" && (d.is_default_output if output else d.is_default_input)) do return &d
	return nil
}

// An interface's inputs or outputs, a row each: on or off, its number, the
// driver's name, an alias to type, and (inputs, open) its level. Channels
// saved but not on the interface now show apart, to forget.
@(private)
channel_list :: proc(a: ^App, st: ^Audio_Config, dev: ^backend.Device_Info, output: bool) {
	f := interface_for(st, st.output if output else st.input)
	mask := &f.outputs if output else &f.inputs
	im.SeparatorText("Outputs" if output else "Inputs")
	n := 0
	if dev != nil do n = min(dev.output_channels if output else dev.input_channels, 64)
	if n == 0 {
		im.TextDisabled("%s", fmt.ctprintf("No %s on this interface.", "outputs" if output else "inputs"))
		return
	}
	im.PushIDInt(i32(1 if output else 0))
	defer im.PopID()
	if im.SmallButton("All") do for c in 0 ..< n do mask^ += {c}
	ui.name(fmt.tprintf("%s all", "outputs" if output else "inputs"))
	im.SameLine()
	if im.SmallButton("None") do mask^ = {}
	ui.name(fmt.tprintf("%s none", "outputs" if output else "inputs"))
	names := dev.output_channel_names if output else dev.input_channel_names
	x0: f32 = 0 // (in a table cell, SameLine counts from the cell's start)
	col_w := im.GetContentRegionAvail().x
	for c in 0 ..< n {
		im.PushIDInt(i32(c))
		on := c in mask^
		locked := output && (c == f.main || c == f.main + 1) // (main's pair stays open)
		im.BeginDisabled(locked)
		if ui.toggle(fmt.ctprintf("%s %d", "Out" if output else "In", c + 1), &on) {
			if on do mask^ += {c}
			else do mask^ -= {c}
		}
		im.EndDisabled()
		if locked && im.IsItemHovered({.AllowWhenDisabled}) do im.SetTooltip("Main plays here (choose another main output to turn it off)")
		im.SameLine(x0 + 96)
		driver := names[c] if c < len(names) else ""
		im.TextDisabled("%s", fmt.ctprintf("%s", driver if driver != "" else "—"))
		im.SameLine(x0 + 190)
		buf: [32]u8
		copy(buf[:len(buf) - 1], channel_alias(f, output, c))
		im.SetNextItemWidth(clamp(col_w - 290, 90, 170))
		if im.InputTextWithHint("##alias", "Name it…", cstring(&buf[0]), len(buf)) {
			set_channel_alias(f, output, c, strings.truncate_to_byte(string(buf[:]), 0))
		}
		ui.name(fmt.tprintf("%s %d alias", "out" if output else "in", c + 1))
		// A pair open on the interface in use: its test tone.
		if output && c % 2 == 0 && interface_key(a.settings.audio.output) == f.id && app.host_output_channel(&a.host, c) >= 0 && app.host_output_channel(&a.host, c + 1) >= 0 {
			im.SameLine(x0 + col_w - 90)
			if im.SmallButton(fmt.ctprintf("%s Test %d/%d", ui.ICON_VOLUME_2, c + 1, c + 2)) do pm.test_tone(&a.m.engine, c)
			ui.name(fmt.tprintf("test %d/%d", c + 1, c + 2))
			if im.IsItemHovered() do im.SetTooltip("A second of tone on this pair, to find which speaker it is")
		}
		if !output {
			if g := app.host_input_channel(&a.host, c); g >= 0 && interface_key(a.settings.audio.input) == f.id {
				im.SameLine(x0 + col_w - 90)
				level_bar(input_view(a, g).peak, 84, 10)
				ui.name(fmt.tprintf("input meter %d", c + 1))
			}
		}
		im.PopID()
	}
	// Saved, but not on this interface (now): kept until forgotten.
	gone := mask^ - channel_mask(n)
	if gone != {} {
		im.TextColored(transmute(im.Vec4)ui.theme().warn, "%s", fmt.ctprintf("%s %s: not on this interface (kept for when it is)", "Outputs" if output else "Inputs", mask_text(gone)))
		im.SameLine()
		if im.SmallButton("Forget them") do mask^ -= gone
	}
}

// Channels 0..<n.
@(private)
channel_mask :: proc(n: int) -> (m: backend.Channel_Mask) {
	for c in 0 ..< min(n, 64) do m += {c}
	return
}
