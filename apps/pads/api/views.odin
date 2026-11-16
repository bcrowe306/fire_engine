package pads_api

import "core:time"

/*
Pads' views, drawn for a controller's display (Push 2's): a view of Pads'
own (the sound editor, the mixer, the sequencer...) at the size a surface
asks for, with Pads' widgets and theme. The app draws each view a surface
asks for after its own frame (offscreen, on the GPU) and hands its pixels
back here; `view_frame` gives the newest (a frame behind). A view not
asked for in two seconds is no longer drawn.
*/

// A view Pads draws for a display.
View_Kind :: enum i32 {
	Device,    // the selected pad's sound: page 0 its envelope, 1 its filter, 2 its pitch, 3 its LFOs
	Mixer,     // the mixer's strips
	Sequencer, // the selected pad's sequence
	Clip,      // the selected pad's sample or clip
	Browser,   // the browser
}

// A view a surface asks for, and its newest pixels.
@(private)
View_Want :: struct {
	kind:          View_Kind,
	page:          i64,
	width, height: i64,
	asked:         time.Tick,
	pixels:        [dynamic]u8, // RGBA, rows top to bottom
	frame:         i64, // how many frames it has had
}

// How long a view is drawn after it was last asked for.
@(private)
VIEW_KEEP :: 2 * time.Second

// The newest frame of view `kind` (`page` of it) at `width` x `height`
// pixels, copied into `rgba` (`size` bytes: RGBA, rows top to bottom,
// width x height x 4), asking for it to be drawn from now on. Its frame
// number (0: none drawn yet, `rgba` untouched; a number not newer than the
// last: unchanged). Each frame Pads draws the views asked for in the last
// two seconds.
view_frame :: proc(api: ^Api, kind: View_Kind, page: i64, width: i64, height: i64, rgba: rawptr, size: i64) -> (i64, Result) {
	if width <= 0 || height <= 0 || width > 4096 || height > 4096 do return 0, fail(api, .Invalid_Argument, "a view's size is 1 to 4096 pixels a side")
	if kind < min(View_Kind) || kind > max(View_Kind) do return 0, fail(api, .Invalid_Argument, "no such view")
	w := view_want(api, kind, page, width, height)
	w.asked = time.tick_now()
	if w.frame == 0 do return 0, .Ok
	n := min(i64(len(w.pixels)), size)
	if rgba != nil && n > 0 do copy(([^]u8)(rgba)[:n], w.pixels[:n])
	return w.frame, .Ok
}

@(private)
view_want :: proc(api: ^Api, kind: View_Kind, page, width, height: i64) -> ^View_Want {
	for &w in api.views do if w.kind == kind && w.page == page && w.width == width && w.height == height do return &w
	append(&api.views, View_Want{kind = kind, page = page, width = width, height = height, pixels = make([dynamic]u8)})
	return &api.views[len(api.views) - 1]
}

// The views asked for lately (for the app to draw): kind, page, size and
// an index for `views_put`. Views not asked for in two seconds are dropped.
// The host's.
views_wanted :: proc(api: ^Api, allocator := context.temp_allocator) -> []View_Request {
	for i := len(api.views) - 1; i >= 0; i -= 1 do if time.tick_since(api.views[i].asked) > VIEW_KEEP {
		delete(api.views[i].pixels)
		ordered_remove(&api.views, i)
	}
	out := make([]View_Request, len(api.views), allocator)
	for w, i in api.views do out[i] = {index = i64(i), kind = w.kind, page = w.page, width = w.width, height = w.height}
	return out
}

// A view to draw (`views_wanted`).
View_Request :: struct {
	index:         i64,
	kind:          View_Kind,
	page:          i64,
	width, height: i64,
}

// A view's new frame, drawn by the app (RGBA, width x height x 4 bytes).
// The host's.
views_put :: proc(api: ^Api, index: i64, rgba: []u8) {
	if index < 0 || index >= i64(len(api.views)) do return
	w := &api.views[index]
	if i64(len(rgba)) != w.width * w.height * 4 do return
	resize(&w.pixels, len(rgba))
	copy(w.pixels[:], rgba)
	w.frame += 1
}

@(private)
views_destroy :: proc(api: ^Api) {
	for w in api.views do delete(w.pixels)
	delete(api.views)
}
