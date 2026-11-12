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
import "fire:clap"
import "fire:fx"
import "fire:synth"

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
		run = proc(u: rawptr) { leave((^App)(u), .New) }})
	add(acts, {id = "open", label = "Open Project…", icon = ui.ICON_FOLDER_OPEN, chord = ui.MOD_CMD | i32(im.Key.O), user = a,
		run = proc(u: rawptr) { project_dialog((^App)(u), .Open) }})
	add(acts, {id = "save", label = "Save", icon = ui.ICON_SAVE, chord = ui.MOD_CMD | i32(im.Key.S), user = a,
		run = proc(u: rawptr) { a := (^App)(u); if save_project(a) do ui.toast(&a.ws.toasts, .Success, "Saved") }})
	add(acts, {id = "save_as", label = "Save As…", icon = ui.ICON_SAVE, chord = ui.MOD_CMD | ui.MOD_SHIFT | i32(im.Key.S), user = a,
		run = proc(u: rawptr) { project_dialog((^App)(u), .Save_As) }})
	add(acts, {id = "rename_project", label = "Rename Project…", icon = ui.ICON_PENCIL, user = a,
		run = proc(u: rawptr) { (^App)(u).proj.rename_open = true }})
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
	add(acts, {id = "export_midi", label = "Export Sequence as MIDI…", icon = ui.ICON_MUSIC, user = a,
		run = proc(u: rawptr) { a := (^App)(u); open_midi_export(a, a.m.project.slot) }})
	add(acts, {id = "export_midi_song", label = "Export Song as MIDI…", icon = ui.ICON_MUSIC, user = a,
		run = proc(u: rawptr) { open_midi_export((^App)(u), -1) },
		enabled = proc(u: rawptr) -> bool { return (^App)(u).m.project.song.count > 0 }})
	add(acts, {id = "clear_pad", label = "Clear Pad", icon = ui.ICON_ERASER, chord = i32(im.Key.Delete), user = a,
		run = proc(u: rawptr) {
			a := (^App)(u)
			switch {
			case editing_notes(a): delete_selection(a)
			case song_editing(a):  song_delete(a)
			case:                  clear_pads(a, selected_pads(a))
			}
		},
		enabled = proc(u: rawptr) -> bool { a := (^App)(u); return editing_notes(a) || song_editing(a) || pm.pad_used(&a.m.project, a.selected) }})
	add(acts, {id = "settings", label = "Settings…", icon = ui.ICON_SETTINGS, chord = ui.MOD_CMD | i32(im.Key.Comma), user = a,
		run = proc(u: rawptr) { (^App)(u).settings.open = true }})
	add(acts, {id = "palette", label = "Command Palette", icon = ui.ICON_SEARCH, chord = ui.MOD_CMD | i32(im.Key.K), user = a,
		run = proc(u: rawptr) { ui.palette_open(&(^App)(u).ws.palette) }})
	add(acts, {id = "theme", label = "Light Theme", icon = ui.ICON_SUN, user = a,
		run = proc(u: rawptr) { a := (^App)(u); set_dark(a, !a.dark) },
		checked = proc(u: rawptr) -> bool { return !(^App)(u).dark }})
	add(acts, {id = "pad_waves", label = "Pad Waveforms", icon = ui.ICON_AUDIO_WAVEFORM, user = a,
		run = proc(u: rawptr) { a := (^App)(u); a.pad_waves = !a.pad_waves },
		checked = proc(u: rawptr) -> bool { return (^App)(u).pad_waves }})
	add(acts, {id = "library", label = "Library", icon = ui.ICON_LIBRARY, chord = ui.MOD_CMD | i32(im.Key.L), user = a,
		run = proc(u: rawptr) { a := (^App)(u); a.ws.left_shown = !a.ws.left_shown },
		checked = proc(u: rawptr) -> bool { return (^App)(u).ws.left_shown }})
	add(acts, {id = "fold_pads", label = "Fold the Pads Area", icon = ui.ICON_PANEL_BOTTOM_CLOSE, chord = ui.MOD_CMD | i32(im.Key.J), user = a,
		run = proc(u: rawptr) { a := (^App)(u); a.ws.bottom_folded = !a.ws.bottom_folded },
		checked = proc(u: rawptr) -> bool { return (^App)(u).ws.bottom_folded }})
	add(acts, {id = "reset_layout", label = "Reset Layout", icon = ui.ICON_LAYOUT_DASHBOARD, user = a,
		run = proc(u: rawptr) { ui.workspace_reset_layout(&(^App)(u).ws) }})
	for b in 0 ..< pm.BANKS {
		ids := [pm.BANKS]string{"bank_a", "bank_b", "bank_c", "bank_d", "bank_e", "bank_f", "bank_g", "bank_h"}
		labels := [pm.BANKS]string{"Bank A", "Bank B", "Bank C", "Bank D", "Bank E", "Bank F", "Bank G", "Bank H"}
		add(acts, {id = ids[b], label = labels[b], icon = ui.ICON_LAYOUT_GRID, chord = ui.MOD_CMD | (i32(im.Key._1) + i32(b)), user = a,
			run = bank_actions[b]})
	}
	add(acts, {id = "play", label = "Play / Stop", icon = ui.ICON_PLAY, chord = i32(im.Key.Space), user = a,
		run = proc(u: rawptr) { toggle_play((^App)(u)) }})
	add(acts, {id = "group_pads", label = "Group Selected Pads", icon = ui.ICON_GROUP, chord = ui.MOD_CMD | i32(im.Key.G), user = a,
		run = proc(u: rawptr) { a := (^App)(u); group_selected(a, a.selected) }})
	add(acts, {id = "next_marker", label = "Next Marker", icon = ui.ICON_SKIP_FORWARD, chord = ui.MOD_ALT | i32(im.Key.RightArrow), user = a,
		run = proc(u: rawptr) { marker_step((^App)(u), false) }})
	add(acts, {id = "prev_marker", label = "Previous Marker", icon = ui.ICON_SKIP_BACK, chord = ui.MOD_ALT | i32(im.Key.LeftArrow), user = a,
		run = proc(u: rawptr) { marker_step((^App)(u), true) }})
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
	add(acts, {id = "duplicate_sequence", label = "Duplicate Sequence", icon = ui.ICON_COPY_PLUS, chord = ui.MOD_CMD | i32(im.Key.D), user = a,
		run = proc(u: rawptr) {
			a := (^App)(u)
			switch {
			case editing_notes(a): duplicate_selection(a)
			case song_editing(a):  song_duplicate(a)
			case:                  pm.duplicate_sequence(&a.m, a.m.project.slot)
			}
		}})
	add(acts, {id = "rename_sequence", label = "Rename Sequence…", icon = ui.ICON_PENCIL, chord = i32(im.Key.F2), user = a,
		run = proc(u: rawptr) { a := (^App)(u); begin_rename_sequence(a, a.m.project.slot) }})
	add(acts, {id = "copy_bars", label = "Copy Bars to…", icon = ui.ICON_COPY, user = a,
		run = proc(u: rawptr) { a := (^App)(u); begin_copy_bars(a, a.m.project.slot) }})
	add(acts, {id = "copy", label = "Copy Marked Notes", icon = ui.ICON_COPY, chord = ui.MOD_CMD | i32(im.Key.C), user = a,
		run = proc(u: rawptr) { a := (^App)(u); if song_editing(a) do song_copy(a); else do copy_marked(a) },
		enabled = proc(u: rawptr) -> bool { a := (^App)(u); return len(a.seq.sel) > 0 || song_editing(a) }})
	add(acts, {id = "paste", label = "Paste Notes", icon = ui.ICON_CLIPBOARD_PASTE, chord = ui.MOD_CMD | i32(im.Key.V), user = a,
		run = proc(u: rawptr) { a := (^App)(u); if a.song_ui.focused do song_paste(a); else do paste_marked(a) },
		enabled = proc(u: rawptr) -> bool { a := (^App)(u); return a.song_ui.clip_n > 0 if a.song_ui.focused else a.seq_ops.has_part }})
	add(acts, {id = "clear_sequence", label = "Clear Sequence", icon = ui.ICON_TRASH_2, user = a,
		run = proc(u: rawptr) { a := (^App)(u); pm.clear_sequence(&a.m, a.m.project.slot) }})
	add(acts, {id = "quit", label = "Quit", icon = ui.ICON_LOG_OUT, chord = ui.MOD_CMD | i32(im.Key.Q), user = a,
		run = proc(u: rawptr) { leave((^App)(u), .Quit) }})
	register_commands(a)
	register_selection_actions(a, acts)
}

