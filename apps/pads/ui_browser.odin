package pads

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import pm "model"
import "app:ui"
import im "deps:imgui"

// A list of a folder's subfolders and audio files.
Browser :: struct {
	dir:     string,
	entries: [dynamic]Entry,
	scanned: bool,
	selected: int,
}

Entry :: struct {
	name:  string,
	path:  string,
	is_dir: bool,
}

AUDIO_EXTS := []string{".wav", ".aif", ".aiff", ".flac", ".mp3", ".ogg"}

browser_init :: proc(b: ^Browser) {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do home = os.get_env("USERPROFILE", context.temp_allocator)
	music, _ := filepath.join({home, "Music"}, context.temp_allocator)
	b.dir = strings.clone(music if os.is_dir(music) else home)
	b.selected = -1
}

browser_destroy :: proc(b: ^Browser) {
	clear_entries(b)
	delete(b.entries)
	delete(b.dir)
}

@(private)
clear_entries :: proc(b: ^Browser) {
	for e in b.entries {
		delete(e.name)
		delete(e.path)
	}
	clear(&b.entries)
}

@(private)
scan :: proc(b: ^Browser) {
	clear_entries(b)
	b.scanned, b.selected = true, -1
	infos, err := os.read_all_directory_by_path(b.dir, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if strings.has_prefix(fi.name, ".") do continue
		is_dir := fi.type == .Directory
		ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
		if !is_dir && !slice.contains(AUDIO_EXTS, ext) do continue
		append(&b.entries, Entry{strings.clone(fi.name), strings.clone(fi.fullpath), is_dir})
	}
	slice.sort_by(b.entries[:], proc(x, y: Entry) -> bool {
		if x.is_dir != y.is_dir do return x.is_dir
		return strings.to_lower(x.name, context.temp_allocator) < strings.to_lower(y.name, context.temp_allocator)
	})
}

// The browser panel: click a folder to open it, double-click a file to
// load it onto the selected pad, or drag it onto a pad.
draw_browser :: proc(user: rawptr) {
	a := (^App)(user)
	b := &a.browser
	if !b.scanned do scan(b)
	if ui.icon_button(ui.ICON_ARROW_UP, "Up a folder") {
		parent := filepath.dir(b.dir)
		delete(b.dir)
		b.dir = strings.clone(parent)
		scan(b)
	}
	im.SameLine()
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", strings.clone_to_cstring(filepath.base(b.dir), context.temp_allocator))
	im.Separator()
	open: string
	for e, k in b.entries {
		im.PushIDInt(i32(k))
		label := strings.concatenate({ui.ICON_FOLDER if e.is_dir else ui.ICON_FILE_AUDIO, "  ", e.name}, context.temp_allocator)
		if im.Selectable(strings.clone_to_cstring(label, context.temp_allocator), k == b.selected, {.AllowDoubleClick}) {
			b.selected = k
			if e.is_dir {
				open = e.path
			} else if im.IsMouseDoubleClicked(.Left) {
				pm.load_onto_pad(&a.m, a.selected, e.path)
			}
		}
		if !e.is_dir && im.BeginDragDropSource() {
			im.SetDragDropPayload("PADS_FILE", raw_data(e.path), uint(len(e.path)))
			im.Text("%s  %s", ui.ICON_FILE_AUDIO, strings.clone_to_cstring(e.name, context.temp_allocator))
			im.EndDragDropSource()
		}
		im.PopID()
	}
	if len(b.entries) == 0 do im.TextDisabled("No audio files here")
	if open != "" {
		next := strings.clone(open)
		delete(b.dir)
		b.dir = next
		scan(b)
	}
}
