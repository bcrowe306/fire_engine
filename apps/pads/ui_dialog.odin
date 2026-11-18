// Dialogs, mirrored on a controller's display (Push 2's): each modal the
// window shows goes through `modal_begin`, which notes its title; its words
// (`modal_text`) and its buttons (`modal_button`) are noted too, and a
// controller's press of one of them is that button clicked. A text field
// (`modal_input`) is noted too: the controller's name editor types into it
// (encoder 1 the cursor, encoder 2 the letter; Delete, Space, Caps, Clear
// on the upper row). A dialog that notes no buttons is only named on the
// controller: answer it in the window. A dialog's settings (`modal_knob`)
// are the controller's encoders: their names and values over them, a turn
// a step of the setting.
package pads

import "core:fmt"
import "core:strings"

import "app:ui"
import pa "api"
import im "deps:imgui"

// A dialog's mirror: what it showed this frame and last.
Dialog_Mirror :: struct {
	now, shown: Dialog_Note,
	press:      int, // a choice a controller pressed, plus 1, for the next frame (0: none)
	turns:      [8]int, // steps a controller's encoders turned each knob, for the next frame
	gen:        int, // the text field's id changes when a controller edits it (the window shows its text)
	cursor:     int, // the name editor's place in the text
	caps:       bool,
	edit_of:    [64]u8, // the dialog the cursor is for (another: it starts at the text's end)
	edit_of_n:  int,
}

// What a dialog showed in a frame.
Dialog_Note :: struct {
	title:   [64]u8,
	title_n: int,
	lines:   [6][160]u8,
	line_n:  [6]int,
	lines_n: int,
	choices: [8][32]u8,
	choice_n: [8]int,
	n:       int,
	input:   []u8, // its text field's buffer (NUL-terminated), if it has one
	knobs:   [8]Dialog_Knob, // its settings a controller's encoders turn
	knob_n:  int,
}

// A dialog's setting, as a controller shows it over an encoder.
Dialog_Knob :: struct {
	label:   [24]u8,
	label_n: int,
	text:    [32]u8,
	text_n:  int,
	fine:    bool, // a step a detent (else three: a choice's)
}

// The dialog's title ("": none).
dialog_title :: proc(n: ^Dialog_Note) -> string { return string(n.title[:n.title_n]) }
// Its line `k` of words.
dialog_line :: proc(n: ^Dialog_Note, k: int) -> string { return string(n.lines[k][:n.line_n[k]]) }
// Its choice `k`.
dialog_choice :: proc(n: ^Dialog_Note, k: int) -> string { return string(n.choices[k][:n.choice_n[k]]) }

// Begins modal `title` as im.BeginPopupModal does, noting it.
modal_begin :: proc(a: ^App, title: cstring, open: ^bool = nil, flags: im.WindowFlags = {}) -> bool {
	if !im.BeginPopupModal(title, open, flags) do return false
	d := &a.dialog.now
	shown := string(ui.shown_label(title))
	if i := strings.index(shown, "###"); i >= 0 do shown = shown[:i]
	d.title_n = copy(d.title[:], shown)
	return true
}

// Words in a modal, as im.TextWrapped shows them, noted (a controller shows
// them too).
modal_text :: proc(a: ^App, text: string, dim := false) {
	if dim do im.TextDisabled("%s", text)
	else do im.TextWrapped("%s", text)
	d := &a.dialog.now
	for line in strings.split_lines(text, context.temp_allocator) {
		if d.lines_n >= len(d.lines) do break
		d.line_n[d.lines_n] = copy(d.lines[d.lines_n][:], line)
		d.lines_n += 1
	}
}

// A modal's text field, as im.InputText, noted: a controller's name editor
// types into `buf` (the field's id changes when it does, so the window
// shows the text). Whether Enter was pressed.
modal_input :: proc(a: ^App, id: string, buf: []u8, flags: im.InputTextFlags = {}) -> bool {
	a.dialog.now.input = buf
	return im.InputText(fmt.ctprintf("%s%d", id, a.dialog.gen), cstring(&buf[0]), len(buf), flags)
}

