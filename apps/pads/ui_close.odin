package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "app:ui"
import pm "model"
import im "deps:imgui"

// Leaving a project with unsaved changes asks first (Save, Don't Save,
// Cancel): quitting, closing the window, a new project, opening another.
// The project saves only when asked; its autosaves are backups beside it
// (`pm.model_save_backup`), and a marker in the settings folder says
// which project is open: still there when Pads starts, Pads stopped
// without closing, and it offers the backup.

// What leaving waits on.
Leave_Action :: enum u8 {None, Quit, New, New_From, Open_Dialog, Open}

// The prompt's state.
Leave_State :: struct {
	action:    Leave_Action,
	path:      string, // Open: where (owned)
	asking:    bool,
	saving_as: bool, // Save chosen on an untitled project: Save As first, then the action
	recover:   string, // a project to offer a crash's backup of (owned; "" none)
}

// Does `action` (opening `path`), first asking to save what changed.
leave :: proc(a: ^App, action: Leave_Action, path := "") {
	st := &a.leave
	delete(st.path)
	st.action, st.path = action, strings.clone(path)
	if !pm.model_dirty(&a.m) || a.platform.driver != nil { // (scripts and tests don't ask)
		leave_go(a)
		return
	}
	st.asking = true
}

// Does what leaving waited on (the project's backup thrown away).
@(private)
leave_go :: proc(a: ^App) {
	st := &a.leave
	action := st.action
	st.action, st.asking, st.saving_as = .None, false, false
	switch action {
	case .None:
	case .Quit:
		pm.model_discard_backup(a.m.project.dir)
		a.platform.running = false
	case .New:
		pm.model_discard_backup(a.m.project.dir)
		new_project(a)
	case .New_From:
		pm.model_discard_backup(a.m.project.dir)
		new_from_template(a, st.path)
	case .Open_Dialog:
		project_dialog(a, .Open)
	case .Open:
		pm.model_discard_backup(a.m.project.dir)
		open_project(a, st.path)
	}
}

// After Save As (the untitled project's Save): what was waiting goes on.
leave_after_save :: proc(a: ^App) {
	if a.leave.saving_as && !pm.model_dirty(&a.m) do leave_go(a)
}

// The prompt (when asking) and the crash recovery offer.
draw_leave :: proc(a: ^App) {
	st := &a.leave
	// The window's close button or the system's quit: asked here.
	if a.platform.quit_requested {
		a.platform.quit_requested = false
		leave(a, .Quit)
	}
	if st.asking {
		im.OpenPopup("Unsaved changes")
		if im.BeginPopupModal("Unsaved changes", nil, {.AlwaysAutoResize}) {
			im.Text("%s", fmt.ctprintf("Save the changes to %s?", project_name(a)))
			im.TextDisabled("Without saving, they are lost.")
			im.Spacing()
			if im.Button("Save", {110, 0}) {
				if a.proj.untitled {
					st.saving_as, st.asking = true, false
					project_dialog(a, .Save_As) // (then the action, once saved)
				} else if save_project(a) {
					leave_go(a)
				}
				im.CloseCurrentPopup()
			}
			ui.name("save changes")
			im.SameLine()
			if im.Button("Don't Save", {110, 0}) {
				leave_go(a)
				im.CloseCurrentPopup()
			}
			ui.name("don't save")
			im.SameLine()
			if im.Button("Cancel", {90, 0}) || im.IsKeyPressed(.Escape) {
				st.asking, st.action = false, .None
				im.CloseCurrentPopup()
			}
			ui.name("cancel leaving")
			im.EndPopup()
		}
	}
	if st.recover != "" {
		im.OpenPopup("Recover")
		if im.BeginPopupModal("Recover", nil, {.AlwaysAutoResize}) {
			im.Text("%s", fmt.ctprintf("Pads didn't close properly. Recover the changes to %s it kept?", strings.trim_suffix(filepath.base(st.recover), ".pads")))
			im.TextDisabled("They were autosaved, but not saved into the project.")
			im.Spacing()
			if im.Button("Recover", {110, 0}) {
				if pm.model_load_backup(&a.m, st.recover) == .None {
					view_restore(a)
					ui.toast(&a.ws.toasts, .Success, "Recovered: save to keep the changes")
				}
				delete(st.recover)
				st.recover = ""
				im.CloseCurrentPopup()
			}
			ui.name("recover")
			im.SameLine()
			if im.Button("Discard", {110, 0}) {
				pm.model_discard_backup(st.recover)
				delete(st.recover)
				st.recover = ""
				im.CloseCurrentPopup()
			}
			ui.name("discard backup")
			im.EndPopup()
		}
	}
}

