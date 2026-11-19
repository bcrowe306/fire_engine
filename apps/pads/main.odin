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
	--virtual-push2  Push 2 on the screen, played with the mouse (View > Push 2 on Screen):
	               Pads' own when none is plugged in
	--no-start-page  no project manager at start or after New Project (tests; --drive never shows it)
	--profile N    draw N frames as fast as possible and print the CPU time per frame
	               (after the drive script, if one is given: profile a loaded project)
	--trace FILE   record a Spall trace of the run into FILE (a build with
	               -define:FIRE_PROF=true: task app:pads PROF=1); see docs/guides/profiling.md
*/
package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:time"

import "fire:midi"
import mfake "fire:midi/fake"
import "fire:prof"

import app "app:core"
import "app:devices"
import "app:ui"
import pa "api"
import push2 "surfaces/push2"
import pc "core"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"

App :: struct {
	using core: pc.Core, // the model and the app's state without the window (bus, host, m, capture, transport)
	api:      pa.Api,   // what the UI, the scripts and surfaces act through (apps/pads/api)
	platform: ui.Platform,
	driver:   ui.Driver,
	actions:  ui.Actions,
	ws:       ui.Workspace,
	dark:     bool,
	lit:      [pm.PADS]f32, // seconds a pad stays lit after a hit
	held:     [pm.PADS]bool,
	sample_armed:   bool, // the Sample control is on: the next pad pressed records (Arm, Threshold, Bars)
	sample_latched: bool, // ... and stays on after each take (Ctrl- or Cmd-click it)
	wave:     Wave_State,
	view_wave: Wave_State, // the device view's (a controller's display): its own zoom
	ctl:      Ctl_State, // the device panel on a controller (ui_ctl.odin)
	dialog:   Dialog_Mirror, // the dialog showing, for a controller (ui_dialog.odin)
	device:   Device_State, // the device tabs' LFO traces
	seq_ops:  Seq_Ops, // renaming, copying bars, the copied part
	spectrum: Spectrum_State, // an effect's spectrum, drawn on its device
	sf_curve: Sf_Curve,       // SuperFilter's response, measured (ui_superfilter.odin)
	sf_more:  bool,           // its LFO's extras shown
	sf_key:   bool,           // its sidechain's row shown (always, while it has a key or its filters)
	pe:       Pe_Ui,          // ProEq's panel: the band selected, the set edited, Audition (ui_proeq.odin)
	pc:       Pc_Ui,          // ProComp's panel: its view, its sidechain row, the meters' held peaks (ui_procomp.odin)
	ps:       Ps_Ui,          // ProSaturator's panel: the meters' held peaks (ui_prosaturator.odin)
	pv:       Pv_Ui,          // ProVerb's panel: its page, its focus, its decay picture (ui_proverb.odin)
	song_ui:  Song_State, // the Song tab's selected step, renaming
	commands: [dynamic]Command, // everything that can be done to something (commands.odin)
	pad_clip: pm.Pad, // a copied pad
	has_pad_clip: bool,
	slot_clip: pm.Effect_Slot, // a copied effect
	has_slot_clip: bool,
	release_at: [pm.PADS]int, // frames until a pad a command played lets go
	audition_off: struct { pad, pitch, frames: int }, // a pitched audition to let go
	voice_edit: pm.Voice, // a copy of the selected pad's voice the knobs point into
	bview:    Browser_View,
	lib:      Lib_State, // the Library's category, selections, last load (ui_library.odin)
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
	wte:       Wave_Editor,  // the wavetable editor's window
	presets:   Preset_Ui,    // the synth's Save Preset dialog
	leave:     Leave_State,
	template:  Template_Ui, // the Save as Template dialog
	cleanup:   Cleanup_Ui,  // the Clean Up Project dialog
	live_audio: [pm.PADS][dynamic]Live_Peak, // audio tracks' input as it is recorded (see `live_audio_frame`)
	status:    Status_State, // the status bar's lights and load  // leaving a project with changes: the prompt; a crash's backup to offer
	param_host: Param_Host,  // where the synth's controls point (a synth pad, or an effect slot)
	synth_ui:  Synth_Ui,     // the synth page's tab, oscillator, envelope, LFO
	seq:      Seq_State,
	take_peaks: map[string]Peaks, // takes' waveforms, for the Audio tab and the rows (by path)
	pad_rects: [pm.PADS_PER_BANK][2]im.Vec2, // where this bank's pads were drawn (for drops)
	pad_sel:  Pad_Set, // pads selected together (Shift: a range, Cmd: one more); see `selected_pads`
	pad_anchor: int,   // where a Shift-click range starts
	frame:    int,
	browser_has_keys: bool, // the browser's list had the keyboard last frame (its arrows)
	grid_held: [pm.PADS_PER_BANK]Grid_Held,
	perf:     Perf_State,
	mixer:    Mixer_State,
	fx:       pm.Fx_Target, // the effect slot the Effects tab edits
	plugin_choice: Plugin_Choice,
	editors:  [dynamic]Plugin_Editor, // plug-ins' own windows open
	about:    About_State,
	fake_interface: bool, // --fake-interface: the simulated driver has `fake_interfaces`
	fake_midi: ^midi.Driver, // --fake-midi: pretend MIDI ports (tests plug controllers into it: `midiport`)
	fake_usb: ^app.Device_Driver, // --fake-usb: pretend USB and HID devices (`usbdev`); else nil
	surfaces_page: Surfaces_Page, // Settings > Control Surfaces (ui_surfaces.odin)
	push_window: Push_Window, // View > Push 2 on Screen (ui_push_window.odin)
	start:     Start_Page,    // the project manager (ui_start.odin)
	controls:  Controls_Ui,   // dialogs a controller's buttons open (ui_controls.odin)
	views:    [dynamic]^View_Draw, // Pads' views drawn for surfaces' displays (ui_views.odin)
	surface_monitor: bool, // its MIDI monitor records
	control_size:   Control_Size, // --control-size: the size controls are this run, whatever Settings says (Auto: as Settings says)
	audio_fallback: bool, // the interface in the settings wasn't there at the start: the system's plays
	plugin_pad: Plugin_Pad_Ui,
	proj:     Project_State,
	detail:   Detail_State,
	toolbar:  Toolbar_State, // the transport toolbar's rows
	seen:     [pm.PADS]u32, // pm.struck as last seen (to light pads the sequencer plays)
	fake_due: f64, // frames the simulated device owes (it runs as the frames go by)
}

