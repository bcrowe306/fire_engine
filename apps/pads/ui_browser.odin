package pads

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "app:ui"
import pm "model"
import im "deps:imgui"

// What the browser panel keeps besides the model: the search box, a tab
// being renamed, and whether the keyboard moved the selection (to scroll
// it into view).
Browser_View :: struct {
	query:     [128]u8,
	rename:    [64]u8,
	renaming:  int, // the favourite being renamed (-1: none)
	scroll_to: bool,
}

// Height of a row in the browser's list.
@(private) BROWSER_ROW :: 22
// Height of the preview's waveform.
@(private) PREVIEW_H :: 40

// Where the favourites are kept (with the user's preferences).
favorites_path :: proc(a: ^App) -> string {
	return prefs_file(a, "favorites.txt")
}

// The Library panel: one search box, then sections that open and close:
// Favourites (the favourite folders and the project's, as tabs), Folders
// (back, forward, up, favourite and refresh; the path; the folder's rows,
// or the search's results as Files), Instruments, Effects and Plug-ins
// (see `draw_device_sections`); and the preview at its foot. Click a file to select it (and, with auto-play, hear
// it), double-click to load it onto the selected pad, or drag it onto a
// pad. The arrow keys move through the list (Right opens a folder, Left
// closes it), Enter loads or opens (Shift+Enter: into a slicer on the next
// empty pad; Cmd+Shift+Enter: on the selected pad), Backspace goes up.
draw_browser :: proc(user: rawptr) {
	a := (^App)(user)
	b := &a.browser
	v := &a.bview
	pm.browser_set_project(b, a.m.project.dir)

	// One search for the whole library: files (under the folder shown) and
	// devices.
	im.SetNextItemWidth(-1)
	if im.InputTextWithHint("##search", fmt.ctprintf("%s  Search sounds and devices", ui.ICON_SEARCH), cstring(&v.query[0]), len(v.query)) {
		pm.browser_search(b, string(cstring(&v.query[0])))
	}
	searching := b.search.query != ""
	find := strings.to_lower(b.search.query, context.temp_allocator)

	// The sections (the preview below them).
	list_h := im.GetContentRegionAvail().y - (PREVIEW_H + im.GetFrameHeight() + 3 * im.GetStyle().ItemSpacing.y + 6)
	// No ImGui keyboard navigation in the list: its keys are the browser's
	// own (Enter would otherwise also press the row last clicked).
	if im.BeginChild("##list", {0, max(list_h, 80)}, {}, {.NoNavInputs}) {
		if library_section("Favourites") do draw_favorite_tabs(a)
		rows := pm.search_results(&b.search) if searching else pm.browser_rows(b)
		if library_section("Files" if searching else "Folders") {
			if !searching do draw_folder_bar(a)
			draw_rows(a, rows)
			if len(rows) == 0 {
				if searching {
					im.TextDisabled("%s", cstring("Searching…") if !pm.search_done(&b.search) else cstring("Nothing found"))
				} else if b.root == "" {
					im.TextDisabled("Save the project to give it a folder")
				} else {
					im.TextDisabled("No audio files or folders here")
				}
			}
			if searching && pm.search_done(&b.search) && len(rows) >= pm.SEARCH_MAX_RESULTS do im.TextDisabled("(the first %d)", i32(pm.SEARCH_MAX_RESULTS))
		}
		draw_device_sections(a, find)
		if im.IsWindowFocused() {
			browser_keys(a, rows)
			a.browser_has_keys = true // (its arrows are its own)
		}
	}
	im.EndChild()
	draw_preview(a)
}

// A section of the library: a header that opens and closes (open at
// first). True while open.
library_section :: proc(title: string) -> bool {
	open := im.CollapsingHeader(fmt.ctprintf("%s###sec%s", title, title), {.DefaultOpen})
	ui.name(fmt.tprintf("section %s", title))
	return open
}

