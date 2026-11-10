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
	if ui.segmented("play_mode", {"Pads", "Keyboard", "Velocity"}, &mode) {
		for k in 0 ..< pm.PADS_PER_BANK do release(a, a.bank * pm.PADS_PER_BANK + k)
		a.play_mode = pm.Play_Mode(mode)
	}
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
		if hit.pressed {
			a.perf_held[i] = true
			if a.perf_hold {
				a.perf_latched[i] = !a.perf_latched[i]
				pm.hold_perf_fx(m, i, a.perf_latched[i])
			} else {
				pm.hold_perf_fx(m, i, true)
			}
		}
		if hit.released {
			a.perf_held[i] = false
			if !a.perf_hold do pm.hold_perf_fx(m, i, false)
		}
		if hit.selected && !hit.menu { // Shift- or Cmd-click: edit it
			a.fx = {.Perf, i, 0}
			show_detail(a, .Effects)
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
