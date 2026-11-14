package pads_core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import app "app:core"
import pm "../model"

// Recent projects kept.
RECENT :: 8

// What a project action came to (the API's `Result`, in the same order),
// with why in `Core.why` when it isn't Ok.
Outcome :: enum i32 {
	Ok,
	Not_Found,
	Invalid,
	Busy,
	Unsupported,
	Io,
}

// The project's files and folders: where it is, whether it has been
// given a place yet, the projects opened lately.
Files :: struct {
	recent:         [dynamic]string, // folders, the latest first (owned)
	untitled:       bool,   // a new project, in the unsaved folder: Save asks for a name and a place
	discard:        string, // an unsaved project left without saving, removed when Pads quits (owned)
	save_name:      string, // the name the Save dialog suggests for a new project (owned; "" = Untitled)
	last_save:      time.Tick,
	last_backup:    time.Tick, // the last autosave (a backup beside the project)
	unsaved_folder: string, // the setting: where new projects are until saved ("": `folders.unsaved`) (owned)
	folders:        Folders,
}

// Where Pads keeps its own files (set by the app at the start; owned).
Folders :: struct {
	settings: string, // settings.ini's folder: templates, the open-project marker
	prefs:    string, // the recent list (--prefs's, else `settings`)
	unsaved:  string, // the default for new projects (Music/Pads/Unsaved; with --prefs, in it)
}

// What the app does around the core's actions: reset its view to a
// project just opened (selection, banks, the view it was left in).
Hooks :: struct {
	user:          rawptr,
	opened:        proc(user: rawptr), // a project was opened, made or recovered (nil: nothing)
	param_touched: proc(user: rawptr, t: pm.Auto_Target, on: bool), // a parameter touched or let go (automation recording)
	param_moved:   proc(user: rawptr, t: pm.Auto_Target, value: f32), // the touched parameter moved (plain units)
	release_held:  proc(user: rawptr), // the pads held on the grid let go (the play mode changes)
	ui:            Ui_Hooks, // the window's, when there is one (none: the API's ui_* are Unsupported)
}

// What the app's window does for the API's `ui` module: views, the look,
// messages, the pads selected together. A headless core leaves them nil.
Ui_Hooks :: struct {
	show:        proc(user: rawptr, name: string) -> bool, // a view, panel or device page by name ("mixer", "sample", "eq"...)
	set_dark:    proc(user: rawptr, dark: bool),
	dark:        proc(user: rawptr) -> bool,
	toast:       proc(user: rawptr, kind: int, text: string), // 0 info, 1 success, 2 warning, 3 error
	messages:    proc(user: rawptr) -> []string, // the messages showing (temporary)
	select_pads: proc(user: rawptr, pads: []int), // the pads selected together (the first the selected one)
	selected_pads: proc(user: rawptr) -> []int,   // (temporary)
}

// Frees the files' state.
files_destroy :: proc(f: ^Files) {
	for r in f.recent do delete(r)
	delete(f.recent)
	delete(f.discard)
	delete(f.save_name)
	delete(f.unsaved_folder)
	delete(f.folders.settings)
	delete(f.folders.prefs)
	delete(f.folders.unsaved)
	f^ = {}
}

@(private)
outcome :: proc(c: ^Core, o: Outcome, why: string) -> Outcome {
	n := copy(c.why[:], why)
	c.why_len = n
	return o
}

// Why the last action that failed failed.
why :: proc(c: ^Core) -> string {
	return string(c.why[:c.why_len])
}

// --- folders ------------------------------------------------------------------------------------

// The folder unsaved projects are in (temporary allocator).
unsaved_root :: proc(c: ^Core) -> string {
	if c.files.unsaved_folder != "" do return c.files.unsaved_folder
	return c.files.folders.unsaved
}

// Whether project folder `dir` is an unsaved one.
is_unsaved :: proc(c: ^Core, dir: string) -> bool {
	return filepath.dir(dir) == unsaved_root(c)
}

