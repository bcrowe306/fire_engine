package pads

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"

setup_actions :: proc(a: ^App) {
	acts := &a.actions
	add :: proc(acts: ^ui.Actions, x: ui.Action) { ui.action_add(acts, x) }
	add(acts, {id = "undo", label = "Undo", icon = ui.ICON_UNDO_2, chord = ui.MOD_CMD | i32(im.Key.Z), user = a,
		run = proc(u: rawptr) { app.undo(&(^App)(u).m.history) },
		enabled = proc(u: rawptr) -> bool { return len((^App)(u).m.history.undo) > 0 }})
	add(acts, {id = "redo", label = "Redo", icon = ui.ICON_REDO_2, chord = ui.MOD_CMD | ui.MOD_SHIFT | i32(im.Key.Z), user = a,
		run = proc(u: rawptr) { app.redo(&(^App)(u).m.history) },
		enabled = proc(u: rawptr) -> bool { return len((^App)(u).m.history.redo) > 0 }})
	add(acts, {id = "import", label = "Import Sample…", icon = ui.ICON_FILE_AUDIO, chord = ui.MOD_CMD | i32(im.Key.O), user = a,
		run = proc(u: rawptr) { open_import_dialog((^App)(u)) }})
	add(acts, {id = "clear_pad", label = "Clear Pad", icon = ui.ICON_ERASER, chord = i32(im.Key.Delete), user = a,
		run = proc(u: rawptr) { a := (^App)(u); pm.clear_pad(&a.m, a.selected) },
		enabled = proc(u: rawptr) -> bool { a := (^App)(u); return a.m.project.pads[a.selected].sample != 0 }})
	add(acts, {id = "palette", label = "Command Palette", icon = ui.ICON_SEARCH, chord = ui.MOD_CMD | i32(im.Key.K), user = a,
		run = proc(u: rawptr) { ui.palette_open(&(^App)(u).ws.palette) }})
	add(acts, {id = "theme", label = "Light Theme", icon = ui.ICON_SUN, user = a,
		run = proc(u: rawptr) { a := (^App)(u); set_dark(a, !a.dark) },
		checked = proc(u: rawptr) -> bool { return !(^App)(u).dark }})
	add(acts, {id = "reset_layout", label = "Reset Layout", icon = ui.ICON_LAYOUT_DASHBOARD, user = a,
		run = proc(u: rawptr) { ui.workspace_reset_layout(&(^App)(u).ws) }})
	for b in 0 ..< pm.BANKS {
		ids := [4]string{"bank_a", "bank_b", "bank_c", "bank_d"}
		labels := [4]string{"Bank A", "Bank B", "Bank C", "Bank D"}
		add(acts, {id = ids[b], label = labels[b], icon = ui.ICON_LAYOUT_GRID, chord = ui.MOD_CMD | (i32(im.Key._1) + i32(b)), user = a,
			run = bank_actions[b]})
	}
	add(acts, {id = "play", label = "Play / Stop", icon = ui.ICON_PLAY, chord = i32(im.Key.Space), user = a,
		run = proc(u: rawptr) { toggle_play((^App)(u)) }})
	add(acts, {id = "record", label = "Record", icon = ui.ICON_CIRCLE_DOT, chord = ui.MOD_CMD | i32(im.Key.R), user = a,
		run = proc(u: rawptr) { toggle_record((^App)(u)) },
		checked = proc(u: rawptr) -> bool { return (^App)(u).capture.armed }})
	add(acts, {id = "metronome", label = "Metronome", icon = ui.ICON_METRONOME, user = a,
		run = proc(u: rawptr) { e := &(^App)(u).m.engine; e.metronome = !e.metronome },
		checked = proc(u: rawptr) -> bool { return (^App)(u).m.engine.metronome }})
	add(acts, {id = "quantize", label = "Quantize Sequence", icon = ui.ICON_MAGNET, chord = ui.MOD_CMD | i32(im.Key.U), user = a,
		run = proc(u: rawptr) { a := (^App)(u); pm.quantize_sequence(&a.m, a.m.project.slot, a.seq.grid) }})
	add(acts, {id = "double", label = "Double Sequence", icon = ui.ICON_COPY_PLUS, user = a,
		run = proc(u: rawptr) { a := (^App)(u); pm.double_sequence(&a.m, a.m.project.slot) }})
	add(acts, {id = "clear_sequence", label = "Clear Sequence", icon = ui.ICON_TRASH_2, user = a,
		run = proc(u: rawptr) { a := (^App)(u); pm.clear_sequence(&a.m, a.m.project.slot) }})
	add(acts, {id = "quit", label = "Quit", icon = ui.ICON_LOG_OUT, chord = ui.MOD_CMD | i32(im.Key.Q), user = a,
		run = proc(u: rawptr) { ui.quit(&(^App)(u).platform) }})
}