bank_actions := [pm.BANKS]proc(u: rawptr) {
	proc(u: rawptr) { (^App)(u).bank = 0 },
	proc(u: rawptr) { (^App)(u).bank = 1 },
	proc(u: rawptr) { (^App)(u).bank = 2 },
	proc(u: rawptr) { (^App)(u).bank = 3 },
	proc(u: rawptr) { (^App)(u).bank = 4 },
	proc(u: rawptr) { (^App)(u).bank = 5 },
	proc(u: rawptr) { (^App)(u).bank = 6 },
	proc(u: rawptr) { (^App)(u).bank = 7 },
}

// Edit > History: every step that can be undone (the newest first) and
// redone; choose one to go back (or forward) to just after it.
draw_history_menu :: proc(a: ^App) {
	h := &a.m.history
	if !im.BeginMenu("History", len(h.undo) > 0 || len(h.redo) > 0) do return
	defer im.EndMenu()
	// Redoable, the furthest first (dimmed: undone).
	for k := 0; k < len(h.redo); k += 1 {
		step := h.redo[k]
		ahead := len(h.redo) - k // redos to reach it
		im.PushStyleColorVec4(.Text, transmute(im.Vec4)ui.theme().text_dim)
		clicked := im.MenuItem(fmt.ctprintf("%s###redo%d", step.name, k))
		ui.name(fmt.tprintf("history redo %d", ahead))
		im.PopStyleColor()
		if clicked do for _ in 0 ..< ahead do app.redo(h)
	}
	if len(h.redo) > 0 do im.Separator()
	for k := len(h.undo) - 1; k >= 0; k -= 1 {
		step := h.undo[k]
		back := len(h.undo) - 1 - k // undos to be just after it
		label := fmt.ctprintf("%s%s###undo%d", step.name, "  (now)" if back == 0 else "", k)
		clicked := im.MenuItem(label, nil, back == 0)
		ui.name(fmt.tprintf("history %d", k + 1))
		if clicked do for _ in 0 ..< back do app.undo(h)
	}
	im.Separator()
	im.TextDisabled("%s", fmt.ctprintf("%d step%s; Cmd+Z undoes one", len(h.undo), "" if len(h.undo) == 1 else "s"))
}

