package pads_push2

import "core:time"

import kit "fsurf:surface"
import pa "../../api"

/*
The pads in Session, two ways (Session switches between them):

- **Pads:** the grid is Pads' pads, the first at the bottom left, along
  each row to the top right (64 a page: A1-D16, then E1-H16; Octave Up
  and Down turn the page). Each in its pad's colour from the app (an
  empty pad dim), flashing bright as it sounds (a press, the sequencer),
  the selected pad white, a held one green. A press plays the pad
  (remapped to its note: no added latency) and selects it; with Delete
  held, it clears it.
- **Sequences:** (the display: the Performance view's launcher) the grid
  is Pads' 64 sequences in the same order, lit in their colours: the one
  shown white, a playing one flashing green on every beat, a queued one
  on every eighth (in time with the tempo). A press launches the sequence
  as the Performance tab does (an empty one is only gone to); with Shift,
  it is only gone to.

Note, Pads' Keyboard mode: the grid is its keys, 0 at the bottom left
along each row (64 of them: four of Pads' banks of keys), each playing the
selected pad pitched as pressing that key in Pads does (its chord too).
The scale's roots light in the pad's colour, the other keys dim white,
the held green; keys past the pad's range are dark.

A grid sends no lights: it is a stack of layers (the frame's, bottom to
top), drawn and sent by the renderer (render.odin).
*/

// What the grid shows.
Grid_Kind :: enum {
	Pads,
	Perform,
	Keys,
	Song, // (song.odin)
	Steps, // Clip's: steps, the bank's pads, the pages (steps.odin)
	Velocity, // Layout again: the selected pad at 16 velocities, the bank's pads
}

// The pads as Pads' pads, its sequences, or its keys.
Grid :: struct {
	using component: kit.Component,
	kind:   Grid_Kind,
	pads:   ^kit.Matrix,
	layers: []Layer, // bottom to top
	held:   [64]bool,
	struck: [pa.PADS]i64, // each pad's hits as last seen
	lit:    [pa.PADS]time.Tick, // when each pad's flash ends
	routed_bank: i64, // Perform: the bank its pads' quarter is routed to
}

// How long a pad flashes after it sounds (the window's pads: 0.12 s).
FLASH_MS :: 120

// The grid's index of a pad: 0 at the bottom left, along each row.
grid_index :: proc(c: ^kit.Control) -> int {
	return (7 - c.row) * 8 + c.col
}

