/*
Pads: a sampler and sequencer built on Fire Engine's application layer.

Copyright (c) 2026 Fire Engine contributors. Pads is free software: you can
redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation, either version 3 of
the License, or (at your option) any later version (see LICENSE here). It
is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY. It is built on Fire Engine (MIT) and Ableton Link (GPL-2.0 or
later).

Load samples onto 64 pads in 4 banks, play them from the mouse, keyboard or
MIDI, and shape each one: its region, mode, loop, envelope, pitch, EQ and
choke group; chop, stretch and edit the audio.

	task app:run
	task app:drive -- tests/app_ui/drive/pads.txt

Options:
	--project DIR  the project folder: opens the project in it, or starts one there
	               (default: a new one in the temporary folder)
	--drive FILE   run the UI from a drive script (see app:ui's Driver)
	--out DIR      where the script's screenshots go (default .build/app/shots)
	--headless     no window on screen (for scripted runs without a display)
	--fake         the simulated audio driver (no sound card needed)
	--prefs DIR    where preferences go (recent projects, favourites); default: the system's
	--control PORT take commands live from a test harness on 127.0.0.1:PORT (0: any free
	               port; the one chosen is printed): see app:ui's Control and tests/e2e
	--profile N    draw N frames as fast as possible and print the CPU time per frame
	               (after the drive script, if one is given: profile a loaded project)
*/
package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
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
	sample_armed:   bool, // the Sample control is on: the next pad pressed records (Arm, Threshold, Bars)
	sample_holding: int,  // the pad recording while it is held (-1: none); its release stops it
	wave:     Wave_State,
	device:   Device_State, // the device tabs' LFO traces
	seq_ops:  Seq_Ops, // renaming, copying bars, the copied part
	spectrum: Spectrum_State, // an effect's spectrum, drawn on its device
	song_ui:  Song_State, // the Song tab's selected step, renaming
	commands: [dynamic]Command, // everything that can be done to something (commands.odin)
	pad_clip: pm.Pad, // a copied pad
	has_pad_clip: bool,
	slot_clip: pm.Effect_Slot, // a copied effect
	has_slot_clip: bool,
	release_at: [pm.PADS]int, // frames until a pad a command played lets go
	audition_off: struct { pad, pitch, frames: int }, // a pitched audition to let go
	voice_edit: pm.Voice, // a copy of the selected pad's voice the knobs point into
	browser:  pm.Browser,
	bview:    Browser_View,
	knob_target: pm.Auto_Target, // what the knob being drawn moves (see `knob_target`)
	knob_scale:  f32,
	auto_rec: Auto_Rec, // recording knob moves (the Automation arm)
	prefs:    string, // where preferences go (--prefs; default: the system's)
	control:  ui.Control, // --control: a test harness's live commands
	pad_waves: bool, // the pads show their sound's waveform (View > Pad Waveforms)
	peaks:    map[app.Id][]ui.Peak, // per sample, for the pads' faces
	tools:    Tool_State,
	settings: App_Settings, // File > Settings…
	plugins:  Plugin_Scan,  // the CLAP plug-ins found
	io:       Track_Io,     // arming, and the MIDI activity lights
	slicer_ui: Slicer_State, // the slicer page's selected slice
	wte:       Wave_Editor,  // the wavetable editor's window
	presets:   Preset_Ui,    // the synth's Save Preset dialog
	leave:     Leave_State,
	template:  Template_Ui, // the Save as Template dialog
	status:    Status_State, // the status bar's lights and load  // leaving a project with changes: the prompt; a crash's backup to offer
	param_host: Param_Host,  // where the synth's controls point (a synth pad, or an effect slot)
	synth_ui:  Synth_Ui,     // the synth page's tab, oscillator, envelope, LFO
	seq:      Seq_State,
	take_peaks: map[string]Peaks, // takes' waveforms, for the Audio tab and the rows (by path)
	capture:  pm.Capture,
	pad_rects: [pm.PADS_PER_BANK][2]im.Vec2, // where this bank's pads were drawn (for drops)
	pad_sel:  Pad_Set, // pads selected together (Shift: a range, Cmd: one more); see `selected_pads`
	pad_anchor: int,   // where a Shift-click range starts
	frame:    int,
	play_mode: pm.Play_Mode,
	keys:     pm.Keys,
	pads_bank: int, // the bank the pads were on before Keyboard mode moved it
	browser_has_keys: bool, // the browser's list had the keyboard last frame (its arrows)
	grid_held: [pm.PADS_PER_BANK]Grid_Held,
	perf:     Perf_State,
	mixer:    Mixer_State,
	fx:       pm.Fx_Target, // the effect slot the Effects tab edits
	plugin_choice: Plugin_Choice,
	editors:  [dynamic]Plugin_Editor, // plug-ins' own windows open
	about:    About_State,
	fake_interface: bool, // --fake-interface: the simulated driver has `fake_interfaces`
	control_size:   Control_Size, // --control-size: the size controls are this run, whatever Settings says (Auto: as Settings says)
	audio_fallback: bool, // the interface in the settings wasn't there at the start: the system's plays
	plugin_pad: Plugin_Pad_Ui,
	proj:     Project_State,
	detail:   Detail_State,
	transport: Transport_State, // the toolbar's
	perf_hold: bool, // performance effects latch
	perf_held, perf_latched: [pm.PERF_FX]bool,
	seen:     [pm.PADS]u32, // pm.struck as last seen (to light pads the sequencer plays)
	fake_due: f64, // frames the simulated device owes (it runs as the frames go by)
}

