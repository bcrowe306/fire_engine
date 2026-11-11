package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import pf "fire:perform"

// The Perform panel's state.
Perf_State :: struct {
	learning:   bool, // the next MIDI note learns the selected pad
	learn_seen: int,  // capture.midi_count when learning began
	sent, received: u64, // MIDI counts last frame
	in_lit, out_lit: f32, // seconds the activity lights stay on
	menu_fx: int, // the performance effect whose menu is open
	seq_bank: int, // the sequence pads' bank shown (0..3)
	holding: bool, // a sequence pad is held in Hold
	held_seq: int, // which
	held_from: int, // the sequence playing before it (to go back to)
	keys_here: bool, // the Perform panel is in front: the pad keys play sequence pads
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

// How the pads play (pads, keyboard, velocity), note repeat, the
// arpeggiator, and the selected pad's MIDI.
draw_perform :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	p := m.project.perform
	changed := false
	w: f32 = -1

	// A panel of its own: a column for how the pads play and MIDI, one for
	// note repeat and the arpeggiator, one for the performance effects
	// (narrow, one after another).
	// Wide: the sequence pads a column of their own, beside the rest;
	// narrow, above them.
	wide := im.GetContentRegionAvail().x >= 900
	beside := im.GetContentRegionAvail().x >= 1000
	if !beside {
		draw_launcher(a)
		im.Spacing()
		im.Separator()
	}
	if wide && !im.BeginTable("##perform", 4 if beside else 3, {.BordersInnerV, .PadOuterX}) do wide, beside = false, false
	defer if wide do im.EndTable()
	if wide {
		if beside do im.TableSetupColumn("s", {.WidthFixed}, 4 * 68 + 3 * 6 + 8)
		im.TableSetupColumn("a", {.WidthStretch}, 1)
		im.TableSetupColumn("b", {.WidthStretch}, 1)
		im.TableSetupColumn("c", {.WidthStretch}, 1.3)
		im.TableNextColumn()
		if beside {
			draw_launcher(a)
			im.TableNextColumn()
		}
	}

	section(a, "Play the pads as", !wide)
	mode := int(a.play_mode)
	if ui.segmented("play_mode", {"Pads", "Keyboard", "Velocity"}, &mode) do set_play_mode(a, pm.Play_Mode(mode))
	if a.play_mode != .Pads {
		im.TextDisabled("%s", fmt.ctprintf("Playing %s %s", pm.pad_label(a.selected), pm.pad_name(&m.project.pads[a.selected])))
	}
	if a.play_mode == .Keyboard {
		k := &a.keys
		im.SetNextItemWidth(170)
		if ui.combo("##scale", pm.SCALE_NAMES[k.scale]) {
			for sc in pm.Scale do if im.Selectable(pm.SCALE_NAMES[sc], sc == k.scale) do k.scale = sc
			im.EndCombo()
		}
		ui.flow(70)
		im.SetNextItemWidth(70)
		if ui.combo("##root", ROOT_NAMES[k.root]) {
			for r, i in ROOT_NAMES do if im.Selectable(r, i == k.root) do k.root = i
			im.EndCombo()
		}
		ui.flow(110)
		im.SetNextItemWidth(110)
		oct := i32(k.octave)
		if im.DragInt("##octave", &oct, 0.05, -3, 3, "Octave %+d", {.ClampOnInput}) do k.octave = int(oct)
		im.SetNextItemWidth(170)
		if ui.combo("##chord", pm.CHORD_NAMES[k.chord]) {
			for c in pm.Chord do if im.Selectable(pm.CHORD_NAMES[c], c == k.chord) do k.chord = c
			im.EndCombo()
		}
	}

	// MIDI: activity, learn, out.
	section(a, "MIDI")
	st := &a.perf
	sent, received := app.host_midi_counts(&a.host)
	dt := im.GetIO().DeltaTime
	st.in_lit = 0.15 if received != st.received else max(st.in_lit - dt, 0)
	st.out_lit = 0.15 if sent != st.sent else max(st.out_lit - dt, 0)
	st.sent, st.received = sent, received
	t := ui.theme()
	light :: proc(label: cstring, on: bool, t: ui.Theme) {
		dl := im.GetWindowDrawList()
		pos := im.GetCursorScreenPos()
		h := im.GetTextLineHeight()
		c := t.ok if on else ui.mix(t.raised, t.text, 0.2)
		im.DrawList_AddCircleFilled(dl, {pos.x + 5, pos.y + h / 2}, 4, ui.col(c))
		im.Dummy({12, h})
		im.SameLine(0, 4)
		im.TextDisabled("%s", label)
	}
	light("In", st.in_lit > 0, t)
	im.SameLine(0, 16)
	light("Out", st.out_lit > 0, t)
	im.SameLine(0, 16)
	ins := len(a.host.midi_inputs)
	im.TextDisabled("%s", fmt.ctprintf("%d input port%s", ins, "" if ins == 1 else "s") if a.host.midi_driver != nil else "No MIDI (simulated device)")

	{ // the selected pad's MIDI
		i := a.selected
		key := pm.midi_key_of(m, i)
		im.AlignTextToFramePadding()
		im.Text("%s", fmt.ctprintf("%s plays on", pm.pad_label(i)))
		im.SameLine()
		if key >= 0 do im.TextDisabled("%s", fmt.ctprintf("key %d (%s)", key, ui.note_name(key)))
		else do im.TextDisabled("no key")
		im.SameLine()
		if st.learning {
			if a.capture.midi_count != st.learn_seen {
				pm.learn_midi(m, a.capture.midi_key, i)
				st.learning = false
				ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Key %d plays %s", a.capture.midi_key, pm.pad_label(i)))
			}
			if ui.icon_button(ui.ICON_X, "Stop learning", on = true) do st.learning = false
			im.SameLine()
			im.TextDisabled("Play a note…")
		} else if im.Button("Learn") {
			st.learning, st.learn_seen = true, a.capture.midi_count
		}

		pad := m.project.pads[i]
		out := pad.midi_out
		if ui.toggle("MIDI out", &out.on) {
			if out.on && out.key == 0 do out.key = u8(pm.pad_key(i))
			pad.midi_out = out
			pm.set_pad(m, i, .Whole, "Set MIDI Out", pad)
			app.seal(&m.history)
		}
		if out.on {
			im.SameLine(0, 16)
			im.SetNextItemWidth(100)
			ch := i32(out.channel) + 1
			if im.DragInt("##ch", &ch, 0.05, 1, 16, "Channel %d", {.ClampOnInput}) {
				pad.midi_out.channel = u8(ch - 1)
				pm.set_pad(m, i, .Whole, "Set MIDI Out", pad)
			}
			if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
			im.SameLine()
			im.SetNextItemWidth(100)
			k := i32(out.key)
			if im.DragInt("##key", &k, 0.1, 0, 127, "Note %d", {.ClampOnInput}) {
				pad.midi_out.key = u8(k)
				pm.set_pad(m, i, .Whole, "Set MIDI Out", pad)
			}
			if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
			im.SameLine()
			midi_out_port_combo(a, i, 180)
		}
	}
	if wide do im.TableNextColumn()
	section(a, "Note repeat", !wide)
	if ui.toggle("Repeat", &p.repeat_on) {
		if p.repeat_on do p.arp_on = false
		changed = true
	}
	ui.flow(90, 16)
	im.SetNextItemWidth(90)
	if rate_combo("##rep_rate", &p.repeat.rate) do changed = true
	ui.flow(110)
	im.SetNextItemWidth(110)
	gate := p.repeat.gate if p.repeat.gate > 0 else 0.5
	if im.DragFloat("##rep_gate", &gate, 0.005, 0.05, 1, "Gate %.2f", {.ClampOnInput}) {
		p.repeat.gate = gate
		changed = true
	}
	step_strip(m, p.repeat.rate, p.repeat_on)

	section(a, "Arpeggiator")
	if ui.toggle("Arpeggiate", &p.arp_on) {
		if p.arp_on do p.repeat_on = false
		changed = true
	}
	im.SameLine(0, 16)
	if ui.toggle("Latch", &p.arp.latch) do changed = true
	im.SetNextItemWidth(130)
	if ui.combo("##arp_mode", ARP_NAMES[p.arp.mode]) {
		for am in pf.Arp_Mode do if im.Selectable(ARP_NAMES[am], am == p.arp.mode) {
			p.arp.mode = am
			changed = true
		}
		im.EndCombo()
	}
	ui.flow(90)
	im.SetNextItemWidth(90)
	if rate_combo("##arp_rate", &p.arp.rate) do changed = true
	octaves := i32(max(p.arp.octaves, 1))
	im.SetNextItemWidth(130)
	if im.DragInt("##arp_oct", &octaves, 0.05, 1, 4, "%d octave" if octaves == 1 else "%d octaves", {.ClampOnInput}) {
		p.arp.octaves = int(octaves)
		changed = true
	}
	ui.flow(110)
	im.SetNextItemWidth(110)
	agate := p.arp.gate if p.arp.gate > 0 else 0.5
	if im.DragFloat("##arp_gate", &agate, 0.005, 0.05, 1, "Gate %.2f", {.ClampOnInput}) {
		p.arp.gate = agate
		changed = true
	}
	step_strip(m, p.arp.rate, p.arp_on)
	if changed do pm.set_perform(m, p)

	// The performance effects: hold a pad to apply its effect to main; with
	// HOLD, a press turns it on until the next. Right-click to edit one.
	if wide do im.TableNextColumn()
	section(a, "Performance effects", !wide)
	ui.toggle("Hold", &a.perf_hold)
	if !a.perf_hold {
		for i in 0 ..< pm.PERF_FX do if a.perf_latched[i] {
			a.perf_latched[i] = false
			if !a.perf_held[i] do pm.hold_perf_fx(m, i, false)
		}
	}
	avail := im.GetContentRegionAvail().x
	gap: f32 = 6
	side := min((avail - 3 * gap) / 4, 140)
	for i in 0 ..< pm.PERF_FX {
		if i % 4 != 0 do im.SameLine(0, gap)
		fx := m.project.perf_fx[i]
		im.PushIDInt(i32(5000 + i))
		hit := ui.pad("fx", {label = fmt.tprintf("fx %d", i + 1), name = pm.perf_label(fx), middle = fmt.tprintf("FX %d", i + 1), tint = ui.theme().accent, has_sound = true, lit = fx.on, selected = a.fx == pm.Fx_Target{.Perf, i, 0}}, {side, side * 0.62})
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
		if hit.selected && !hit.menu { // Shift- or Cmd-click: edit it
			show_device(a, {.Perf, i, 0})
		}
		if hit.menu {
			a.perf.menu_fx = i
			im.OpenPopup("##fxmenu")
		}
	}
	if im.BeginPopup("##fxmenu") {
		command_items(a, {kind = .Slot, fx = {.Perf, a.perf.menu_fx, 0}})
		im.EndPopup()
	}

	_ = w
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
	c := ui.with_alpha(ui.rgb(0xffffff) if on else t.accent, 0.28 if on else 0.12)
	im.DrawList_AddRectFilled(dl, {lo.x + 2, y}, {hi.x - 2, hi.y - 2}, ui.col(c), 4)
	oy := hi.y - h * (0.08 + 0.84 * own)
	im.DrawList_AddLine(dl, {lo.x + 6, oy}, {lo.x + 18, oy}, ui.col(ui.with_alpha(t.text, 0.6)), 2)
}