// Makes a folder for a new project: "Untitled.pads", "Untitled 2.pads"...
// in the unsaved folder, whichever is free (the system's temporary folder
// if that can't be made). The caller owns it.
unsaved_new :: proc(c: ^Core) -> string {
	root := unsaved_root(c)
	if os.make_directory_all(root) != nil && !os.is_dir(root) {
		dir, _ := os.make_directory_temp("", "Untitled.pads", context.allocator)
		return dir
	}
	for n := 1; ; n += 1 {
		name := "Untitled.pads" if n == 1 else fmt.tprintf("Untitled %d.pads", n)
		dir, _ := filepath.join({root, name})
		if !os.exists(dir) && os.make_directory(dir) == nil do return dir
		delete(dir)
	}
}

// Removes unsaved project folder `dir` (left without saving), unless it is
// the one open. Only a folder in the unsaved folder is removed.
unsaved_discard :: proc(c: ^Core, dir: string) {
	if dir == "" || dir == c.m.project.dir || !is_unsaved(c, dir) do return
	os.remove_all(dir)
}

// Where the user's project templates are (each a project folder; temporary).
templates_folder :: proc(c: ^Core) -> string {
	p, _ := filepath.join({c.files.folders.settings, "Templates"}, context.temp_allocator)
	return p
}

// The templates there are: their names and folders (temporary allocator).
template_list :: proc(c: ^Core) -> (names, dirs: []string) {
	ns := make([dynamic]string, context.temp_allocator)
	ds := make([dynamic]string, context.temp_allocator)
	h, err := os.open(templates_folder(c))
	if err != nil do return
	defer os.close(h)
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	for fi in infos do if fi.type == .Directory && strings.has_suffix(fi.name, ".pads") {
		append(&ns, strings.trim_suffix(fi.name, ".pads"))
		d, _ := filepath.join({templates_folder(c), fi.name}, context.temp_allocator)
		append(&ds, d)
	}
	return ns[:], ds[:]
}

// The project's name: its folder's without ".pads", or "Untitled".
project_name :: proc(c: ^Core) -> string {
	if c.files.untitled do return "Untitled"
	return strings.trim_suffix(filepath.base(c.m.project.dir), ".pads")
}

// --- recent projects ----------------------------------------------------------------------------

@(private)
recent_path :: proc(c: ^Core) -> string {
	if c.files.folders.prefs == "" do return ""
	os.make_directory_all(c.files.folders.prefs)
	p, _ := filepath.join({c.files.folders.prefs, "recent.txt"}, context.temp_allocator)
	return p
}

// Reads the recent projects list (folders that still have a project).
recent_load :: proc(c: ^Core) {
	path := recent_path(c)
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || len(c.files.recent) >= RECENT do continue
		f, _ := filepath.join({l, pm.PROJECT_FILE}, context.temp_allocator)
		if os.exists(f) do append(&c.files.recent, strings.clone(l))
	}
}

// Puts `dir` at the top of the recent projects, and writes the list.
recent_add :: proc(c: ^Core, dir: string) {
	f := &c.files
	for r, i in f.recent do if r == dir {
		delete(r)
		ordered_remove(&f.recent, i)
		break
	}
	inject_at(&f.recent, 0, strings.clone(dir))
	for len(f.recent) > RECENT do delete(pop(&f.recent))
	if path := recent_path(c); path != "" {
		_ = os.write_entire_file(path, transmute([]u8)strings.join(f.recent[:], "\n", context.temp_allocator))
	}
}

// --- the open-project marker --------------------------------------------------------------------

@(private)
session_marker :: proc(c: ^Core) -> string {
	p, _ := filepath.join({c.files.folders.settings, "open-project.txt"}, context.temp_allocator)
	return p
}

// Notes that the project is open (until a clean exit).
session_mark :: proc(c: ^Core) {
	_ = os.write_entire_file(session_marker(c), transmute([]u8)c.m.project.dir)
}

// A clean exit: the marker and the open project's backup gone.
session_unmark :: proc(c: ^Core) {
	pm.model_discard_backup(c.m.project.dir)
	os.remove(session_marker(c))
}

