/*
UI tests that need a window and a GPU. They run here, as a program, because
macOS only allows windows on the main thread and `odin test` runs tests on
worker threads. Each case draws a small UI, is driven by a script (input
events and screenshots, see app:ui's Driver), and checks what happened.

	task app:test            # also runs the headless odin tests
	.build/app/ui_tests [--out DIR] [CASE...]

Exits 0 when every case passes, 1 when one fails, and 0 with a "skipped"
line when there is no GPU to draw with.
*/
package ui_tests

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:path/filepath"

import "app:ui"
import im "deps:imgui"

Case :: struct {
	name:   string,
	script: string,
	draw:   proc(s: ^State),
	check:  proc(s: ^State, c: ^Checker),
}

// What a case's UI keeps between frames, for its checks.
State :: struct {
	platform: ^ui.Platform,
	clicks:   int,
	volume:   f32,
	enabled:  bool,
	name:     [64]u8,
	shots:    []string,
}

Checker :: struct {
	failures: int,
	case_:    string,
}

expect :: proc(c: ^Checker, ok: bool, what: string, args: ..any) {
	if ok do return
	c.failures += 1
	fmt.eprintfln("FAIL %s: %s", c.case_, fmt.tprintf(what, ..args))
}

cases := []Case {
	{
		name = "driven_input_reaches_widgets",
		script = `
size 640 400
wait 2
click 80 40                 # the button
drag 30 92 200 92 6         # the slider, from its left to the right
click 30 128                # the checkbox: on
click 120 164               # the text field
text hello
key enter
wait 2
screenshot frame
`,
		draw = proc(s: ^State) {
			im.SetNextWindowPos({0, 0})
			im.SetNextWindowSize({640, 400})
			im.Begin("main", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoCollapse})
			im.SetCursorPos({20, 20})
			if im.Button("Press me", {120, 40}) do s.clicks += 1
			im.SetCursorPos({20, 80})
			im.SetNextItemWidth(200)
			im.SliderFloat("Volume", &s.volume, 0, 1)
			im.SetCursorPos({20, 116})
			im.Checkbox("Enabled", &s.enabled)
			im.SetCursorPos({20, 152})
			im.SetNextItemWidth(200)
			im.InputText("Name", cstring(&s.name[0]), len(s.name))
			im.End()
		},
		check = proc(s: ^State, c: ^Checker) {
			expect(c, s.clicks == 1, "button clicked once (got %d)", s.clicks)
			expect(c, s.volume > 0.6, "slider dragged right (got %v)", s.volume)
			expect(c, s.enabled, "checkbox turned on")
			got := string(cstring(&s.name[0]))
			expect(c, got == "hello", "text typed (got %q)", got)
			expect(c, len(s.shots) == 1, "one screenshot (got %d)", len(s.shots))
			if len(s.shots) == 1 {
				img, err := png.load_from_file(s.shots[0])
				expect(c, err == nil, "screenshot decodes: %v", err)
				if err == nil {
					defer png.destroy(img)
					scale := f32(img.width) / 640
					expect(c, img.height == int(400 * scale), "screenshot is the window's size")
					// The button is drawn in the theme's control colour,
					// the background in its surface colour.
					t := ui.theme_dark()
					btn := pixel(img, int(30 * scale), int(30 * scale))
					bg := pixel(img, int(600 * scale), int(380 * scale))
					expect(c, near(bg, t.surface), "background is the surface colour (got %v)", bg)
					expect(c, !near(btn, t.surface), "the button is drawn (got %v)", btn)
				}
			}
		},
	},
}

pixel :: proc(img: ^png.Image, x, y: int) -> ui.Color {
	i := (y * img.width + x) * img.channels
	b := img.pixels.buf[i:]
	return {f32(b[0]) / 255, f32(b[1]) / 255, f32(b[2]) / 255, 1}
}

near :: proc(a, b: ui.Color) -> bool {
	return abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02
}

main :: proc() {
	out := ".build/app/ui_tests"
	only := make([dynamic]string)
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "--out" && i + 1 < len(os.args) {
			i += 1
			out = os.args[i]
		} else {
			append(&only, os.args[i])
		}
	}
	failed, ran := 0, 0
	for k in cases {
		if len(only) > 0 {
			found := false
			for n in only do found ||= n == k.name
			if !found do continue
		}
		p: ui.Platform
		if !ui.platform_init(&p, {title = k.name, width = 640, height = 400, headless = true}) {
			ui.platform_destroy(&p)
			fmt.println("skipped: no GPU device to draw with")
			os.exit(0)
		}
		p.fixed_dt = 1.0 / 60
		d: ui.Driver
		dir, _ := filepath.join({out, k.name})
		ui.driver_init(&d, k.script, dir)
		p.driver = &d
		s := State{platform = &p}
		frames := 0
		for ui.frame_begin(&p) {
			k.draw(&s)
			ui.frame_end(&p)
			frames += 1
			if frames > 2000 do break
		}
		s.shots = d.shots[:]
		c := Checker{case_ = k.name}
		expect(&c, !d.failed, "the script ran")
		k.check(&s, &c)
		ran += 1
		if c.failures > 0 do failed += 1
		fmt.printfln("%s %s (%d frames)", "FAIL" if c.failures > 0 else "ok  ", k.name, frames)
		ui.driver_destroy(&d)
		ui.platform_destroy(&p)
	}
	fmt.printfln("%d of %d UI cases passed", ran - failed, ran)
	os.exit(1 if failed > 0 else 0)
}
