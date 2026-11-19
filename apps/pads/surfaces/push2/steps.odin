package pads_push2

import "core:fmt"
import "core:math"
import "core:time"

import kit "fsurf:surface"
import pa "../../api"

/*
Clip's pads: entering notes (Live's layout).

- **The top four rows:** 32 steps of the selected pad, the first at the top
  left, along each row; a step is the sequencer's grid (the scene buttons
  pick it: 1/32t at the top ... 1/4 at the bottom; 1/4t isn't one). A step
  with a note is in the pad's colour, an empty one dim (each beat's first a
  little brighter), the playhead's green (white over a note), steps past
  the sequence's end dark. A press puts a note there (as hard as it was
  hit), or selects the notes there; let go without turning an encoder, the
  notes there are taken out. Held, its notes are the sequencer's selection:
  Clip's encoders (velocity, length, position, chance...) edit them.
- **The bottom left 4 x 4:** the bank's 16 pads (as Pads' pads: the first
  at the bottom left): a press plays it and makes it the one whose steps
  show.
- **The bottom right 4 x 4:** the pages of 32 steps (the first at the top
  left): those the sequence has dim, the one shown white, the playhead's
  green; a press shows it. Left and Right go a page back or on. While
  playing, the page follows the playhead (unless one was chosen in the
  last four seconds).
- **Duplicate held:** a step pressed (or two: the first and last of a
  range) is copied; the next step pressed gets it (the copy's notes added
  there). A pad pressed is copied (its notes in the sequence); the next pad
  pressed gets them.
- **Delete held:** a step's notes taken out; a pad's notes in the sequence
  taken out.
*/

// The steps a page shows.
STEPS_PAGE :: 32

// Choosing a page holds it this long while playing (else it follows the
// playhead).
STEPS_HOLD_MS :: 4000

// Clip's pads' state.
Steps :: struct {
	page:      int,
	chosen_at: time.Tick, // when a page was chosen (it holds a while)
	held:      int,  // the step held (-1: none)
	held_at:   u64,  // when it was pressed (ns)
	remove:    bool, // let go untouched: its notes go (it had some)
	copy_lo, copy_hi: int, // Duplicate held: the steps copied (-1: none yet)
	copy_down: int,  // the first step of a range, still held (-1: none)
	copy_pad:  i64,  // Duplicate held: the pad copied (-1: none)
	turned_ns: u64,  // when an encoder last turned (a held step edited)
}

// The scene buttons' grids, the top one first (1/4t: none).
SCENE_GRIDS := [8]i32{i32(pa.Grid.Thirty_Second_Triplet), i32(pa.Grid.Thirty_Second), i32(pa.Grid.Sixteenth_Triplet), i32(pa.Grid.Sixteenth), i32(pa.Grid.Eighth_Triplet), i32(pa.Grid.Eighth), -1, i32(pa.Grid.Quarter)}

// A grid's step, in beats.
grid_beats :: proc(g: pa.Grid) -> f64 {
	switch g {
	case .Quarter:               return 1
	case .Eighth:                return 0.5
	case .Eighth_Triplet:        return 1.0 / 3
	case .Sixteenth:             return 0.25
	case .Sixteenth_Triplet:     return 1.0 / 6
	case .Thirty_Second:         return 0.125
	case .Thirty_Second_Triplet: return 1.0 / 12
	case .Sixty_Fourth:          return 0.0625
	}
	return 0.25
}

// Where the steps are now: the step's beats, the sequence's steps and
// pages, the selected pad and the bank, the current sequence, the
// playhead's step (-1: stopped).
@(private)
Steps_Now :: struct {
	step:  f64,
	count: int,
	pages: int,
	pad:   i64,
	bank:  i64,
	slot:  i64,
	head:  int,
}

@(private)
steps_now :: proc(p: ^Push2) -> (n: Steps_Now) {
	t := p.pads_api
	g: pa.Grid
	t.ui_sequencer_grid(t.api, &g)
	n.step = grid_beats(g)
	t.sequence_current(t.api, &n.slot)
	ss: pa.Sequence_State
	t.sequence_state(t.api, n.slot, &ss)
	n.count = max(int(math.ceil(ss.beats / n.step - 1e-9)), 1)
	n.pages = (n.count + STEPS_PAGE - 1) / STEPS_PAGE
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	n.pad, n.bank = perf.selected, perf.bank
	n.head = -1
	tr: pa.Transport_State
	if t.transport_state(t.api, &tr) == .Ok && tr.playing && ss.beats > 0 {
		n.head = int(math.mod(tr.beat, ss.beats) / n.step)
	}
	return
}

