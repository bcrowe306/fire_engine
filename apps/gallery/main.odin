/*
A gallery of app:ui: every widget and editor, docked panels, a menu bar,
actions with shortcuts, the command palette and toasts, in both themes.
Edits go through app:core's history, so everything here undoes (Cmd/Ctrl+Z).
The page to review the look on, by eye or by screenshot.

	task app:gallery
	.build/app/gallery --drive tests/app_ui/drive/gallery.txt --out .build/app/gallery_shots --headless
*/
package gallery

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import app "app:core"
import "app:ui"
import im "deps:imgui"

// The model the gallery edits: plain values, changed only by commands.
Model :: struct {
	volume, pan, cutoff: f32,
	main, bus_a:         f32,
	x, y:                f32,
	on:                  bool,
	mode:                int,
	cells:               [4 * 16]bool,
	notes:               [dynamic]ui.Roll_Note,
	points:              [dynamic]ui.Lane_Point,
	start, end:          i64,
}

State :: struct {
	p:        ui.Platform,
	d:        ui.Driver,
	dark:     bool,
	m:        Model,
	history:  app.History,
	actions:  ui.Actions,
	ws:       ui.Workspace,
	frame:    int,
	selected: int,
	peaks:    []ui.Peak,
	view:     ui.Wave_View,
	roll:     ui.Roll_View,
	sel:      [2]i64,
}

// Fields of the model, for `app.Key`s.
F_VOLUME, F_PAN, F_CUTOFF, F_MAIN, F_BUS :: 1, 2, 3, 4, 5

set_f32 :: proc(ctx: rawptr, key: app.Key, v: f32) {
	m := (^Model)(ctx)
	switch key.field {
	case F_VOLUME: m.volume = v
	case F_PAN:    m.pan = v
	case F_CUTOFF: m.cutoff = v
	case F_MAIN:   m.main = v
	case F_BUS:    m.bus_a = v
	}
}

set_cells :: proc(ctx: rawptr, key: app.Key, v: [4 * 16]bool) {
	(^Model)(ctx).cells = v
}

set_markers :: proc(ctx: rawptr, key: app.Key, v: [2]i64) {
	m := (^Model)(ctx)
	m.start, m.end = v[0], v[1]
}

