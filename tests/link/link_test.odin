package test_link

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

import "fire:core"
import "fire:link"
import "fire:rt"
import abl "fire:sys/abl_link"
import tb "fire:timebase"
import "fire:transport"

SR :: 48_000.0
BLOCK :: 480 // 10 ms

// The clock at the start of the last block, and that block's host time.
Last_Block :: struct {
	grid:    f64,
	host_ns: u64,
}

// Runs the clock in real time for `d`, as a device callback would, and
// returns the last block's start.
run_for :: proc(c: ^transport.Clock, d: time.Duration) -> (last: Last_Block) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		ctx := core.Process_Context{frames = BLOCK}
		last.host_ns = rt.host_time_ns()
		transport.process(c, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			l := (^Last_Block)(user)
			if seg.transport.host_ns == l.host_ns do l.grid = f64(seg.transport.grid)
		}, &last, last.host_ns)
		time.sleep(10 * time.Millisecond)
	}
	return
}

// The beat Link `l` gives for host time `host_ns`. Comparing at the block's own
// time keeps the check independent of how late this thread runs.
link_beat_at :: proc(l: abl.Link, state: abl.Session_State, host_ns: u64, quantum: f64) -> f64 {
	abl.capture_app_session_state(l, state)
	us := abl.clock_micros(l) + (i64(host_ns) - i64(rt.host_time_ns())) / 1000
	return abl.beat_at_time(state, us, quantum)
}

// Alone in a session: the clock's grid is Link's beat timeline, and local
// tempo changes become the session tempo.
@(test)
clock_follows_link_alone :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	c, _ := transport.create(transport.default_settings(SR))
	defer transport.destroy(c)
	l, err := link.create(120)
	testing.expect_value(t, err, core.Error.None)
	defer link.destroy(l)
	transport.set_sync(c, link.sync(l))
	transport.set_tempo(c, 97)
	probe := abl.create_session_state()
	defer abl.destroy_session_state(probe)
	// Link moves audio-thread commits to the app side on its own thread, so
	// give it time on a loaded machine.
	diff := 0.0
	ok := false
	for _ in 0 ..< 100 {
		last := run_for(c, 50 * time.Millisecond)
		diff = last.grid - link_beat_at(l.handle, probe, last.host_ns, 4)
		if link.session_tempo(l) == 97 && abs(diff) < 0.02 {
			ok = true
			break
		}
	}
	testing.expectf(t, ok, "session tempo %v (want 97); clock grid differs from Link by %v beats", link.session_tempo(l), diff)
	testing.expect_value(t, transport.status(c).tempo_bpm, 97)
	transport.set_sync(c, {})
	run_for(c, 20 * time.Millisecond)
}

// Two members of one session on this machine: a tempo change by the peer
// reaches the clock, and both agree on the beat phase.
@(test)
clock_and_peer_agree :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	c, _ := transport.create(transport.default_settings(SR))
	defer transport.destroy(c)
	l, _ := link.create(120)
	defer link.destroy(l)
	peer := abl.create(120)
	defer abl.destroy(peer)
	state := abl.create_session_state()
	defer abl.destroy_session_state(state)

	transport.set_sync(c, link.sync(l))
	link.enable(l, true)
	abl.enable(peer, true)
	found := false
	for _ in 0 ..< 100 {
		run_for(c, 50 * time.Millisecond)
		if link.peers(l) > 0 {
			found = true
			break
		}
	}
	if !found {
		log.warn("no Link peer discovered within 5 s (no multicast on this network?); skipping the two-peer checks")
		transport.set_sync(c, {})
		run_for(c, 20 * time.Millisecond)
		return
	}

	abl.capture_app_session_state(peer, state)
	abl.set_tempo(state, 141, abl.clock_micros(peer))
	abl.commit_app_session_state(peer, state)
	ok := false
	for _ in 0 ..< 100 {
		run_for(c, 50 * time.Millisecond)
		// Link sends tempo as whole microseconds per beat: 141 arrives as 140.99997.
		if abs(transport.status(c).tempo_bpm - 141) < 1e-3 {
			ok = true
			break
		}
	}
	testing.expect(t, ok, "the peer's tempo never reached the clock")
	last := run_for(c, 200 * time.Millisecond)
	phase_diff := math.mod(last.grid - link_beat_at(peer, state, last.host_ns, 4) + 2, 4) - 2
	testing.expectf(t, abs(phase_diff) < 0.02, "phase differs from the peer by %v beats", phase_diff)

	// And our tempo changes reach the peer.
	transport.set_tempo(c, 88)
	run_for(c, 100 * time.Millisecond)
	reached := false
	for _ in 0 ..< 100 {
		abl.capture_app_session_state(peer, state)
		if abs(abl.tempo(state) - 88) < 1e-3 {
			reached = true
			break
		}
		run_for(c, 50 * time.Millisecond)
	}
	testing.expect(t, reached, "our tempo never reached the peer")
	transport.set_sync(c, {})
	run_for(c, 20 * time.Millisecond)
}

