/*
Pads' model, without its GUI: the project (128 pads in 8 banks, the samples
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
// Banks of pads (A to H).
BANKS :: 8
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

// What a pad is: a sampler (it plays its sample when hit), or an audio
// track (it records takes from an input and plays them with the sequence).
Pad_Kind :: enum u8 {
	Sampler,
	Audio,
}

// The inputs an audio pad records.
Audio_Input :: enum u8 {
	Stereo_1_2, // inputs 1 and 2
	Mono_1,     // input 1, on both sides
	Mono_2,
}

// An audio pad's take in one sequence: a file one sequence long (at the
// tempo it was recorded at), looping with the sequence and following the
// tempo.
Clip :: struct {
	sample: app.Id, // 0 = none
	bpm:    f64,
}

// The sampler's voice beyond its amp's attack and release: the rest of
// its amp envelope, its filter, its pitch envelope, two LFOs and their
// routes, and how many notes it plays at once. A plain value (part of a Pad).
Voice :: struct {
	decay, sustain: f32, // the amp envelope's (seconds; 0..1)
	filter:   sampler.Voice_Filter,
	steep:    bool, // 24 dB (else 12)
	cutoff:   f32,  // Hz
	resonance: f32, // 0..1
	key_track: f32, // 0..1: the cutoff follows the key
	vel_cutoff: f32, // -1..1
	filter_env: f32, // -1..1 (±6 octaves)
	filter_adsr: [4]f32, // attack, decay (s), sustain (0..1), release (s)
	pitch_env: f32, // semitones
	pitch_adsr: [4]f32,
	vel_pitch: f32, // semitones at full velocity
	pitch_track: f32, // 0..1: keys transpose (1 = a semitone a key)
	fine:     f32, // cents
	lfos:     [sampler.LFOS]Lfo,
	routes:   [sampler.MOD_ROUTES]Route,
	voices:   int, // notes at once (1..32)
}

// One LFO's settings.
Lfo :: struct {
	shape: sampler.Lfo_Shape,
	mode:  sampler.Lfo_Mode,
	rate:  f32, // Hz (Auto, Trigger)
	sync:  u8,  // index into sampler.LFO_SYNC_BEATS (Sync)
	fade:  f32, // seconds
	phase: f32, // degrees
}

// A modulation route: `source` moves `dest` by `amount` (-1..1).
Route :: struct {
	source: sampler.Mod_Source,
	dest:   sampler.Mod_Dest,
	amount: f32,
}

// The voice a pad starts with: a full amp sustain, the filter open and off,
// no pitch envelope, LFOs at 2 Hz going nowhere (routes 1-3 from LFO 1, 4-6
// from LFO 2), 8 notes.
default_voice :: proc() -> (v: Voice) {
	v.decay, v.sustain = 1, 1
	v.cutoff = 20_000
	v.filter_adsr = {0.001, 0.5, 0, 0.2}
	v.pitch_adsr = {0.001, 0.3, 0, 0.2}
	v.pitch_track = 1
	for &l in v.lfos do l = {rate = 2, sync = 4}
	for &r, i in v.routes do r.source = .Lfo_1 if i < sampler.MOD_ROUTES / 2 else .Lfo_2
	v.voices = 8
	return
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
	fade_in:    i64, // frames of the region faded in from its start (0 = none)
	fade_out:   i64, // frames faded out before its end (0 = none; not while it loops)
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
	midi_out:   Midi_Out, // its hits also go out as MIDI
	inserts:    [PAD_INSERTS]Effect_Slot, // after its EQ
	mute, solo: bool,
	sends:      [BUSES]Send, // to the buses, besides its output
	kind:       Pad_Kind,
	input:      Audio_Input, // an audio pad's
	monitor:    bool,        // an armed audio pad plays its input through its strip
	voice:      Voice,       // a sampler pad's voice (envelopes, filter, pitch, LFOs)
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
	clips:   [SLOTS][PADS]Clip, // audio pads' takes, per sequence
	slot:    int, // the current sequence: what plays and is edited
	midi_map: [128]i16, // MIDI key → the pad it plays (-1: none); default: key N plays pad N (A1 = 0, H16 = 127)
	perform: Perform, // the arpeggiator and note repeat (`set_perform`)
	buses:   [BUSES]Bus,
	main:    Bus,
	perf_fx: [PERF_FX]Effect_Slot, // the performance effects (on while held)
	perf_intensity: [PERF_FX]f32, // how hard each plays (0..1) unless its press says
	song:    Song,
	transport: Transport, // loop, count-in, the metronome, the time signature, input quantize
	song_mode: bool, // play the song, not the current sequence
	switch_at: Switch_At, // when a sequence picked while playing takes over
	dir:     string, // the project folder (samples/ inside it)
	strings: strings.Intern, // sample names and paths
}

// A time signature: `num` beats of 1/`den` notes a bar (4/4, 3/4, 6/8).
Time_Sig :: struct {
	num: int, // 1..16
	den: int, // 2, 4, 8 or 16
}

// Recorded notes moved toward a grid as they are played.
Input_Quantize :: struct {
	on:       bool,
	grid:     Grid,
	strength: f32, // 0..1: how far a note moves toward the grid (1: onto it)
	swing:    f32, // 0..1: the grid's off-beats pushed later (as a sequence's swing)
}

// The transport's settings, saved with the project.
Transport :: struct {
	loop:      bool, // a sequence (or the song) loops; off, it plays once and stops
	count_in:  int,  // bars of click before recording starts (0..2)
	metro_db:  f32,  // the metronome's level
	metro_rec_only: bool, // it clicks only while recording (and counting in)
	time_sig:  Time_Sig,
	quantize:  Input_Quantize,
}

// The transport settings a project starts with.
default_transport :: proc() -> Transport {
	return {loop = true, count_in = 0, metro_db = -6, time_sig = {4, 4}, quantize = {grid = .Sixteenth, strength = 1}}
}

// The default pad: one-shot, full volume, centred.
default_pad :: proc() -> Pad {
	return {mode = .One_Shot, attack = 0.001, release = 0.05, color = 0x58a6ff, voice = default_voice()}
}

// Prepares an empty project in `dir`.
project_init :: proc(p: ^Project, dir: string) {
	p^ = {}
	p.bpm = 120
	p.transport = default_transport()
	for &pad in p.pads do pad = default_pad()
	for &s in p.sequences do s = default_sequence()
	p.perf_fx = default_perf_fx()
	for &x in p.perf_intensity do x = 1
	p.perform = {arp = {rate = .Sixteenth, gate = 0.5, octaves = 1}, repeat = {rate = .Sixteenth, gate = 0.5}}
	for &k, key in p.midi_map do k = i16(key) if key < PADS else -1 // note N plays pad N (A1 = 0)
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

// Whether pad `index` makes sound: a sampler with a sample, or an audio
// pad.
pad_used :: proc(p: ^Project, index: int) -> bool {
	pad := &p.pads[index]
	return pad.sample != 0 || pad.kind == .Audio
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

// "A1".."H16": a pad's label.
pad_label :: proc(index: int, allocator := context.temp_allocator) -> string {
	letters := "ABCDEFGH"
	return strings.concatenate({letters[index / PADS_PER_BANK:][:1], itoa(index % PADS_PER_BANK + 1, allocator)}, allocator)
}

// The note pad `index` is (and, in the engine, the key its sampler answers
// to): A1 is 0, H16 is 127.
pad_key :: proc "contextless" (index: int) -> u8 {
	return u8(clamp(index, 0, 127))
}

// "C-2 · 0": a pad's note, as its face shows it.
pad_note_name :: proc(index: int) -> string {
	names := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
	k := int(pad_key(index))
	return strings.concatenate({names[k % 12], itoa(k / 12 - 2) if k / 12 >= 2 else strings.concatenate({"-", itoa(2 - k / 12)}, context.temp_allocator), " · ", itoa(k)}, context.temp_allocator)
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