main :: proc() {
	ui.crash_install()
	context.assertion_failure_proc = ui.crash_assertion
	project, drive, out, headless, fake, profile, prefs := "", "", ".build/app/shots", false, false, 0, ""
	trace := ""
	fake_interface := false
	control_size := Control_Size.Auto
	control := -1
	surfaces: [dynamic]string // --surface PATH: control-surface libraries to load
	defer delete(surfaces)
	surface_dev, fake_midi, fake_usb, virtual_push2 := false, false, false, false
	start_page := true
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
		case "--trace":    trace = next(&i)
		case "--prefs":    prefs = next(&i)
		case "--control":  control = strconv.parse_int(next(&i)) or_else 0
		case "--surface":  append(&surfaces, next(&i))
		case "--surface-dev": surface_dev = true // (a surface's author: rebuilt libraries load again)
		case "--fake-midi": fake_midi = true // (tests: MIDI ports of pretend controllers, plugged in by `midiport`)
		case "--fake-usb": fake_usb = true // (tests: pretend USB and HID devices, plugged in by `usbdev`)
		case "--control-size": control_size = control_size_parse(next(&i)) // (tests: the size their positions were written for)
		case "--no-start-page": start_page = false
		case "--virtual-push2": virtual_push2 = true // Push 2 on the screen (View > Push 2 on Screen)
		case "--fake-interface": fake_interface = true // (tests: a simulated 8-in/8-out interface beside the 2-in/2-out one)
		case "--version":
			fmt.println("Pads", version_text())
			os.exit(0)
		case:
			fmt.eprintln("pads: unknown option", os.args[i])
			os.exit(2)
		}
	}
	// (Stopped last of all: after the audio device has closed.)
	if trace != "" {
		if !prof.ENABLED do fmt.eprintln("pads: --trace needs a build with -define:FIRE_PROF=true (task app:pads PROF=1)")
		else if !prof.start(trace) do fmt.eprintln("pads: could not make", trace)
		else do prof.thread_name("main")
	}
	defer prof.stop()
	a := new(App)
	a.fake_interface = fake_interface
	if fake_midi do a.fake_midi = mfake.create()
	a.surfaces_page = {assign_lib = -1, virtual = -1}
	defer {
		delete(a.surfaces_page.assign_in)
		delete(a.surfaces_page.assign_out)
		delete(a.surfaces_page.log_surface)
	}
	defer if a.fake_midi != nil do midi.driver_destroy(a.fake_midi)
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
	// A run with its own preferences (a test) keeps out of the user's Trash.
	if a.prefs != "" {
		trash, _ := filepath.join({a.prefs, "Trash"}, context.temp_allocator)
		app.trash_redirect(trash)
	}
	files_init(a)
	defer pc.files_destroy(&a.files)
	pc.recent_load(&a.core)
	if project == "" && a.settings.open_last && len(a.files.recent) > 0 do project = a.files.recent[0]
	untitled := project == "" // a new project in the unsaved folder, until it is saved somewhere
	if project == "" {
		// (A script without --prefs: the system's temporary folder, not the
		// user's unsaved projects.)
		if drive != "" && a.prefs == "" {
			dir, _ := os.make_directory_temp("", "Untitled.pads", context.allocator)
			project = dir
		} else do project = pc.unsaved_new(&a.core)
	}
	p := &a.platform
	layout := ""
	// (layout2.ini: the panels as they are since the Library and the bottom
	// area; a layout.ini from before has panels that are gone.)
	if a.settings.layout do layout, _ = filepath.join({settings_folder(a), "layout2.ini"})
	if !ui.platform_init(p, {title = "Pads", width = 1440, height = 900, headless = headless, draw_unseen = profile > 0, vsync = profile == 0, ini_path = layout}) {
		ui.platform_destroy(p)
		os.exit(1)
	}
	defer ui.platform_destroy(p)
	defer views_destroy(a) // (before the platform: their GPU textures)
	defer push_window_destroy(a) // (its display's picture: before the platform too)
	defer virtual_play_destroy(&a.surfaces_page.play)
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
	pa.api_init(&a.api, &a.core)
	defer pa.api_destroy(&a.api)
	settings_register(a)
	defer pc.settings_destroy(&a.core)
	defer pc.launch_destroy(&a.core)
	// (After the model is gone, its files let go: an unsaved project left
	// without saving.)
	defer if a.files.discard != "" && pc.is_unsaved(&a.core, a.files.discard) do os.remove_all(a.files.discard)
	defer pm.model_destroy(&a.m)
	// Control surfaces (fire-surface): the libraries in Pads' Surfaces
	// folder, FSURF_PATH and the system's, and --surface's; each gets the API
	// as "fire.pads" 1 and fsurf.daw. Stopped before the model goes.
	// Their USB and HID devices (a display's): libusb and hidapi, or pretend
	// ones (--fake-usb). Freed after the surfaces stop.
	if fake_usb do a.fake_usb = app.devices_fake_create()
	drivers := a.fake_usb if fake_usb else devices.create()
	defer drivers.destroy(drivers)
	{
		folder, _ := filepath.join({settings_folder(a), "Surfaces"}, context.temp_allocator)
		pa.surfaces_start(&a.api, {folder}, watch = surface_dev, devices = drivers)
		// Pads' own Push 2 surface, built in (apps/pads/surfaces/push2).
		app.surfaces_add_static(&a.api.surfaces, &push2.fsurf_entry, "Push 2 (built in)")
	}
	defer pa.surfaces_stop(&a.api)
	push_window_listen(a) // (Push 2's palette, as the surface sets it: its lights on the screen)
	a.push_window.open = virtual_push2
	for path in surfaces do if _, r := pa.surface_load(&a.api, path); r != .Ok {
		why, _ := pa.last_error(&a.api)
		fmt.eprintfln("pads: --surface %s: %s", path, why)
	}
	defer pm.capture_destroy(&a.capture)
	defer project_state_destroy(&a.proj)
	defer pm.export_destroy(&a.job.export)
	// A project folder with a project in it opens; otherwise it is a new one
	// (with what the settings say a new one starts with).
	a.proj.settings = {rate = 48_000, encoding = .Int24, tail = 1}
	project_defaults_apply(a)
	if f, _ := filepath.join({project, pm.PROJECT_FILE}, context.temp_allocator); os.exists(f) {
		if pm.model_load(&a.m, project) != .None do fmt.eprintln("pads: could not open", project) // api-lint: the project Pads starts with, before its first frame
		else do view_restore(a)
	} else {
		pm.model_new(&a.m, project) // api-lint: the project Pads starts with
	}
	pa.transport_set_metronome(&a.api, true) // (the click on; a new project's clicks only while recording: see Project_Defaults.recording)
	a.files.untitled = untitled
	a.start.off = !start_page || drive != ""
	if untitled && !a.start.off do start_page_show(a) // (no project to open: the project manager)
	a.files.last_save = time.tick_now()
	a.files.last_backup = time.tick_now()
	// Stopped last time without closing: its backup, offered.
	if drive == "" {
		if crashed := pc.session_crashed(&a.core); crashed != "" do a.leave.recover = strings.clone(crashed)
		pc.session_mark(&a.core)
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
		a.control.json, a.control.json_user = proc(user: rawptr, line: string, out: ^strings.Builder) { pa.remote_call(&(^App)(user).api, line, out) }, a
		// (A client's subscriptions: its events pushed between answers, dropped when it leaves.)
		a.control.connected = proc(user: rawptr, on: bool) {
			a := (^App)(user)
			if on do pa.remote_connect(&a.api, proc(user: rawptr, line: string) { ui.control_push(&(^App)(user).control, line) }, a)
			else do pa.remote_disconnect(&a.api)
		}
		p.driver, p.control = &a.driver, &a.control
		// Every frame 1/60 s, in a window too: a harness counts time in
		// frames ("wait 25", a click's frames), and a window's frames come
		// at the display's rate (120 a second on a ProMotion display, more
		// without vsync), which made taps twice as fast and double-clicks
		// out of time. Headless, frames go by only while a command runs (a
		// test's frames are the ones it asked for, however busy the machine).
		p.fixed_dt = 1.0 / 60
		if headless do a.control.lockstep = true
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
			dialog_frame(a)
			views_render(a) // (between frames: their own ImGui context)
		}
	}
	if profile > 0 {
		// After a drive script, if there was one: the state it left.
		p.running, p.driver, p.fixed_dt = true, nil, 0
		run_profile(a, profile)
	}
	// Leaving (asked first, when there were changes): a clean exit.
	if drive == "" do pc.session_unmark(&a.core)
	if drive != "" {
		for s in a.driver.shots do fmt.println("screenshot:", s)
		if a.driver.failed do os.exit(1)
		if ui.probe_conflicts_seen > 0 { // (said on stderr as they came: "imgui: conflicting ID")
			fmt.eprintfln("%d ImGui ID conflict(s)", ui.probe_conflicts_seen)
			os.exit(1)
		}
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
	prof.zone("frame")
	prof.begin("api_frame")
	pa.api_frame(&a.api, f64(im.GetIO().DeltaTime)) // (posted calls, what is due, subscribers told)
	prof.end()
	app.dispatch(&a.bus)
	prof.begin("host_update")
	app.host_update(&a.host)
	prof.end()
	prof.begin("fake audio")
	run_fake(a)
	prof.end()
	handle_drops(a)
	update_meters(a)
	if a.settings.recording == "" do ui.handle_shortcuts(&a.actions) // (not while a new shortcut is pressed)
	if a.settings.recording == "" do play_keys(a)
	pc.launch_frame(&a.core) // (Hold: the sequence pads let go, once their launch has come)
	if a.settings.recording == "" do pad_arrows(a)
	plugins_scan_step(a)
	track_io_frame(a)
	// Which editor has the keyboard: the one drawn focused this frame says
	// so (a hidden one keeps none).
	a.seq.focused, a.song_ui.focused = false, false
	a.browser_has_keys = false
	// How the app is left goes with the project when it saves.
	a.m.project.view = {play_mode = a.play_mode, keys = a.keys, bank = a.bank, selected = a.selected, seq_bank = a.launch.win_row / 4, seq_lane0 = a.launch.win_lane, seq_row0 = a.launch.win_row, seq_keys = a.launch.seq_keys, seq_mode = a.seq.mode}
	a.ws.bottom_folded_h = im.GetFrameHeight() + 2 * im.GetStyle().WindowPadding.y
	prof.begin("workspace")
	ui.workspace_draw(&a.ws, &a.actions, draw_menu, a)
	prof.end()
	fold_pads_check(a)
	draw_plugin_choice(a)
	draw_wave_editor(a)
	draw_preset_save(a)
	draw_leave(a)
	draw_template_save(a)
	draw_cleanup(a)
	draw_lib_save_as(a)
	draw_about(a)
	draw_export(a)
	draw_settings(a)
	draw_rename_project(a)
	draw_seq_dialogs(a)
	draw_start_page(a)
	draw_start_dialogs(a)
	draw_length_dialog(a)
	draw_quantize_dialog(a)
	draw_convert_dialog(a)
	draw_scale_dialog(a)
	draw_recording_dialog(a)
	draw_transport_dialog(a)
	draw_repeat_dialog(a)
	draw_push_window(a)
	draw_sequence_dialog(a)
	draw_lane_dialog(a)
	prof.begin("project_frame")
	project_frame(a)
	prof.end()
	prof.begin("sync")
	pm.sync(&a.m.engine)
	prof.end()
	pm.plugins_idle(&a.m)
	prof.begin("editors_frame")
	editors_frame(a)
	prof.end()
	pm.capture_poll(&a.m, &a.capture)
	live_audio_frame(a)
	// A MIDI pad pressed while the Sample control is armed records into it
	// (and its release stops it); the note itself played already.
	for t in a.capture.midi_presses {
		if t.on do sample_press(a, int(t.pad), false)
		else do sample_release(a, int(t.pad))
	}
	pm.launch_record_poll(&a.m)
	if a.host.opened do pm.record_prepare(&a.m, &a.rec, a.selected) // (ready before a press: no take loses its start)
	pm.inputs_follow(&a.m) // (pads on a channel the interface hasn't: the next one it has)
	a.m.engine.sampling = a.rec.pad if a.rec.active else -1 // (a pad's input heard while sampling into it, on Auto)
	if pm.record_poll(&a.m, &a.rec) do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Recorded onto %s", pm.pad_label(a.rec.pad)))
	if a.rec.last_done {
		// What came in, when it isn't what was wanted: silence (the input,
		// or the system's microphone permission), or Threshold's level never reached.
		a.rec.last_done = false
		pad := a.rec.pad
		from := audio_in_text(a, pad) if pad >= 0 && pad < pm.PADS else "its input"
		switch {
		case a.rec.last_failed:
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Couldn't record onto %s: its file couldn't be written (the project's folder, or the disk)", pm.pad_label(pad)))
		case a.rec.last_peak_db < -90:
			why := ""
			#partial switch mic_access() {
			case .Denied: why = " — macOS isn't letting Pads use the microphone: allow it in System Settings > Privacy & Security > Microphone"
			case .Not_Asked, .Unknown: why = " — if a sound was there, macOS may be keeping the microphone from Pads: started from another app (a terminal, an editor), it's that app's permission. Allow that app in System Settings > Privacy & Security > Microphone, or start Pads as Pads.app"
			}
			ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("The sample on %s is silent: nothing came in on %s%s", pm.pad_label(pad), from, why))
		case a.rec.last_dropped:
			ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("Nothing kept: %s never reached %.0f dB (its loudest: %.0f dB). Lower the threshold in the Sample menu", from, a.settings.sample_threshold_db, a.rec.last_peak_db))
		}
	}
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
	return pc.keyboard_notes(&a.core, k, out)
}

