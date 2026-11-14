package pads

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import app "app:core"
import "app:ui"
import pa "api"
import pc "core"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"

// What the File menu keeps between runs, and the export under way.
Project_State :: struct {
	title:      string, // the window's, as last set
	export:     pm.Export,
	exporting:  bool,
	progress:   f64,
	export_open: bool, // the Export dialog shows
	settings:   pm.Export_Settings,
	rename_open: bool, // the Rename Project dialog shows
	rename_buf: [64]u8,
}

// A folder or file chosen in one of the project dialogs.
Project_Chosen :: struct {
	what: enum u8 {Open, Save_As, Export},
	path: string,
}

// --- recent projects -----------------------------------------------------------------------

// The path of preferences file `name`: in --prefs's folder, or the
// system's place for them (temporary allocator; "" if there is none).
prefs_file :: proc(a: ^App, name: string) -> string {
	dir := a.prefs if a.prefs != "" else settings_folder(a)
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	// Kept elsewhere before settings.ini: brought over the first time.
	if a.prefs == "" && !os.exists(path) {
		if p := sdl.GetPrefPath("Fire Engine", "Pads"); p != nil {
			old, _ := filepath.join({string(cstring(p)), name}, context.temp_allocator)
			sdl.free(rawptr(p))
			if data, err := os.read_entire_file(old, context.temp_allocator); err == nil do _ = os.write_entire_file(path, data)
		}
	}
	return path
}

// Frees the project state.
project_state_destroy :: proc(st: ^Project_State) {
	delete(st.title)
	pm.export_destroy(&st.export)
}

// --- actions -------------------------------------------------------------------------------

// Saves into the project's folder (a new one is in the unsaved folder
// until Save As gives it a place: that asks first).
save_project :: proc(a: ^App) -> bool {
	if a.files.untitled { // not yet anywhere: name it and pick a place first
		project_dialog(a, .Save_As)
		return false
	}
	return toast_failed(a, pa.project_save(&a.api), "Could not save the project")
}

// Opens the project in folder `dir` (what was open is left without
// saving: `leave` asked first).
open_project :: proc(a: ^App, dir: string) -> bool {
	if !toast_failed(a, pa.project_open(&a.api, dir, discard_changes = true), fmt.tprintf("Could not open %s", filepath.base(dir))) do return false
	ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Opened %s", filepath.base(dir)))
	return true
}

// A new, empty project (in the unsaved folder until saved somewhere).
// (`leave` asks to save what was open first.)
new_project :: proc(a: ^App) {
	toast_failed(a, pa.project_new(&a.api, discard_changes = true), "Could not start a new project")
}

// A toast saying what failed and why, when `r` isn't Ok; true when it is.
toast_failed :: proc(a: ^App, r: pa.Result, what: string) -> bool {
	if r == .Ok do return true
	why, _ := pa.last_error(&a.api)
	ui.toast(&a.ws.toasts, .Error, fmt.tprintf("%s: %s", what, why))
	return false
}

// What the app does when the core opened, made or recovered a project:
// the selection back to the top, the view as the project was left.
project_opened :: proc(user: rawptr) {
	a := (^App)(user)
	a.selected, a.bank, a.fx = 0, 0, {}
	a.seq.selected = -1
	view_restore(a)
}

