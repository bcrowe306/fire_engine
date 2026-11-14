package pads

import "core:fmt"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import pf "fire:perform"

// A pad's MIDI page (the first device of its chain, before its sound):
// how the pads play (Pads, Keyboard on it, Velocity), its note repeat, its
// arpeggiator, and its MIDI (the key that plays it, Learn, MIDI out). The
// repeat and the arpeggiator are the pad's own (saved with it): they act
// on its live notes, not the sequencer's.

// Four columns side by side when wide; else two (how the pads play and
// MIDI; note repeat and the arpeggiator).
draw_midi_fx :: proc(a: ^App, i: int) {
	avail := im.GetContentRegionAvail()
	wide := avail.x >= 1000
	if !im.BeginTable("##midifx", 4 if wide else 2, {.BordersInnerV, .PadOuterX}) do return
	defer im.EndTable()
	im.TableNextColumn()
	draw_play_as(a, i)
	if wide do im.TableNextColumn()
	else do im.Spacing()
	draw_pad_midi(a, i)
	im.TableNextColumn()
	draw_repeat_fx(a, i)
	if wide do im.TableNextColumn()
	else do im.Spacing()
	draw_arp_fx(a, i)
}

// Whether pad `i` has a MIDI effect on (its tab says so).
midi_fx_on :: proc(a: ^App, i: int) -> bool {
	fx := a.m.project.pads[i].midi_fx
	return fx.repeat_on || fx.arp_on
}

// How the 16 pads play: each its own sound, a keyboard of this pad (a
// scale or chords, from a root and octave), or this pad at 16 velocities.
@(private)
draw_play_as :: proc(a: ^App, i: int) {
	m := &a.m
	section(a, "Play the pads as", false)
	mode := int(a.play_mode)
	if ui.segmented("play_mode", {"Pads", "Keyboard", "Velocity"}, &mode) do set_play_mode(a, pm.Play_Mode(mode))
	if a.play_mode != .Pads {
		im.TextDisabled("%s", fmt.ctprintf("Playing %s %s", pm.pad_label(a.selected), pm.pad_name(&m.project.pads[a.selected])))
	}
	if a.play_mode == .Keyboard {
		k := a.keys // (set through the API: perform_set_keys)
		set :: proc(a: ^App, k: pm.Keys) { pa.perform_set_keys(&a.api, pa.Scale(k.scale), i64(k.root), i64(k.octave), pa.Chord(k.chord)) }
		im.SetNextItemWidth(170)
		if ui.combo("##scale", pm.SCALE_NAMES[k.scale]) {
			for sc in pm.Scale do if im.Selectable(pm.SCALE_NAMES[sc], sc == k.scale) {
				k.scale = sc
				set(a, k)
			}
			im.EndCombo()
		}
		ui.flow(70)
		im.SetNextItemWidth(70)
		if ui.combo("##root", ROOT_NAMES[k.root]) {
			for r, n in ROOT_NAMES do if im.Selectable(r, n == k.root) {
				k.root = n
				set(a, k)
			}
			im.EndCombo()
		}
		oct := f64(k.octave)
		if e := ui.number_drag("octave", &oct, -3, 3, 1, 1, "Octave %+.0f", 110); e.changed {
			k.octave = clamp(int(oct), -3, 3)
			set(a, k)
		}
		ui.flow(170)
		im.SetNextItemWidth(170)
		if ui.combo("##chord", pm.CHORD_NAMES[k.chord]) {
			for c in pm.Chord do if im.Selectable(pm.CHORD_NAMES[c], c == k.chord) {
				k.chord = c
				set(a, k)
			}
			im.EndCombo()
		}
	}
}

// Pad `i`'s note repeat: on (the arpeggiator off), its step, its gate.
@(private)
draw_repeat_fx :: proc(a: ^App, i: int) {
	m := &a.m
	fx := m.project.pads[i].midi_fx
	section(a, "Note repeat", false)
	changed, ended := false, false
	if ui.toggle("Repeat", &fx.repeat_on) {
		if fx.repeat_on do fx.arp_on = false
		changed, ended = true, true
	}
	if im.IsItemHovered() do im.SetTooltip("Held, this pad plays again on every step")
	im.SameLine(0, 6)
	im.SetNextItemWidth(80)
	if rate_combo("##rep_rate", &fx.repeat.rate) do changed, ended = true, true
	ui.flow(150, 6)
	gate := f64(fx.repeat.gate if fx.repeat.gate > 0 else 0.5)
	if e := ui.value_bar("rep_gate", "Gate", &gate, 0.05, 1, 0.01, 0.002, "%.2f", 150); e.changed || e.ended {
		fx.repeat.gate = f32(gate)
		changed = changed || e.changed
		ended = ended || e.ended
	}
	step_strip(m, fx.repeat.rate, fx.repeat_on)
	midi_fx_edit(a, i, fx, "Note Repeat", changed, ended)
}

