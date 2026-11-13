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
import "fire:dsp"
import "fire:sampler"
import "fire:stretch"

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
	Sampler, // plays its sample (its region), pitched by key
	Audio,   // records its input into clips and plays them
	Slicer,  // its sample sliced in place, a slice on each key from its base note
	Synth,   // a wavetable synth (see `Synth_Patch`)
	Plugin,  // a CLAP instrument (`Pad.instrument`)
}

// Slices a slicer can have.
MAX_SLICER_SLICES :: 64

// One slice of a slicer: where it starts (it ends where the next does, or
// at the region's end), and its own level, pitch, pan and direction.
Slice :: struct {
	start:   i64, // in the sample's frames
	gain_db: f32,
	pitch:   f32, // semitones
	pan:     f32, // -1..1
	reverse: bool,
}

// How a slicer was last sliced (what Re-slice does again).
Slice_By :: enum u8 {
	Transients, // at the hits (`sensitivity`)
	Beats,      // on a grid of its own tempo (`grain`)
	Equal,      // into `parts` equal slices
	Manual,     // by hand
}

// A slicer: its sample sliced in place (the pad's region, split at each
// slice's start), slice k playing on key `base` + k. Mono: a slice cuts the
// one before off; thru: a slice plays on past its end to the region's end;
// gate: a slice stops when its key is let go (else it plays to its end).
// Every slice fades in and out by `fade_in_ms` and `fade_out_ms`.
Slicer :: struct {
	slices:      [MAX_SLICER_SLICES]Slice,
	count:       int,
	base:        u8, // the key of slice 1 (C3 = 60)
	mono:        bool,
	thru:        bool,
	gate:        bool,
	fade_in_ms:  f32,
	fade_out_ms: f32,
	by:          Slice_By,
	sensitivity: f32, // .Transients: 0..1
	grain:       stretch.Warp_Grain, // .Beats: 1/4, 1/8, 1/16 (Transients: a bar)
	parts:       int, // .Equal
}

// A new slicer's settings (no slices yet).
default_slicer :: proc() -> Slicer {
	return {base = 60, fade_in_ms = 0.5, fade_out_ms = 3, sensitivity = 0.5, grain = .Sixteenth, parts = 16}
}

// What an audio pad records: the interface's channels, or (resampling)
// another track, a bus or main, as they sound after their faders, lined
// up after their effects' latency.
Audio_Input :: struct {
	channel: u8,   // .Interface: its first input channel (0: input 1)
	stereo:  bool, // .Interface: it and the next (1/2, 3/4...); else it alone, on both sides
	from:    Input_From,
	source:  u8,   // .Pad: the pad; .Bus: the bus (0 = bus 1)
}

// Where an audio pad's input comes from.
Input_From :: enum u8 {
	Interface, // the device's input channels
	Pad,       // another track's output (after its fader)
	Bus,       // a bus's output
	Main,      // main's output (everything heard, but the click)
	None,      // nothing: it records and monitors nothing (and doesn't follow the interface)
}

// Where a track's MIDI comes from.
Midi_In_Mode :: enum u8 {
	All,  // any port: the drum map (note N plays the pad the map gives it)
	None, // no MIDI plays it
	Port, // `Midi_In.port` (and channel): played chromatically, while armed
}

// A track's MIDI input.
Midi_In :: struct {
	mode:    Midi_In_Mode,
	port:    string, // .Port: the port's id (interned)
	channel: u8,     // 0 = any; 1..16
}

// An audio pad's take in one sequence: a file one sequence long (at the
// tempo it was recorded at), looping with the sequence and following the
// tempo.
Clip :: struct {
	sample: app.Id, // 0 = none; with a part, its latest take
	bpm:    f64,
	part:   app.Id, // its regions and takes (`Project.parts`; 0: its sample whole, see `Audio_Part`)
}

