// The project manager: a page over the window when Pads starts with no
// project to open, after New Project, and from File > Projects (and a
// controller's Shift + Setup). The project open (Save, Save As, Rename),
// its recent projects (the latest first, when each was last changed), all
// the projects folder's (searched; each duplicated or moved to the Trash),
// templates, a new empty project, Open…. Choosing one opens it (what was
// open is asked about first, as the File menu's); Empty Project goes on
// with the new one already open. The Library shows the projects
// meanwhile (Recent, else Projects), and so does a controller's browser
// (Push 2's Browse), the same list: an item picked there is the one lit
// here.
package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "app:ui"
import pa "api"
import im "deps:imgui"

// The project manager's state (the window's and a controller's).
Start_Page :: struct {
	open: bool,
	off:  bool, // --no-start-page: not at start, nor after New Project (the API still shows it)
	search:     [64]u8, // All Projects' filter
	dup_open:   bool,   // the Duplicate dialog: for which project, under what name
	dup_dir:    string, // (owned)
	dup_name:   [64]u8,
	trash_open: bool,   // the Move to Trash dialog: for which project
	trash_dir:  string, // (owned)
	ctl_tab:    int, // a controller's: 0 Recent, 1 All, 2 Templates
	ctl_sel:    int,
}

// Shows the project manager, the Library on the projects (the recent ones,
// else the projects folder's).
start_page_show :: proc(a: ^App) {
	a.start.open = true
	ps, _ := pa.project_state(&a.api)
	want := Lib_Kind.Recent if ps.recent > 0 else .Projects
	for c, k in lib_categories(a) do if c.kind == want {
		lib_show(a, k)
		break
	}
}

