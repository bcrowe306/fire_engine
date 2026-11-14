package pads_api

import "core:strings"

import pc "../core"

// What a setting is (`settings_info`).
Setting_Kind :: enum i32 {
	Bool,
	Int,    // a whole number in min..max
	Number, // a number in min..max
	Choice, // one of its choices
	Text,   // words (a folder, a port's name)
}

// What part of Pads a setting changes (applied when it is set: the
// audio device reopened, the MIDI ports, what the tempo follows...).
Setting_Group :: enum i32 {
	Appearance,
	Audio,
	Midi,
	Sync,
	Recording,
	Project,
	Plugins,
}

// What setting `name` is.
Setting_Info :: struct {
	kind:    Setting_Kind,
	group:   Setting_Group,
	min:     f64, // Int and Number
	max:     f64,
	choices: i64, // Choice: how many (settings_choice)
}

// Settings there are (settings_name lists them).
settings_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(api.core.registry.list)), .Ok
}

// Setting `index`'s name: "section.key", as settings.ini has it
// ("project.tempo", "midi.sync"). Temporary.
settings_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	l := api.core.registry.list
	if index < 0 || index >= i64(len(l)) do return "", fail(api, .Not_Found, "no such setting")
	return l[index].name, .Ok
}

// What setting `name` is: its kind, its group, its range or choices.
settings_info :: proc(api: ^Api, name: string) -> (Setting_Info, Result) {
	s, r := find(api, name)
	if r != .Ok do return {}, r
	return {kind = Setting_Kind(s.kind), group = Setting_Group(s.group), min = s.min, max = s.max, choices = i64(len(s.choices))}, .Ok
}

// What setting `name` does, in a few words. Temporary.
settings_about :: proc(api: ^Api, name: string) -> (string, Result) {
	s, r := find(api, name)
	if r != .Ok do return "", r
	return s.about, .Ok
}

// Choice `index` of setting `name` ("Midi_Clock"). Temporary.
settings_choice :: proc(api: ^Api, name: string, index: i64) -> (string, Result) {
	s, r := find(api, name)
	if r != .Ok do return "", r
	if index < 0 || index >= i64(len(s.choices)) do return "", fail(api, .Not_Found, "no such choice")
	return s.choices[index], .Ok
}

// Setting `name` as a number: a Bool's 0 or 1, a Choice's index (a Text's 0).
settings_get_number :: proc(api: ^Api, name: string) -> (f64, Result) {
	s, r := find(api, name)
	if r != .Ok do return 0, r
	return pc.setting_number(s), .Ok
}

// Setting `name` as text: "true", "120", a choice's name, a folder.
// Temporary.
settings_get_text :: proc(api: ^Api, name: string) -> (string, Result) {
	s, r := find(api, name)
	if r != .Ok do return "", r
	return pc.setting_text(s), .Ok
}

// Sets setting `name` to `value` (a Bool: nonzero is true; a Choice: its
// index), applies it and saves the settings. Invalid_Argument out of its
// range; Io_Error if it couldn't be applied (it is put back).
settings_set_number :: proc(api: ^Api, name: string, value: f64) -> Result {
	s, r := find(api, name)
	if r != .Ok do return r
	return result(api, pc.setting_set_number(api.core, s, value))
}

// Sets setting `name` from text (a Text's words, a Choice's name, "true"
// or "false", a number), applies it and saves the settings.
settings_set_text :: proc(api: ^Api, name: string, value: string) -> Result {
	s, r := find(api, name)
	if r != .Ok do return r
	return result(api, pc.setting_set_text(api.core, s, value))
}

@(private)
find :: proc(api: ^Api, name: string) -> (^pc.Setting, Result) {
	s := pc.setting_find(api.core, name)
	if s == nil do return nil, failf(api, .Not_Found, "no setting ", name)
	return s, .Ok
}

@(private)
clone_temp :: proc(s: string) -> string {
	return strings.clone(s, context.temp_allocator)
}
