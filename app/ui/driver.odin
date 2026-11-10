package ui

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import sdl "deps:sdl3"

// Runs a UI from a script: input events pushed into SDL's queue (so they
// reach ImGui exactly as real input does) and screenshots of chosen
// frames, for testing layouts and interactions without a person. One
// command per line; `#` starts a comment. Coordinates are logical points
// from the window's top left.
//
//	size W H              resize the window
//	wait [N]              let N frames pass (default 1)
//	move X Y              move the mouse
//	down [BUTTON]         press a mouse button (left, right, middle; default left)
//	up [BUTTON]           release it
//	click X Y [BUTTON]    move, press, and release on the next frame
//	drag X1 Y1 X2 Y2 [N]  press at the first point, move to the second over N frames, release
//	scroll DX DY          turn the wheel (positive DY scrolls up)
//	key CHORD             press and release a key: a, enter, space, ctrl+z, cmd+shift+s...
//	text STRING           type text into the focused field
//	screenshot NAME       save this frame as NAME.png in the output directory
//	quit                  stop the app
//
// Any other command goes to `Driver.command` (the app's own: "theme
// light", "open demo.pads"). When the script ends, the app quits.
Driver :: struct {
	lines:     []string,
	at:        int,      // next line
	wait:      int,      // frames left to wait
	pending:   [dynamic]sdl.Event, // events for the next frame (a click's release)
	out_dir:   string,   // where screenshots go
	shot_path: string,   // set for the frame to capture
	shots:     [dynamic]string, // every screenshot written
	failed:    bool,     // a line could not be run
	command:   proc(user: rawptr, words: []string) -> bool, // the app's commands; false = unknown
	user:      rawptr,
	texts:     [dynamic]cstring, // text events' strings, alive until the run ends
	mouse:     [2]f32,
	data:      []u8,
}

// Loads a script from `path`. Screenshots go to `out_dir` (created).
driver_load :: proc(d: ^Driver, path: string, out_dir: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("ui: cannot read drive script %s: %v", path, err)
		return false
	}
	return driver_init(d, string(data), out_dir, data)
}

// Starts a script given as text.
driver_init :: proc(d: ^Driver, script: string, out_dir: string, owned: []u8 = nil) -> bool {
	d.data = owned
	d.lines = strings.split_lines(script)
	d.out_dir = strings.clone(out_dir)
	_ = os.make_directory_all(out_dir)
	return true
}

// Frees the script and the list of screenshots.
driver_destroy :: proc(d: ^Driver) {
	delete(d.lines)
	delete(d.data)
	delete(d.out_dir)
	for s in d.shots do delete(s)
	delete(d.shots)
	for t in d.texts do delete(t)
	delete(d.texts)
	delete(d.pending)
	delete(d.shot_path)
	d^ = {}
}

// Runs the script up to its next frame boundary. Called by `frame_begin`.
@(private)
driver_step :: proc(d: ^Driver, p: ^Platform) {
	for e in d.pending {
		e := e
		_ = sdl.PushEvent(&e)
	}
	clear(&d.pending)
	if d.wait > 0 {
		d.wait -= 1
		return
	}
	for d.at < len(d.lines) {
		line := strings.trim_space(d.lines[d.at])
		d.at += 1
		if i := strings.index_byte(line, '#'); i >= 0 do line = strings.trim_space(line[:i])
		if line == "" do continue
		words := strings.fields(line, context.temp_allocator)
		if driver_run(d, p, words, line) do return // this command takes the frame
	}
	if d.wait == 0 && len(d.pending) == 0 do quit(p)
}