// At the start: the project open when Pads last stopped without closing,
// if it left a backup newer than itself ("" none).
session_crashed :: proc(c: ^Core) -> string {
	data, err := os.read_entire_file(session_marker(c), context.temp_allocator)
	if err != nil do return ""
	dir := strings.trim_space(string(data))
	if dir == "" || !pm.model_backup_newer(dir) do return ""
	return dir
}

// --- actions ------------------------------------------------------------------------------------

@(private)
opened :: proc(c: ^Core) {
	c.files.last_save = time.tick_now()
	session_mark(c)
	if c.hooks.opened != nil do c.hooks.opened(c.hooks.user)
}

// A new, empty project in the unsaved folder (what was open is left as
// it is: ask to save first).
project_new :: proc(c: ^Core) -> Outcome {
	dir := unsaved_new(c)
	defer delete(dir)
	if pm.model_new(&c.m, dir) != .None do return outcome(c, .Io, "could not start a new project")
	c.m.engine.metronome = true // (its click on: while recording, as a new project's is)
	c.files.untitled = true
	opened(c)
	return .Ok
}

// A new, untitled project made from the template in folder `dir`.
project_new_from :: proc(c: ^Core, dir: string) -> Outcome {
	f, _ := filepath.join({dir, pm.PROJECT_FILE}, context.temp_allocator)
	if !os.exists(f) do return outcome(c, .Not_Found, "no such template")
	to := unsaved_new(c)
	defer delete(to)
	if pm.model_new_from(&c.m, dir, to) != .None do return outcome(c, .Io, "could not start from that template")
	c.files.untitled = true
	opened(c)
	return .Ok
}

// Opens the project in folder `dir`.
project_open :: proc(c: ^Core, dir: string) -> Outcome {
	f, _ := filepath.join({dir, pm.PROJECT_FILE}, context.temp_allocator)
	if !os.exists(f) do return outcome(c, .Not_Found, "no project there")
	if pm.model_load(&c.m, dir) != .None do return outcome(c, .Io, "could not open the project")
	c.files.untitled = is_unsaved(c, c.m.project.dir) // (one left in the unsaved folder, opened: still to be given a place)
	recent_add(c, dir)
	opened(c)
	return .Ok
}

// Saves into the project's folder (an untitled one: where it is, still
// untitled).
project_save :: proc(c: ^Core) -> Outcome {
	if pm.model_save(&c.m) != .None do return outcome(c, .Io, "could not save the project")
	c.files.last_save = time.tick_now()
	if !c.files.untitled do recent_add(c, c.m.project.dir)
	return .Ok
}

// Saves the project as `path` (a "<name>.pads" folder: ".pads" is added
// when missing); from now on it is the project. Not over another project
// unless `replace` (it is written into that folder).
project_save_as :: proc(c: ^Core, path: string, replace := false) -> Outcome {
	if path == "" do return outcome(c, .Invalid, "no folder given")
	dir := path if strings.has_suffix(path, ".pads") else strings.concatenate({path, ".pads"}, context.temp_allocator)
	if dir != c.m.project.dir && os.exists(dir) && !replace do return outcome(c, .Invalid, fmt.tprintf("%s is already there", filepath.base(dir)))
	if o := save_into(c, dir); o != .Ok do return o
	c.files.last_save = time.tick_now()
	recent_add(c, c.m.project.dir)
	session_mark(c)
	return .Ok
}

// Saves the project into folder `dir`, which becomes the project's (an
// unsaved project's folder moves there, its recordings with it; one on
// another disk, or a saved project, is copied).
save_into :: proc(c: ^Core, dir: string) -> Outcome {
	if c.files.untitled && is_unsaved(c, c.m.project.dir) {
		old := strings.clone(c.m.project.dir, context.temp_allocator)
		if pm.model_move(&c.m, dir) != .None {
			if pm.model_save_as(&c.m, dir) != .None do return outcome(c, .Io, "could not save there")
			pm.model_discard_backup(old)
			unsaved_discard(c, old)
		}
	} else if pm.model_save_as(&c.m, dir) != .None {
		return outcome(c, .Io, "could not save there")
	}
	c.files.untitled = false
	return .Ok
}