main :: proc() {
	ui.crash_install()
	context.assertion_failure_proc = ui.crash_assertion
	project, drive, out, headless, fake, profile, prefs := "", "", ".build/app/shots", false, false, 0, ""
	fake_interface := false
	control_size := Control_Size.Auto
	control := -1
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
		case "--prefs":    prefs = next(&i)
		case "--control":  control = strconv.parse_int(next(&i)) or_else 0
		case "--control-size": control_size = control_size_parse(next(&i)) // (tests: the size their positions were written for)
		case "--fake-interface": fake_interface = true // (tests: a simulated 8-in/8-out interface beside the 2-in/2-out one)
		case "--version":
			fmt.println("Pads", version_text())
			os.exit(0)
		case:
			fmt.eprintln("pads: unknown option", os.args[i])
			os.exit(2)
		}
	}
	a := new(App)
	a.fake_interface = fake_interface
	a.control_size = control_size
	a.dark, a.pad_waves = true, true
	a.io.by_select = -1
	a.sample_holding = -1
	a.peaks = make(map[app.Id][]ui.Peak)
	defer {
		for _, p in a.peaks do delete(p)
		delete(a.peaks)
		take_peaks_clear(a)
		delete(a.take_peaks)
		browser_view_destroy(&a.bview)
		delete(a.auto_rec.points)
	}
	a.prefs = prefs
	// The settings first: the device, the look, the last project.
	settings_load(a)
	{ // Every message to a log file as well (the one before kept beside it).
		lp, _ := filepath.join({settings_folder(a), "pads.log"})
		ui.log_open(&a.ws.toasts, lp)
	}
	defer settings_destroy(&a.settings)
	recent_load(a)
	if project == "" && a.settings.open_last && len(a.proj.recent) > 0 do project = a.proj.recent[0]
	untitled := project == "" // a new project in the temporary folder, until it is saved somewhere
	if project == "" {
		dir, _ := os.make_directory_temp("", "Untitled.pads", context.allocator)
		project = dir
	}
	p := &a.platform
	layout := ""
	// (layout2.ini: the panels as they are since the Library and the bottom
	// area; a layout.ini from before has panels that are gone.)
	if a.settings.layout do layout, _ = filepath.join({settings_folder(a), "layout2.ini"})
	if !ui.platform_init(p, {title = "Pads", width = 1440, height = 900, headless = headless, vsync = profile == 0, ini_path = layout}) {
		ui.platform_destroy(p)
		os.exit(1)
	}
	defer ui.platform_destroy(p)
	appearance_apply(a)
	p.confirm_quit = true // (closing asks to save first: draw_leave)
	app.bus_init(&a.bus)
	defer app.bus_destroy(&a.bus)
	if !open_engine(a, fake) {
		fmt.eprintln("pads: no audio device; using the simulated one")
		if !open_engine(a, true) {
			fmt.eprintln("pads: could not open even the simulated audio device")
			os.exit(1)
		}
	}
	defer app.host_destroy(&a.host)
	if pm.model_init(&a.m, &a.host, project, &a.bus) != .None {
		fmt.eprintln("pads: could not start the engine")
		os.exit(1)
	}
	outputs_apply(a)
	defer pm.model_destroy(&a.m)
	defer pm.capture_destroy(&a.capture)
	defer project_state_destroy(&a.proj)
	// A project folder with a project in it opens; otherwise it is a new one
	// (with what the settings say a new one starts with).
	a.proj.settings = {rate = 48_000, encoding = .Int24, tail = 1}
	project_defaults_apply(a)
	if f, _ := filepath.join({project, pm.PROJECT_FILE}, context.temp_allocator); os.exists(f) {
		if pm.model_load(&a.m, project) != .None do fmt.eprintln("pads: could not open", project)
		else do view_restore(a)
	} else {
		pm.model_new(&a.m, project)
	}
	a.proj.untitled = untitled
	a.proj.last_save = time.tick_now()
	a.proj.last_backup = time.tick_now()
	// Stopped last time without closing: its backup, offered.
	if drive == "" {
		if crashed := session_crashed(a); crashed != "" do a.leave.recover = strings.clone(crashed)
		session_mark(a)
	}
	sync_apply(a)
	defer plugin_choice_clear(&a.plugin_choice)
	a.seq.selected, a.seq.grid = -1, .Sixteenth
	app.subscribe(&a.bus, app.Host_Engine_Changed, proc(user: rawptr, e: ^app.Host_Engine_Changed) {
		a := (^App)(user)
		pm.record_forget(&a.rec) // (its recorders were the old graph's)
		a.sample_holding = -1
		pm.engine_rebuild(&a.m.engine)
		sync_apply(a) // (the clock out and what it follows: on the new clock)
	}, a)
	app.subscribe(&a.bus, app.Host_Event, proc(user: rawptr, e: ^app.Host_Event) {
		if e.kind == .Devices do on_devices_changed((^App)(user))
	}, a)
	setup_actions(a)
	keys_apply(a)
	subscribe_settings(a)
	subscribe_imports(a)
	subscribe_project(a)
	setup_workspace(a)
	install_knob_hooks(a)
	defer ui.workspace_destroy(&a.ws)
	a.bview.renaming = -1
	a.song_ui.time.marker_drag, a.song_ui.time.point_drag = -1, -1
	pm.browser_init(&a.browser, favorites_path(a))
	defer pm.browser_destroy(&a.browser)
	plugins_load(a)
	defer plugins_destroy(&a.plugins)
	defer editors_close_all(a) // (before the plug-ins go)

	if control >= 0 {
		// Live: commands from a harness, through a driver with no script of
		// its own (the app runs as usual between them).
		if !ui.control_open(&a.control, control) do os.exit(1)
		ui.driver_init(&a.driver, "", out)
		a.driver.live = true
		a.driver.command = drive_command
		a.driver.user = a
		p.driver, p.control = &a.driver, &a.control
		if headless do p.fixed_dt = 1.0 / 60
		ui.probe_on(true)
		fmt.printfln("control: listening on 127.0.0.1:%d", a.control.port)
		os.flush(os.stdout)
	}
	defer if control >= 0 do ui.control_close(&a.control)
	if drive != "" {
		if !ui.driver_load(&a.driver, drive, out) do os.exit(1)
		ui.probe_on(true)
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
	// Leaving (asked first, when there were changes): a clean exit.
	if drive == "" do session_unmark(a)
	if drive != "" {
		for s in a.driver.shots do fmt.println("screenshot:", s)
		if a.driver.failed do os.exit(1)
	}
}

