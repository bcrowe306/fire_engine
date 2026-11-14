package pads_core

import "core:fmt"
import "core:strconv"
import "core:strings"

// Pads' settings, by name: each a value the app keeps (settings.ini's
// section and key: "project.tempo"), registered with what it is, its
// range or choices, and what applying it means. The API reads and sets
// them generically; the app registers them once at the start.

// What a setting is.
Setting_Kind :: enum i32 {
	Bool,
	Int,    // a whole number in min..max
	Number, // a number in min..max
	Choice, // one of its choices (by index, or by name as text)
	Text,   // words (a folder, a port's name)
}

// What setting it changes: the app applies the group (reopens the audio
// device, the MIDI ports...) and saves the settings.
Setting_Group :: enum i32 {
	Appearance,
	Audio,
	Midi,
	Sync,
	Recording,
	Project,
	Plugins,
}

// Where a setting's value is kept (the field `ptr` points at).
Setting_Store :: enum u8 {
	Bool,   // ^bool
	Int,    // ^int
	F64,    // ^f64
	F32,    // ^f32
	U8,     // ^u8 (an enum: Choice)
	String, // ^string (owned by the app's allocator)
}

// One setting, as registered.
Setting :: struct {
	name:    string, // "section.key", as in settings.ini (static)
	kind:    Setting_Kind,
	group:   Setting_Group,
	store:   Setting_Store,
	ptr:     rawptr,
	min, max: f64,     // Int and Number
	choices: []string, // Choice: its names, in its values' order (static)
	about:   string,   // what it does, in a few words (static)
}

// The registered settings.
Settings :: struct {
	list:    [dynamic]Setting,
	changed: proc(user: rawptr, group: Setting_Group) -> bool, // apply and save; false if it couldn't be applied (and was put back)
	user:    rawptr,
	version: u64, // goes up with every change (here, or saved by the app's own window: `settings_touched`)
}

// Notes that the settings changed (the app's Settings window saved them).
settings_touched :: proc(c: ^Core) {
	c.registry.version += 1
}

// Registers setting `s` (control thread, at the start).
setting_register :: proc(c: ^Core, s: Setting) {
	append(&c.registry.list, s)
}

// Frees the registry.
settings_destroy :: proc(c: ^Core) {
	delete(c.registry.list)
	c.registry.list = nil
}

// The setting called `name`, or nil.
setting_find :: proc(c: ^Core, name: string) -> ^Setting {
	for &s in c.registry.list do if s.name == name do return &s
	return nil
}

// A setting's value as a number: a Bool's 0 or 1, a Choice's index; a
// Text's 0.
setting_number :: proc(s: ^Setting) -> f64 {
	switch s.store {
	case .Bool:   return 1 if (^bool)(s.ptr)^ else 0
	case .Int:    return f64((^int)(s.ptr)^)
	case .F64:    return (^f64)(s.ptr)^
	case .F32:    return f64((^f32)(s.ptr)^)
	case .U8:     return f64((^u8)(s.ptr)^)
	case .String: return 0
	}
	return 0
}

// A setting's value as text: "true", "120", "Midi_Clock", a folder
// (temporary).
setting_text :: proc(s: ^Setting) -> string {
	switch s.kind {
	case .Bool:   return "true" if (^bool)(s.ptr)^ else "false"
	case .Text:   return (^string)(s.ptr)^
	case .Choice:
		k := int((^u8)(s.ptr)^)
		return s.choices[k] if k < len(s.choices) else fmt.tprint(k)
	case .Int, .Number:
		return fmt.tprint(setting_number(s))
	}
	return ""
}

// Sets setting `s` to number `v` (a Bool: nonzero; a Choice: its index),
// then the app applies it and saves.
setting_set_number :: proc(c: ^Core, s: ^Setting, v: f64) -> Outcome {
	switch s.kind {
	case .Text:
		return outcome(c, .Invalid, "a text setting: set it as text")
	case .Choice:
		if v != f64(int(v)) || v < 0 || int(v) >= len(s.choices) do return outcome(c, .Invalid, fmt.tprintf("%s is one of %d choices", s.name, len(s.choices)))
	case .Int:
		if v != f64(int(v)) do return outcome(c, .Invalid, fmt.tprintf("%s is a whole number", s.name))
		fallthrough
	case .Number:
		if !(v >= s.min && v <= s.max) do return outcome(c, .Invalid, fmt.tprintf("%s is %g..%g", s.name, s.min, s.max))
	case .Bool:
	}
	switch s.store {
	case .Bool:   (^bool)(s.ptr)^ = v != 0
	case .Int:    (^int)(s.ptr)^ = int(v)
	case .F64:    (^f64)(s.ptr)^ = v
	case .F32:    (^f32)(s.ptr)^ = f32(v)
	case .U8:     (^u8)(s.ptr)^ = u8(v)
	case .String:
	}
	return setting_changed(c, s)
}

// Sets setting `s` from text: a Text's words, a Choice's name, "true" or
// "false", a number.
setting_set_text :: proc(c: ^Core, s: ^Setting, v: string) -> Outcome {
	switch s.kind {
	case .Text:
		p := (^string)(s.ptr)
		delete(p^)
		p^ = strings.clone(v)
		return setting_changed(c, s)
	case .Choice:
		for n, k in s.choices do if strings.equal_fold(n, v) do return setting_set_number(c, s, f64(k))
		return outcome(c, .Invalid, fmt.tprintf("%s is one of %s", s.name, strings.join(s.choices, ", ", context.temp_allocator)))
	case .Bool:
		switch v {
		case "true", "on", "1":   return setting_set_number(c, s, 1)
		case "false", "off", "0": return setting_set_number(c, s, 0)
		}
		return outcome(c, .Invalid, fmt.tprintf("%s is true or false", s.name))
	case .Int, .Number:
		x, ok := strconv.parse_f64(v)
		if !ok do return outcome(c, .Invalid, fmt.tprintf("%s is a number", s.name))
		return setting_set_number(c, s, x)
	}
	return .Ok
}

@(private)
setting_changed :: proc(c: ^Core, s: ^Setting) -> Outcome {
	c.registry.version += 1
	if c.registry.changed != nil && !c.registry.changed(c.registry.user, s.group) {
		return outcome(c, .Io, fmt.tprintf("%s couldn't be applied: it is back as it was", s.name))
	}
	return .Ok
}
