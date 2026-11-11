package pads_model

import "core:math"
import "core:os"
import "core:path/filepath"

import "fire:clip"
import "fire:dsp"
import "fire:graph"
import "fire:record"
import "fire:stream"
import tb "fire:timebase"
import "fire:transport"

// A stretch of the timeline where one sequence's clip plays for an audio
// pad: from `start` (a top of that sequence) to `end` (`math.INF_F64`: on
// and on).
Audio_Run :: struct {
	valid:      bool,
	slot:       int,
	start, end: f64,
	offset:     f64, // beats into the sequence each pass starts at (a song step's part)
	period:     f64, // beats a pass plays
	step:       int, // the song step it starts at, or -1
}

// Silence, for the monitor's gain.
@(private)
MONITOR_OFF_DB :: -96

// An audio pad's nodes besides the voice, EQ and fader: the players into
// the voice, the input into the monitor (into the voice) and the recorder.
@(private)
build_audio :: proc(e: ^Engine, i: int, n: ^Pad_Nodes, pad: Pad) {
	g := e.host.graph
	n.audio = true
	for k in 0 ..< 2 {
		node, player := clip.audio_player_create(clip.default_audio_player_settings(e.timeline, e.host.streamer))
		id, err := graph.add_node(g, node, 0, 2)
		if err != .None do continue
		n.players[k], n.player_ids[k] = player, id
		for c in 0 ..< 2 do graph.connect(g, id, c, n.voice, c)
	}
	n.holds = {}
	// The input: a pair of channels, or one on both sides.
	ins := g.settings.input_channels
	first := int(pad.input.channel)
	src := [2]int{first, first + 1} if pad.input.stereo else [2]int{first, first}
	channels := 2 if pad.input.stereo else 1
	if ins <= max(src[0], src[1]) do return // the device has no such input
	if mid, err := graph.add_node(g, dsp.gain_create(), 2, 2); err == .None {
		n.monitor_id = mid
		for c in 0 ..< 2 {
			graph.connect(g, graph.INPUT, src[c], mid, c)
			graph.connect(g, mid, c, n.voice, c)
		}
		graph.set_param(g, mid, dsp.GAIN_PARAM_DB, MONITOR_OFF_DB)
		n.monitor_on = false
	}
	if e.host.disk == nil do return
	dir, _ := filepath.join({e.project.dir, "takes"}, context.temp_allocator)
	os.make_directory_all(dir)
	node, rec, err := record.audio_recorder_create(e.host.disk, {timeline = e.timeline, channels = channels, directory = dir, name = pad_label(i), encoding = .Float32})
	if err != .None do return
	id, aerr := graph.add_node(g, node, channels, 0)
	if aerr != .None do return
	n.rec, n.rec_id, n.rec_on = rec, id, false
	for c in 0 ..< channels do graph.connect(g, graph.INPUT, src[c], id, c)
	// Nothing while counting in: takes start at the top.
	record.audio_recorder_set_punch(rec, 0, 1e12)
}

// Takes everything a pad has out of the graph.
@(private)
remove_pad_nodes :: proc(g: ^graph.Graph, n: ^Pad_Nodes) {
	if n.track_in != {} do graph.remove_node(g, n.track_in)
	graph.remove_node(g, n.voice)
	graph.remove_node(g, n.eq)
	graph.remove_node(g, n.auto_voice)
	graph.remove_node(g, n.auto_eq)
	graph.remove_node(g, n.fader)
	graph.remove_node(g, n.auto_fader)
	if n.audio {
		for id in n.player_ids do if id != {} do graph.remove_node(g, id)
		if n.monitor_id != {} do graph.remove_node(g, n.monitor_id)
		if n.rec_id != {} do graph.remove_node(g, n.rec_id)
	}
	n^ = {}
}

// Each frame: audio pads record while armed and recording (not in song
// mode), monitor while armed, and their players have what plays now and
// next.
@(private)
sync_audio :: proc(e: ^Engine) {
	p := e.project
	g := e.host.graph
	any := false
	for &n, i in e.nodes {
		if !n.live || !n.audio do continue
		any = true
		pad := &p.pads[i]
		rec := e.recording && e.armed[i] && !p.song_mode
		if n.rec != nil && rec != n.rec_on {
			if record.audio_recorder_arm(n.rec, rec) == .None do n.rec_on = rec
		}
		mon := e.armed[i] && pad.monitor
		if n.monitor_id != {} && mon != n.monitor_on {
			graph.set_param(g, n.monitor_id, dsp.GAIN_PARAM_DB, 0 if mon else MONITOR_OFF_DB)
			n.monitor_on = mon
		}
	}
	if !any do return
	beat, _, _ := transport.timeline_status(e.host.clock, e.timeline)
	place_audio(e, f64(beat))
}

