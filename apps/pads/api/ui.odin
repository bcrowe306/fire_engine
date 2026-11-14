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

// The window now.
ui_state :: proc(api: ^Api) -> (Ui_State, Result) {
	u, r := ui_hooks(api)
	if r != .Ok do return {}, r
	return {dark = u.dark(api.core.hooks.user), messages = i64(len(u.messages(api.core.hooks.user))), selected = i64(len(u.selected_pads(api.core.hooks.user)))}, .Ok
}

// Shows view, panel or device page `name`: a view ("sequence", "song",
// "mixer", "perform"), the pads ("pads"), the Library ("browser",
// "devices"), or the selected pad's page ("sample", "global", "env",
// "filter", "pitch", "lfo", "effect", "eq", "midi"). Not_Found for
// another name.
ui_show :: proc(api: ^Api, name: string) -> Result {
	u, r := ui_hooks(api)
	if r != .Ok do return r
	if !u.show(api.core.hooks.user, name) do return fail(api, .Not_Found, "no such view or page")
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
