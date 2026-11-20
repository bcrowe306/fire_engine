package pads_push2

import "core:fmt"

import kit "fsurf:surface"
import pa "../../api"

/*
The buttons along the sides that aren't a mode's (docs/design/push2.md,
"The rest of the controls"). Each lights to say what it does now, and a
press says what it did in Pads' message (the window's, and the display's
banner).

- **Double Loop:** the current sequence twice as long, its notes again in
  the new half; in Song, the selected clip twice as long (the lane's later
  clips moving on).
- **New:** a new empty sequence (the next free slot), selected; Shift: a
  copy of the current one.
- **Automate:** automation recording on or off (red while on); held long
  or with Shift: the sequencer's Automation tab (Clip) for the selected pad.
- **Fixed Length:** Pads' Sequence Length dialog (its lengths on the lower
  row); held long or with Shift: the Sequence dialog (colour, tempo, bars,
  the pad's loop, when a sequence takes over; Rename, Duplicate, Clear).
- **Quantize:** input quantize on or off; held long or with Shift: Pads'
  Quantize dialog (quantizing the notes, its settings and input
  quantize's on the encoders). Lit bright while input quantize is on (the
  display shows "IQ 1/16" too).
- **Convert:** Pads' Convert dialog for the selected pad: Make a Slicer,
  Slice onto Pads, Into a Synth, Back to a Sampler (those that fit it),
  Resample Sequence, Resample Pad (onto the next empty pad).
- **Scale:** Pads' Key dialog: the project key's scale, root, octave and
  the chords' voicing on the encoders (lit while the pads are a note mode).
- **Accent:** every pad hit at full velocity (lit while on); held long,
  only while held.
- **Add Device:** Browse on the Library's effects for the selected pad.
- **Add Track:** the next empty pad selected (Song: a new lane); Shift: a
  new mixer bus.
- **Shift + Setup:** Pads' project page on the display (View_Kind.Projects:
  the project open, Save, Save As, Rename; Recent, All, Templates; Open,
  New Empty, Duplicate, Trash); again, or Close, closes it.
- **Setup:** Pads' Settings on the display (View_Kind.Settings: Audio,
  Channels, MIDI, Sync) and in the window; again: back. Shift or held
  long: the Push's own settings on the display (setup.odin).
- **User:** nothing (Pads keeps the Push in User mode): unlit.
*/

// Held at least this long: a button's long press.
LONG_PRESS_NS :: 400_000_000

// The side buttons not a mode's (their controls, by name).
@(private)
extras_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, buttons: map[string]^kit.Control) -> ^kit.Component {
	c := kit.component_make(cs, "Extras")
	bind :: proc(c: ^kit.Component, buttons: map[string]^kit.Control, slot, name: string) {
		if b, ok := buttons[name]; ok do kit.layer_bind(c.layer, slot, b)
	}
	bind(c, buttons, "double", "Double Loop")
	bind(c, buttons, "new", "New")
	bind(c, buttons, "automate", "Automate")
	bind(c, buttons, "fixed", "Fixed Length")
	bind(c, buttons, "quantize", "Quantize")
	bind(c, buttons, "convert", "Convert")
	bind(c, buttons, "scale", "Scale")
	bind(c, buttons, "accent", "Accent")
	bind(c, buttons, "add_device", "Add Device")
	bind(c, buttons, "add_track", "Add Track")
	bind(c, buttons, "setup", "Setup")
	bind(c, buttons, "user", "User")
	c.on_activate = proc(c: ^kit.Component) {
		// The Push's own settings, as kept (setup.odin).
		p := (^Push2)(c.cs.user)
		p.push_settings = setup_load(c.cs)
		setup_apply(c.cs, p.push_settings)
		kit.task_every(c.cs, RENDER_MS, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		held := p.extra_down[slot] != 0
		switch slot {
		case "automate":
			armed: bool
			if t != nil do t.ui_automation_armed(t.api, &armed)
			kit.light_value(control, RED if armed || held else DIM_RED)
		case "user":
			kit.light_value(control, OFF)
		case "scale":
			perf: pa.Perform_State
			if t != nil do t.perform_state(t.api, &perf)
			kit.light_value(control, W_ON if (perf.play_mode == .Scale || perf.play_mode == .Chords || perf.play_mode == .Progressions) || held else W_DIM)
		case "accent":
			on: bool
			if t != nil do t.perform_accent(t.api, &on)
			kit.light_value(control, W_ON if on else W_DIM)
		case "setup":
			kit.light_value(control, W_ON if p.setup_open || held || kit.modes_current(p.enc_modes) == "settings" else W_DIM)
		case "quantize":
			iq: pa.Input_Quantize
			if t != nil do t.sequence_input_quantize(t.api, &iq)
			kit.light_value(control, W_ON if iq.on || held else W_DIM)
		case:
			kit.light_value(control, W_ON if held else W_DIM)
		}
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		#partial switch e.kind {
		case .Press:
			p.extra_down[e.slot] = max(e.time_ns, 1)
			if e.slot == "accent" { // (on at once; held long: only while held)
				t.perform_accent(t.api, &p.accent_was)
				t.perform_set_accent(t.api, true)
			}
		case .Release:
			down := p.extra_down[e.slot]
			p.extra_down[e.slot] = 0
			long := down != 0 && e.time_ns > down && e.time_ns - down >= LONG_PRESS_NS
			extra_press(p, e.slot, long || p.shift.held)
		case:
			return
		}
		kit.redraw_owned(c)
		render(p)
		invalidate(c.cs)
	}
	p.extras = c
	return c
}