// Opens the audio device (the fake one if asked), with inputs for
// recording when the device has them.
open_engine :: proc(a: ^App, fake: bool) -> bool {
	// The devices the settings name, then (when they are gone: unplugged)
	// the system's default ones; each with its inputs, then without. The
	// simulated device has no devices to name.
	named := a.settings.audio.output != "" || a.settings.audio.input != ""
	for default_devices in ([]bool{fake, true}) {
		if default_devices && !fake && !named do continue // (the first pass was already the default ones)
		for with_inputs in ([]bool{true, false}) {
			settings := host_settings(a, fake)
			if !with_inputs do settings.input_channels, settings.inputs = {}, 0
			// (The simulated driver knows only its own devices.)
			if default_devices || (fake && !strings.has_prefix(settings.output_device, "fake:")) do settings.output_device, settings.input_device = "", ""
			if a.host.driver != nil do app.host_destroy(&a.host)
			if app.host_init(&a.host, settings, &a.bus) != .None do continue
			if app.host_open(&a.host) == .None {
				if default_devices && !fake && named {
					fmt.eprintln("pads: the audio device in the settings is not there; using the system's")
					a.audio_fallback = true // (switched back when it is: on_devices_changed)
				}
				return true
			}
		}
		if fake do break
	}
	return false
}

