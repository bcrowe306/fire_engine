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
	draw_launcher(a)
	im.Spacing()
	im.Separator()
	wide := im.GetContentRegionAvail().x >= 900
	if wide && !im.BeginTable("##perform", 3, {.BordersInnerV, .PadOuterX}) do wide = false
	defer if wide do im.EndTable()
	if wide {
		im.TableSetupColumn("a", {.WidthStretch}, 1)
		im.TableSetupColumn("b", {.WidthStretch}, 1)
		im.TableSetupColumn("c", {.WidthStretch}, 1.3)
		im.TableNextColumn()
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

// The sequences to play live: every one in use (and the current one) as
// a cell, in its state: playing (a bar runs across it), queued (it pulses
// and counts down), the one shown. Click to launch it (when stopped it
// starts playing); Shift-click only to show it. When a switch lands: the
// project's launch setting (in the toolbar).
draw_launcher :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	t := ui.theme()

	beat, playing := pm.position(&m.engine)
	tl, _ := pm.timeline_beat(&m.engine)
	next, in_beats, queued := pm.pending_switch(&m.engine)
	clock := a.transport.clock
	w: f32 = 132
	h: f32 = 58
	gap: f32 = 6
	avail := im.GetContentRegionAvail().x
	per_row := max(int((avail + gap) / (w + gap)), 1)
	shown := 0
	dl := im.GetWindowDrawList()
	for k in 0 ..< pm.SLOTS {
		if !pm.slot_used(m, k) && k != p.slot do continue
		if shown % per_row != 0 do im.SameLine(0, gap)
		shown += 1
		im.PushIDInt(i32(9000 + k))
		pos := im.GetCursorScreenPos()
		clicked := im.InvisibleButton("##cell", {w, h})
		ui.name(fmt.tprintf("launch %d", k + 1))
		item_menu(a, seq_target(k), "##cellmenu")
		hovered := im.IsItemHovered()
		is_cur := k == p.slot
		is_playing := is_cur && playing
		is_next := queued && next == k
		sc := ui.rgb(pm.sequence_color(p, k))
		bg := ui.mix(t.raised, sc, 0.12)
		if is_playing do bg = ui.mix(t.raised, sc, 0.55)
		else if is_cur do bg = ui.mix(t.raised, sc, 0.28)
		if hovered do bg = ui.lighten(bg, 0.06)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		// Queued: a border that pulses with the beat.
		if is_next {
			pulse := f32(0.5 + 0.5 * math.cos(math.TAU * tl))
			im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.with_alpha(t.warn, 0.5 + 0.5 * pulse)), t.radius, 2.5)
		}
		im.DrawList_AddRectFilled(dl, pos, {pos.x + 4, pos.y + h}, ui.col(sc), 2)
		s := p.sequences[k]
		fg := t.text
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 7}, ui.col(fg), fmt.ctprintf("%s", pm.sequence_name(p, k)))
		info := fmt.ctprintf("%d bar%s%s", s.bars, "" if s.bars == 1 else "s", fmt.tprintf(" · %.0f BPM", s.bpm) if s.bpm > 0 else "")
		if is_next do info = fmt.ctprintf("in %.1f beats", max(in_beats, 0))
		im.DrawList_AddText(dl, {pos.x + 10, pos.y + 7 + im.GetTextLineHeightWithSpacing()}, ui.col(t.warn if is_next else (t.text if is_playing else t.text_dim)), info)
		// Playing: where in it the playhead is.
		if is_playing {
			f := f32(beat / max(pm.seq_beats(p, s), 1e-6))
			im.DrawList_AddRectFilled(dl, {pos.x + 4, pos.y + h - 6}, {pos.x + 4 + (w - 8) * f, pos.y + h - 3}, ui.col(t.text), 2)
		}
		if clicked {
			if im.GetIO().KeyShift {
				if !playing do pm.select_slot(m, k)
			} else {
				pm.select_slot(m, k)
				if !playing do pm.play(&m.engine)
			}
		}
		im.PopID()
	}
	// A new one: the next empty sequence, shown (to record into).
	if shown % per_row != 0 do im.SameLine(0, gap)
	if e := pm.next_empty_slot(m, p.slot); e >= 0 {
		pos := im.GetCursorScreenPos()
		if im.InvisibleButton("##newcell", {w, h}) do pm.select_slot(m, e)
		ui.name("new sequence")
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Go to %s (empty) to make a new one", pm.sequence_name(p, e)))
		im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.with_alpha(t.text, 0.25)), t.radius, 1.5)
		pl := im.CalcTextSize("+  New")
		im.DrawList_AddText(dl, {pos.x + (w - pl.x) / 2, pos.y + (h - pl.y) / 2}, ui.col(t.text_dim), "+  New")
	}
	_ = clock
}

// How the pads play: each its sound, a keyboard of the selected one, or
// it at 16 velocities. Held pads let go first.
set_play_mode :: proc(a: ^App, mode: pm.Play_Mode) {
	if a.play_mode == mode do return
	for k in 0 ..< pm.PADS_PER_BANK do release(a, a.bank * pm.PADS_PER_BANK + k)
	a.play_mode = mode
}
