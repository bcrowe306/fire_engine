package pads_model

import fc "fire:core"
import "fire:clip"
import "fire:dsp"
import "fire:graph"
import tb "fire:timebase"

// Automation of any parameter (points with a target): an automation
// player for each node a target points at, wired into it, given the
// points of every target on that node in what plays. Pads' own lanes stay
// on their three players (`sync_automation`).

// [control] A node's automation player.
@(private)
Auto_Dest :: struct {
	node:    graph.Node_Id, // the node it moves
	id:      graph.Node_Id, // the player's node
	player:  ^clip.Automation_Player,
	playing: bool, // it has a clip
}

// [control] The node target `t` moves now, if it has one (a pad that is
// live, an insert or send that is there).
resolve_target :: proc(e: ^Engine, t: Auto_Target) -> (id: graph.Node_Id, ok: bool) {
	switch t.track {
	case .None:
		return
	case .Pad:
		i := int(t.index)
		if i >= PADS do return
		n := &e.nodes[i]
		if !n.live do return
		st := &e.mixer.strips[i]
		switch t.device {
		case .Sound, .Pan: return n.voice, true
		case .Eq:          return n.eq, true
		case .Volume:      return n.fader, true
		case .Insert:
			if int(t.slot) >= PAD_INSERTS || !st.inserts[t.slot].has do return
			return st.inserts[t.slot].id, true
		case .Send:
			if int(t.slot) >= BUSES || !st.sends[t.slot].has do return
			return st.sends[t.slot].id, true
		}
	case .Bus, .Main:
		b := BUSES if t.track == .Main else int(t.index)
		if b > BUSES do return
		bn := &e.mixer.buses[b]
		if bn.fader == {} do return
		#partial switch t.device {
		case .Volume: return bn.fader, true
		case .Pan:    return bn.pan, true
		case .Insert:
			if int(t.slot) >= BUS_SLOTS || !bn.slots[t.slot].has do return
			return bn.slots[t.slot].id, true
		}
	}
	return
}

// The parameter target `t` moves on its node (a fader's and a send's gain
// in dB, a pan's position, else its own).
target_param :: proc "contextless" (t: Auto_Target) -> fc.Param_Id {
	#partial switch t.device {
	case .Volume, .Send: return dsp.GAIN_PARAM_DB
	case .Pan:
		if t.track != .Pad do return dsp.PAN_PARAM_POSITION
	}
	return t.param
}

// [control] Gives each targeted node what it plays: a clip of every
// target's points on it in the plan, through its own player (made when
// needed); players of nodes no longer targeted (or gone) are let go.
@(private)
sync_targets :: proc(e: ^Engine) {
	p := e.project
	g := e.host.graph
	pl := e.plan
	length := 0.0
	for s in pl.segs[:pl.count] do length = max(length, s.start + s.span)
	// Each node's builder.
	Build :: struct {
		node: graph.Node_Id,
		b:    clip.Automation_Builder,
		any:  bool,
	}
	builds := make([dynamic]Build, context.temp_allocator)
	defer for &x in builds do clip.automation_builder_destroy(&x.b)
	builder_for :: proc(builds: ^[dynamic]Build, node: graph.Node_Id, length: f64) -> ^Build {
		for &x in builds do if x.node == node do return &x
		append(builds, Build{node = node})
		x := &builds[len(builds) - 1]
		clip.automation_builder_init(&x.b, tb.Beats(max(length, 1e-6)), context.temp_allocator)
		return x
	}
	if length > 0 do for sg in pl.segs[:pl.count] {
		if sg.silent do continue
		s := p.sequences[sg.slot]
		l := seq_beats(p, s)
		lo, hi := sg.offset, min(sg.offset + sg.period, l)
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for pt in s.points {
				if pt.target.track == .None || pt.beat < lo - 1e-9 || pt.beat > hi + 1e-9 || off + pt.beat - lo > sg.span do continue
				node, ok := resolve_target(e, pt.target)
				if !ok do continue
				x := builder_for(&builds, node, length)
				at := tb.Beats(sg.start + off + pt.beat - lo)
				shape := clip.Segment_Shape.Step if pt.target.stepped else (clip.Segment_Shape.Curve if pt.curve != 0 else .Linear)
				v := f64(pt.value)
				if pt.target.stepped do v = f64(int(v + 0.5 if v >= 0 else v - 0.5))
				clip.automation_add_point(&x.b, target_param(pt.target), at, v, shape, pt.curve)
				x.any = true
			}
		}
	}
	loops := pl.loop_end > pl.loop_start
	placement := clip.Placement{at = tb.Beats(pl.at), loop = loops}
	if !loops do placement.length = tb.Beats(plan_end(pl) - pl.at)
	used := make([]bool, len(e.auto_dests), context.temp_allocator)
	for &x in builds {
		if !x.any do continue
		lo, hi := tb.Beats(pl.loop_start), tb.Beats(pl.loop_end)
		if pl.loop_end <= pl.loop_start do lo, hi = 0, tb.Beats(length)
		clip.automation_set_loop(&x.b, lo, hi)
		c, err := clip.automation_build(&x.b)
		if err != .None || c == nil do continue
		k := -1
		for d, j in e.auto_dests do if d.node == x.node do k = j
		if k < 0 {
			node, player, perr := clip.automation_player_create({timeline = e.timeline})
			if perr != .None {
				clip.automation_clip_release(c)
				continue
			}
			id, aerr := graph.add_node(g, node, 0, 0)
			if aerr != .None {
				clip.automation_clip_release(c)
				continue
			}
			graph.connect_events(g, id, x.node)
			append(&e.auto_dests, Auto_Dest{node = x.node, id = id, player = player})
			k = len(e.auto_dests) - 1
			used = resize_bools(used, len(e.auto_dests))
			graph.commit(g)
		}
		clip.automation_player_set(e.auto_dests[k].player, c, placement)
		clip.automation_clip_release(c)
		e.auto_dests[k].playing = true
		used[k] = true
	}
	// The sequence's MIDI CC lanes: one player into the router.
	ccs := clip.Automation_Builder{}
	clip.automation_builder_init(&ccs, tb.Beats(max(length, 1e-6)), context.temp_allocator)
	defer clip.automation_builder_destroy(&ccs)
	any_cc := false
	if length > 0 do for sg in pl.segs[:pl.count] {
		if sg.silent do continue
		s := p.sequences[sg.slot]
		l := seq_beats(p, s)
		lo, hi := sg.offset, min(sg.offset + sg.period, l)
		for off := 0.0; off < sg.span - 1e-9; off += sg.period {
			for c in s.ccs {
				if c.beat < lo - 1e-9 || c.beat > hi + 1e-9 || off + c.beat - lo > sg.span do continue
				clip.automation_add_point(&ccs, CC_PARAM_BASE + fc.Param_Id(int(c.pad) * 128 + int(c.cc)), tb.Beats(sg.start + off + c.beat - lo), f64(c.value), .Step)
				any_cc = true
			}
		}
	}
	if any_cc {
		lo, hi := tb.Beats(pl.loop_start), tb.Beats(pl.loop_end)
		if pl.loop_end <= pl.loop_start do lo, hi = 0, tb.Beats(length)
		clip.automation_set_loop(&ccs, lo, hi)
		if c, err := clip.automation_build(&ccs); err == .None && c != nil {
			if e.cc_player == nil {
				node, player, perr := clip.automation_player_create({timeline = e.timeline})
				if perr == .None {
					if id, aerr := graph.add_node(g, node, 0, 0); aerr == .None {
						graph.connect_events(g, id, e.router_id)
						e.cc_id, e.cc_player = id, player
						graph.commit(g)
					}
				}
			}
			if e.cc_player != nil do clip.automation_player_set(e.cc_player, c, placement)
			clip.automation_clip_release(c)
		}
	} else if e.cc_player != nil {
		clip.automation_player_set(e.cc_player, nil, {})
	}

	// The rest: nothing to play (their nodes get their own values back).
	released := false
	for k := len(e.auto_dests) - 1; k >= 0; k -= 1 {
		if k < len(used) && used[k] do continue
		d := &e.auto_dests[k]
		if d.playing {
			clip.automation_player_set(d.player, nil, {})
			d.playing = false
			released = true
		}
		// A node gone (rebuilt): its player goes too.
		if !node_targeted(e, d.node) {
			graph.remove_node(g, d.id)
			ordered_remove(&e.auto_dests, k)
		}
	}
	if released do targets_resend(e)
}

