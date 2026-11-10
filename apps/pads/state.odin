package pads

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"

// What a test harness sees of the app (`state`, a drive command): the
// pads, the sequencer, the mixer, the browser and the preview, the
// project, the messages showing. Plain values, as JSON.
State :: struct {
	selected:   int,
	bank:       int,
	play_mode:  string,
	detail_tab: string, // the sampler's tab in front, or "EQ", or "Effect"
	track:      string, // what the bottom panel shows: "pad 1", "bus 1" (5: main), "perf 1"
	dark:       bool,
	playing:    bool,
	beat:       f64,
	slot:       int,
	bpm:        f64,
	metronome:  bool,
	loop:       bool,
	count_in:   int,
	time_sig:   string, // "3/4"
	metro_db:   f32,
	metro_rec_only: bool,
	quantize:   struct { on: bool, grid: string, strength, swing: f32 },
	timeline:   f64, // the playhead on the timeline (negative counting in)
	position:   string, // as the toolbar shows it: bar.beat.sixteenth
	recording:  bool,
	song_mode:  bool,
	song_steps: int,
	song:       [dynamic]int, // each step's sequence (1-based)
	notes:      int, // in the current sequence
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
	fx_params:  [dynamic][2]f32, // the effect being edited: its settings, (id, value) each
	pads:       [dynamic]State_Pad, // the ones with a sound
	buses:      [pm.BUSES + 1]State_Bus, // A..D, then main
	browser:    State_Browser,
	toasts:     []string,
	errors:     int, // drive lines that failed so far
}

State_Pad :: struct {
	index:   int,
	label:   string,
	name:    string,
	mode:    string,
	volume:  f32,
	pan:     f32,
	pitch:   f32,
	bus:     int,
	mute:    bool,
	solo:    bool,
	sends:   [pm.BUSES]f32, // dB (-60: off)
	inserts: [pm.PAD_INSERTS]string,
	slices:  int,
	level:   f32, // the meter's peak now
	start, end: i64, // its region (end resolved)
	fade_in, fade_out: i64,
	playhead: i64, // the frame it plays now (-1: silent)
	kind:    string, // "Sampler" or "Audio"
	input:   string,
	monitor: bool,
	armed:   bool,
	take:    i64, // an audio pad's take in the current sequence: its frames (0: none)
	attack, release: f32,
	voice:   pm.Voice, // its envelopes, filter, pitch, LFOs and routes
	cutoff_now: f64, // the filter's cutoff as it plays now (modulated, automated)
}

State_Sequence :: struct {
	slot:  int, // 1-based
	name:  string,
	bpm:   f64, // its own (0: the project's)
	bars:  int,
	notes: int,
}

State_Bus :: struct {
	name:   string,
	volume: f32,
	pan:    f32,
	mute:   bool,
	solo:   bool,
	slots:  [pm.BUS_SLOTS]string,
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
	s.play_mode = enum_name(a.play_mode)
	switch a.detail.device.kind {
	case .Instrument: s.detail_tab = enum_name(a.detail.tab)
	case .Eq:         s.detail_tab = "EQ"
	case .Slot:       s.detail_tab = "Effect"
	}
	s.track = fmt.tprintf("%s %d", strings.to_lower(enum_name(a.detail.track.kind), context.temp_allocator), a.detail.track.index + 1)
	s.dark = a.dark
	s.beat, s.playing = pm.position(&m.engine)
	s.slot, s.bpm, s.metronome = p.slot + 1, p.bpm, m.engine.metronome
	s.recording = a.capture.armed
	tr := p.transport
	s.loop, s.count_in, s.metro_db, s.metro_rec_only = tr.loop, tr.count_in, tr.metro_db, tr.metro_rec_only
	s.time_sig = fmt.tprintf("%d/%d", tr.time_sig.num, tr.time_sig.den)
	s.quantize = {tr.quantize.on, string(pm.GRID_NAMES[tr.quantize.grid]), tr.quantize.strength, tr.quantize.swing}
	tl, _ := pm.timeline_beat(&m.engine)
	s.timeline = tl
	bar, bt, six := pm.position_of(p, tl if tl < 0 else s.beat)
	s.position = fmt.tprintf("%d.%d.%d", bar, bt, six)
	s.song_mode, s.song_steps = p.song_mode, p.song.count
	s.song = make([dynamic]int, context.temp_allocator)
	for st in p.song.steps[:p.song.count] do append(&s.song, int(st.slot) + 1)
	seq := pm.current_sequence(m)
	s.notes, s.points, s.bars = len(seq.notes), len(seq.points), seq.bars
	s.undo = app.undo_name(&m.history)
	s.dirty = pm.model_dirty(m)
	s.project = p.dir
	s.exporting = a.proj.exporting
	s.sequences = make([dynamic]State_Sequence, context.temp_allocator)
	for sq, k in p.sequences do if pm.slot_used(m, k) || k == p.slot {
		append(&s.sequences, State_Sequence{slot = k + 1, name = pm.sequence_name(p, k), bpm = sq.bpm, bars = sq.bars, notes = len(sq.notes)})
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
		for x, k in pad.sends do sp.sends[k] = pm.send_db(x)
		for x, k in pad.inserts do sp.inserts[k] = pm.slot_name(x)
		v := a.mixer.pads[i]
		sp.level = max(v[0].peak, v[1].peak)
		sp.start, sp.end = pm.pad_region(m, i)
		sp.fade_in, sp.fade_out = pad.fade_in, pad.fade_out
		f, ok := pm.pad_playhead(&m.engine, i)
		sp.playhead = f if ok else -1
		sp.kind, sp.input, sp.monitor, sp.armed = enum_name(pad.kind), enum_name(pad.input), pad.monitor, pm.audio_armed(m, i)
		sp.attack, sp.release, sp.voice = pad.attack, pad.release, pad.voice
		if l, live := pm.pad_live(&m.engine, i); live do sp.cutoff_now = l.cutoff
		if c := app.store_get(&p.samples, pm.current_clip(m, i).sample); c != nil do sp.take = c.frames
		append(&s.pads, sp)
	}
	for b in 0 ..= pm.BUSES {
		bus := pm.bus_of(m, b)^
		sb := State_Bus{name = pm.bus_name(0 if b == pm.BUSES else b + 1), volume = bus.volume, pan = bus.pan, mute = bus.mute, solo = bus.solo}
		for x, k in bus.slots do sb.slots[k] = pm.slot_name(x)
		s.buses[b] = sb
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