// Above the folder's rows: back, forward, up, favourite and refresh, then
// the path.
@(private)
draw_folder_bar :: proc(a: ^App) {
	b := &a.browser
	t := ui.theme()
	if ui.icon_button(ui.ICON_ARROW_LEFT, "Back", disabled = len(b.back) == 0) do pm.browser_back(b)
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_ARROW_RIGHT, "Forward", disabled = len(b.forward) == 0) do pm.browser_forward(b)
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_ARROW_UP, "Up a folder (Backspace)", disabled = pm.parent_of(b.root) == "") do pm.browser_up(b)
	im.SameLine(0, 2)
	fav := pm.is_favorite(b, b.root)
	if ui.icon_button(ui.ICON_STAR, "Remove from favourites" if fav else "Add this folder to favourites", on = fav, color = t.warn, disabled = b.root == "") {
		if fav {
			for f, i in b.favorites do if !f.project && f.path == b.root {
				pm.favorite_remove(b, i)
				break
			}
		} else {
			pm.favorite_add(b, b.root)
		}
		pm.favorites_save(b, favorites_path(a))
	}
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_REFRESH_CW, "Read the folders again") do pm.browser_refresh(b)
	draw_crumbs(a)
}

// The favourites, as tabs: click one to show it; right-click to rename,
// move or remove it; "+" adds the folder shown.
@(private)
draw_favorite_tabs :: proc(a: ^App) {
	b := &a.browser
	v := &a.bview
	t := ui.theme()
	// Pills that wrap onto more lines (a tab bar would scroll some out of
	// sight in a narrow sidebar).
	changed := false
	im.PushStyleVarVec2(.FramePadding, {8, 4})
	im.PushStyleVar(.FrameRounding, 12)
	defer im.PopStyleVar(2)
	for f, i in b.favorites {
		icon := ui.ICON_FOLDER_HEART if f.project else ui.ICON_STAR
		label := fmt.ctprintf("%s %s##fav%d", icon, f.name, i)
		if i > 0 do ui.flow(ui.button_width(label), 4)
		on := i == b.tab
		if on {
			im.PushStyleColorVec4(.Button, transmute(im.Vec4)t.accent)
			im.PushStyleColorVec4(.ButtonHovered, transmute(im.Vec4)ui.lighten(t.accent, 0.1))
			im.PushStyleColorVec4(.Text, transmute(im.Vec4)t.accent_text)
		}
		if im.Button(label) && !on do pm.browser_set_tab(b, i)
		if on do im.PopStyleColor(3)
		ui.name(fmt.tprintf("tab %s", f.name)) // for a test: "tab Documents"
		if im.IsItemHovered({.DelayNormal}) do im.SetTooltip("%s", fmt.ctprintf("%s (right-click to rename, move or remove)", favorite_where(b, i)))
		if im.BeginPopupContextItem(fmt.ctprintf("##favmenu%d", i)) {
			if v.renaming != i {
				v.renaming = i
				v.rename = {}
				copy(v.rename[:len(v.rename) - 1], f.name)
			}
			im.SetNextItemWidth(160)
			if im.InputText("##rename", cstring(&v.rename[0]), len(v.rename), {.EnterReturnsTrue}) {
				pm.favorite_rename(b, i, string(cstring(&v.rename[0])))
				changed = true
				im.CloseCurrentPopup()
			}
			if im.MenuItem("Move left", nil, false, i > 0) {
				pm.favorite_move(b, i, i - 1)
				changed = true
			}
			if im.MenuItem("Move right", nil, false, i < len(b.favorites) - 1) {
				pm.favorite_move(b, i, i + 1)
				changed = true
			}
			if im.MenuItem("Remove", nil, false, len(b.favorites) > 1) {
				pm.favorite_remove(b, i)
				changed = true
			}
			im.EndPopup()
		} else if v.renaming == i {
			v.renaming = -1
		}
		if changed do break // the list changed under us
	}
	ui.flow(im.GetFrameHeight(), 4)
	if ui.icon_button(ui.ICON_PLUS, "Add this folder as a favourite", disabled = b.root == "" || pm.is_favorite(b, b.root)) {
		pm.favorite_add(b, b.root)
		changed = true
	}
	if changed do pm.favorites_save(b, favorites_path(a))
	v.scroll_to = false
	im.Spacing()
}