// The step a pad of the top four rows is (0..31), or -1.
@(private)
step_of :: proc(i: int) -> int {
	if i < 32 do return -1
	return (7 - i / 8) * 8 + i % 8
}

// A pad of the bottom left 4 x 4: which of the bank's 16 (-1: not one).
@(private)
bank_pad_of :: proc(i: int) -> int {
	if i >= 32 || i % 8 >= 4 do return -1
	return (i / 8) * 4 + i % 8
}

// A pad of the bottom right 4 x 4: which page (-1: not one).
@(private)
page_of :: proc(i: int) -> int {
	if i >= 32 || i % 8 < 4 do return -1
	return (3 - i / 8) * 4 + (i % 8 - 4)
}

// The page shown (following the playhead while playing, unless one was
// chosen lately).
@(private)
steps_page :: proc(p: ^Push2, n: Steps_Now) -> int {
	s := &p.steps
	if n.head >= 0 && time.tick_diff(s.chosen_at, time.tick_now()) > STEPS_HOLD_MS * time.Millisecond && s.held < 0 {
		s.page = n.head / STEPS_PAGE
	}
	s.page = clamp(s.page, 0, max(n.pages - 1, 0))
	return s.page
}

// The notes of pad `pad` starting in beats lo..hi of the current sequence
// (their indices).
@(private)
notes_in :: proc(p: ^Push2, n: Steps_Now, pad: i64, lo, hi: f64) -> [dynamic]i64 {
	t := p.pads_api
	out := make([dynamic]i64, context.temp_allocator)
	ss: pa.Sequence_State
	t.sequence_state(t.api, n.slot, &ss)
	for k in 0 ..< ss.notes {
		x: pa.Note
		if t.sequence_note(t.api, n.slot, k, &x) != .Ok do continue
		if (pad < 0 || x.pad == pad) && x.start >= lo - 1e-9 && x.start < hi - 1e-9 do append(&out, k)
	}
	return out
}

// Clip's pads' lights.
STEPS_LAYERS := []Layer{steps_layer}

@(private)
steps_layer :: proc(g: ^Grid, f: ^Frame) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	if t == nil do return
	n := steps_now(p)
	page := steps_page(p, n)
	// The steps with the pad's notes.
	has: [STEPS_PAGE]bool
	ss: pa.Sequence_State
	t.sequence_state(t.api, n.slot, &ss)
	for k in 0 ..< ss.notes {
		x: pa.Note
		if t.sequence_note(t.api, n.slot, k, &x) != .Ok || x.pad != n.pad do continue
		s := int(x.start / n.step + 1e-9) - page * STEPS_PAGE
		if s >= 0 && s < STEPS_PAGE do has[s] = true
	}
	st: pa.Pad_State
	t.pad_state(t.api, n.pad, &st)
	c := u32(st.color) & 0xFFFFFF
	per_beat := max(int(math.round(1 / n.step)), 1)
	for i in 32 ..< 64 {
		s := step_of(i)
		gs := page * STEPS_PAGE + s
		switch {
		case gs >= n.count:      f[i] = {}
		case s == p.steps.held:  f[i] = cell_index(WHITE)
		case gs == n.head:       f[i] = cell_index(WHITE if has[s] else GREEN)
		case has[s]:             f[i] = cell_colour(c, fallback = WHITE)
		case gs % per_beat == 0: f[i] = cell_colour(0x303030)
		case:                    f[i] = cell_colour(0x101010)
		}
	}
	// The bank's pads.
	for i in 0 ..< 32 {
		if b := bank_pad_of(i); b >= 0 {
			pad := int(n.bank) * 16 + b
			if pad < pa.PADS do f[i] = pad_cell(g, pad, i64(pad) == n.pad)
		} else if pg := page_of(i); pg >= 0 {
			switch {
			case pg >= n.pages:                         f[i] = {}
			case pg == page:                            f[i] = cell_index(WHITE)
			case n.head >= 0 && pg == n.head / STEPS_PAGE: f[i] = cell_index(GREEN)
			case:                                       f[i] = cell_index(DIM_WHITE)
			}
		}
	}
	for h, i in g.held do if h && step_of(i) < 0 && page_of(i) < 0 do f[i] = cell_index(GREEN)
}

