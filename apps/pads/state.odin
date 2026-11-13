package pads

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import "fire:backend"
import "fire:fx"
import "fire:synth"

// What a test harness sees of the app (`state`, a drive command): the
// pads, the sequencer, the mixer, the browser and the preview, the
// project, the messages showing. Plain values, as JSON.
State :: struct {
	selected:   int,
	bank:       int,
	keyboard:   [16]string, // Keyboard mode: the note each pad of the grid plays ("": none)
	wavetable:  State_Wavetable, // the wavetable editor (when open on a table of the project's)
	play_mode:  string,
	detail_tab: string, // the sampler's tab in front, or "EQ", or "Effect"
	track:      string, // what the bottom panel shows: "pad 1", "bus 1" (5: main), "perf 1"
	dark:       bool,
	folded:         bool,   // the pads area folded to a bar
	library:        bool,   // the Library shown
	control_h:      f32,    // a control's height in points (the control size)
	playing:    bool,
	beat:       f64,
	slot:       int,
	bpm:        f64,
	metronome:  bool,
	loop:       bool,
	count_in:   int,
	time_sig:   string, // "3/4"
	metro_db:   f32,
	metro_click: int, // the metronome's sound (0 beep .. 3 cowbell)
	metro_rec_only: bool,
	quantize:   struct { on: bool, grid: string, strength, swing: f32 },
	timeline:   f64, // the playhead on the timeline (negative counting in)
	position:   string, // as the toolbar shows it: bar.beat.sixteenth
	recording:  bool,
	version:    string, // Pads' version ("0.1.0-dev")
	audio_inputs, audio_outputs: [dynamic]int, // the interface's channels open (1-based)
	audio_missing_inputs, audio_missing_outputs: [dynamic]int, // asked for, not on it
	song_mode:  bool,
	song_clips: int,
	song:       [dynamic]int, // each clip's sequence (1-based)
	clips:      [dynamic]State_Clip, // each clip's settings
	song_clip:  int, // the clip leading where it plays (1-based; 0: none)
	song_lanes: [dynamic]State_Lane, // the lanes shown
	meters:     [dynamic][3]f64, // the time signature lane: beat, numerator, denominator
	song_zoom:  f64, // the Song view's points a beat
	song_scroll: f64, // the beat at its left edge
	song_tool:  string, // "Select" or "Draw"
	pads_folded: bool, // the bottom area is folded
	song_beat:  f64, // where in the song (beats)
	song_seconds: f64, // how long the song plays
	tempo_points: [dynamic][3]f64, // the song's tempo lane: beat, BPM, 1 if it ramps
	markers:    [dynamic]string, // the song's markers, in order
	marker_beats: [dynamic]f64,
	song_loop:  [2]f64, // its loop range (beats; 0, 0: none)
	cue:        f64, // where song mode starts
	song_selected: int, // the clip whose settings show (1-based; 0: none)
	song_sel:   [dynamic]int, // the selected clips (1-based)
	arrangements: [dynamic]string,
	arrangement: int, // 1-based
	snap:       bool, // the sequence editor snaps to its grid
	curved:     int, // automation points of the current sequence bending the line after them
	repeat_all: bool,   // the toolbar's note repeat is on
	seq_mode:   string, // the Sequence view's tab: "Notes", "Automation" or "Audio"
	audio:      State_Audio_View, // the Audio tab's selection
	chances:    []f32,  // each note's chance (0..1) in the current sequence
	ccs:        int,    // MIDI CC steps in the current sequence
	auto_lane:  string, // the automation the Automation tab shows ("A1 Volume")
	notes:      int, // in the current sequence
	note_list:  [dynamic]State_Note, // its notes (in order)
	muted_notes: int,
	launch:     string, // when a sequence picked while playing takes over: Now, Beat, Bar, End
	launch_hold: bool,  // sequence pads play while held
	seq_bank:   int,    // the launcher's window's row / 4 (an older project's bank)
	window:     [2]int, // the launcher's window: its first lane and row (1-based)
	lanes:      []string, // the launcher's lanes' names
	seq_lanes:  []int,    // each sequence's lane and row: lane * 100 + row (both 1-based)
	silences:   int,    // times Stop silenced every voice
	theme:      string, // the theme in use
	zoom:       f32,
	settings_open: bool,
	sample_method: string, // the Sample control's: Hold, Arm, Threshold, Bars
	sample_armed:  bool,
	sampling:      int, // the pad a sample is recording into (-1: none)
	clock_out:  bool,   // MIDI clock goes out
	sync:       string, // what the tempo follows: Internal, Midi_Clock, Link
	plugins:    int,    // plug-ins found
	plugin_effects: [dynamic]string, // the effects among them (names)
	pad_sel:    [dynamic]int, // the pads selected together (0-based)
	points:     int,
	bars:       int,
	undo:       string, // the next undo step's name
	dirty:      bool,
	project:    string,
	exporting:  bool,
	sequences:  [dynamic]State_Sequence, // the ones in use
	marked:     bool, // notes are selected in the sequence editor
	selected_notes: int,
	tool:       string, // the editor's tool: Select, Draw, Erase, Move
	piano_roll: bool,   // the editor shows one pad's piano roll
	perf_on:    [pm.PERF_FX]bool, // the performance effects held (or latched)
	perf_now:   [pm.PERF_FX]f32,  // how hard each plays while held (-1: its own)
	perf_intensity: [pm.PERF_FX]f32, // each one's own
	queued:     int, // the sequence about to take over (1-based; 0: none)
	columns:    []int, // what each launcher lane plays (1-based; 0: nothing), a lane each
	launch_record: bool, // Record to Song is armed
	launch_continue: bool, // launches carry on where the playhead is
	main_volume: f32, // main's fader (dB)
	mixer_view: Mixer_View, // the Mixer's sections shown, narrow or wide
	loudness:   [4]f32, // main's momentary, short-term, integrated (LUFS) and true peak (dBTP)
	correlation: f32,    // main's phase correlation
	fx_params:  [dynamic][2]f32, // the effect being edited: its settings, (id, value) each
	pads:       [dynamic]State_Pad, // the ones with a sound
	buses:      [dynamic]State_Bus, // those in use (A...), then main
	browser:    State_Browser,
	toasts:     []string,
	errors:     int, // drive lines that failed so far
}