// A modal's button, noted: clicked, or pressed on a controller.
modal_button :: proc(a: ^App, label: cstring, size := im.Vec2{}) -> bool {
	clicked := im.Button(label, size)
	d := &a.dialog.now
	k := d.n
	if k < len(d.choices) {
		d.choice_n[k] = copy(d.choices[k][:], string(ui.shown_label(label)))
		d.n += 1
		if a.dialog.press == k + 1 {
			a.dialog.press = 0
			clicked = true
		}
	}
	return clicked
}

// A modal's setting, noted: a controller's encoder (the next free) shows
// `label` and `text` and turns it. The steps it was turned since (the
// window draws its own control for it, and applies these).
modal_knob :: proc(a: ^App, label, text: string, fine := false) -> int {
	d := &a.dialog.now
	k := d.knob_n
	if k >= len(d.knobs) do return 0
	x := &d.knobs[k]
	x.label_n = copy(x.label[:], label)
	x.text_n = copy(x.text[:], text)
	x.fine = fine
	d.knob_n += 1
	n := a.dialog.turns[k]
	a.dialog.turns[k] = 0
	return n
}

// After the window's frame: what its dialog showed is what a controller
// shows now.
dialog_frame :: proc(a: ^App) {
	a.dialog.shown = a.dialog.now
	a.dialog.now = {}
	if dialog_title(&a.dialog.shown) == "" {
		a.dialog.press = 0
		a.dialog.turns = {}
	}
}

// The dialog view (View_Kind.Dialog): its title, its words, its choices on
// the row of buttons. One not answered there: where to answer it.
view_dialog :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	d := &a.dialog.shown
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	title := dialog_title(d)
	if title == "" do return
	top: f32 = 6 if d.input == nil else CTL_TABS_H + 2 // (a text field: the name editor's buttons above)
	body_bottom := o.y + full.y - CTL_BUTTONS_H - 6 - (48 if d.knob_n > 0 else 0) // (settings: their boxes under it)
	im.DrawList_AddRectFilled(dl, {o.x + 8, o.y + top}, {o.x + full.x - 8, body_bottom}, ui.col(t.raised), t.radius)
	im.PushFontFloat(a.platform.fonts.bold, 22)
	im.DrawList_AddText(dl, {o.x + 24, o.y + top + 6}, ui.col(t.text), fmt.ctprintf("%s", title))
	im.PopFont()
	y := o.y + top + (40 if d.input == nil else 32)
	if d.n == 0 {
		im.DrawList_AddText(dl, {o.x + 24, y}, ui.col(t.accent), "Pads is asking something on the computer: answer it there.")
		return
	}
	for k in 0 ..< d.lines_n {
		im.DrawList_AddText(dl, {o.x + 24, y}, ui.col(t.text if k == 0 else t.text_dim), fmt.ctprintf("%s", dialog_line(d, k)))
		y += im.GetTextLineHeight() + 4
	}
	if d.input != nil do name_editor(ctx, d.input, y, full)
	for k in 0 ..< d.n {
		if p, _ := ctl_button(ctx, k, fmt.ctprintf("%s", dialog_choice(d, k)), false, full); p do a.dialog.press = k + 1
	}
	// Its settings on the encoders (their boxes over the lower row).
	if d.knob_n > 0 {
		plot := im.Vec2{full.x, full.y - CTL_PLOT_Y - 46 - CTL_BUTTONS_H - 2}
		for k in 0 ..< d.knob_n {
			x := &d.knobs[k]
			n, _ := ctl_value_box(ctx, k, fmt.ctprintf("%s", string(x.label[:x.label_n])), string(x.text[:x.text_n]), 1.0 / 160 if x.fine else CTL_STEP, plot)
			a.dialog.turns[k] += n
		}
	}
	im.Dummy({1, 1})
}

// The window's dialog, for the API (ui_dialog).
dialog_hook :: proc(user: rawptr) -> (string, int) {
	a := (^App)(user)
	d := &a.dialog.shown
	// (Settings: a controller shows its own view of them, View_Kind
	// .Settings; its "Keep these settings?" is a dialog of its own.)
	if strings.has_prefix(dialog_title(d), "Settings") do return "", 0
	return dialog_title(d), d.n
}

_ :: pa

// The letters the name editor turns through (Caps: the capitals).
NAME_LETTERS :: "abcdefghijklmnopqrstuvwxyz0123456789 -_.'&()#"
NAME_CAPITALS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.'&()#"

