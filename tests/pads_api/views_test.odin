package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

// A view asked for (no app here draws it: no frame yet); a bad size refused.
@(test)
a_view_is_asked_for_and_waits_for_a_frame :: proc(t: ^testing.T) {
	r := rig_make(t, "views")
	defer rig_destroy(r)
	buf: [16 * 8 * 4]u8
	n, res := pa.view_frame(&r.api, .Device, 0, 16, 8, &buf[0], len(buf))
	testing.expect_value(t, res, pa.Result.Ok)
	testing.expect_value(t, n, 0)
	wants := pa.views_wanted(&r.api)
	if testing.expect_value(t, len(wants), 1) {
		testing.expect_value(t, wants[0].kind, pa.View_Kind.Device)
		testing.expect(t, wants[0].width == 16 && wants[0].height == 8)
		// The app's frame handed back: given out next time.
		px: [16 * 8 * 4]u8
		px[0] = 200
		pa.views_put(&r.api, wants[0].index, px[:])
		n, _ = pa.view_frame(&r.api, .Device, 0, 16, 8, &buf[0], len(buf))
		testing.expect_value(t, n, 1)
		testing.expect_value(t, buf[0], 200)
	}
	_, res = pa.view_frame(&r.api, .Device, 0, 0, 8, nil, 0)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
}

// A controller's encoders and buttons on a view: waiting for its drawing
// (the app's), what it offers as it last drew.
@(test)
a_views_controls_wait_for_its_drawing :: proc(t: ^testing.T) {
	r := rig_make(t, "view_input")
	defer rig_destroy(r)
	api := &r.api
	testing.expect_value(t, pa.view_turn(api, .Device, 2, 0, 0.1), pa.Result.Not_Found) // (not asked for)
	pa.view_frame(api, .Device, 2, 16, 8, nil, 0)
	testing.expect_value(t, pa.view_turn(api, .Device, 2, 8, 0.1), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.view_turn(api, .Device, 2, 1, 0.1), pa.Result.Ok)
	testing.expect_value(t, pa.view_turn(api, .Device, 2, 1, 0.05), pa.Result.Ok)
	testing.expect_value(t, pa.view_touch(api, .Device, 2, 1, true), pa.Result.Ok)
	testing.expect_value(t, pa.view_press(api, .Device, 2, 3, true), pa.Result.Ok)
	wants := pa.views_wanted(api)
	if !testing.expect_value(t, len(wants), 1) do return
	inp := pa.views_input(api, wants[0].index)
	testing.expect(t, abs(inp.turn[1] - 0.15) < 1e-9 && inp.held[1] && inp.pressed[3], "waiting")
	testing.expect_value(t, pa.view_touch(api, .Device, 2, 1, false), pa.Result.Ok)
	testing.expect(t, !inp.held[1] && inp.ended[1], "let go: its edit ends")
	testing.expect_value(t, pa.view_press(api, .Device, 2, 3, false), pa.Result.Ok)
	testing.expect(t, inp.released[3], "let go")
	// What the app's drawing said it offers.
	inp.state = {knobs = 8, buttons = 0b111, lit = 0b010}
	st, res := pa.view_state(api, .Device, 2)
	testing.expect(t, res == .Ok && st.knobs == 8 && st.buttons == 0b111 && st.lit == 0b010, "its state")
}