// A synth pad's patch, for tests: its routes, the parameters off their
// defaults (by name, curved values), its wavetables, its LFO shapes'
// point counts, the voices sounding.
State_Synth :: struct {
	routes:  [dynamic]State_Route,
	params:  map[string]f32,
	tables:  [synth.OSCS]string,
	points:  [synth.LFOS]int,
	voices:  int,
	effects: [len(fx.Effect)]string, // in their order
	preset:  string,
}

State_Route :: struct {
	source, dest: string,
	amount:       f32,
	bipolar:      bool,
}

// The wavetable editor's table: its name, keyframes (each its frame and
// source), the chosen one and its harmonics' levels.
State_Wavetable :: struct {
	open:      bool,
	name:      string,
	blend:     string,
	positions: []int,
	sources:   []string,
	key:       int,
	levels:    []f32,
}

// A slicer pad's slices (each start, level, pitch) and how they play.
State_Slicer :: struct {
	starts:   []i64,
	gains:    []f32, // dB
	pitches:  []f32,
	base:     int,
	mono, gate, thru: bool,
	by:       string,
	selected: int, // the slice whose settings show
}

State_Pad :: struct {
	index:   int,
	label:   string,
	name:    string,
	color:   u32,
	mode:    string,
	volume:  f32,
	pan:     f32,
	pitch:   f32,
	bus:     int,
	mute:    bool,
	solo:    bool,
	sends:   []f32, // dB (-60: off), to each bus in use
	choke:   int,    // its choke group (0: none)
	warp:    string, // its warp's mode, or "" when off
	eq_on:   bool,   // its EQ is in
	midi_out: bool,  // its MIDI out is on
	repeat:  bool,   // its note repeat is on
	arp:     bool,   // its arpeggiator is on
	warp_bpm: f64,   // its sample's tempo (warp)
	warp_ready: bool, // its warp rendered and playing
	inserts: [pm.PAD_INSERTS]string,
	slices:  int,
	level:   f32, // the meter's peak now
	start, end: i64, // its region (end resolved)
	fade_in, fade_out: i64,
	playhead: i64, // the frame it plays now (-1: silent)
	kind:    string, // "Sampler", "Slicer" or "Audio"
	slicer:  State_Slicer, // a slicer's slices
	synth:   State_Synth,  // a synth's patch
	input:   string,
	monitor: string, // Auto, In, Off
	armed:   bool,
	midi_in: string, // what MIDI plays it: "All MIDI", "No MIDI", a port's name
	midi_in_notes: u32, // MIDI notes that have played it
	take:    i64, // an audio pad's take in the current sequence: its frames (0: none; with a part, the sequence's)
	loop:    f64, // its own loop in the current sequence, beats (0: none)
	regions: int, // its part's regions in the current sequence
	takes:   int, // ... and takes
	attack, release: f32,
	voice:   pm.Voice, // its envelopes, filter, pitch, LFOs and routes
	cutoff_now: f64, // the filter's cutoff as it plays now (modulated, automated)
}

