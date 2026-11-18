package test_pads_api

import "core:strings"
import "core:testing"

import pa "../../apps/pads/api"
import pc "../../apps/pads/core"

// A window, as Pads' hooks give the API one (headless: a record of what
// it was asked).
@(private)
Fake_Window :: struct {
	shown:    string,
	dark:     bool,
	messages: [dynamic]string,
	selected: [dynamic]int,
	dialog:   string,
	start:    bool,
	armed:    bool,
	grid:     int,
	picked:   int,
}

@(private)
fake_window :: proc(r: ^Rig, w: ^Fake_Window) {
	r.core.hooks.user = w
	r.core.hooks.ui = {
		show = proc(user: rawptr, name: string) -> bool {
			w := (^Fake_Window)(user)
			if name != "mixer" && name != "eq" do return false
			w.shown = name
			return true
		},
		set_dark = proc(user: rawptr, dark: bool) { (^Fake_Window)(user).dark = dark },
		dark = proc(user: rawptr) -> bool { return (^Fake_Window)(user).dark },
		toast = proc(user: rawptr, kind: int, text: string) { append(&(^Fake_Window)(user).messages, strings.clone(text, context.temp_allocator)) },
		messages = proc(user: rawptr) -> []string { return (^Fake_Window)(user).messages[:] },
		select_pads = proc(user: rawptr, pads: []int) {
			w := (^Fake_Window)(user)
			clear(&w.selected)
			append(&w.selected, ..pads)
		},
		selected_pads = proc(user: rawptr) -> []int { return (^Fake_Window)(user).selected[:] },
		dialog = proc(user: rawptr) -> (string, int) {
			w := (^Fake_Window)(user)
			return w.dialog, 2 if w.dialog != "" else 0
		},
		start_page = proc(user: rawptr) -> bool { return (^Fake_Window)(user).start },
		set_start_page = proc(user: rawptr, open: bool) { (^Fake_Window)(user).start = open },
		automation_armed = proc(user: rawptr) -> bool { return (^Fake_Window)(user).armed },
		quantize = proc(user: rawptr) { (^Fake_Window)(user).dialog = "quantized" },
		sample_armed = proc(user: rawptr) -> bool { return (^Fake_Window)(user).armed },
		select_notes = proc(user: rawptr, indices: []int) { (^Fake_Window)(user).picked = len(indices) },
		seq_grid = proc(user: rawptr) -> int { return (^Fake_Window)(user).grid },
		set_seq_grid = proc(user: rawptr, grid: int) { (^Fake_Window)(user).grid = grid },
		set_automation_armed = proc(user: rawptr, on: bool) { (^Fake_Window)(user).armed = on },
	}
}

@(test)
the_window_through_the_api :: proc(t: ^testing.T) {
	r := rig_make(t, "ui")
	defer rig_destroy(r)
	api := &r.api
	// Headless: no window.
	_, res := pa.ui_state(api)
	testing.expect_value(t, res, pa.Result.Unsupported)
	testing.expect_value(t, pa.ui_show(api, "mixer"), pa.Result.Unsupported)
	testing.expect_value(t, pa.ui_set_start_page(api, true), pa.Result.Unsupported)
	w: Fake_Window
	defer delete(w.messages)
	defer delete(w.selected)
	fake_window(r, &w)
	testing.expect_value(t, pa.ui_show(api, "mixer"), pa.Result.Ok)
	// The project manager: shown, closed.
	testing.expect_value(t, pa.ui_set_start_page(api, true), pa.Result.Ok)
	open, _ := pa.ui_start_page(api)
	testing.expect(t, open, "the project manager shows")
	pa.ui_set_start_page(api, false)
	open, _ = pa.ui_start_page(api)
	testing.expect(t, !open, "closed")
	// Automation recording: armed, disarmed.
	testing.expect_value(t, pa.ui_set_automation_armed(api, true), pa.Result.Ok)
	armed, _ := pa.ui_automation_armed(api)
	testing.expect(t, armed, "armed")
	pa.ui_set_automation_armed(api, false)
	// Quantize, as the window's button.
	testing.expect_value(t, pa.ui_quantize(api), pa.Result.Ok)
	testing.expect_value(t, w.dialog, "quantized")
	// The Sample control, the sequencer's grid and selection.
	sa, _ := pa.ui_sample_armed(api)
	testing.expect(t, !sa, "not armed")
	testing.expect_value(t, pa.ui_set_sequencer_grid(api, .Eighth), pa.Result.Ok)
	g, _ := pa.ui_sequencer_grid(api)
	testing.expect_value(t, g, pa.Grid.Eighth)
	pa.sequence_add_note(api, 0, {start = 0, length = 0.25, pad = 0, velocity = 1, probability = 1})
	testing.expect_value(t, pa.ui_select_notes(api, {0}), pa.Result.Ok)
	testing.expect_value(t, w.picked, 1)
	testing.expect_value(t, pa.ui_select_notes(api, {5}), pa.Result.Not_Found)
	w.dialog = ""
	testing.expect_value(t, w.shown, "mixer")
	testing.expect_value(t, pa.ui_show(api, "nowhere"), pa.Result.Not_Found)
	// The Library onto a pad: the fake window has none (nothing selected).
	testing.expect_value(t, pa.ui_library_load(api, 0), pa.Result.Not_Found)
	testing.expect_value(t, pa.ui_library_load(api, 999), pa.Result.Not_Found)
	testing.expect_value(t, pa.ui_set_dark(api, true), pa.Result.Ok)
	testing.expect_value(t, pa.ui_message_show(api, .Success, "Done"), pa.Result.Ok)
	testing.expect_value(t, pa.ui_message_show(api, .Info, "  "), pa.Result.Invalid_Argument)
	m, _ := pa.ui_message(api, 0)
	testing.expect_value(t, m, "Done")
	_, res = pa.ui_message(api, 1)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.ui_select_pads(api, {3, 4, 5}), pa.Result.Ok)
	testing.expect_value(t, pa.ui_select_pads(api, {}), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.ui_select_pads(api, {300}), pa.Result.Not_Found)
	p, _ := pa.ui_selected_pad(api, 2)
	testing.expect_value(t, p, 5)
	s, _ := pa.ui_state(api)
	testing.expect(t, s.dark && s.messages == 1 && s.selected == 3, "the window's state")
	// Its dialog: none, then one with two choices.
	d, _ := pa.ui_dialog(api)
	testing.expect(t, !d.open && d.choices == 0, "no dialog")
	w.dialog = "Unsaved changes"
	d, _ = pa.ui_dialog(api)
	title, _ := pa.ui_dialog_title(api)
	testing.expect(t, d.open && d.choices == 2 && title == "Unsaved changes", "a dialog")
	_ = pc.Ui_Hooks{}
}

@(test)
a_step_is_named_by_the_caller :: proc(t: ^testing.T) {
	r := rig_make(t, "step_names")
	defer rig_destroy(r)
	api := &r.api
	testing.expect_value(t, pa.history_name_next(api, "Faster"), pa.Result.Ok)
	pa.transport_set_tempo(api, 130)
	n, _ := pa.history_undo_name(api)
	testing.expect_value(t, n, "Faster")
	// Once only: the next edit has its own name.
	pa.transport_set_tempo(api, 131)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Set Tempo")
	// An edit that changes nothing makes no step: the name isn't put on the one before.
	pa.history_name_next(api, "Nothing")
	pa.transport_set_tempo(api, 131)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Set Tempo")
	testing.expect_value(t, pa.history_name_next(api, ""), pa.Result.Invalid_Argument)
}