// Keyboard mode's degrees below the pad's own note that bank A's first pad
// starts at: the root five octaves down (the bottom of the MIDI range,
// whatever the octave set). A slicer's keys start at its first slice.
keyboard_bottom :: proc(a: ^App) -> int {
	return pc.keyboard_bottom(&a.core)
}

// The bank Keyboard mode opens on: the one holding the pad's own note.
keyboard_home_bank :: proc(a: ^App) -> int {
	return pc.keyboard_home_bank(&a.core)
}

// Whether every pitch can be played: the MIDI range (the pad's own note
// is key 60).
keyboard_in_range :: proc(ps: []int) -> bool {
	return pc.keyboard_in_range(ps)
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
	// A sequence a key pressed: let go with it, whatever is held with it
	// and wherever the window is now (else Hold kept it playing).
	for k, i in PAD_KEYS do if a.perf.key_slot[i] > 0 && im.IsKeyReleased(k) {
		seq_pad_release(a, a.perf.key_slot[i] - 1)
		a.perf.key_slot[i] = 0
	}
	if io.WantTextInput || io.KeyCtrl || io.KeySuper || io.KeyAlt do return
	if a.launch.seq_keys { // the sequence pads' Keys switch: the keys play them
		for k, i in PAD_KEYS {
			// (The launcher's window: the bottom row Z X C V, each a lane.)
			slot, _, _, _ := window_cell(a, i % 4, i / 4)
			if slot < 0 do continue
			if im.IsKeyPressed(k, false) {
				seq_pad_press(a, slot, true)
				a.perf.key_slot[i] = slot + 1
			}
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
		if pa.pad_load_sample(&a.api, i64(index), d.path) == .Ok {
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
	a.play_mode, a.keys, a.bank, a.selected, a.launch.win_lane, a.launch.win_row, a.launch.seq_keys = v.play_mode, v.keys, v.bank, v.selected, v.seq_lane0, v.seq_row0, v.seq_keys
	a.seq.mode = v.seq_mode
}

// Where Pads keeps its own files (the core's `Folders`), and what the app
// does when the core opens a project.
files_init :: proc(a: ^App) {
	f := &a.files.folders
	f.settings = strings.clone(settings_folder(a))
	f.prefs = strings.clone(a.prefs if a.prefs != "" else settings_folder(a))
	_ = prefs_file(a, "recent.txt") // (kept elsewhere before settings.ini: brought over the first time)
	// New projects until saved: Music/Pads/Unsaved (with --prefs: in it, so
	// a test stays in its own), else beside the settings.
	// A quick save's untitled projects: Documents (with --prefs: in it).
	if a.prefs != "" do f.projects, _ = filepath.join({a.prefs, "Projects"})
	else if d := sdl.GetUserFolder(.DOCUMENTS); d != nil do f.projects = strings.clone(string(d))
	switch {
	case a.prefs != "":
		f.unsaved, _ = filepath.join({a.prefs, "Unsaved"})
	case:
		if d := sdl.GetUserFolder(.MUSIC); d != nil do f.unsaved, _ = filepath.join({string(d), "Pads", "Unsaved"})
		else do f.unsaved, _ = filepath.join({settings_folder(a), "Unsaved"})
	}
	a.hooks = {
		user = a,
		opened = project_opened,
		// A parameter touched through the API: its moves recorded as a knob's are.
		param_touched = proc(user: rawptr, t: pm.Auto_Target, on: bool) {
			a := (^App)(user)
			if on do record_touch(a, t)
			else do record_release(a)
		},
		release_held = proc(user: rawptr) {
			a := (^App)(user)
			for k in 0 ..< pm.PADS_PER_BANK do release(a, a.bank * pm.PADS_PER_BANK + k)
		},
		ui = {
			show = proc(user: rawptr, name: string) -> bool { return show_named((^App)(user), name) },
			dialog = dialog_hook,
			library_load = proc(user: rawptr, pad: int) -> bool { return lib_load_onto((^App)(user), pad) },
			start_page = proc(user: rawptr) -> bool { return (^App)(user).start.open },
			automation_armed = proc(user: rawptr) -> bool { return (^App)(user).auto_rec.armed },
			quantize = proc(user: rawptr) { quantize_now((^App)(user)) },
			sample_armed = proc(user: rawptr) -> bool { return (^App)(user).sample_armed },
			select_notes = proc(user: rawptr, indices: []int) {
				a := (^App)(user)
				s := pm.current_sequence(&a.m)
				clear(&a.seq.sel)
				for i in indices do append(&a.seq.sel, s.notes[i])
			},
			seq_grid = proc(user: rawptr) -> int { return int((^App)(user).seq.grid) },
			set_seq_grid = proc(user: rawptr, grid: int) { (^App)(user).seq.grid = pm.Grid(grid) },
			set_automation_armed = proc(user: rawptr, on: bool) {
				a := (^App)(user)
				a.auto_rec.armed = on
				if !on do record_release(a)
			},
			set_start_page = proc(user: rawptr, open: bool) {
				a := (^App)(user)
				if open do start_page_show(a)
				else do a.start.open = false
			},
			set_dark = proc(user: rawptr, dark: bool) { set_dark((^App)(user), dark) },
			dark = proc(user: rawptr) -> bool { return (^App)(user).dark },
			toast = proc(user: rawptr, kind: int, text: string) {
				kinds := [4]ui.Toast_Kind{.Info, .Success, .Warning, .Error}
				ui.toast(&(^App)(user).ws.toasts, kinds[clamp(kind, 0, 3)], text)
			},
			messages = proc(user: rawptr) -> []string {
				t, _ := ui.toast_texts(&(^App)(user).ws.toasts)
				return t
			},
			select_pads = proc(user: rawptr, pads: []int) {
				a := (^App)(user)
				a.pad_sel = {}
				for p in pads do a.pad_sel += {p}
				a.selected, a.pad_anchor = pads[0], pads[0]
				if a.play_mode != .Keyboard do a.bank = pads[0] / pm.PADS_PER_BANK
				show_pad_chain(a, a.selected)
			},
			selected_pads = proc(user: rawptr) -> []int {
				a := (^App)(user)
				sel := selected_pads(a)
				out := make([dynamic]int, context.temp_allocator)
				append(&out, a.selected)
				for p in 0 ..< pm.PADS do if p in sel && p != a.selected do append(&out, p)
				return out[:]
			},
		},
		param_moved = proc(user: rawptr, t: pm.Auto_Target, value: f32) {
			a := (^App)(user)
			scale := a.knob_scale
			a.knob_scale = 1 // (the API's values are the target's own units)
			record_move(a, value)
			a.knob_scale = scale
		},
	}
}

// Draws `frames` frames back to back and prints the CPU time per frame.
run_profile :: proc(a: ^App, frames: int) {
	p := &a.platform
	times := make([]f64, frames)
	defer delete(times)
	drawn := make([]ui.Draw_Stats, frames)
	defer delete(drawn)
	for i in 0 ..< frames {
		t0 := time.tick_now()
		if !ui.frame_begin(p) do break
		frame(a)
		ui.frame_end(p)
		times[i] = time.duration_milliseconds(time.tick_since(t0))
		drawn[i] = p.drawn
	}
	slice.sort_by(drawn[frames / 10:], proc(x, y: ui.Draw_Stats) -> bool { return x.vertices < y.vertices })
	d := drawn[frames / 10 + (frames - frames / 10) / 2]
	rest := times[frames / 10:]
	slice.sort(rest)
	fmt.printfln("%d frames: median %.3f ms, p99 %.3f ms; drawn (median): %d vertices, %d indices, %d draw lists, %d draw commands", len(rest), rest[len(rest) / 2], rest[len(rest) * 99 / 100], d.vertices, d.indices, d.lists, d.commands)
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
		a.sample_armed = a.sample_latched // (latched: on for the next one too)
	case:
		return false
	}
	s := &a.settings
	if pa.recording_sample_start(&a.api, i64(index), pa.Sampling(method), clamp(s.sample_threshold_db, -80, 0), i64(clamp(s.sample_bars, 1, 16))) != .Ok {
		ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("%s's input is set to No input: pick one on its strip", pm.pad_label(index)) if a.m.project.pads[index].input.from == .None else "No audio input to record from")
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
	pa.recording_sample_stop(&a.api)
}
