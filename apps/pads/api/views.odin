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
	Device,    // the device panel as Pads shows it (its device, its tab), for a controller (see View_Button)
	Mixer,     // the mixer's strips
	Sequencer, // the selected pad's sequence
	Clip,      // the Performance view's launcher: lanes of sequences (see View_Button)
	Browser,   // the Library's browser: its rows, the preview (see View_Button)
	Dialog,    // the dialog Pads shows (ui_dialog): its title, its words, its choices on the buttons
	Song,      // the song's lanes around its cursor (`song_edit_state`), its tabs: Song, Clip, Lanes, Arrangement, Markers, Tempo
	Settings,  // Pads' Settings: Audio, Channels, MIDI, Sync (what a headless Pads needs set from a controller)
	Projects,  // the project page: the project open (Save, Save As, Rename), Recent, All, Templates (Open, New, Duplicate, Trash)
}

// A view's buttons a controller presses (`view_press`): the row of choices
// under its knobs (Lower_1..8: 0..7), the row of tabs over them
// (Upper_1..8: 8..15), the page before and after (its knobs' pages), and
// the next device in the chain, the item before and after (Up, Down); and
// the controller's modifiers, pressed
// and let go as they are held (Mute, Solo: the lower row mutes or solos
// the mixer's strips; Shift; Delete: a knob touched goes back to its
// default).
View_Button :: enum i64 {
	Lower_1, Lower_2, Lower_3, Lower_4, Lower_5, Lower_6, Lower_7, Lower_8,
	Upper_1, Upper_2, Upper_3, Upper_4, Upper_5, Upper_6, Upper_7, Upper_8,
	Page_Left,
	Page_Right,
	Next_Device,
	Mute,
	Solo,
	Shift,
	Delete,
	Up,   // the view's item before (a controller's ▲: the device before, the row above, the strips' eight before)
	Down, // the view's item after (▼)
	Select, // a controller's Select (the sequencer: the cursor's note kept in the selection or let go; with Shift, every note of the selected pad)
}

// What a view offers a controller now, as it last drew: its knobs (one an
// encoder, 0..knobs-1), its buttons (bit k: View_Button k is there; `lit`
// bit k: it is on), and its knobs' pages (`page` of `pages`).
View_State :: struct {
	knobs:   i64,
	buttons: i64,
	lit:     i64,
	pages:   i64,
	page:    i64,
}

// A controller's input to a view, waiting for its next drawing (the app's:
// `views_input`), and what it offered when last drawn.
View_Input :: struct {
	turn:     [8]f64, // knob k turned (a fraction of its travel)
	held:     [8]bool, // knob k touched
	ended:    [8]bool, // knob k let go
	pressed:  [32]bool, // View_Button k pressed
	released: [32]bool, // View_Button k let go
	state:    View_State,
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
	input:         View_Input,
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

// Turns knob `knob` (0..7) of view `kind` (`page` of it, any size asked
// for) by `amount`, a fraction of its travel (+ or -): as the knob turned
// in Pads, at its next drawing. Not_Found: no such view asked for.
view_turn :: proc(api: ^Api, kind: View_Kind, page: i64, knob: i64, amount: f64) -> Result {
	w, r := view_of(api, kind, page, knob)
	if r != .Ok do return r
	w.input.turn[knob] += amount
	return .Ok
}

// Knob `knob` of a view touched (`on`) or let go: lit while touched; let
// go, its edit ends (one undo step a touch).
view_touch :: proc(api: ^Api, kind: View_Kind, page: i64, knob: i64, on: bool) -> Result {
	w, r := view_of(api, kind, page, knob)
	if r != .Ok do return r
	w.input.held[knob] = on
	if !on do w.input.ended[knob] = true
	return .Ok
}

// Button `button` (a View_Button) of a view pressed (`on`) or let go: as
// its button clicked in Pads (some act while held: recording).
view_press :: proc(api: ^Api, kind: View_Kind, page: i64, button: i64, on: bool) -> Result {
	if button < 0 || button > i64(max(View_Button)) do return fail(api, .Invalid_Argument, "no such button (View_Button)")
	w, r := view_of(api, kind, page, 0)
	if r != .Ok do return r
	if on do w.input.pressed[button] = true
	else do w.input.released[button] = true
	return .Ok
}

// What view `kind` (`page` of it) offers a controller, as it last drew.
view_state :: proc(api: ^Api, kind: View_Kind, page: i64) -> (View_State, Result) {
	w, r := view_of(api, kind, page, 0)
	if r != .Ok do return {}, r
	return w.input.state, .Ok
}

// A view's input, for the app to give its drawing (and to say what it
// offers, in `state`). The host's.
views_input :: proc(api: ^Api, index: i64) -> ^View_Input {
	if index < 0 || index >= i64(len(api.views)) do return nil
	return &api.views[index].input
}

@(private)
view_of :: proc(api: ^Api, kind: View_Kind, page, control: i64) -> (^View_Want, Result) {
	if control < 0 || control >= 8 do return nil, fail(api, .Invalid_Argument, "a view's knobs are 0..7")
	for &w in api.views do if w.kind == kind && w.page == page do return &w, .Ok
	return nil, fail(api, .Not_Found, "that view isn't asked for (view_frame)")
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