bank_actions := [4]proc(u: rawptr) {
	proc(u: rawptr) { (^App)(u).bank = 0 },
	proc(u: rawptr) { (^App)(u).bank = 1 },
	proc(u: rawptr) { (^App)(u).bank = 2 },
	proc(u: rawptr) { (^App)(u).bank = 3 },
}

set_dark :: proc(a: ^App, dark: bool) {
	a.dark = dark
	ui.set_theme(&a.platform, ui.theme_dark() if dark else ui.theme_light())
}

draw_menu :: proc(user: rawptr) {
	a := (^App)(user)
	if im.BeginMenu("File") {
		ui.menu_action(&a.actions, "import")
		im.Separator()
		ui.menu_action(&a.actions, "quit")
		im.EndMenu()
	}
	if im.BeginMenu("Edit") {
		ui.menu_action(&a.actions, "undo")
		ui.menu_action(&a.actions, "redo")
		im.Separator()
		ui.menu_action(&a.actions, "clear_pad")
		im.Separator()
		ui.menu_action(&a.actions, "palette")
		im.EndMenu()
	}
	if im.BeginMenu("Sequence") {
		ui.menu_action(&a.actions, "play")
		ui.menu_action(&a.actions, "record")
		ui.menu_action(&a.actions, "metronome")
		im.Separator()
		ui.menu_action(&a.actions, "quantize")
		ui.menu_action(&a.actions, "double")
		ui.menu_action(&a.actions, "clear_sequence")
		im.EndMenu()
	}
	if im.BeginMenu("View") {
		for id in ([]string{"bank_a", "bank_b", "bank_c", "bank_d"}) do ui.menu_action(&a.actions, id)
		im.Separator()
		ui.menu_action(&a.actions, "theme")
		ui.menu_action(&a.actions, "reset_layout")
		im.EndMenu()
	}
}

setup_workspace :: proc(a: ^App) {
	w := &a.ws
	ui.workspace_init(w)
	w.sizes[.Left] = 0.18
	w.sizes[.Right] = 0.25
	w.sizes[.Bottom] = 0.42
	ui.panel_add(w, {id = "browser", title = "Browser", icon = ui.ICON_FOLDER, open = true, draw = draw_browser, user = a}, .Left)
	ui.panel_add(w, {id = "pads", title = "Pads", icon = ui.ICON_LAYOUT_GRID, open = true, draw = draw_pads, user = a, flags = {.NoScrollbar}}, .Center)
	ui.panel_add(w, {id = "inspector", title = "Pad", icon = ui.ICON_SLIDERS_HORIZONTAL, open = true, draw = draw_inspector, user = a}, .Right)
	ui.panel_add(w, {id = "sequence", title = "Sequence", icon = ui.ICON_LIST_MUSIC, open = true, draw = draw_sequence, user = a}, .Bottom)
	ui.panel_add(w, {id = "sample", title = "Sample", icon = ui.ICON_AUDIO_WAVEFORM, open = true, draw = draw_sample, user = a}, .Bottom)
	ui.panel_focus(w, "sequence")
}

// An "Import Sample" dialog (the system's), onto the selected pad. The
// dialog may answer on another thread: the choice comes back on the bus.
open_import_dialog :: proc(a: ^App) {
	filters := [1]sdl.DialogFileFilter{{name = "Audio", pattern = "wav;aif;aiff;flac;mp3;ogg"}}
	sdl.ShowOpenFileDialog(proc "c" (user: rawptr, files: [^]cstring, filter: i32) {
		if files == nil || files[0] == nil do return
		a := (^App)(user)
		context = runtime.default_context()
		app.post_any_thread(&a.bus, Import_Chosen{strings.clone(string(files[0]))})
	}, a, a.platform.window, &filters[0], 1, nil, false)
}

// A file chosen in the import dialog.
Import_Chosen :: struct {
	path: string,
}