// One frame: events, the engine, then the UI.
frame :: proc(a: ^App) {
	app.dispatch(&a.bus)
	app.host_update(&a.host)
	run_fake(a)
	handle_drops(a)
	update_meters(a)
	if a.settings.recording == "" do ui.handle_shortcuts(&a.actions) // (not while a new shortcut is pressed)
	if a.settings.recording == "" do play_keys(a)
	if a.settings.recording == "" do pad_arrows(a)
	plugins_scan_step(a)
	track_io_frame(a)
	// Which editor has the keyboard: the one drawn focused this frame says
	// so (a hidden one keeps none).
	a.seq.focused, a.song_ui.focused = false, false
	a.browser_has_keys = false
	// How the app is left goes with the project when it saves.
	a.m.project.view = {play_mode = a.play_mode, keys = a.keys, bank = a.bank, selected = a.selected, seq_bank = a.perf.win_row / 4, seq_lane0 = a.perf.win_lane, seq_row0 = a.perf.win_row, seq_keys = a.perf.seq_keys, seq_mode = a.seq.mode}
	a.ws.bottom_folded_h = im.GetFrameHeight() + 2 * im.GetStyle().WindowPadding.y
	ui.workspace_draw(&a.ws, &a.actions, draw_menu, a)
	fold_pads_check(a)
	draw_plugin_choice(a)
	draw_wave_editor(a)
	draw_preset_save(a)
	draw_leave(a)
	draw_template_save(a)
	draw_about(a)
	draw_export(a)
	draw_settings(a)
	draw_rename_project(a)
	draw_seq_dialogs(a)
	project_frame(a)
	pm.sync(&a.m.engine)
	pm.plugins_idle(&a.m)
	editors_frame(a)
	pm.capture_poll(&a.m, &a.capture)
	// A MIDI pad pressed while the Sample control is armed records into it
	// (and its release stops it); the note itself played already.
	for t in a.capture.midi_presses {
		if t.on do sample_press(a, int(t.pad), false)
		else do sample_release(a, int(t.pad))
	}
	pm.launch_record_poll(&a.m)
	if a.host.opened do pm.record_prepare(&a.m, &a.rec, a.selected) // (ready before a press: no take loses its start)
	if pm.record_poll(&a.m, &a.rec) do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Recorded onto %s", pm.pad_label(a.rec.pad)))
	dt := im.GetIO().DeltaTime
	for &l in a.lit do l = max(l - dt, 0)
	for i in 0 ..< pm.PADS {
		n := pm.struck(&a.m.engine, i)
		if n != a.seen[i] do a.lit[i] = 0.12
		a.seen[i] = n
		if i == a.audition_off.pad && a.audition_off.frames > 0 {
			a.audition_off.frames -= 1
			if a.audition_off.frames == 0 do pm.hit(&a.m.engine, i, false, pitch = i8(a.audition_off.pitch), keyboard = true)
		}
		if a.release_at[i] > 0 {
			a.release_at[i] -= 1
			if a.release_at[i] == 0 do pm.hit(&a.m.engine, i, false)
		}
	}
	a.frame += 1
}

// The simulated device runs on the UI thread (manual mode): give it the
// callbacks this frame's time is worth, so --fake plays in real time, and
// a drive script (fixed 1/60 s frames) the same way every run.
run_fake :: proc(a: ^App) {
	if app.host_fake(&a.host) == nil || !a.host.running do return
	f := a.host.format
	if f.buffer_frames <= 0 do return
	a.fake_due += f64(im.GetIO().DeltaTime) * f.sample_rate
	n := int(a.fake_due) / f.buffer_frames
	if n > 0 {
		app.host_fake_run(&a.host, n)
		a.fake_due -= f64(n * f.buffer_frames)
	}
}

