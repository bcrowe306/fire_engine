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
//	hold KEY / let KEY    press / release a key and keep it: a modifier (shift, ctrl, alt, cmd: a Shift-drag), a letter or a digit
//	drop X Y PATH         drop a file on the window at X, Y (as from the desktop)
//	screenshot NAME       save this frame as NAME.png in the output directory
//	quit                  stop the app
//
// By what the user sees (the probe: items found by their label, waiting
// up to a second for one to show; LABEL in quotes if it has spaces,
// "Label#2" for the second; `in WINDOW` limits it to a panel by its id):
//
//	click_item LABEL [in WINDOW] [right|double] [at FX FY]   click the item (at FX, FY of its
//	                      width and height, 0..1; default its centre)
//	hover_item LABEL [in WINDOW]                  move the mouse onto it
//	drag_item LABEL [in WINDOW] to LABEL [in WINDOW] [N]   drag one item onto another
//	drag_by LABEL [in WINDOW] DX DY [N]           drag from the item's centre by DX, DY (a knob, a fader)
//	expect_item LABEL [in WINDOW] / expect_no_item LABEL [in WINDOW]
//	items [TEXT]          list the items showing (whose label or window has TEXT): window, label,
//	                      rectangle and label as given, tab-separated
//
// Any other command goes to `Driver.command` (the app's own: "theme
// light", "open demo.pads"). When the script ends, the app quits — unless
// it is live (fed line by line from a `Control` connection).
Driver :: struct {
	lines:     []string,
	at:        int,      // next line
	wait:      int,      // frames left to wait
	pending:   [dynamic]sdl.Event, // events for the next frame (a click's release)
	zoom:      f32, // the UI's zoom (positions are ImGui's: the window's are this many times larger)
	out_dir:   string,   // where screenshots go
	shot_path: string,   // set for the frame to capture
	shots:     [dynamic]string, // every screenshot written
	failed:    bool,     // a line could not be run
	command:   proc(user: rawptr, words: []string) -> bool, // the app's commands; false = unknown
	user:      rawptr,
	texts:     [dynamic]cstring, // text events' strings, alive until the run ends
	mouse:     [2]f32,
	data:      []u8,
	live:      bool, // lines come from a Control connection; it never ends on its own
	retry:     int,  // frames an item command has waited for its item
	reply:     strings.Builder, // what the current line says back (live), and its error
	error:     string,
	errors:    int, // lines that failed
}

// A line said something back (a live caller reads it): `text` and a
// newline. For the app's own commands (a state dump).
driver_say :: proc(d: ^Driver, text: string) {
	strings.write_string(&d.reply, text)
	strings.write_byte(&d.reply, '\n')
}

// The current line failed with `message` (printed, and told to a live
// caller); the script's run fails.
driver_error :: proc(d: ^Driver, message: string) {
	fmt.eprintln(message)
	if d.error == "" do d.error = strings.clone(message)
	d.failed = true
	d.errors += 1
}

// Whether the driver has run everything it was given (and its events have
// gone out): a live caller's line is done.
driver_idle :: proc(d: ^Driver) -> bool {
	return d.at >= len(d.lines) && d.wait == 0 && len(d.pending) == 0
}

// Gives a live driver one more line to run.
driver_feed :: proc(d: ^Driver, line: string) {
	lines := make([dynamic]string, 0, len(d.lines) + 1)
	append(&lines, ..d.lines)
	append(&lines, strings.clone(line))
	delete(d.lines)
	d.lines = lines[:]
	strings.builder_reset(&d.reply)
	delete(d.error)
	d.error = ""
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
	strings.builder_destroy(&d.reply)
	delete(d.error)
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
		if strings.has_prefix(line, "#") do continue
		if i := strings.index(line, " #"); i >= 0 do line = strings.trim_space(line[:i]) // a comment after it ("Label#2" stays)
		if line == "" do continue
		words := split_words(line)
		crash_note(line)
		if driver_run(d, p, words, line) do return // this command takes the frame
	}
	if d.wait == 0 && len(d.pending) == 0 && !d.live do quit(p)
}

// A line's words: spaces separate them, "double quotes" keep spaces in
// one (temporary allocator).
@(private)
split_words :: proc(line: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(line) {
		for i < len(line) && line[i] == ' ' do i += 1
		if i >= len(line) do break
		if line[i] == '"' {
			j := strings.index_byte(line[i + 1:], '"')
			end := len(line) if j < 0 else i + 1 + j
			append(&out, line[i + 1:end])
			i = end + 1
		} else {
			j := strings.index_byte(line[i:], ' ')
			end := len(line) if j < 0 else i + j
			append(&out, line[i:end])
			i = end
		}
	}
	return out[:]
}