// The Audio tab's selection.
State_Audio_View :: struct {
	region:   int, // -1: none
	range:    [2]f64,
	cursor:   f64,
	has_clip: bool, // something copied
}

State_Sequence :: struct {
	slot:  int, // 1-based
	name:  string,
	bpm:   f64, // its own (0: the project's)
	bars:  int,
	notes: int,
	color: u32, // shown (its own or its slot's)
}

State_Note :: struct {
	start: f64,
	pad:   int,
	pitch: int,
	muted: bool,
}

State_Clip :: struct {
	slot:      int, // 1-based
	lane:      int, // 1-based
	at:        f64,
	length:    f64,
	start:     f64, // its part's start in the sequence
	part:      f64, // beats a pass plays
	phase:     f64,
	mute:      bool,
	transpose: int,
	label:     string,
}

State_Lane :: struct {
	name: string,
	mute: bool,
	solo: bool,
}

State_Bus :: struct {
	name:   string,
	volume: f32,
	pan:    f32,
	mute:   bool,
	solo:   bool,
	slots:  [pm.BUS_SLOTS]string,
	dest:   string, // where it goes ("Main", another bus)
}

State_Browser :: struct {
	root:       string,
	tab:        int,
	favorites:  []string,
	rows:       []string, // as shown (indented by two spaces a level)
	selected:   string,
	searching:  string,
	results:    []string,
	search_done: bool,
	previewing: bool,
	preview:    string,
	auto_play:  bool,
	sync:       bool,
	volume:     f32,
	beats:      f64,
}

