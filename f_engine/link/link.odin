/*
Ableton Link: tempo and beat-phase sync with other apps and devices on the
local network.

Optional, and under a different licence: Link is GPLv2+ unless you hold
Ableton's commercial licence, and so is any app that links this package.
Nothing else in Fire Engine depends on it. Build the library first with
`scripts/link.sh` (it fetches a pinned Link release into third_party/).

A `Link` follows the session through the clock's sync hook: the clock takes
the session tempo, and its grid is the session's beat timeline, so bar lines
agree with peers when the quantum is the bar length. Local tempo changes
(`transport.set_tempo`, or a leader's tempo map) are pushed to the session.

	l, _ := link.create(120, quantum = 4)
	defer link.destroy(l)
	transport.set_sync(clock, link.sync(l))
	link.enable(l, true)

	// Launch quantized as usual; peers see the same downbeats.
	transport.play(clock, clip, tb.Quantize.Bar)

With start/stop sync on (`enable_start_stop`), the session also carries
play and stop. Name the timeline to follow in `sync`: starting or stopping it
here (`transport.play`, `transport.stop`) starts or stops peers at the same
beat, and their starts and stops start and stop it. Joining a session that
already plays starts it on the session's next quantum.

	transport.set_sync(clock, link.sync(l, song))
	link.enable_start_stop(l, true)
	transport.play(clock, song, tb.Quantize.Bar) // peers start on that bar too

Pass the device's presentation time to `transport.process` (its `host_ns`
argument) so the beat lines up with what peers hear.
*/
package link

import "core:math"
import "core:mem"

import "fire:core"
import "fire:rt"
import abl "fire:sys/abl_link"
import tb "fire:timebase"
import "fire:transport"

// A Link session member. Create with `create`. Fields are internal.
Link :: struct {
	handle:    abl.Link,
	audio:     abl.Session_State, // audio thread only
	app:       abl.Session_State, // control thread only
	quantum:   f64,
	allocator: mem.Allocator,
	// Audio thread.
	last_bpm:  f64, // tempo returned to the clock last block; 0 before the first
	filter:    Host_Time_Filter,
	following: bool, // start/stop sync was on last block
	playing:   bool, // the session's play state as last seen
	toggles:   u64,  // `Sync_Block.toggles` as last seen
}

// Control thread. Creates a Link instance, not yet enabled (see `enable`),
// with a starting tempo (used while alone in a session) and a `quantum` in
// beats: the phase length peers agree on, normally one bar. Free with
// `destroy`.
create :: proc(bpm: f64 = 120, quantum: f64 = 4, allocator := context.allocator) -> (l: ^Link, err: core.Error) {
	if !(bpm >= transport.MIN_BPM && bpm <= transport.MAX_BPM) || !(quantum > 0) do return nil, .Invalid_Argument
	l = new(Link, allocator)
	if l == nil do return nil, .Out_Of_Memory
	l.allocator, l.quantum = allocator, quantum
	l.handle = abl.create(bpm)
	l.audio = abl.create_session_state()
	l.app = abl.create_session_state()
	if l.handle.impl == nil || l.audio.impl == nil || l.app.impl == nil {
		destroy(l)
		return nil, .Out_Of_Memory
	}
	return l, .None
}

// Control thread. Leaves the session and frees `l`. Detach it from the clock
// first (`transport.set_sync(clock, {})`) and let a block pass, so the audio
// thread no longer uses it.
destroy :: proc(l: ^Link) {
	if l == nil do return
	if l.handle.impl != nil {
		abl.enable(l.handle, false)
		abl.destroy(l.handle)
	}
	if l.audio.impl != nil do abl.destroy_session_state(l.audio)
	if l.app.impl != nil do abl.destroy_session_state(l.app)
	free(l, l.allocator)
}

// Control thread. Joins (true) or leaves (false) the network session.
// Disabled, Link still keeps time on its own.
enable :: proc(l: ^Link, on: bool) {
	abl.enable(l.handle, on)
}

// Any thread. Whether `l` is joined to the network session.
is_enabled :: proc(l: ^Link) -> bool {
	return abl.is_enabled(l.handle)
}

// Any thread. How many other apps share the session.
peers :: proc(l: ^Link) -> int {
	return int(abl.num_peers(l.handle))
}

// Control thread. The session tempo now, as the network sees it.
session_tempo :: proc(l: ^Link) -> f64 {
	abl.capture_app_session_state(l.handle, l.app)
	return abl.tempo(l.app)
}

