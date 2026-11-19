package pads_model

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "fire:fx"

// ProVerb's presets from an installed ValhallaRoom: read from its preset
// folder on this machine (its own files, never copied into Pads), each
// one's settings mapped to ProVerb's (`fx.proverb_reference_values`).

// One preset read from the installed reference: its name, the folder it
// was in, and ProVerb's settings for it.
Imported_Preset :: struct {
	name:   string,
	folder: string,
	values: fx.Proverb_Values,
}

// The folders ValhallaRoom installs its presets into (the system's and the
// user's), on this system. A test may point it elsewhere.
proverb_import_dirs: []string

@(private = "file") imported: [dynamic]Imported_Preset
@(private = "file") imported_read: bool

// Control thread. The installed reference's presets (read the first time
// asked, sorted by folder then name; none where it isn't installed).
imported_presets :: proc() -> []Imported_Preset {
	if !imported_read do imported_presets_reload()
	return imported[:]
}

// Control thread. Reads the installed reference's presets again (from
// `proverb_import_dirs`, or this system's own folders when it is empty).
imported_presets_reload :: proc() {
	for p in imported {
		delete(p.name)
		delete(p.folder)
	}
	clear(&imported)
	imported_read = true
	dirs := proverb_import_dirs
	when ODIN_OS == .Darwin {
		if len(dirs) == 0 {
			home := os.get_env("HOME", context.temp_allocator)
			dirs = {"/Library/Audio/Presets/Valhalla DSP, LLC/ValhallaRoom", strings.concatenate({home, "/Library/Audio/Presets/Valhalla DSP, LLC/ValhallaRoom"}, context.temp_allocator)}
		}
	}
	for d in dirs do import_dir(d, d)
	slice.sort_by(imported[:], proc(a, b: Imported_Preset) -> bool {
		if a.folder != b.folder do return a.folder < b.folder
		return a.name < b.name
	})
}

// Every .vpreset under `dir` (its folder named against `root`).
@(private = "file")
import_dir :: proc(root, dir: string) {
	f, err := os.open(dir)
	if err != nil do return
	defer os.close(f)
	entries, rerr := os.read_dir(f, -1, context.temp_allocator)
	if rerr != nil do return
	for e in entries {
		if e.type == .Directory {
			import_dir(root, e.fullpath)
			continue
		}
		if !strings.has_suffix(e.name, ".vpreset") do continue
		data, derr := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
		if derr != nil do continue
		attrs, name, ok := vpreset_attrs(string(data))
		if !ok do continue
		rel, _ := filepath.rel(root, filepath.dir(e.fullpath), context.temp_allocator)
		folder := "" if rel == "." else rel
		if name == "" do name = strings.trim_suffix(e.name, ".vpreset")
		append(&imported, Imported_Preset{name = strings.clone(name), folder = strings.clone(folder), values = fx.proverb_reference_values(attrs)})
	}
}

// A preset file's root element's numeric attributes and its presetName;
// false if it isn't one.
@(private = "file")
vpreset_attrs :: proc(text: string) -> (attrs: map[string]f64, name: string, ok: bool) {
	start := strings.index(text, "<ValhallaRoom")
	if start < 0 do return
	end := strings.index(text[start:], ">")
	if end < 0 do return
	tag := text[start + len("<ValhallaRoom"):start + end]
	attrs = make(map[string]f64, context.temp_allocator)
	rest := tag
	for {
		eq := strings.index(rest, "=\"")
		if eq < 0 do break
		key := strings.trim_space(rest[:eq])
		if sp := strings.last_index_any(key, " \t\r\n"); sp >= 0 do key = key[sp + 1:]
		rest = rest[eq + 2:]
		q := strings.index(rest, "\"")
		if q < 0 do break
		val := rest[:q]
		rest = rest[q + 1:]
		if key == "presetName" {
			name = val
			continue
		}
		if x, vok := strconv.parse_f64(val); vok do attrs[key] = x
	}
	return attrs, name, len(attrs) > 0
}

// A slot holding imported preset `p`: a ProVerb at its settings, on.
imported_preset_slot :: proc(p: Imported_Preset) -> Effect_Slot {
	s := new_effect(.Proverb)
	v := p.values
	for info in fx.proverb_params do if info.id != fx.PV_PARAM_QUALITY do slot_set(&s, info.id, v[info.id])
	return s
}