// An item command's target: a label and, after `in`, its window; the
// words after it.
@(private)
target :: proc(w: []string) -> (label, window: string, rest: []string) {
	if len(w) == 0 do return
	label, rest = w[0], w[1:]
	if len(rest) >= 2 && rest[0] == "in" do window, rest = rest[1], rest[2:]
	return
}

// Finds an item for line `line`, or makes the line run again next frame
// (up to a second) while it isn't there yet; false then, or when it never
// shows (the line fails).
@(private)
find_or_wait :: proc(d: ^Driver, label, window, line: string) -> (Probe_Item, bool) {
	it, ok := probe_find(label, window)
	if ok {
		d.retry = 0
		return it, true
	}
	d.retry += 1
	if d.retry < 60 {
		d.at -= 1 // this line again, next frame
		return {}, false
	}
	d.retry = 0
	in_ := fmt.tprintf(" in %s", window) if window != "" else ""
	driver_error(d, fmt.tprintf("ui: drive line %d: no item \"%s\"%s (%s)", d.at, label, in_, line))
	return {}, false
}

@(private)
centre :: proc(it: Probe_Item) -> [2]f32 {
	return {(it.min.x + it.max.x) / 2, (it.min.y + it.max.y) / 2}
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
		// The press (a frame after the mouse arrives, as for a click), the
		// moves and the release become lines run on later frames.
		extra := make([dynamic]string, context.temp_allocator)
		append(&extra, "down")
		for i in 1 ..= steps {
			t := f32(i) / f32(steps)
			append(&extra, fmt.tprintf("move %v %v", from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t))
		}
		append(&extra, "up")
		insert_lines(d, extra[:])
		return true
	case "scroll":
		e: sdl.Event
		z := d.zoom if d.zoom > 0 else 1
		e.wheel = {type = .MOUSE_WHEEL, windowID = window, x = num(w, 1), y = num(w, 2), mouse_x = d.mouse.x * z, mouse_y = d.mouse.y * z}
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
		// Released with the modifiers: ImGui reads modifier state from each
		// key event, so an up event still carrying Cmd would leave it held.
		up := down
		up.key.type, up.key.down, up.key.mod = .KEY_UP, false, {}
		append(&d.pending, up)
		return true
	case "hold", "let":
		if len(w) < 2 do return fail(d, line)
		key: sdl.Keycode
		mod: sdl.Keymod
		switch w[1] {
		case "shift": key, mod = sdl.K_LSHIFT, {.LSHIFT}
		case "ctrl":  key, mod = sdl.K_LCTRL, {.LCTRL}
		case "alt":   key, mod = sdl.K_LALT, {.LALT}
		case "cmd":
			when ODIN_OS == .Darwin {
				key, mod = sdl.K_LGUI, {.LGUI}
			} else {
				key, mod = sdl.K_LCTRL, {.LCTRL}
			}
		case:
			// A letter or a digit (a pad key held, say).
			if len(w[1]) != 1 do return fail(d, line)
			c := w[1][0]
			switch c {
			case 'a' ..= 'z', '0' ..= '9': key = sdl.Keycode(c)
			case: return fail(d, line)
			}
		}
		down := w[0] == "hold"
		e: sdl.Event
		e.key = {type = .KEY_DOWN if down else .KEY_UP, windowID = window, scancode = sdl.GetScancodeFromKey(key, nil), key = key, mod = mod if down else {}, down = down}
		_ = sdl.PushEvent(&e)
		return true
	case "text":
		s := strings.trim_space(line[len("text"):])
		cs := strings.clone_to_cstring(s)
		append(&d.texts, cs)
		e: sdl.Event
		e.text = {type = .TEXT_INPUT, windowID = window, text = cs}
		_ = sdl.PushEvent(&e)
		return true
	case "drop":
		if len(w) < 4 do return fail(d, line)
		path := strings.trim_space(line[strings.index(line, w[3]):])
		append(&p.drops, Drop{strings.clone(path), {num(w, 1), num(w, 2)}})
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
	case "click_item", "hover_item":
		label, win, rest := target(w[1:])
		it, ok := find_or_wait(d, label, win, line)
		if !ok do return true
		at := centre(it)
		b := u8(1)
		double := false
		for r, k in rest {
			if r == "right" do b = 3
			if r == "double" do double = true
			if r == "at" && k + 2 < len(rest) {
				fx, fy := num(rest, k + 1, 0.5), num(rest, k + 2, 0.5)
				at = {it.min.x + (it.max.x - it.min.x) * fx, it.min.y + (it.max.y - it.min.y) * fy}
			}
		}
		push_motion(d, window, at)
		if w[0] == "hover_item" do return true
		// Pressed a frame after the mouse arrives, as a person's would be: an
		// item that allows overlap (a tab) counts as hovered only if it was
		// the frame before.
		which := "right" if b == 3 else "left"
		press := []string{fmt.tprintf("down %s", which), fmt.tprintf("up %s", which)}
		if double do press = {fmt.tprintf("down %s", which), fmt.tprintf("up %s", which), fmt.tprintf("down %s", which), fmt.tprintf("up %s", which)}
		insert_lines(d, press)
		return true
	case "drag_item":
		from_l, from_w, rest := target(w[1:])
		if len(rest) < 2 || rest[0] != "to" do return fail(d, line)
		to_l, to_w, rest2 := target(rest[1:])
		a, ok := find_or_wait(d, from_l, from_w, line)
		if !ok do return true
		b, ok2 := find_or_wait(d, to_l, to_w, line)
		if !ok2 do return true
		steps := 12
		if len(rest2) > 0 do steps = max(int(num(rest2, 0, 12)), 1)
		fa, fb := centre(a), centre(b)
		return driver_run(d, p, {"drag", fmt.tprint(fa.x), fmt.tprint(fa.y), fmt.tprint(fb.x), fmt.tprint(fb.y), fmt.tprint(steps)}, line)
	case "drag_by":
		label, win, rest := target(w[1:])
		if len(rest) < 2 do return fail(d, line)
		it, ok := find_or_wait(d, label, win, line)
		if !ok do return true
		c := centre(it)
		steps := max(int(num(rest, 2, 12)), 1)
		return driver_run(d, p, {"drag", fmt.tprint(c.x), fmt.tprint(c.y), fmt.tprint(c.x + num(rest, 0)), fmt.tprint(c.y + num(rest, 1)), fmt.tprint(steps)}, line)
	case "expect_item", "expect_no_item":
		label, win, _ := target(w[1:])
		_, found := probe_find(label, win)
		want := w[0] == "expect_item"
		if found != want {
			// Items show a frame late: give it up to a second.
			d.retry += 1
			if d.retry < 60 {
				d.at -= 1
				return true
			}
			d.retry = 0
			driver_error(d, fmt.tprintf("ui: drive line %d: expected %s\"%s\"%s", d.at, "" if want else "no ", label, fmt.tprintf(" in %s", win) if win != "" else ""))
			return false
		}
		d.retry = 0
		return false
	case "items":
		filter := strings.to_lower(w[1] if len(w) > 1 else "", context.temp_allocator)
		for it in probe_items() {
			if filter != "" && !strings.contains(strings.to_lower(it.raw, context.temp_allocator), filter) && !strings.contains(strings.to_lower(it.window, context.temp_allocator), filter) do continue
			driver_say(d, fmt.tprintf("%s\t%s\t%.0f %.0f %.0f %.0f\t%s", it.window, it.label, it.min.x, it.min.y, it.max.x, it.max.y, it.raw))
		}
		return false
	}
	if d.command != nil && d.command(d.user, w) do return true
	return fail(d, line)
}

@(private)
fail :: proc(d: ^Driver, line: string) -> bool {
	driver_error(d, fmt.tprintf("ui: drive script line %d not understood: %s", d.at, line))
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
	z := d.zoom if d.zoom > 0 else 1
	e.motion = {type = .MOUSE_MOTION, windowID = window, x = at.x * z, y = at.y * z, xrel = (at.x - d.mouse.x) * z, yrel = (at.y - d.mouse.y) * z}
	d.mouse = at
	_ = sdl.PushEvent(&e)
}

@(private)
push_button :: proc(d: ^Driver, window: sdl.WindowID, b: u8, down: bool, later: bool) {
	e: sdl.Event
	z := d.zoom if d.zoom > 0 else 1
	e.button = {type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP, windowID = window, button = b, down = down, clicks = 1, x = d.mouse.x * z, y = d.mouse.y * z}
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