// A copy of `b` `n` long (the new ones false).
@(private)
resize_bools :: proc(b: []bool, n: int) -> []bool {
	out := make([]bool, n, context.temp_allocator)
	copy(out, b)
	return out
}

// [control] Whether any point of any sequence targets node `node` now.
@(private)
node_targeted :: proc(e: ^Engine, node: graph.Node_Id) -> bool {
	for s in e.project.sequences do for pt in s.points {
		if pt.target.track == .None do continue
		if id, ok := resolve_target(e, pt.target); ok && id == node do return true
	}
	return false
}

// [control] Lets every target go (stopped): their players play nothing,
// and the nodes get their own values again.
@(private)
release_targets :: proc(e: ^Engine) {
	any := false
	for &d in e.auto_dests do if d.playing {
		clip.automation_player_set(d.player, nil, {})
		d.playing = false
		any = true
	}
	if e.cc_player != nil do clip.automation_player_set(e.cc_player, nil, {})
	if any do targets_resend(e)
}

// [control] Whether a targeted node is not the one its player is wired
// to any more (a pad or an effect rebuilt): the sequencer syncs again.
@(private)
targets_stale :: proc(e: ^Engine) -> bool {
	for s in e.project.sequences[e.project.slot:e.project.slot + 1] do for pt in s.points {
		if pt.target.track == .None do continue
		id, ok := resolve_target(e, pt.target)
		if !ok do continue
		found := false
		for d in e.auto_dests do if d.node == id && d.playing do found = true
		if !found do return true
	}
	return false
}

// [control] The project's own values sent again where automation moved
// them: pads' (sound, EQ, fader), every insert's and bus's.
@(private)
targets_resend :: proc(e: ^Engine) {
	e.resend = true
	g := e.host.graph
	p := e.project
	for &st, i in e.mixer.strips {
		if !st.built do continue
		for &f, k in st.inserts do if f.has do apply_slot(g, &f, p.pads[i].inserts[k], true)
		for &sn in st.sends do if sn.has do sn.db = 1e9 // (sent again)
	}
	for &bn, b in e.mixer.buses {
		bn.sent = false
		settings := &p.main if b == BUSES else &p.buses[b]
		for &f, k in bn.slots do if f.has do apply_slot(g, &f, settings.slots[k], true)
	}
	for i in 0 ..< PADS do mark(e, i)
}

// [control] Takes every target's player out of the graph.
@(private)
remove_targets :: proc(e: ^Engine) {
	g := e.host.graph
	for d in e.auto_dests do graph.remove_node(g, d.id)
	clear(&e.auto_dests)
	if e.cc_player != nil do graph.remove_node(g, e.cc_id)
	e.cc_id, e.cc_player = {}, nil
}