main :: proc() {
	drive, out, headless, profile := "", ".build/app/gallery_shots", false, 0
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--drive":    if i + 1 < len(os.args) { i += 1; drive = os.args[i] }
		case "--out":      if i + 1 < len(os.args) { i += 1; out = os.args[i] }
		case "--headless": headless = true
		case "--profile":  if i + 1 < len(os.args) { i += 1; profile = strconv.parse_int(os.args[i]) or_else 300 }
		}
	}
	s := new(State)
	s.dark = true
	s.m = {volume = 0.8, cutoff = 0.6, main = 0.8, bus_a = 0.6, x = 0.3, y = 0.6, on = true, end = 40_000}
	for i in 0 ..< 16 do s.m.cells[i] = i % 4 == 0
	for i in 0 ..< 16 do s.m.cells[16 + i] = i % 8 == 4
	for i in 0 ..< 16 do s.m.cells[32 + i] = i % 2 == 0
	append(&s.m.notes, ui.Roll_Note{start = 0, length = 1, key = 60, velocity = 0.9}, ui.Roll_Note{start = 1, length = 0.5, key = 64, velocity = 0.6}, ui.Roll_Note{start = 2, length = 1.5, key = 67, velocity = 0.8}, ui.Roll_Note{start = 4, length = 2, key = 72, velocity = 0.5})
	append(&s.m.points, ui.Lane_Point{0, 0.2}, ui.Lane_Point{2, 0.8}, ui.Lane_Point{5, 0.4}, ui.Lane_Point{8, 0.9})
	s.selected = 5
	s.roll = {beat0 = 0, beats = 8, key0 = 55, keys = 24}
	// A test tone with an envelope, for the waveform.
	samples := make([]f32, 48_000)
	for &x, i in samples {
		env := math.exp(-f32(i) / 9000)
		x = env * math.sin(f32(i) * 0.05) * (0.6 + 0.4 * math.sin(f32(i) * 0.0007))
	}
	s.peaks = ui.peaks_of(samples, 2048)

	if !ui.platform_init(&s.p, {title = "Gallery", width = 1440, height = 900, headless = headless, vsync = profile == 0}) do os.exit(1)
	defer ui.platform_destroy(&s.p)
	app.history_init(&s.history, &s.m)
	setup_actions(s)
	setup_workspace(s)
	if drive != "" {
		ui.driver_load(&s.d, drive, out)
		s.d.command = proc(user: rawptr, w: []string) -> bool {
			s := (^State)(user)
			switch w[0] {
			case "theme":
				s.dark = len(w) < 2 || w[1] != "light"
				ui.set_theme(&s.p, ui.theme_dark() if s.dark else ui.theme_light())
				return true
			case "action":
				return len(w) > 1 && ui.run_action(&s.actions, w[1])
			}
			return false
		}
		s.d.user = s
		s.p.driver = &s.d
		s.p.fixed_dt = 1.0 / 60
	}
	defer ui.driver_destroy(&s.d)
	if profile > 0 {
		times := make([]f64, profile)
		for i in 0 ..< profile {
			t0 := time.tick_now()
			if !ui.frame_begin(&s.p) do break
			ui.handle_shortcuts(&s.actions)
			ui.workspace_draw(&s.ws, &s.actions, draw_menu, s)
			ui.frame_end(&s.p)
			s.frame += 1
			times[i] = time.duration_milliseconds(time.tick_since(t0))
		}
		rest := times[profile / 10:]
		slice.sort(rest)
		fmt.printfln("%d frames: median %.3f ms, p99 %.3f ms", len(rest), rest[len(rest) / 2], rest[len(rest) * 99 / 100])
		return
	}
	for ui.frame_begin(&s.p) {
		ui.handle_shortcuts(&s.actions)
		ui.workspace_draw(&s.ws, &s.actions, draw_menu, s)
		ui.frame_end(&s.p)
		s.frame += 1
	}
	for shot in s.d.shots do fmt.println("screenshot:", shot)
	fmt.printfln("model: volume %.3f, %d undo steps", s.m.volume, len(s.history.undo))
}

setup_actions :: proc(s: ^State) {
	a := &s.actions
	ui.action_add(a, {id = "undo", label = "Undo", icon = ui.ICON_UNDO_2, chord = ui.MOD_CMD | i32(im.Key.Z), user = s,
		run = proc(u: rawptr) { app.undo(&(^State)(u).history) },
		enabled = proc(u: rawptr) -> bool { return len((^State)(u).history.undo) > 0 }})
	ui.action_add(a, {id = "redo", label = "Redo", icon = ui.ICON_REDO_2, chord = ui.MOD_CMD | ui.MOD_SHIFT | i32(im.Key.Z), user = s,
		run = proc(u: rawptr) { app.redo(&(^State)(u).history) },
		enabled = proc(u: rawptr) -> bool { return len((^State)(u).history.redo) > 0 }})
	ui.action_add(a, {id = "palette", label = "Command Palette", icon = ui.ICON_SEARCH, chord = ui.MOD_CMD | i32(im.Key.K), user = s,
		run = proc(u: rawptr) { ui.palette_open(&(^State)(u).ws.palette) }})
	ui.action_add(a, {id = "theme", label = "Toggle Light Theme", icon = ui.ICON_SUN, user = s,
		run = proc(u: rawptr) {
			s := (^State)(u)
			s.dark = !s.dark
			ui.set_theme(&s.p, ui.theme_dark() if s.dark else ui.theme_light())
		},
		checked = proc(u: rawptr) -> bool { return !(^State)(u).dark }})
	ui.action_add(a, {id = "toast", label = "Show a Notification", icon = ui.ICON_BELL, user = s,
		run = proc(u: rawptr) { ui.toast(&(^State)(u).ws.toasts, .Success, "Saved demo.pads") }})
	ui.action_add(a, {id = "reset_layout", label = "Reset Layout", icon = ui.ICON_LAYOUT_DASHBOARD, user = s,
		run = proc(u: rawptr) { ui.workspace_reset_layout(&(^State)(u).ws) }})
}

