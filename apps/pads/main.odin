/*
Pads: a sampler and sequencer built on Fire Engine's application layer.
Load samples onto 64 pads in 4 banks, play them from the mouse, keyboard or
MIDI, and shape each one: its region, mode, loop, envelope, pitch, EQ and
choke group; chop, stretch and edit the audio.

	task app:run
	task app:drive -- tests/app_ui/drive/pads.txt

Options:
	--project DIR  the project folder (default: a new one in the temporary folder)
	--drive FILE   run the UI from a drive script (see app:ui's Driver)
	--out DIR      where the script's screenshots go (default .build/app/shots)
	--headless     no window on screen (for scripted runs without a display)
	--fake         the simulated audio driver (no sound card needed)
	--profile N    draw N frames as fast as possible and print the CPU time per frame
	               (after the drive script, if one is given: profile a loaded project)
*/
package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:time"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

App :: struct {
	platform: ui.Platform,
	driver:   ui.Driver,
	bus:      app.Bus,
	host:     app.Host,
	m:        pm.Model,
	actions:  ui.Actions,
	ws:       ui.Workspace,
	dark:     bool,
	bank:     int,
	selected: int,
	lit:      [pm.PADS]f32, // seconds a pad stays lit after a hit
	held:     [pm.PADS]bool,
	rec:      pm.Recording,
	wave:     Wave_State,
	browser:  Browser,
	tools:    Tool_State,
	pad_rects: [pm.PADS_PER_BANK][2]im.Vec2, // where this bank's pads were drawn (for drops)
	frame:    int,
}

main :: proc() {
	project, drive, out, headless, fake, profile := "", "", ".build/app/shots", false, false, 0
	for i := 1; i < len(os.args); i += 1 {
		next :: proc(i: ^int) -> string {
			if i^ + 1 < len(os.args) {
				i^ += 1
				return os.args[i^]
			}
			return ""
		}
		switch os.args[i] {
		case "--project":  project = next(&i)
		case "--drive":    drive = next(&i)
		case "--out":      out = next(&i)
		case "--headless": headless = true
		case "--fake":     fake = true
		case "--profile":  profile = strconv.parse_int(next(&i)) or_else 300
		case:
			fmt.eprintln("pads: unknown option", os.args[i])
			os.exit(2)
		}
	}
	if project == "" {
		dir, _ := os.make_directory_temp("", "Untitled.pads", context.allocator)
		project = dir
	}

	a := new(App)
	a.dark = true
	p := &a.platform
	if !ui.platform_init(p, {title = "Pads", width = 1440, height = 900, headless = headless, vsync = profile == 0}) {
		ui.platform_destroy(p)
		os.exit(1)
	}
	defer ui.platform_destroy(p)
	app.bus_init(&a.bus)
	defer app.bus_destroy(&a.bus)
	if !open_engine(a, fake) {
		fmt.eprintln("pads: no audio device; using the simulated one")
		open_engine(a, true)
	}
	defer app.host_destroy(&a.host)
	if pm.model_init(&a.m, &a.host, project, &a.bus) != .None {
		fmt.eprintln("pads: could not start the engine")
		os.exit(1)
	}
	defer pm.model_destroy(&a.m)
	app.subscribe(&a.bus, app.Host_Engine_Changed, proc(user: rawptr, e: ^app.Host_Engine_Changed) {
		pm.engine_rebuild(&(^App)(user).m.engine)
	}, a)
	setup_actions(a)
	subscribe_imports(a)
	setup_workspace(a)
	defer ui.workspace_destroy(&a.ws)
	browser_init(&a.browser)
	defer browser_destroy(&a.browser)

	if drive != "" {
		if !ui.driver_load(&a.driver, drive, out) do os.exit(1)
		a.driver.command = drive_command
		a.driver.user = a
		p.driver = &a.driver
		p.fixed_dt = 1.0 / 60
	}
	defer ui.driver_destroy(&a.driver)

	if profile == 0 || drive != "" {
		for ui.frame_begin(p) {
			frame(a)
			ui.frame_end(p)
		}
	}
	if profile > 0 {
		// After a drive script, if there was one: the state it left.
		p.running, p.driver, p.fixed_dt = true, nil, 0
		run_profile(a, profile)
	}
	if drive != "" {
		for s in a.driver.shots do fmt.println("screenshot:", s)
		if a.driver.failed do os.exit(1)
	}
}

