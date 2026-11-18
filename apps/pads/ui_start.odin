// The project manager: a page over the window when Pads starts with no
// project to open, and after New Project. Its recent projects (the
// latest first, when each was last changed), the projects folder's,
// templates, an empty project, Open…. Choosing one opens it (what was
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

// The project manager's state.
Start_Page :: struct {
	open: bool,
	off:  bool, // --no-start-page: not at start, nor after New Project (the API still shows it)
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
	// The heading; the way on with what is open.
	im.PushFontFloat(f.bold, 28)
	im.Text("Projects")
	im.PopFont()
	im.TextDisabled("Pick up a recent project, start from a template, or go on with the empty one.")
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
		if im.Button(ui.ICON_FILE_PLUS + "  Empty Project", {side - 8, 44}) do a.start.open = false
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
		seen := make(map[string]bool, context.temp_allocator)
		if ps.recent == 0 do im.TextDisabled("No recent projects yet")
		for k in 0 ..< ps.recent {
			dir, _ := pa.project_recent(&a.api, k)
			seen[same_dir(dir)] = true
			start_row(a, dir, dir == lit, fmt.tprintf("start recent %d", k))
		}
		im.Dummy({0, 10})
		im.SeparatorText("In the projects folder")
		n := 0
		for it in lib_items_of(a, {kind = .Projects}) do if !seen[same_dir(it.path)] {
			start_row(a, it.path, it.path == lit, fmt.tprintf("start project %s", it.name))
			n += 1
		}
		if n == 0 do im.TextDisabled("Nothing more there")
	}
	im.EndChild()
	_ = t
}

// A project's row: its name, its folder, when it last changed. A click
// opens it.
@(private = "file")
start_row :: proc(a: ^App, dir: string, lit: bool, probe: string) {
	t := ui.theme()
	name := strings.trim_suffix(filepath.base(dir), ".pads")
	there := os.exists(dir)
	when_ := ""
	if fi, err := os.stat(dir, context.temp_allocator); err == nil do when_ = ago(fi.modification_time)
	x, y := im.GetCursorScreenPos().x, im.GetCursorScreenPos().y
	w := im.GetContentRegionAvail().x
	if !there do im.BeginDisabled()
	if im.Selectable(fmt.ctprintf("##%s", dir), lit, {}, {0, 40}) do leave(a, .Open, dir)
	ui.name(probe)
	if !there do im.EndDisabled()
	dl := im.GetWindowDrawList()
	im.DrawList_AddText(dl, {x + 8, y + 3}, ui.col(t.text if there else t.text_dim), fmt.ctprintf("%s", name))
	ui.text_push(.Caption)
	im.DrawList_AddText(dl, {x + 8, y + 21}, ui.col(t.text_dim), fmt.ctprintf("%s", filepath.dir(dir) if there else "Not found"))
	if when_ != "" {
		c := fmt.ctprintf("%s", when_)
		im.DrawList_AddText(dl, {x + w - im.CalcTextSize(c).x - 8, y + 12}, ui.col(t.text_dim), c)
	}
	ui.text_pop()
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