// Where favourite `i` points, for its tooltip.
@(private)
favorite_where :: proc(b: ^pm.Browser, i: int) -> string {
	d := pm.favorite_dir(b, i)
	return d if d != "" else "The project's samples (save the project first)"
}

// The root's path, each part a button (the last ones that fit).
@(private)
draw_crumbs :: proc(a: ^App) {
	b := &a.browser
	t := ui.theme()
	crumbs := pm.browser_crumbs(b)
	avail := im.GetContentRegionAvail().x
	// From the end, as many as fit.
	first := len(crumbs) - 1
	w: f32 = 0
	for i := len(crumbs) - 1; i >= 0; i -= 1 {
		cw := im.CalcTextSize(fmt.ctprintf("%s", crumbs[i].name)).x + 16
		if w + cw > avail && i < len(crumbs) - 1 do break
		w += cw
		first = i
	}
	im.PushStyleVarVec2(.FramePadding, {4, 2})
	im.PushStyleColorVec4(.Button, {0, 0, 0, 0})
	defer im.PopStyleColor()
	defer im.PopStyleVar()
	if first > 0 {
		im.TextDisabled("…")
		im.SameLine(0, 2)
	}
	for i in first ..< len(crumbs) {
		c := crumbs[i]
		last := i == len(crumbs) - 1
		if !last do im.PushStyleColorVec4(.Text, transmute(im.Vec4)t.text_dim)
		if im.SmallButton(fmt.ctprintf("%s##crumb%d", c.name, i)) && !last do pm.browser_go(b, c.path)
		if !last do im.PopStyleColor()
		if !last {
			im.SameLine(0, 0)
			im.TextDisabled("%s", cstring(ui.ICON_CHEVRON_RIGHT))
			im.SameLine(0, 0)
		}
	}
}

