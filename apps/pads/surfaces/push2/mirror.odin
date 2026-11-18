package pads_push2

import "core:fmt"

import kit "fsurf:surface"
import pa "../../api"

/*
Device: Pads' device panel itself (fire.pads views: View_Kind.Device), the
same state as the window's, so each follows the other:

- the display: the panel as Pads lays it out for Push 2 (its tabs, its
  picture, its knobs, its choices; the pad's meters)
- the upper row: its tabs; the lower row: its choices; Page < and >: its
  knobs' pages; Device again: the next device in the chain
- the encoders: its knobs (Shift: finer); touched, lit; a touch an undo step

Browse and Clip are the same, on Pads' browser and its launcher (View_Kind
.Browser, .Clip).

A dialog in the window shows on the display over any mode (View_Kind
.Dialog), its choices on the lower row; one it can't show (to type into) is
named, with where to answer it.
*/

// A turn of an encoder: this much of a knob's travel (Shift: a tenth).
TURN :: 1.0 / 160

// Whether Device is Pads' own panel (Pads is there: fire.pads).
uses_tabs :: proc(p: ^Push2) -> bool { return p.pads_api != nil }

// The view's state as Pads last drew it.
@(private)
view_now :: proc(p: ^Push2, kind: pa.View_Kind) -> (st: pa.View_State) {
	t := p.pads_api
	if t != nil do t.view_state(t.api, kind, 0, &st)
	return
}

// A view button's light: lit, there, or off.
@(private)
light_button :: proc(c: ^kit.Control, st: pa.View_State, b: pa.View_Button) {
	bit := i64(1) << uint(b)
	switch {
	case st.lit & bit != 0:     kit.light_value(c, WHITE)
	case st.buttons & bit != 0: kit.light_value(c, DIM_WHITE)
	case:                       kit.light_value(c, OFF)
	}
}

@(private)
press :: proc(p: ^Push2, kind: pa.View_Kind, b: pa.View_Button, on: bool) {
	t := p.pads_api
	if t != nil do t.view_press(t.api, kind, 0, i64(b), on)
}

@(private)
mirror_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, page_l, page_r: ^kit.Control) -> []^kit.Component {
	// The rows and Page < >: the panel's buttons.
	rows := kit.component_make(cs, "Panel Buttons")
	for b in p.upper do kit.layer_bind(rows.layer, "upper", b)
	for b in p.lower do kit.layer_bind(rows.layer, "lower", b)
	kit.layer_bind(rows.layer, "page_left", page_l)
	kit.layer_bind(rows.layer, "page_right", page_r)
	rows.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 80, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	rows.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		st := view_now(p, p.mirror_kind)
		switch slot {
		case "upper": light_button(control, st, pa.View_Button(int(pa.View_Button.Upper_1) + row_index(p.upper, control)))
		case "lower": light_button(control, st, pa.View_Button(row_index(p.lower, control)))
		case "page_left": kit.light_value(control, W_ON if st.page > 0 else W_DIM)
		case "page_right": kit.light_value(control, W_ON if st.page < st.pages - 1 else W_DIM)
		}
	}
	rows.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		if e.kind != .Press && e.kind != .Release do return
		on := e.kind == .Press
		switch e.slot {
		case "upper":
			k := row_index(p.upper, e.control)
			// Perform: Select + a lane's name, the lane's dialog (its
			// colour, its name).
			if p.select_held && p.mirror_kind == .Clip && k < 4 {
				if on && p.pads_api != nil {
					v: pa.Launcher_View
					p.pads_api.launcher_view(p.pads_api.api, &v)
					app_show(p, fmt.tprintf("lane %d", v.lane + i64(k) + 1))
				}
				return
			}
			press(p, p.mirror_kind, pa.View_Button(int(pa.View_Button.Upper_1) + k), on)
			// Perform: a lane's name, its sequence in Clip.
			if on && p.mirror_kind == .Clip && k < 4 {
				p.mirror_kind = .Sequencer
				kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "clip"))
				app_show(p, "sequence")
			}
		case "lower": press(p, p.mirror_kind, pa.View_Button(row_index(p.lower, e.control)), on)
		case "page_left": press(p, p.mirror_kind, .Page_Left, on)
		case "page_right": press(p, p.mirror_kind, .Page_Right, on)
		}
		invalidate(c.cs)
	}
	// The encoders: the panel's knobs.
	knobs := kit.component_make(cs, "Panel Knobs")
	for e in p.encoders do kit.layer_bind(knobs.layer, "knob", e)
	knobs.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		k := row_index(p.encoders, e.control)
		if t == nil || k < 0 do return
		#partial switch e.kind {
		case .Touch:   t.view_touch(t.api, p.mirror_kind, 0, i64(k), true)
		case .Untouch: t.view_touch(t.api, p.mirror_kind, 0, i64(k), false)
		case .Delta:
			p.steps.turned_ns = e.time_ns // (a step held and edited: kept on its release)
			t.view_turn(t.api, p.mirror_kind, 0, i64(k), f64(e.delta) * TURN / (10 if p.shift.held else 1))
		}
	}
	out := make([]^kit.Component, 2)
	out[0], out[1] = rows, knobs
	return out
}

