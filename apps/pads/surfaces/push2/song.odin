package pads_push2

import kit "fsurf:surface"
import pa "../../api"

/*
Song (Master): the song's arrangement edited from the Push, Pads' Song tab
showing it too (one state: the cursor, the selected lane and clip).

- **The grid:** Pads' 64 sequences, the first at the bottom left (as
  Session's Sequences): each in its colour (bright when the song has it,
  dim when not), the current one white, those playing in the song flashing
  green on the beat. A press picks the sequence a lane button puts in;
  with Select it opens in Clip (the sequencer); Duplicate copies it;
  Delete takes it out of the song (its clips, the gaps closed).
- **The scene buttons:** the song's lanes, eight at a time (the top one
  the first shown; Up and Down the other eight). A press puts the current
  sequence at the cursor on that lane (after the clip the cursor is in)
  and moves the cursor to its end (the next follows it); the lane's later
  clips move on to make room (a ripple edit). With Select (or Shift): the
  clip at the cursor there is selected (its settings on the Clip tab);
  Delete: it is removed, the lane's later clips closing the gap and the
  cursor back where it began; Duplicate: copied right after itself (the
  later clips moving on); Mute or Solo: the lane muted or soloed.
- **Left and Right:** the cursor a bar back or on (Shift: a beat).
- **The display:** Pads' Song view (View_Kind.Song): its tabs on the upper
  row (Song, Clip, Lanes, Arrangement, Markers, Tempo), the encoders and
  the lower row its knobs and buttons.
- **Master** again shows the Song view; Shift+Master turns song playback
  (Song mode) on or off without leaving where the Push is.
*/

// The lanes a scene button shows: lights, a press.
@(private)
song_lanes_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2) -> ^kit.Component {
	c := kit.component_make(cs, "Song Lanes")
	for s in p.scenes do kit.layer_bind(c.layer, "lane", s)
	c.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, RENDER_MS, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		e: pa.Song_Edit
		st: pa.Song_State
		t.song_edit_state(t.api, &e)
		t.song_state(t.api, &st)
		lane := e.first_lane + i64(row_index(p.scenes, control))
		l: pa.Song_Lane
		t.song_lane(t.api, lane, &l)
		playing := false
		if st.beat >= 0 do for i in 0 ..< st.clips {
			sc: pa.Song_Clip
			t.song_clip(t.api, i, &sc)
			if sc.lane == lane && !sc.mute && sc.at <= st.beat && st.beat < sc.at + sc.length do playing = true
		}
		sel := lane == e.lane
		v := u8(OFF)
		switch {
		case playing && p.lights.frac < 0.5: v = GREEN
		case l.solo:                         v = BLUE if sel else DIM_BLUE
		case l.mute:                         v = ORANGE if sel else DIM_ORANGE
		case sel:                            v = WHITE
		case lane < st.lanes:                v = DIM_WHITE
		}
		kit.light_value(control, v)
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		ed: pa.Song_Edit
		t.song_edit_state(t.api, &ed)
		lane := ed.first_lane + i64(row_index(p.scenes, e.control))
		at: i64 = -1
		t.song_clip_at(t.api, lane, ed.cursor, &at)
		switch {
		case p.mute_held || p.solo_held:
			l: pa.Song_Lane
			t.song_lane(t.api, lane, &l)
			if p.mute_held do l.mute = !l.mute
			else do l.solo = !l.solo
			t.song_set_lane(t.api, lane, l)
		case p.delete_held:
			t.song_select_lane(t.api, lane)
			if at >= 0 {
				ids := [1]i64{at}
				t.song_ripple_remove(t.api, &ids[0], 1)
			}
		case p.dup_held:
			if at >= 0 {
				n: i64
				t.song_ripple_duplicate(t.api, at, &n)
			}
		case p.select_held || p.shift.held:
			t.song_select_lane(t.api, lane)
			t.song_select_clip(t.api, at)
		case:
			n: i64
			t.song_add_at_cursor(t.api, lane, -1, &n)
		}
		kit.redraw_owned(c)
		render(p)
		invalidate(c.cs)
	}
	return c
}

// The arrows in Song: Up and Down the eight lanes shown, Left and Right
// the cursor (a bar; Shift: a beat). Whether they lit (`slot`).
@(private)
song_arrow_light :: proc(p: ^Push2, slot: string) -> bool {
	t := p.pads_api
	e: pa.Song_Edit
	t.song_edit_state(t.api, &e)
	switch slot {
	case "up":   return e.first_lane > 0
	case "down": return e.first_lane < 8
	case "left": return e.cursor > 0
	}
	return true
}

