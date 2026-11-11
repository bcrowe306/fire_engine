package pads

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "app:ui"
import im "deps:imgui"

// The app's settings (File > Settings…, Cmd+,), kept with the preferences
// (settings.txt), the same for every project.
App_Settings :: struct {
	count_in_click: bool,    // the count-in clicks even with the metronome off (default on)
	preroll:        Preroll, // how early a hit before a sequence's downbeat still goes on it
	open:           bool,    // the window shows
}

// How early a hit before a sequence's downbeat still goes on it while
// recording.
Preroll :: enum u8 {
	Off,
	Thirty_Second,
	Sixteenth,
	Eighth,
}

// The settings a new install starts with.
DEFAULT_SETTINGS :: App_Settings{count_in_click = true, preroll = .Sixteenth}

// Pre-roll names, as the window shows them.
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

// Reads the settings (missing ones keep their defaults).
settings_load :: proc(a: ^App) {
	a.settings = DEFAULT_SETTINGS
	path := prefs_file(a, "settings.txt")
	if path == "" do return
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

// Writes the settings.
settings_save :: proc(a: ^App) {
	path := prefs_file(a, "settings.txt")
	if path == "" do return
	s := a.settings
	text := fmt.tprintf("count_in_click=%d\npreroll=%d\n", 1 if s.count_in_click else 0, int(s.preroll))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

// Each frame: the settings where they act (the engine's count-in click,
// the recording's pre-roll), and the window when it is open.
draw_settings :: proc(a: ^App) {
	a.m.engine.count_in_click = a.settings.count_in_click
	a.capture.preroll = preroll_beats(a.settings.preroll)
	if !a.settings.open do return
	im.OpenPopup("Settings")
	if im.BeginPopupModal("Settings", &a.settings.open, {.AlwaysAutoResize}) {
		changed := false
		im.SeparatorText("Recording")
		if ui.toggle("Count-in clicks with the metronome off", &a.settings.count_in_click) do changed = true
		im.TextDisabled("The bars counted in before recording always click.")
		im.Spacing()
		im.AlignTextToFramePadding()
		im.Text("Early hits go on the downbeat")
		im.SameLine()
		im.SetNextItemWidth(160)
		if ui.combo("##preroll", PREROLL_NAMES[a.settings.preroll]) {
			for p in Preroll do if im.Selectable(PREROLL_NAMES[p], p == a.settings.preroll) {
				a.settings.preroll = p
				changed = true
			}
			im.EndCombo()
		}
		im.TextDisabled("A hit this much before a sequence's first beat (at the end of the loop,\nor of the count-in) is recorded on it.")
		im.Spacing()
		if im.Button("Done") || im.IsKeyPressed(.Escape) {
			a.settings.open = false
			im.CloseCurrentPopup()
		}
		if changed do settings_save(a)
		im.EndPopup()
	}
}