@(private)
grid_make :: proc(cs: ^kit.Control_Surface, name: string, pads: ^kit.Matrix, kind: Grid_Kind) -> ^Grid {
	g := new(Grid)
	kit.component_init(cs, &g.component, name)
	g.kind = kind
	g.pads = pads
	switch kind {
	case .Pads:      g.layers = PADS_LAYERS
	case .Perform:   g.layers = PERFORM_LAYERS
	case .Keys:      g.layers = KEY_LAYERS
	case .Song:      g.layers = SONG_LAYERS
	case .Steps:     g.layers = STEPS_LAYERS
	case .Velocity:  g.layers = VELOCITY_LAYERS
	}
	kit.layer_bind_matrix(g.layer, "pads", pads)
	g.on_activate = proc(c: ^kit.Component) {
		g := (^Grid)(c)
		if t := (^Push2)(c.cs.user).pads_api; t != nil do for &n, i in g.struck do t.pad_struck(t.api, i64(i), &n) // (old hits: no flash)
		g.lit = {}
		render_show((^Push2)(c.cs.user), g)
	}
	g.on_deactivate = proc(c: ^kit.Component) {
		g := (^Grid)(c)
		p := (^Push2)(c.cs.user)
		if t := p.pads_api; t != nil && g.kind == .Keys {
			for h, i in g.held do if h do t.perform_play_key(t.api, i64(i), false, 1)
		}
		g.held = {}
		if p.render.grid == g do render_show(p, nil)
	}
	g.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		grid_route((^Grid)(c), control)
	}
	g.on_event = proc(c: ^kit.Component, e: kit.Event) {
		g := (^Grid)(c)
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		i := grid_index(e.control)
		#partial switch e.kind {
		case .Press:
			g.held[i] = true
			switch g.kind {
			case .Pads:
				n := p.pad_page * 64 + i
				if n >= pa.PADS do return
				if p.delete_held { // (Delete held: cleared, undoably, as Pads' Clear Pad)
					t.pad_clear(t.api, i64(n))
					g.held[i] = false
					render(p)
					return
				}
				// Browsing, Shift: the Library's selected item onto it (as
				// its last load: a sampler, a slicer...).
				if p.shift.held && kit.modes_current(p.enc_modes) == "browse" {
					t.ui_library_load(t.api, i64(n))
					render(p)
					return
				}
				// (it sounds through its remap; here it's selected)
				t.perform_select_pad(t.api, i64(n))
			case .Keys:
				t.perform_play_key(t.api, i64(i), true, clamp(f32(e.velocity) / 127, 1.0 / 127, 1))
				// (a slicer's slice: selected, its page showing it)
				perf: pa.Perform_State
				st: pa.Pad_State
				k: pa.Perform_Key
				t.perform_state(t.api, &perf)
				t.pad_state(t.api, perf.selected, &st)
				if st.kind == .Slicer && t.perform_key(t.api, i64(i), &k) == .Ok {
					sl: pa.Pad_Slices
					t.pad_slices(t.api, perf.selected, &sl)
					if k.pitch >= 0 && k.pitch < sl.count do t.pad_select_slice(t.api, k.pitch)
				}
			case .Perform:
				perform_press(g, i, true, f32(e.velocity) / 127)
			case .Song:
				song_press(p, i)
			case .Steps:
				steps_press(g, i, f32(e.velocity) / 127, e.time_ns)
			case .Velocity:
				if k := bank_pad_of(i); k >= 0 { // (left: the velocities)
					perf: pa.Perform_State
					t.perform_state(t.api, &perf)
					t.pad_play(t.api, perf.selected, true, f32(k + 1) / 16)
				} else if b := velocity_bank_pad(i); b >= 0 {
					perf: pa.Perform_State
					t.perform_state(t.api, &perf)
					if pad := perf.bank * 16 + i64(b); pad < pa.PADS do t.perform_select_pad(t.api, pad)
				}
			}
		case .Release:
			g.held[i] = false
			if g.kind == .Keys do t.perform_play_key(t.api, i64(i), false, 1)
			if g.kind == .Perform do perform_press(g, i, false, 0)
			if g.kind == .Steps do steps_release(g, i)
			if g.kind == .Velocity && bank_pad_of(i) >= 0 {
				perf: pa.Perform_State
				t.perform_state(t.api, &perf)
				t.pad_play(t.api, perf.selected, false, 0)
			}
		case .Pressure:
			if g.kind == .Perform do perform_pressure(g, i, e.value)
			return
		case:
			return
		}
		render(p)
	}
	return g
}

// Turns the Pads grid's page (64 pads a page).
@(private)
grid_page :: proc(g: ^Grid, to: int) {
	p := (^Push2)(g.cs.user)
	page := clamp(to, 0, (pa.PADS + 63) / 64 - 1)
	if page == p.pad_page do return
	p.pad_page = page
	g.held = {}
	for c in g.pads.controls do if kit.owns(g, c) do grid_route(g, c)
	render(p)
	invalidate(g.cs)
}

// A pad's route: Pads' pads play their notes (Pads' drum map: note N
// plays pad N); sequences and keys are the surface's.
@(private)
grid_route :: proc(g: ^Grid, c: ^kit.Control) {
	p := (^Push2)(g.cs.user)
	n := p.pad_page * 64 + grid_index(c)
	if g.kind == .Perform { // (the pads' quarter: its bank's)
		q, col, row := perform_cell(grid_index(c))
		n = perform_pad(p.pads_api, col, row) if q == .Pads && p.pads_api != nil else pa.PADS
	}
	if g.kind == .Steps { // (the bank's pads play: the rest are the surface's)
		n = pa.PADS
		if b := bank_pad_of(grid_index(c)); b >= 0 && p.pads_api != nil && !p.delete_held && !p.dup_held {
			perf: pa.Perform_State
			p.pads_api.perform_state(p.pads_api.api, &perf)
			n = int(perf.bank) * 16 + b
		}
	}
	if (g.kind == .Pads || g.kind == .Perform || g.kind == .Steps) && n < pa.PADS && !p.delete_held do kit.set_route(c, .Remap, u8(n), pa.PADS_CHANNEL) // (the pads only: not an armed synth's keys)
	else do kit.set_route(c, .Claim)
}

// --- the layers ---------------------------------------------------------------------------------

// Pads: their colours (the selected white, a sounding one flashing), the held.
PADS_LAYERS := []Layer{pads_layer, held_layer}

// Keys: the scale (roots in the pad's colour), the held.
KEY_LAYERS := []Layer{keys_base, held_layer}

// A pad's colour, its brightness unlit (lit: flashing as it sounds).
PAD_UNLIT :: 0.45

// The page's pads.
@(private)
pads_layer :: proc(g: ^Grid, f: ^Frame) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	if t == nil do return
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	for i in 0 ..< 64 {
		n := p.pad_page * 64 + i
		if n < pa.PADS do f[i] = pad_cell(g, n, perf.selected == i64(n))
	}
}

