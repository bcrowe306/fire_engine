package ui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode"

import im "deps:imgui"

// --- actions -------------------------------------------------------------------------------

// The command key: Cmd on macOS, Ctrl elsewhere (ImGui swaps them on macOS).
MOD_CMD :: im.KEY_MOD_CTRL
// Shift, for chords.
MOD_SHIFT :: im.KEY_MOD_SHIFT
// Alt (Option), for chords.
MOD_ALT :: im.KEY_MOD_ALT

// Something the user can do, by menu, shortcut or command palette: "Undo",
// "Save", "Play". `chord` is a key plus modifiers (`MOD_CMD | i32(im.Key.Z)`;
// 0 = none).
Action :: struct {
	id:      string, // stable, for `run_action` and drive scripts
	label:   string, // as menus show it
	icon:    string, // an ICON_ constant, or ""
	chord:   im.KeyChord,
	run:     proc(user: rawptr),
	user:    rawptr,
	enabled: proc(user: rawptr) -> bool, // nil = always
	checked: proc(user: rawptr) -> bool, // nil = not a toggle
}

// The app's actions. Call `handle_shortcuts` once per frame.
Actions :: struct {
	list: [dynamic]Action,
}

// Adds an action.
action_add :: proc(a: ^Actions, action: Action) {
	append(&a.list, action)
}

// The action with `id`, or nil.
action_find :: proc(a: ^Actions, id: string) -> ^Action {
	for &x in a.list do if x.id == id do return &x
	return nil
}

// Whether the action can run now.
action_enabled :: proc(x: ^Action) -> bool {
	return x.enabled == nil || x.enabled(x.user)
}

// Runs the action `id` if it exists and is enabled; true if it ran.
run_action :: proc(a: ^Actions, id: string) -> bool {
	x := action_find(a, id)
	if x == nil || !action_enabled(x) do return false
	x.run(x.user)
	return true
}

// Runs every action whose shortcut was pressed this frame (unless a text
// field has the keyboard).
handle_shortcuts :: proc(a: ^Actions) {
	if im.GetIO().WantTextInput do return
	for &x in a.list {
		if x.chord != 0 && im.Shortcut(x.chord, {.RouteGlobal}) && action_enabled(&x) do x.run(x.user)
	}
}

// A menu item for the action `id`, with its icon, shortcut and check mark.
menu_action :: proc(a: ^Actions, id: string) {
	x := action_find(a, id)
	if x == nil do return
	label := strings.clone_to_cstring(x.label if x.icon == "" else strings.concatenate({x.icon, "  ", x.label}, context.temp_allocator), context.temp_allocator)
	short := strings.clone_to_cstring(chord_text(x.chord), context.temp_allocator)
	checked := x.checked != nil && x.checked(x.user)
	if im.MenuItem(label, short, checked, action_enabled(x)) do x.run(x.user)
}

// "⌘⇧Z" on macOS, "Ctrl+Shift+Z" elsewhere.
chord_text :: proc(chord: im.KeyChord) -> string {
	if chord == 0 do return ""
	b := strings.builder_make(context.temp_allocator)
	when ODIN_OS == .Darwin {
		// Open Sans has no ⌘⌥⇧: Lucide draws them.
		if chord & MOD_CMD != 0 do strings.write_string(&b, ICON_COMMAND)
		if chord & MOD_ALT != 0 do strings.write_string(&b, ICON_OPTION)
		if chord & MOD_SHIFT != 0 do strings.write_string(&b, ICON_ARROW_BIG_UP)
	} else {
		if chord & MOD_CMD != 0 do strings.write_string(&b, "Ctrl+")
		if chord & MOD_ALT != 0 do strings.write_string(&b, "Alt+")
		if chord & MOD_SHIFT != 0 do strings.write_string(&b, "Shift+")
	}
	key := im.Key(chord & ~i32(im.KEY_MOD_MASK))
	strings.write_string(&b, string(im.GetKeyName(key)))
	return strings.to_string(b)
}

// --- command palette -------------------------------------------------------------------------

// A searchable list of every action (Cmd/Ctrl+K): type to filter, arrows
// to choose, Enter to run, Escape to close.
Palette :: struct {
	open:     bool,
	focus:    bool,
	query:    [128]u8,
	selected: int,
}

