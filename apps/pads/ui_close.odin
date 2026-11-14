package pads

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "app:ui"
import pa "api"
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

// Does what leaving waited on (what was open left without saving: the
// API throws its backup away, and an unsaved project's folder).
@(private)
leave_go :: proc(a: ^App) {
	st := &a.leave
	action := st.action
	st.action, st.asking, st.saving_as = .None, false, false
	switch action {
	case .None:
	case .Quit:
		// (An unsaved project left without saving: its folder goes once Pads
		// has let go of its files.)
		pm.model_discard_backup(a.m.project.dir) // api-lint: quitting without saving: the backup goes, the project stays open until Pads has stopped
		if a.files.untitled {
			delete(a.files.discard)
			a.files.discard = strings.clone(a.m.project.dir)
		}
		a.platform.running = false
	case .New:
		new_project(a)
	case .New_From:
		if toast_failed(a, pa.project_new_from_template(&a.api, st.path, discard_changes = true), "Could not start from that template") {
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("A new project from %s", st.path))
		}
	case .Open_Dialog:
		project_dialog(a, .Open)
	case .Open:
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
				if a.files.untitled {
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
				if toast_failed(a, pa.project_recover(&a.api, st.recover), "Could not recover") {
					ui.toast(&a.ws.toasts, .Success, "Recovered: save to keep the changes")
				}
				delete(st.recover)
				st.recover = ""
				im.CloseCurrentPopup()
			}
			ui.name("recover")
			im.SameLine()
			if im.Button("Discard", {110, 0}) {
				pa.project_discard_backup(&a.api, st.recover) // (an unsaved one's folder too: nothing of it to keep)
				delete(st.recover)
				st.recover = ""
				im.CloseCurrentPopup()
			}
			ui.name("discard backup")
			im.EndPopup()
		}
	}
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
			if toast_failed(a, pa.project_save_template(&a.api, name), "Could not save the template") do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved the template %s", name))
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