// Pad `n` as every grid shows it: its colour (an empty one an eighth as
// bright), white when `selected`, its full colour for FLASH_MS after it
// sounds (a press, the sequencer, a controller).
@(private)
pad_cell :: proc(g: ^Grid, n: int, selected: bool) -> Cell {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	st: pa.Pad_State
	if t.pad_state(t.api, i64(n), &st) != .Ok do return {}
	c := u32(st.color) & 0xFFFFFF
	cell := cell_colour(scale(c, PAD_UNLIT) if st.used else dim(c, 8))
	if selected do cell = cell_index(WHITE)
	hits: i64
	if t.pad_struck(t.api, i64(n), &hits) == .Ok && hits != g.struck[n] {
		g.struck[n] = hits
		g.lit[n] = time.tick_add(p.render.now, FLASH_MS * time.Millisecond)
	}
	if time.tick_diff(p.render.now, g.lit[n]) > 0 do cell = cell_colour(c, fallback = WHITE)
	return cell
}

// A held pad: green.
@(private)
held_layer :: proc(g: ^Grid, f: ^Frame) {
	for h, i in g.held do if h do f[i] = cell_index(GREEN)
}

// Where in its beat `beat` is (0..1).
@(private)
beat_phase :: proc(beat: f64) -> f64 {
	return beat - f64(int(beat)) if beat >= 0 else 0
}

// The keys: a root in the selected pad's colour, the others dim white,
// past the pad's range dark.
@(private)
keys_base :: proc(g: ^Grid, f: ^Frame) {
	t := (^Push2)(g.cs.user).pads_api
	if t == nil do return
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	st: pa.Pad_State
	t.pad_state(t.api, perf.selected, &st)
	if st.kind == .Slicer { // (a slicer: a pad a slice, the selected white, the sounding one bright)
		sl: pa.Pad_Slices
		t.pad_slices(t.api, perf.selected, &sl)
		for i in 0 ..< 64 {
			k: pa.Perform_Key
			if t.perform_key(t.api, i64(i), &k) != .Ok || k.pitch < 0 || k.pitch >= sl.count do continue
			switch {
			case k.pitch == sl.playing:  f[i] = cell_colour(u32(st.color))
			case k.pitch == sl.selected: f[i] = cell_index(WHITE)
			case:                        f[i] = cell_colour(scale(u32(st.color), 0.45))
			}
		}
		return
	}
	for i in 0 ..< 64 {
		k: pa.Perform_Key
		if t.perform_key(t.api, i64(i), &k) != .Ok || !k.playable do continue
		f[i] = cell_colour(u32(st.color)) if k.root else cell_index(DIM_WHITE)
	}
}

// Whether sequence `slot` plays in its lane now, whether it is queued,
// and the beat on the timeline (to blink in time).
@(private)
sequence_playing :: proc(t: ^pa.Table_V1, slot: int) -> (playing, queued: bool, beat: f64) {
	tr: pa.Transport_State
	if t.transport_state(t.api, &tr) != .Ok || !tr.playing do return // (stopped, a lane's sequence is only its current one)
	beat = tr.timeline_beat
	ls: pa.Launcher_State
	if t.launcher_state(t.api, &ls) != .Ok do return
	for lane in 0 ..< ls.lanes {
		l: pa.Lane_State
		if t.launcher_lane(t.api, lane, &l) != .Ok do continue
		if l.playing == i64(slot) do playing = true
		if l.queued == i64(slot) do queued = true
	}
	return
}

// A colour 1/`n` as bright.
@(private)
dim :: proc(c: u32, n: u32) -> u32 {
	return ((c >> 16 & 0xFF) / n) << 16 | ((c >> 8 & 0xFF) / n) << 8 | (c & 0xFF) / n
}

