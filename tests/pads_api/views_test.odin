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