// Runs one command; true if the script should continue on the next frame.
@(private)
driver_run :: proc(d: ^Driver, p: ^Platform, w: []string, line: string) -> bool {
	num :: proc(w: []string, i: int, def: f32 = 0) -> f32 {
		if i >= len(w) do return def
		v, ok := strconv.parse_f32(w[i])
		return v if ok else def
	}
	window := sdl.GetWindowID(p.window)
	switch w[0] {
	case "size":
		sdl.SetWindowSize(p.window, i32(num(w, 1, 1280)), i32(num(w, 2, 800)))
		d.wait = 1 // let the resize settle
		return true
	case "wait":
		d.wait = max(int(num(w, 1, 1)) - 1, 0)
		return true
	case "move":
		push_motion(d, window, {num(w, 1), num(w, 2)})
		return true
	case "down", "up":
		push_button(d, window, button(w, 1), w[0] == "down", false)
		return true
	case "click":
		push_motion(d, window, {num(w, 1), num(w, 2)})
		push_button(d, window, button(w, 3), true, false)
		push_button(d, window, button(w, 3), false, true) // released on the next frame
		return true
	case "drag":
		from, to := [2]f32{num(w, 1), num(w, 2)}, [2]f32{num(w, 3), num(w, 4)}
		steps := max(int(num(w, 5, 8)), 1)
		push_motion(d, window, from)
		push_button(d, window, 1, true, false)
		// The moves and the release become lines run on later frames.
		extra := make([dynamic]string, context.temp_allocator)
		for i in 1 ..= steps {
			t := f32(i) / f32(steps)
			append(&extra, fmt.tprintf("move %v %v", from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t))
		}
		append(&extra, "up")
		insert_lines(d, extra[:])
		return true
	case "scroll":
		e: sdl.Event
		e.wheel = {type = .MOUSE_WHEEL, windowID = window, x = num(w, 1), y = num(w, 2), mouse_x = d.mouse.x, mouse_y = d.mouse.y}
		_ = sdl.PushEvent(&e)
		return true
	case "key":
		if len(w) < 2 do return fail(d, line)
		key, mod, ok := parse_chord(w[1])
		if !ok do return fail(d, line)
		code := sdl.GetScancodeFromKey(key, nil)
		down: sdl.Event
		down.key = {type = .KEY_DOWN, windowID = window, scancode = code, key = key, mod = mod, down = true}
		_ = sdl.PushEvent(&down)
		up := down
		up.key.type, up.key.down = .KEY_UP, false
		append(&d.pending, up)
		return true
	case "text":
		s := strings.trim_space(line[len("text"):])
		cs := strings.clone_to_cstring(s)
		append(&d.texts, cs)
		e: sdl.Event
		e.text = {type = .TEXT_INPUT, windowID = window, text = cs}
		_ = sdl.PushEvent(&e)
		return true
	case "screenshot":
		if len(w) < 2 do return fail(d, line)
		name := strings.concatenate({w[1], ".png"}, context.temp_allocator)
		path, _ := filepath.join({d.out_dir, name}, context.allocator)
		d.shot_path = path
		append(&d.shots, strings.clone(path))
		return true
	case "quit":
		quit(p)
		return true
	}
	if d.command != nil && d.command(d.user, w) do return true
	return fail(d, line)
}

@(private)
fail :: proc(d: ^Driver, line: string) -> bool {
	fmt.eprintfln("ui: drive script line %d not understood: %s", d.at, line)
	d.failed = true
	return false
}

@(private)
insert_lines :: proc(d: ^Driver, extra: []string) {
	lines := make([dynamic]string, 0, len(d.lines) + len(extra))
	append(&lines, ..d.lines[:d.at])
	for s in extra do append(&lines, strings.clone(s, context.allocator)) // small; freed with the process
	append(&lines, ..d.lines[d.at:])
	delete(d.lines)
	d.lines = lines[:]
}

@(private)
button :: proc(w: []string, i: int) -> u8 {
	if i >= len(w) do return 1
	switch w[i] {
	case "right":  return 3
	case "middle": return 2
	}
	return 1
}

@(private)
push_motion :: proc(d: ^Driver, window: sdl.WindowID, at: [2]f32) {
	e: sdl.Event
	e.motion = {type = .MOUSE_MOTION, windowID = window, x = at.x, y = at.y, xrel = at.x - d.mouse.x, yrel = at.y - d.mouse.y}
	d.mouse = at
	_ = sdl.PushEvent(&e)
}

@(private)
push_button :: proc(d: ^Driver, window: sdl.WindowID, b: u8, down: bool, later: bool) {
	e: sdl.Event
	e.button = {type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP, windowID = window, button = b, down = down, clicks = 1, x = d.mouse.x, y = d.mouse.y}
	if later {
		append(&d.pending, e)
	} else {
		_ = sdl.PushEvent(&e)
	}
}

// "ctrl+shift+z" → the key and its modifiers. `cmd` is the platform's
// command key (Cmd on macOS, Ctrl elsewhere).
@(private)
parse_chord :: proc(chord: string) -> (key: sdl.Keycode, mod: sdl.Keymod, ok: bool) {
	parts := strings.split(chord, "+", context.temp_allocator)
	for part, i in parts {
		if i < len(parts) - 1 {
			switch part {
			case "ctrl":  mod += {.LCTRL}
			case "shift": mod += {.LSHIFT}
			case "alt":   mod += {.LALT}
			case "cmd":   mod += {.LGUI} when ODIN_OS == .Darwin else {.LCTRL}
			case:         return 0, {}, false
			}
			continue
		}
		alias := part
		switch part {
		case "enter":     alias = "Return"
		case "esc":       alias = "Escape"
		case "del":       alias = "Delete"
		case "backspace": alias = "Backspace"
		}
		name := strings.clone_to_cstring(alias, context.temp_allocator)
		key = sdl.GetKeyFromName(name)
		if key == sdl.K_UNKNOWN do return 0, {}, false
	}
	return key, mod, true
}
