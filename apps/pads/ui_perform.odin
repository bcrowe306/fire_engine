package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import pf "fire:perform"

// The Perform tab: the whole height (the pads area folds while it shows),
// three grids side by side — the sequence launcher (its columns are lanes,
// playing together), the 16 pads to play, and the performance effects —
// and the main and cue levels at the right.

// The Perform tab's state.
Perf_State :: struct {
	learning:   bool, // the next MIDI note learns the selected pad
	learn_seen: int,  // capture.midi_count when learning began
	sent, received: u64, // MIDI counts last frame
	in_lit, out_lit: f32, // seconds the activity lights stay on
	menu_fx: int, // the performance effect whose menu is open
	seq_bank: int, // the sequence pads' bank shown (0..3)
	holding: bool, // a sequence pad is held in Hold
	held_seq: int, // which
	held_from: int, // what its column played before it (-1: nothing; to go back to)
	seq_keys: bool, // the pad keys play the sequence pads shown (the Keys switch)
	shown_frame: i32, // the frame it last showed (it folds the pads area)
	folded_it:   bool,
}

// Step lengths, as the UI shows them.
RATE_NAMES := [pf.Rate]cstring{
	.Quarter = "1/4", .Eighth = "1/8", .Eighth_Triplet = "1/8T", .Sixteenth = "1/16",
	.Sixteenth_Triplet = "1/16T", .Thirty_Second = "1/32", .Thirty_Second_Triplet = "1/32T",
}

// Arpeggio orders, as the UI shows them.
ARP_NAMES := [pf.Arp_Mode]cstring{.Up = "Up", .Down = "Down", .Up_Down = "Up-down", .Random = "Random", .As_Played = "As played"}