// A press of pad `i` in Clip (`velocity` 0..1).
@(private)
steps_press :: proc(g: ^Grid, i: int, velocity: f32, time_ns: u64) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	s := &p.steps
	n := steps_now(p)
	page := steps_page(p, n)
	if pg := page_of(i); pg >= 0 {
		if pg < n.pages {
			s.page = pg
			s.chosen_at = time.tick_now()
		}
		return
	}
	if b := bank_pad_of(i); b >= 0 {
		pad := n.bank * 16 + i64(b)
		if pad >= pa.PADS do return
		switch {
		case p.dup_held && s.copy_pad < 0:
			s.copy_pad = pad
			say(p, .Info, fmt.tprintf("Copied %s's notes: press a pad to paste them", pad_name(pad)))
		case p.dup_held:
			ids := notes_in(p, n, s.copy_pad, 0, 1e9)
			for k in ids {
				x: pa.Note
				t.sequence_note(t.api, n.slot, k, &x)
				x.pad = pad
				out: i64
				t.sequence_add_note(t.api, n.slot, x, &out)
			}
			say(p, .Success, fmt.tprintf("%d note%s of %s onto %s", len(ids), "" if len(ids) == 1 else "s", pad_name(s.copy_pad), pad_name(pad)))
		case p.delete_held:
			p.delete_used = true
			ids := notes_in(p, n, pad, 0, 1e9)
			if len(ids) > 0 do t.sequence_remove_notes(t.api, n.slot, &ids[0], i64(len(ids)))
			say(p, .Info, fmt.tprintf("%s's notes taken out of the sequence", pad_name(pad)))
		case:
			t.perform_select_pad(t.api, pad) // (it sounds through its remap)
		}
		return
	}
	st := step_of(i)
	if st < 0 do return
	gs := page * STEPS_PAGE + st
	if gs >= n.count do return
	lo, hi := f64(gs) * n.step, f64(gs + 1) * n.step
	switch {
	case p.dup_held:
		if s.copy_lo < 0 { // (the first: copied)
			s.copy_lo, s.copy_down = gs, gs
			say(p, .Info, "Step copied: press another while holding it for a range, or a step to paste")
			return
		}
		if s.copy_down >= 0 && s.copy_hi < 0 && gs != s.copy_down { // (a second while the first is held: the range)
			s.copy_lo, s.copy_hi = min(s.copy_down, gs), max(s.copy_down, gs)
			say(p, .Info, fmt.tprintf("Steps %d-%d copied: press a step to paste", s.copy_lo + 1, s.copy_hi + 1))
			return
		}
		// Pasted here.
		hi_step := s.copy_hi if s.copy_hi >= 0 else s.copy_lo
		ids := notes_in(p, n, n.pad, f64(s.copy_lo) * n.step, f64(hi_step + 1) * n.step)
		d := f64(gs - s.copy_lo) * n.step
		for k in ids {
			x: pa.Note
			t.sequence_note(t.api, n.slot, k, &x)
			x.start += d
			out: i64
			t.sequence_add_note(t.api, n.slot, x, &out)
		}
		say(p, .Success, fmt.tprintf("%d step%s pasted", hi_step - s.copy_lo + 1, "" if hi_step == s.copy_lo else "s"))
	case p.delete_held:
		p.delete_used = true
		ids := notes_in(p, n, n.pad, lo, hi)
		if len(ids) > 0 do t.sequence_remove_notes(t.api, n.slot, &ids[0], i64(len(ids)))
	case:
		ids := notes_in(p, n, n.pad, lo, hi)
		s.held, s.held_at = st, max(time_ns, 1)
		s.remove = len(ids) > 0
		if len(ids) == 0 {
			out: i64
			t.sequence_add_note(t.api, n.slot, {start = lo, length = n.step, pad = n.pad, velocity = clamp(velocity, 1.0 / 127, 1), probability = 1}, &out)
			ids = notes_in(p, n, n.pad, lo, hi)
		}
		if len(ids) > 0 do t.ui_select_notes(t.api, &ids[0], i64(len(ids)))
	}
}

// A release of pad `i` in Clip.
@(private)
steps_release :: proc(g: ^Grid, i: int) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	s := &p.steps
	st := step_of(i)
	if st < 0 do return
	n := steps_now(p)
	if s.copy_down >= 0 {
		s.copy_down = -1
		return
	}
	if st != s.held do return
	held_at := s.held_at
	s.held = -1
	// Let go untouched (no encoder turned while held): its notes go.
	if s.remove && s.turned_ns < held_at {
		gs := s.page * STEPS_PAGE + st
		ids := notes_in(p, n, n.pad, f64(gs) * n.step, f64(gs + 1) * n.step)
		if len(ids) > 0 do t.sequence_remove_notes(t.api, n.slot, &ids[0], i64(len(ids)))
		t.ui_select_notes(t.api, nil, 0)
	}
}

