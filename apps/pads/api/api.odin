// The Pads API: everything Pads does, for its own UI and test scripts,
// for control-surface libraries and scripts loaded into it, and for other
// processes (see docs/guides/api.md). A proc a thing it does, named
// `module_verb_object`; each takes the `Api` and returns what it gives and
// a `Result` (`last_error` says why in words). The C ABI (`pads_api.h`,
// the same names prefixed `pads_`) and the remote methods are generated
// from these declarations by scripts/api.py.
//
// Control thread only; another thread posts calls with `api_post`.
//
//	r := pads_api.transport_set_tempo(api, 128)
//	if r != .Ok do fmt.println(pads_api.last_error(api))
//	pads_api.transport_play(api)
//	s, _ := pads_api.transport_state(api)
package pads_api

import "core:strings"
import "core:sync"

import pc "../core"

// The API's major version: a function table of this version only grows.
VERSION :: 1

// What a call came to. `last_error` says why it wasn't `Ok`.
Result :: enum i32 {
	Ok,
	Not_Found,        // what it names isn't there (nothing to undo, say)
	Invalid_Argument, // an argument out of its range
	Busy,             // not now (an undo group open, say)
	Unsupported,      // not in this version, or not for this thing
	Io_Error,         // a file couldn't be read or written
}

// The API for one app. Fields are internal.
Api :: struct {
	core:      ^pc.Core,
	error:     [256]u8,
	error_len: int,
	gesture:   bool, // a gesture is open: edits merge (history_gesture_begin)
	touched:   Param_Ref, // the parameter touched (param_touch), when `has_touch`
	has_touch: bool,
	subs:      [dynamic]Sub,
	next_sub:  i64,
	lock:      sync.Mutex, // guards `posted`
	posted:    [dynamic]Posted,
	last:      Seen, // what subscribers were last told about
	primed:    bool,
	table:     Table_V1, // the C function table (gen_c.odin)
}

// A call posted from another thread: run on the control thread at the
// next frame, with `user`.
Post_Proc :: #type proc "c" (api: ^Api, user: rawptr)

@(private)
Posted :: struct {
	call: Post_Proc,
	user: rawptr,
}

// Makes the API for the app whose state is `core`. Control thread.
api_init :: proc(api: ^Api, core: ^pc.Core) {
	api.core = core
	api.subs = make([dynamic]Sub)
	api.posted = make([dynamic]Posted)
	api.next_sub = 1
	table_fill(api)
}

// Frees what the API holds (its subscriptions go). Control thread.
api_destroy :: proc(api: ^Api) {
	delete(api.subs)
	delete(api.posted)
	api^ = {}
}

// Runs once a frame on the control thread: the app's clock goes on by
// `dt` seconds (what is due on it happens: a tap tempo's start), the
// calls posted from other threads run, and subscribers hear what changed
// since the last frame (once each, coalesced).
api_frame :: proc(api: ^Api, dt: f64) {
	pc.tick(api.core, dt)
	posted: [dynamic]Posted
	{
		sync.mutex_guard(&api.lock)
		posted, api.posted = api.posted, make([dynamic]Posted)
	}
	for p in posted do p.call(api, p.user)
	delete(posted)
	deliver_changes(api)
}

// Queues `call` to run on the control thread at the next frame, with
// `user`. Any thread. Its results come back however `user` says (the call
// writes them there, say).
api_post :: proc(api: ^Api, call: Post_Proc, user: rawptr) -> Result {
	if call == nil do return fail(api, .Invalid_Argument, "no call to post")
	sync.mutex_guard(&api.lock)
	append(&api.posted, Posted{call, user})
	return .Ok
}

// The API's version (`VERSION`).
api_version :: proc(api: ^Api) -> (i64, Result) {
	return VERSION, .Ok
}

// Why the last call that failed failed, in words (temporary: until the
// next failure). "" before any.
last_error :: proc(api: ^Api) -> (string, Result) {
	return string(api.error[:api.error_len]), .Ok
}

// Records why a call failed and returns `r`.
@(private)
fail :: proc(api: ^Api, r: Result, why: string) -> Result {
	n := copy(api.error[:], why)
	api.error_len = n
	return r
}

@(private)
failf :: proc(api: ^Api, r: Result, parts: ..string) -> Result {
	return fail(api, r, strings.concatenate(parts, context.temp_allocator))
}