// Note names of the roots.
ROOT_NAMES := [12]cstring{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

draw_perform :: proc(user: rawptr) {
	a := (^App)(user)
	st := &a.perf
	fold_pads_while_shown(a, &st.shown_frame, &st.folded_it)
	draw_perform_bar(a)
	im.Spacing()
	avail := im.GetContentRegionAvail()
	levels_w := inner_w() + 44 // (main's fader and meter as in the mixer, and the cue's fader)
	gap: f32 = 14
	col_w := max((avail.x - levels_w - 3 * gap) / 3, 160)
	h := avail.y
	if im.BeginChild("##perflaunch", {col_w, h}) do draw_launcher(a)
	im.EndChild()
	im.SameLine(0, gap)
	if im.BeginChild("##perfpads", {col_w, h}) {
		perf_title("Pads")
		draw_pads(a)
	}
	im.EndChild()
	im.SameLine(0, gap)
	if im.BeginChild("##perffx", {col_w, h}) do draw_perf_fx(a)
	im.EndChild()
	im.SameLine(0, gap)
	if im.BeginChild("##perflevels", {levels_w, h}) do draw_perf_levels(a)
	im.EndChild()
}

// A grid's title.
@(private)
perf_title :: proc(title: cstring) {
	im.TextDisabled("%s", title)
	im.Spacing()
}

// The bar on top: the sequence bank (and Keys), Launch or Hold and when a
// launch happens, Record to Song; the effects' Hold.
@(private)
draw_perform_bar :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	st := &a.perf
	bank := st.seq_bank
	if ui.segmented("seq_bank", {"A", "B", "C", "D"}, &bank) do st.seq_bank = bank
	ui.name("sequence bank")
	if im.IsItemHovered() do im.SetTooltip("The sequence pads' bank: 16 sequences each")
	im.SameLine(0, 6)
	if ui.icon_button(ui.ICON_KEYBOARD, "Keys: the computer's pad keys play these sequence pads (not the pads)", on = st.seq_keys) do st.seq_keys = !st.seq_keys
	ui.name("sequence keys")
	im.SameLine(0, 14)
	hold := 1 if p.launch_hold else 0
	if ui.segmented("launch_mode", {"Launch", "Hold"}, &hold) do pm.set_launch_hold(m, hold == 1)
	ui.name("launch mode")
	if im.IsItemHovered() do im.SetTooltip("Launch: a press starts it in its column; Hold: it plays while held, then what was there")
	im.SameLine(0, 10)
	im.AlignTextToFramePadding()
	im.TextDisabled("at")
	im.SameLine()
	at := int(p.switch_at)
	if ui.segmented("launch_quantize", {"End", "Bar", "Beat", "Now"}, &at) do p.switch_at = pm.Switch_At(at)
	if im.IsItemHovered() do im.SetTooltip("When a launch happens: when its column's sequence comes round, the next bar or beat, or now")
	ui.name("launch quantize")
	im.SameLine(0, 10)
	cont := p.launch_continue
	if ui.toggle("Continue", &cont) do pm.set_launch_continue(m, cont)
	ui.name("launch continue")
	if im.IsItemHovered() do im.SetTooltip("Continue: a launched sequence carries on where the playhead is in what played (that pass so far, modulo its length), for seamless changes; off, it starts from its top")
	im.SameLine(0, 14)
	rec := pm.launch_recording(m)
	if ui.icon_button(ui.ICON_CIRCLE_DOT, "Record to Song: what you launch is written into the Song (column 1 into lane 1...)", on = rec, color = ui.theme().danger) do pm.set_launch_record(m, !rec)
	ui.name("record to song")
	im.SameLine(0, 2)
	im.AlignTextToFramePadding()
	if rec do im.TextColored(transmute(im.Vec4)ui.theme().danger, "Recording to Song")
	else do im.TextDisabled("Record to Song")
	// The effects' Hold, at the right.
	w := im.CalcTextSize("Hold effects").x + 40
	im.SameLine(max(im.GetCursorPosX() + 10, im.GetCursorPosX() + im.GetContentRegionAvail().x - w))
	ui.toggle("Hold effects", &a.perf_hold)
	if im.IsItemHovered() do im.SetTooltip("A press turns an effect on until the next press")
	if !a.perf_hold {
		for i in 0 ..< pm.PERF_FX do if a.perf_latched[i] {
			a.perf_latched[i] = false
			if !a.perf_held[i] do pm.hold_perf_fx(m, i, false)
		}
	}
}