// The rows: folders (click to open one in place, its icon showing it open;
// double-click to go into it), files to select, hear and load.
@(private)
draw_rows :: proc(a: ^App, rows: []pm.Browser_Entry) {
	b := &a.browser
	v := &a.bview
	t := ui.theme()
	dl := im.GetWindowDrawList()
	im.PushStyleVarVec2(.ItemSpacing, {0, 0})
	defer im.PopStyleVar()
	// The keyboard moved the selection: bring its row into view (the
	// clipper only draws what shows).
	if v.scroll_to {
		for r, i in rows do if r.path == b.selected {
			y := f32(i) * BROWSER_ROW
			top, h := im.GetScrollY(), im.GetWindowHeight()
			if y < top do im.SetScrollY(y)
			else if y + BROWSER_ROW > top + h do im.SetScrollY(y + BROWSER_ROW - h)
			break
		}
	}
	clipper: im.ListClipper
	im.ListClipper_Begin(&clipper, i32(len(rows)), BROWSER_ROW)
	defer im.ListClipper_End(&clipper)
	go_into, toggle := "", ""
	for im.ListClipper_Step(&clipper) {
		for k in clipper.DisplayStart ..< clipper.DisplayEnd {
			e := rows[k]
			im.PushIDInt(k)
			defer im.PopID()
			pos := im.GetCursorScreenPos()
			w := im.GetContentRegionAvail().x
			selected := e.path == b.selected
			clicked_row := im.InvisibleButton("##row", {w, BROWSER_ROW})
			ui.name(e.name)
			if clicked_row {
				pm.browser_select(b, e.path)
				if e.is_dir do toggle = e.path
				else do preview_selected(a, e, true)
			}
			hovered := im.IsItemHovered()
			if hovered && im.IsMouseDoubleClicked(.Left) {
				if e.is_dir do go_into = e.path
				else do load_selected(a, e)
			}
			if !e.is_dir && im.BeginDragDropSource() {
				im.SetDragDropPayload("PADS_FILE", raw_data(e.path), uint(len(e.path)))
				im.Text("%s", fmt.ctprintf("%s  %s", ui.ICON_FILE_AUDIO, filepath.base(e.path)))
				im.EndDragDropSource()
			}
			if !e.is_dir do item_menu(a, {kind = .File, path = e.path}, "##filemenu")
			if e.is_dir && im.BeginPopupContextItem("##rowmenu") {
				if im.MenuItem("Open") do go_into = e.path
				if im.MenuItem("Add to favourites", nil, false, !pm.is_favorite(b, e.path)) {
					pm.favorite_add(b, e.path)
					pm.favorites_save(b, favorites_path(a))
				}
				im.EndPopup()
			}
			// Drawn: the selection, the indent, a chevron and an icon, the name.
			if selected do im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + BROWSER_ROW}, ui.col(ui.with_alpha(t.accent, 0.35)), 4)
			else if hovered do im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + BROWSER_ROW}, ui.col(t.hover), 4)
			// A folder's icon says whether it is open (no chevron as well).
			x := pos.x + 6 + f32(e.depth) * 16
			ty := pos.y + (BROWSER_ROW - im.GetTextLineHeight()) / 2
			icon := ui.ICON_FOLDER if e.is_dir else ui.ICON_FILE_AUDIO
			if e.is_dir && b.expanded[e.path] do icon = ui.ICON_FOLDER_OPEN
			im.DrawList_AddText(dl, {x, ty}, ui.col(t.warn if e.is_dir else t.accent), fmt.ctprintf("%s", icon))
			x += 22
			// (A search result's name is its path under the tab.)
			im.DrawList_PushClipRect(dl, pos, {pos.x + w - 4, pos.y + BROWSER_ROW}, true)
			im.DrawList_AddText(dl, {x, ty}, ui.col(t.text), fmt.ctprintf("%s", e.name))
			im.DrawList_PopClipRect(dl)
		}
	}
	if go_into != "" {
		pm.browser_go(b, strings.clone(go_into, context.temp_allocator))
	} else if toggle != "" {
		pm.browser_toggle(b, strings.clone(toggle, context.temp_allocator))
	}
	v.scroll_to = false
}

// The keys, while the list has focus.
@(private)
browser_keys :: proc(a: ^App, rows: []pm.Browser_Entry) {
	b := &a.browser
	if im.GetIO().WantTextInput do return
	step :: proc(a: ^App, rows: []pm.Browser_Entry, d: int) {
		e, ok := pm.browser_step(&a.browser, rows, d)
		if !ok do return
		a.bview.scroll_to = true
		if !e.is_dir do preview_selected(a, e, true)
	}
	if im.IsKeyPressed(.DownArrow) do step(a, rows, 1)
	if im.IsKeyPressed(.UpArrow) do step(a, rows, -1)
	current: pm.Browser_Entry
	has := false
	for r in rows do if r.path == b.selected {
		current, has = r, true
		break
	}
	if has && current.is_dir {
		if im.IsKeyPressed(.RightArrow) do pm.browser_expand(b, strings.clone(current.path, context.temp_allocator), true)
		if im.IsKeyPressed(.LeftArrow) do pm.browser_expand(b, strings.clone(current.path, context.temp_allocator), false)
	}
	if im.IsKeyPressed(.Enter) && has {
		io := im.GetIO()
		switch {
		case current.is_dir: pm.browser_go(b, strings.clone(current.path, context.temp_allocator))
		case io.KeyShift && (io.KeySuper || io.KeyCtrl): load_into_slicer(a, a.selected, current.path) // onto the selected pad
		case io.KeyShift: slice_onto_next(a, current.path)
		case: load_selected(a, current)
		}
	}
	if im.IsKeyPressed(.Backspace) do pm.browser_up(b)
}

