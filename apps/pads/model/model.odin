/*
Pads' model, without its GUI: the project (64 pads in 4 banks, the samples
they play), the commands that change it, and what keeps the engine in step
with it. The GUI (apps/pads) draws this; tests drive it headless.

Every change goes through `app.History` (see edit.odin), so it can be
undone, and marks what it touched dirty; `sync` (engine.odin) then brings
the engine's graph up to date.
*/
package pads_model

import "core:strings"

import app "app:core"
import fc "fire:core"
import "fire:sampler"

// Pads in a bank, and banks.
PADS_PER_BANK :: 16
// Banks of pads (A to D).
BANKS :: 4
// Every pad.
PADS :: PADS_PER_BANK * BANKS
// Choke groups a pad can join (1 to CHOKE_GROUPS; 0 = none).
CHOKE_GROUPS :: 6
// Slice points a chopped pad can hold.
MAX_SLICES :: 32

// How a pad plays its sample.
Pad_Mode :: enum u8 {
	One_Shot, // to the end, whatever the release
	Gate,     // while held
	Loop,     // loops while held
	Hold,     // loops until hit again (or choked)
}

// One pad. A plain value (no pointers), so a whole pad can be copied,
// stored in an undo step and restored.
Pad :: struct {
	name:       [32]u8,
	color:      u32, // 0xRRGGBB
	sample:     app.Id, // 0 = empty
	// Region of the sample, in its frames (end 0 = to the end).
	start, end: i64,
	mode:       Pad_Mode,
	loop_start, loop_end: i64, // 0 and 0 = the region
	loop_mode:  sampler.Loop_Mode,
	crossfade:  i64,
	reverse:    bool,
	attack:     f32, // seconds
	release:    f32, // seconds
	pitch:      f32, // semitones
	volume:     f32, // dB
	pan:        f32, // -1..1
	choke:      u8,  // 0 = none, 1..CHOKE_GROUPS
	eq:         [3]f32, // low, mid, high: dB
	bus:        u8,  // 0 = main (buses come with the mixer)
	// Slices (from chopping), as frame positions; the pad plays slice 0,
	// keys play the others (the chopper).
	slices:     [MAX_SLICES]i64,
	slice_count: int,
}

// A sample the project holds: a file in its folder.
Sample :: struct {
	name:     string, // the file name (interned: never freed while the project lives)
	path:     string, // absolute
	frames:   i64,
	rate:     f64,
	channels: int,
}

// A project.
Project :: struct {
	ids:     app.Ids,
	bpm:     f64,
	pads:    [PADS]Pad,
	samples: app.Store(Sample),
	sequences: [SLOTS]Sequence,
	slot:    int, // the current sequence: what plays and is edited
	dir:     string, // the project folder (samples/ inside it)
	strings: strings.Intern, // sample names and paths
}

// The default pad: one-shot, full volume, centred.
default_pad :: proc() -> Pad {
	return {mode = .One_Shot, attack = 0.001, release = 0.05, color = 0x58a6ff}
}

// Prepares an empty project in `dir`.
project_init :: proc(p: ^Project, dir: string) {
	p.bpm = 120
	for &pad in p.pads do pad = default_pad()
	for &s in p.sequences do s = default_sequence()
	app.store_init(&p.samples)
	strings.intern_init(&p.strings)
	p.dir = intern(p, dir)
}

// Frees the project.
project_destroy :: proc(p: ^Project) {
	for &s in p.sequences do delete_sequence(&s)
	app.store_destroy(&p.samples)
	strings.intern_destroy(&p.strings)
}

// A string kept for the project's lifetime.
intern :: proc(p: ^Project, s: string) -> string {
	x, _ := strings.intern_get(&p.strings, s)
	return x
}

// A pad's name.
pad_name :: proc(pad: ^Pad) -> string {
	return strings.truncate_to_byte(string(pad.name[:]), 0)
}

// Sets a pad's name (cut to fit).
set_pad_name :: proc(pad: ^Pad, name: string) {
	pad.name = {}
	copy(pad.name[:len(pad.name) - 1], name)
}

// "A1".."D16": a pad's label.
pad_label :: proc(index: int, allocator := context.temp_allocator) -> string {
	letters := "ABCD"
	return strings.concatenate({letters[index / PADS_PER_BANK:][:1], itoa(index % PADS_PER_BANK + 1, allocator)}, allocator)
}

// The MIDI key pad `index` answers in the engine.
PAD_KEY_BASE :: 36
// The key of pad `index`.
pad_key :: proc "contextless" (index: int) -> u8 {
	return u8(PAD_KEY_BASE + index)
}

@(private)
itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf := make([]u8, 8, allocator)
	i := len(buf)
	v := n
	if v == 0 {
		buf[i - 1] = '0'
		return string(buf[i - 1:])
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return string(buf[i:])
}

@(private)
_ :: fc.Error