// The system's folder or file dialog; the choice comes back on the bus.
project_dialog :: proc(a: ^App, what: type_of(Project_Chosen{}.what)) {
	@(static) pending: type_of(Project_Chosen{}.what)
	pending = what
	cb :: proc "c" (user: rawptr, files: [^]cstring, filter: i32) {
		if files == nil || files[0] == nil do return
		a := (^App)(user)
		context = runtime.default_context()
		app.post_any_thread(&a.bus, Project_Chosen{pending, strings.clone(string(files[0]))})
	}
	switch what {
	case .Open:
		sdl.ShowOpenFolderDialog(cb, a, a.platform.window, nil, false)
	case .Save_As:
		// A name and a place: "<name>.pads" (a folder: the project and its
		// samples), in Documents for a new one, else beside this one.
		filters := [1]sdl.DialogFileFilter{{name = "Pads project", pattern = "pads"}}
		where_ := filepath.dir(a.m.project.dir)
		if a.files.untitled {
			where_ = "."
			if d := sdl.GetUserFolder(.DOCUMENTS); d != nil do where_ = strings.clone_from_cstring(d, context.temp_allocator)
			if a.settings.projects_folder != "" do where_ = a.settings.projects_folder
		}
		name := a.files.save_name if a.files.untitled && a.files.save_name != "" else project_name(a)
		start_at := fmt.ctprintf("%s/%s.pads", where_, name)
		sdl.ShowSaveFileDialog(cb, a, a.platform.window, &filters[0], 1, start_at)
	case .Export:
		if a.proj.settings.stems != .None {
			sdl.ShowOpenFolderDialog(cb, a, a.platform.window, nil, false)
		} else {
			filters := [1]sdl.DialogFileFilter{{name = "WAV", pattern = "wav"}}
			// Named after what it renders: the arrangement, or the sequence.
			p := &a.m.project
			name := pm.arrangement_name(p, p.arrangement) if a.proj.settings.source == .Song else pm.sequence_name(p, p.slot)
			start_at: cstring = nil
			if p.dir != "" do start_at = fmt.ctprintf("%s/%s.wav", p.dir, name)
			sdl.ShowSaveFileDialog(cb, a, a.platform.window, &filters[0], 1, start_at)
		}
	}
}

// What a dialog chose.
subscribe_project :: proc(a: ^App) {
	app.subscribe(&a.bus, Project_Chosen, proc(user: rawptr, e: ^Project_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		switch e.what {
		case .Open: leave(a, .Open, e.path)
		case .Save_As:
			save_project_as(a, e.path)
			leave_after_save(a)
		case .Export:
			path := e.path
			if a.proj.settings.stems == .None && !strings.has_suffix(path, ".wav") do path = strings.concatenate({path, ".wav"}, context.temp_allocator)
			start_export(a, path)
		}
	}, a)
}

// Starts an export (it runs a slice each frame).
start_export :: proc(a: ^App, path: string) {
	st := &a.proj
	pm.export_destroy(&st.export)
	if !pm.export_begin(&a.m, &st.export, st.settings, path) {
		ui.toast(&a.ws.toasts, .Warning, "Nothing to export")
		return
	}
	st.exporting, st.progress = true, 0
}

// Resamples the current sequence onto the next empty pad.
start_resample :: proc(a: ^App) {
	st := &a.proj
	pm.export_destroy(&st.export)
	if !pm.export_to_pad(&a.m, &st.export) {
		ui.toast(&a.ws.toasts, .Warning, "No empty pad to resample onto")
		return
	}
	st.exporting, st.progress = true, 0
}

// Bounces pads `pads` (what they play in the current sequence, after
// their faders) onto the next empty pad.
start_bounce_pads :: proc(a: ^App, pads: Pad_Set) {
	st := &a.proj
	if st.exporting do return
	pm.export_destroy(&st.export)
	if !pm.bounce_pads(&a.m, &st.export, pads) {
		ui.toast(&a.ws.toasts, .Warning, "Nothing to bounce, or no empty pad")
		return
	}
	st.exporting, st.progress = true, 0
}

// Bounces bus `b` (0-based) onto the next empty pad.
start_bounce_bus :: proc(a: ^App, b: int) {
	st := &a.proj
	if st.exporting do return
	pm.export_destroy(&st.export)
	if !pm.bounce_bus(&a.m, &st.export, b) {
		ui.toast(&a.ws.toasts, .Warning, "Nothing on that bus to bounce, or no empty pad")
		return
	}
	st.exporting, st.progress = true, 0
}