// The marker saying which project is open (in the settings folder).
@(private)
session_marker :: proc(a: ^App) -> string {
	p, _ := filepath.join({settings_folder(a), "open-project.txt"}, context.temp_allocator)
	return p
}

// Notes that the project is open (until a clean exit).
session_mark :: proc(a: ^App) {
	_ = os.write_entire_file(session_marker(a), transmute([]u8)a.m.project.dir)
}

// A clean exit: the marker and the open project's backup gone.
session_unmark :: proc(a: ^App) {
	pm.model_discard_backup(a.m.project.dir)
	os.remove(session_marker(a))
}

// At start: the project open when Pads last stopped without closing, if
// it left a backup newer than itself ("" none).
session_crashed :: proc(a: ^App) -> string {
	data, err := os.read_entire_file(session_marker(a), context.temp_allocator)
	if err != nil do return ""
	dir := strings.trim_space(string(data))
	if dir == "" || !pm.model_backup_newer(dir) do return ""
	return dir
}

// Autosaves (as backups) every few minutes, while there are changes.
autosave_frame :: proc(a: ^App) {
	st := &a.proj
	every := time.Duration(a.settings.autosave_min) * time.Minute
	if every > 0 && pm.model_dirty(&a.m) && time.tick_since(st.last_backup) > every && !st.exporting {
		pm.model_save_backup(&a.m)
		st.last_backup = time.tick_now()
	}
}

// --- templates ---------------------------------------------------------------------------------

// Where the user's project templates are (each a project folder).
templates_folder :: proc(a: ^App) -> string {
	p, _ := filepath.join({settings_folder(a), "Templates"}, context.temp_allocator)
	return p
}

// The templates there are: their names and folders (temporary allocator).
template_list :: proc(a: ^App) -> (names, dirs: []string) {
	ns := make([dynamic]string, context.temp_allocator)
	ds := make([dynamic]string, context.temp_allocator)
	h, err := os.open(templates_folder(a))
	if err != nil do return
	defer os.close(h)
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	for fi in infos do if fi.type == .Directory && strings.has_suffix(fi.name, ".pads") {
		append(&ns, strings.trim_suffix(fi.name, ".pads"))
		d, _ := filepath.join({templates_folder(a), fi.name}, context.temp_allocator)
		append(&ds, d)
	}
	return ns[:], ds[:]
}

// A new, untitled project made from the template in folder `dir`.
new_from_template :: proc(a: ^App, dir: string) {
	to, _ := os.make_directory_temp("", "Untitled.pads", context.temp_allocator)
	if pm.model_new_from(&a.m, dir, to) != .None {
		ui.toast(&a.ws.toasts, .Error, "Could not start from that template")
		return
	}
	a.proj.untitled = true
	a.selected, a.bank, a.fx = 0, 0, {}
	a.seq.selected = -1
	view_restore(a)
	session_mark(a)
	ui.toast(&a.ws.toasts, .Success, fmt.tprintf("A new project from %s", strings.trim_suffix(filepath.base(dir), ".pads")))
}

// The Save as Template dialog's state.
Template_Ui :: struct {
	open: bool,
	name: [64]u8,
}

// Save as Template: its name, then the project copied into the templates.
draw_template_save :: proc(a: ^App) {
	st := &a.template
	if !st.open do return
	im.OpenPopup("Save as Template")
	if im.BeginPopupModal("Save as Template", &st.open, {.AlwaysAutoResize}) {
		im.TextDisabled("New projects can start from it (File > New from Template)")
		im.SetNextItemWidth(280)
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		enter := im.InputText("##tplname", cstring(&st.name[0]), len(st.name), {.EnterReturnsTrue})
		ui.name("template name")
		name := strings.trim_space(strings.truncate_to_byte(string(st.name[:]), 0))
		if (im.Button("Save") || enter) && name != "" {
			dir, _ := filepath.join({templates_folder(a), strings.concatenate({pm.safe_name(name), ".pads"}, context.temp_allocator)}, context.temp_allocator)
			os.remove_all(dir) // (the same name: replaced)
			if pm.model_save_copy(&a.m, dir) == .None do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved the template %s", name))
			else do ui.toast(&a.ws.toasts, .Error, "Could not save the template")
			st.open = false
			im.CloseCurrentPopup()
		}
		ui.name("save template")
		im.SameLine()
		if im.Button("Cancel") {
			st.open = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
