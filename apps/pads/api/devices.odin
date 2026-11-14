package pads_api

import "core:strings"

import pm "../model"

// Built-in synth presets there are (device_preset_name lists them).
device_preset_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(pm.BUILTIN_PRESETS)), .Ok
}

// Built-in preset `index`'s name ("Warm Pad"). Temporary.
device_preset_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= i64(len(pm.BUILTIN_PRESETS)) do return "", fail(api, .Not_Found, "no such preset")
	return pm.BUILTIN_PRESETS[index].name, .Ok
}

// Built-in preset `index`'s kind ("Bass", "Pad", "Lead"). Temporary.
device_preset_category :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= i64(len(pm.BUILTIN_PRESETS)) do return "", fail(api, .Not_Found, "no such preset")
	return pm.BUILTIN_PRESETS[index].category, .Ok
}

// Puts built-in preset `index` on pad `pad` (it becomes a synth): one undo
// step.
device_load_preset :: proc(api: ^Api, pad: i64, index: i64) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if index < 0 || index >= i64(len(pm.BUILTIN_PRESETS)) do return fail(api, .Not_Found, "no such preset")
	if p.kind == .Audio do return fail(api, .Unsupported, "an audio track can't be a synth")
	pm.preset_apply_builtin(&api.core.m, int(pad), int(index))
	edited(api)
	return .Ok
}

// Puts the preset saved at `path` on pad `pad` (it becomes a synth): one
// undo step. Io_Error if it can't be read.
device_load_preset_file :: proc(api: ^Api, pad: i64, path: string) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if p.kind == .Audio do return fail(api, .Unsupported, "an audio track can't be a synth")
	pr, err := pm.preset_read(path)
	if err != .None do return failf(api, .Io_Error, "could not read the preset ", path)
	pm.preset_apply(&api.core.m, int(pad), &pr)
	edited(api)
	return .Ok
}

// Saves synth pad `pad`'s patch as preset `name` in folder `dir`: the
// file's path. Unsupported for a pad that isn't a synth.
device_save_preset :: proc(api: ^Api, pad: i64, dir: string, name: string) -> (string, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return "", r
	if p.kind != .Synth do return "", fail(api, .Unsupported, "only a synth's patch is a preset")
	if strings.trim_space(name) == "" do return "", fail(api, .Invalid_Argument, "a preset needs a name")
	path, err := pm.preset_save(&api.core.m, int(pad), dir, name)
	if err != .None do return "", fail(api, .Io_Error, "could not save the preset there")
	return strings.clone(path, context.temp_allocator), .Ok
}

// The preset synth pad `pad`'s patch came from ("" if none). Temporary.
device_preset_of :: proc(api: ^Api, pad: i64) -> (string, Result) {
	if _, r := pad_of(api, pad); r != .Ok do return "", r
	return strings.clone(pm.synth_preset_name(&api.core.m, int(pad)), context.temp_allocator), .Ok
}

// Makes pad `pad` play CLAP instrument `id` of the library at `path`
// (named `name`): one undo step.
device_load_plugin :: proc(api: ^Api, pad: i64, path, id, name: string) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	if path == "" || id == "" do return fail(api, .Invalid_Argument, "a plug-in needs its library's path and its id")
	pm.make_plugin_pad(&api.core.m, int(pad), path, id, name if name != "" else id)
	edited(api)
	return .Ok
}