// Plays pad `index` (from the mouse, a key or a script). In keyboard and
// velocity modes the pad's place in the grid says how to play the
// selected pad instead.
press :: proc(a: ^App, index: int, velocity: f32 = 1) {
	if a.play_mode == .Pads && sample_press(a, index, im.GetIO().KeyAlt) do return // (recording into it instead of playing it)
	k := index % pm.PADS_PER_BANK
	g := &a.grid_held[k]
	if g.on do release(a, index)
	switch a.play_mode {
	case .Pads:
		a.selected = index
		g^ = {on = true, pad = index}
		if pad := a.m.project.pads[index]; pad.sample != 0 || pad.kind == .Synth do pm.hit(&a.m.engine, index, true, velocity) // (a synth needs no sample)
	case .Keyboard:
		pitches: [4]int
		ps := keyboard_notes(a, k, &pitches)
		if !keyboard_in_range(ps) do break // (past what a pad can be pitched to: silent)
		g^ = {on = true, pad = a.selected, keyboard = true, count = len(ps)}
		for p, i in ps {
			g.pitches[i] = i8(clamp(p, -48, 48))
			pm.hit(&a.m.engine, a.selected, true, velocity, g.pitches[i], keyboard = true)
		}
	case .Velocity:
		g^ = {on = true, pad = a.selected}
		pm.hit(&a.m.engine, a.selected, true, pm.velocity_of_pad(k))
	}
	a.lit[a.bank * pm.PADS_PER_BANK + k] = 0.18
	a.held[index] = true
}

// The pitches (from the target pad's own) pad `k` of the grid plays in
// Keyboard mode: the scale's degrees from the bank's start (bank A the
// first 16 from the root, B the next 16...), or for a slicer its slice.
keyboard_notes :: proc(a: ^App, k: int, out: ^[4]int) -> []int {
	degree := a.bank * pm.PADS_PER_BANK + k - keyboard_bottom(a)
	if a.m.project.pads[a.selected].kind == .Slicer {
		out[0] = degree
		return out[:1]
	}
	return pm.keyboard_pitches(a.keys, degree, out)
}

// Keyboard mode's degrees below the pad's own note that bank A's first pad
// starts at: the root five octaves down (the bottom of the MIDI range,
// whatever the octave set). A slicer's keys start at its first slice.
keyboard_bottom :: proc(a: ^App) -> int {
	if a.m.project.pads[a.selected].kind == .Slicer do return 0
	n := pm.scale_size(a.keys.scale)
	return n * (5 + a.keys.octave)
}

// The bank Keyboard mode opens on: the one holding the pad's own note.
keyboard_home_bank :: proc(a: ^App) -> int {
	return clamp(keyboard_bottom(a) / pm.PADS_PER_BANK, 0, pm.PADS / pm.PADS_PER_BANK - 1)
}

// Whether every pitch can be played: the MIDI range (the pad's own note
// is key 60).
keyboard_in_range :: proc(ps: []int) -> bool {
	for p in ps do if p < -60 || p > 67 do return false
	return len(ps) > 0
}

// Releases pad `index` (what its press played).
release :: proc(a: ^App, index: int) {
	sample_release(a, index)
	k := index % pm.PADS_PER_BANK
	g := &a.grid_held[k]
	a.held[index] = false
	if !g.on do return
	g.on = false
	if g.keyboard {
		for p in g.pitches[:g.count] do pm.hit(&a.m.engine, g.pad, false, 0, p, keyboard = true)
	} else {
		pm.hit(&a.m.engine, g.pad, false)
	}
}

// What a press of a grid pad played, to release it.
Grid_Held :: struct {
	on:       bool,
	pad:      int,
	keyboard: bool,
	pitches:  [4]i8,
	count:    int,
}

// The computer keyboard as the 4×4 pad grid, pad 1 first: the bottom row
// (Z X C V) is pads 1–4, the top row (1 2 3 4) pads 13–16, as they sit.
PAD_KEYS := [16]im.Key{.Z, .X, .C, .V, .A, .S, .D, .F, .Q, .W, .E, .R, ._1, ._2, ._3, ._4}

