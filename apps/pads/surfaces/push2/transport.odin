package pads_push2

import "core:math"
import "core:time"

import kit "fsurf:surface"
import pa "../../api"

/*
The transport's lights, in time (one task every RENDER_MS reads Pads'
transport and lights the buttons from it):

- **Tap Tempo** blinks every beat, always (stopped, at the tempo), brighter
  on the bar's first beat.
- **Play** blinks on the beat while playing (dim stopped).
- **Record** blinks fast while counting in, on the beat while recording
  (Rec armed and playing, or a sample recording into a pad); armed and
  stopped, it is lit.
- **Metronome** on pulses with the click while it clicks (lit stopped).
- **Session** blinks in eighths while a sequence's launch waits for its
  moment.
*/

// What the transport's lights show now.
Transport_Lights :: struct {
	tr:       pa.Transport_State,
	rs:       pa.Recording_State,
	sample_armed: bool, // the Sample control armed (the next pad records)
	queued:   bool, // a lane's launch waits
	frac:     f64,  // where in the beat (0..1)
	first:    bool, // the bar's first beat
	started:  time.Tick, // (stopped: beats counted from here)
	tap_held: bool,
	ok:       bool,
	owned:    proc(c: ^kit.Component, slot: string, control: ^kit.Control), // the transport's own (stop)
}

@(private)
transport_lights_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, transport: ^kit.Component) -> ^kit.Component {
	p.lights.started = time.tick_now()
	p.lights.owned = transport.on_owned
	transport.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		l := &p.lights
		if !l.ok {
			if l.owned != nil do l.owned(c, slot, control)
			return
		}
		on := l.frac < 0.5 // (the beat's first half)
		switch slot {
		case "tap":
			v := u8(W_DIM)
			if l.frac < 0.25 do v = W_ON if l.first else W_HALF
			kit.light_value(control, W_ON if l.tap_held else v)
		case "play":
			kit.light_value(control, GREEN if l.tr.playing && on else DIM_GREEN)
		case "record":
			v := u8(DIM_RED)
			switch {
			case l.tr.counting_in && l.rs.armed: v = RED if math.mod(l.frac * 4, 1) < 0.5 else DIM_RED
			case l.rs.recording || l.rs.sampling || l.sample_armed: v = RED if on else DIM_RED
			case l.rs.armed: v = RED
			}
			kit.light_value(control, v)
		case "metronome":
			v := u8(W_DIM)
			if l.tr.metronome {
				clicks := l.tr.playing && (!l.tr.metronome_recording_only || l.rs.recording)
				v = W_HALF if clicks && l.frac >= 0.2 else W_ON
			}
			kit.light_value(control, v)
		case:
			if l.owned != nil do l.owned(c, slot, control)
		}
	}
	c := kit.component_make(cs, "Transport Lights")
	p.transport = transport
	c.on_activate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		kit.task_every(c.cs, RENDER_MS, proc(data: rawptr) {
			p := (^Push2)(data)
			if transport_lights_read(p) {
				kit.redraw_owned(p.transport)
				if p.session_button != nil do kit.redraw_owned(p.session_button)
			}
		}, p, c)
	}
	return c
}

// Reads Pads' transport (whether the lights changed is left to the
// controls: a light sent again unchanged is not sent).
@(private)
transport_lights_read :: proc(p: ^Push2) -> bool {
	t := p.pads_api
	l := &p.lights
	if t == nil do return false
	l.ok = t.transport_state(t.api, &l.tr) == .Ok && t.recording_state(t.api, &l.rs) == .Ok
	t.ui_sample_armed(t.api, &l.sample_armed)
	if !l.ok do return false
	num := max(int(l.tr.time_sig_num), 1)
	if l.tr.playing {
		b := l.tr.timeline_beat
		l.frac = b - math.floor(b)
		l.first = l.tr.beat_in_bar == 1 if !l.tr.counting_in else int(math.floor(b)) %% num == 0
	} else {
		b := time.duration_seconds(time.tick_since(l.started)) * max(l.tr.bpm, 1) / 60
		l.frac = b - math.floor(b)
		l.first = int(math.floor(b)) %% num == 0
	}
	l.queued = false
	if l.tr.playing {
		ls: pa.Launcher_State
		if t.launcher_state(t.api, &ls) == .Ok do for lane in 0 ..< ls.lanes {
			st: pa.Lane_State
			if t.launcher_lane(t.api, lane, &st) == .Ok && st.queued >= 0 && st.queued != st.playing {
				l.queued = true
				break
			}
		}
	}
	return true
}

// The Session button's light: its mode's, blinking in eighths while a
// launch waits.
@(private)
session_light :: proc(p: ^Push2, base: u8) -> u8 {
	l := &p.lights
	if !l.ok || !l.queued do return base
	return W_ON if math.mod(l.frac * 2, 1) < 0.5 else W_DIM
}
