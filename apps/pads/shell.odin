package pads

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"
import fc "fire:core"

setup_actions :: proc(a: ^App) {
	acts := &a.actions
	add :: proc(acts: ^ui.Actions, x: ui.Action) { ui.action_add(acts, x) }
	add(acts, {id = "undo", label = "Undo", icon = ui.ICON_UNDO_2, chord = ui.MOD_CMD | i32(im.Key.Z), user = a,
		run = proc(u: rawptr) { app.undo(&(^App)(u).m.history) },
		enabled = proc(u: rawptr) -> bool { return len((^App)(u).m.history.undo) > 0 }})
	add(acts, {id = "redo", label = "Redo", icon = ui.ICON_REDO_2, chord = ui.MOD_CMD | ui.MOD_SHIFT | i32(im.Key.Z), user = a,
		run = proc(u: rawptr) { app.redo(&(^App)(u).m.history) },
		enabled = proc(u: rawptr) -> bool { return len((^App)(u).m.history.redo) > 0 }})
	add(acts, {id = "new", label = "New Project", icon = ui.ICON_FILE_PLUS, chord = ui.MOD_CMD | i32(im.Key.N), user = a,
		run = proc(u: rawptr) { new_project((^App)(u)) }})
	add(acts, {id = "open", label = "Open Project…", icon = ui.ICON_FOLDER_OPEN, chord = ui.MOD_CMD | i32(im.Key.O), user = a,
		run = proc(u: rawptr) { project_dialog((^App)(u), .Open) }})
	add(acts, {id = "save", label = "Save", icon = ui.ICON_SAVE, chord = ui.MOD_CMD | i32(im.Key.S), user = a,
		run = proc(u: rawptr) { a := (^App)(u); if save_project(a) do ui.toast(&a.ws.toasts, .Success, "Saved") }})
	add(acts, {id = "save_as", label = "Save As…", icon = ui.ICON_SAVE, chord = ui.MOD_CMD | ui.MOD_SHIFT | i32(im.Key.S), user = a,
		run = proc(u: rawptr) { project_dialog((^App)(u), .Save_As) }})
	add(acts, {id = "export", label = "Export Audio…", icon = ui.ICON_DOWNLOAD, chord = ui.MOD_CMD | i32(im.Key.E), user = a,
		run = proc(u: rawptr) { (^App)(u).proj.export_open = true }})
	add(acts, {id = "resample", label = "Resample Sequence to Pad", icon = ui.ICON_COPY_PLUS, user = a,
		run = proc(u: rawptr) { start_resample((^App)(u)) }})
	add(acts, {id = "song_mode", label = "Song Mode", icon = ui.ICON_LIST_MUSIC, user = a,
		run = proc(u: rawptr) { a := (^App)(u); a.m.project.song_mode = !a.m.project.song_mode; a.m.engine.seq_dirty = true },
		checked = proc(u: rawptr) -> bool { return (^App)(u).m.project.song_mode }})
	add(acts, {id = "import", label = "Import Sample…", icon = ui.ICON_FILE_AUDIO, chord = ui.MOD_CMD | i32(im.Key.I), user = a,
		run = proc(u: rawptr) { open_import_dialog((^App)(u)) }})
	add(acts, {id = "import_midi", label = "Import MIDI File…", icon = ui.ICON_MUSIC, user = a,
		run = proc(u: rawptr) { open_midi_dialog((^App)(u)) }})
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
		ui.menu_action(&a.actions, "new")
		ui.menu_action(&a.actions, "open")
		if im.BeginMenu("Open Recent", len(a.proj.recent) > 0) {
			for r in a.proj.recent do if im.MenuItem(fmt.ctprintf("%s", filepath.base(r))) do open_project(a, r)
			im.EndMenu()
		}
		ui.menu_action(&a.actions, "save")
		ui.menu_action(&a.actions, "save_as")
		im.Separator()
		ui.menu_action(&a.actions, "import")
		ui.menu_action(&a.actions, "import_midi")
		ui.menu_action(&a.actions, "export")
		ui.menu_action(&a.actions, "resample")
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
		ui.menu_action(&a.actions, "song_mode")
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
		w.sizes[.Bottom] = 0.44
	ui.panel_add(w, {id = "browser", title = "Browser", icon = ui.ICON_FOLDER, open = true, draw = draw_browser, user = a}, .Left)
	ui.panel_add(w, {id = "sequence", title = "Sequence", icon = ui.ICON_LIST_MUSIC, open = true, draw = draw_sequence, user = a}, .Center)
	ui.panel_add(w, {id = "song", title = "Song", icon = ui.ICON_LIST_ORDERED, open = true, draw = draw_song, user = a}, .Center)
	ui.panel_add(w, {id = "mixer", title = "Mixer", icon = ui.ICON_SLIDERS_VERTICAL, open = true, draw = draw_mixer, user = a}, .Center)
	ui.panel_add(w, {id = "detail", title = "Pads", icon = ui.ICON_LAYOUT_GRID, open = true, draw = draw_detail, user = a, flags = {.NoScrollbar, .NoScrollWithMouse}}, .Bottom)
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

// A MIDI file dialog: the file goes into the current sequence (drums by
// the MIDI map).
open_midi_dialog :: proc(a: ^App) {
	filters := [1]sdl.DialogFileFilter{{name = "MIDI", pattern = "mid;midi"}}
	sdl.ShowOpenFileDialog(proc "c" (user: rawptr, files: [^]cstring, filter: i32) {
		if files == nil || files[0] == nil do return
		a := (^App)(user)
		context = runtime.default_context()
		app.post_any_thread(&a.bus, Midi_Chosen{strings.clone(string(files[0]))})
	}, a, a.platform.window, &filters[0], 1, nil, false)
}

// A MIDI file chosen in its dialog.
Midi_Chosen :: struct {
	path: string,
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
	app.subscribe(&a.bus, Plugin_Chosen, proc(user: rawptr, e: ^Plugin_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		choose_plugin(a, e.path, a.plugin_choice.target)
	}, a)
	app.subscribe(&a.bus, Midi_Chosen, proc(user: rawptr, e: ^Midi_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		n := pm.import_midi(&a.m, e.path, a.m.project.slot)
		if n < 0 do ui.toast(&a.ws.toasts, .Error, "Could not read that MIDI file")
		else do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%d notes into sequence %d", n, a.m.project.slot + 1))
	}, a)
}

// --- drive scripts ---------------------------------------------------------------------------

// Pads' own drive-script commands:
//
//	select N              select pad N (0..63)
//	hit N / release N     play pad N, release it
//	load N PATH           load a file onto pad N
//	bank N                show bank N (0..3)
//	browse DIR            show folder DIR in the browser (it goes on the back list)
//	browser up|back|forward|refresh|fav | open|toggle|select REL (under the folder shown) | tab N
//	state                 the app's state as one line of JSON (pads, sequencer, mixer, browser...)
//	crash segv|assert|bounds   crash on purpose (the crash reporter's test)
//	search QUERY (\"\" stops) / preview play|stop|auto on|off|sync on|off|volume DB
//	expect root NAME / expect rows K / expect results K (waits for the search) / expect previewing 0|1 / expect favorites K / expect selected_file NAME
//	set N FIELD VALUE     set a pad field: volume, pan, pitch, mode (0..3), choke, reverse (0/1)
//	chop N equal K        chop pad N into K parts (or: chop N transients SENSITIVITY)
//	expect pad N FIELD VALUE   fail unless pad N's FIELD (sample, name, volume, pan, pitch, mode, start, end, choke) is VALUE
//	expect samples K      fail unless the project holds K samples
//	expect selected N / expect bank N / expect dark 0|1
//	expect undo NAME      fail unless the next undo step is NAME
//	panel ID              bring a panel (browser, sequence, song, mixer, pads) or a pad tab (sample, pad, effects, perform) to the front
//	play / stop / rec on|off / metronome on|off   the sequencer
//	slot N (1..32) / bars N / tempo BPM / swing AMOUNT (0..1, on 1/16)
//	note PAD BEAT LENGTH [VELOCITY]   add a note to the current sequence
//	expect notes K / expect playing 0|1 / expect slot N / expect points K
//	expect midi_key PAD KEY / expect struck PAD MIN (it has sounded MIN+ times)
//	mode pads|keys|velocity / scale NAME / chord off|triad|seventh|power
//	arp on|off / repeat on|off / midi KEY VELOCITY (0: off) / learn PAD KEY
//	point PAD volume|pitch|low|mid|high BEAT VALUE / import_midi PATH
//	lane velocity|chance|automation [PARAM]   what the sequence editor's lane shows
//	insert PAD SLOT KIND / busfx BUS SLOT KIND / perf_fx N KIND   (BUS 4 = main; KIND: lowpass, reverb, ring...)
//	plugin BUS SLOT ID PATH / edit_fx pad P S|bus B S|perf N / fx_param ID VALUE (the edited slot)
//	send PAD BUS DB [pre|post]   a pad's send to bus BUS (1..4; DB -60 = off)
//	route PAD BUS (0 = main) / busvol BUS DB / mute|solo pad N|bus B (toggles) / perf N on|off
//	expect level main|bus B|pad N above|below DB / expect fx KIND
//	save / save_as DIR / open DIR / new / export PATH [song] [stems pads|buses] [rate HZ] [bits 16|24|32] [tail S]
//	resample / song add SLOT [REPEATS] | mode on|off | loop on|off | clear / switch end|bar|beat|now / export_dialog [off]
//	expect file PATH / expect song K / expect dirty 0|1 / expect pads_loaded K
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
			pm.browser_go(&a.browser, absolute(strings.join(w[1:], " ", context.temp_allocator)))
			return true
		}
	case "browser":
		// browser up|back|forward|open REL|toggle REL|select REL|down|tab N|refresh
		b := &a.browser
		if len(w) < 2 do return false
		rel := strings.join(w[2:], " ", context.temp_allocator) if len(w) > 2 else ""
		under, _ := filepath.join({b.root, rel}, context.temp_allocator)
		switch w[1] {
		case "up":      return pm.browser_up(b)
		case "back":    return pm.browser_back(b)
		case "forward": return pm.browser_forward(b)
		case "open":    pm.browser_go(b, under)
		case "toggle":  pm.browser_toggle(b, under)
		case "select":
			pm.browser_select(b, under)
			if pm.is_audio(under) do preview_selected(a, {path = under}, true)
		case "tab":     pm.browser_set_tab(b, num(w, 2))
		case "refresh": pm.browser_refresh(b)
		case "fav":     pm.favorite_add(b, b.root); pm.favorites_save(b, favorites_path(a))
		case: return false
		}
		return true
	case "state":
		ui.driver_say(&a.driver, state_json(a))
		return true
	case "crash":
		// crash segv|assert|bounds: the crash reporter's own test (scripts and harnesses only)
		if len(w) < 2 do return false
		switch w[1] {
		case "segv":
			p: ^int = nil
			p^ = 1
		case "assert": assert(false, "crash assert")
		case "bounds":
			xs := []int{1, 2}
			i := len(w) // 2: one past the end
			_ = xs[i]
		}
		return true
	case "search":
		q := strings.join(w[1:], " ", context.temp_allocator) if len(w) > 1 else ""
		a.bview.query = {}
		copy(a.bview.query[:len(a.bview.query) - 1], q)
		pm.browser_search(&a.browser, q)
		return true
	case "preview":
		// preview stop|play|auto on|off|sync on|off|volume DB
		e := &a.m.engine
		if len(w) < 2 do return false
		switch w[1] {
		case "stop":   pm.preview_stop(e)
		case "play":   pm.preview_play(e, a.browser.selected)
		case "auto":   e.preview.auto_play = len(w) > 2 && w[2] == "on"
		case "sync":   e.preview.sync = len(w) > 2 && w[2] == "on"
		case "volume": e.preview.volume = numf(w, 2)
		case: return false
		}
		return true
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
	case "mode":
		if len(w) < 2 do return false
		switch w[1] {
		case "pads":     a.play_mode = .Pads
		case "keys":     a.play_mode = .Keyboard
		case "velocity": a.play_mode = .Velocity
		case: return false
		}
		return true
	case "scale":
		if len(w) < 2 do return false
		for sc in pm.Scale do if strings.equal_fold(string(pm.SCALE_NAMES[sc]), strings.join(w[1:], " ", context.temp_allocator)) {
			a.keys.scale = sc
			return true
		}
		return false
	case "chord":
		if len(w) < 2 do return false
		switch w[1] {
		case "off":     a.keys.chord = .Off
		case "triad":   a.keys.chord = .Triad
		case "seventh": a.keys.chord = .Seventh
		case "power":   a.keys.chord = .Power
		case: return false
		}
		return true
	case "arp", "repeat":
		p := a.m.project.perform
		on := len(w) < 2 || w[1] != "off"
		if w[0] == "arp" do p.arp_on, p.repeat_on = on, p.repeat_on && !on
		else do p.repeat_on, p.arp_on = on, p.arp_on && !on
		pm.set_perform(&a.m, p)
		return true
	case "midi":
		// midi KEY VELOCITY (0 = note-off)
		if len(w) < 3 do return false
		key, vel := num(w, 1), num(w, 2)
		if key < 0 || key > 127 do return false
		app.host_midi_inject(&a.host, {0x90 if vel > 0 else 0x80, u8(key), u8(clamp(vel, 0, 127))})
		return true
	case "learn":
		if i := num(w, 1); pad_ok(i) && len(w) > 2 {
			pm.learn_midi(&a.m, num(w, 2), i)
			return true
		}
	case "point":
		// point PAD PARAM BEAT VALUE (PARAM: volume, pitch, low, mid, high)
		if len(w) < 5 do return false
		i := num(w, 1)
		if !pad_ok(i) do return false
		param: pm.Lane_Param
		switch w[2] {
		case "volume": param = .Volume
		case "pitch":  param = .Pitch
		case "low":    param = .Eq_Low
		case "mid":    param = .Eq_Mid
		case "high":   param = .Eq_High
		case: return false
		}
		pm.add_point(&a.m, a.m.project.slot, {pad = u8(i), param = param, beat = f64(numf(w, 3)), value = numf(w, 4)})
		return true
	case "lane":
		// lane velocity|chance|automation [volume|pitch|low|mid|high]
		if len(w) < 2 do return false
		switch w[1] {
		case "velocity":   a.seq.lane = 0
		case "chance":     a.seq.lane = 1
		case "automation": a.seq.lane = 2
		case: return false
		}
		if len(w) > 2 do for lp in pm.Lane_Param do if strings.has_prefix(strings.to_lower(string(pm.LANE_NAMES[lp]), context.temp_allocator), w[2]) || (w[2] == "low" && lp == .Eq_Low) || (w[2] == "mid" && lp == .Eq_Mid) || (w[2] == "high" && lp == .Eq_High) {
			a.seq.param = lp
			break
		}
		return true
	case "import_midi":
		if len(w) < 2 do return false
		if pm.import_midi(&a.m, strings.join(w[1:], " ", context.temp_allocator), a.m.project.slot) < 0 do return drive_fail(a, "could not read the MIDI file")
		return true
	case "insert", "busfx", "perf_fx":
		// insert PAD SLOT KIND / busfx BUS SLOT KIND (BUS 0..3, 4 = main) / perf_fx N KIND
		target := pm.Fx_Target{}
		k := 3
		switch w[0] {
		case "insert":  target = {.Pad, num(w, 1), num(w, 2)}
		case "busfx":   target = {.Bus, num(w, 1), num(w, 2)}
		case "perf_fx": target, k = {.Perf, num(w, 1), 0}, 2
		}
		if len(w) <= k do return false
		kind, ok := effect_kind(w[k])
		if !ok do return false
		s := pm.new_effect(kind)
		if target.kind == .Perf do s.on = false
		pm.set_target_slot(&a.m, target, s, "Set Effect")
		a.fx = target
		return true
	case "plugin":
		// plugin BUS SLOT ID PATH
		if len(w) < 5 do return false
		t := pm.Fx_Target{.Bus, num(w, 1), num(w, 2)}
		pm.set_target_slot(&a.m, t, pm.new_plugin_effect(&a.m.project, strings.join(w[4:], " ", context.temp_allocator), w[3], w[3]), "Add Plug-in")
		a.fx = t
		return true
	case "fx_param":
		// fx_param ID VALUE: a setting of the slot being edited
		if len(w) < 3 do return false
		pm.set_target_param(&a.m, a.fx, fc.Param_Id(num(w, 1)), numf(w, 2))
		app.seal(&a.m.history)
		return true
	case "edit_fx":
		// edit_fx pad PAD SLOT / edit_fx bus BUS SLOT / edit_fx perf N
		if len(w) < 3 do return false
		switch w[1] {
		case "pad":  a.fx = {.Pad, num(w, 2), num(w, 3)}
		case "bus":  a.fx = {.Bus, num(w, 2), num(w, 3)}
		case "perf": a.fx = {.Perf, num(w, 2), 0}
		case: return false
		}
		show_detail(a, .Effects)
		return true
	case "send":
		// send PAD BUS DB [pre|post]
		i, b := num(w, 1), num(w, 2)
		if !pad_ok(i) || b < 1 || b > pm.BUSES || len(w) < 4 do return false
		pm.set_send_db(&a.m, i, b, numf(w, 3))
		app.seal(&a.m.history)
		if len(w) > 4 do pm.set_send_pre(&a.m, i, b, w[4] == "pre")
		return true
	case "route":
		if i := num(w, 1); pad_ok(i) {
			pm.set_pad_bus(&a.m, i, num(w, 2))
			return true
		}
	case "busvol":
		b := num(w, 1)
		if b < 0 || b > pm.BUSES do return false
		bus := pm.bus_of(&a.m, b)^
		bus.volume = numf(w, 2)
		pm.set_bus(&a.m, b, 0, "Set Volume", bus)
		app.seal(&a.m.history)
		return true
	case "mute", "solo":
		// mute pad N / mute bus B (solo likewise); toggles
		if len(w) < 3 do return false
		i := num(w, 2)
		if w[1] == "pad" && pad_ok(i) {
			p := a.m.project.pads[i]
			if w[0] == "mute" do p.mute = !p.mute
			else do p.solo = !p.solo
			pm.set_pad(&a.m, i, .Mute, "Mute", p)
			app.seal(&a.m.history)
			return true
		}
		if w[1] == "bus" && i >= 0 && i <= pm.BUSES {
			bus := pm.bus_of(&a.m, i)^
			if w[0] == "mute" do bus.mute = !bus.mute
			else do bus.solo = !bus.solo
			pm.set_bus(&a.m, i, 1, "Mute", bus)
			app.seal(&a.m.history)
			return true
		}
	case "perf":
		// perf N on|off: hold (or let go of) performance effect N (0..15)
		i := num(w, 1)
		if i < 0 || i >= pm.PERF_FX do return false
		pm.hold_perf_fx(&a.m, i, len(w) < 3 || w[2] != "off")
		return true
	case "save":
		return save_project(a)
	case "save_as":
		if len(w) < 2 do return false
		if pm.model_save_as(&a.m, strings.join(w[1:], " ", context.temp_allocator)) != .None do return drive_fail(a, "could not save as")
		return true
	case "open":
		if len(w) < 2 do return false
		if !open_project(a, strings.join(w[1:], " ", context.temp_allocator)) do return drive_fail(a, "could not open")
		return true
	case "new":
		new_project(a)
		return true
	case "export":
		// export PATH [song] [stems pads|buses] [rate HZ] [bits 16|24|32] [tail S]
		if len(w) < 2 do return false
		st := pm.Export_Settings{rate = 48_000, encoding = .Int24}
		for k := 2; k < len(w); k += 1 {
			switch w[k] {
			case "song":  st.source = .Song
			case "stems": k += 1; st.stems = .Pads if k < len(w) && w[k] == "pads" else .Buses
			case "rate":  k += 1; st.rate = f64(numf(w, k))
			case "tail":  k += 1; st.tail = f64(numf(w, k))
			case "bits":
				k += 1
				switch num(w, k) {
				case 16: st.encoding = .Int16
				case 32: st.encoding = .Float32
				}
			}
		}
		x: pm.Export
		defer pm.export_destroy(&x)
		if len(pm.export_all(&a.m, st, w[1], &x)) == 0 do return drive_fail(a, "nothing exported")
		return true
	case "resample":
		start_resample(a)
		return true
	case "song":
		// song add SLOT [REPEATS] / song mode on|off / song loop on|off / song clear
		if len(w) < 2 do return false
		switch w[1] {
		case "add":
			reps := num(w, 3) if len(w) > 3 else 1
			pm.song_add(&a.m, num(w, 2) - 1, repeats = reps)
		case "mode":
			a.m.project.song_mode = len(w) < 3 || w[2] != "off"
			a.m.engine.seq_dirty = true
		case "loop":
			s := a.m.project.song
			s.loop = len(w) < 3 || w[2] != "off"
			pm.set_song(&a.m, "Loop Song", s)
		case "clear":
			pm.set_song(&a.m, "Clear Song", {})
		case: return false
		}
		return true
	case "switch":
		if len(w) < 2 do return false
		switch w[1] {
		case "end":  a.m.project.switch_at = .End
		case "bar":  a.m.project.switch_at = .Bar
		case "beat": a.m.project.switch_at = .Beat
		case "now":  a.m.project.switch_at = .Now
		case: return false
		}
		return true
	case "export_dialog":
		a.proj.export_open = len(w) < 2 || w[1] != "off"
		return true
	case "panel":
		if len(w) < 2 do return false
		switch w[1] {
		case "sample":            show_detail(a, .Sample)
		case "pad", "inspector":  show_detail(a, .Pad)
		case "effect", "effects": show_detail(a, .Effects)
		case "perform":           show_detail(a, .Perform)
		case "pads":              ui.panel_focus(&a.ws, "detail")
		case: return ui.panel_focus(&a.ws, strings.clone_to_cstring(w[1], context.temp_allocator))
		}
		return true
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