// Session: Pads' pads, or its sequences (each press the other); Octave Up
// and Down turn the pads' page.
@(private)
grid_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, pads: ^kit.Matrix, session_b, octave_up, octave_down: ^kit.Control) -> (pads_mode, seq_mode: []^kit.Component) {
	p.pad_grid = grid_make(cs, "Session Pads", pads, .Pads)
	p.seq_grid = grid_make(cs, "Session Perform", pads, .Perform)
	nav := perform_nav_setup(cs, p, octave_up, octave_down)
	page := kit.component_make(cs, "Pad Page")
	kit.layer_bind(page.layer, "up", octave_up)
	kit.layer_bind(page.layer, "down", octave_down)
	page.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		last := (pa.PADS + 63) / 64 - 1
		on := p.pad_page < last if slot == "up" else p.pad_page > 0
		kit.light_value(control, W_ON if on else W_DIM)
	}
	page.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		grid_page(p.pad_grid, p.pad_page + (1 if e.slot == "up" else -1))
		kit.redraw_owned(c)
	}
	button := kit.component_make(cs, "Session Button")
	kit.layer_bind(button.layer, "session", session_b)
	button.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		switch kit.modes_current(p.pad_modes) {
		case "pads":      kit.light_value(control, session_light(p, W_ON))
		case "sequences": kit.light_value(control, session_light(p, W_HALF))
		case:             kit.light_value(control, session_light(p, W_DIM))
		}
	}
	button.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		next := "sequences" if kit.modes_current(p.pad_modes) == "pads" else "pads"
		kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, next))
		app_show(p, "perform" if next == "sequences" else "pads") // (the window follows)
		// Sequences: the display the Performance view's launcher; back to
		// Pads, what it showed before.
		if next == "sequences" {
			if kit.modes_current(p.enc_modes) != "perform" do p.enc_before, p.kind_before = p.enc_modes.current, p.mirror_kind
			p.mirror_kind = .Clip
			kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "perform"))
		} else if kit.modes_current(p.enc_modes) == "perform" {
			p.mirror_kind = p.kind_before
			kit.modes_select(p.enc_modes, p.enc_before)
		}
		invalidate(c.cs)
		kit.redraw_owned(c)
	}
	p.session_button = button
	pm := make([]^kit.Component, 2)
	pm[0], pm[1] = p.pad_grid, page
	sm := make([]^kit.Component, 2)
	sm[0], sm[1] = p.seq_grid, nav
	return pm, sm
}

// The arrows: Left and Right select the pad before or after the selected
// one (the window's selection: its devices, the keyboard's sound), Up and
// Down the sequence before or after the one shown. Each lit while there is
// one to go to.
@(private)
arrows_setup :: proc(cs: ^kit.Control_Surface, left, right, up, down: ^kit.Control) -> ^kit.Component {
	c := kit.component_make(cs, "Arrows")
	kit.layer_bind(c.layer, "left", left)
	kit.layer_bind(c.layer, "right", right)
	kit.layer_bind(c.layer, "up", up)
	kit.layer_bind(c.layer, "down", down)
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		if p.pads_api != nil && kit.modes_current(p.pad_modes) == "song" {
			kit.light_value(control, W_ON if song_arrow_light(p, slot) else W_DIM)
			return
		}
		if p.pads_api != nil && kit.modes_current(p.pad_modes) == "steps" && (slot == "left" || slot == "right") {
			kit.light_value(control, W_ON if steps_arrow_light(p, slot) else W_DIM)
			return
		}
		pad, seq := arrows_now(c)
		on: bool
		switch slot {
		case "left":  on = pad > 0
		case "right": on = pad < pa.PADS - 1
		case "up":    on = seq < pa.SEQUENCES - 1
		case "down":  on = seq > 0
		}
		kit.light_value(control, W_ON if on else W_DIM)
	}
	c.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 200, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		t := (^Push2)(c.cs.user).pads_api
		if t == nil do return
		if kit.modes_current((^Push2)(c.cs.user).pad_modes) == "song" {
			song_arrow((^Push2)(c.cs.user), e.slot)
			kit.redraw_owned(c)
			invalidate(c.cs)
			return
		}
		if kit.modes_current((^Push2)(c.cs.user).pad_modes) == "steps" && (e.slot == "left" || e.slot == "right") {
			steps_arrow((^Push2)(c.cs.user), e.slot)
			kit.redraw_owned(c)
			return
		}
		pad, seq := arrows_now(c)
		switch e.slot {
		case "left":  t.perform_select_pad(t.api, max(pad - 1, 0))
		case "right": t.perform_select_pad(t.api, min(pad + 1, pa.PADS - 1))
		case "up", "down":
			d: i64 = 1 if e.slot == "up" else -1
			if kit.modes_current((^Push2)(c.cs.user).pad_modes) == "sequences" { // (Perform: the launcher's rows)
				v: pa.Launcher_View
				t.launcher_view(t.api, &v)
				t.launcher_set_view(t.api, v.lane, max(v.row + d, 0))
				render((^Push2)(c.cs.user))
			} else do t.sequence_select(t.api, clamp(seq + d, 0, pa.SEQUENCES - 1))
		}
		kit.redraw_owned(c)
		invalidate(c.cs)
	}
	return c
}

// The selected pad and the sequence shown.
@(private)
arrows_now :: proc(c: ^kit.Component) -> (pad, seq: i64) {
	t := (^Push2)(c.cs.user).pads_api
	if t == nil do return
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	t.sequence_current(t.api, &seq)
	return perf.selected, seq
}