// A dialog in the window: over any mode, its choices on the lower row.
@(private)
dialog_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2) {
	choices := kit.component_make(cs, "Dialog Choices", priority = 10)
	for b in p.lower do kit.layer_bind(choices.layer, "choice", b)
	choices.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		light_button(control, view_now(p, .Dialog), pa.View_Button(row_index(p.lower, control)))
	}
	choices.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		if e.kind != .Press && e.kind != .Release do return
		press(p, .Dialog, pa.View_Button(row_index(p.lower, e.control)), e.kind == .Press)
	}
	// Its name editor (a text field): the encoders and the upper row.
	editor := kit.component_make(cs, "Dialog Editor", priority = 10)
	for e in p.encoders do kit.layer_bind(editor.layer, "knob", e)
	for b in p.upper do kit.layer_bind(editor.layer, "upper", b)
	editor.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		if slot == "upper" do light_button(control, view_now(p, .Dialog), pa.View_Button(int(pa.View_Button.Upper_1) + row_index(p.upper, control)))
	}
	editor.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		if e.slot == "upper" {
			if e.kind == .Press || e.kind == .Release do press(p, .Dialog, pa.View_Button(int(pa.View_Button.Upper_1) + row_index(p.upper, e.control)), e.kind == .Press)
			return
		}
		k := row_index(p.encoders, e.control)
		#partial switch e.kind {
		case .Touch:   t.view_touch(t.api, .Dialog, 0, i64(k), true)
		case .Untouch: t.view_touch(t.api, .Dialog, 0, i64(k), false)
		case .Delta:   t.view_turn(t.api, .Dialog, 0, i64(k), f64(e.delta) * TURN)
		}
	}
	p.dialog_modes = kit.modes_make(cs, "Dialog")
	kit.modes_add(p.dialog_modes, "none", {})
	kit.modes_add(p.dialog_modes, "open", {choices, editor})
	// Watched ten times a second (and the window's panel followed).
	watch := kit.component_make(cs, "Watch Pads")
	watch.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 100, proc(data: rawptr) {
			c := (^kit.Component)(data)
			p := (^Push2)(c.cs.user)
			t := p.pads_api
			if t == nil do return
			d: pa.Dialog_State
			t.ui_dialog(t.api, &d)
			if d.open != p.dialog_open {
				p.dialog_open = d.open
				kit.modes_select(p.dialog_modes, 1 if d.open else 0)
				invalidate(c.cs)
			}
			if d.open do for x in p.dialog_modes.modes[1].components do kit.redraw_owned(x)
			// Pads' project manager showing: Browse, on the projects (the
			// Library's: Pads chose them); gone (a project chosen): Mix.
			start: bool
			t.ui_start_page(t.api, &start)
			if start != p.start_shown {
				p.start_shown = start
				browsing := kit.modes_current(p.enc_modes) == "browse"
				if start && !browsing {
					p.mirror_kind = .Browser
					kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "browse"))
				} else if !start && browsing {
					mix_select(p, p.mix_page)
				}
				if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
				invalidate(c.cs)
			}
			// Pads' play mode chosen in the window: Note follows it.
			perf: pa.Perform_State
			t.perform_state(t.api, &perf)
			cur := kit.modes_current(p.pad_modes)
			if perf.play_mode == .Velocity && cur != "velocity" do kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "velocity"))
			else if perf.play_mode != .Velocity && cur == "velocity" do kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "pads"))
			if perf.play_mode == .Keyboard && cur != "note" do kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "note"))
			else if perf.play_mode != .Keyboard && cur == "note" do kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "pads"))
		}, c, c)
	}
	p.watch = watch
}

// Shows the window's part a mode is about ("mixer", "device", "pads",
// "perform").
@(private)
app_show :: proc(p: ^Push2, name: string) {
	t := p.pads_api
	if t == nil do return
	t.ui_show(t.api, cstring(raw_data(name)), i64(len(name)))
}
