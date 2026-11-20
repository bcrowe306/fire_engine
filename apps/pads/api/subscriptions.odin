package pads_api

import "core:mem"

import pm "../model"

// What a subscriber hears about. Topics whose module isn't built yet
// answer `subscribe` with `Unsupported`.
Topic :: enum i32 {
	Transport, // playing, tempo, loop, time signature, count-in, metronome, pattern/song (not the playhead: poll it)
	History,   // undo and redo steps, saved or not
	Selection, // the selected pad, the bank, the play mode, the keys
	Pad,
	Mixer,     // buses (added, routed, levels, mute, solo, groups), the pads' levels, pans, mutes, solos, sends, outputs (not the meters: poll them)
	Sequence,
	Song,      // the song's clips, lanes, tempo, meters, markers, loop; the arrangement
	Launcher,  // its lanes, where sequences are, its settings, what each lane plays and has queued
	Project,   // another project open, saved somewhere, renamed; the recent list
	Settings,  // any setting
	Recording,
	Ui,
	Key,       // the project key, the chords' voicing, the progression in use
}

// The topics this version reports.
TOPICS :: bit_set[Topic]{.Transport, .History, .Selection, .Mixer, .Song, .Launcher, .Project, .Settings, .Key}

// Called on the control thread, once a frame at most, when `topic`
// changed (`index`: which pad, bus...; -1 for the whole topic), with the
// `user` given to `subscribe`. Read what it is now with the topic's
// snapshot (`transport_state`...).
Change_Proc :: #type proc "c" (api: ^Api, topic: Topic, index: i64, user: rawptr)

// A subscription, for `unsubscribe` (0: none).
Subscription :: distinct i64

@(private)
Sub :: struct {
	id:       Subscription,
	topic:    Topic,
	index:    i64,
	callback: Change_Proc,
	user:     rawptr,
	owner:    i64, // what made it (a surface while it started, the remote client), dropped with it; 0: the caller
}

// What the subscribers were last told.
@(private)
Seen :: struct {
	transport: Transport_State,
	history:   History_State,
	undo_name: [64]u8,
	project:   Project_State,
	dir:       [256]u8,
	settings:  u64,
	mixer:     u64,
	song:      u64,
	launcher:  u64,
	selection: u64,
	key:       u64,
}

// Calls `callback` with `user` when `topic` changes (`index`: only for
// that pad, bus...; -1: all). Control thread. Unsupported for a topic
// this version doesn't report (see `TOPICS`).
subscribe :: proc(api: ^Api, topic: Topic, index: i64, callback: Change_Proc, user: rawptr) -> (Subscription, Result) {
	if callback == nil do return 0, fail(api, .Invalid_Argument, "no callback")
	if topic not_in TOPICS do return 0, failf(api, .Unsupported, "no changes reported for this topic yet")
	id := Subscription(api.next_sub)
	api.next_sub += 1
	append(&api.subs, Sub{id, topic, index, callback, user, api.owner})
	// A topic nobody watched isn't kept up: what it is now, so a change
	// after this is told.
	if topic not_in api.watched {
		now := seen_now(api, {topic})
		seen_take(&api.last, &now, topic)
		api.watched += {topic}
	}
	return id, .Ok
}

// Stops subscription `sub`. Not_Found if there is none. Control thread
// (a callback may unsubscribe itself).
unsubscribe :: proc(api: ^Api, sub: Subscription) -> Result {
	for s, k in api.subs do if s.id == sub {
		ordered_remove(&api.subs, k)
		return .Ok
	}
	return fail(api, .Not_Found, "no such subscription")
}

// Tells the subscribers what changed since the last frame.
@(private)
deliver_changes :: proc(api: ^Api) {
	// Only the topics someone subscribes to are looked at (Pads itself
	// subscribes to none: then nothing is).
	watched: bit_set[Topic]
	for s in api.subs do watched += {s.topic}
	api.watched = watched
	if watched == {} do return
	now := seen_now(api, watched) // (each topic's last is what it was when it was first subscribed to, or at the last frame)
	changed: bit_set[Topic]
	if now.transport != api.last.transport do changed += {.Transport}
	if now.history != api.last.history || now.undo_name != api.last.undo_name do changed += {.History}
	if now.project != api.last.project || now.dir != api.last.dir do changed += {.Project}
	if now.settings != api.last.settings do changed += {.Settings}
	if now.mixer != api.last.mixer do changed += {.Mixer}
	if now.song != api.last.song do changed += {.Song}
	if now.launcher != api.last.launcher do changed += {.Launcher}
	if now.selection != api.last.selection do changed += {.Selection}
	if now.key != api.last.key do changed += {.Key}
	changed &= watched
	api.last = now
	if changed == {} do return
	// (A callback may subscribe or unsubscribe: go by id over a copy.)
	subs := make([]Sub, len(api.subs), context.temp_allocator)
	copy(subs, api.subs[:])
	for s in subs do if s.topic in changed && still_subscribed(api, s.id) do s.callback(api, s.topic, -1, s.user)
}