// Sequence pads in banks of 16 (A to D: 64 sequences), as the pads are:
// press one to launch it at the switch point set (it blinks while
// queued), or (Hold) to play it only while held, the one before coming
// back when let go. With the Perform panel in front the computer's pad
// keys play the bank shown.
draw_launcher :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	st := &a.perf
	t := ui.theme()
	beat, playing := pm.position(&m.engine)
	tl, _ := pm.timeline_beat(&m.engine)
	next, in_beats, queued := pm.pending_switch(&m.engine)
	// The bank, how pads launch, and when.
	im.AlignTextToFramePadding()
	im.TextDisabled("Sequences")
	im.SameLine(0, 10)
	if ui.segmented("seq_bank", {"A", "B", "C", "D"}, &st.seq_bank) {}
	ui.name("sequence bank")
	ui.flow(150, 14)
	hold := 1 if p.launch_hold else 0
	if ui.segmented("launch_mode", {"Launch", "Hold"}, &hold) do pm.set_launch_hold(m, hold == 1)
	ui.name("launch mode")
	if im.IsItemHovered() do im.SetTooltip("Launch: a press switches to it; Hold: it plays while held, then the one before")
	ui.flow(230, 14)
	at := int(p.switch_at)
	im.AlignTextToFramePadding()
	im.TextDisabled("at")
	im.SameLine()
	if ui.segmented("launch_quantize", {"End", "Bar", "Beat", "Now"}, &at) do p.switch_at = pm.Switch_At(at)
	if im.IsItemHovered() do im.SetTooltip("When a pad's sequence takes over: the end of the one playing, the next bar or beat, or now")
	ui.name("launch quantize")
	// The pads: four rows of four, the top row the bank's last four.
	gap: f32 = 6
	avail := im.GetContentRegionAvail()
	// (as big as fits half the panel's height: the rest of Perform is below)
	// (beside the rest, the panel's height; above it, half)
	share: f32 = 1 if im.GetContentRegionAvail().x < 520 else 0.55
	size := clamp(min((min(avail.x, 520) - gap * 3) / 4, (avail.y * share - gap * 3 - im.GetFrameHeight() - 12) / 4), 44, 80)
	origin := im.GetCursorScreenPos()
	for k in 0 ..< pm.PADS_PER_BANK {
		slot := st.seq_bank * pm.PADS_PER_BANK + k
		row, col := 3 - k / 4, k % 4 // (as the pad grid: 1 at the bottom left)
		im.SetCursorScreenPos({origin.x + f32(col) * (size + gap), origin.y + f32(row) * (size + gap)})
		im.PushIDInt(i32(9000 + slot))
		used := pm.slot_used(m, slot)
		is_cur := slot == p.slot
		is_next := queued && next == slot
		s := p.sequences[slot]
		middle := fmt.tprintf("%d bar%s", s.bars, "" if s.bars == 1 else "s") if used else "empty"
		if is_next do middle = fmt.tprintf("in %.1f", max(in_beats, 0))
		pulse := f32(0.5 + 0.5 * math.cos(math.TAU * tl))
		face := ui.Pad_Face{
			label     = fmt.tprintf("launch %d", slot + 1),
			name      = pm.sequence_name(p, slot) if s.name[0] != 0 else fmt.tprintf("Seq %d", slot + 1),
			middle    = middle,
			tint      = ui.rgb(pm.sequence_color(p, slot)),
			has_sound = used || is_cur,
			lit       = (is_cur && playing) || (is_next && pulse > 0.5),
			selected  = is_cur,
		}
		hit := ui.pad("##seqpad", face, {size, size})
		if hit.menu do im.OpenPopup("##cellmenu")
		item_menu(a, seq_target(slot), "##cellmenu")
		if hit.pressed do seq_pad_press(a, slot, false)
		if hit.released do seq_pad_release(a, slot)
		// Playing: where in it the playhead is.
		if is_cur && playing {
			pos := im.GetItemRectMin()
			f := f32(beat / max(pm.seq_beats(p, s), 1e-6))
			dl := im.GetWindowDrawList()
			im.DrawList_AddRectFilled(dl, {pos.x + 6, pos.y + size - 7}, {pos.x + 6 + (size - 12) * clamp(f, 0, 1), pos.y + size - 4}, ui.col(t.text), 2)
		}
		im.PopID()
	}
	// Beside (or under, if narrow): go to the next empty one (to record into).
	if avail.x >= 4 * (size + gap) + 90 do im.SetCursorScreenPos({origin.x + 4 * (size + gap) + 8, origin.y})
	else do im.SetCursorScreenPos({origin.x, origin.y + 4 * (size + gap)})
	if e := pm.next_empty_slot(m, p.slot); e >= 0 {
		if im.Button(fmt.ctprintf("%s  New", ui.ICON_PLUS)) {
			pm.select_slot(m, e)
			st.seq_bank = e / pm.PADS_PER_BANK
		}
		ui.name("new sequence")
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Go to %s (empty) to make a new one", pm.sequence_name(p, e)))
	}
	im.SetCursorScreenPos({origin.x, origin.y + 4 * (size + gap) + im.GetFrameHeight() + 4})
	im.Dummy({1, 1})
	// The keys play these while this panel is in front.
	st.keys_here = im.IsWindowFocused({.RootWindow, .ChildWindows})
}