draw_menu :: proc(user: rawptr) {
	s := (^State)(user)
	if im.BeginMenu("Edit") {
		ui.menu_action(&s.actions, "undo")
		ui.menu_action(&s.actions, "redo")
		im.Separator()
		ui.menu_action(&s.actions, "palette")
		im.EndMenu()
	}
	if im.BeginMenu("View") {
		ui.menu_action(&s.actions, "theme")
		ui.menu_action(&s.actions, "reset_layout")
		ui.menu_action(&s.actions, "toast")
		im.EndMenu()
	}
}

setup_workspace :: proc(s: ^State) {
	w := &s.ws
	ui.workspace_init(w)
	ui.panel_add(w, {id = "controls", title = "Controls", icon = ui.ICON_SLIDERS_HORIZONTAL, open = true, draw = draw_controls, user = s}, .Center)
	ui.panel_add(w, {id = "editors", title = "Editors", icon = ui.ICON_AUDIO_WAVEFORM, open = true, draw = draw_editors, user = s}, .Bottom)
	ui.panel_add(w, {id = "history", title = "History", icon = ui.ICON_HISTORY, open = true, draw = draw_history, user = s}, .Right)
}

edit :: proc(s: ^State, e: ui.Edit, name: string, field: int, old, new: f32) {
	if e.changed do app.set_value(&s.history, name, {1, field}, old, new, set_f32)
	if e.ended do app.seal(&s.history)
}

draw_controls :: proc(user: rawptr) {
	s := (^State)(user)
	m := &s.m
	f := s.p.fonts
	im.PushFontFloat(f.bold, 22)
	im.Text("Fire Engine UI")
	im.PopFont()
	im.TextDisabled("%s", fmt.ctprintf("Widgets of app:ui, %s theme", "dark" if s.dark else "light"))
	section(f, "Buttons")
	im.Button("Button")
	im.SameLine()
	ui.icon_button(ui.ICON_PLAY, "Play")
	im.SameLine()
	ui.icon_button(ui.ICON_SQUARE, "Stop")
	im.SameLine()
	ui.icon_button(ui.ICON_CIRCLE, "Record", on = true, color = ui.rgb(0xf0555a))
	im.SameLine()
	ui.icon_button(ui.ICON_REPEAT, "Loop", on = m.on)
	im.SameLine(0, 20)
	ui.segmented("mode", {"Grid", "Keys", "Repeat", "Velocity"}, &m.mode)
	im.SameLine(0, 20)
	ui.toggle("Metronome", &m.on)

	section(f, "Knobs, faders, meters, XY")
	v := m.volume
	edit(s, ui.knob("Volume", &v, 0, 1, 0.8), "Set Volume", F_VOLUME, m.volume, v)
	im.SameLine(0, 18)
	p := m.pan
	edit(s, ui.knob("Pan", &p, -1, 1, 0, "%+.2f"), "Set Pan", F_PAN, m.pan, p)
	im.SameLine(0, 18)
	c := m.cutoff
	edit(s, ui.knob("Cutoff", &c, 0, 1, 1), "Set Cutoff", F_CUTOFF, m.cutoff, c)
	im.SameLine(0, 30)
	mf := m.main
	edit(s, ui.fader("Main", &mf, 0, 1, 0.8), "Set Main", F_MAIN, m.main, mf)
	im.SameLine(0, 12)
	bf := m.bus_a
	edit(s, ui.fader("Bus A", &bf, 0, 1, 0.8), "Set Bus A", F_BUS, m.bus_a, bf)
	im.SameLine(0, 12)
	t := f32(s.frame) / 60
	l := 0.5 + 0.45 * math.sin(t * 2)
	ui.meter("m1", l, l * 0.6, 0.95)
	im.SameLine(0, 4)
	ui.meter("m2", l * 0.8, l * 0.5, 0.8)
	im.SameLine(0, 30)
	ui.xy_pad("xy", &m.x, &m.y)

	section(f, "Pads")
	names := [8]string{"Kick", "Snare", "Hat", "Open hat", "Clap", "Perc", "", "Vox"}
	tints := [8]ui.Color{ui.rgb(0xff7a59), ui.rgb(0xffc14d), ui.rgb(0x5ad1a5), ui.rgb(0x5ad1a5), ui.rgb(0x9b8cff), ui.rgb(0x58a6ff), {}, ui.rgb(0xff6fae)}
	for n, i in names {
		if i > 0 do im.SameLine(0, 10)
		im.PushIDInt(i32(i))
		hit := ui.pad("pad", {name = n if n != "" else "Empty", middle = fmt.tprintf("A%d", i + 1) if n != "" else "", tint = tints[i], has_sound = n != "", lit = i == 2 && (s.frame / 20) % 2 == 0, selected = s.selected == i, buttons = n != ""})
		if hit.pressed || hit.selected do s.selected = i
		im.PopID()
	}
}