// Any thread. Turns start/stop sync on or off: whether the session's play
// state starts and stops the timeline named in `sync`, and its starts and
// stops reach the session. Peers share play state only among those with it on.
enable_start_stop :: proc(l: ^Link, on: bool) {
	abl.enable_start_stop_sync(l.handle, on)
}

// Any thread. Whether start/stop sync is on.
is_start_stop_enabled :: proc(l: ^Link) -> bool {
	return abl.is_start_stop_sync_enabled(l.handle)
}

// Control thread. Whether the session is playing, as the network sees it.
session_playing :: proc(l: ^Link) -> bool {
	abl.capture_app_session_state(l.handle, l.app)
	return abl.is_playing(l.app)
}

// The hook to pass to `transport.set_sync`; with start/stop sync, `timeline`
// is the one the session starts and stops. `l` must outlive its use.
sync :: proc(l: ^Link, timeline: core.Timeline_Id = {}) -> transport.Sync {
	return {begin_block = begin_block, user = l, timeline = timeline}
}

// [rt] Reports local tempo changes to the session, then gives the clock the
// session's tempo and its beat at the block's first frame.
@(private)
begin_block :: proc(user: rawptr, b: ^transport.Sync_Block) {
	l := (^Link)(user)
	host_ns := b.host_ns if b.host_ns != 0 else rt.host_time_ns()
	host_ns = filter_add(&l.filter, i64(b.frame), host_ns)
	// Link has its own clock; map ours onto it (both monotonic, same rate).
	link_us := abl.clock_micros(l.handle) + (i64(host_ns) - i64(rt.host_time_ns())) / 1000

	abl.capture_audio_session_state(l.handle, l.audio)
	commit := false
	local_change := l.last_bpm != 0 && abs(b.desired_bpm - l.last_bpm) > 1e-6
	alone_at_start := l.last_bpm == 0 && abl.num_peers(l.handle) == 0
	if local_change || alone_at_start {
		abl.set_tempo(l.audio, b.desired_bpm, link_us)
		commit = true
	}
	b.bpm = abl.tempo(l.audio)
	b.beat = tb.Beats(abl.beat_at_time(l.audio, link_us, l.quantum))
	b.ok = true
	l.last_bpm = b.bpm
	if start_stop(l, b) do commit = true
	if commit do abl.commit_audio_session_state(l.handle, l.audio)
}

// [rt] Start/stop sync, after `begin_block` set the block's beat: passes a
// local start or stop to the session, or the session's to the clock. True
// when the session state needs committing.
@(private)
start_stop :: proc(l: ^Link, b: ^transport.Sync_Block) -> (commit: bool) {
	if !abl.is_start_stop_sync_enabled(l.handle) {
		l.following = false
		return false
	}
	session := abl.is_playing(l.audio)
	q := tb.Beats(l.quantum)
	if !l.following {
		// Joining: take the session's state from its next quantum.
		l.following, l.playing, l.toggles = true, session, b.toggles
		if session && !b.playing {
			start := tb.Beats(abl.beat_at_time(l.audio, abl.time_for_is_playing(l.audio), l.quantum))
			b.start_stop, b.start_stop_at = .Start, next_in_phase(start, b.beat, q)
		}
		return false
	}
	if b.toggles != l.toggles {
		// Started or stopped here: tell the session when, on its timeline.
		l.toggles = b.toggles
		if b.playing != session {
			abl.set_is_playing(l.audio, b.playing, abl.time_at_beat(l.audio, f64(b.toggled_at), l.quantum))
			l.playing = b.playing
			return true
		}
		l.playing = session
		return false
	}
	if session != l.playing {
		// A peer started or stopped the session.
		l.playing = session
		if session == b.playing do return false
		at := tb.Beats(abl.beat_at_time(l.audio, abl.time_for_is_playing(l.audio), l.quantum))
		// Long past (a missed start): wait for its phase instead of jumping.
		if at < b.beat - q do at = next_in_phase(at, b.beat, q) if session else b.beat
		b.start_stop, b.start_stop_at = .Start if session else .Stop, at
	}
	return false
}

// The first beat at or after `from` in phase with `beat` (modulo `q`).
@(private)
next_in_phase :: proc "contextless" (beat, from, q: tb.Beats) -> tb.Beats {
	n := tb.Beats(math.ceil(f64((from - beat) / q)))
	return beat + max(n, 0) * q
}
