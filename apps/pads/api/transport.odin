package pads_api

import "fire:dsp"
import pm "../model"

// The metronome's sound.
Metronome_Sound :: enum i32 {
	Beep,
	Wood,
	Stick,
	Cowbell,
}

// The transport now. The playhead (`beat`, `timeline_beat`, the position)
// moves without a change being reported: poll it.
Transport_State :: struct {
	playing:       bool,
	counting_in:   bool, // playing, still before the top (the count-in)
	recording:     bool, // Rec is armed
	song_mode:     bool, // the song plays (else the sequence shown: Pattern)
	beat:          f64,  // beats into what plays (0 stopped)
	timeline_beat: f64,  // beats on the timeline (negative counting in)
	bar:           i64,  // where it is, as a musician counts (from 1; 0 or less counting in)
	beat_in_bar:   i64,  // ... the beat (from 1)
	sixteenth:     i64,  // ... the sixteenth (from 1)
	bpm:           f64,
	loop:          bool, // it goes round (else it plays once and stops)
	count_in:      i64,  // bars of click before recording (0..2)
	time_sig_num:  i64,
	time_sig_den:  i64,
	metronome:     bool, // the click is on
	metronome_db:  f32,
	metronome_sound: Metronome_Sound,
	metronome_accent: bool, // the bar's first beat clicks louder
	metronome_recording_only: bool, // it clicks only while recording (and counting in)
}

// The transport now.
transport_state :: proc(api: ^Api) -> (Transport_State, Result) {
	m := &api.core.m
	e := &m.engine
	p := &m.project
	tr := p.transport
	s: Transport_State
	tl, playing := pm.timeline_beat(e)
	rel, _ := pm.position(e)
	s.playing, s.counting_in = playing, playing && tl < 0
	s.recording, s.song_mode = api.core.capture.armed, p.song_mode
	s.beat, s.timeline_beat = rel, tl
	if playing {
		bar, bt, six := pm.position_of(p, tl if tl < 0 else rel)
		s.bar, s.beat_in_bar, s.sixteenth = i64(bar), i64(bt), i64(six)
	} else {
		s.bar, s.beat_in_bar, s.sixteenth = 1, 1, 1
	}
	s.bpm, s.loop, s.count_in = p.bpm, tr.loop, i64(tr.count_in)
	s.time_sig_num, s.time_sig_den = i64(tr.time_sig.num), i64(tr.time_sig.den)
	s.metronome, s.metronome_db = e.metronome, tr.metro_db
	s.metronome_sound = Metronome_Sound(tr.click)
	s.metronome_accent, s.metronome_recording_only = !tr.no_accent, tr.metro_rec_only
	return s, .Ok
}

// Starts playing from beat `from_beat` of what plays (the sequence shown,
// or the song from its cue at 0); with `count_in`, the count-in's bars of
// click first. Playing already, it starts again from there.
transport_play :: proc(api: ^Api, from_beat: f64 = 0, count_in := false) -> Result {
	if from_beat < 0 do return fail(api, .Invalid_Argument, "from_beat is below 0")
	pm.play(&api.core.m.engine, count_in = count_in, from_beat = from_beat)
	return .Ok
}

// Stops (back to the top) and disarms Rec. Stopped already, it does
// nothing more.
transport_stop :: proc(api: ^Api) -> Result {
	c := api.core
	pm.stop(&c.m.engine)
	pm.capture_arm(&c.m, &c.capture, false)
	c.transport.stopped_at = c.transport.clock
	return .Ok
}

// Plays if stopped, stops if playing (the Space key).
transport_toggle :: proc(api: ^Api) -> Result {
	if _, playing := pm.timeline_beat(&api.core.m.engine); playing do return transport_stop(api)
	return transport_play(api)
}

// Silences every sound at once (a fade of a few milliseconds), playing or
// not: what pressing Stop twice does.
transport_silence :: proc(api: ^Api) -> Result {
	pm.silence_all(&api.core.m.engine)
	api.core.transport.silences += 1
	return .Ok
}

// Sets the tempo (40..300 BPM), undoably.
transport_set_tempo :: proc(api: ^Api, bpm: f64) -> Result {
	if !(bpm >= 40 && bpm <= 300) do return fail(api, .Invalid_Argument, "the tempo is 40..300 BPM")
	pm.set_bpm(&api.core.m, bpm)
	edited(api)
	return .Ok
}