// Opens the palette (bind it to an action with MOD_CMD | Key.K).
palette_open :: proc(p: ^Palette) {
	p.open, p.focus, p.selected = true, true, 0
	p.query = {}
}

// Draws the palette if it is open, and runs what the user picks (after the
// palette's own style is popped, so an action may change the theme).
palette_draw :: proc(p: ^Palette, a: ^Actions) {
	if !p.open do return
	run := palette_window(p, a)
	if run != nil && action_enabled(run) {
		p.open = false
		run.run(run.user)
	}
}

@(private)
palette_window :: proc(p: ^Palette, a: ^Actions) -> (run: ^Action) {
	t := current
	vp := im.GetMainViewport()
	w: f32 = min(560, vp.WorkSize.x - 40)
	im.SetNextWindowPos({vp.WorkPos.x + (vp.WorkSize.x - w) / 2, vp.WorkPos.y + 80})
	im.SetNextWindowSize({w, 0})
	// Raised above the panels, with a hairline, so it reads as floating.
	im.PushStyleVarVec2(.WindowPadding, {10, 10})
	im.PushStyleVar(.WindowRounding, t.radius_big)
	im.PushStyleVar(.WindowBorderSize, 1)
	im.PushStyleColorVec4(.WindowBg, transmute(im.Vec4)mix(t.surface, t.raised, 0.6))
	im.PushStyleColorVec4(.Border, transmute(im.Vec4)t.hover)
	defer im.PopStyleColor(2)
	defer im.PopStyleVar(3)
	if !im.Begin("##palette", &p.open, {.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings, .NoDocking, .AlwaysAutoResize}) {
		im.End()
		return nil
	}
	defer im.End()
	if p.focus {
		im.SetKeyboardFocusHere()
		p.focus = false
	}
	im.SetNextItemWidth(-1)
	im.InputTextWithHint("##query", ICON_SEARCH + "  Type a command", cstring(&p.query[0]), len(p.query))
	query := string(cstring(&p.query[0]))
	matches := make([dynamic]^Action, context.temp_allocator)
	for &x in a.list do if fuzzy_match(query, x.label) do append(&matches, &x)
	if im.IsKeyPressed(.DownArrow) do p.selected = min(p.selected + 1, len(matches) - 1)
	if im.IsKeyPressed(.UpArrow) do p.selected = max(p.selected - 1, 0)
	p.selected = clamp(p.selected, 0, max(len(matches) - 1, 0))
	if im.IsKeyPressed(.Enter) && len(matches) > 0 do run = matches[p.selected]
	if im.IsKeyPressed(.Escape) do p.open = false
	im.Spacing()
	for x, i in matches {
		if i >= 12 do break
		label := strings.clone_to_cstring(fmt.tprintf("%s  %s", x.icon if x.icon != "" else " ", x.label), context.temp_allocator)
		im.PushIDInt(i32(i))
		enabled := action_enabled(x)
		if !enabled do im.BeginDisabled()
		if im.Selectable(label, i == p.selected, {}, {w - 20, 0}) do run = x
		if !enabled do im.EndDisabled()
		if x.chord != 0 {
			s := strings.clone_to_cstring(chord_text(x.chord), context.temp_allocator)
			sw := im.CalcTextSize(s).x
			im.SameLine(w - 20 - sw)
			im.TextDisabled("%s", s)
		}
		im.PopID()
	}
	if len(matches) == 0 do im.TextDisabled("No command matches")
	return
}

// Whether every character of `query` appears in `label` in order, ignoring
// case ("svas" matches "Save As").
fuzzy_match :: proc(query, label: string) -> bool {
	q := query
	for r in label {
		if len(q) == 0 do break
		qr, n := rune(q[0]), 1
		if qr >= 0x80 do qr, n = utf8_first(q)
		if unicode.to_lower(r) == unicode.to_lower(qr) do q = q[n:]
	}
	return len(q) == 0
}

@(private)
utf8_first :: proc(s: string) -> (rune, int) {
	for r, i in s {
		_ = i
		return r, len(string_of_rune(r))
	}
	return 0, 1
}