// Draws the project manager while it shows: over the Library, the views
// and the devices (the toolbar and the status bar stay).
draw_start_page :: proc(a: ^App) {
	if !a.start.open do return
	t := ui.theme()
	vp := im.GetMainViewport()
	im.SetNextWindowPos(vp.WorkPos) // (the work area: under the toolbar, over the status bar)
	im.SetNextWindowSize(vp.WorkSize)
	// On top (a docked panel brought forward can't cover it), but not
	// while something is held or a menu or dialog is open.
	if !im.IsAnyItemActive() && !im.IsPopupOpen("", {.AnyPopupId, .AnyPopupLevel}) do im.SetNextWindowFocus()
	im.PushStyleVarVec2(.WindowPadding, {36, 28})
	shown := im.Begin("Projects###start page", nil, {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking})
	im.PopStyleVar()
	defer im.End()
	if !shown do return
	f := a.platform.fonts
	// The heading, the project open (its name, whether it's saved) with
	// Save, Save As and Rename, and the way back to it.
	im.PushFontFloat(f.bold, 28)
	im.Text("Projects")
	im.PopFont()
	{
		st, _ := pa.project_state(&a.api)
		name := project_name(a)
		state := "Not saved yet" if st.untitled else ("Unsaved changes" if st.dirty else "Saved")
		im.AlignTextToFramePadding()
		im.Text("%s", fmt.ctprintf("Open: %s", name))
		im.SameLine(0, 10)
		im.TextDisabled("%s", fmt.ctprintf("%s", state))
		im.SameLine(0, 18)
		if im.Button(ui.ICON_SAVE + "  Save##start") do save_project(a)
		ui.name("start save")
		im.SameLine(0, 6)
		if im.Button("Save As…##start") {
			a.lib.save_as_name = {}
			copy(a.lib.save_as_name[:len(a.lib.save_as_name) - 1], name)
			a.lib.save_as_open = true
		}
		ui.name("start save as")
		im.SameLine(0, 6)
		if im.Button("Rename…##start") do a.proj.rename_open = true
		ui.name("start rename")
		im.SameLine(0, 18)
		if im.Button(ui.ICON_X + "  Back to it##start") do a.start.open = false
		ui.name("start close")
	}
	ps, _ := pa.project_state(&a.api)
	// The Library's selected project (a controller's browser too).
	lit := ""
	if c := lib_cat(a); c.kind == .Recent || c.kind == .Projects || c.kind == .Templates {
		items := lib_items(a)
		if k := lib_selected(a, items); k >= 0 do lit = items[k].path if c.kind != .Templates else items[k].name
	}
	im.Dummy({0, 12})
	avail := im.GetContentRegionAvail()
	side := min(f32(320), avail.x * 0.32)
	// Starting: empty, opened, from a template.
	if im.BeginChild("start side", {side, 0}) {
		if im.Button(ui.ICON_FILE_PLUS + "  New Empty Project", {side - 8, 44}) do leave(a, .New_Empty)
		ui.name("start empty")
		im.Dummy({0, 4})
		if im.Button(ui.ICON_FOLDER_OPEN + "  Open…", {side - 8, 36}) do leave(a, .Open_Dialog)
		ui.name("start open")
		im.Dummy({0, 10})
		im.SeparatorText("Templates")
		if ps.templates == 0 do im.TextDisabled("None yet: File > Save as Template")
		for k in 0 ..< ps.templates {
			n, _ := pa.project_template_name(&a.api, k)
			if im.Selectable(fmt.ctprintf("%s  %s##template%d", ui.ICON_FILE_PLUS, n, k), n == lit, {}, {0, 30}) do leave(a, .New_From, n)
			ui.name(fmt.tprintf("start template %s", n))
		}
	}
	im.EndChild()
	im.SameLine(0, 28)
	// The projects: recent ones, then the projects folder's others.
	if im.BeginChild("start projects", {0, 0}) {
		im.SeparatorText("Recent")
		if ps.recent == 0 do im.TextDisabled("No recent projects yet")
		im.PushID("recent") // (a project in both lists: its rows two items, not one id twice)
		for k in 0 ..< ps.recent {
			dir, _ := pa.project_recent(&a.api, k)
			start_row(a, dir, dir == lit, fmt.tprintf("start recent %d", k))
		}
		im.PopID()
		im.Dummy({0, 10})
		im.SeparatorText("All Projects")
		im.SetNextItemWidth(min(f32(320), im.GetContentRegionAvail().x))
		im.InputTextWithHint("##start search", "Search…", cstring(&a.start.search[0]), len(a.start.search))
		ui.name("start search")
		filter := strings.to_lower(strings.trim_space(string(cstring(&a.start.search[0]))), context.temp_allocator)
		n := 0
		im.PushID("all")
		for it in lib_items_of(a, {kind = .Projects}) {
			if filter != "" && !strings.contains(strings.to_lower(it.name, context.temp_allocator), filter) do continue
			start_row(a, it.path, it.path == lit, fmt.tprintf("start project %s", it.name), true)
			n += 1
		}
		im.PopID()
		if n == 0 do im.TextDisabled("None" if filter == "" else "None by that name")
	}
	im.EndChild()
	_ = t
}

// A project's row: its name, its folder, when it last changed. A click
// opens it.
@(private = "file")
start_row :: proc(a: ^App, dir: string, lit: bool, probe: string, manage := false) {
	t := ui.theme()
	name := strings.trim_suffix(filepath.base(dir), ".pads")
	there := os.exists(dir)
	when_ := ""
	if fi, err := os.stat(dir, context.temp_allocator); err == nil do when_ = ago(fi.modification_time)
	x, y := im.GetCursorScreenPos().x, im.GetCursorScreenPos().y
	w := im.GetContentRegionAvail().x
	if !there do im.BeginDisabled()
	if manage do im.SetNextItemAllowOverlap() // (its Duplicate and Trash over it take their clicks)
	if im.Selectable(fmt.ctprintf("##%s", dir), lit, {}, {0, 40}) do leave(a, .Open, dir)
	ui.name(probe)
	if !there do im.EndDisabled()
	dl := im.GetWindowDrawList()
	im.DrawList_AddText(dl, {x + 8, y + 3}, ui.col(t.text if there else t.text_dim), fmt.ctprintf("%s", name))
	ui.text_push(.Caption)
	im.DrawList_AddText(dl, {x + 8, y + 21}, ui.col(t.text_dim), fmt.ctprintf("%s", filepath.dir(dir) if there else "Not found"))
	right := x + w - 8
	if manage && there {
		right -= 64
		im.SetCursorScreenPos({right, y + 8})
		im.PushID(fmt.ctprintf("%s", dir)) // (each row's buttons its own)
		if ui.icon_button(ui.ICON_COPY, "Duplicate") do start_duplicate(a, dir)
		ui.name(fmt.tprintf("%s duplicate", probe))
		im.SameLine(0, 4)
		if ui.icon_button(ui.ICON_TRASH_2, "Move to the Trash") do start_trash(a, dir)
		ui.name(fmt.tprintf("%s trash", probe))
		im.PopID()
		im.SetCursorScreenPos({x, y + 44})
		im.Dummy({0, 0})
		right -= 8
	}
	if when_ != "" {
		c := fmt.ctprintf("%s", when_)
		im.DrawList_AddText(dl, {right - im.CalcTextSize(c).x, y + 12}, ui.col(t.text_dim), c)
	}
	ui.text_pop()
}