// The sequence launcher: the bank's 16 sequences as four columns, each a
// lane playing one at a time (all together); Shift-click launches one
// alone (the other columns stop then; Option-click only goes to it, to
// edit it); the row's arrow launches the
// row, the column's square stops it, the last one stops them all. A
// sequence pad shows its notes, a bar filling across while it plays (a
// queued one counts down); an empty one is nearly invisible (click it to
// make a new sequence there).
draw_launcher :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	st := &a.perf
	t := ui.theme()
	perf_title("Sequences · each column a lane")
	tl, playing := pm.timeline_beat(&m.engine)
	avail := im.GetContentRegionAvail()
	gap: f32 = 6
	arrow: f32 = 22
	size := clamp(min((avail.x - arrow - 4 * gap) / 4, (avail.y - im.GetFrameHeight() - 5 * gap) / 4), 40, 140)
	origin := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	for k in 0 ..< pm.PADS_PER_BANK {
		slot := st.seq_bank * pm.PADS_PER_BANK + k
		row, col := 3 - k / 4, k % 4 // (as the pad grid: 1 at the bottom left)
		pos := im.Vec2{origin.x + f32(col) * (size + gap), origin.y + f32(row) * (size + gap)}
		im.SetCursorScreenPos(pos)
		im.PushIDInt(i32(9000 + slot))
		used := pm.slot_used(m, slot)
		cs, frac, next, in_beats, queued := pm.column_state(&m.engine, col)
		playing_here := playing && cs == slot
		queued_here := queued && next == slot
		s := p.sequences[slot]
		if !used && slot != p.slot {
			// Empty: nearly invisible; a + when the mouse is over it.
			clicked := im.InvisibleButton("##empty", {size, size})
			ui.name(fmt.tprintf("launch %d", slot + 1))
			hot := im.IsItemHovered()
			im.DrawList_AddRect(dl, pos, {pos.x + size, pos.y + size}, ui.col(ui.with_alpha(t.text, 0.12 if hot else 0.05)), t.radius, 1)
			if hot {
				ts := im.CalcTextSize("+")
				im.DrawList_AddText(dl, {pos.x + (size - ts.x) / 2, pos.y + (size - ts.y) / 2}, ui.col(t.text_dim), "+")
				im.SetTooltip("%s", fmt.ctprintf("%s (empty): click to make a new sequence here", pm.sequence_name(p, slot)))
			}
			if clicked do pm.select_slot(m, slot)
			item_menu(a, seq_target(slot), "##cellmenu")
			im.PopID()
			continue
		}
		middle := ""
		if queued_here do middle = fmt.tprintf("in %.1f", max(in_beats, 0))
		else if queued && cs == slot && next < 0 do middle = "stops"
		pulse := f32(0.5 + 0.5 * math.cos(math.TAU * tl))
		face := ui.Pad_Face{
			label     = fmt.tprintf("launch %d", slot + 1),
			name      = pm.sequence_name(p, slot),
			middle    = middle,
			tint      = ui.rgb(pm.sequence_color(p, slot)),
			has_sound = true,
			lit       = playing_here || (queued_here && pulse > 0.5),
			selected  = slot == p.slot,
			notes     = seq_minis(a, slot), // (its notes, small, behind)
		}
		hit := ui.pad("##seqpad", face, {size, size})
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s · %d bar%s%s · column %d\nClick: launch it in its column · Shift-click: launch it alone · Option-click: edit it", pm.sequence_name(p, slot), s.bars, "" if s.bars == 1 else "s", fmt.tprintf(" · %.0f BPM", s.bpm) if s.bpm > 0 else "", col + 1))
		if hit.menu do im.OpenPopup("##cellmenu")
		item_menu(a, seq_target(slot), "##cellmenu")
		if hit.pressed do seq_pad_press(a, slot, false)
		if hit.selected && !hit.menu && im.GetIO().KeyShift do pm.launch_slot(m, slot, alone = true) // (Shift-click: alone)
		if hit.released do seq_pad_release(a, slot)
		// Playing: a bar filling across as it goes round.
		if playing_here do im.DrawList_AddRectFilled(dl, {pos.x + 6, pos.y + size - 7}, {pos.x + 6 + (size - 12) * f32(clamp(frac, 0, 1)), pos.y + size - 4}, ui.col(t.text), 2)
		im.PopID()
	}
	// Each row's launch arrow.
	for row in 0 ..< 4 {
		r := 3 - row // (the bottom row first)
		pos := im.Vec2{origin.x + 4 * (size + gap), origin.y + f32(row) * (size + gap) + (size - arrow) / 2}
		im.SetCursorScreenPos(pos)
		im.PushIDInt(i32(9500 + r))
		if ui.icon_button(ui.ICON_PLAY, fmt.ctprintf("Launch row %d: its sequences together", r + 1), size = arrow) do pm.launch_row(m, st.seq_bank, r)
		im.PopID()
	}
	// Each column's stop, and Stop All.
	y := origin.y + 4 * (size + gap)
	for col in 0 ..< pm.LAUNCH_COLS {
		cs, _, next, _, queued := pm.column_state(&m.engine, col)
		im.SetCursorScreenPos({origin.x + f32(col) * (size + gap), y})
		im.PushIDInt(i32(9600 + col))
		on := cs >= 0 && playing
		stopping := queued && next < 0
		if im.Button(ui.ICON_SQUARE, {size, 0}) do pm.stop_column(&m.engine, col)
		ui.name(fmt.tprintf("stop column %d", col + 1))
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Stop column %d%s", col + 1, fmt.tprintf(" (%s)", pm.sequence_name(p, cs)) if on else ""))
		if on || stopping {
			lo, hi := im.GetItemRectMin(), im.GetItemRectMax()
			im.DrawList_AddRect(dl, lo, hi, ui.col(ui.with_alpha(t.warn if stopping else t.accent, 0.7)), t.radius, 1.5)
		}
		im.PopID()
	}
	im.SetCursorScreenPos({origin.x + 4 * (size + gap), y})
	if ui.icon_button(ui.ICON_SQUARE_X, "Stop all columns", size = arrow) do pm.stop_all_columns(&m.engine)
	ui.name("stop all")
	im.SetCursorScreenPos({origin.x, y + im.GetFrameHeight() + 4})
	im.Dummy({1, 1})
}