// A sequence pad pressed (or its key): launched, or (Hold) played while
// held, remembering the one to come back to.
seq_pad_press :: proc(a: ^App, slot: int, from_key: bool) {
	m := &a.m
	st := &a.perf
	_, playing := pm.position(&m.engine)
	if m.project.launch_hold {
		if !st.holding do st.held_from = m.project.slot
		st.holding, st.held_seq = true, slot
	}
	if !from_key && im.GetIO().KeyShift {
		if !playing do pm.select_slot(m, slot) // (Shift: go to it, not start it)
		return
	}
	pm.select_slot(m, slot)
	if !playing do pm.play(&m.engine)
}

// A sequence pad let go: in Hold, back to the sequence before.
seq_pad_release :: proc(a: ^App, slot: int) {
	st := &a.perf
	if !a.m.project.launch_hold || !st.holding || st.held_seq != slot do return
	st.holding = false
	pm.select_slot(&a.m, st.held_from)
}

// How the pads play: each its sound, a keyboard of the selected one, or
// it at 16 velocities. Held pads let go first.
set_play_mode :: proc(a: ^App, mode: pm.Play_Mode) {
	if a.play_mode == mode do return
	for k in 0 ..< pm.PADS_PER_BANK do release(a, a.bank * pm.PADS_PER_BANK + k)
	a.play_mode = mode
}