// Asks for a name to duplicate project `dir` under (its name and " copy"
// to start).
start_duplicate :: proc(a: ^App, dir: string) {
	delete(a.start.dup_dir)
	a.start.dup_dir = strings.clone(dir)
	a.start.dup_name = {}
	copy(a.start.dup_name[:len(a.start.dup_name) - 1], fmt.tprintf("%s copy", strings.trim_suffix(filepath.base(dir), ".pads")))
	a.start.dup_open = true
}

// Asks before moving project `dir` to the Trash.
start_trash :: proc(a: ^App, dir: string) {
	delete(a.start.trash_dir)
	a.start.trash_dir = strings.clone(dir)
	a.start.trash_open = true
}

// The project page's dialogs: Duplicate (its name) and Move to Trash (are
// you sure). A controller's display shows them too (its name editor types).
draw_start_dialogs :: proc(a: ^App) {
	st := &a.start
	if st.dup_open {
		im.OpenPopup("Duplicate Project")
		if modal_begin(a, "Duplicate Project", &st.dup_open, {.AlwaysAutoResize}) {
			modal_text(a, "The copy's name (beside it in its folder):")
			im.SetNextItemWidth(280)
			enter := modal_input(a, "##dupname", st.dup_name[:], {.EnterReturnsTrue})
			if modal_button(a, "Duplicate") || enter {
				name := strings.trim_space(string(cstring(&st.dup_name[0])))
				if toast_failed(a, pa.project_duplicate(&a.api, st.dup_dir, name), "Could not duplicate it") {
					ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Duplicated as %s", name))
					st.dup_open = false
					im.CloseCurrentPopup()
				}
			}
			im.SameLine()
			if modal_button(a, "Cancel") || im.IsKeyPressed(.Escape) {
				st.dup_open = false
				im.CloseCurrentPopup()
			}
			im.EndPopup()
		}
	}
	if st.trash_open {
		im.OpenPopup("Move to Trash")
		if modal_begin(a, "Move to Trash", &st.trash_open, {.AlwaysAutoResize}) {
			modal_text(a, fmt.tprintf("Move %s to the Trash? (You can put it back from there.)", strings.trim_suffix(filepath.base(st.trash_dir), ".pads")))
			if modal_button(a, "Move to Trash") {
				if toast_failed(a, pa.project_trash(&a.api, st.trash_dir), "Could not move it") do ui.toast(&a.ws.toasts, .Success, "Moved to the Trash")
				st.trash_open = false
				im.CloseCurrentPopup()
			}
			im.SameLine()
			if modal_button(a, "Cancel") || im.IsKeyPressed(.Escape) {
				st.trash_open = false
				im.CloseCurrentPopup()
			}
			im.EndPopup()
		}
	}
}

// Folder `dir` as one spelling (macOS's /private/var and /var are one
// place: a listing says the one, the recent list may say the other).
@(private = "file")
same_dir :: proc(dir: string) -> string {
	return strings.trim_prefix(dir, "/private")
}

// How long ago `then` was, in words.
@(private = "file")
ago :: proc(then: time.Time) -> string {
	s := time.duration_seconds(time.since(then))
	switch {
	case s < 60:        return "just now"
	case s < 3600:      return fmt.tprintf("%d min ago", int(s / 60))
	case s < 86400:     return fmt.tprintf("%d h ago", int(s / 3600))
	case s < 2 * 86400: return "yesterday"
	case s < 7 * 86400: return fmt.tprintf("%d days ago", int(s / 86400))
	}
	y, m, d := time.date(then)
	return fmt.tprintf("%d-%02d-%02d", y, int(m), d)
}