// `path` made absolute (from the working folder), temporary allocator.
@(private)
absolute :: proc(path: string) -> string {
	if filepath.is_abs(path) do return path
	cwd, _ := os.get_working_directory(context.temp_allocator)
	full, _ := filepath.join({cwd, path}, context.temp_allocator)
	return full
}

// An effect kind by its name in scripts: lowpass, reverb, ring, ...
@(private)
effect_kind :: proc(name: string) -> (pm.Effect_Kind, bool) {
	for k in pm.Effect_Kind {
		n, _ := strings.replace_all(strings.to_lower(string(pm.EFFECT_NAMES[k]), context.temp_allocator), "-", "", context.temp_allocator)
		n, _ = strings.replace_all(n, " ", "", context.temp_allocator)
		if n == strings.to_lower(name, context.temp_allocator) || strings.has_prefix(n, strings.to_lower(name, context.temp_allocator)) do return k, true
	}
	return .None, false
}

@(private)
drive_fail :: proc(a: ^App, what: string) -> bool {
	ui.driver_error(&a.driver, fmt.tprint("pads: drive:", what))
	return true
}

@(private)
drive_expect :: proc(a: ^App, w: []string) -> bool {
	if len(w) < 3 do return false
	switch w[1] {
	case "level":
		// expect level main|bus B|pad N above|below DB (the meter's level as shown, dB)
		i := 0
		k := 3
		view: [2]Meter_View
		switch w[2] {
		case "main": view = a.mixer.buses[pm.BUSES]
		case "bus":
			if len(w) < 6 do return false
			i, _ = strconv.parse_int(w[3])
			view = a.mixer.buses[clamp(i, 0, pm.BUSES)]
			k = 4
		case "pad":
			if len(w) < 6 do return false
			i, _ = strconv.parse_int(w[3])
			view = a.mixer.pads[clamp(i, 0, pm.PADS - 1)]
			k = 4
		case: return false
		}
		peak := [2]f32{view[0].peak, view[1].peak}
		if len(w) < k + 2 do return false
		lim, _ := strconv.parse_f32(w[k + 1])
		db := 20 * math.log10(max(max(peak[0], peak[1]), 1e-6))
		above := w[k] == "above"
		if above != (db > lim) do return drive_fail(a, fmt.tprintf("expected %s %s %.1f dB, got %.1f dB", w[2], w[k], lim, db))
		return true
	case "fx":
		// expect fx KIND: the slot being edited holds KIND
		s, _ := pm.target_slot(&a.m, a.fx)
		kind, ok := effect_kind(w[2])
		if !ok || s.kind != kind do return drive_fail(a, fmt.tprintf("expected %s in the edited slot, got %s", w[2], pm.slot_name(s)))
		return true
	case "file":
		path := strings.join(w[2:], " ", context.temp_allocator)
		if !os.exists(path) do return drive_fail(a, fmt.tprintf("expected the file %s", path))
		return true
	case "song":
		want, _ := strconv.parse_int(w[2])
		if a.m.project.song.count != want do return drive_fail(a, fmt.tprintf("expected %d song steps, got %d", want, a.m.project.song.count))
		return true
	case "dirty":
		if pm.model_dirty(&a.m) != (w[2] == "1") do return drive_fail(a, fmt.tprintf("expected dirty %s", w[2]))
		return true
	case "root":
		if filepath.base(a.browser.root) != strings.join(w[2:], " ", context.temp_allocator) do return drive_fail(a, fmt.tprintf("expected the browser in %s, it is in %s", w[2], a.browser.root))
		return true
	case "rows":
		want, _ := strconv.parse_int(w[2])
		if got := len(pm.browser_rows(&a.browser)); got != want do return drive_fail(a, fmt.tprintf("expected %d browser rows, got %d", want, got))
		return true
	case "results":
		want, _ := strconv.parse_int(w[2])
		start := time.tick_now()
		for !pm.search_done(&a.browser.search) && time.tick_since(start) < 5 * time.Second do time.sleep(time.Millisecond)
		if got := len(pm.search_results(&a.browser.search)); got != want do return drive_fail(a, fmt.tprintf("expected %d search results, got %d", want, got))
		return true
	case "previewing":
		start := time.tick_now()
		for a.m.engine.preview.loading != nil && time.tick_since(start) < 3 * time.Second {
			pm.sync(&a.m.engine)
			time.sleep(time.Millisecond)
		}
		if pm.preview_playing(&a.m.engine) != (w[2] == "1") do return drive_fail(a, fmt.tprintf("expected previewing %s", w[2]))
		return true
	case "favorites":
		want, _ := strconv.parse_int(w[2])
		if len(a.browser.favorites) != want do return drive_fail(a, fmt.tprintf("expected %d favourites, got %d", want, len(a.browser.favorites)))
		return true
	case "selected_file":
		if filepath.base(a.browser.selected) != strings.join(w[2:], " ", context.temp_allocator) do return drive_fail(a, fmt.tprintf("expected %s selected in the browser, got %s", w[2], a.browser.selected))
		return true
	case "pads_loaded":
		want, _ := strconv.parse_int(w[2])
		got := 0
		for pad in a.m.project.pads do if pad.sample != 0 do got += 1
		if got != want do return drive_fail(a, fmt.tprintf("expected %d pads with sounds, got %d", want, got))
		return true
	case "points":
		want, _ := strconv.parse_int(w[2])
		got := len(pm.current_sequence(&a.m).points)
		if got != want do return drive_fail(a, fmt.tprintf("expected %d automation points, got %d", want, got))
		return true
	case "midi_key":
		if len(w) < 4 do return false
		want, _ := strconv.parse_int(w[3])
		i, _ := strconv.parse_int(w[2])
		if got := pm.midi_key_of(&a.m, i); got != want do return drive_fail(a, fmt.tprintf("expected pad %d on key %d, got %d", i, want, got))
		return true
	case "struck":
		// expect struck PAD MIN: pad PAD has sounded at least MIN times
		if len(w) < 4 do return false
		i, _ := strconv.parse_int(w[2])
		want, _ := strconv.parse_int(w[3])
		if got := int(pm.struck(&a.m.engine, i)); got < want do return drive_fail(a, fmt.tprintf("expected pad %d struck %d+ times, got %d", i, want, got))
		return true
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