// Pad `i`'s arpeggiator: on (repeat off), latch, its order, step, octaves
// and gate.
@(private)
draw_arp_fx :: proc(a: ^App, i: int) {
	m := &a.m
	fx := m.project.pads[i].midi_fx
	section(a, "Arpeggiator", false)
	changed, ended := false, false
	if ui.toggle("Arpeggiate", &fx.arp_on) {
		if fx.arp_on do fx.repeat_on = false
		changed, ended = true, true
	}
	if im.IsItemHovered() do im.SetTooltip("The notes held on this pad (in Keyboard, a chord) play one after another")
	im.SameLine(0, 6)
	if ui.toggle("Latch", &fx.arp.latch) do changed, ended = true, true
	ui.flow(120, 6)
	im.SetNextItemWidth(120)
	if ui.combo("##arp_mode", ARP_NAMES[fx.arp.mode]) {
		for am in pf.Arp_Mode do if im.Selectable(ARP_NAMES[am], am == fx.arp.mode) {
			fx.arp.mode = am
			changed, ended = true, true
		}
		im.EndCombo()
	}
	im.SameLine(0, 6)
	im.SetNextItemWidth(80)
	if rate_combo("##arp_rate", &fx.arp.rate) do changed, ended = true, true
	ui.flow(120, 6)
	octaves := f64(max(fx.arp.octaves, 1))
	if e := ui.number_drag("arp octaves", &octaves, 1, 4, 1, 1, "%.0f oct", 80); e.changed || e.ended {
		fx.arp.octaves = int(octaves)
		changed = changed || e.changed
		ended = ended || e.ended
	}
	ui.flow(120, 6)
	gate := f64(fx.arp.gate if fx.arp.gate > 0 else 0.5)
	if e := ui.value_bar("arp_gate", "Gate", &gate, 0.05, 1, 0.01, 0.002, "%.2f", 120); e.changed || e.ended {
		fx.arp.gate = f32(gate)
		changed = changed || e.changed
		ended = ended || e.ended
	}
	step_strip(m, fx.arp.rate, fx.arp_on)
	midi_fx_edit(a, i, fx, "Arpeggiator", changed, ended)
}

@(private)
midi_fx_edit :: proc(a: ^App, i: int, fx: pm.Perform, name: string, changed, ended: bool) {
	if changed {
		pa.history_gesture_begin(&a.api) // (a drag: one step)
		pa.sequence_set_midi_fx(&a.api, i64(i), pa.midi_fx_of(fx))
	}
	if ended do pa.history_gesture_end(&a.api)
}

// Pad `i`'s MIDI: the activity lights, the key that plays it (Learn: the
// next note played), and MIDI out (its hits also go out as a note).
@(private)
draw_pad_midi :: proc(a: ^App, i: int) {
	m := &a.m
	st := &a.perf
	section(a, "MIDI", false)
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
	key := pm.midi_key_of(m, i)
	im.AlignTextToFramePadding()
	im.Text("%s", fmt.ctprintf("%s plays on", pm.pad_label(i)))
	im.SameLine()
	if key >= 0 do im.TextDisabled("%s", fmt.ctprintf("key %d (%s)", key, ui.note_name(key)))
	else do im.TextDisabled("no key")
	im.SameLine()
	if st.learning {
		if a.capture.midi_count != st.learn_seen {
			pa.midi_learn(&a.api, i64(a.capture.midi_key), i64(i))
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
		ch := f64(out.channel) + 1
		if e := ui.number_drag("midi out channel", &ch, 1, 16, 1, 1, "Channel %.0f", 110); e.changed || e.ended {
			pad.midi_out.channel = u8(ch - 1)
			if e.changed do pm.set_pad(m, i, .Whole, "Set MIDI Out", pad)
			if e.ended do app.seal(&m.history)
		}
		im.SameLine(0, 6)
		k := f64(out.key)
		if e := ui.number_drag("midi out note", &k, 0, 127, 1, 1, "Note %.0f", 100); e.changed || e.ended {
			pad.midi_out.key = u8(k)
			if e.changed do pm.set_pad(m, i, .Whole, "Set MIDI Out", pad)
			if e.ended do app.seal(&m.history)
		}
		midi_out_port_combo(a, i, 180)
	}
}
