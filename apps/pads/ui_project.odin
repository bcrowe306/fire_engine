package pads

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"

// Recent projects kept.
RECENT :: 8
// How often unsaved changes are saved on their own.
AUTOSAVE_EVERY :: 60 * time.Second

// What the File menu keeps between runs, and the export under way.
Project_State :: struct {
	recent:     [dynamic]string,
	last_save:  time.Tick,
	title:      string, // the window's, as last set
	export:     pm.Export,
	exporting:  bool,
	progress:   f64,
	export_open: bool, // the Export dialog shows
	settings:   pm.Export_Settings,
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
	dir := a.prefs
	if dir != "" {
		os.make_directory_all(dir)
	} else {
		p := sdl.GetPrefPath("Fire Engine", "Pads")
		if p == nil do return ""
		dir = strings.clone_from_cstring(cstring(p), context.temp_allocator)
		sdl.free(rawptr(p))
	}
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// Reads the recent projects list (folders that still have a project).
recent_load :: proc(a: ^App) {
	st := &a.proj
	path := prefs_file(a, "recent.txt")
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || len(st.recent) >= RECENT do continue
		f, _ := filepath.join({l, pm.PROJECT_FILE}, context.temp_allocator)
		if os.exists(f) do append(&st.recent, strings.clone(l))
	}
}

// Puts `dir` at the top of the recent projects, and writes the list.
recent_add :: proc(a: ^App, dir: string) {
	st := &a.proj
	for r, i in st.recent do if r == dir {
		delete(r)
		ordered_remove(&st.recent, i)
		break
	}
	inject_at(&st.recent, 0, strings.clone(dir))
	for len(st.recent) > RECENT do delete(pop(&st.recent))
	if path := prefs_file(a, "recent.txt"); path != "" {
		_ = os.write_entire_file(path, transmute([]u8)strings.join(st.recent[:], "\n", context.temp_allocator))
	}
}

// Frees the project state.
project_state_destroy :: proc(st: ^Project_State) {
	for r in st.recent do delete(r)
	delete(st.recent)
	delete(st.title)
	pm.export_destroy(&st.export)
}

// --- actions -------------------------------------------------------------------------------

// Saves into the project's folder (a new one is in the temporary folder
// until Save As gives it a place).
save_project :: proc(a: ^App) -> bool {
	if pm.model_save(&a.m) != .None {
		ui.toast(&a.ws.toasts, .Error, "Could not save the project")
		return false
	}
	a.proj.last_save = time.tick_now()
	recent_add(a, a.m.project.dir)
	return true
}

// Opens the project in folder `dir`.
open_project :: proc(a: ^App, dir: string) -> bool {
	if pm.model_load(&a.m, dir) != .None {
		ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not open %s", filepath.base(dir)))
		return false
	}
	a.selected, a.bank, a.fx = 0, 0, {}
	a.seq.selected = -1
	a.proj.last_save = time.tick_now()
	recent_add(a, dir)
	ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Opened %s", filepath.base(dir)))
	return true
}

// A new, empty project (in the temporary folder until saved somewhere);
// what was open is saved first.
new_project :: proc(a: ^App) {
	if pm.model_dirty(&a.m) do pm.model_save(&a.m)
	dir, _ := os.make_directory_temp("", "Untitled.pads", context.temp_allocator)
	if pm.model_new(&a.m, dir) != .None do ui.toast(&a.ws.toasts, .Error, "Could not start a new project")
	a.selected, a.bank, a.fx = 0, 0, {}
	a.seq.selected = -1
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
	case .Open, .Save_As:
		sdl.ShowOpenFolderDialog(cb, a, a.platform.window, nil, false)
	case .Export:
		if a.proj.settings.stems != .None {
			sdl.ShowOpenFolderDialog(cb, a, a.platform.window, nil, false)
		} else {
			filters := [1]sdl.DialogFileFilter{{name = "WAV", pattern = "wav"}}
			sdl.ShowSaveFileDialog(cb, a, a.platform.window, &filters[0], 1, nil)
		}
	}
}

// What a dialog chose.
subscribe_project :: proc(a: ^App) {
	app.subscribe(&a.bus, Project_Chosen, proc(user: rawptr, e: ^Project_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		switch e.what {
		case .Open: open_project(a, e.path)
		case .Save_As:
			dir := e.path
			if !strings.has_suffix(dir, ".pads") do dir = strings.concatenate({dir, "/", "Untitled.pads"}, context.temp_allocator)
			if pm.model_save_as(&a.m, dir) == .None {
				recent_add(a, dir)
				ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved as %s", filepath.base(dir)))
			} else {
				ui.toast(&a.ws.toasts, .Error, "Could not save there")
			}
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

// Each frame: an export's next slice, autosave, the window's title.
project_frame :: proc(a: ^App) {
	st := &a.proj
	if st.exporting {
		st.progress = pm.export_step(&a.m, &st.export, 96_000)
		if st.export.finished || st.export.failed {
			files := pm.export_finish(&a.m, &st.export)
			st.exporting = false
			if st.export.failed do ui.toast(&a.ws.toasts, .Error, "The export failed")
			else if st.export.to_pad >= 0 do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Resampled onto %s", pm.pad_label(st.export.to_pad)))
			else do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Exported %d file%s", len(files), "" if len(files) == 1 else "s"))
		}
	}
	if pm.model_dirty(&a.m) && time.tick_since(st.last_save) > AUTOSAVE_EVERY && !st.exporting {
		if pm.model_save(&a.m) == .None do st.last_save = time.tick_now()
	}
	title := fmt.tprintf("%s%s — Pads", strings.trim_suffix(filepath.base(a.m.project.dir), ".pads"), " •" if pm.model_dirty(&a.m) else "")
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
		if ui.segmented("src", {"This sequence", "The song"}, &src) do s.source = pm.Export_Source(src)
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