// The app's state as JSON (temporary allocator).
state_json :: proc(a: ^App) -> string {
	m := &a.m
	p := &m.project
	s: State
	s.selected, s.bank = a.selected, a.bank
	if a.play_mode == .Keyboard {
		for k in 0 ..< pm.PADS_PER_BANK {
			ps: [4]int
			notes := keyboard_notes(a, k, &ps)
			s.keyboard[k] = fmt.tprintf("%s", ui.note_name(60 + notes[0])) if keyboard_in_range(notes) else ""
		}
	}
	if a.wte.open && a.wte.pad >= 0 && a.wte.pad < pm.PADS {
		src := p.pads[a.wte.pad].synth.tables[a.wte.osc]
		if d := app.store_get(&p.wave_docs, src.table); d != nil {
			w := &s.wavetable
			w.open, w.name, w.blend, w.key = true, pm.wave_doc_name(m, src.table), enum_name(d.doc.blend), a.wte.key
			w.positions = make([]int, d.doc.count, context.temp_allocator)
			w.sources = make([]string, d.doc.count, context.temp_allocator)
			for k in 0 ..< d.doc.count do w.positions[k], w.sources[k] = d.doc.keys[k].position, enum_name(d.doc.keys[k].source)
			kk := clamp(a.wte.key, 0, d.doc.count - 1)
			w.levels = make([]f32, synth.TABLE_HARMONICS, context.temp_allocator)
			copy(w.levels, d.doc.keys[kk].levels[:])
		}
	}
	s.play_mode = enum_name(a.play_mode)
	switch a.detail.device.kind {
	case .Instrument: s.detail_tab = enum_name(a.detail.tab)
	case .Eq:         s.detail_tab = "EQ"
	case .Slot:       s.detail_tab = "Effect"
	case .Midi:       s.detail_tab = "MIDI"
	}
	s.track = fmt.tprintf("%s %d", strings.to_lower(enum_name(a.detail.track.kind), context.temp_allocator), a.detail.track.index + 1)
	s.dark = a.dark
	s.folded, s.library = a.ws.bottom_folded, a.ws.left_shown
	s.control_h = ui.DENSITY_HEIGHT[a.platform.density]
	s.beat, s.playing = pm.position(&m.engine)
	s.slot, s.bpm, s.metronome = p.slot + 1, p.bpm, m.engine.metronome
	s.recording = a.capture.armed
	tr := p.transport
	s.loop, s.count_in, s.metro_db, s.metro_rec_only = tr.loop, tr.count_in, tr.metro_db, tr.metro_rec_only
	s.metro_click = int(tr.click)
	s.time_sig = fmt.tprintf("%d/%d", tr.time_sig.num, tr.time_sig.den)
	s.quantize = {tr.quantize.on, string(pm.GRID_NAMES[tr.quantize.grid]), tr.quantize.strength, tr.quantize.swing}
	tl, _ := pm.timeline_beat(&m.engine)
	s.timeline = tl
	bar, bt, six := pm.position_of(p, tl if tl < 0 else s.beat)
	s.position = fmt.tprintf("%d.%d.%d", bar, bt, six)
	s.version = PADS_VERSION
	ones :: proc(m: backend.Channel_Mask) -> [dynamic]int {
		out := make([dynamic]int, context.temp_allocator)
		for c in m do append(&out, c + 1)
		return out
	}
	s.audio_inputs, s.audio_outputs = ones(a.host.open_inputs), ones(a.host.open_outputs)
	s.audio_missing_inputs, s.audio_missing_outputs = ones(a.host.missing_inputs), ones(a.host.missing_outputs)
	s.song_mode, s.song_clips = p.song_mode, p.song.count
	s.song = make([dynamic]int, context.temp_allocator)
	for c in p.song.clips[:p.song.count] do append(&s.song, int(c.slot) + 1)
	s.clips = make([dynamic]State_Clip, context.temp_allocator)
	for &c in p.song.clips[:p.song.count] {
		append(&s.clips, State_Clip{int(c.slot) + 1, int(c.lane) + 1, c.at, c.length, c.start, pm.clip_period(p, c), c.phase, c.mute, int(c.transpose), strings.clone(pm.clip_label(&c), context.temp_allocator)})
	}
	s.song_lanes = make([dynamic]State_Lane, context.temp_allocator)
	for i in 0 ..< pm.song_lanes(&p.song) {
		l := p.song.lanes[i]
		append(&s.song_lanes, State_Lane{strings.clone(pm.lane_name(&p.song, i), context.temp_allocator), l.mute, l.solo})
	}
	s.meters = make([dynamic][3]f64, context.temp_allocator)
	for mt in p.song.meters[:p.song.meter_count] do append(&s.meters, [3]f64{mt.beat, f64(mt.sig.num), f64(mt.sig.den)})
	s.song_zoom, s.song_scroll = f64(a.song_ui.ppb), a.song_ui.scroll
	s.song_tool = "Draw" if a.song_ui.tool == .Draw else "Select"
	s.pads_folded = a.ws.bottom_folded
	{
		clip, _, beat := pm.song_progress(&m.engine)
		s.song_clip, s.song_beat = clip + 1, beat
	}
	s.song_seconds = pm.song_seconds(p)
	s.tempo_points = make([dynamic][3]f64, context.temp_allocator)
	for pt in p.song.tempo[:p.song.tempo_count] do append(&s.tempo_points, [3]f64{pt.beat, pt.bpm, 1 if pt.ramp else 0})
	s.markers = make([dynamic]string, context.temp_allocator)
	s.marker_beats = make([dynamic]f64, context.temp_allocator)
	for &mk in p.song.markers[:p.song.marker_count] {
		append(&s.markers, strings.clone(pm.marker_name(&mk), context.temp_allocator))
		append(&s.marker_beats, mk.beat)
	}
	if p.song.loop_on do s.song_loop = {p.song.loop_start, p.song.loop_end}
	s.cue = m.engine.cue
	s.song_selected = a.song_ui.cur + 1 if a.song_ui.cur < p.song.count else 0
	s.song_sel = make([dynamic]int, context.temp_allocator)
	for k in 0 ..< p.song.count do if k in a.song_ui.sel do append(&s.song_sel, k + 1)
	s.arrangements = make([dynamic]string, context.temp_allocator)
	for k in 0 ..< p.arrangement_count do append(&s.arrangements, strings.clone(pm.arrangement_name(p, k), context.temp_allocator))
	s.arrangement = p.arrangement + 1
	s.snap = !a.seq.free
	seq := pm.current_sequence(m)
	s.notes, s.points, s.bars = len(seq.notes), len(seq.points), seq.bars
	for pt in seq.points do if pt.curve != 0 do s.curved += 1
	s.seq_mode = enum_name(a.seq.mode)
	s.repeat_all = a.m.engine.repeat_all
	s.audio = {region = a.seq.aud.region, range = a.seq.aud.range, cursor = a.seq.aud.cursor, has_clip = a.seq.aud.has_clip}
	s.chances = make([]f32, len(seq.notes), context.temp_allocator)
	s.ccs = len(seq.ccs)
	for n, k in seq.notes do s.chances[k] = n.probability
	s.auto_lane = lane_name(a, current_lane(a))
	s.note_list = make([dynamic]State_Note, context.temp_allocator)
	for n in seq.notes {
		append(&s.note_list, State_Note{start = n.start, pad = int(n.pad), pitch = int(n.pitch), muted = n.muted})
		if n.muted do s.muted_notes += 1
	}
	s.launch = enum_name(p.switch_at)
	s.launch_hold, s.seq_bank = p.launch_hold, a.perf.win_row / 4
	s.window = {a.perf.win_lane + 1, a.perf.win_row + 1}
	s.lanes = make([]string, p.lanes.count, context.temp_allocator)
	for k in 0 ..< p.lanes.count do s.lanes[k] = strings.clone(pm.launch_lane_name(p, k), context.temp_allocator)
	s.seq_lanes = make([]int, pm.SLOTS, context.temp_allocator)
	for x, k in p.lanes.place do s.seq_lanes[k] = (int(x.lane) + 1) * 100 + int(x.row) + 1
	s.columns = make([]int, p.lanes.count, context.temp_allocator)
	for k in 0 ..< p.lanes.count {
		cs, _, _, _, _ := pm.column_state(&m.engine, k)
		s.columns[k] = cs + 1
	}
	s.launch_record = pm.launch_recording(m)
	s.launch_continue = p.launch_continue
	s.main_volume = p.main.volume
	s.mixer_view = a.settings.mixer_view
	{
		mo, st, it, tp := pm.main_loudness(&m.engine)
		s.loudness = {mo, st, it, f32(20 * math.log10(max(f64(tp), 1e-9)))}
		s.correlation, _ = pm.main_stereo(&m.engine, nil)
	}
	s.silences = a.transport.silences
	s.theme, s.zoom, s.settings_open = a.settings.theme.name, a.settings.zoom, a.settings.open
	s.sample_method, s.sample_armed, s.sampling = enum_name(a.settings.sample_method), a.sample_armed, a.rec.pad if a.rec.active else -1
	s.clock_out, s.sync = a.settings.clock_out, enum_name(a.settings.sync) // (the setting: with no output port open nothing is sent)
	s.plugins = len(a.plugins.entries)
	s.plugin_effects = make([dynamic]string, context.temp_allocator)
	for e in plugin_effects(a) do append(&s.plugin_effects, e.name)
	s.pad_sel = make([dynamic]int, context.temp_allocator)
	for i in 0 ..< pm.PADS do if i in selected_pads(a) do append(&s.pad_sel, i)
	s.undo = app.undo_name(&m.history)
	s.dirty = pm.model_dirty(m)
	s.project = p.dir
	s.exporting = a.proj.exporting
	s.sequences = make([dynamic]State_Sequence, context.temp_allocator)
	for sq, k in p.sequences do if pm.slot_used(m, k) || k == p.slot {
		append(&s.sequences, State_Sequence{slot = k + 1, name = pm.sequence_name(p, k), bpm = sq.bpm, bars = sq.bars, notes = len(sq.notes), color = pm.sequence_color(p, k)})
	}
	s.marked = len(a.seq.sel) > 0
	s.selected_notes = len(a.seq.sel)
	s.tool = enum_name(a.seq.tool)
	s.piano_roll = a.seq.piano
	s.fx_params = make([dynamic][2]f32, context.temp_allocator)
	if fx, ok := pm.target_slot(m, a.fx); ok do for prm in fx.params[:fx.count] do append(&s.fx_params, [2]f32{f32(prm.id), prm.value})
	for fx, k in p.perf_fx do s.perf_on[k] = fx.on
	s.perf_now, s.perf_intensity = m.engine.perf_live, p.perf_intensity
	if q, _, ok := pm.pending_switch(&m.engine); ok do s.queued = q + 1
	s.pads = make([dynamic]State_Pad, context.temp_allocator)
	for &pad, i in p.pads do if pm.pad_used(p, i) {
		sp := State_Pad{index = i, label = pm.pad_label(i), name = pm.pad_name(&pad), mode = enum_name(pad.mode),
			volume = pad.volume, pan = pad.pan, pitch = pad.pitch, bus = int(pad.bus), mute = pad.mute, solo = pad.solo,
			slices = pad.slice_count}
		sp.choke = int(pad.choke)
		if pad.warp.on do sp.warp = enum_name(pad.warp.mode)
		sp.repeat, sp.arp = pad.midi_fx.repeat_on, pad.midi_fx.arp_on
		sp.eq_on, sp.midi_out = pad.eq_on, pad.midi_out.on
		sp.warp_bpm, sp.warp_ready = pad.warp.bpm, pad.warp.on && !pm.warp_rendering(&m.engine, i)
		sp.sends = make([]f32, p.bus_count, context.temp_allocator)
		for x, k in pad.sends[:p.bus_count] do sp.sends[k] = pm.send_db(x)
		for x, k in pad.inserts do sp.inserts[k] = pm.slot_name(x)
		v := a.mixer.pads[i]
		sp.level = max(v[0].peak, v[1].peak)
		sp.start, sp.end = pm.pad_region(m, i)
		sp.fade_in, sp.fade_out = pad.fade_in, pad.fade_out
		f, ok := pm.pad_playhead(&m.engine, i)
		sp.playhead = f if ok else -1
		sp.kind, sp.input, sp.monitor, sp.armed = enum_name(pad.kind), audio_in_text(a, i), enum_name(pad.monitor), pm.track_armed(m, i)
		sp.midi_in = midi_in_text(a, i)
		if pad.kind == .Synth {
			sy := &pad.synth
			x := State_Synth{routes = make([dynamic]State_Route, context.temp_allocator), params = make(map[string]f32, allocator = context.temp_allocator)}
			for r in sy.routes[:sy.route_count] {
				spec := synth.param_spec(r.dest)
				append(&x.routes, State_Route{source = mod_name(a, r.source), dest = spec.name if spec != nil else "?", amount = r.amount, bipolar = r.bipolar})
			}
			for &spec in synth.PARAMS do if sy.values[spec.id] != spec.default do x.params[spec.name] = synth.param_curve(&spec, sy.values[spec.id])
			for k in 0 ..< synth.OSCS do x.tables[k] = pm.synth_source_name(m, sy.tables[k])
			for e, k in sy.fx_order do x.effects[k] = synth.EFFECT_NAMES[e]
			x.preset = pm.synth_preset_name(m, i)
			for k in 0 ..< synth.LFOS do x.points[k] = sy.shapes[k].count
			if live, sounding := pm.synth_live(&m.engine, i); sounding do x.voices = int(live.voices)
			sp.synth = x
		}
		if pad.kind == .Slicer {
			sl := pad.slicer
			x := State_Slicer{base = int(sl.base), mono = sl.mono, gate = sl.gate, thru = sl.thru, by = enum_name(sl.by), selected = a.slicer_ui.selected}
			x.starts = make([]i64, sl.count, context.temp_allocator)
			x.gains = make([]f32, sl.count, context.temp_allocator)
			x.pitches = make([]f32, sl.count, context.temp_allocator)
			for s, k in sl.slices[:sl.count] do x.starts[k], x.gains[k], x.pitches[k] = s.start, s.gain_db, s.pitch
			sp.slicer = x
		}
		sp.midi_in_notes, _ = pm.midi_activity(&m.engine, i)
		sp.attack, sp.release, sp.voice = pad.attack, pad.release, pad.voice
		sp.color = pad.color
		if l, live := pm.pad_live(&m.engine, i); live do sp.cutoff_now = l.cutoff
		if c := app.store_get(&p.samples, pm.current_clip(m, i).sample); c != nil do sp.take = c.frames
		if x := pm.track_beats(p, p.sequences[p.slot], i); x < pm.seq_beats(p, p.sequences[p.slot]) - 1e-9 do sp.loop = x
		if pm.current_clip(m, i).part != 0 {
			x := pm.part_of(p, p.slot, i)
			sp.regions, sp.takes = x.count, x.take_count
			if x.count > 0 && x.take_count > 0 do sp.take = i64(math.round(pm.seq_beats(p, p.sequences[p.slot]) * pm.frames_per_beat_of(p, p.slot, i, x.takes[0])))
		} else if sp.take > 0 {
			sp.regions, sp.takes = 1, 1
		}
		append(&s.pads, sp)
	}
	s.buses = make([dynamic]State_Bus, context.temp_allocator)
	for b in 0 ..= pm.BUSES do if b < p.bus_count || b == pm.BUSES {
		bus := pm.bus_of(m, b)^
		sb := State_Bus{name = pm.bus_index_name(p, b), volume = bus.volume, pan = bus.pan, mute = bus.mute, solo = bus.solo, dest = pm.bus_name(p, int(bus.dest)) if b < pm.BUSES else ""}
		for x, k in bus.slots do sb.slots[k] = pm.slot_name(x)
		append(&s.buses, sb)
	}
	br := &a.browser
	s.browser.root, s.browser.tab, s.browser.selected = br.root, br.tab, br.selected
	favs := make([]string, len(br.favorites), context.temp_allocator)
	for f, i in br.favorites do favs[i] = f.name
	s.browser.favorites = favs
	rows := pm.browser_rows(br)
	names := make([]string, len(rows), context.temp_allocator)
	for r, i in rows {
		pad := make([]u8, r.depth * 2, context.temp_allocator)
		for &c in pad do c = ' '
		names[i] = string(pad) if r.depth > 0 else ""
		names[i] = concat(names[i], r.name)
	}
	s.browser.rows = names
	s.browser.searching = br.search.query
	res := pm.search_results(&br.search)
	rn := make([]string, len(res), context.temp_allocator)
	for r, i in res do rn[i] = r.name
	s.browser.results = rn
	s.browser.search_done = pm.search_done(&br.search) || br.search.query == ""
	pv := &m.engine.preview
	s.browser.previewing = pm.preview_playing(&m.engine)
	s.browser.preview = pv.path
	s.browser.auto_play, s.browser.sync, s.browser.volume, s.browser.beats = pv.auto_play, pv.sync, pv.volume, pv.beats
	texts, _ := ui.toast_texts(&a.ws.toasts)
	s.toasts = texts
	s.errors = a.driver.errors
	data, err := json.marshal(s, {pretty = false}, context.temp_allocator)
	if err != nil do return "{}"
	return string(data)
}

@(private)
concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(private)
enum_name :: proc(v: $T) -> string {
	return fmt.tprint(v)
}