// A file was selected: preview it (with auto-play, or when asked).
@(private)
preview_selected :: proc(a: ^App, e: pm.Browser_Entry, auto: bool) {
	if e.is_dir || pm.is_midi(e.path) do return // (a MIDI file isn't heard: drag it onto a pad)
	if auto && !a.m.engine.preview.auto_play do return
	pm.preview_play(&a.m.engine, e.path)
}

// Loads file `e` onto the selected pad.
@(private)
load_selected :: proc(a: ^App, e: pm.Browser_Entry) {
	if drop_midi(a, e.path, a.selected) do return // (a MIDI file: its notes on the pad)
	if pm.load_onto_pad(&a.m, a.selected, e.path) == .None {
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Loaded %s onto %s", filepath.base(e.path), pm.pad_label(a.selected)))
	} else {
		ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", filepath.base(e.path)))
	}
}

// The preview: the selected file's waveform with a playhead; play/stop,
// auto-play, tempo sync, and the preview's volume.
@(private)
draw_preview :: proc(a: ^App) {
	b := &a.browser
	e := &a.m.engine
	pv := &e.preview
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := im.GetContentRegionAvail().x
	im.Dummy({w, PREVIEW_H})
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + PREVIEW_H}, ui.col(t.bg), t.radius)
	selected := b.selected != "" && pm.is_audio(b.selected)
	if pv.frames > 0 && pv.path == b.selected {
		mid := pos.y + PREVIEW_H / 2
		half := f32(PREVIEW_H) / 2 - 3
		cols := int(w - 4)
		for x in 0 ..< cols {
			c := pv.wave[x * pm.PREVIEW_WAVE / max(cols, 1)]
			px := pos.x + 2 + f32(x)
			im.DrawList_AddLine(dl, {px, mid - c[1] * half}, {px, mid - c[0] * half + 1}, ui.col(ui.with_alpha(t.accent, 0.8)), 1)
		}
		if p := pm.preview_progress(e); p >= 0 {
			px := pos.x + 2 + f32(p) * (w - 4)
			im.DrawList_AddLine(dl, {px, pos.y + 2}, {px, pos.y + PREVIEW_H - 2}, ui.col(t.text), 1.5)
		}
	} else {
		label: cstring = "Select a sample to hear it" if !selected else "Press play to hear it"
		if pv.loading != nil do label = "Loading…"
		ts := im.CalcTextSize(label)
		im.DrawList_AddText(dl, {pos.x + (w - ts.x) / 2, pos.y + (PREVIEW_H - ts.y) / 2}, ui.col(t.text_dim), label)
	}

	playing := pm.preview_playing(e)
	if ui.icon_button(ui.ICON_SQUARE if playing else ui.ICON_PLAY, "Stop the preview" if playing else "Play the selected sample", on = playing, color = t.ok, disabled = !playing && !selected) {
		if playing do pm.preview_stop(e)
		else do pm.preview_play(e, b.selected)
	}
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_ZAP if pv.auto_play else ui.ICON_ZAP_OFF, "Auto-play: on (selecting a sample plays it)" if pv.auto_play else "Auto-play: off", on = pv.auto_play) {
		pv.auto_play = !pv.auto_play
		if !pv.auto_play do pm.preview_stop(e)
	}
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_METRONOME, "Sync: loops play at the project's tempo while the sequencer plays" if !pv.sync else "Sync: on", on = pv.sync) do pv.sync = !pv.sync
	if pv.beats > 0 && pv.path == b.selected {
		im.SameLine(0, 6)
		im.AlignTextToFramePadding()
		im.TextDisabled("%s", fmt.ctprintf("%d beats", int(pv.beats)))
	}
	im.SameLine(0, 8)
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", cstring(ui.ICON_VOLUME_2))
	im.SameLine(0, 4)
	im.SetNextItemWidth(max(im.GetContentRegionAvail().x, 40))
	vol := pv.volume
	if im.SliderFloat("##pvol", &vol, -48, 6, "%.0f dB") do pv.volume = vol
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) do pv.volume = -6
	if im.IsItemHovered({.DelayNormal}) do im.SetTooltip("The preview's volume (double-click: -6 dB)")
}