@(private)
string_of_rune :: proc(r: rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_rune(&b, r)
	return strings.to_string(b)
}

// --- toasts ----------------------------------------------------------------------------------

// How a toast looks.
Toast_Kind :: enum u8 {
	Info,
	Success,
	Warning,
	Error,
}

// Short notices in the bottom right corner that fade after a few seconds.
Toasts :: struct {
	items: [dynamic]Toast,
	log:   [dynamic]Log_Entry, // every toast's message, the newest last (the last `LOG_KEEP`)
	log_path: string, // a file every message is appended to as well ("" none: see `log_open`)
}

// A message as the log keeps it.
Log_Entry :: struct {
	kind: Toast_Kind,
	text: string, // allocated
	at:   time.Time,
}

// Messages a log keeps.
LOG_KEEP :: 200

@(private)
Toast :: struct {
	kind:  Toast_Kind,
	text:  string, // allocated
	age:   f32,    // seconds shown
	life:  f32,
}

// Shows `text` for `seconds`.
// The messages showing now, oldest first, and their kinds (temporary
// allocator; for a test harness).
toast_texts :: proc(ts: ^Toasts) -> (texts: []string, kinds: []Toast_Kind) {
	t := make([]string, len(ts.items), context.temp_allocator)
	k := make([]Toast_Kind, len(ts.items), context.temp_allocator)
	for x, i in ts.items do t[i], k[i] = x.text, x.kind
	return t, k
}

toast :: proc(ts: ^Toasts, kind: Toast_Kind, text: string, seconds: f32 = 3.5) {
	append(&ts.items, Toast{kind = kind, text = strings.clone(text), life = seconds})
	log_add(ts, kind, text)
}

// Adds a message to the log without showing it (a status bar shows the
// newest).
log_add :: proc(ts: ^Toasts, kind: Toast_Kind, text: string) {
	if len(ts.log) >= LOG_KEEP {
		delete(ts.log[0].text)
		ordered_remove(&ts.log, 0)
	}
	append(&ts.log, Log_Entry{kind, strings.clone(text), time.now()})
	if ts.log_path != "" {
		kinds := [Toast_Kind]string{.Info = "info", .Success = "ok", .Warning = "warning", .Error = "error"}
		line := fmt.tprintf("%v %s %s\n", time.now(), kinds[kind], text)
		if f, err := os.open(ts.log_path, {.Write, .Create, .Append}, {.Read_User, .Write_User}); err == nil {
			_, _ = os.write_string(f, line)
			os.close(f)
		}
	}
}

// Writes every message to the file at `path` as well (owned by the
// caller), the one before it kept as `path.1` once it passes 1 MB.
log_open :: proc(ts: ^Toasts, path: string) {
	ts.log_path = path
	if fi, err := os.stat(path, context.temp_allocator); err == nil && fi.size > 1 << 20 {
		old := strings.concatenate({path, ".1"}, context.temp_allocator)
		os.remove(old)
		os.rename(path, old)
	}
}

// Frees every toast.
toasts_destroy :: proc(ts: ^Toasts) {
	for x in ts.items do delete(x.text)
	delete(ts.items)
	for x in ts.log do delete(x.text)
	delete(ts.log)
}

// Draws the toasts and ages them by this frame's time.
toasts_draw :: proc(ts: ^Toasts) {
	t := current
	vp := im.GetMainViewport()
	dt := im.GetIO().DeltaTime
	y := vp.WorkPos.y + vp.WorkSize.y - 16
	#reverse for &x, i in ts.items {
		x.age += dt
		if x.age > x.life {
			delete(x.text)
			ordered_remove(&ts.items, i)
			continue
		}
		alpha := clamp(min(x.age / 0.15, (x.life - x.age) / 0.4), 0, 1)
		icon := ICON_INFO
		color := t.accent
		switch x.kind {
		case .Info:
		case .Success: icon, color = ICON_CIRCLE_CHECK, t.ok
		case .Warning: icon, color = ICON_TRIANGLE_ALERT, t.warn
		case .Error:   icon, color = ICON_CIRCLE_X, t.danger
		}
		text := strings.clone_to_cstring(x.text, context.temp_allocator)
		ic := strings.clone_to_cstring(icon, context.temp_allocator)
		ts_ := im.CalcTextSize(text)
		w := ts_.x + 56
		h := ts_.y + 22
		pos := im.Vec2{vp.WorkPos.x + vp.WorkSize.x - w - 16, y - h}
		dl := im.GetForegroundDrawList()
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, col(with_alpha(t.surface, alpha)), t.radius_big)
		im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, col(with_alpha(t.border, alpha)), t.radius_big)
		im.DrawList_AddText(dl, {pos.x + 14, pos.y + 11}, col(with_alpha(color, alpha)), ic)
		im.DrawList_AddText(dl, {pos.x + 40, pos.y + 11}, col(with_alpha(t.text, alpha)), text)
		y = pos.y - 8
	}
}

