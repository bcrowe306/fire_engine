package pads_api

import "core:strings"

import pc "../core"

// A message's kind.
Message_Kind :: enum i32 {
	Info,
	Success,
	Warning,
	Error,
}

// The window now (Unsupported without one: a headless Pads).
Ui_State :: struct {
	dark:     bool, // the dark theme
	messages: i64,  // messages showing (ui_message)
	selected: i64,  // pads selected together (ui_selected_pad)
}

// The dialog the window shows now (a controller shows it too: View_Kind
// .Dialog). `choices`: its buttons a controller can press (0: it can't be
// answered there; its title says what it is).
Dialog_State :: struct {
	open:    bool,
	choices: i64,
}

// The dialog the window shows now.
ui_dialog :: proc(api: ^Api) -> (Dialog_State, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return {}, r
	if u.dialog == nil do return {}, .Ok
	title, choices := u.dialog(api.core.hooks.user)
	return {open = title != "", choices = i64(choices)}, .Ok
}

// The dialog's title ("" when none shows). Temporary.
ui_dialog_title :: proc(api: ^Api) -> (string, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return "", r
	if u.dialog == nil do return "", .Ok
	title, _ := u.dialog(api.core.hooks.user)
	return strings.clone(title, context.temp_allocator), .Ok
}

// The window now.
ui_state :: proc(api: ^Api) -> (Ui_State, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return {}, r
	return {dark = u.dark(api.core.hooks.user), messages = i64(len(u.messages(api.core.hooks.user))), selected = i64(len(u.selected_pads(api.core.hooks.user)))}, .Ok
}

// Shows view, panel or device page `name`: a view ("sequence", "song",
// "mixer", "perform"), the pads ("pads"), the Library ("browser",
// "devices"), or the selected pad's page ("sample", "global", "env",
// "filter", "pitch", "lfo", "effect", "eq", "midi"; "device": its chain
// as it was), performance effect N ("fx 1".."fx 16") in the device
// panel, a Library category ("library Effects", "library This Project"),
// the Library for the device shown ("browse device"), the sequencer's
// Automation tab ("automation"), or a dialog: Sequence Length
// ("sequence length"), Quantize's settings ("quantize"), Convert
// ("convert"), Keyboard mode's scale ("scale"), Settings ("settings"),
// Recording ("recording": the Sample control), Transport ("transport":
// loop, count-in, the click, the time signature), Copy Bars ("copy
// bars"), the current sequence's settings ("sequence settings"), launcher
// lane N's ("lane N", from 1). Not_Found for another name.
ui_show :: proc(api: ^Api, name: string) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if !u.show(api.core.hooks.user, name) do return fail(api, .Not_Found, "no such view or page")
	return .Ok
}

// The Library's selected item onto pad `pad`, as its last load did (a
// sample as a sampler, a slicer...; else the item's first action): a
// controller's Shift + pad. Not_Found when nothing is selected or it
// can't go onto a pad.
ui_library_load :: proc(api: ^Api, pad: i64) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if pad < 0 || pad >= PADS do return fail(api, .Not_Found, "a pad is 0..127")
	if u.library_load == nil || !u.library_load(api.core.hooks.user, int(pad)) do return fail(api, .Not_Found, "nothing selected to load onto a pad")
	return .Ok
}

// Whether the project manager shows: the window's page of recent
// projects, templates, New and Open (when Pads starts with no project to
// open, and after New Project). A controller shows its browser on the
// projects meanwhile.
ui_start_page :: proc(api: ^Api) -> (bool, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return false, r
	if u.start_page == nil do return false, .Ok
	return u.start_page(api.core.hooks.user), .Ok
}

// Shows the project manager (`open`), or closes it (the project open now
// stays). Opening or making a project closes it too.
ui_set_start_page :: proc(api: ^Api, open: bool) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if u.set_start_page == nil do return fail(api, .Unsupported, "no project manager")
	u.set_start_page(api.core.hooks.user, open)
	return .Ok
}

// Selects the current sequence's notes `indices` in the sequencer (its
// knobs, the window's and a controller's, edit them); none: nothing
// selected.
ui_select_notes :: proc(api: ^Api, indices: []i64) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if u.select_notes == nil do return fail(api, .Unsupported, "no sequencer")
	s := &api.core.m.project.sequences[api.core.m.project.slot]
	ids := make([]int, len(indices), context.temp_allocator)
	for x, k in indices {
		if x < 0 || x >= i64(len(s.notes)) do return fail(api, .Not_Found, "no such note")
		ids[k] = int(x)
	}
	u.select_notes(api.core.hooks.user, ids)
	return .Ok
}

