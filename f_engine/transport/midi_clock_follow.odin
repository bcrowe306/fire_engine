package transport

import "core:math"

import "fire:core"
import tb "fire:timebase"

// Follows an outside MIDI clock: its tempo (from the 24 ticks per quarter
// note, smoothed), its position (Song Position Pointer, then counted
// ticks), and its Start, Continue and Stop for one timeline. Give the clock
// `midi_clock_follow_sync` of it; `events` must point at the MIDI that came
// in during the block the clock runs (the app host's `host_block_midi`).
// Audio-thread state; read `bpm` and `running` from any thread (torn
// reads are harmless: they are for display).
Midi_Clock_Follower :: struct {
	events:   ^[]core.Event, // the block's incoming MIDI
	bpm:      f64,  // the tempo heard (0: no clock yet)
	running:  bool, // between a Start (or Continue) and a Stop
	// Audio thread.
	ticks:    i64,  // ticks since the top (24 a beat)
	last:     f64,  // the reference frame of the last tick
	interval: f64,  // frames per tick, smoothed (0: none yet)
	heard:    int,  // ticks heard since the clock started (it takes a few to know the tempo)
	pending:  Start_Stop,
}

// A `Sync` that makes the clock follow `f`, starting and stopping
// `timeline` with the outside clock's Start and Stop.
midi_clock_follow_sync :: proc(f: ^Midi_Clock_Follower, timeline: core.Timeline_Id = {}) -> Sync {
	return {begin_block = midi_clock_follow_block, user = f, timeline = timeline}
}

// [rt]
@(private)
midi_clock_follow_block :: proc(user: rawptr, b: ^Sync_Block) {
	f := (^Midi_Clock_Follower)(user)
	if f.events != nil do for e in f.events^ {
		m, ok := e.payload.(core.Midi_Raw)
		if !ok do continue
		at := f64(b.frame) + f64(e.offset)
		switch m.bytes[0] {
		case MIDI_CLOCK:
			if f.heard > 0 {
				d := at - f.last
				// A gap (the clock stopped and came back): not an interval.
				if d > 0 && (f.interval == 0 || d < f.interval * 4) {
					f.interval = d if f.interval == 0 else f.interval + (d - f.interval) * 0.08
				}
			}
			f.last = at
			f.heard += 1
			if f.running do f.ticks += 1
		case MIDI_START:
			f.ticks, f.running = 0, true
			f.pending = .Start
		case MIDI_CONTINUE:
			f.running = true
			f.pending = .Start
		case MIDI_STOP:
			f.running = false
			f.pending = .Stop
		case MIDI_SONG_POSITION:
			f.ticks = i64(int(m.bytes[1]) | int(m.bytes[2]) << 7) * 6 // sixteenths
		}
	}
	if f.interval <= 0 || f.heard < 3 do return
	f.bpm = b.sample_rate * 60 / (f.interval * 24)
	b.ok = true
	b.bpm = f.bpm
	// Where it is at the block's first frame: the last tick, and how far
	// past it (at the tempo heard, never past the next tick).
	since := clamp((f64(b.frame) - f.last) / f.interval, 0, 1)
	b.beat = tb.Beats((f64(f.ticks) + (since if f.running else 0)) / 24)
	if f.pending != .None {
		b.start_stop = f.pending
		b.start_stop_at = tb.Beats(math.floor(f64(f.ticks) / 24 * 4 + 1e-9) / 4) // where it was (a sixteenth)
		f.pending = .None
	}
}
