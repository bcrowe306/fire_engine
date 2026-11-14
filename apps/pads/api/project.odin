package pads_api

import pc "../core"
import pm "../model"

// The project now: where it is, whether it changed, the lists beside it.
Project_State :: struct {
	untitled:  bool, // not saved anywhere yet (it is in the unsaved folder)
	dirty:     bool, // changed since it was saved
	recent:    i64,  // projects in the recent list (project_recent)
	templates: i64,  // templates there are (project_template_name)
}

// What `project_unused_files` found: files the project doesn't use, by
// kind, and their size.
Unused_Files :: struct {
	unused:          i64, // files in its samples folders nothing uses
	unused_bytes:    i64,
	undo_only:       i64, // samples only undoing would bring back
	undo_only_bytes: i64,
	cache:           i64, // renderings, made again when needed
	cache_bytes:     i64,
}

// What `project_clean_up` did.
Clean_Up :: struct {
	files: i64, // moved to the Trash
	bytes: i64,
}

// The project now.
project_state :: proc(api: ^Api) -> (Project_State, Result) {
	c := api.core
	names, _ := pc.template_list(c)
	return {untitled = c.files.untitled, dirty = pm.model_dirty(&c.m), recent = i64(len(c.files.recent)), templates = i64(len(names))}, .Ok
}

// The project's folder (an untitled one's is in the unsaved folder).
// Temporary.
project_dir :: proc(api: ^Api) -> (string, Result) {
	return api.core.m.project.dir, .Ok
}

// The project's name: its folder's, without ".pads" ("Untitled" before
// it is saved). Temporary.
project_name :: proc(api: ^Api) -> (string, Result) {
	return pc.project_name(api.core), .Ok
}

// A new, empty project. With changes not saved, Busy unless
// `discard_changes` (they are lost; an untitled project's folder goes).
project_new :: proc(api: ^Api, discard_changes: bool) -> Result {
	left := leaving(api, discard_changes) or_return
	r := result(api, pc.project_new(api.core))
	if r == .Ok do pc.unsaved_discard(api.core, left)
	return r
}

// A new, untitled project from the template called `name`. Not_Found if
// there is none; Busy with changes not saved unless `discard_changes`.
project_new_from_template :: proc(api: ^Api, name: string, discard_changes: bool) -> Result {
	dir := pc.template_dir(api.core, name)
	if dir == "" do return fail(api, .Not_Found, "no such template")
	left := leaving(api, discard_changes) or_return
	r := result(api, pc.project_new_from(api.core, dir))
	if r == .Ok do pc.unsaved_discard(api.core, left)
	return r
}

// Opens the project in folder `dir`. Not_Found if there is none there;
// Busy with changes not saved unless `discard_changes`.
project_open :: proc(api: ^Api, dir: string, discard_changes: bool) -> Result {
	left := leaving(api, discard_changes) or_return
	r := result(api, pc.project_open(api.core, dir))
	if r == .Ok do pc.unsaved_discard(api.core, left)
	return r
}

// Saves the project where it is (an untitled one stays untitled, in the
// unsaved folder: `project_save_as` gives it a place).
project_save :: proc(api: ^Api) -> Result {
	return result(api, pc.project_save(api.core))
}

// Saves the project as folder `path` (".pads" added when missing), which
// it is from now on. Invalid_Argument if something is there already,
// unless `replace` (the project is written into that folder).
project_save_as :: proc(api: ^Api, path: string, replace := false) -> Result {
	return result(api, pc.project_save_as(api.core, path, replace))
}

// Renames the project's folder to "<name>.pads", where it is.
// Unsupported for an untitled project (save it as); Invalid_Argument for
// a name a folder can't have, or one taken.
project_rename :: proc(api: ^Api, name: string) -> Result {
	return result(api, pc.project_rename(api.core, name))
}

// Recent project `index`'s folder (0: the latest). Temporary.
project_recent :: proc(api: ^Api, index: i64) -> (string, Result) {
	r := api.core.files.recent
	if index < 0 || index >= i64(len(r)) do return "", fail(api, .Not_Found, "no such recent project")
	return r[index], .Ok
}

// Template `index`'s name (in name order). Temporary.
project_template_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	names, _ := pc.template_list(api.core)
	if index < 0 || index >= i64(len(names)) do return "", fail(api, .Not_Found, "no such template")
	return names[index], .Ok
}

// Saves a copy of the project as template `name` (one of that name is
// replaced). New projects can start from it.
project_save_template :: proc(api: ^Api, name: string) -> Result {
	return result(api, pc.template_save(api.core, name))
}

// Opens the backup the project in `dir` left when Pads stopped without
// closing (its changes, not yet saved). Not_Found if it left none.
project_recover :: proc(api: ^Api, dir: string) -> Result {
	return result(api, pc.project_recover(api.core, dir))
}

// Throws away the backup the project in `dir` left (an unsaved project's
// folder with it).
project_discard_backup :: proc(api: ^Api, dir: string) -> Result {
	if dir == api.core.m.project.dir do return fail(api, .Busy, "that project is open")
	pc.project_discard_backup(api.core, dir)
	return .Ok
}

// The files in the project's folder it doesn't use now, by kind.
project_unused_files :: proc(api: ^Api) -> (Unused_Files, Result) {
	u: Unused_Files
	for f in pm.unused_files(&api.core.m) {
		switch f.kind {
		case .Unused:    u.unused += 1;    u.unused_bytes += f.size
		case .Undo_Only: u.undo_only += 1; u.undo_only_bytes += f.size
		case .Cache:     u.cache += 1;     u.cache_bytes += f.size
		}
	}
	return u, .Ok
}

// Moves the files the project doesn't use to the Trash (from where they
// can be put back) and saves it: those nothing uses, and with
// `undo_only` the samples only undo would bring back (undo is forgotten),
// with `cache` the renderings. Io_Error if some couldn't be moved.
project_clean_up :: proc(api: ^Api, undo_only, cache: bool) -> (Clean_Up, Result) {
	kinds: bit_set[pm.Unused_Kind] = {.Unused}
	if undo_only do kinds += {.Undo_Only}
	if cache do kinds += {.Cache}
	want: i64
	for f in pm.unused_files(&api.core.m) do if f.kind in kinds do want += 1
	n, bytes := pc.clean_up(api.core, kinds)
	c := Clean_Up{files = i64(n), bytes = bytes}
	if c.files < want do return c, fail(api, .Io_Error, "some files couldn't be moved to the Trash")
	return c, .Ok
}

// Before leaving the project open: Busy if it has changes and they may
// not be lost; else its backup goes, and an untitled project's folder is
// returned (to remove once the next is open).
@(private)
leaving :: proc(api: ^Api, discard_changes: bool) -> (left: string, r: Result) {
	c := api.core
	if pm.model_dirty(&c.m) && !discard_changes do return "", fail(api, .Busy, "the project has changes not saved: save it, or discard them")
	pm.model_discard_backup(c.m.project.dir)
	if c.files.untitled do left = clone_temp(c.m.project.dir)
	return left, .Ok
}

// A core action's outcome as a Result (the same order), its reason with it.
@(private)
result :: proc(api: ^Api, o: pc.Outcome) -> Result {
	if o == .Ok do return .Ok
	return fail(api, Result(o), pc.why(api.core))
}