// Button `slot` pressed (`alt`: held long, or with Shift).
@(private)
extra_press :: proc(p: ^Push2, slot: string, alt: bool) {
	t := p.pads_api
	cur: i64
	t.sequence_current(t.api, &cur)
	switch slot {
	case "double":
		if kit.modes_current(p.pad_modes) == "song" {
			e: pa.Song_Edit
			t.song_edit_state(t.api, &e)
			if e.clip < 0 {
				say(p, .Warning, "Double Loop: select a clip first (Select + a lane button)")
				return
			}
			sc: pa.Song_Clip
			t.song_clip(t.api, e.clip, &sc)
			if t.song_ripple_resize(t.api, e.clip, sc.length * 2) == .Ok do say(p, .Success, fmt.tprintf("Clip doubled: %g beats", sc.length * 2))
			return
		}
		if t.sequence_double(t.api, cur) != .Ok {
			say(p, .Warning, "Double Loop: it would be longer than 64 bars")
			return
		}
		ss: pa.Sequence_State
		t.sequence_state(t.api, cur, &ss)
		say(p, .Success, fmt.tprintf("%s doubled: %d bars", seq_name(p, cur), ss.bars))
	case "new":
		if alt {
			to: i64
			if t.sequence_duplicate(t.api, cur, &to) != .Ok {
				say(p, .Warning, "Every sequence slot is used")
				return
			}
			say(p, .Success, fmt.tprintf("A copy: %s", seq_name(p, to)))
			return
		}
		for k in i64(0) ..< 64 {
			ss: pa.Sequence_State
			if t.sequence_state(t.api, k, &ss) != .Ok || ss.used || k == cur do continue
			t.sequence_select(t.api, k)
			say(p, .Success, fmt.tprintf("New sequence: %s", seq_name(p, k)))
			return
		}
		say(p, .Warning, "Every sequence slot is used")
	case "automate":
		if alt {
			// The sequencer's Automation tab (the selected pad's lanes).
			p.mirror_kind = .Sequencer
			kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "clip"))
			app_show(p, "automation")
			steps_show(p)
			if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
			return
		}
		armed: bool
		t.ui_automation_armed(t.api, &armed)
		t.ui_set_automation_armed(t.api, !armed)
		say(p, .Info, "Automation recording on: knob moves while recording are written" if !armed else "Automation recording off")
	case "fixed":
		app_show(p, "sequence settings" if alt else "sequence length")
	case "convert":
		app_show(p, "convert")
	case "scale":
		app_show(p, "scale")
	case "accent":
		if alt {
			t.perform_set_accent(t.api, p.accent_was) // (held: momentary)
			return
		}
		t.perform_set_accent(t.api, !p.accent_was)
		say(p, .Info, "Accent on: every pad hit at full velocity" if !p.accent_was else "Accent off")
	case "add_device":
		// The Library's effects for the selected pad (a load: its next empty slot).
		setup_close(p)
		p.mirror_kind = .Browser
		kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "browse"))
		app_show(p, "library Effects")
		if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	case "add_track":
		if alt {
			b: i64
			if t.mixer_add_bus(t.api, &b) != .Ok {
				say(p, .Warning, "There are 16 buses already")
				return
			}
			say(p, .Success, fmt.tprintf("A new bus: Bus %c", 'A' + rune(b)))
			app_show(p, "mixer")
			return
		}
		if kit.modes_current(p.pad_modes) == "song" {
			l: i64
			if t.song_add_lane(t.api, &l) != .Ok {
				say(p, .Warning, "The song has 16 lanes already")
				return
			}
			t.song_select_lane(t.api, l)
			say(p, .Success, fmt.tprintf("A new lane: Lane %d", l + 1))
			return
		}
		perf: pa.Perform_State
		t.perform_state(t.api, &perf)
		for k in i64(1) ..= 128 {
			i := (perf.selected + k) % 128
			ps: pa.Pad_State
			if t.pad_state(t.api, i, &ps) == .Ok && !ps.used {
				t.perform_select_pad(t.api, i)
				say(p, .Success, fmt.tprintf("Pad %c%d selected: empty, ready for a sound", 'A' + rune(i / 16), i % 16 + 1))
				return
			}
		}
		say(p, .Warning, "No empty pad")
	case "setup":
		if alt {
			// Shift + Setup: Pads' project page (again: closed).
			start: bool
			t.ui_start_page(t.api, &start)
			t.ui_set_start_page(t.api, !start)
			return
		}
		if p.setup_open {
			setup_close(p)
			return
		}
		// Pads' Settings on the display (and the window's); again: back.
		if kit.modes_current(p.enc_modes) == "settings" {
			kit.modes_select(p.enc_modes, p.settings_before)
			p.mirror_kind = p.settings_kind
		} else {
			p.settings_before, p.settings_kind = p.enc_modes.current, p.mirror_kind
			p.mirror_kind = .Settings
			kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "settings"))
			app_show(p, "settings")
		}
		if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	case "quantize":
		if alt {
			app_show(p, "quantize")
		} else {
			q: pa.Input_Quantize
			t.sequence_input_quantize(t.api, &q)
			t.sequence_set_input_quantize(t.api, !q.on, q.grid, q.strength, q.swing)
			say(p, .Info, "Input quantize: on" if !q.on else "Input quantize: off")
		}
	}
}