// The sampler's voice beyond its amp's attack and release: the rest of
// its amp envelope, its filter, its pitch envelope, two LFOs and their
// routes, and how many notes it plays at once. A plain value (part of a Pad).
Voice :: struct {
	decay, sustain: f32, // the amp envelope's (seconds; 0..1)
	velocity: f32, // velocity sensitivity, 0..1 (0: all as loud; 0.5: in proportion; more: steeper)
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
	mode:     sampler.Voice_Mode, // poly, mono (each note anew), legato (notes over held ones slide)
	glide:    f32,  // seconds: mono and legato notes slide from the last one
	glide_always:  bool, // every mono note glides (not only those over a held one)
	glide_octaves: bool, // a glide's time is an octave's (leaps take longer)
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
	v.velocity = 0.4
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
	eq_on:      bool,   // its EQ is in (off: flat, whatever its bands are)
	bus:        u8,  // 0 = main (buses come with the mixer)
	// Slices (from chopping), as frame positions; the pad plays slice 0,
	// keys play the others (the chopper).
	slices:     [MAX_SLICES]i64,
	slice_count: int,
	midi_out:   Midi_Out, // its hits also go out as MIDI
	midi_fx:    Perform,  // its MIDI effects: note repeat or the arpeggiator on its live notes
	midi_in:    Midi_In,  // what MIDI plays it
	inserts:    [PAD_INSERTS]Effect_Slot, // after its EQ
	mute, solo: bool,
	sends:      [BUSES]Send, // to the buses, besides its output
	kind:       Pad_Kind,
	input:      Audio_Input, // an audio pad's
	monitor:    Monitor,     // its input heard: an audio track's while armed, any other's while sampled into (Auto), always (In), never (Off: a new pad's, so a microphone near the speakers doesn't feed back)
	voice:      Voice,       // a sampler pad's voice (envelopes, filter, pitch, LFOs)
	warp:       Warp,        // following the tempo (see `Warp`)
	slicer:     Slicer,      // a slicer's slices and settings (kept when it is a sampler again)
	synth:      Synth_Patch, // a synth's sound (kept when it is something else again)
	instrument: Effect_Slot, // a plug-in pad's CLAP instrument (kind .Plugin; kept likewise)
	plugin_lanes: [PLUGIN_LANES]Plugin_Lane, // what each Plugin_N lane moves
	frozen:     bool, // it plays its renderings (`Project.freezes`) instead of its device and inserts
	cue:        Send, // its send to the cue mix (a performer's headphones)
}

// A sample the project holds: a file in its folder.
Sample :: struct {
	name:     string, // the file name (interned: never freed while the project lives)
	path:     string, // absolute
	frames:   i64,
	rate:     f64,
	channels: int,
}

// Whether an audio track plays its input through its strip (software
// monitoring, through its effects): while it is armed (Auto), always (In),
// or never (Off: you hear it on the interface).
Monitor :: enum u8 {
	Auto,
	In,
	Off,
}

// How the app was left with a project (written by the app, saved with
// the project, put back when it opens): how the pads play, the bank and
// pad selected, the sequence pads' bank.
View_State :: struct {
	play_mode: Play_Mode,
	keys:      Keys,
	bank:      int,
	selected:  int,
	seq_bank:  int, // (before v37: the sequence pads' bank; now `seq_row0 / 4`)
	seq_lane0, seq_row0: int, // the launcher's window: its first lane and row
	seq_keys:  bool, // the pad keys play the sequence pads
	seq_mode:  Seq_Mode, // the Sequence view's tab: Notes or Automation
}

// The Sequence view's tabs: notes (and their velocity, chance and CC), one
// automation at a time, or an audio track's part.
Seq_Mode :: enum u8 {
	Notes,
	Automation,
	Audio, // the selected audio track's part, large (see the app's Audio tab)
}