// The colour a performance effect's kind gives its pad: filters violet,
// rhythm (stutters, cutters, gates) teal, pitch and ring mod pink, space
// (delay, reverb, modulation) blue, drive (crush, saturation, distortion)
// coral.
@(private)
fx_kind_color :: proc(k: pm.Effect_Kind) -> ui.Color {
	#partial switch k {
	case .Low_Pass, .High_Pass, .Band_Pass, .Comb, .Filter, .Eq: return ui.rgb(0x7f77dd)
	case .Stutter, .Cutter, .Gate:                                return ui.rgb(0x1d9e75)
	case .Pitch, .Ring_Mod:                                       return ui.rgb(0xd4537e)
	case .Delay, .Reverb, .Chorus, .Flanger, .Phaser:             return ui.rgb(0x378add)
	case .Bitcrush, .Saturation, .Distortion, .Compressor, .Limiter: return ui.rgb(0xd85a30)
	}
	return ui.theme().accent
}

// The performance effects: 16 pads on main, each coloured by its kind,
// on while held (with Hold effects, until pressed again); where it is
// pressed is how hard it plays (the top: all of it), shown as a fill.
// Right-click (or Shift-click) one to edit it.
@(private)
draw_perf_fx :: proc(a: ^App) {
	m := &a.m
	perf_title("Effects")
	avail := im.GetContentRegionAvail()
	gap: f32 = 6
	side := clamp(min((avail.x - 3 * gap) / 4, (avail.y - 3 * gap) / 4), 40, 140)
	origin := im.GetCursorScreenPos()
	for i in 0 ..< pm.PERF_FX {
		row, col := i / 4, i % 4
		im.SetCursorScreenPos({origin.x + f32(col) * (side + gap), origin.y + f32(row) * (side + gap)})
		fx := m.project.perf_fx[i]
		im.PushIDInt(i32(5000 + i))
		hit := ui.pad("fx", {label = fmt.tprintf("fx %d", i + 1), name = pm.perf_label(fx), middle = fmt.tprintf("FX %d", i + 1), tint = fx_kind_color(fx.kind), has_sound = true, lit = fx.on, selected = a.fx == pm.Fx_Target{.Perf, i, 0}}, {side, side})
		im.PopID()
		// Where it is pressed is how hard it plays: the top, all of it.
		lo, hi := im.GetItemRectMin(), im.GetItemRectMax()
		press := 1 - clamp((im.GetIO().MousePos.y - lo.y) / max(hi.y - lo.y, 1), 0, 1)
		press = clamp((press - 0.08) / 0.84, 0, 1) // a margin at each end reaches 0 and 1
		if hit.pressed {
			a.perf_held[i] = true
			if a.perf_hold {
				a.perf_latched[i] = !a.perf_latched[i]
				pm.hold_perf_fx(m, i, a.perf_latched[i], press)
			} else {
				pm.hold_perf_fx(m, i, true, press)
			}
		}
		if hit.held do pm.perf_intensity_live(m, i, press)
		intensity_fill(a, i, lo, hi)
		if hit.released {
			a.perf_held[i] = false
			if !a.perf_hold do pm.hold_perf_fx(m, i, false)
		}
		if hit.selected && !hit.menu do show_device(a, {.Perf, i, 0}) // Shift- or Cmd-click: edit it
		if hit.menu {
			a.perf.menu_fx = i
			im.OpenPopup("##fxmenu")
		}
	}
	if im.BeginPopup("##fxmenu") {
		command_items(a, {kind = .Slot, fx = {.Perf, a.perf.menu_fx, 0}})
		im.EndPopup()
	}
	im.SetCursorScreenPos({origin.x, origin.y + 4 * (side + gap)})
	im.Dummy({1, 1})
}