// Polls the clock in real time until `cond` holds, up to `tries` × 50 ms.
run_until :: proc(c: ^transport.Clock, tries: int, cond: proc(user: rawptr) -> bool, user: rawptr) -> bool {
	for _ in 0 ..< tries {
		run_for(c, 50 * time.Millisecond)
		if cond(user) do return true
	}
	return false
}

Start_Stop_Rig :: struct {
	c:    ^transport.Clock,
	song: core.Timeline_Id,
	l:    ^link.Link,
}

song_playing :: proc(user: rawptr) -> bool {
	r := (^Start_Stop_Rig)(user)
	_, playing, _ := transport.timeline_status(r.c, r.song)
	return playing
}

song_stopped :: proc(user: rawptr) -> bool { return !song_playing(user) }

session_playing :: proc(user: rawptr) -> bool { return link.session_playing((^Start_Stop_Rig)(user).l) }

session_stopped :: proc(user: rawptr) -> bool { return !session_playing(user) }

// Sets the session's play state from outside the clock, as a peer would.
set_session_playing :: proc(l: ^link.Link, playing: bool, delay_us: i64 = 0) {
	abl.capture_app_session_state(l.handle, l.app)
	abl.set_is_playing(l.app, playing, abl.clock_micros(l.handle) + delay_us)
	abl.commit_app_session_state(l.handle, l.app)
}

// Start/stop sync alone in a session: the timeline's starts and stops become
// the session's, and the session's (another app's, here the app thread's)
// start and stop it at the time they name.
@(test)
start_stop_follows_the_session :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	r: Start_Stop_Rig
	r.c, _ = transport.create(transport.default_settings(SR))
	defer transport.destroy(r.c)
	r.song, _ = transport.add_timeline(r.c)
	r.l, _ = link.create(120)
	defer link.destroy(r.l)
	transport.set_sync(r.c, link.sync(r.l, r.song))
	link.enable_start_stop(r.l, true)
	testing.expect(t, link.is_start_stop_enabled(r.l))
	run_for(r.c, 50 * time.Millisecond)
	testing.expect(t, !link.session_playing(r.l))

	// Here → session.
	transport.play(r.c, r.song)
	testing.expect(t, run_until(r.c, 100, session_playing, &r), "a local start never reached the session")
	transport.stop(r.c, r.song)
	testing.expect(t, run_until(r.c, 100, session_stopped, &r), "a local stop never reached the session")

	// Session → here, at the time it names: a start 300 ms ahead.
	pos0, _, _ := transport.timeline_status(r.c, r.song)
	set_session_playing(r.l, true, 300_000)
	run_for(r.c, 100 * time.Millisecond)
	testing.expect(t, !song_playing(&r), "started before the session's start time")
	testing.expect(t, run_until(r.c, 100, song_playing, &r), "the session's start never started the song")
	// Started at the session's start beat: it has played the beats since.
	pos, _, _ := transport.timeline_status(r.c, r.song)
	pos -= pos0
	abl.capture_app_session_state(r.l.handle, r.l.app)
	since := abl.beat_at_time(r.l.app, abl.clock_micros(r.l.handle), 4) - abl.beat_at_time(r.l.app, abl.time_for_is_playing(r.l.app), 4)
	testing.expectf(t, abs(f64(pos) - since) < 0.1, "song at %v beats, session started %v beats ago", pos, since)
	set_session_playing(r.l, false)
	testing.expect(t, run_until(r.c, 100, song_stopped, &r), "the session's stop never stopped the song")
	// The clock's own starts and stops aren't echoed back as local ones.
	testing.expect(t, !link.session_playing(r.l))

	// Joining a session that plays: the song starts on its next quantum.
	link.enable_start_stop(r.l, false)
	run_for(r.c, 20 * time.Millisecond)
	pos0, _, _ = transport.timeline_status(r.c, r.song)
	set_session_playing(r.l, true, -1_000_000) // started a second ago
	link.enable_start_stop(r.l, true)
	testing.expect(t, run_until(r.c, 100, song_playing, &r), "joining a playing session didn't start the song")
	abl.capture_app_session_state(r.l.handle, r.l.app)
	start := abl.beat_at_time(r.l.app, abl.time_for_is_playing(r.l.app), 4)
	now := abl.beat_at_time(r.l.app, abl.clock_micros(r.l.handle), 4)
	pos, _, _ = transport.timeline_status(r.c, r.song)
	pos -= pos0
	phase := math.mod(now - start - f64(pos) + 400, 4)
	testing.expectf(t, phase < 0.1 || phase > 3.9, "song at %v is off the session's phase (%v beats since its start)", pos, now - start)

	// Off: the session no longer moves it.
	link.enable_start_stop(r.l, false)
	run_for(r.c, 20 * time.Millisecond)
	set_session_playing(r.l, false)
	run_for(r.c, 200 * time.Millisecond)
	testing.expect(t, song_playing(&r), "stopped by the session with start/stop sync off")
	transport.set_sync(r.c, {})
	run_for(r.c, 20 * time.Millisecond)
}