@(private)
song_arrow :: proc(p: ^Push2, slot: string) {
	t := p.pads_api
	e: pa.Song_Edit
	t.song_edit_state(t.api, &e)
	switch slot {
	case "up":   t.song_show_lanes(t.api, 0)
	case "down": t.song_show_lanes(t.api, 8)
	case "left", "right":
		tr: pa.Transport_State
		t.transport_state(t.api, &tr)
		step := 1.0 if p.shift.held else f64(max(tr.time_sig_num, 1)) * 4 / f64(max(tr.time_sig_den, 1))
		to := e.cursor + (step if slot == "right" else -step)
		if !p.shift.held do to = f64(int(to / step + (0.5 if slot == "right" else 0.999))) * step // (to a bar line)
		t.song_set_cursor(t.api, max(to, 0))
	}
	render(p)
}

// The sequences' lights in Song.
SONG_LAYERS := []Layer{song_layer, held_layer}

@(private)
song_layer :: proc(g: ^Grid, f: ^Frame) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	if t == nil do return
	st: pa.Song_State
	t.song_state(t.api, &st)
	in_song, playing: [64]bool
	for i in 0 ..< st.clips {
		sc: pa.Song_Clip
		t.song_clip(t.api, i, &sc)
		if sc.slot < 0 || sc.slot >= 64 do continue
		in_song[sc.slot] = true
		if st.beat >= 0 && !sc.mute && sc.at <= st.beat && st.beat < sc.at + sc.length do playing[sc.slot] = true
	}
	for i in 0 ..< 64 {
		ss: pa.Sequence_State
		if t.sequence_state(t.api, i64(i), &ss) != .Ok do continue
		c := u32(ss.color) & 0xFFFFFF
		switch {
		case ss.current:                  f[i] = cell_index(WHITE if ss.used else DIM_WHITE)
		case !ss.used:                    continue
		case in_song[i]:                  f[i] = cell_colour(c)
		case:                             f[i] = cell_colour(scale(c, 0.3))
		}
		if playing[i] && p.lights.frac < 0.5 do f[i] = cell_index(GREEN)
	}
}

// A press of sequence `slot` in Song.
@(private)
song_press :: proc(p: ^Push2, slot: int) {
	t := p.pads_api
	n: i64
	switch {
	case p.delete_held: t.song_remove_sequence(t.api, i64(slot), &n)
	case p.dup_held:    t.sequence_duplicate(t.api, i64(slot), &n)
	case p.select_held: // (its notes: Clip)
		t.sequence_select(t.api, i64(slot))
		p.mirror_kind = .Sequencer
		kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "clip"))
		app_show(p, "sequence")
		if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	case:               t.sequence_select(t.api, i64(slot))
	}
}

// Master: Song (the grid the sequences, the scene buttons the lanes, the
// display Pads' Song view); Shift+Master song playback on or off.
@(private)
song_button_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, master_b: ^kit.Control) -> ^kit.Component {
	c := kit.component_make(cs, "Song Button")
	kit.layer_bind(c.layer, "master", master_b)
	c.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 200, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		tr: pa.Transport_State
		if t := p.pads_api; t != nil do t.transport_state(t.api, &tr)
		switch {
		case kit.modes_current(p.pad_modes) == "song": kit.light_value(control, W_ON)
		case tr.song_mode:                             kit.light_value(control, W_HALF)
		case:                                          kit.light_value(control, W_DIM)
		}
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		if p.shift.held {
			tr: pa.Transport_State
			t.transport_state(t.api, &tr)
			t.transport_set_song_mode(t.api, !tr.song_mode)
			kit.redraw_owned(c)
			return
		}
		song_show(p)
		t.transport_set_song_mode(t.api, true)
		kit.redraw_owned(c)
	}
	p.song_button = c
	return c
}

// Song on the grid and the display (the window's Song tab too).
@(private)
song_show :: proc(p: ^Push2) {
	if kit.modes_current(p.pad_modes) != "song" do kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "song")) // (leaving Note: its display gone first)
	enc := kit.modes_current(p.enc_modes)
	if enc != "song" && enc != "perform" do p.enc_before, p.kind_before = p.enc_modes.current, p.mirror_kind
	p.mirror_kind = .Song
	kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "song"))
	app_show(p, "song")
	if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	invalidate(p.enc_modes.cs)
}
