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
	w: Fake_Window
	defer delete(w.messages)
	defer delete(w.selected)
	fake_window(r, &w)
	testing.expect_value(t, pa.ui_show(api, "mixer"), pa.Result.Ok)
	testing.expect_value(t, w.shown, "mixer")
	testing.expect_value(t, pa.ui_show(api, "nowhere"), pa.Result.Not_Found)
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