// Loads files chosen in the import dialog onto the selected pad.
subscribe_imports :: proc(a: ^App) {
	app.subscribe(&a.bus, Import_Chosen, proc(user: rawptr, e: ^Import_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		if pm.load_onto_pad(&a.m, a.selected, e.path) != .None do ui.toast(&a.ws.toasts, .Error, "Could not load that file")
	}, a)
}

// --- drive scripts ---------------------------------------------------------------------------

// Pads' own drive-script commands:
//
//	select N              select pad N (0..63)
//	hit N / release N     play pad N, release it
//	load N PATH           load a file onto pad N
//	bank N                show bank N (0..3)
//	browse DIR            show folder DIR in the browser
//	set N FIELD VALUE     set a pad field: volume, pan, pitch, mode (0..3), choke, reverse (0/1)
//	chop N equal K        chop pad N into K parts (or: chop N transients SENSITIVITY)
//	expect pad N FIELD VALUE   fail unless pad N's FIELD (sample, name, volume, pan, pitch, mode, start, end, choke) is VALUE
//	expect samples K      fail unless the project holds K samples
//	expect selected N / expect bank N / expect dark 0|1
//	expect undo NAME      fail unless the next undo step is NAME
//	panel ID              bring a panel to the front: browser, pads, inspector, sequence, sample
//	play / stop / rec on|off / metronome on|off   the sequencer
//	slot N (1..32) / bars N / tempo BPM / swing AMOUNT (0..1, on 1/16)
//	note PAD BEAT LENGTH [VELOCITY]   add a note to the current sequence
//	expect notes K / expect playing 0|1 / expect slot N
//	theme light|dark, action ID
drive_command :: proc(user: rawptr, w: []string) -> bool {
	a := (^App)(user)
	num :: proc(w: []string, i: int) -> int {
		if i >= len(w) do return -1
		v, _ := strconv.parse_int(w[i])
		return v
	}
	numf :: proc(w: []string, i: int) -> f32 {
		if i >= len(w) do return 0
		v, _ := strconv.parse_f32(w[i])
		return v
	}
	pad_ok :: proc(i: int) -> bool { return i >= 0 && i < pm.PADS }
	switch w[0] {
	case "select":
		if i := num(w, 1); pad_ok(i) {
			a.selected = i
			return true
		}
	case "hit":
		if i := num(w, 1); pad_ok(i) {
			press(a, i)
			return true
		}
	case "release":
		if i := num(w, 1); pad_ok(i) {
			release(a, i)
			return true
		}
	case "load":
		if i := num(w, 1); pad_ok(i) && len(w) > 2 {
			if pm.load_onto_pad(&a.m, i, strings.join(w[2:], " ", context.temp_allocator)) != .None do return drive_fail(a, "could not load")
			a.selected = i
			return true
		}
	case "browse":
		if len(w) > 1 {
			delete(a.browser.dir)
			a.browser.dir = strings.clone(strings.join(w[1:], " ", context.temp_allocator))
			a.browser.scanned = false
			return true
		}
	case "bank":
		if b := num(w, 1); b >= 0 && b < pm.BANKS {
			a.bank = b
			return true
		}
	case "set":
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 4 do return false
		pad := a.m.project.pads[i]
		field: pm.Pad_Field
		switch w[2] {
		case "volume":  pad.volume, field = numf(w, 3), .Volume
		case "pan":     pad.pan, field = numf(w, 3), .Pan
		case "pitch":   pad.pitch, field = numf(w, 3), .Pitch
		case "mode":    pad.mode, field = pm.Pad_Mode(num(w, 3)), .Mode
		case "choke":   pad.choke, field = u8(num(w, 3)), .Choke
		case "reverse": pad.reverse, field = num(w, 3) != 0, .Reverse
		case: return false
		}
		pm.set_pad(&a.m, i, field, "Set", pad)
		return true
	case "chop":
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 4 do return false
		if w[2] == "equal" do pm.chop_to_pads(&a.m, i, pm.Chop_Equal{num(w, 3)})
		else do pm.chop_to_pads(&a.m, i, pm.Chop_Transients{f64(numf(w, 3))})
		return true
	case "theme":
		set_dark(a, len(w) < 2 || w[1] != "light")
		return true
	case "panel":
		return len(w) > 1 && ui.panel_focus(&a.ws, strings.clone_to_cstring(w[1], context.temp_allocator))
	case "play":
		pm.play(&a.m.engine)
		return true
	case "stop":
		pm.stop(&a.m.engine)
		pm.capture_arm(&a.m, &a.capture, false)
		return true
	case "rec":
		pm.capture_arm(&a.m, &a.capture, len(w) < 2 || w[1] != "off")
		return true
	case "metronome":
		a.m.engine.metronome = len(w) < 2 || w[1] != "off"
		return true
	case "slot":
		if k := num(w, 1); k >= 1 && k <= pm.SLOTS {
			pm.select_slot(&a.m, k - 1)
			return true
		}
	case "bars":
		if k := num(w, 1); k >= 1 {
			pm.set_bars(&a.m, a.m.project.slot, k)
			app.seal(&a.m.history)
			return true
		}
	case "note":
		if len(w) < 4 do return false
		i := num(w, 1)
		if !pad_ok(i) do return false
		vel := numf(w, 4) if len(w) > 4 else 0.8
		pm.add_note(&a.m, a.m.project.slot, {start = f64(numf(w, 2)), length = f64(numf(w, 3)), pad = u8(i), velocity = vel, probability = 1})
		return true
	case "swing":
		pm.set_swing(&a.m, a.m.project.slot, numf(w, 1), .Sixteenth)
		app.seal(&a.m.history)
		return true
	case "tempo":
		pm.set_bpm(&a.m, f64(numf(w, 1)))
		app.seal(&a.m.history)
		return true
	case "action":
		return len(w) > 1 && ui.run_action(&a.actions, w[1])
	case "expect":
		return drive_expect(a, w)
	}
	return false
}

