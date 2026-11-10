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
	// Widget cases.
	knob:     f32,
	edits:    [dynamic]ui.Edit,
	cells:    [2 * 8]bool,
	notes:    [dynamic]ui.Roll_Note,
	roll:     ui.Roll_View,
	adds:     int,
	moves:    int,
	marker:   i64,
	marker_released: bool,
	view:     ui.Wave_View,
	choice:   int,
	actions:  ui.Actions,
	ws:       ui.Workspace,
	ran:      [dynamic]string,
	ws_ready: bool,
}

// Opens the workspace once, with two actions the cases run.
ready_workspace :: proc(s: ^State) {
	if s.ws_ready do return
	s.ws_ready = true
	ui.workspace_init(&s.ws)
	ui.action_add(&s.actions, {id = "undo", label = "Undo", chord = ui.MOD_CMD | i32(im.Key.Z), user = s, run = proc(u: rawptr) { append(&(^State)(u).ran, "undo") }})
	ui.action_add(&s.actions, {id = "palette", label = "Command Palette", chord = ui.MOD_CMD | i32(im.Key.K), user = s, run = proc(u: rawptr) { ui.palette_open(&(^State)(u).ws.palette) }})
	ui.action_add(&s.actions, {id = "theme", label = "Toggle Light Theme", user = s, run = proc(u: rawptr) { append(&(^State)(u).ran, "theme") }})
}

full_window :: proc() {
	im.SetNextWindowPos({0, 0})
	im.SetNextWindowSize({640, 400})
	im.Begin("main", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoCollapse})
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
	{
		name = "knob_drag_and_reset",
		script = `
size 640 400
wait 2
drag 62 66 62 16 8        # up 50 points: more
wait 2
move 62 66
click 62 66
click 62 66               # a double-click: back to the default
wait 2
`,
		draw = proc(s: ^State) {
			full_window()
			im.SetCursorPos({40, 20})
			e := ui.knob("Gain", &s.knob, 0, 1, 0.5, "%.2f", 44)
			if e != {} do append(&s.edits, e)
			im.End()
		},
		check = proc(s: ^State, c: ^Checker) {
			started, changed, ended := 0, 0, 0
			for e in s.edits {
				if e.started do started += 1
				if e.changed do changed += 1
				if e.ended do ended += 1
			}
			expect(c, started >= 1, "a gesture started")
			expect(c, changed >= 2, "the value moved during the drag (%d changes)", changed)
			expect(c, ended >= 2, "the drag ended, and the reset ended at once (%d)", ended)
			expect(c, s.knob == 0.5, "double-click reset to the default (got %v)", s.knob)
		},
	},
	{
		name = "step_grid_paints",
		script = `
size 640 400
wait 2
drag 25 13 175 13 8       # across the first row: all on
wait 2
`,
		draw = proc(s: ^State) {
			full_window()
			im.SetCursorPos({10, 0})
			ui.step_grid("grid", s.cells[:], 2, 8, nil, -1, {20, 24})
			im.End()
		},
		check = proc(s: ^State, c: ^Checker) {
			on := 0
			for x in s.cells[:8] do if x do on += 1
			expect(c, on == 8, "the dragged row is all on (got %d of 8)", on)
			for x in s.cells[8:] do expect(c, !x, "the second row is untouched")
		},
	},
	{
		name = "piano_roll_adds_and_moves",
		script = `
size 640 400
wait 2
click 300 100             # empty space: add a note
wait 2
drag 70 392 170 392 6     # the first note (beat 0, the lowest key: y 383-400): two beats right
wait 2
`,
		draw = proc(s: ^State) {
			if s.roll.beats == 0 {
				s.roll = {beat0 = 0, beats = 12, key0 = 48, keys = 24}
				append(&s.notes, ui.Roll_Note{0, 1, 48, 0.8, false})
			}
			full_window()
			im.SetCursorPos({0, 0})
			r := ui.piano_roll("roll", s.notes[:], &s.roll, 0.25, {640, 400})
			if r.add {
				s.adds += 1
				append(&s.notes, ui.Roll_Note{r.at_beat, 0.5, r.at_key, 0.8, false})
			}
			if r.released && r.moving >= 0 {
				s.moves += 1
				s.notes[r.moving].start, s.notes[r.moving].key = r.to_start, r.to_key
			}
			im.End()
		},
		check = proc(s: ^State, c: ^Checker) {
			expect(c, s.adds == 1, "one note added (got %d)", s.adds)
			expect(c, s.moves == 1, "one note moved (got %d)", s.moves)
			if len(s.notes) > 0 {
				expect(c, abs(s.notes[0].start - 2) < 0.26, "moved about 2 beats right (to %v)", s.notes[0].start)
				expect(c, s.notes[0].key == 48, "on the same key (got %d)", s.notes[0].key)
			}
		},
	},
	{
		name = "waveform_marker_drag",
		script = `
size 640 400
wait 2
drag 160 60 320 60 6      # the marker at a quarter, to the middle
wait 2
`,
		draw = proc(s: ^State) {
			if s.marker == 0 do s.marker = 2500
			full_window()
			im.SetCursorPos({0, 0})
			peaks := [4]ui.Peak{{-0.5, 0.5}, {-0.3, 0.3}, {-0.8, 0.8}, {-0.1, 0.1}}
			markers := []ui.Marker{{frame = s.marker, drag = true, label = "S"}}
			e := ui.waveform("wave", peaks[:], 10_000, &s.view, markers, nil, {640, 120})
			if e.moved do s.marker = e.marker_to
			if e.released do s.marker_released = true
			im.End()
		},
		check = proc(s: ^State, c: ^Checker) {
			expect(c, abs(s.marker - 5000) < 100, "the marker went to the middle (got %d)", s.marker)
			expect(c, s.marker_released, "the drag ended")
		},
	},
	{
		name = "segmented_choice",
		script = `
size 640 400
wait 2
click 150 27              # the third option
wait 2
`,
		draw = proc(s: ^State) {
			full_window()
			im.SetCursorPos({20, 15})
			ui.segmented("mode", {"Grid", "Keys", "Repeat"}, &s.choice)
			im.End()
		},
		check = proc(s: ^State, c: ^Checker) {
			expect(c, s.choice == 2, "the third option chosen (got %d)", s.choice)
		},
	},
	{
		name = "shortcuts_and_the_palette",
		script = `
size 640 400
wait 2
key cmd+z                 # a shortcut runs its action
wait 2
key cmd+k                 # the palette
wait 2
text tog
wait 1
key enter                 # runs the only match
wait 2
screenshot palette_done
`,
		draw = proc(s: ^State) {
			ready_workspace(s)
			ui.handle_shortcuts(&s.actions)
			full_window()
			im.Text("Workspace")
			im.End()
			ui.palette_draw(&s.ws.palette, &s.actions)
		},
		check = proc(s: ^State, c: ^Checker) {
			expect(c, len(s.ran) == 2, "two actions ran (got %d: %v)", len(s.ran), s.ran)
			if len(s.ran) == 2 {
				expect(c, s.ran[0] == "undo", "the shortcut ran undo")
				expect(c, s.ran[1] == "theme", "the palette ran the theme action")
			}
			expect(c, !s.ws.palette.open, "the palette closed")
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