@(private)
still_subscribed :: proc(api: ^Api, id: Subscription) -> bool {
	for s in api.subs do if s.id == id do return true
	return false
}

// Topic `t`'s part of `from` into `to`.
@(private)
seen_take :: proc(to, from: ^Seen, t: Topic) {
	#partial switch t {
	case .Transport: to.transport = from.transport
	case .History:   to.history, to.undo_name = from.history, from.undo_name
	case .Project:   to.project, to.dir = from.project, from.dir
	case .Settings:  to.settings = from.settings
	case .Mixer:     to.mixer = from.mixer
	case .Song:      to.song = from.song
	case .Launcher:  to.launcher = from.launcher
	case .Selection: to.selection = from.selection
	case .Key:       to.key = from.key
	}
}

// What `topics` are now (the others left zero).
@(private)
seen_now :: proc(api: ^Api, topics: bit_set[Topic]) -> Seen {
	s: Seen
	if .Transport in topics {
		s.transport, _ = transport_state(api)
		s.transport.beat, s.transport.timeline_beat = 0, 0 // (the playhead is polled, not reported)
		s.transport.bar, s.transport.beat_in_bar, s.transport.sixteenth = 0, 0, 0
	}
	if .History in topics {
		s.history, _ = history_state(api)
		name, _ := history_undo_name(api)
		copy(s.undo_name[:], name)
	}
	// (Not `project_state`: whether it is dirty is History's, and the
	// templates are a folder, not read every frame.)
	if .Project in topics {
		s.project = {untitled = api.core.files.untitled, recent = i64(len(api.core.files.recent))}
		copy(s.dir[:], api.core.m.project.dir)
	}
	if .Settings in topics do s.settings = api.core.registry.version
	if .Mixer in topics do s.mixer = mixer_digest(api)
	c := api.core
	p := &c.m.project
	if .Song in topics {
		h := fnv_init()
		fnv(&h, mem.any_to_bytes(p.song))
		fnv(&h, mem.any_to_bytes(p.arrangement))
		fnv(&h, mem.any_to_bytes(c.m.engine.cue))
		s.song = h
	}
	if .Launcher in topics {
		h := fnv_init()
		fnv(&h, mem.any_to_bytes(p.lanes))
		x := struct{ at: pm.Switch_At, hold, cont, rec: bool }{p.switch_at, p.launch_hold, p.launch_continue, pm.launch_recording(&c.m)}
		fnv(&h, mem.any_to_bytes(x))
		for k in 0 ..< p.lanes.count {
			cs, _, next, _, queued := pm.column_state(&c.m.engine, k)
			y := [3]int{cs, next, int(queued)}
			fnv(&h, mem.any_to_bytes(y))
		}
		s.launcher = h
	}
	if .Selection in topics {
		h := fnv_init()
		x := struct{ sel, bank: int, mode: pm.Play_Mode, keys: pm.Keys }{c.selected, c.bank, c.play_mode, c.keys}
		fnv(&h, mem.any_to_bytes(x))
		s.selection = h
	}
	if .Key in topics {
		h := fnv_init()
		x := struct{ keys: pm.Keys, prog: pm.Progression }{c.keys, c.progression}
		fnv(&h, mem.any_to_bytes(x))
		s.key = h
	}
	return s
}

// A digest of what the Mixer topic reports: the buses, and each pad's
// mix (not its sound: hashing every pad's whole patch each frame would
// cost too much).
@(private)
mixer_digest :: proc(api: ^Api) -> u64 {
	p := &api.core.m.project
	h := fnv_init()
	mix :: fnv
	mix(&h, mem.any_to_bytes(p.bus_count))
	for &b in p.buses[:p.bus_count] {
		x := struct{ v, pan: f32, mute, solo, group, folded: bool, dest: u8, cue: pm.Send }{b.volume, b.pan, b.mute, b.solo, b.group, b.folded, b.dest, b.cue}
		mix(&h, mem.any_to_bytes(x))
		mix(&h, b.name[:])
	}
	{
		m := p.main
		x := struct{ v, pan: f32, mute: bool }{m.volume, m.pan, m.mute}
		mix(&h, mem.any_to_bytes(x))
	}
	for &pad in p.pads {
		x := struct{ v, pan: f32, mute, solo: bool, bus: u8, cue: pm.Send }{pad.volume, pad.pan, pad.mute, pad.solo, pad.bus, pad.cue}
		mix(&h, mem.any_to_bytes(x))
		mix(&h, mem.slice_to_bytes(pad.sends[:]))
	}
	return h
}

@(private)
fnv_init :: proc() -> u64 {
	return 14695981039346656037
}

// FNV-1a over `data` into `h`.
@(private)
fnv :: proc(h: ^u64, data: []byte) {
	for b in data {
		h^ ~= u64(b)
		h^ *= 1099511628211
	}
}

// Drops the subscriptions tagged `owner`.
@(private)
drop_owned :: proc(api: ^Api, owner: i64) {
	if owner == 0 do return
	for k := len(api.subs) - 1; k >= 0; k -= 1 do if api.subs[k].owner == owner do ordered_remove(&api.subs, k)
}