// The sequencer's grid: where notes snap, a controller's step size.
ui_sequencer_grid :: proc(api: ^Api) -> (Grid, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return .Sixteenth, r
	if u.seq_grid == nil do return .Sixteenth, .Ok
	return Grid(u.seq_grid(api.core.hooks.user)), .Ok
}

// Sets the sequencer's grid.
ui_set_sequencer_grid :: proc(api: ^Api, grid: Grid) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if grid < min(Grid) || grid > max(Grid) do return fail(api, .Invalid_Argument, "no such grid")
	if u.set_seq_grid == nil do return fail(api, .Unsupported, "no sequencer")
	u.set_seq_grid(api.core.hooks.user, int(grid))
	return .Ok
}

// Whether the Sample control is armed (the window's toolbar, the Recording
// dialog): the next pad pressed records into it.
ui_sample_armed :: proc(api: ^Api) -> (bool, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return false, r
	if u.sample_armed == nil do return false, .Ok
	return u.sample_armed(api.core.hooks.user), .Ok
}

// Quantize, as the window's button does: the sequencer's selected notes,
// else the current sequence, as the Quantize setting says
// (`sequence_quantize_setting`); the window says which.
ui_quantize :: proc(api: ^Api) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if u.quantize == nil do return fail(api, .Unsupported, "no Quantize")
	u.quantize(api.core.hooks.user)
	return .Ok
}

// Whether automation recording is armed (the window's Auto): knob and
// fader moves while recording are written into the sequence.
ui_automation_armed :: proc(api: ^Api) -> (bool, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return false, r
	if u.automation_armed == nil do return false, .Ok
	return u.automation_armed(api.core.hooks.user), .Ok
}

// Arms automation recording (`on`), or disarms it.
ui_set_automation_armed :: proc(api: ^Api, on: bool) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if u.set_automation_armed == nil do return fail(api, .Unsupported, "no automation recording")
	u.set_automation_armed(api.core.hooks.user, on)
	return .Ok
}

// The dark theme (`dark`), or the light one. Saved with the settings.
ui_set_dark :: proc(api: ^Api, dark: bool) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	u.set_dark(api.core.hooks.user, dark)
	return .Ok
}

// Shows message `text` for a few seconds (and keeps it in the log).
ui_message_show :: proc(api: ^Api, kind: Message_Kind, text: string) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if kind < min(Message_Kind) || kind > max(Message_Kind) do return fail(api, .Invalid_Argument, "no such kind")
	if strings.trim_space(text) == "" do return fail(api, .Invalid_Argument, "no text")
	u.toast(api.core.hooks.user, int(kind), text)
	return .Ok
}

// Message `index` of those showing (the oldest first). Temporary.
ui_message :: proc(api: ^Api, index: i64) -> (string, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return "", r
	ms := u.messages(api.core.hooks.user)
	if index < 0 || index >= i64(len(ms)) do return "", fail(api, .Not_Found, "no such message")
	return ms[index], .Ok
}

// Selects pads `pads` together (the first the selected pad: what Keyboard
// mode plays and the editors show). Menus of the pads act on them all.
ui_select_pads :: proc(api: ^Api, pads: []i64) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if len(pads) == 0 do return fail(api, .Invalid_Argument, "no pads")
	ps := make([]int, len(pads), context.temp_allocator)
	for p, k in pads {
		if _, pr := pad_of(api, p); pr != .Ok do return pr
		ps[k] = int(p)
	}
	u.select_pads(api.core.hooks.user, ps)
	return .Ok
}

// Pad `index` of those selected together.
ui_selected_pad :: proc(api: ^Api, index: i64) -> (i64, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return -1, r
	ps := u.selected_pads(api.core.hooks.user)
	if index < 0 || index >= i64(len(ps)) do return -1, fail(api, .Not_Found, "no such pad selected")
	return i64(ps[index]), .Ok
}

@(private)
ui_hooks :: proc(api: ^Api) -> (^pc.Ui_Hooks, Result) {
	u := &api.core.hooks.ui
	if u.show == nil do return nil, fail(api, .Unsupported, "no window (a headless Pads)")
	return u, .Ok
}