@(private)
drive_fail :: proc(a: ^App, what: string) -> bool {
	fmt.eprintln("pads: drive:", what)
	a.driver.failed = true
	return true
}

@(private)
drive_expect :: proc(a: ^App, w: []string) -> bool {
	if len(w) < 3 do return false
	switch w[1] {
	case "notes":
		want, _ := strconv.parse_int(w[2])
		got := len(pm.current_sequence(&a.m).notes)
		if got != want do return drive_fail(a, fmt.tprintf("expected %d notes, got %d", want, got))
		return true
	case "playing":
		_, on := pm.position(&a.m.engine)
		if on != (w[2] == "1") do return drive_fail(a, fmt.tprintf("expected playing %s, got %v", w[2], on))
		return true
	case "slot":
		want, _ := strconv.parse_int(w[2])
		if a.m.project.slot + 1 != want do return drive_fail(a, fmt.tprintf("expected slot %d, got %d", want, a.m.project.slot + 1))
		return true
	case "selected", "bank":
		want, _ := strconv.parse_int(w[2])
		got := a.selected if w[1] == "selected" else a.bank
		if got != want do return drive_fail(a, fmt.tprintf("expected %s %d, got %d", w[1], want, got))
		return true
	case "dark":
		want := w[2] == "1"
		if a.dark != want do return drive_fail(a, fmt.tprintf("expected dark %v, got %v", want, a.dark))
		return true
	case "samples":
		want, _ := strconv.parse_int(w[2])
		got := app.store_len(&a.m.project.samples)
		if got != want do return drive_fail(a, fmt.tprintf("expected %d samples, got %d", want, got))
		return true
	case "undo":
		want := strings.join(w[2:], " ", context.temp_allocator)
		got := app.undo_name(&a.m.history)
		if got != want do return drive_fail(a, fmt.tprintf("expected undo %q, got %q", want, got))
		return true
	case "pad":
		if len(w) < 5 do return false
		i, _ := strconv.parse_int(w[2])
		pad := &a.m.project.pads[i]
		got: string
		switch w[3] {
		case "sample": got = "none" if pad.sample == 0 else pm.pad_sample(&a.m, i).name
		case "name":   got = pm.pad_name(pad)
		case "volume": got = fmt.tprintf("%g", pad.volume)
		case "pan":    got = fmt.tprintf("%g", pad.pan)
		case "pitch":  got = fmt.tprintf("%g", pad.pitch)
		case "mode":   got = fmt.tprintf("%d", int(pad.mode))
		case "start":  got = fmt.tprintf("%d", pad.start)
		case "end":    got = fmt.tprintf("%d", pad.end)
		case "choke":  got = fmt.tprintf("%d", pad.choke)
		case: return false
		}
		want := strings.join(w[4:], " ", context.temp_allocator)
		if got != want do return drive_fail(a, fmt.tprintf("expected pad %d %s %q, got %q", i, w[3], want, got))
		return true
	}
	return false
}
