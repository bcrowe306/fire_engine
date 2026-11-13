package pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"

// The folders in a project folder files are made in (see
// docs/design/project-format.md). Every file the project plays is in its
// samples table, under `Samples/`; everything under `cache/` can be made
// again and is never copied.
Project_Folder :: enum {
	Imported,  // `Samples/Imported`: files brought in (the browser, a drop, Add Take File)
	Recorded,  // `Samples/Recorded`: sampled into pads, audio tracks' takes
	Processed, // `Samples/Processed`: bounces, freezes, consolidations, edits' results, export to a pad
	Warp,      // `cache/warp`: warp renderings
	Comp,      // `cache/comp`: comp renderings
	Spool,     // `cache/recording`: audio tracks' takes while they are recorded (each folded into Recorded, then removed)
}

// The folder all of a project's own audio is in.
SAMPLES_FOLDER :: "Samples"
// The folder of what a project can make again.
CACHE_FOLDER :: "cache"

@(private)
FOLDER_PARTS := [Project_Folder][2]string {
	.Imported  = {SAMPLES_FOLDER, "Imported"},
	.Recorded  = {SAMPLES_FOLDER, "Recorded"},
	.Processed = {SAMPLES_FOLDER, "Processed"},
	.Warp      = {CACHE_FOLDER, "warp"},
	.Comp      = {CACHE_FOLDER, "comp"},
	.Spool     = {CACHE_FOLDER, "recording"},
}

// Folder `f` of project folder `dir` (temporary allocator; not made).
project_folder :: proc(dir: string, f: Project_Folder) -> string {
	parts := FOLDER_PARTS[f]
	path, _ := filepath.join({dir, parts[0], parts[1]}, context.temp_allocator)
	return path
}

// Makes folder `f` of project folder `dir` if it is missing. Returns it
// (temporary allocator), or "" if it can't be made.
project_folder_make :: proc(dir: string, f: Project_Folder) -> string {
	path := project_folder(dir, f)
	if os.make_directory_all(path) != nil && !os.is_dir(path) do return ""
	return path
}

// A path for a new file named `name` in folder `f` of project folder
// `dir` (made if missing): `name`, or `name 2`, `name 3`... whichever no
// file there has, so nothing is ever written over. "" if the folder can't
// be made. The caller owns it (`context.allocator`).
project_new_file :: proc(dir: string, f: Project_Folder, name: string) -> string {
	folder := project_folder_make(dir, f)
	if folder == "" do return ""
	return unique_path(folder, safe_file_name(name))
}

// The folder the browser's project tab shows: `Samples/`, or an older
// project's `samples/` while it has no `Samples/` (temporary allocator).
project_samples_root :: proc(dir: string) -> string {
	root, _ := filepath.join({dir, SAMPLES_FOLDER}, context.temp_allocator)
	if os.is_dir(root) do return root
	old, _ := filepath.join({dir, "samples"}, context.temp_allocator)
	if os.is_dir(old) do return old
	return root
}

// How a project file stores `path`: relative to project folder `dir`
// when inside it, with `/` whatever the system (so a project moves
// between systems); absolute otherwise (temporary allocator).
stored_path :: proc(dir, path: string) -> string {
	rel, err := filepath.rel(dir, path, context.temp_allocator)
	if err != nil || rel == ".." || strings.has_prefix(rel, "../") || strings.has_prefix(rel, "..\\") do return path
	if ODIN_OS == .Windows {
		s, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
		return s
	}
	return rel
}

// The path a project file's `stored` means in project folder `dir`: a
// relative one (`/` or `\` between its parts) joined to it; an absolute
// one as it is (temporary allocator).
loaded_path :: proc(dir, stored: string) -> string {
	if filepath.is_abs(stored) do return stored
	s := stored
	// (A Windows separator read elsewhere: on Windows join takes either.)
	if ODIN_OS != .Windows do s, _ = strings.replace_all(stored, "\\", "/", context.temp_allocator)
	full, _ := filepath.join({dir, s}, context.temp_allocator)
	return full
}