// A project.
Project :: struct {
	ids:     app.Ids,
	bpm:     f64,
	pads:    [PADS]Pad,
	samples: app.Store(Sample),
	wave_docs: app.Store(Wave_Doc), // the project's own wavetables (the wavetable editor's)
	launch_hold: bool, // sequence pads play while held (back to the one before when let go), else launch
	launch_continue: bool, // a launched sequence carries on where the playhead is (its column's pass so far, modulo its length), else from its top
	view:    View_State, // how the app was left: kept with the project, so it opens as it was
	sequences: [SLOTS]Sequence,
	lanes:   Lanes, // the launcher's lanes and each sequence's place in them
	clips:   [SLOTS][PADS]Clip, // audio pads' takes, per sequence
	parts:   app.Store(Audio_Part), // their edits (see `Audio_Part`; only those a clip names are saved)
	freezes: [SLOTS][PADS]Clip, // frozen pads' renderings, per sequence (see `freeze_begin`)
	slot:    int, // the current sequence: what plays and is edited
	midi_map: [128]i16, // MIDI key → the pad it plays (-1: none); default: key N plays pad N (A1 = 0, H16 = 127)
	perform: Perform, // files before v31: note repeat and the arpeggiator for every pad (read into each pad's `midi_fx`)
	buses:   [BUSES]Bus, // the first `bus_count` are in use
	bus_count: int,
	main:    Bus,
	perf_fx: [PERF_FX]Effect_Slot, // the performance effects (on while held)
	perf_intensity: [PERF_FX]f32, // how hard each plays (0..1) unless its press says
	song:    Song, // the current arrangement's (kept in `arrangements` too when switching or saving)
	arrangements: [ARRANGEMENTS]Arrangement,
	arrangement_count: int, // 1..ARRANGEMENTS
	arrangement: int,       // the current one
	transport: Transport, // loop, count-in, the metronome, the time signature, input quantize
	song_mode: bool, // play the song, not the current sequence
	switch_at: Switch_At, // when a sequence picked while playing takes over
	dir:     string, // the project folder (see project_paths.odin)
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
	click:     dsp.Click_Sound, // the metronome's sound
	no_accent: bool, // the bar's first beat clicks as the others
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
	return {mode = .One_Shot, attack = 0.001, release = 0.05, color = 0x58a6ff, voice = default_voice(), input = {channel = 0, stereo = true}, monitor = .Off, slicer = default_slicer(), midi_fx = DEFAULT_MIDI_FX}
}

// A pad's MIDI effects to start with: both off, at 1/16, half a step long.
DEFAULT_MIDI_FX :: Perform{arp = {rate = .Sixteenth, gate = 0.5, octaves = 1}, repeat = {rate = .Sixteenth, gate = 0.5}}

// Prepares an empty project in `dir`.
project_init :: proc(p: ^Project, dir: string) {
	p^ = {}
	p.bpm = 120
	p.transport = default_transport()
	for &pad in p.pads do pad = default_pad()
	for &s in p.sequences do s = default_sequence()
	p.lanes = default_lanes(DEFAULT_LANES)
	p.perf_fx = default_perf_fx()
	p.bus_count = DEFAULT_BUSES
	p.arrangement_count = 1
	copy(p.arrangements[0].name[:], "Song")
	for &x in p.perf_intensity do x = 1
	p.perform = DEFAULT_MIDI_FX
	for &k, key in p.midi_map do k = i16(key) if key < PADS else -1 // note N plays pad N (A1 = 0)
	app.store_init(&p.samples)
	app.store_init(&p.wave_docs)
	app.store_init(&p.parts)
	strings.intern_init(&p.strings)
	p.dir = intern(p, dir)
}

// Frees the project.
project_destroy :: proc(p: ^Project) {
	for &s in p.sequences do delete_sequence(&s)
	app.store_destroy(&p.samples)
	app.store_destroy(&p.wave_docs)
	app.store_destroy(&p.parts)
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
	return pad.sample != 0 || pad.kind == .Audio || pad.kind == .Slicer || pad.kind == .Synth || pad.kind == .Plugin
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