// --- workspace -------------------------------------------------------------------------------

// A dockable window of the app: the pad grid, the mixer, the browser.
Panel :: struct {
	id:    cstring, // stable, unique: ImGui keeps the layout by it
	title: string,  // shown on the tab
	icon:  string,
	open:  bool,
	draw:  proc(user: rawptr),
	user:  rawptr,
	flags: im.WindowFlags,
	focus: int, // frames left to bring it to the front (its tab, when docked): docking settles over the first frames
	no_tab: bool, // docked, it shows no tab of its own (it draws its own tabs; it stays where the layout puts it)
}

// Where a panel goes in the default layout.
Dock :: enum u8 {
	Center,
	Left,
	Right,
	Bottom,
}

// The app's window: an optional menu bar, a full-window dockspace holding
// the panels, the palette and the toasts. The first time (no saved layout)
// panels are docked where `layout` says.
Workspace :: struct {
	panels:  [dynamic]Panel,
	layout:  map[cstring]Dock,
	sizes:   [Dock]f32, // fraction of the window for each side (defaults set by workspace_init)
	palette: Palette,
	toasts:  Toasts,
	dock_id: im.ID,
	built:   bool,
	// Set when the app's layout file existed at startup: then ImGui restores
	// the user's layout and the default one is not built.
	has_saved_layout: bool,
	titles:  map[cstring]cstring, // "Title###id"
	// A bar under the menus, above the panels, the whole window wide (a
	// transport): drawn by `toolbar(toolbar_user)`, `toolbar_h` tall.
	toolbar:      proc(user: rawptr),
	toolbar_user: rawptr,
	toolbar_h:    f32,
	// A bar along the bottom of the window (a status bar): drawn by
	// `statusbar(toolbar_user)`, `statusbar_h` tall.
	statusbar:    proc(user: rawptr),
	statusbar_h:  f32,
}

// Prepares a workspace.
workspace_init :: proc(w: ^Workspace) {
	w.panels = make([dynamic]Panel)
	w.layout = make(map[cstring]Dock)
	w.titles = make(map[cstring]cstring)
	w.sizes = {.Center = 0, .Left = 0.22, .Right = 0.24, .Bottom = 0.4}
}

// Frees the workspace.
workspace_destroy :: proc(w: ^Workspace) {
	for _, t in w.titles do delete(t)
	delete(w.titles)
	delete(w.panels)
	delete(w.layout)
	toasts_destroy(&w.toasts)
}

// Adds a panel, docked at `where` in the default layout.
panel_add :: proc(w: ^Workspace, p: Panel, where_: Dock = .Center) {
	append(&w.panels, p)
	w.layout[p.id] = where_
	label := p.title if p.icon == "" else strings.concatenate({p.icon, "  ", p.title}, context.temp_allocator)
	w.titles[p.id] = strings.clone_to_cstring(fmt.tprintf("%s###%s", label, p.id))
}

// The panel `id`, or nil.
panel_find :: proc(w: ^Workspace, id: cstring) -> ^Panel {
	for &p in w.panels do if p.id == id do return &p
	return nil
}

// Opens panel `id` and brings it to the front (its tab, if docked with
// others). False if there is no such panel.
panel_focus :: proc(w: ^Workspace, id: cstring) -> bool {
	p := panel_find(w, id)
	if p == nil do return false
	p.open, p.focus = true, 3
	return true
}

