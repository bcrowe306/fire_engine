package pads

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "app:ui"
import pa "api"
import im "deps:imgui"

// The project page on a controller's display (View_Kind.Projects: Push 2's
// Shift + Setup, and at start while the window shows it): the project open
// and whether it is saved; Recent, All or Templates on the upper row; their
// list (encoder 1); on the lower row Open (a template: New), New Empty,
// Save, Save As, Rename, Duplicate, Trash; Close on the upper row's last.
// Save As, Rename, Duplicate and Trash are the window's dialogs, which the
// display shows (its name editor types).

@(private) CTL_PROJECT_TABS := [3]string{"Recent", "All", "Templates"}
@(private) CTL_PROJECT_ROWS :: 5

// One row of the controller's project list: a project's folder (or a
// template's name) and how it reads.
@(private)
Ctl_Project_Row :: struct {
	dir:  string, // "" for a template
	name: string,
}

// The rows of the controller's project tab `tab`.
@(private)
ctl_project_rows :: proc(a: ^App, tab: int) -> []Ctl_Project_Row {
	out := make([dynamic]Ctl_Project_Row, context.temp_allocator)
	ps, _ := pa.project_state(&a.api)
	switch tab {
	case 0:
		for k in 0 ..< ps.recent {
			dir, _ := pa.project_recent(&a.api, k)
			append(&out, Ctl_Project_Row{dir = dir, name = strings.trim_suffix(filepath.base(dir), ".pads")})
		}
	case 1:
		for it in lib_items_of(a, {kind = .Projects}) do append(&out, Ctl_Project_Row{dir = it.path, name = it.name})
	case 2:
		for k in 0 ..< ps.templates {
			n, _ := pa.project_template_name(&a.api, k)
			append(&out, Ctl_Project_Row{name = n})
		}
	}
	return out[:]
}

ctl_projects :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	st := &a.start
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	inp := ctx.input
	pressed :: proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp != nil && inp.pressed[int(b)] }
	ui.text_push(.Label)
	defer ui.text_pop()
	// The tabs, and Close.
	for n, k in CTL_PROJECT_TABS {
		ctl_upper(ctx, k, n, st.ctl_tab == k)
		if pressed(inp, pa.View_Button(int(pa.View_Button.Upper_1) + k)) && st.ctl_tab != k do st.ctl_tab, st.ctl_sel = k, 0
	}
	ctl_upper(ctx, 7, ui.ICON_X + "  Close", false)
	if pressed(inp, .Upper_8) do st.open = false
	rows := ctl_project_rows(a, st.ctl_tab)
	if d := ctl_list_steps(0); d != 0 do st.ctl_sel += d
	if pressed(inp, .Up) do st.ctl_sel -= 1 // (▲ ▼: the rows)
	if pressed(inp, .Down) do st.ctl_sel += 1
	ctx.buttons |= 1 << uint(pa.View_Button.Up) | 1 << uint(pa.View_Button.Down)
	st.ctl_sel = clamp(st.ctl_sel, 0, max(len(rows) - 1, 0))
	top := o.y + CTL_PLOT_Y
	bottom := o.y + full.y - CTL_BUTTONS_H - 2
	// The project open, across the top.
	ps, _ := pa.project_state(&a.api)
	state := "not saved yet" if ps.untitled else ("unsaved changes" if ps.dirty else "saved")
	im.DrawList_AddText(dl, {o.x + 8, top}, ui.col(t.text), fmt.ctprintf("Open: %s", project_name(a)))
	im.DrawList_AddText(dl, {o.x + 8, top + im.GetTextLineHeight() + 2}, ui.col(t.text_dim), fmt.ctprintf("%s", state))
	// The list.
	x0, x1 := o.x + f32(2 * CTL_COL) + 3, o.x + full.x - 3
	rh := (bottom - top) / CTL_PROJECT_ROWS
	im.DrawList_AddRectFilled(dl, {x0, top}, {x1, bottom}, ui.col(ui.PLOT_BG), t.radius)
	first := clamp(st.ctl_sel - CTL_PROJECT_ROWS / 2, 0, max(len(rows) - CTL_PROJECT_ROWS, 0))
	for k in first ..< min(first + CTL_PROJECT_ROWS, len(rows)) {
		y := top + f32(k - first) * rh
		if k == st.ctl_sel do im.DrawList_AddRectFilled(dl, {x0 + 2, y + 1}, {x1 - 2, y + rh - 1}, ui.col(ui.with_alpha(t.accent, 0.45)), 4)
		icon := ui.ICON_FILE_PLUS if rows[k].dir == "" else ui.ICON_FOLDER
		im.DrawList_AddText(dl, {x0 + 8, y + (rh - im.GetTextLineHeight()) / 2}, ui.col(t.text), fmt.ctprintf("%s  %s", icon, rows[k].name))
	}
	if len(rows) == 0 {
		why: cstring = "No recent projects yet" if st.ctl_tab == 0 else ("No projects yet" if st.ctl_tab == 1 else "No templates yet")
		ts := im.CalcTextSize(why)
		im.DrawList_AddText(dl, {(x0 + x1 - ts.x) / 2, top + (bottom - top - ts.y) / 2}, ui.col(t.text_dim), why)
	}
	// The lower row.
	sel: Ctl_Project_Row
	has := len(rows) > 0
	if has do sel = rows[st.ctl_sel]
	project := has && sel.dir != ""
	button :: proc(ctx: ^View_Ctx, k: int, label: cstring, ok: bool, full: im.Vec2) -> bool {
		p, _ := ctl_button(ctx, k, label, false, full)
		if !ok do ctx.buttons &~= 1 << uint(k)
		return p && ok
	}
	if button(ctx, 0, "New" if has && !project else "Open", has, full) {
		if project do leave(a, .Open, sel.dir)
		else do leave(a, .New_From, sel.name)
	}
	if button(ctx, 1, "New Empty", true, full) do leave(a, .New_Empty)
	if button(ctx, 2, ui.ICON_SAVE + "  Save", true, full) do save_project(a)
	if button(ctx, 3, "Save As", true, full) {
		a.lib.save_as_name = {}
		copy(a.lib.save_as_name[:len(a.lib.save_as_name) - 1], project_name(a))
		a.lib.save_as_open = true
	}
	if button(ctx, 4, "Rename", true, full) do a.proj.rename_open = true
	if button(ctx, 5, "Duplicate", project, full) do start_duplicate(a, sel.dir)
	if button(ctx, 6, ui.ICON_TRASH_2 + "  Trash", project, full) do start_trash(a, sel.dir)
}