play_keys :: proc(a: ^App) {
	io := im.GetIO()
	if io.WantTextInput || io.KeyCtrl || io.KeySuper || io.KeyAlt do return
	if a.perf.seq_keys { // the sequence pads' Keys switch: the keys play them
		for k, i in PAD_KEYS {
			// (The launcher's window: the bottom row Z X C V, each a lane.)
			slot, _, _, _ := window_cell(a, i % 4, i / 4)
			if slot < 0 do continue
			if im.IsKeyPressed(k, false) do seq_pad_press(a, slot, true)
			if im.IsKeyReleased(k) do seq_pad_release(a, slot)
		}
		return
	}
	for k, i in PAD_KEYS {
		index := a.bank * pm.PADS_PER_BANK + i
		if im.IsKeyPressed(k, false) do press(a, index, 0.85)
		if im.IsKeyReleased(k) do release(a, index)
	}
}

// The arrow keys move the selection between pads: Left and Right the
// previous and next, Up and Down the pad above and below in the grid (on
// to the next bank at its edge). Not while a text field, the browser's
// list or the piano roll's selected notes have them; in the sequence
// editor (no notes selected) Up and Down step to the next row's pad.
pad_arrows :: proc(a: ^App) {
	io := im.GetIO()
	if io.WantTextInput || io.KeyCtrl || io.KeySuper || io.KeyAlt || a.browser_has_keys do return
	if a.seq.focused && len(a.seq.sel) > 0 do return
	step := 0
	if im.IsKeyPressed(.LeftArrow) do step = -1
	if im.IsKeyPressed(.RightArrow) do step = 1
	up, down := im.IsKeyPressed(.UpArrow), im.IsKeyPressed(.DownArrow)
	if a.seq.focused {
		if up do step = 1
		if down do step = -1
	} else {
		if up do step = 4
		if down do step = -4
	}
	if step == 0 do return
	i := (a.selected + step + pm.PADS) % pm.PADS
	a.selected = i
	if a.play_mode != .Keyboard do a.bank = i / pm.PADS_PER_BANK // (Keyboard mode's banks are notes)
	show_pad_chain(a, i)
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
		if drop_midi(a, d.path, index) do continue
		if index < 0 do index = a.selected
		if pm.load_onto_pad(&a.m, index, d.path) == .None {
			a.selected = index
			ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Loaded %s onto %s", filepath.base(d.path), pm.pad_label(index)))
		} else {
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", filepath.base(d.path)))
		}
	}
}

// Puts the app as the project was left (after opening one).
view_restore :: proc(a: ^App) {
	v := a.m.project.view
	a.play_mode, a.keys, a.bank, a.selected, a.perf.win_lane, a.perf.win_row, a.perf.seq_keys = v.play_mode, v.keys, v.bank, v.selected, v.seq_lane0, v.seq_row0, v.seq_keys
	a.seq.mode = v.seq_mode
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

// A pad pressed (on the grid in Pads mode, or by MIDI): recorded into
// instead of played when Option/Alt is held (`alt`, Hold) or the Sample
// control is armed (its method; it disarms). True when it is recording (or
// tried to).
sample_press :: proc(a: ^App, index: int, alt: bool) -> bool {
	method: pm.Sampling
	switch {
	case alt:
		method = .Hold
	case a.sample_armed && a.settings.sample_method != .Hold:
		method = a.settings.sample_method
		a.sample_armed = false
	case:
		return false
	}
	s := &a.settings
	if pm.record_start(&a.m, &a.rec, index, method, s.sample_threshold_db, s.sample_bars) != .None {
		ui.toast(&a.ws.toasts, .Warning, "No audio input to record from")
		return true
	}
	a.selected = index
	a.pad_sel, a.pad_anchor = {index}, index
	show_pad_chain(a, index)
	a.sample_holding = index if method != .Bars else -1 // (Bars stop by themselves)
	return true
}

// A pad let go: the sample being recorded into it while held stops.
sample_release :: proc(a: ^App, index: int) {
	if a.sample_holding != index || index < 0 do return
	pm.record_stop(&a.rec)
	a.sample_holding = -1
}
