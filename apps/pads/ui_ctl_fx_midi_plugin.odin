// MIDI and plug-ins: the pad's MIDI effects and CLAP plug-ins (in an
// effect slot, or as a pad's instrument) on a controller's display
// (docs/design/push2-devices.md, docs/design/push2-fx-midi-plugin.md),
// each its picture (ui_fxpic_midi_plugin.odin) over its banks.
//
//	MIDI effects: Repeat (Rate, Gate) and Arpeggiator (Mode, Rate,
//	Octaves, Gate); the rates, the mode and the octaves dropdowns. The
//	lower row turns note repeat, the arpeggiator and its latch on and off.
//	Plug-ins: their parameters in banks of eight (seven after Perform's
//	Intensity), named for the parameters' CLAP module where the plug-in
//	gives one, else by number ("1–8", "9–16"...); stepped ones dropdowns
//	of the plug-in's own names for their steps. Open / Close Editor on the
//	lower row. An instrument keeps its pad's letter and name on top.
//
// An effect's On is Mute + Device, Remove is Delete + Device.
package pads

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:clap"
import fc "fire:core"
import c "fire:sys/clap"
import "fire:transport"

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_midi_plugin :: proc(p: ^Fx_Panel) -> bool {
	switch p.where_ {
	case .Midi:
		mp_midi(p)
		return true
	case .Plugin_Instrument:
		if p.plugin == nil do return false
		mp_plugin(p)
		return true
	case .Slot:
		if p.kind != .Plugin || p.plugin == nil || p.twin do return false
		mp_plugin(p)
		return true
	case .Synth, .Pad_Eq:
	}
	return false
}

// The tempo grid now: the bar the transport is in and where in it (stopped:
// the clock's own bar).
@(private = "file")
mp_grid :: proc(a: ^App) -> Rhy_Grid {
	m := &a.m
	st := transport.status(a.host.clock)
	bar := max(pm.bar_beats(&m.project), 0.25)
	g := Rhy_Grid{bar = bar, grid = f64(st.grid), bpm = st.tempo_bpm if st.tempo_bpm > 0 else 120}
	if beat, playing := pm.position(&m.engine); playing && beat >= 0 {
		g.playing = true
		g.now = math.mod(beat, bar)
		g.bar_no = int(beat / bar) + 1
	} else {
		g.now = g.grid - math.floor(g.grid / bar) * bar
	}
	return g
}

// --- MIDI effects ------------------------------------------------------------------------------

// The notes the pad last heard live (what its arpeggiator walks), in the
// order they came: those held, gathered while any is (a gap longer than
// MP_GESTURE starts again). Read on the UI's side: what the window and a
// controller hold, what came back from the engine (MIDI in). The arpeggiator's own notes come back as held
// ones too: those an octave or more above a note already in are left out.
@(private = "file")
mp_heard: struct {
	pad:   int,
	notes: [8]int,
	n:     int,
	was:   [256]bool,
	last:  time.Tick, // when any was last held
}

@(private = "file")
MP_GESTURE :: 0.6 // seconds

// The notes the arpeggiator picture walks for pad `i`, and where they come
// from: held now, the last played, or a demo chord (none yet).
@(private = "file")
mp_notes :: proc(a: ^App, i: int) -> (notes: []int, source: string) {
	H := &mp_heard
	if H.pad != i + 1 do H^ = {pad = i + 1}
	// Held now: Keyboard mode's keys on the pad, the pad itself, MIDI notes
	// into it (and, recording, every hit).
	now: [256]bool
	for k in 0 ..< 256 do now[k], _ = pm.key_held(&a.capture, i, k - 128)
	for &h in a.api.keys_held do if h.count > 0 && h.pad == i do for x in h.pitches[:h.count] do now[int(x) + 128] = true
	if a.held[i] do now[128] = true
	any := false
	for k in 0 ..< 256 {
		held := now[k]
		defer H.was[k] = held
		if !held do continue
		any = true
		if H.was[k] do continue
		// Newly held: a new gesture after a gap, else one more of this one.
		if H.last != {} && time.duration_seconds(time.tick_since(H.last)) > MP_GESTURE do H.n = 0
		H.last = time.tick_now()
		pitch := k - 128
		known := false
		for x in H.notes[:H.n] do if (pitch - x) % 12 == 0 && pitch >= x do known = true
		if known do continue
		if H.n == len(H.notes) {
			copy(H.notes[:], H.notes[1:])
			H.n -= 1
		}
		H.notes[H.n] = pitch
		H.n += 1
	}
	if any do H.last = time.tick_now()
	if H.n == 0 {
		@(static) demo := [3]int{0, 4, 7}
		return demo[:], "(a demo chord: none played yet)"
	}
	recent := H.last != {} && time.duration_seconds(time.tick_since(H.last)) <= MP_GESTURE
	return H.notes[:H.n], "held" if recent else "last played"
}

