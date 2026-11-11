/*
Ableton Link for Pads: not in this build, because its library wasn't built
(`./scripts/link.sh`, which `task deps` runs) or LINK=0 asked to leave it
out. With the library there, `task app:pads` uses the package in ../on.
*/
package padslink

import fc "fire:core"
import "fire:transport"

// Whether Link is built into this Pads.
AVAILABLE :: false

// Link's state (nothing, here).
State :: struct {
	on: bool,
}

// Joins a Link session at `bpm` (never, here: false).
start :: proc(s: ^State, clock: ^transport.Clock, timeline: fc.Timeline_Id, bpm, quantum: f64) -> bool { return false }

// Leaves the session.
stop :: proc(s: ^State, clock: ^transport.Clock) {}

// Shares starts and stops with the session too (or not).
set_start_stop :: proc(s: ^State, on: bool) {}

// How many other apps are in the session.
peers :: proc(s: ^State) -> int { return 0 }