// Pads' message `text` (the window's, and the display's banner).
@(private)
say :: proc(p: ^Push2, kind: pa.Message_Kind, text: string) {
	t := p.pads_api
	t.ui_message_show(t.api, kind, cstring(raw_data(text)), i64(len(text)))
}

// Sequence `slot`'s name. Temporary.
@(private)
seq_name :: proc(p: ^Push2, slot: i64) -> string {
	t := p.pads_api
	buf: [64]u8
	n: i64
	t.sequence_name(t.api, slot, &buf[0], len(buf), &n)
	return fmt.tprintf("%s", string(buf[:min(int(n), len(buf))]))
}

// The Swing encoder: the current sequence's swing and input quantize's
// together (one amount: they rarely differ), 1% a tick (Shift: 0.2%);
// touched, shown over the display (screen.odin), one undo step a touch.
@(private)
swing_setup :: proc(cs: ^kit.Control_Surface, swing: ^kit.Control) -> ^kit.Component {
	c := kit.component_make(cs, "Swing")
	kit.layer_bind(c.layer, "swing", swing)
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		#partial switch e.kind {
		case .Touch:   t.history_gesture_begin(t.api)
		case .Untouch: t.history_gesture_end(t.api)
		case .Delta:
			cur: i64
			t.sequence_current(t.api, &cur)
			ss: pa.Sequence_State
			t.sequence_state(t.api, cur, &ss)
			grid := ss.swing_grid if ss.swing_grid == .Eighth || ss.swing_grid == .Sixteenth else pa.Grid.Sixteenth
			to := clamp(ss.swing + f32(e.delta) * (0.002 if p.shift.held else 0.01), 0, 1)
			t.sequence_set_swing(t.api, cur, to, grid)
			q: pa.Input_Quantize
			t.sequence_input_quantize(t.api, &q)
			t.sequence_set_input_quantize(t.api, q.on, q.grid, q.strength, to)
			invalidate(c.cs)
		}
	}
	return c
}

// The swing now, as the Swing encoder's overlay shows it.
@(private)
swing_text :: proc(p: ^Push2) -> string {
	t := p.pads_api
	if t == nil do return ""
	cur: i64
	t.sequence_current(t.api, &cur)
	ss: pa.Sequence_State
	t.sequence_state(t.api, cur, &ss)
	return fmt.tprintf("%.0f%% on %s", ss.swing * 100, "1/8" if ss.swing_grid == .Eighth else "1/16")
}

// The side buttons that do something else with Shift (lit while it is
// held; the others dark).
SHIFT_FUNCTIONS := []string{"Shift", "Record", "Play", "Metronome", "Fixed Length", "Undo", "Master", "New", "Automate", "Add Track", "Setup", "Quantize", "Accent", "Left", "Right"}

// Shift held: the side buttons with a Shift function lit, the others dark
// (their own lights back when it is let go), and Pads' view told (its
// knobs' names say "fine", a SHIFT badge).
@(private)
shift_hints_setup :: proc(cs: ^kit.Control_Surface) -> ^kit.Component {
	c := kit.component_make(cs, "Shift Hints")
	c.on_activate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		for b in p.sides {
			lit := false
			for n in SHIFT_FUNCTIONS do if b.name == n do lit = true
			kit.light_hold(b, W_ON if lit else OFF)
		}
		shift_tell(p, true)
		invalidate(c.cs)
	}
	c.on_deactivate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		for b in p.sides do kit.light_release(b)
		shift_tell(p, false)
		invalidate(c.cs)
	}
	return c
}

// Pads' views told Shift is held (or not).
@(private)
shift_tell :: proc(p: ^Push2, held: bool) {
	t := p.pads_api
	if t == nil do return
	for k in pa.View_Kind do t.view_press(t.api, k, 0, i64(pa.View_Button.Shift), held)
}