// Main's level and the cue's (the headphones': Settings sets where it
// plays), each a fader with its meter as in the mixer, their names and
// levels under them on one line.
@(private)
draw_perf_levels :: proc(a: ^App) {
	m := &a.m
	perf_title("Levels")
	avail := im.GetContentRegionAvail()
	line := im.GetTextLineHeightWithSpacing()
	total := max(avail.y - 4, 100)
	h := total - 2 * STRIP_PAD - line - 6
	// Narrow strips, as the mixer's: the two side by side in the column.
	was := strip_w_cur
	strip_w_cur = STRIP_NARROW_W
	defer strip_w_cur = was
	b := m.project.main
	vol := b.volume
	label :: proc(text: cstring) {
		w := inner_w()
		at := im.GetCursorPosX()
		im.SetCursorPosX(at + max((w - im.CalcTextSize(text).x) / 2, 0))
		im.TextDisabled("%s", text)
	}
	top := im.GetCursorScreenPos()
	strip_begin(total, false)
	strip_name = "Main" // (its fader: "Main fader", as in the mixer)
	if e := fader_meter(a, &vol, &a.mixer.buses[pm.BUSES], h); e.changed || e.ended {
		b.volume = vol
		if e.changed do pm.set_bus(m, pm.BUSES, 0, "Main Volume", b)
		if e.ended do app.seal(&m.history)
	}
	label(fmt.ctprintf("Main %.1f", vol))
	strip_end(top, total)
	im.SameLine(0, STRIP_GAP)
	top = im.GetCursorScreenPos()
	strip_begin(total, false)
	cue := a.settings.audio.cue_db
	has_cue := m.engine.outputs.cue >= 0
	strip_name = "Cue"
	if e := fader_meter(a, &cue, &a.mixer.cue, h); e.changed || e.ended {
		if e.changed {
			a.settings.audio.cue_db = clamp(cue, -60, 6)
			outputs_apply(a)
		}
		if e.ended do settings_save(a) // (an app setting, kept with the others)
	}
	if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("The cue (headphones) level%s", "" if has_cue else ": set a cue output in Settings to hear it"))
	label(fmt.ctprintf("Cue %.1f", cue) if has_cue else "Cue (off)")
	strip_end(top, total)
}

// A combo of step lengths.
@(private)
rate_combo :: proc(id: cstring, rate: ^pf.Rate) -> (changed: bool) {
	if ui.combo(id, RATE_NAMES[rate^]) {
		for r in pf.Rate do if im.Selectable(RATE_NAMES[r], r == rate^) {
			rate^ = r
			changed = true
		}
		im.EndCombo()
	}
	return
}

