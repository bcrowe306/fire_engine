package app

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// An INI file in memory: sections of `key = value` lines, in the order they
// were read or set, with the comment lines (`#` or `;`) above each section
// and entry kept, so a file a person edited keeps its notes when it is
// written back. Keys and values are trimmed; a value may be quoted to keep
// its spaces. Lines before the first `[section]` belong to section "".
Ini :: struct {
	sections:  [dynamic]Ini_Section,
	allocator: runtime.Allocator,
}

// One `[name]` of an `Ini`.
Ini_Section :: struct {
	name:     string,
	comments: [dynamic]string, // the lines above its header
	entries:  [dynamic]Ini_Entry,
	trailing: [dynamic]string, // comments after its last entry (at the end of the file)
}

// One `key = value` of an `Ini_Section`.
Ini_Entry :: struct {
	key, value: string,
	comments:   [dynamic]string, // the lines above it
}

// Reads INI text. Never fails: lines it can't read are kept as comments.
ini_parse :: proc(text: string, allocator := context.allocator) -> (ini: Ini) {
	ini.allocator = allocator
	context.allocator = allocator
	pending := make([dynamic]string)
	current := ini_section(&ini, "")
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" {
			continue
		}
		if line[0] == '#' || line[0] == ';' {
			append(&pending, strings.clone(line))
			continue
		}
		if line[0] == '[' && line[len(line) - 1] == ']' {
			current = ini_section(&ini, strings.trim_space(line[1:len(line) - 1]))
			append(&current.comments, ..pending[:])
			clear(&pending)
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			append(&pending, strings.concatenate({"# ", line})) // not ours to read: kept, harmless
			continue
		}
		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' do value = value[1:len(value) - 1]
		e := ini_entry(current, key)
		delete(e.value)
		e.value = strings.clone(value)
		append(&e.comments, ..pending[:])
		clear(&pending)
	}
	if len(pending) > 0 do append(&ini.sections[len(ini.sections) - 1].trailing, ..pending[:])
	delete(pending)
	return
}

// Reads the INI file at `path` (an empty one if there is none). False if it
// exists and can't be read.
ini_load :: proc(path: string, allocator := context.allocator) -> (ini: Ini, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		ini.allocator = allocator
		return ini, !os.exists(path)
	}
	return ini_parse(string(data), allocator), true
}

// The text of `ini`: each section's comments, its header, its entries (each
// after its comments), a blank line between sections. Values with spaces at
// their ends, or a `#` or `;`, are quoted.
ini_text :: proc(ini: ^Ini, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	first := true
	for &s in ini.sections {
		if s.name == "" && len(s.entries) == 0 && len(s.comments) == 0 && len(s.trailing) == 0 do continue
		if !first do strings.write_byte(&b, '\n')
		first = false
		for c in s.comments do fmt.sbprintln(&b, c)
		if s.name != "" do fmt.sbprintf(&b, "[%s]\n", s.name)
		for &e in s.entries {
			for c in e.comments do fmt.sbprintln(&b, c)
			v := e.value
			quote := v != strings.trim_space(v) || strings.contains_any(v, "#;")
			if quote do fmt.sbprintf(&b, "%s = \"%s\"\n", e.key, v)
			else do fmt.sbprintf(&b, "%s = %s\n", e.key, v)
		}
		for c in s.trailing do fmt.sbprintln(&b, c)
	}
	return strings.to_string(b)
}

// Writes `ini` to `path`, whole or not at all (a temporary file beside it,
// then renamed over it); makes its folder if need be.
ini_save :: proc(ini: ^Ini, path: string) -> bool {
	os.make_directory_all(filepath.dir(path))
	text := ini_text(ini, context.temp_allocator)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)text) != nil do return false
	return os.rename(tmp, path) == nil
}

// Frees `ini`.
ini_destroy :: proc(ini: ^Ini) {
	context.allocator = ini.allocator
	for &s in ini.sections {
		delete(s.name)
		for c in s.comments do delete(c)
		delete(s.comments)
		for &e in s.entries {
			delete(e.key)
			delete(e.value)
			for c in e.comments do delete(c)
			delete(e.comments)
		}
		delete(s.entries)
		for c in s.trailing do delete(c)
		delete(s.trailing)
	}
	delete(ini.sections)
	ini^ = {}
}

// Section `name` (added at the end if missing).
ini_section :: proc(ini: ^Ini, name: string) -> ^Ini_Section {
	for &s in ini.sections do if s.name == name do return &s
	context.allocator = ini.allocator if ini.allocator.procedure != nil else context.allocator
	if ini.allocator.procedure == nil do ini.allocator = context.allocator
	append(&ini.sections, Ini_Section{name = strings.clone(name), comments = make([dynamic]string), entries = make([dynamic]Ini_Entry), trailing = make([dynamic]string)})
	return &ini.sections[len(ini.sections) - 1]
}

@(private)
ini_entry :: proc(s: ^Ini_Section, key: string) -> ^Ini_Entry {
	for &e in s.entries do if e.key == key do return &e
	append(&s.entries, Ini_Entry{key = strings.clone(key), comments = make([dynamic]string)})
	return &s.entries[len(s.entries) - 1]
}

// The value of `key` in `section`, if it is there.
ini_get :: proc(ini: ^Ini, section, key: string) -> (string, bool) {
	for &s in ini.sections do if s.name == section {
		for e in s.entries do if e.key == key do return e.value, true
	}
	return "", false
}