// The name editor: a dialog's text field on the display, the letter at
// the cursor boxed. Encoder 1 moves the cursor (past the end: a new
// letter), encoder 2 turns its letter; the upper row: Delete (the letter
// before the cursor), Space, Caps, Clear. The dialog's buttons below.
@(private)
name_editor :: proc(ctx: ^View_Ctx, buf: []u8, y: f32, full: im.Vec2) {
	a := ctx.a
	mx := &a.dialog
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	n := 0
	for n < len(buf) && buf[n] != 0 do n += 1
	// Another dialog: the cursor at the end of its text.
	title := dialog_title(&mx.shown)
	if string(mx.edit_of[:mx.edit_of_n]) != title {
		mx.edit_of_n = copy(mx.edit_of[:], title)
		mx.cursor = n
	}
	edited := false
	letters := NAME_CAPITALS if mx.caps else NAME_LETTERS
	if d := ctl_steps(0, CTL_STEP); d != 0 do mx.cursor = clamp(mx.cursor + d, 0, min(n, len(buf) - 2))
	if d := ctl_steps(1, CTL_STEP); d != 0 && len(buf) > 1 {
		if mx.cursor >= n { // (past the end: a new letter, then turned)
			if n < len(buf) - 1 {
				buf[n] = letters[0]
				n += 1
				buf[n] = 0
				d -= 1 if d > 0 else 0
			}
		}
		if mx.cursor < n {
			at := strings.index_byte(letters, buf[mx.cursor])
			if at < 0 do at = 0
			buf[mx.cursor] = letters[((at + d) % len(letters) + len(letters)) % len(letters)]
		}
		edited = true
	}
	inp := ctx.input
	pressed :: proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp != nil && inp.pressed[int(b)] }
	if pressed(inp, .Upper_1) && mx.cursor > 0 { // Delete: the letter before the cursor
		copy(buf[mx.cursor - 1:], buf[mx.cursor:n + 1])
		mx.cursor -= 1
		n -= 1
		edited = true
	}
	if pressed(inp, .Upper_2) && n < len(buf) - 1 { // Space
		copy(buf[mx.cursor + 1:], buf[mx.cursor:n + 1])
		buf[mx.cursor] = ' '
		mx.cursor += 1
		n += 1
		edited = true
	}
	if pressed(inp, .Upper_3) do mx.caps = !mx.caps
	if pressed(inp, .Upper_4) { // Clear
		buf[0] = 0
		n, mx.cursor = 0, 0
		edited = true
	}
	if edited do mx.gen += 1 // (the window's field shows it)
	upper :: proc(ctx: ^View_Ctx, k: int, label: string, on: bool) { ctl_upper(ctx, k, label, on) }
	upper(ctx, 0, "Delete", false)
	upper(ctx, 1, "Space", false)
	upper(ctx, 2, "Caps", mx.caps)
	upper(ctx, 3, "Clear", false)
	// The field: the text, the letter at the cursor boxed.
	im.PushFontFloat(a.platform.fonts.semibold, 22)
	defer im.PopFont()
	x0 := o.x + 24
	fy := y + 4
	fh := im.GetTextLineHeight() + 10
	im.DrawList_AddRectFilled(dl, {x0 - 6, fy}, {o.x + full.x - 24, fy + fh}, ui.col(t.bg), t.radius)
	text := string(buf[:n])
	x := x0
	for i in 0 ..= n {
		ch := text[i:i + 1] if i < n else " "
		w := im.CalcTextSize(fmt.ctprintf("%s", ch)).x
		if i == mx.cursor {
			im.DrawList_AddRectFilled(dl, {x - 1, fy + 3}, {x + max(w, 10) + 1, fy + fh - 3}, ui.col(t.accent), 3)
		}
		im.DrawList_AddText(dl, {x, fy + 5}, ui.col(t.bg if i == mx.cursor else t.text), fmt.ctprintf("%s", ch))
		x += max(w, 10) if i == mx.cursor && i == n else w
	}
	ui.text_push(.Caption)
	im.DrawList_AddText(dl, {x0, fy + fh + 4}, ui.col(t.text_dim), "Encoder 1: move · Encoder 2: letter")
	ui.text_pop()
	ui.knob_input.drawn = max(ui.knob_input.drawn, 2)
}