// A bar of steps at `rate`, the one the playhead is in lit: what note
// repeat or the arpeggiator plays on (bright when it is on).
@(private)
step_strip :: proc(m: ^pm.Model, rate: pf.Rate, on: bool) {
	t := ui.theme()
	step := f64(pf.rate_beats(rate))
	bar := pm.bar_beats(&m.project)
	n := clamp(int(bar / step + 0.5), 1, 48)
	beat, playing := pm.position(&m.engine)
	now := int(math.mod(beat, bar) / step) if playing else -1
	frac := f32(math.mod(beat, step) / step) if playing else 1
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := im.GetContentRegionAvail().x
	h: f32 = 14
	gap: f32 = 2
	cw := (w - gap * f32(n - 1)) / f32(n)
	im.Dummy({w, h})
	ui.name("steps")
	base := t.accent if on else ui.mix(t.raised, t.text, 0.25)
	for k in 0 ..< n {
		x := pos.x + f32(k) * (cw + gap)
		beat_start := math.mod(f64(k) * step, 1) < 1e-6
		c := ui.mix(t.raised, base, 0.35 if beat_start else 0.18)
		if k == now do c = ui.mix(base, ui.rgb(0xffffff), (1 - frac) * 0.5 if on else 0) // a flash that fades through the step
		im.DrawList_AddRectFilled(dl, {x, pos.y}, {x + cw, pos.y + h}, ui.col(c), 2)
	}
}

// A performance effect's pad's intensity: a fill from the bottom to how
// hard it plays now (bright while on), and a mark at its own intensity.
@(private)
intensity_fill :: proc(a: ^App, i: int, lo, hi: im.Vec2) {
	t := ui.theme()
	m := &a.m
	on := m.project.perf_fx[i].on
	own := m.project.perf_intensity[i]
	now := m.engine.perf_live[i] if on && m.engine.perf_live[i] >= 0 else own
	dl := im.GetWindowDrawList()
	h := hi.y - lo.y
	y := hi.y - h * (0.08 + 0.84 * now)
	c := ui.with_alpha(ui.rgb(0xffffff), 0.28 if on else 0.1)
	im.DrawList_AddRectFilled(dl, {lo.x + 2, y}, {hi.x - 2, hi.y - 2}, ui.col(c), 4)
	oy := hi.y - h * (0.08 + 0.84 * own)
	im.DrawList_AddLine(dl, {lo.x + 6, oy}, {lo.x + 18, oy}, ui.col(ui.with_alpha(t.text, 0.6)), 2)
}

// A sequence pad pressed (or its key): launched in its column (a
// Shift-click launches it alone: see `draw_launcher`), or (Hold) played while held,
// remembering what its column played to come back to. Option-click only
// goes to a sequence (to edit it), stopped.
seq_pad_press :: proc(a: ^App, slot: int, from_key: bool) {
	m := &a.m
	st := &a.perf
	_, playing := pm.position(&m.engine)
	io := im.GetIO()
	if !from_key && io.KeyAlt {
		if !playing do pm.select_slot(m, slot) // (Option: go to it, not start it)
		return
	}
	if m.project.launch_hold {
		if !st.holding {
			cs, _, _, _, _ := pm.column_state(&m.engine, pm.launch_col(slot))
			st.held_from = cs if playing else -1
		}
		st.holding, st.held_seq = true, slot
	}
	pm.launch_slot(m, slot)
}

// A sequence pad let go: in Hold, its column goes back to what it played.
seq_pad_release :: proc(a: ^App, slot: int) {
	st := &a.perf
	m := &a.m
	if !m.project.launch_hold || !st.holding || st.held_seq != slot do return
	st.holding = false
	if st.held_from >= 0 do pm.launch_slot(m, st.held_from)
	else do pm.stop_column(&m.engine, pm.launch_col(slot))
}

// How the pads play: each its sound, a keyboard of the selected one, or
// it at 16 velocities. Held pads let go first.
set_play_mode :: proc(a: ^App, mode: pm.Play_Mode) {
	if a.play_mode == mode do return
	for k in 0 ..< pm.PADS_PER_BANK do release(a, a.bank * pm.PADS_PER_BANK + k)
	// Keyboard mode's banks run up the scale from the lowest note: it opens
	// on the one holding the pad's own; leaving it, the pads' bank again.
	if mode == .Keyboard {
		a.pads_bank = a.bank
		a.play_mode = mode
		a.bank = keyboard_home_bank(a)
		return
	}
	if a.play_mode == .Keyboard do a.bank = a.pads_bank
	a.play_mode = mode
}
