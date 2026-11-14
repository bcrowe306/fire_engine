package pads_api

// What a subscriber hears about. Topics whose module isn't built yet
// answer `subscribe` with `Unsupported`.
Topic :: enum i32 {
	Transport, // playing, tempo, loop, time signature, count-in, metronome, pattern/song (not the playhead: poll it)
	History,   // undo and redo steps, saved or not
	Selection,
	Pad,
	Mixer,
	Sequence,
	Song,
	Launcher,
	Project,
	Settings,
	Recording,
	Ui,
}

// The topics this version reports.
TOPICS :: bit_set[Topic]{.Transport, .History}

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
	return s
}
