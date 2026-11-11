/*
Ableton Link for Pads: not built in. Link is GPLv2+; Pads (MIT) leaves it
out unless it is built with `task app:pads LINK=1` (after
`./scripts/link.sh`), which uses the package in ../on instead of this one.
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
