/*
Ableton Link for Pads: built in (`task app:pads LINK=1`). Link is GPLv2+, so
a Pads built this way is too. The clock follows the session (its tempo and
beat grid, the bar as quantum); start/stop sync starts and stops the
sequencer with the session.
*/
package padslink

import fc "fire:core"
import "fire:link"
import "fire:transport"

// Whether Link is built into this Pads.
AVAILABLE :: true

// Link's state: the session while joined.
State :: struct {
	on: bool,
	l:  ^link.Link,
}

// Joins a Link session at `bpm`, a bar of `quantum` beats; the clock
// follows it and starts and stops `timeline` with it. False if Link
// can't start.
start :: proc(s: ^State, clock: ^transport.Clock, timeline: fc.Timeline_Id, bpm, quantum: f64) -> bool {
	if s.on do return true
	l, err := link.create(bpm, quantum)
	if err != .None do return false
	s.l, s.on = l, true
	transport.set_sync(clock, link.sync(l, timeline))
	link.enable(l, true)
	return true
}

// Leaves the session; the clock carries on at the session's tempo.
stop :: proc(s: ^State, clock: ^transport.Clock) {
	if !s.on do return
	transport.set_sync(clock, {})
	link.enable(s.l, false)
	link.destroy(s.l)
	s^ = {}
}

// Shares starts and stops with the session too (or not).
set_start_stop :: proc(s: ^State, on: bool) {
	if s.on do link.enable_start_stop(s.l, on)
}

// How many other apps are in the session.
peers :: proc(s: ^State) -> int {
	return link.peers(s.l) if s.on else 0
}
