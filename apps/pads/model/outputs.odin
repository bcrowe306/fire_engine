package pads_model

import app "app:core"
import "fire:dsp"
import "fire:graph"

// Where Pads plays: main on an output pair of the interface, a cue mix
// (a copy of main, each track's cue send, and the click) on another, and
// direct outs (a bus or pad straight to a pair). The app says which pairs
// (they are settings, not the project's); the engine wires them through
// the host's channel mapping, and what isn't open falls back: main to the
// first open pair, a direct out to main, the cue to nowhere.

// The app's output settings (physical channels, 0-based first of a pair).
Outputs :: struct {
	main:      int, // main's pair
	cue:       int, // the cue pair (-1: none)
	cue_db:    f32, // the cue mix's level
	click_cue: bool, // the click on the cue only (not in main)
}

// Sets where Pads plays (sync wires it).
set_outputs :: proc(e: ^Engine, o: Outputs) {
	if e.outputs == o do return
	e.outputs = o
	e.io_dirty = true
}

// The interface's channels changed (reopened with others): what plays to
// and records from them is wired again.
io_changed :: proc(e: ^Engine) {
	e.io_dirty = true
	// Audio pads take their inputs again (built anew: their input "changed").
	for &n, i in e.nodes do if n.live && n.audio {
		n.built.input.channel = 255
		mark(e, i)
	}
}

// Sets pad `index`'s cue send (drags merge: seal when one ends).
set_pad_cue :: proc(m: ^Model, index: int, s: Send) {
	if index < 0 || index >= PADS do return
	pad := m.project.pads[index]
	pad.cue = s
	set_pad(m, index, .Cue, "Cue Send", pad)
}

// Sets bus `b`'s (0-based; not main) cue send.
set_bus_cue :: proc(m: ^Model, b: int, s: Send) {
	if b < 0 || b >= BUSES do return
	nb := m.project.buses[b]
	nb.cue = s
	set_bus(m, b, 7, "Cue Send", nb)
}

// The graph's OUTPUT channels device output pair `first` plays on (both
// open), or false.
@(private)
out_pair :: proc(e: ^Engine, first: int) -> (l, r: int, ok: bool) {
	if first < 0 do return -1, -1, false
	l, r = app.host_output_channel(e.host, first), app.host_output_channel(e.host, first + 1)
	return l, r, l >= 0 && r >= 0
}

// [control] Direct out `pair`'s node (made the first time a route names
// it; sync_outputs wires it).
@(private)
out_pair_node :: proc(e: ^Engine, pair: int) -> graph.Node_Id {
	if pair < 0 || pair >= OUT_PAIRS do return e.mixer.buses[BUSES].input
	mx := &e.mixer
	if mx.out_pairs[pair] == {} {
		id, err := graph.add_node(e.host.graph, dsp.gain_create(), 2, 2)
		if err != .None do return mx.buses[BUSES].input
		mx.out_pairs[pair] = id
		e.io_dirty = true
	}
	return mx.out_pairs[pair]
}