// Gives each audio pad's players the runs of the plan at `beat` and after
// it: one plays now, the other is ready for what comes next.
@(private)
place_audio :: proc(e: ^Engine, beat: f64) {
	if e.audio_dirty {
		for &n in e.nodes do n.holds = {} // a clip changed: everything again
		e.audio_dirty = false
	}
	cur, next := audio_runs(e.plan, beat)
	for &n, i in e.nodes {
		if !n.live || !n.audio do continue
		// The player that has what plays now keeps it; the other takes the next.
		now := 0
		if n.holds[1] == cur || (n.holds[0] != cur && next.valid && n.holds[0] == next) do now = 1
		if n.holds[now] != cur do give(e, &n, i, now, cur)
		if next.valid && n.holds[1 - now] != next do give(e, &n, i, 1 - now, next)
	}
}

@(private)
give :: proc(e: ^Engine, n: ^Pad_Nodes, pad, k: int, run: Audio_Run) {
	if n.players[k] == nil do return
	n.holds[k] = run
	c := e.project.clips[run.slot][pad] if run.valid else {}
	muted := run.valid && run.step >= 0 && run.step < e.project.song.count && e.project.song.steps[run.step].mute
	src := source_of(e, c.sample)
	if src == nil || !(c.bpm > 0) || muted {
		clip.audio_player_set(n.players[k], nil, {})
		return
	}
	// A song step's part of the take: its frames.
	info := stream.source_info(src)
	fpb := info.sample_rate * 60 / c.bpm
	first := i64(run.offset * fpb)
	last := i64((run.offset + run.period) * fpb) if run.period > 0 else 0
	if first <= 0 || first >= info.frames do first = 0
	if last <= first || last > info.frames do last = 0
	ac, err := clip.audio_clip_create(src, {start = first, end = last, bpm = c.bpm, mode = .Repitch, fade_in = -1, fade_out = -1})
	if err != .None {
		clip.audio_player_set(n.players[k], nil, {})
		return
	}
	placement := clip.Placement{at = tb.Beats(run.start), loop = true}
	if run.end < math.INF_F64 do placement.length = tb.Beats(run.end - run.start)
	clip.audio_player_set(n.players[k], ac, placement)
	clip.audio_clip_release(ac)
}

// The run of plan `pl` playing at timeline beat `beat` (the first, before
// the plan starts), and the one after it. Consecutive segments of one
// sequence are one run; a run that is the whole loop goes on and on.
audio_runs :: proc(pl: Plan, beat: f64) -> (cur, next: Audio_Run) {
	pl := pl
	if pl.count == 0 do return
	loops := pl.loop_end > pl.loop_start
	cycle := pl.loop_end - pl.loop_start
	x := max(beat - pl.at, 0)
	base := pl.at
	if loops && x >= pl.loop_end {
		n := math.floor((x - pl.loop_start) / cycle)
		base += n * cycle
		x -= n * cycle
	}
	seg := -1
	for s, i in pl.segs[:pl.count] do if x >= s.start && x < s.start + s.span {
		seg = i
		break
	}
	if seg < 0 do return // past the end
	run_from :: proc(pl: ^Plan, seg: int, base: f64, loops: bool) -> (r: Audio_Run, after: int) {
		first := pl.segs[seg]
		last := seg
		for last + 1 < pl.count && pl.segs[last + 1].slot == first.slot && pl.segs[last + 1].offset == first.offset && pl.segs[last + 1].period == first.period && pl.alike[last + 1] do last += 1
		end := pl.segs[last].start + pl.segs[last].span
		r = {valid = true, slot = first.slot, start = base + first.start, end = base + end, offset = first.offset, period = first.period, step = first.step}
		if loops && first.start <= pl.loop_start && end >= pl.loop_end do r.start, r.end = pl.at + first.start, math.INF_F64 // the same run every cycle
		return r, last + 1
	}
	after: int
	cur, after = run_from(&pl, seg, base, loops)
	if cur.end == math.INF_F64 do return
	if after < pl.count && (!loops || pl.segs[after].start < pl.loop_end) {
		next, _ = run_from(&pl, after, base, loops)
	} else if loops {
		for s, i in pl.segs[:pl.count] do if s.start >= pl.loop_start {
			next, _ = run_from(&pl, i, base + cycle, loops)
			break
		}
	}
	return
}

// Whether every audio pad's players can start without a dropout (their
// takes' starts are buffered): a take just recorded or placed needs a
// moment from the disk.
audio_ready :: proc(e: ^Engine) -> bool {
	for &n in e.nodes do if n.live && n.audio {
		for pl in n.players do if pl != nil && !clip.audio_player_ready(pl) do return false
	}
	return true
}