// Draws the workspace: `menu` (may be nil) in the main menu bar, the
// dockspace, every open panel, the palette and the toasts.
workspace_draw :: proc(w: ^Workspace, actions: ^Actions, menu: proc(user: rawptr) = nil, menu_user: rawptr = nil) {
	if menu != nil && im.BeginMainMenuBar() {
		menu(menu_user)
		im.EndMainMenuBar()
	}
	if w.toolbar != nil {
		flags := im.WindowFlags{.NoScrollbar, .NoSavedSettings, .NoTitleBar, .NoResize, .NoMove, .NoScrollWithMouse, .NoDocking}
		if im.BeginViewportSideBar("##toolbar", im.GetMainViewport(), .Up, w.toolbar_h, flags) do w.toolbar(w.toolbar_user)
		im.End()
	}
	if w.statusbar != nil {
		flags := im.WindowFlags{.NoScrollbar, .NoSavedSettings, .NoTitleBar, .NoResize, .NoMove, .NoScrollWithMouse, .NoDocking}
		if im.BeginViewportSideBar("##statusbar", im.GetMainViewport(), .Down, w.statusbar_h, flags) do w.statusbar(w.toolbar_user)
		im.End()
	}
	w.dock_id = im.DockSpaceOverViewport(0, im.GetMainViewport(), {.PassthruCentralNode})
	if !w.built {
		w.built = true
		if !w.has_saved_layout do build_layout(w)
	}
	for &p in w.panels {
		if !p.open do continue
		if p.focus > 0 {
			im.SetNextWindowFocus()
			p.focus -= 1
		}
		if p.no_tab {
			wc := im.WindowClass{ParentViewportId = ~im.ID(0), DockNodeFlagsOverrideSet = DOCK_NODE_NO_TAB_BAR, DockingAllowUnclassed = true}
			im.SetNextWindowClass(&wc)
		}
		// The panels in the middle sit a shade darker than the rest: the main
		// content, set apart.
		// (Filled here: a docked window's background is its dock host's.)
		if im.Begin(w.titles[p.id], &p.open, p.flags) {
			if w.layout[p.id] == .Center {
				at, size := im.GetWindowPos(), im.GetWindowSize()
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), at, {at.x + size.x, at.y + size.y}, col(current.inset))
			}
			p.draw(p.user)
		}
		im.End()
	}
	if actions != nil do palette_draw(&w.palette, actions)
	toasts_draw(&w.toasts)
}

// ImGuiDockNodeFlags_NoTabBar, an internal flag (bit 12): a node with no tab bar.
@(private) DOCK_NODE_NO_TAB_BAR :: transmute(im.DockNodeFlags)i32(1 << 12)

// ImGuiDockNodeFlags_DockSpace, an internal flag (bit 10).
@(private) DOCK_NODE_DOCKSPACE :: transmute(im.DockNodeFlags)i32(1 << 10)

// Splits the dockspace into the sides the panels ask for and docks them.
@(private)
build_layout :: proc(w: ^Workspace) {
	vp := im.GetMainViewport()
	id := w.dock_id
	im.DockBuilderRemoveNode(id)
	im.DockBuilderAddNode(id, DOCK_NODE_DOCKSPACE)
	im.DockBuilderSetNodeSize(id, vp.WorkSize)
	used: [Dock]bool
	for _, d in w.layout do used[d] = true
	center := id
	nodes: [Dock]im.ID
	if used[.Left] do nodes[.Left] = im.DockBuilderSplitNode(center, .Left, w.sizes[.Left], nil, &center)
	if used[.Right] do nodes[.Right] = im.DockBuilderSplitNode(center, .Right, w.sizes[.Right] / (1 - w.sizes[.Left] if used[.Left] else 1), nil, &center)
	if used[.Bottom] do nodes[.Bottom] = im.DockBuilderSplitNode(center, .Down, w.sizes[.Bottom], nil, &center)
	nodes[.Center] = center
	for p in w.panels do im.DockBuilderDockWindow(w.titles[p.id], nodes[w.layout[p.id]])
	im.DockBuilderFinish(id)
}

// Resets the panels to the default layout (an action for the View menu).
workspace_reset_layout :: proc(w: ^Workspace) {
	for &p in w.panels do p.open = true
	build_layout(w)
}