set_dark :: proc(a: ^App, dark: bool) {
	a.settings.theme = ui.theme_dark() if dark else ui.theme_light()
	appearance_apply(a)
	settings_save(a)
}

draw_menu :: proc(user: rawptr) {
	a := (^App)(user)
	if im.BeginMenu("File") {
		ui.menu_action(&a.actions, "new")
		names, dirs := template_list(a)
		if im.BeginMenu("New from Template", len(names) > 0) {
			for n, k in names do if im.MenuItem(fmt.ctprintf("%s", n)) do leave(a, .New_From, dirs[k])
			im.EndMenu()
		}
		ui.menu_action(&a.actions, "open")
		if im.BeginMenu("Open Recent", len(a.proj.recent) > 0) {
			for r in a.proj.recent do if im.MenuItem(fmt.ctprintf("%s", filepath.base(r))) do leave(a, .Open, r)
			im.EndMenu()
		}
		ui.menu_action(&a.actions, "save")
		ui.menu_action(&a.actions, "save_as")
		if im.MenuItem("Save as Template…") {
			a.template = {open = true}
			copy(a.template.name[:63], project_name(a))
		}
		ui.menu_action(&a.actions, "rename_project")
		im.Separator()
		ui.menu_action(&a.actions, "import")
		ui.menu_action(&a.actions, "import_midi")
		ui.menu_action(&a.actions, "export")
		ui.menu_action(&a.actions, "export_midi")
		ui.menu_action(&a.actions, "export_midi_song")
		ui.menu_action(&a.actions, "resample")
		im.Separator()
		ui.menu_action(&a.actions, "settings")
		ui.menu_action(&a.actions, "quit")
		im.EndMenu()
	}
	if im.BeginMenu("Edit") {
		ui.menu_action(&a.actions, "undo")
		ui.menu_action(&a.actions, "redo")
		draw_history_menu(a)
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
		if im.BeginMenu("Bank") {
			for id in ([]string{"bank_a", "bank_b", "bank_c", "bank_d", "bank_e", "bank_f", "bank_g", "bank_h"}) do ui.menu_action(&a.actions, id)
			im.EndMenu()
		}
		im.Separator()
		ui.menu_action(&a.actions, "theme")
		ui.menu_action(&a.actions, "pad_waves")
		ui.menu_action(&a.actions, "library")
		ui.menu_action(&a.actions, "fold_pads")
		ui.menu_action(&a.actions, "reset_layout")
		im.EndMenu()
	}
	if im.BeginMenu("Help") {
		if im.MenuItem("About Pads") do a.about.open = true
		ui.name("menu about")
		im.EndMenu()
	}
}