// Duplicate let go: what was copied is forgotten.
@(private)
steps_forget_copy :: proc(p: ^Push2) {
	p.steps.copy_lo, p.steps.copy_hi, p.steps.copy_down, p.steps.copy_pad = -1, -1, -1, -1
}

// Left and Right in Clip: a page back or on.
@(private)
steps_arrow :: proc(p: ^Push2, slot: string) {
	n := steps_now(p)
	s := &p.steps
	s.page = clamp(steps_page(p, n) + (1 if slot == "right" else -1), 0, max(n.pages - 1, 0))
	s.chosen_at = time.tick_now()
	render(p)
}

// Whether Left or Right has a page to go to.
@(private)
steps_arrow_light :: proc(p: ^Push2, slot: string) -> bool {
	n := steps_now(p)
	page := steps_page(p, n)
	return page > 0 if slot == "left" else page < n.pages - 1
}

// The scene buttons in Clip: the sequencer's grid (lit: the one now).
@(private)
steps_scenes_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2) -> ^kit.Component {
	c := kit.component_make(cs, "Step Grids")
	for s in p.scenes do kit.layer_bind(c.layer, "grid", s)
	c.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 200, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		k := row_index(p.scenes, control)
		if t == nil || k < 0 || SCENE_GRIDS[k] < 0 {
			kit.light_value(control, OFF)
			return
		}
		g: pa.Grid
		t.ui_sequencer_grid(t.api, &g)
		kit.light_value(control, WHITE if i32(g) == SCENE_GRIDS[k] else DIM_WHITE)
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		k := row_index(p.scenes, e.control)
		if t == nil || k < 0 || SCENE_GRIDS[k] < 0 do return
		t.ui_set_sequencer_grid(t.api, pa.Grid(SCENE_GRIDS[k]))
		say(p, .Info, fmt.tprintf("Steps: %s", SCENE_NAMES[k]))
		kit.redraw_owned(c)
		render(p)
	}
	return c
}

// Pad `pad`'s name ("A1").
@(private)
pad_name :: proc(pad: i64) -> string {
	return fmt.tprintf("%c%d", 'A' + rune(pad / 16), pad % 16 + 1)
}

// Clip: the pads its steps (the pads' mode before kept).
@(private)
steps_show :: proc(p: ^Push2) {
	if kit.modes_current(p.pad_modes) == "steps" do return
	p.pads_before = p.pad_modes.current
	kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "steps"))
}

// Leaving Clip: the pads as they were.
@(private)
steps_leave :: proc(p: ^Push2) {
	if kit.modes_current(p.pad_modes) != "steps" do return
	kit.modes_select(p.pad_modes, p.pads_before)
}

// --- Velocity mode (Layout pressed again) ------------------------------------------------------

/*
The selected pad at 16 velocities, as Pads' Velocity mode: the bottom left
4 x 4, softest at the bottom left to loudest at the top right (each lit in
the pad's colour, brighter as it is louder); the bottom right 4 x 4, the
bank's pads (a press makes one the pad played); the top rows dark. Layout
is lit orange (Layout again: back to the drums).
*/

VELOCITY_LAYERS := []Layer{velocity_layer}

// A pad of the bottom right 4 x 4 in Velocity mode: which of the bank's 16.
@(private)
velocity_bank_pad :: proc(i: int) -> int {
	if i >= 32 || i % 8 < 4 do return -1
	return (i / 8) * 4 + (i % 8 - 4)
}

@(private)
velocity_layer :: proc(g: ^Grid, f: ^Frame) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	if t == nil do return
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	st: pa.Pad_State
	t.pad_state(t.api, perf.selected, &st)
	c := u32(st.color) & 0xFFFFFF
	for i in 0 ..< 32 {
		if k := bank_pad_of(i); k >= 0 {
			f[i] = cell_colour(scale(c, 0.15 + 0.85 * f32(k + 1) / 16), fallback = WHITE)
			if g.held[i] do f[i] = cell_index(GREEN)
		} else if b := velocity_bank_pad(i); b >= 0 {
			pad := int(perf.bank) * 16 + b
			if pad < pa.PADS do f[i] = pad_cell(g, pad, i64(pad) == perf.selected)
		}
	}
}