// Sets `key` in `section` to `value` (adding either where missing).
ini_set :: proc(ini: ^Ini, section, key, value: string) {
	context.allocator = ini.allocator if ini.allocator.procedure != nil else context.allocator
	e := ini_entry(ini_section(ini, section), key)
	delete(e.value)
	e.value = strings.clone(value)
}

// Takes `key` out of `section`.
ini_remove :: proc(ini: ^Ini, section, key: string) {
	context.allocator = ini.allocator
	for &s in ini.sections do if s.name == section {
		for e, i in s.entries do if e.key == key {
			delete(e.key)
			delete(e.value)
			for c in e.comments do delete(c)
			delete(e.comments)
			ordered_remove(&s.entries, i)
			return
		}
	}
}

// Takes section `name` (and everything in it) out.
ini_remove_section :: proc(ini: ^Ini, name: string) {
	context.allocator = ini.allocator
	for &s, i in ini.sections do if s.name == name {
		delete(s.name)
		for c in s.comments do delete(c)
		delete(s.comments)
		for &e in s.entries {
			delete(e.key)
			delete(e.value)
			for c in e.comments do delete(c)
			delete(e.comments)
		}
		delete(s.entries)
		for c in s.trailing do delete(c)
		delete(s.trailing)
		ordered_remove(&ini.sections, i)
		return
	}
}

// `key` in `section` as a whole number, else `default`.
ini_int :: proc(ini: ^Ini, section, key: string, default: int) -> int {
	v, ok := ini_get(ini, section, key)
	if !ok do return default
	n, nok := strconv.parse_int(v)
	return n if nok else default
}

// `key` in `section` as a number, else `default`.
ini_f64 :: proc(ini: ^Ini, section, key: string, default: f64) -> f64 {
	v, ok := ini_get(ini, section, key)
	if !ok do return default
	n, nok := strconv.parse_f64(v)
	return n if nok else default
}

// `key` in `section` as true/false (also yes/no, on/off, 1/0), else `default`.
ini_bool :: proc(ini: ^Ini, section, key: string, default: bool) -> bool {
	v, ok := ini_get(ini, section, key)
	if !ok do return default
	switch strings.to_lower(v, context.temp_allocator) {
	case "true", "yes", "on", "1":  return true
	case "false", "no", "off", "0": return false
	}
	return default
}

// Sets `key` to a whole number.
ini_set_int :: proc(ini: ^Ini, section, key: string, v: int) { ini_set(ini, section, key, fmt.tprintf("%d", v)) }
// Sets `key` to a number (as few digits as keep it).
ini_set_f64 :: proc(ini: ^Ini, section, key: string, v: f64) { ini_set(ini, section, key, fmt.tprintf("%v", v)) }
// Sets `key` to true or false.
ini_set_bool :: proc(ini: ^Ini, section, key: string, v: bool) { ini_set(ini, section, key, "true" if v else "false") }

// --- where settings go ----------------------------------------------------------------------

// Where an app keeps its settings file `file` ("settings.ini"): beside the
// app when one is already there (a portable install: beside the
// executable, or beside its .app bundle on macOS), else in the user's
// configuration folder for `app` (macOS ~/Library/Application
// Support/<app>, Windows %APPDATA%\<app>, Linux $XDG_CONFIG_HOME/<app> or
// ~/.config/<app>). Returns the path and whether it is the portable one.
settings_file_path :: proc(app: string, file: string, allocator := context.allocator) -> (path: string, portable: bool) {
	beside := app_folder(context.temp_allocator)
	if beside != "" {
		p, _ := filepath.join({beside, file}, context.temp_allocator)
		if os.exists(p) do return strings.clone(p, allocator), true
	}
	p, _ := filepath.join({user_config_folder(app, context.temp_allocator), file}, context.temp_allocator)
	return strings.clone(p, allocator), false
}

// The folder the app is in: the executable's, or on macOS the one its
// .app bundle is in ("" if unknown).
app_folder :: proc(allocator := context.allocator) -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil || exe == "" do return ""
	dir := filepath.dir(exe)
	// .../Name.app/Contents/MacOS/exe: beside Name.app.
	if strings.has_suffix(dir, "/Contents/MacOS") {
		bundle := filepath.dir(filepath.dir(dir))
		if strings.has_suffix(bundle, ".app") do dir = filepath.dir(bundle)
	}
	return strings.clone(dir, allocator)
}

// The user's configuration folder for `app`.
user_config_folder :: proc(app: string, allocator := context.allocator) -> string {
	p: string
	when ODIN_OS == .Darwin {
		home := os.get_env("HOME", context.temp_allocator)
		p, _ = filepath.join({home, "Library", "Application Support", app}, context.temp_allocator)
	} else when ODIN_OS == .Windows {
		data := os.get_env("APPDATA", context.temp_allocator)
		if data == "" do data = os.get_env("USERPROFILE", context.temp_allocator)
		p, _ = filepath.join({data, app}, context.temp_allocator)
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if xdg == "" do xdg, _ = filepath.join({home, ".config"}, context.temp_allocator)
		p, _ = filepath.join({xdg, strings.to_lower(app, context.temp_allocator)}, context.temp_allocator)
	}
	return strings.clone(p, allocator)
}