// [control] Wires the outputs to the interface's channels, when where they
// go changed: main to its pair (or the first open one), the cue to its pair
// (or nowhere), each direct out to its pair (or into main: while exporting,
// or when its pair isn't open), and the click to main and the cue (or the
// cue only). True if wires changed.
@(private)
sync_outputs :: proc(e: ^Engine) -> bool {
	g := e.host.graph
	mx := &e.mixer
	o := e.outputs
	want: Out_Wiring
	want.set = true
	outs := g.settings.output_channels
	if l, r, ok := out_pair(e, o.main); ok {
		want.main = {l, r}
	} else {
		want.main = {0, min(1, outs - 1)} // (the first open pair)
	}
	want.cue = {-1, -1}
	if l, r, ok := out_pair(e, o.cue); ok && o.cue != o.main && !e.export_once do want.cue = {l, r}
	want.cue_db = o.cue_db
	want.click_cue = want.cue[0] >= 0
	want.click_main = !(o.click_cue && want.click_cue)
	for id, k in mx.out_pairs {
		if id == {} do continue
		want.pairs[k] = {-2, -2}
		l, r, ok := out_pair(e, 2 * k)
		pair := [2]int{l, r}
		if ok && !e.export_once && pair != want.main do want.pairs[k] = pair
	}
	if !e.io_dirty && mx.wired == want do return false
	e.io_dirty = false
	was := mx.wired
	if !was.set do was = {main = {-1, -1}, cue = {-1, -1}}
	main_in := mx.buses[BUSES].input
	// Main.
	if was.main != want.main {
		for c in 0 ..< 2 do if was.main[c] >= 0 do graph.disconnect(g, mx.out_main, c, graph.OUTPUT, was.main[c])
		for c in 0 ..< 2 do if want.main[c] >= 0 do graph.connect(g, mx.out_main, c, graph.OUTPUT, want.main[c])
	}
	// The cue.
	if was.cue != want.cue {
		for c in 0 ..< 2 do if was.cue[c] >= 0 do graph.disconnect(g, mx.cue_meter_id, c, graph.OUTPUT, was.cue[c])
		for c in 0 ..< 2 do if want.cue[c] >= 0 do graph.connect(g, mx.cue_meter_id, c, graph.OUTPUT, want.cue[c])
	}
	if !was.set || was.cue_db != want.cue_db do graph.set_param(g, mx.out_cue, dsp.GAIN_PARAM_DB, f64(want.cue_db))
	// The click.
	if was.click_main != want.click_main || !was.set {
		for c in 0 ..< 2 {
			if want.click_main do graph.connect(g, e.metro_id, c, mx.out_main, c)
			else do graph.disconnect(g, e.metro_id, c, mx.out_main, c)
		}
	}
	if was.click_cue != want.click_cue || !was.set {
		for c in 0 ..< 2 {
			if want.click_cue do graph.connect(g, e.metro_id, c, mx.out_cue, c)
			else do graph.disconnect(g, e.metro_id, c, mx.out_cue, c)
		}
	}
	// Direct outs.
	for id, k in mx.out_pairs {
		if id == {} || (was.set && was.pairs[k] == want.pairs[k]) do continue
		w := was.pairs[k]
		if was.set {
			if w[0] == -2 do for c in 0 ..< 2 do graph.disconnect(g, id, c, main_in, c)
			else do for c in 0 ..< 2 do if w[c] >= 0 do graph.disconnect(g, id, c, graph.OUTPUT, w[c])
		}
		n := want.pairs[k]
		if n[0] == -2 do for c in 0 ..< 2 do graph.connect(g, id, c, main_in, c)
		else do for c in 0 ..< 2 do graph.connect(g, id, c, graph.OUTPUT, n[c])
	}
	mx.wired = want
	return true
}

// [control] A send (`s`) as a gain from `pre` (before the fader) or `post`
// into `dest` while it is on (not while exporting: the cue isn't
// exported). True if the graph changed.
@(private)
sync_send :: proc(e: ^Engine, sn: ^Send_Node, s: Send, pre, post, dest: graph.Node_Id) -> (changed: bool) {
	g := e.host.graph
	on := s.level > 0 && !e.export_once
	if sn.has && (!on || sn.pre != s.pre) {
		graph.remove_node(g, sn.id)
		sn^ = {}
		changed = true
	}
	if on && !sn.has {
		id, err := graph.add_node(g, dsp.gain_create(), 2, 2)
		if err != .None do return
		src := pre if s.pre else post
		for c in 0 ..< 2 {
			graph.connect(g, src, c, id, c)
			graph.connect(g, id, c, dest, c)
		}
		sn^ = {has = true, id = id, pre = s.pre, db = 1}
		changed = true
	}
	if sn.has {
		if db := send_db(s); db != sn.db {
			graph.set_param(g, sn.id, dsp.GAIN_PARAM_DB, f64(db))
			sn.db = db
		}
	}
	return
}

// Whether audio pad `index`'s input channels are open on the interface
// (always, for an input from inside the mix).
input_open :: proc(e: ^Engine, index: int) -> bool {
	if index < 0 || index >= PADS do return false
	in_ := e.project.pads[index].input
	if in_.from != .Interface do return true
	first := int(in_.channel)
	if app.host_input_channel(e.host, first) < 0 do return false
	return !in_.stereo || app.host_input_channel(e.host, first + 1) >= 0
}

// Audio tracks whose input isn't open on the interface (it changed, or the
// project came from another) take the first one that is: the first pair
// for a stereo input (or, with none, the first channel), the first channel
// for a mono one. One undo step ("Audio Inputs"); nothing while the device
// isn't open or has no input. Returns how many changed. Cheap: call it
// each frame.
inputs_follow :: proc(m: ^Model) -> (changed: int) {
	e := &m.engine
	h := e.host
	if !h.opened || h.open_inputs == {} do return
	first, pair := -1, -1
	for c in 0 ..< 64 do if c in h.open_inputs {
		if first < 0 do first = c
		if pair < 0 && c % 2 == 0 && c + 1 in h.open_inputs do pair = c
	}
	if first < 0 do return
	for pad, i in m.project.pads {
		if pad.kind != .Audio || pad.input.from != .Interface || input_open(e, i) do continue
		p := pad
		if p.input.stereo && pair >= 0 do p.input.channel = u8(pair)
		else do p.input = {channel = u8(first), stereo = false}
		if changed == 0 {
			app.seal(&m.history)
			app.begin(&m.history, "Audio Inputs")
		}
		set_pad(m, i, .Input, "Audio Inputs", p)
		changed += 1
	}
	if changed > 0 {
		app.end(&m.history)
		app.seal(&m.history)
	}
	return
}