// One tap of tap tempo, now (the app's clock): returns the tempo the taps
// so far make, set (to a tenth), or 0 until there are two. The fourth tap
// stopped starts playing a beat later; a pause of 2 s starts again.
transport_tap :: proc(api: ^Api) -> (f64, Result) {
	t := &api.core.transport
	t.tapped = max(t.clock, 1e-6)
	b := pm.tap(&t.taps, t.clock)
	if _, playing := pm.timeline_beat(&api.core.m.engine); playing do t.taps.start_at = 0 // playing: only the tempo
	if b <= 0 do return 0, .Ok
	bpm := f64(int(b * 10 + 0.5)) / 10
	pm.set_bpm(&api.core.m, bpm)
	edited(api)
	return bpm, .Ok
}

// Loops (it goes round) or plays once and stops, undoably.
transport_set_loop :: proc(api: ^Api, on: bool) -> Result {
	n := api.core.m.project.transport
	n.loop = on
	return set_transport(api, .Loop, "Loop", n)
}

// Sets the bars of click before recording (0..2), undoably.
transport_set_count_in :: proc(api: ^Api, bars: i64) -> Result {
	if bars < 0 || bars > 2 do return fail(api, .Invalid_Argument, "the count-in is 0..2 bars")
	n := api.core.m.project.transport
	n.count_in = int(bars)
	return set_transport(api, .Count_In, "Count-in", n)
}

// Sets the time signature: `num` beats (1..16) of 1/`den` (2, 4, 8 or
// 16), undoably.
transport_set_time_signature :: proc(api: ^Api, num, den: i64) -> Result {
	if num < 1 || num > 16 do return fail(api, .Invalid_Argument, "a bar is 1..16 beats")
	if den != 2 && den != 4 && den != 8 && den != 16 do return fail(api, .Invalid_Argument, "the beat is 1/2, 1/4, 1/8 or 1/16")
	n := api.core.m.project.transport
	n.time_sig = {int(num), int(den)}
	return set_transport(api, .Time_Sig, "Time Signature", n)
}

// Turns the metronome on or off (the app's, not the project's: not undoable).
transport_set_metronome :: proc(api: ^Api, on: bool) -> Result {
	api.core.m.engine.metronome = on
	return .Ok
}

// Sets the metronome's level (-48..6 dB), undoably.
transport_set_metronome_level :: proc(api: ^Api, db: f32) -> Result {
	if !(db >= -48 && db <= 6) do return fail(api, .Invalid_Argument, "the metronome's level is -48..6 dB")
	n := api.core.m.project.transport
	n.metro_db = db
	return set_transport(api, .Metro_Level, "Metronome Level", n)
}

// Sets the metronome's sound, undoably.
transport_set_metronome_sound :: proc(api: ^Api, sound: Metronome_Sound) -> Result {
	if sound < min(Metronome_Sound) || sound > max(Metronome_Sound) do return fail(api, .Invalid_Argument, "no such sound")
	n := api.core.m.project.transport
	n.click = dsp.Click_Sound(sound)
	return set_transport(api, .Metro_Sound, "Metronome Sound", n)
}

// Accents the bar's first beat (or clicks it as the others), undoably.
transport_set_metronome_accent :: proc(api: ^Api, on: bool) -> Result {
	n := api.core.m.project.transport
	n.no_accent = !on
	return set_transport(api, .Metro_Accent, "Metronome Accent", n)
}

// Clicks only while recording and counting in (or always when on),
// undoably.
transport_set_metronome_recording_only :: proc(api: ^Api, on: bool) -> Result {
	n := api.core.m.project.transport
	n.metro_rec_only = on
	return set_transport(api, .Metro_Rec_Only, "Metronome Mode", n)
}

// Plays the song (true) or the sequence shown (false: Pattern).
transport_set_song_mode :: proc(api: ^Api, on: bool) -> Result {
	p := &api.core.m.project
	if p.song_mode == on do return .Ok
	p.song_mode = on
	api.core.m.engine.seq_dirty = true
	return .Ok
}

@(private)
set_transport :: proc(api: ^Api, field: pm.Transport_Field, name: string, n: pm.Transport) -> Result {
	pm.set_transport(&api.core.m, field, name, n)
	edited(api)
	return .Ok
}