// Two members with start/stop sync: one's start starts the other on the same
// beat phase, and its stop stops it.
@(test)
start_stop_between_peers :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	a, b: Start_Stop_Rig
	for r in ([]^Start_Stop_Rig{&a, &b}) {
		r.c, _ = transport.create(transport.default_settings(SR))
		r.song, _ = transport.add_timeline(r.c)
		r.l, _ = link.create(120)
		transport.set_sync(r.c, link.sync(r.l, r.song))
		link.enable_start_stop(r.l, true)
		link.enable(r.l, true)
	}
	defer for r in ([]^Start_Stop_Rig{&a, &b}) {
		transport.set_sync(r.c, {})
		run_for(r.c, 20 * time.Millisecond)
		link.destroy(r.l)
		transport.destroy(r.c)
	}
	// Both clocks run on this thread, block by block.
	both :: proc(a, b: ^Start_Stop_Rig, d: time.Duration) {
		start := time.tick_now()
		for time.tick_since(start) < d {
			for r in ([]^Start_Stop_Rig{a, b}) {
				ctx := core.Process_Context{frames = BLOCK}
				transport.process(r.c, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {}, nil, rt.host_time_ns())
			}
			time.sleep(10 * time.Millisecond)
		}
	}
	found := false
	for _ in 0 ..< 100 {
		both(&a, &b, 50 * time.Millisecond)
		if link.peers(a.l) > 0 && link.peers(b.l) > 0 {
			found = true
			break
		}
	}
	if !found {
		log.warn("no Link peer discovered within 5 s (no multicast on this network?); skipping")
		return
	}
	transport.play(a.c, a.song, tb.Quantize.Bar)
	started := false
	for _ in 0 ..< 200 {
		both(&a, &b, 50 * time.Millisecond)
		if song_playing(&a) && song_playing(&b) {
			started = true
			break
		}
	}
	if !testing.expect(t, started, "a's start never started b") do return
	both(&a, &b, 200 * time.Millisecond)
	pa, _, _ := transport.timeline_status(a.c, a.song)
	pb, _, _ := transport.timeline_status(b.c, b.song)
	testing.expectf(t, abs(f64(pa - pb)) < 0.05, "a at %v beats, b at %v", pa, pb)

	transport.stop(b.c, b.song)
	stopped := false
	for _ in 0 ..< 200 {
		both(&a, &b, 50 * time.Millisecond)
		if !song_playing(&a) && !song_playing(&b) {
			stopped = true
			break
		}
	}
	testing.expect(t, stopped, "b's stop never stopped a")
}
