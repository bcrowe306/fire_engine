/*
Pads: a sampler and sequencer built on Fire Engine's application layer.

	task app:run
	task app:drive -- tests/app_ui/drive/smoke.txt

Options:
	--drive FILE   run the UI from a drive script (see app:ui's Driver)
	--out DIR      where the script's screenshots go (default .build/app/shots)
	--headless     no window on screen (for scripted runs without a display)
	--profile N    draw N frames as fast as possible and print the CPU time per frame
*/
package pads

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import "app:ui"
import im "deps:imgui"

App :: struct {
	platform:  ui.Platform,
	driver:    ui.Driver,
	show_demo: bool,
	theme:     ui.Theme,
}

main :: proc() {
	drive, out, headless, profile := "", ".build/app/shots", false, 0
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--drive":    if i + 1 < len(os.args) { i += 1; drive = os.args[i] }
		case "--out":      if i + 1 < len(os.args) { i += 1; out = os.args[i] }
		case "--headless": headless = true
		case "--profile":  if i + 1 < len(os.args) { i += 1; profile = strconv.parse_int(os.args[i]) or_else 300 }
		case:
			fmt.eprintln("pads: unknown option", os.args[i])
			os.exit(2)
		}
	}

	app: App
	app.show_demo = true
	app.theme = ui.theme_dark()
	p := &app.platform
	if !ui.platform_init(p, {title = "Pads", width = 1280, height = 800, headless = headless, vsync = profile == 0}) {
		ui.platform_destroy(p)
		os.exit(1)
	}
	defer ui.platform_destroy(p)
	if drive != "" {
		if !ui.driver_load(&app.driver, drive, out) do os.exit(1)
		app.driver.command = app_command
		app.driver.user = &app
		p.driver = &app.driver
		p.fixed_dt = 1.0 / 60 // repeatable screenshots
	}
	defer ui.driver_destroy(&app.driver)

	if profile > 0 {
		run_profile(&app, profile)
		return
	}
	for ui.frame_begin(p) {
		draw(&app)
		ui.frame_end(p)
	}
	if drive != "" {
		for s in app.driver.shots do fmt.println("screenshot:", s)
		if app.driver.failed do os.exit(1)
	}
}

// The drive script's own commands.
app_command :: proc(user: rawptr, words: []string) -> bool {
	app := (^App)(user)
	switch words[0] {
	case "theme":
		app.theme = ui.theme_light() if len(words) > 1 && words[1] == "light" else ui.theme_dark()
		ui.set_theme(&app.platform, app.theme)
		return true
	case "demo":
		app.show_demo = len(words) < 2 || words[1] != "off"
		return true
	}
	return false
}

draw :: proc(app: ^App) {
	im.SetNextWindowPos({24, 24}, .FirstUseEver)
	im.SetNextWindowSize({420, 300}, .FirstUseEver)
	if im.Begin("Pads") {
		im.PushFontFloat(app.platform.fonts.bold, 22)
		im.Text("Pads")
		im.PopFont()
		im.TextDisabled("Milestone 1: SDL3, SDL_GPU and Dear ImGui, linked statically.")
		im.Separator()
		@(static) volume: f32 = 0.7
		@(static) enabled := true
		@(static) name: [64]u8
		im.SliderFloat("Volume", &volume, 0, 1)
		im.Checkbox("Enabled", &enabled)
		im.InputText("Name", cstring(&name[0]), len(name))
		if im.Button("Light theme") do app_command(app, {"theme", "light"})
		im.SameLine()
		if im.Button("Dark theme") do app_command(app, {"theme", "dark"})
		im.Text("Frame %d, %.0f FPS", app.platform.frame, im.GetIO().Framerate)
	}
	im.End()
	if app.show_demo do im.ShowDemoWindow(&app.show_demo)
}

// Draws `frames` frames back to back (no vsync) and prints the CPU time
// each took: building the UI, and recording and submitting its drawing.
run_profile :: proc(app: ^App, frames: int) {
	p := &app.platform
	times := make([]f64, frames)
	defer delete(times)
	for i in 0 ..< frames {
		t0 := time.tick_now()
		if !ui.frame_begin(p) do break
		draw(app)
		ui.frame_end(p)
		times[i] = time.duration_milliseconds(time.tick_since(t0))
	}
	rest := times[frames / 10:] // the first frames build the font atlas
	slice.sort(rest)
	fmt.printfln("%d frames: median %.3f ms, p99 %.3f ms, max %.3f ms", len(rest), rest[len(rest) / 2], rest[len(rest) * 99 / 100], rest[len(rest) - 1])
}