setup_workspace :: proc(a: ^App) {
	w := &a.ws
	ui.workspace_init(w)
	w.toolbar, w.toolbar_user, w.toolbar_h = draw_toolbar, a, TOOLBAR_H
	w.statusbar, w.statusbar_h = draw_statusbar, STATUS_H
	w.left, w.left_user, w.left_title, w.left_shown = draw_browser, a, "Library###browser", true
	ui.panel_add(w, {id = "sequence", title = "Sequence", icon = ui.ICON_LIST_MUSIC, open = true, draw = draw_sequence, user = a}, .Center)
	ui.panel_add(w, {id = "song", title = "Song", icon = ui.ICON_LIST_ORDERED, open = true, draw = draw_song, user = a}, .Center)
	ui.panel_add(w, {id = "mixer", title = "Mixer", icon = ui.ICON_SLIDERS_VERTICAL, open = true, draw = draw_mixer, user = a}, .Center)
	ui.panel_add(w, {id = "perform", title = "Perform", icon = ui.ICON_KEYBOARD_MUSIC, open = true, draw = draw_perform, user = a}, .Center)
	w.bottom, w.bottom_user, w.bottom_title = draw_bottom, a, "Devices###detail"
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

// Where a MIDI export goes (and what: a sequence, or -1 the song).
Midi_Export_Chosen :: struct {
	path: string,
	slot: int,
}

// The save dialog for a MIDI export of sequence `slot` (-1: the song).
open_midi_export :: proc(a: ^App, slot: int) {
	@(static) pending: int
	pending = slot
	filters := [1]sdl.DialogFileFilter{{name = "MIDI", pattern = "mid"}}
	name := fmt.ctprintf("%s.mid", project_name(a) if slot < 0 else pm.sequence_name(&a.m.project, slot))
	sdl.ShowSaveFileDialog(proc "c" (user: rawptr, files: [^]cstring, filter: i32) {
		if files == nil || files[0] == nil do return
		a := (^App)(user)
		context = runtime.default_context()
		app.post_any_thread(&a.bus, Midi_Export_Chosen{strings.clone(string(files[0])), pending})
	}, a, a.platform.window, &filters[0], 1, name)
}

// A .mid file dropped (on pad `pad`, or -1 the window): on a pad, its notes
// all on that pad, pitched; else as drums by the MIDI map, into the
// current sequence. True if it was one.
drop_midi :: proc(a: ^App, path: string, pad: int) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	if !strings.has_suffix(lower, ".mid") && !strings.has_suffix(lower, ".midi") do return false
	slot := a.m.project.slot
	n := pm.import_midi(&a.m, path, slot, .On_Pad if pad >= 0 else .By_Map, max(pad, 0))
	if n < 0 do ui.toast(&a.ws.toasts, .Error, "Could not read that MIDI file")
	else do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%d notes into %s%s", n, pm.sequence_name(&a.m.project, slot), fmt.tprintf(", on %s", pm.pad_label(pad)) if pad >= 0 else ""))
	return true
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
	app.subscribe(&a.bus, Midi_Export_Chosen, proc(user: rawptr, e: ^Midi_Export_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		path := e.path if strings.has_suffix(strings.to_lower(e.path, context.temp_allocator), ".mid") else strings.concatenate({e.path, ".mid"}, context.temp_allocator)
		n := pm.export_midi(&a.m, path, e.slot)
		if n < 0 do ui.toast(&a.ws.toasts, .Error, "Could not write that MIDI file")
		else do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Exported %d notes to %s", n, filepath.base(path)))
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
//	command ID KIND [I [S]] run a command on a target: pad I, note I of sequence S, sequence I, song_step I, bus I, file PATH, take I
//	panel ID              bring a panel (browser, sequence, song, mixer, perform, pads) or a pad tab (sample, env, filter, pitch, lfo, effects, global) to the front
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
//	send PAD BUS DB [pre|post]   a pad's send to bus BUS (1..the buses in use; DB -60 = off)
//	addbus / delbus B / busdest B D (0 = main) / busname B NAME   buses: add, delete, route, rename
//	warp PAD on|off [beats|tones|complex|repitch] [BPM]   a pad's warp (its sample's tempo: guessed if not given)
//	plugin_folder PATH / scan_plugins   a folder for plug-ins, and a scan of every folder
//	slicer PAD [FILE] / empty_slicer PAD / slice PAD transients|beats|equal / sampler PAD   slicers
//	midi KEY VEL [PORT] / midi_in PAD all|none|PORT [CH] / arm PAD on|off   MIDI in (by port index), a track's MIDI input, arming
//	route PAD BUS (0 = main) / busvol BUS DB / mute|solo pad N|bus B (toggles) / perf N on|off
//	expect level main|bus B|pad N above|below DB / expect fx KIND
//	save / save_as DIR / rename_project NAME / open DIR / new / export PATH [song] [stems pads|buses] [rate HZ] [bits 16|24|32] [tail S]
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
		case "pads":     set_play_mode(a, .Pads)
		case "keys":     set_play_mode(a, .Keyboard)
		case "velocity": set_play_mode(a, .Velocity)
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
		// midi KEY VELOCITY [PORT] (0 = note-off; the port's index, 0 by default)
		if len(w) < 3 do return false
		key, vel := num(w, 1), num(w, 2)
		if key < 0 || key > 127 do return false
		port := u8(num(w, 3)) if len(w) > 3 else 0
		app.host_midi_inject(&a.host, {0x90 if vel > 0 else 0x80, u8(key), u8(clamp(vel, 0, 127))}, port)
		return true
	case "midi_in":
		// midi_in PAD all|none|INDEX [CHANNEL]: what MIDI plays it (INDEX: an
		// input port's index, as `midi` sends; for scripts without ports)
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 3 do return false
		p := a.m.project.pads[i]
		switch w[2] {
		case "all":  p.midi_in = {mode = .All}
		case "none": p.midi_in = {mode = .None}
		case:        p.midi_in = {mode = .Port, port = pm.intern(&a.m.project, w[2]), channel = u8(num(w, 3)) if len(w) > 3 else 0}
		}
		pm.set_pad(&a.m, i, .Midi_In, "MIDI In", p)
		app.seal(&a.m.history)
		pm.sync(&a.m.engine)
		if p.midi_in.mode == .Port do a.m.engine.router.in_port[i] = i16(num(w, 2)) // (no ports here: the index as given)
		return true
	case "arm":
		// arm PAD on|off
		i := num(w, 1)
		if !pad_ok(i) do return false
		on := len(w) < 3 || w[2] != "off"
		pm.arm_track(&a.m, i, on)
		if on do a.io.manual += {i}
		else do a.io.manual -= {i}
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
	case "template": // template save NAME | template new NAME: save the project as a template, or a new project from one
		if len(w) < 3 do return false
		name := strings.join(w[2:], " ", context.temp_allocator)
		dir, _ := filepath.join({templates_folder(a), strings.concatenate({pm.safe_name(name), ".pads"}, context.temp_allocator)}, context.temp_allocator)
		if w[1] == "save" do return pm.model_save_copy(&a.m, dir) == .None
		new_from_template(a, dir)
		return true
	case "export_midi": // export_midi SLOT|song PATH: a sequence (1..) or the song as a MIDI file
		if len(w) < 3 do return false
		slot := -1 if w[1] == "song" else num(w, 1) - 1
		return pm.export_midi(&a.m, strings.join(w[2:], " ", context.temp_allocator), slot) >= 0
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
		show_device(a, a.fx)
		return true
	case "send":
		// send PAD BUS DB [pre|post]
		i, b := num(w, 1), num(w, 2)
		if !pad_ok(i) || b < 1 || b > a.m.project.bus_count || len(w) < 4 do return false
		pm.set_send_db(&a.m, i, b, numf(w, 3))
		app.seal(&a.m.history)
		if len(w) > 4 do pm.set_send_pre(&a.m, i, b, w[4] == "pre")
		return true
	case "route":
		if i := num(w, 1); pad_ok(i) {
			pm.set_pad_bus(&a.m, i, num(w, 2))
			return true
		}
	case "slicer": // slicer PAD [FILE]: the pad a slicer (its sample sliced), or FILE loaded into one
		i := num(w, 1)
		if !pad_ok(i) do return false
		if len(w) > 2 do return load_into_slicer(a, i, strings.join(w[2:], " ", context.temp_allocator))
		pm.make_slicer(&a.m, i)
		return true
	case "empty_slicer": // empty_slicer PAD
		i := num(w, 1)
		if !pad_ok(i) do return false
		pm.empty_slicer(&a.m, i)
		return true
	case "slice": // slice PAD transients|beats|equal: slices it again
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 3 do return false
		by := pm.Slice_By.Transients
		switch w[2] {
		case "beats": by = .Beats
		case "equal": by = .Equal
		}
		pm.slice_pad(&a.m, i, by)
		return true
	case "synth": // synth PAD: the pad a synth
		i := num(w, 1)
		if !pad_ok(i) do return false
		pm.make_synth(&a.m, i)
		return true
	case "synth_param": // synth_param PAD ID VALUE: a synth parameter's plain value
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 4 do return false
		pm.set_synth_value(&a.m, i, fc.Param_Id(num(w, 2)), numf(w, 3), "Set")
		app.seal(&a.m.history)
		return true
	case "synth_tab": // synth_tab osc|filter|env|lfo|mod|effects|macro|global
		if len(w) < 2 do return false
		for t in Synth_Tab do if strings.to_lower(SYNTH_TAB_NAMES[t], context.temp_allocator) == w[1] {
			a.synth_ui.tab, a.synth_ui.show = t, 2
			return true
		}
		return false
	case "wavetable_editor": // wavetable_editor OSC [new|copy|close]: the editor on oscillator OSC (1..3) of the selected pad
		o := num(w, 1)
		if o < 1 || o > synth.OSCS do return false
		open_wave_editor(a, o - 1)
		if len(w) > 2 && w[2] == "new" do pm.new_wave_doc(&a.m, a.selected, o - 1)
		if len(w) > 2 && w[2] == "copy" do pm.new_wave_doc(&a.m, a.selected, o - 1, true)
		if len(w) > 2 && w[2] == "close" do a.wte.open = false
		return true
	case "wavetable_key": // wavetable_key K [draw|lines|harmonics|audio]: choose keyframe K (1..) in the editor, and its source
		k := num(w, 1)
		a.wte.key = k - 1
		if len(w) > 2 {
			src := a.m.project.pads[a.wte.pad].synth.tables[a.wte.osc]
			d := app.store_get(&a.m.project.wave_docs, src.table)
			if d == nil || k < 1 || k > d.doc.count do return false
			x := d^
			for s, n in KEY_SOURCE_NAMES do if strings.to_lower(s, context.temp_allocator) == w[2] do x.doc.keys[k - 1].source = synth.Key_Source(n)
			pm.set_wave_doc(&a.m, src.table, x, "Keyframe Source")
			app.seal(&a.m.history)
		}
		return true
	case "synth_lfo": // synth_lfo K: the LFO tab shows LFO K (1..8) or random modulator K - 8 (9..12)
		k := num(w, 1)
		if k < 1 || k > synth.LFOS + synth.RANDOMS do return false
		a.synth_ui.lfo = k - 1
		return true
	case "synth_fx": // synth_fx NAME: the effect the Effects tab shows (chorus, compressor, delay, distortion, eq, filter, flanger, phaser, reverb)
		if len(w) < 2 do return false
		for e in fx.Effect do if strings.to_lower(fmt.tprint(e), context.temp_allocator) == w[1] {
			a.synth_ui.effect = e
			return true
		}
		return false
	case "slices_seq": // slices_seq PAD: a sequence of its slices (the next empty slot)
		i := num(w, 1)
		if !pad_ok(i) do return false
		return pm.slices_to_sequence(&a.m, i) >= 0
	case "slice_out": // slice_out PAD K: slice K (1..) onto the next empty pad
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 3 do return false
		return pm.slice_to_pad(&a.m, i, num(w, 2) - 1) >= 0
	case "sampler": // sampler PAD: a slicer a sampler again
		i := num(w, 1)
		if !pad_ok(i) do return false
		pm.make_sampler(&a.m, i)
		return true
	case "warp": // warp PAD on|off [beats|tones|complex|repitch] [BPM]
		i := num(w, 1)
		if !pad_ok(i) || len(w) < 3 do return false
		wp := a.m.project.pads[i].warp
		wp.on = w[2] == "on"
		if len(w) > 3 do switch w[3] {
		case "beats":   wp.mode = .Beats
		case "tones":   wp.mode = .Tones
		case "complex": wp.mode = .Complex
		case "repitch": wp.mode = .Repitch
		}
		if len(w) > 4 do wp.bpm = f64(numf(w, 4))
		pm.set_warp(&a.m, i, wp)
		app.seal(&a.m.history)
		return true
	case "plugin_folder": // plugin_folder PATH: a folder plug-ins are scanned in
		if len(w) < 2 do return false
		append(&a.settings.plugin_folders, strings.clone(strings.join(w[1:], " ", context.temp_allocator)))
		return true
	case "scan_plugins": // scans now (a library a frame)
		plugins_scan(a)
		return true
	case "addbus": // a bus after the others
		return pm.add_bus(&a.m) > 0
	case "delbus": // delbus B (1..)
		n := a.m.project.bus_count
		pm.delete_bus(&a.m, num(w, 1))
		return a.m.project.bus_count == n - 1
	case "busdest": // busdest B D: bus B (1..) to D (0 = main, or a bus); fails if it would loop
		return pm.set_bus_dest(&a.m, num(w, 1), num(w, 2))
	case "busname": // busname B NAME
		if len(w) < 3 do return false
		pm.rename_bus(&a.m, num(w, 1), strings.join(w[2:], " ", context.temp_allocator))
		return true
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
	case "save": // (in place, even a new project: no dialog in a script)
		if a.proj.untitled do return pm.model_save(&a.m) == .None
		return save_project(a)
	case "rename_project":
		if len(w) < 2 do return false
		return rename_project(a, strings.join(w[1:], " ", context.temp_allocator))
	case "save_as":
		if len(w) < 2 do return false
		if pm.model_save_as(&a.m, strings.join(w[1:], " ", context.temp_allocator)) != .None do return drive_fail(a, "could not save as")
		a.proj.untitled = false
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
		// song add SLOT [REPEATS] / song mode on|off / song loop on|off / song clear /
		// song tempo BEAT BPM [ramp] / song meter STEP NUM DEN / song marker BEAT NAME /
		// song range START END | off / song jump MARKER
		if len(w) < 2 do return false
		switch w[1] {
		case "add":
			reps := num(w, 3) if len(w) > 3 else 1
			pm.song_add(&a.m, num(w, 2) - 1, repeats = reps)
		case "mode":
			a.m.project.song_mode = len(w) < 3 || w[2] != "off"
			a.m.engine.seq_dirty = true
		case "loop": // the transport's loop (the song's, a sequence's)
			tr := a.m.project.transport
			tr.loop = len(w) < 3 || w[2] != "off"
			pm.set_transport(&a.m, .Loop, "Loop", tr)
		case "clear":
			pm.set_song(&a.m, "Clear Song", {})
		case "tempo": // song tempo BEAT BPM [ramp]: a tempo point
			if len(w) < 4 do return false
			b, _ := strconv.parse_f64(w[2])
			bpm, _ := strconv.parse_f64(w[3])
			pm.tempo_point_add(&a.m, {b, bpm, len(w) > 4 && w[4] == "ramp"})
		case "meter": // song meter STEP NUM DEN: step STEP's (1..) time signature
			if len(w) < 5 do return false
			pm.set_step_meter(&a.m, num(w, 2) - 1, {num(w, 3), num(w, 4)})
		case "marker": // song marker BEAT NAME
			if len(w) < 4 do return false
			b, _ := strconv.parse_f64(w[2])
			pm.marker_add(&a.m, b, strings.join(w[3:], " ", context.temp_allocator))
		case "range": // song range START END (beats) | song range off: the loop range
			if len(w) > 2 && w[2] == "off" {
				pm.set_song_loop(&a.m, false, 0, 0)
			} else if len(w) > 3 {
				x, _ := strconv.parse_f64(w[2])
				y, _ := strconv.parse_f64(w[3])
				pm.set_song_loop(&a.m, true, x, y)
			} else {
				return false
			}
		case "step": // song step STEP: its settings show (1..)
			a.song_ui.step = clamp(num(w, 2) - 1, -1, a.m.project.song.count - 1)
		case "jump": // song jump MARKER: go to marker MARKER (1..)
			k := num(w, 2) - 1
			if k < 0 || k >= a.m.project.song.marker_count do return false
			pm.song_jump(&a.m.engine, a.m.project.song.markers[k].beat)
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
		case "pad", "inspector", "global": show_detail(a, .Global)
		case "env":               show_detail(a, .Env)
		case "filter":            show_detail(a, .Filter)
		case "pitch":             show_detail(a, .Pitch)
		case "lfo":               show_detail(a, .Lfo)
		case "effect", "effects": show_device(a, a.fx)
		case "eq":                show_eq(a)
		case "pads":              a.ws.bottom_folded = false
		case "browser", "library": library_show(a, 0)
		case "devices":            library_show(a, 1)
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
	case "command": // command ID KIND [INDEX [SLOT]]: a command on a target (pad 3, sequence 2...)
		if len(w) < 3 do return false
		t: Target
		ok := false
		for k in Target_Kind do if strings.to_lower(fmt.tprint(k), context.temp_allocator) == w[2] {
			t.kind, ok = k, true
		}
		if !ok do return drive_fail(a, fmt.tprintf("no target kind %s", w[2]))
		if len(w) > 3 do t.index = num(w, 3)
		if len(w) > 4 do t.slot = num(w, 4)
		if t.kind == .Sequence do t.slot = t.index
		if t.kind == .File && len(w) > 3 do t.path = absolute(strings.join(w[3:], " ", context.temp_allocator))
		if !run_command(a, w[1], t) do return drive_fail(a, fmt.tprintf("command %s did not run on %v", w[1], t))
		return true
	case "group": // group PAD... [as NAME]: those pads (0..) under a new group bus / group fold B | unfold B | ungroup B (1..)
		if len(w) < 2 do return false
		switch w[1] {
		case "fold", "unfold":
			pm.set_group_folded(&a.m, num(w, 2), w[1] == "fold")
			return true
		case "ungroup":
			pm.ungroup(&a.m, num(w, 2))
			return true
		}
		pads := make([dynamic]int, context.temp_allocator)
		name := ""
		for k := 1; k < len(w); k += 1 {
			if w[k] == "as" {
				name = strings.join(w[k + 1:], " ", context.temp_allocator)
				break
			}
			append(&pads, num(w, k))
		}
		return pm.group_pads(&a.m, pads[:], name) > 0
	case "sidechain": // sidechain PAD SLOT pad N | bus B | off [listen] [hpf HZ]: insert SLOT (0..) of pad PAD (0..) keyed from pad N (0..) or bus B (0..)
		if len(w) < 4 do return false
		pad, slot := num(w, 1), num(w, 2)
		if pad < 0 || pad >= pm.PADS || slot < 0 || slot >= pm.PAD_INSERTS do return false
		sl := a.m.project.pads[pad].inserts[slot]
		switch w[3] {
		case "pad": sl.key = {.Pad, num(w, 4)}
		case "bus": sl.key = {.Bus, num(w, 4)}
		case "off": sl.key = {}
		case: return false
		}
		sl.listen = false
		for k := 5; k < len(w); k += 1 {
			if w[k] == "listen" do sl.listen = true
			if w[k] == "hpf" && k + 1 < len(w) {
				x, _ := strconv.parse_f32(w[k + 1])
				sl.key_hpf = x
			}
		}
		pm.set_insert(&a.m, pad, slot, sl, "Sidechain")
		return true
	case "plugin_pad": // plugin_pad PAD PATH ID: pad PAD (0..) plays plug-in ID of the CLAP file at PATH (from the working folder), selected
		if len(w) < 4 do return false
		i := num(w, 1)
		name := w[3]
		if lib, err := clap.library_open(absolute(w[2])); err == .None {
			for d in lib.plugins do if d.id == w[3] do name = strings.clone(d.name, context.temp_allocator)
			clap.library_close(lib)
		}
		pm.make_plugin_pad(&a.m, i, absolute(w[2]), w[3], name)
		a.selected = i
		show_device(a, {.Instrument, i, 0})
		return true
	case "plugin_editor": // plugin_editor open|close: the selected pad's plug-in's own window
		if len(w) < 2 do return false
		if w[1] == "close" {
			if p := pm.pad_plugin(&a.m.engine, a.selected); p != nil do editor_close(a, p)
			return true
		}
		editor_open(a, {.Instrument, a.selected, 0}) // (headless: it says why it can't)
		return true
	case "plugin_lane": // plugin_lane LANE PARAM: the selected pad's lane LANE (1..8) moves its plug-in's parameter PARAM (an id; 0: none)
		if len(w) < 3 do return false
		id := fc.Param_Id(num(w, 2))
		info := fc.Param_Info{}
		for p in pm.target_params(&a.m.engine, {.Instrument, a.selected, 0}) do if p.id == id do info = p
		pm.set_plugin_lane(&a.m, a.selected, num(w, 1) - 1, info)
		return true
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
	case "plugin":
		// expect plugin loaded|failed|editor|no-editor: the selected pad's plug-in
		p := pm.pad_plugin(&a.m.engine, a.selected)
		open := false
		for e in a.editors do open ||= p != nil && e.plugin == p
		ok: bool
		switch w[2] {
		case "loaded":    ok = p != nil
		case "failed":    ok = pm.pad_plugin_failed(&a.m.engine, a.selected)
		case "editor":    ok = open
		case "no-editor": ok = !open
		case: return false
		}
		if !ok do return drive_fail(a, fmt.tprintf("expected the plug-in %s", w[2]))
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
		for _, i in a.m.project.pads do if pm.pad_used(&a.m.project, i) do got += 1
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
