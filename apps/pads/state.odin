package pads

import "core:encoding/json"
import "core:fmt"

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
	detail_tab: string,
	dark:       bool,
	playing:    bool,
	beat:       f64,
	slot:       int,
	bpm:        f64,
	metronome:  bool,
	recording:  bool,
	song_mode:  bool,
	song_steps: int,
	notes:      int, // in the current sequence
	points:     int,
	bars:       int,
	undo:       string, // the next undo step's name
	dirty:      bool,
	project:    string,
	exporting:  bool,
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
	s.detail_tab = enum_name(a.detail.tab)
	s.dark = a.dark
	s.beat, s.playing = pm.position(&m.engine)
	s.slot, s.bpm, s.metronome = p.slot + 1, p.bpm, m.engine.metronome
	s.recording = a.capture.armed
	s.song_mode, s.song_steps = p.song_mode, p.song.count
	seq := pm.current_sequence(m)
	s.notes, s.points, s.bars = len(seq.notes), len(seq.points), seq.bars
	s.undo = app.undo_name(&m.history)
	s.dirty = pm.model_dirty(m)
	s.project = p.dir
	s.exporting = a.proj.exporting
	s.pads = make([dynamic]State_Pad, context.temp_allocator)
	for &pad, i in p.pads do if pad.sample != 0 {
		sp := State_Pad{index = i, label = pm.pad_label(i), name = pm.pad_name(&pad), mode = enum_name(pad.mode),
			volume = pad.volume, pan = pad.pan, pitch = pad.pitch, bus = int(pad.bus), mute = pad.mute, solo = pad.solo,
			slices = pad.slice_count}
		for x, k in pad.sends do sp.sends[k] = pm.send_db(x)
		for x, k in pad.inserts do sp.inserts[k] = pm.slot_name(x)
		v := a.mixer.pads[i]
		sp.level = max(v[0].peak, v[1].peak)
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