// A gate (0.05..1 of a step) on `bank`'s column `col`, as a percentage:
// whether it moved (`v` the new one) and whether its encoder was let go.
@(private = "file")
mp_gate :: proc(p: ^Fx_Panel, bank, col: int, label: string, v: ^f32) -> (changed, ended: bool) {
	n := fx_index(p, bank, col)
	tag := fmt.ctprintf("%s##mpg%d", label, n)
	if !ctl_knob(p.ctx, n, p.banks * 8, tag, p.plot) do return
	x := v^
	e := ui.knob(tag, &x, 0.05, 1, 0.5, "%.2f", shown_value = fmt.ctprintf("%.0f %%", x * 100))
	v^ = clamp(x, 0.05, 1)
	return e.changed, e.ended
}

@(private = "file")
MP_OCTAVES := [?]string{"1", "2", "3", "4"}

@(private = "file")
mp_midi :: proc(p: ^Fx_Panel) {
	ctx := p.ctx
	a := ctx.a
	i := p.pad
	fx, _ := pa.sequence_midi_fx(&a.api, i64(i))
	ctl_tabs(ctx, {"MIDI Effects"}, 0)
	fx_banks(p, "Repeat", "Arpeggiator")
	// The picture: the bank shown's effect.
	arp := a.ctl.page == 1
	notes, source := mp_notes(a, i)
	pic := Mp_Midi_Picture {
		arp = arp, on = fx.arp if arp else fx.repeat, rate = int(fx.arp_rate if arp else fx.repeat_rate), gate = fx.arp_gate if arp else fx.repeat_gate,
		mode = int(fx.arp_mode), octaves = int(fx.arp_octaves), latch = fx.arp_latch, notes = notes, source = source,
		grid = mp_grid(a), color = ui.rgb(a.m.project.pads[i].color),
	}
	if !arp {
		switch {
		case fx.repeat && fx.arp:    pic.instead = "the arpeggiator plays instead"
		case a.m.engine.repeat_all:  pic.instead = fmt.tprintf("the toolbar's Note Repeat plays (%s)", MP_RATE_NAMES[clamp(int(a.m.engine.repeat_all_settings.rate), 0, len(MP_RATE_NAMES) - 1)])
		}
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	mp_midi_picture(pic, p.plot)
	// The knobs: the rates, the mode and the octaves dropdowns.
	to := fx
	set := false
	gesture, ended := false, false
	if k := fx_choice(p, 0, 0, "Rate", MP_RATE_NAMES[:], int(fx.repeat_rate)); k >= 0 do to.repeat_rate, set = pa.Grid(k), true
	if ch, en := mp_gate(p, 0, 1, "Gate", &to.repeat_gate); ch || en do set, gesture, ended = set || ch, gesture || ch, ended || en
	if k := fx_choice(p, 1, 0, "Mode", MP_ARP_MODES[:], int(fx.arp_mode)); k >= 0 do to.arp_mode, set = pa.Arp_Mode(k), true
	if k := fx_choice(p, 1, 1, "Rate", MP_RATE_NAMES[:], int(fx.arp_rate)); k >= 0 do to.arp_rate, set = pa.Grid(k), true
	if k := fx_choice(p, 1, 2, "Octaves", MP_OCTAVES[:], int(fx.arp_octaves) - 1); k >= 0 do to.arp_octaves, set = i64(k + 1), true
	if ch, en := mp_gate(p, 1, 3, "Gate", &to.arp_gate); ch || en do set, gesture, ended = set || ch, gesture || ch, ended || en
	// The lower row: each on or off.
	if b, _ := ctl_button(ctx, 0, "Repeat", fx.repeat, p.full); b do to.repeat, set = !fx.repeat, true
	if b, _ := ctl_button(ctx, 1, "Arpeggiator", fx.arp, p.full); b do to.arp, set = !fx.arp, true
	if b, _ := ctl_button(ctx, 2, "Latch", fx.arp_latch, p.full); b do to.arp_latch, set = !fx.arp_latch, true
	if gesture do pa.history_gesture_begin(&a.api) // (a gate's turn: one undo step)
	if set && to != fx do pa.sequence_set_midi_fx(&a.api, i64(i), to)
	if ended do pa.history_gesture_end(&a.api)
}

// --- plug-ins ----------------------------------------------------------------------------------

// What a plug-in says of its parameters that the engine doesn't keep: each
// one's CLAP module, and its steps' names (a stepped one's, read once).
// Kept for the plug-in shown (another: read again).
@(private = "file")
mp_cache: struct {
	plugin:  ^clap.Plugin,
	count:   int,
	modules: map[fc.Param_Id]string,
	steps:   map[fc.Param_Id][]string,
}

@(private = "file")
mp_cache_for :: proc(pl: ^clap.Plugin) {
	C := &mp_cache
	if C.plugin == pl && C.count == len(pl.infos) do return
	for _, s in C.modules do delete(s)
	for _, list in C.steps {
		for s in list do delete(s)
		delete(list)
	}
	clear(&C.modules)
	clear(&C.steps)
	C.plugin, C.count = pl, len(pl.infos)
	if pl.params == nil do return
	n := int(pl.params.count(pl.plugin))
	for k in 0 ..< n {
		info: c.Param_Info
		if !pl.params.get_info(pl.plugin, u32(k), &info) do continue
		module := strings.trim_space(string(cstring(&info.module[0])))
		if module != "" do C.modules[fc.Param_Id(info.id)] = strings.clone(module)
	}
}

// Stepped parameter `info`'s steps as the plug-in names them (nil: more
// than 64 of them). Where it names them only by their number ("1.00"), or
// not at all: Off and On for two, else whole numbers.
@(private = "file")
mp_steps :: proc(pl: ^clap.Plugin, info: fc.Param_Info) -> []string {
	if info.max - info.min > 64 do return nil
	C := &mp_cache
	if list, ok := C.steps[info.id]; ok do return list
	n := int(info.max - info.min) + 1
	list := make([]string, n)
	for k in 0 ..< n {
		v := info.min + f64(k)
		text := strings.trim_space(clap.plugin_param_text(pl, info.id, v, context.temp_allocator))
		if x, ok := strconv.parse_f64(text); text == "" || (ok && x == v) {
			text = OFF_ON[k] if info.min == 0 && info.max == 1 else fmt.tprintf("%d", int(v))
		}
		list[k] = strings.clone(text)
	}
	C.steps[info.id] = list
	return list
}

// A bank of a plug-in's parameters: its name, and which (indices into the
// parameters shown).
@(private = "file")
Mp_Bank :: struct {
	name:   string,
	params: [8]int,
	n:      int,
}

// The plug-in's parameters (`params`) in banks of `per`: by module where
// it gives them (each module's in turn, in the order they first come; a
// second bank of one "Osc 2"), else by number ("1–8").
@(private = "file")
mp_banks :: proc(params: []fc.Param_Info, per: int) -> []Mp_Bank {
	C := &mp_cache
	out := make([dynamic]Mp_Bank, context.temp_allocator)
	modules := make([dynamic]string, context.temp_allocator)
	for q in params {
		m := C.modules[q.id] or_else ""
		found := false
		for x in modules do found ||= x == m
		if !found do append(&modules, m)
	}
	numbered := len(modules) == 1 && modules[0] == ""
	for m in modules {
		first := len(out)
		for q, k in params {
			if (C.modules[q.id] or_else "") != m do continue
			if len(out) == first || out[len(out) - 1].n == per do append(&out, Mp_Bank{})
			b := &out[len(out) - 1]
			b.params[b.n] = k
			b.n += 1
		}
		// Its name: the module's last part ("Synth/Osc 1": "Osc 1"), numbered past its first.
		short := m
		if j := strings.last_index(m, "/"); j >= 0 do short = m[j + 1:]
		if short == "" do short = "Other"
		for &b, k in out[first:] {
			switch {
			case numbered: b.name = fmt.tprintf("%d–%d", b.params[0] + 1, b.params[b.n - 1] + 1)
			case k == 0:   b.name = short
			case:          b.name = fmt.tprintf("%s %d", short, k + 1)
			}
		}
	}
	return out[:]
}

// The parameter last turned (shown large once let go), of the plug-in shown.
@(private = "file")
mp_last: struct {
	plugin:    ^clap.Plugin,
	id:        fc.Param_Id,
	intensity: bool,
	set:       bool,
}

@(private = "file")
mp_plugin :: proc(p: ^Fx_Panel) {
	ctx := p.ctx
	a := ctx.a
	m := &a.m
	pl := p.plugin
	mp_cache_for(pl)
	params := pm.target_params(&m.engine, p.t)
	banks := mp_banks(params, 8 - p.lead)
	names := make([]string, len(banks), context.temp_allocator)
	for b, k in banks do names[k] = b.name
	fx_banks(p, ..names)
	page := clamp(a.ctl.page, 0, max(len(banks) - 1, 0))
	// The knobs: the bank shown's (the others aren't drawn).
	if page < len(banks) {
		b := banks[page]
		for k in 0 ..< b.n {
			info := params[b.params[k]]
			steps: []string
			if .Stepped in info.flags do steps = mp_steps(pl, info)
			fx_knob(p, page, k, info.id, info.name, steps)
		}
	}
	// The parameter turned: its encoder touched now, else the last.
	L := &mp_last
	if L.plugin != pl do L^ = {plugin = pl}
	turning := false
	if ki := ui.knob_input; ki != nil && page < len(banks) {
		for col in 0 ..< 8 do if ki.held[col] {
			switch {
			case p.lead == 1 && col == 0: L.intensity, L.set = true, true
			case col - p.lead < banks[page].n:
				L.id, L.intensity, L.set = params[banks[page].params[col - p.lead]].id, false, true
			case: continue
			}
			turning = true
			break
		}
	}
	// The picture.
	pic := Mp_Plugin_Picture {
		name = pm.slot_name(p.s), params = len(params), bank = page, turning = turning,
		bold = a.platform.fonts.bold, color = ui.theme().accent, off = p.where_ == .Slot && !p.s.on && p.t.kind != .Perf,
	}
	if pl.library != nil do for d in pl.library.plugins do if d.id == pl.id {
		pic.vendor, pic.version = d.vendor, d.version
		if d.name != "" do pic.name = d.name
	}
	if p.where_ == .Plugin_Instrument {
		pad := &m.project.pads[p.pad]
		pic.pad = fmt.tprintf("%s  %s", pm.pad_label(p.pad), pm.pad_name(pad))
		pic.pad_color = ui.rgb(pad.color)
		pic.color = pic.pad_color
	}
	shown := make([]Mp_Plugin_Bank, len(banks), context.temp_allocator)
	for b, k in banks do shown[k] = {b.name, b.n}
	pic.banks = shown
	if L.set {
		if L.intensity && p.t.kind == .Perf {
			x := m.project.perf_intensity[p.t.index]
			pic.knob, pic.value, pic.frac = "Intensity", fmt.tprintf("%.2f", x), x
		} else if info, ok := fx_param_info(p, L.id); ok {
			v := fx_value(p, L.id)
			pic.knob = info.name
			pic.value = clap.plugin_param_text(pl, L.id, f64(v), context.temp_allocator)
			if pic.value == "" do pic.value = fmt.tprintf("%.2f", v)
			if info.max > info.min do pic.frac = f32((f64(v) - info.min) / (info.max - info.min))
		}
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	mp_plugin_picture(pic, p.plot)
	// The lower row: its editor (on the computer).
	ctl_editor_button(ctx, 0, p.t, pl, p.full)
}
