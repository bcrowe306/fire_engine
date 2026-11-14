package pads_api

import "core:mem"

import pm "../model"

// What a subscriber hears about. Topics whose module isn't built yet
// answer `subscribe` with `Unsupported`.
Topic :: enum i32 {
	Transport, // playing, tempo, loop, time signature, count-in, metronome, pattern/song (not the playhead: poll it)
	History,   // undo and redo steps, saved or not
	Selection,
	Pad,
	Mixer,     // buses (added, routed, levels, mute, solo, groups), the pads' levels, pans, mutes, solos, sends, outputs (not the meters: poll them)
	Sequence,
	Song,
	Launcher,
	Project,   // another project open, saved somewhere, renamed; the recent list
	Settings,  // any setting
	Recording,
	Ui,
}

// The topics this version reports.
TOPICS :: bit_set[Topic]{.Transport, .History, .Mixer, .Project, .Settings}

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
}

// Calls `callback` with `user` when `topic` changes (`index`: only for
// that pad, bus...; -1: all). Control thread. Unsupported for a topic
// this version doesn't report (see `TOPICS`).
subscribe :: proc(api: ^Api, topic: Topic, index: i64, callback: Change_Proc, user: rawptr) -> (Subscription, Result) {
	if callback == nil do return 0, fail(api, .Invalid_Argument, "no callback")
	if topic not_in TOPICS do return 0, failf(api, .Unsupported, "no changes reported for this topic yet")
	id := Subscription(api.next_sub)
	api.next_sub += 1
	append(&api.subs, Sub{id, topic, index, callback, user})
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
	now := seen_now(api)
	if !api.primed {
		api.last, api.primed = now, true
		return
	}
	changed: bit_set[Topic]
	if now.transport != api.last.transport do changed += {.Transport}
	if now.history != api.last.history || now.undo_name != api.last.undo_name do changed += {.History}
	if now.project != api.last.project || now.dir != api.last.dir do changed += {.Project}
	if now.settings != api.last.settings do changed += {.Settings}
	if now.mixer != api.last.mixer do changed += {.Mixer}
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

@(private)
seen_now :: proc(api: ^Api) -> Seen {
	s: Seen
	s.transport, _ = transport_state(api)
	s.transport.beat, s.transport.timeline_beat = 0, 0 // (the playhead is polled, not reported)
	s.transport.bar, s.transport.beat_in_bar, s.transport.sixteenth = 0, 0, 0
	s.history, _ = history_state(api)
	name, _ := history_undo_name(api)
	copy(s.undo_name[:], name)
	// (Not `project_state`: whether it is dirty is History's, and the
	// templates are a folder, not read every frame.)
	s.project = {untitled = api.core.files.untitled, recent = i64(len(api.core.files.recent))}
	copy(s.dir[:], api.core.m.project.dir)
	s.settings = api.core.registry.version
	s.mixer = mixer_digest(api)
	return s
}

// A digest of what the Mixer topic reports: the buses, and each pad's
// mix (not its sound: hashing every pad's whole patch each frame would
// cost too much).
@(private)
mixer_digest :: proc(api: ^Api) -> u64 {
	p := &api.core.m.project
	h: u64 = 14695981039346656037
	mix :: proc(h: ^u64, data: []byte) {
		for b in data {
			h^ ~= u64(b)
			h^ *= 1099511628211
		}
	}
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
