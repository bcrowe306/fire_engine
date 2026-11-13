package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"

import sdl "deps:sdl3"

// Projects not saved yet live in a folder of Pads' own (not the system's
// temporary one, which it may clear): their recordings and autosaves
// survive Pads stopping, and the project is offered again when it starts.
// Saving moves the folder where the user chooses; leaving without saving
// removes it.

// The folder unsaved projects are in: the setting, else `Pads/Unsaved` in
// the user's Music folder (with --prefs: in that folder, so a test stays
// in its own), else beside the settings (temporary allocator).
unsaved_root :: proc(a: ^App) -> string {
	if a.settings.unsaved_folder != "" do return a.settings.unsaved_folder
	if a.prefs != "" {
		p, _ := filepath.join({a.prefs, "Unsaved"}, context.temp_allocator)
		return p
	}
	if d := sdl.GetUserFolder(.MUSIC); d != nil {
		p, _ := filepath.join({string(d), "Pads", "Unsaved"}, context.temp_allocator)
		return p
	}
	p, _ := filepath.join({settings_folder(a), "Unsaved"}, context.temp_allocator)
	return p
}

// Whether project folder `dir` is an unsaved one (in `unsaved_root`).
is_unsaved :: proc(a: ^App, dir: string) -> bool {
	return filepath.dir(dir) == unsaved_root(a)
}

// Makes a folder for a new project: "Untitled.pads", "Untitled 2.pads"...
// in `unsaved_root`, whichever is free (the system's temporary folder if
// that can't be made). The caller owns it.
unsaved_new :: proc(a: ^App) -> string {
	root := unsaved_root(a)
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
// the one open. Only a folder in `unsaved_root` is removed.
unsaved_discard :: proc(a: ^App, dir: string) {
	if dir == "" || dir == a.m.project.dir || !is_unsaved(a, dir) do return
	os.remove_all(dir)
}