// Opens the audio device (the fake one if asked), with inputs for
// recording when the device has them.
open_engine :: proc(a: ^App, fake: bool) -> bool {
	for inputs in ([]int{2, 0}) {
		settings := app.Host_Settings{fake = fake, inputs = inputs, max_block = 512, ram_bytes = 512 << 20, rebuild_on_rate_change = true}
		if a.host.driver != nil do app.host_destroy(&a.host)
		if app.host_init(&a.host, settings, &a.bus) != .None do continue
		if app.host_open(&a.host) == .None do return true
	}
	return false
}

// One frame: events, the engine, then the UI.
frame :: proc(a: ^App) {
	app.dispatch(&a.bus)
	app.host_update(&a.host)
	handle_drops(a)
	ui.handle_shortcuts(&a.actions)
	play_keys(a)
	ui.workspace_draw(&a.ws, &a.actions, draw_menu, a)
	pm.sync(&a.m.engine)
	if pm.record_poll(&a.m, &a.rec) do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Recorded onto %s", pm.pad_label(a.rec.pad)))
	dt := im.GetIO().DeltaTime
	for &l in a.lit do l = max(l - dt, 0)
	a.frame += 1
}

// Plays pad `index` (from the mouse, a key or a script).
press :: proc(a: ^App, index: int, velocity: f32 = 1) {
	a.selected = index
	if a.m.project.pads[index].sample != 0 {
		pm.hit(&a.m.engine, index, true, velocity)
		a.lit[index] = 0.18
	}
	a.held[index] = true
}

// Releases pad `index`.
release :: proc(a: ^App, index: int) {
	if !a.held[index] do return
	a.held[index] = false
	pm.hit(&a.m.engine, index, false)
}

// The computer keyboard as a 4×4 pad grid, top row first.
PAD_KEYS := [16]im.Key{._1, ._2, ._3, ._4, .Q, .W, .E, .R, .A, .S, .D, .F, .Z, .X, .C, .V}

play_keys :: proc(a: ^App) {
	io := im.GetIO()
	if io.WantTextInput || io.KeyCtrl || io.KeySuper do return
	for k, i in PAD_KEYS {
		index := a.bank * pm.PADS_PER_BANK + i
		if im.IsKeyPressed(k, false) do press(a, index, 0.85)
		if im.IsKeyReleased(k) do release(a, index)
	}
}

// The pad of the current bank drawn at `pos`, or -1.
pad_at :: proc(a: ^App, pos: im.Vec2) -> int {
	for r, i in a.pad_rects {
		if pos.x >= r[0].x && pos.x < r[1].x && pos.y >= r[0].y && pos.y < r[1].y do return a.bank * pm.PADS_PER_BANK + i
	}
	return -1
}

// Files dropped on the window go to the pad under them, or the selected one.
handle_drops :: proc(a: ^App) {
	for d in a.platform.drops {
		index := pad_at(a, d.pos)
		if index < 0 do index = a.selected
		if pm.load_onto_pad(&a.m, index, d.path) == .None {
			a.selected = index
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Loaded %s onto %s", filepath.base(d.path), pm.pad_label(index)))
		} else {
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", filepath.base(d.path)))
		}
	}
}

// Draws `frames` frames back to back and prints the CPU time per frame.
run_profile :: proc(a: ^App, frames: int) {
	p := &a.platform
	times := make([]f64, frames)
	defer delete(times)
	for i in 0 ..< frames {
		t0 := time.tick_now()
		if !ui.frame_begin(p) do break
		frame(a)
		ui.frame_end(p)
		times[i] = time.duration_milliseconds(time.tick_since(t0))
	}
	rest := times[frames / 10:]
	slice.sort(rest)
	fmt.printfln("%d frames: median %.3f ms, p99 %.3f ms", len(rest), rest[len(rest) / 2], rest[len(rest) * 99 / 100])
}