// Bounces pad `i` in place: an audio track of its sound, the pad muted.
start_bounce_in_place :: proc(a: ^App, i: int) {
	st := &a.proj
	if st.exporting do return
	pm.export_destroy(&st.export)
	if !pm.bounce_in_place_begin(&a.m, &st.export, i) {
		ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("%s can't be bounced in place (no notes, an audio track, or no empty pad)", pm.pad_label(i)))
		return
	}
	st.exporting, st.progress = true, 0
}

// Freezes pad `i` (its renderings made a slice a frame, as an export).
start_freeze :: proc(a: ^App, i: int) {
	st := &a.proj
	if st.exporting do return
	pm.export_destroy(&st.export)
	if !pm.freeze_begin(&a.m, &st.export, i) {
		ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("%s has nothing to freeze (no notes, or an audio pad)", pm.pad_label(i)))
		return
	}
	st.exporting, st.progress = true, 0
}

// Each frame: an export's next slice, autosave, the window's title.
project_frame :: proc(a: ^App) {
	st := &a.proj
	if st.exporting {
		st.progress = pm.export_step(&a.m, &st.export, 96_000)
		if st.export.finished || st.export.failed {
			files := pm.export_finish(&a.m, &st.export)
			st.exporting = false
			if st.export.failed do ui.toast(&a.ws.toasts, .Error, "The export failed")
			else if st.export.made >= 0 do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s bounced in place onto %s", pm.pad_label(st.export.in_place), pm.pad_label(st.export.made)))
			else if st.export.to_pad >= 0 && st.export.bounce != "" do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Bounced onto %s", pm.pad_label(st.export.to_pad)))
			else if st.export.to_pad >= 0 do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Resampled onto %s", pm.pad_label(st.export.to_pad)))
			else if st.export.freeze >= 0 do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s frozen", pm.pad_label(st.export.freeze)))
			else do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Exported %d file%s", len(files), "" if len(files) == 1 else "s"))
		}
	}
	pc.autosave(&a.core, time.Duration(a.settings.autosave_min) * time.Minute, st.exporting) // (backups: the project saves only when asked)
	title := fmt.tprintf("%s%s — Pads", project_name(a), " •" if pm.model_dirty(&a.m) else "")
	if title != st.title {
		delete(st.title)
		st.title = strings.clone(title)
		sdl.SetWindowTitle(a.platform.window, fmt.ctprintf("%s", title))
	}
}

// --- the Export dialog ---------------------------------------------------------------------