// Whether `name` can name a project's folder.
name_ok :: proc(name: string) -> bool {
	n := strings.trim_space(name)
	return n != "" && !strings.contains_any(n, "/\\:")
}

// Renames the project to `name`: its folder becomes "<name>.pads" beside
// where it is. Unsupported for an untitled project (save it as first).
project_rename :: proc(c: ^Core, new_name: string) -> Outcome {
	name := strings.trim_space(new_name)
	if !name_ok(name) do return outcome(c, .Invalid, "not a name a folder can have")
	if c.files.untitled do return outcome(c, .Unsupported, "the project isn't saved anywhere yet: save it as")
	to := fmt.tprintf("%s/%s.pads", filepath.dir(c.m.project.dir), name)
	if to == c.m.project.dir do return .Ok
	if os.exists(to) do return outcome(c, .Invalid, fmt.tprintf("%s is already there", filepath.base(to)))
	if pm.model_move(&c.m, to) != .None do return outcome(c, .Io, "could not rename the project")
	recent_add(c, c.m.project.dir)
	session_mark(c)
	return .Ok
}

// Saves a copy of the project as the template `name` (one of that name
// replaced).
template_save :: proc(c: ^Core, name: string) -> Outcome {
	if !name_ok(name) do return outcome(c, .Invalid, "not a name a template can have")
	dir, _ := filepath.join({templates_folder(c), strings.concatenate({pm.safe_name(strings.trim_space(name)), ".pads"}, context.temp_allocator)}, context.temp_allocator)
	os.remove_all(dir)
	if pm.model_save_copy(&c.m, dir) != .None do return outcome(c, .Io, "could not save the template")
	return .Ok
}

// The template called `name`'s folder, or "" (temporary).
template_dir :: proc(c: ^Core, name: string) -> string {
	names, dirs := template_list(c)
	for n, k in names do if n == name do return dirs[k]
	return ""
}

// Opens the backup the project in `dir` left (Pads stopped without
// closing): its changes, to be saved.
project_recover :: proc(c: ^Core, dir: string) -> Outcome {
	if !pm.model_backup_newer(dir) do return outcome(c, .Not_Found, "no backup newer than the project there")
	fresh := strings.clone(c.m.project.dir, context.temp_allocator) if c.files.untitled else "" // (the new one Pads started with)
	if pm.model_load_backup(&c.m, dir) != .None do return outcome(c, .Io, "could not open the backup")
	c.files.untitled = is_unsaved(c, c.m.project.dir)
	unsaved_discard(c, fresh)
	opened(c)
	return .Ok
}

// Throws away the backup the project in `dir` left (an unsaved project's
// folder with it).
project_discard_backup :: proc(c: ^Core, dir: string) {
	pm.model_discard_backup(dir)
	unsaved_discard(c, dir)
}

// Autosaves (as a backup beside the project) when `every` has passed since
// the last, while there are changes and `busy` is false.
autosave :: proc(c: ^Core, every: time.Duration, busy: bool) {
	f := &c.files
	if every > 0 && pm.model_dirty(&c.m) && time.tick_since(f.last_backup) > every && !busy {
		pm.model_save_backup(&c.m)
		f.last_backup = time.tick_now()
	}
}

// Moves the project's files nothing uses to the Trash (`trash`), and
// saves it: those of `kinds` (`.Unused`; `.Undo_Only` forgets the undo
// history; `.Cache` is made again when needed). How many, and their size.
clean_up :: proc(c: ^Core, kinds: bit_set[pm.Unused_Kind], extra: []app.Id = nil, trash := app.move_to_trash) -> (moved: int, bytes: i64) {
	chosen := make([dynamic]pm.Unused_File, context.temp_allocator)
	for f in pm.unused_files(&c.m, extra) do if f.kind in kinds do append(&chosen, f)
	if len(chosen) == 0 do return 0, 0
	return pm.clean_up(&c.m, chosen[:], trash)
}