draw_editors :: proc(user: rawptr) {
	s := (^State)(user)
	m := &s.m
	avail := im.GetContentRegionAvail()
	half := (avail.x - 16) / 2
	markers := []ui.Marker{{frame = m.start, color = ui.rgb(0x3ccf7a), label = "S", drag = true}, {frame = m.end, color = ui.rgb(0xf0555a), label = "E", drag = true}}
	e := ui.waveform("wave", s.peaks, 48_000, &s.view, markers, &s.sel, {half, 120}, ui.rgb(0x5ad1a5))
	if e.moved {
		nv := [2]i64{m.start, m.end}
		nv[e.marker] = e.marker_to
		app.set_value(&s.history, "Move Marker", {2, 1}, [2]i64{m.start, m.end}, nv, set_markers)
	}
	if e.released do app.seal(&s.history)
	im.SameLine(0, 16)
	before := m.cells
	g := ui.step_grid("grid", m.cells[:], 4, 16, {"Kick", "Snare", "Hat", "Clap"}, s.frame / 8 % 16, {20, 24})
	if g.changed {
		after := m.cells
		m.cells = before // the command applies it
		app.set_value(&s.history, "Edit Steps", {3, 1}, before, after, set_cells)
	}
	if g.ended do app.seal(&s.history)
	r := ui.piano_roll("roll", m.notes[:], &s.roll, 0.25, {half, max(avail.y - 140, 120)}, f64(s.frame % 480) / 60)
	if r.add do append(&m.notes, ui.Roll_Note{start = r.at_beat, length = 0.5, key = r.at_key, velocity = 0.8})
	if r.released && r.moving >= 0 do m.notes[r.moving].start, m.notes[r.moving].key = r.to_start, r.to_key
	if r.released && r.resizing >= 0 do m.notes[r.resizing].length = r.to_length
	if r.delete >= 0 do ordered_remove(&m.notes, r.delete)
	im.SameLine(0, 16)
	l := ui.automation_lane("lane", m.points[:], 0, 8, 0.25, {half, max(avail.y - 140, 120)})
	if l.add do append(&m.points, l.at)
	if l.released && l.moving >= 0 do m.points[l.moving] = l.to
	if l.delete >= 0 do ordered_remove(&m.points, l.delete)
}

draw_history :: proc(user: rawptr) {
	s := (^State)(user)
	h := &s.history
	im.TextDisabled("%s", fmt.ctprintf("%d steps, %s", len(h.undo), "unsaved" if app.is_dirty(h) else "saved"))
	im.Separator()
	for step, i in h.undo {
		im.PushIDInt(i32(i))
		im.Selectable(fmt.ctprintf("%s  %s", ui.ICON_CIRCLE_DOT, step.name), i == len(h.undo) - 1)
		im.PopID()
	}
	#reverse for step, i in h.redo {
		im.PushIDInt(i32(1000 + i))
		im.TextDisabled("%s", fmt.ctprintf("%s  %s", ui.ICON_CIRCLE, step.name))
		im.PopID()
	}
}

section :: proc(f: ui.Fonts, title: cstring) {
	im.Spacing()
	im.Spacing()
	im.PushFontFloat(f.semibold, 13)
	im.TextDisabled("%s", title)
	im.PopFont()
	im.Separator()
	im.Spacing()
}