// The Export dialog (and the progress of one under way).
draw_export :: proc(a: ^App) {
	st := &a.proj
	if st.exporting {
		im.OpenPopup("Exporting")
		if im.BeginPopupModal("Exporting", nil, {.AlwaysAutoResize, .NoMove}) {
			im.Text("%s", fmt.ctprintf("Rendering %d of %d…", min(st.export.pass + 1, len(st.export.passes)), len(st.export.passes)))
			im.ProgressBar(f32(st.progress), {320, 0})
			if !st.exporting do im.CloseCurrentPopup()
			im.EndPopup()
		}
		return
	}
	if !st.export_open do return
	im.OpenPopup("Export")
	if im.BeginPopupModal("Export", &st.export_open, {.AlwaysAutoResize}) {
		s := &st.settings
		src := int(s.source)
		im.TextDisabled("What")
		if ui.segmented("src", {"This sequence", "A song"}, &src) do s.source = pm.Export_Source(src)
		if s.source == .Song {
			// Which arrangement (each exports on its own).
			m := &a.m
			im.SameLine()
			im.SetNextItemWidth(170)
			if ui.combo("##exparr", fmt.ctprintf("%s", pm.arrangement_name(&m.project, m.project.arrangement))) {
				for k in 0 ..< m.project.arrangement_count {
					if im.Selectable(fmt.ctprintf("%s###ea%d", pm.arrangement_name(&m.project, k), k), k == m.project.arrangement) do pm.select_arrangement(m, k)
				}
				im.EndCombo()
			}
			im.TextDisabled("%s", fmt.ctprintf("%s long", clock_text(pm.song_seconds(&m.project))))
		}
		stems := int(s.stems)
		im.TextDisabled("As")
		if ui.segmented("stems", {"Mixdown", "Stems: pads", "Stems: buses"}, &stems) do s.stems = pm.Export_Stems(stems)
		enc := int(s.encoding)
		im.TextDisabled("Format")
		if ui.segmented("enc", {"16-bit", "24-bit", "32-bit float"}, &enc) do s.encoding = pm.Export_Encoding(enc)
		rates := [3]f64{44_100, 48_000, 96_000}
		r := 1
		for x, i in rates do if s.rate == x do r = i
		im.TextDisabled("Sample rate")
		if ui.segmented("rate", {"44.1 kHz", "48 kHz", "96 kHz"}, &r) do s.rate = rates[r]
		if s.rate == 0 do s.rate = 48_000
		tail := f32(s.tail)
		im.TextDisabled("After the end (for reverb and echoes)")
		im.SetNextItemWidth(200)
		if im.DragFloat("##tail", &tail, 0.05, 0, 10, "Tail %.1f s", {.ClampOnInput}) do s.tail = f64(tail)
		im.Spacing()
		im.Separator()
		im.Spacing()
		if im.Button(ui.ICON_DOWNLOAD + "  Export…") {
			st.export_open = false
			project_dialog(a, .Export)
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") {
			st.export_open = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

// The project's name: its folder's, without ".pads" ("Untitled" until it
// is saved somewhere).
project_name :: proc(a: ^App) -> string {
	name, _ := pa.project_name(&a.api)
	return name
}

// Saves the project as `path` (a "<name>.pads" folder: ".pads" is added
// when missing); from now on it is the project. Not over another project.
save_project_as :: proc(a: ^App, path: string) -> bool {
	if !toast_failed(a, pa.project_save_as(&a.api, path), "Could not save") do return false
	ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved as %s", project_name(a)))
	return true
}

// Renames the project to `name`: its folder becomes "<name>.pads" beside
// where it is (a new project: the Save dialog, suggesting that name).
rename_project :: proc(a: ^App, new_name: string) -> bool {
	name := strings.trim_space(new_name)
	if a.files.untitled && pc.name_ok(name) { // not saved anywhere yet: the Save dialog, with that name
		delete(a.files.save_name)
		a.files.save_name = strings.clone(name)
		project_dialog(a, .Save_As)
		return true
	}
	if !toast_failed(a, pa.project_rename(&a.api, name), "Could not rename the project") do return false
	ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Renamed to %s", name))
	return true
}

// The Rename Project dialog (File > Rename Project…).
draw_rename_project :: proc(a: ^App) {
	st := &a.proj
	if !st.rename_open do return
	im.OpenPopup("Rename Project")
	if im.BeginPopupModal("Rename Project", &st.rename_open, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() {
			st.rename_buf = {}
			copy(st.rename_buf[:len(st.rename_buf) - 1], project_name(a))
			im.SetKeyboardFocusHere()
		}
		im.SetNextItemWidth(280)
		enter := im.InputText("##projname", cstring(&st.rename_buf[0]), len(st.rename_buf), {.EnterReturnsTrue, .AutoSelectAll})
		im.TextDisabled("%s", fmt.ctprintf("Its folder: %s.pads", strings.truncate_to_byte(string(st.rename_buf[:]), 0)))
		if im.Button("Rename") || enter {
			if rename_project(a, strings.truncate_to_byte(string(st.rename_buf[:]), 0)) {
				st.rename_open = false
				im.CloseCurrentPopup()
			}
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) {
			st.rename_open = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
