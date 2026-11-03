package test_link

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

import "fire:core"
import "fire:link"
import "fire:rt"
import abl "fire:sys/abl_link"
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
