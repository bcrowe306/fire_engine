package pads_api

import pm "../model"

// How a sample is recorded into a pad.
Sampling :: enum i32 {
	Hold,      // from now until recording_sample_stop
	Arm,       // as Hold (the toolbar's Arm waits for a pad's press; through the API, now)
	Threshold, // from where the input first passes `threshold_db`, until stopped
	Bars,      // the next `bars` bars, from the next bar's start (it starts playing if stopped)
}

// Recording now.
Recording_State :: struct {
	armed:       bool, // Rec: notes played, knobs moved (with Auto), and armed audio tracks' inputs go into the sequence while it plays
	recording:   bool, // armed and playing (or counting in)
	sampling:    bool, // a sample is being recorded into a pad
	sample_pad:  i64,  // ... which (-1: none)
	latency:     i64,  // frames a take is moved earlier by (the device's round trip and the setting)
}

// Recording now.
recording_state :: proc(api: ^Api) -> (Recording_State, Result) {
	c := api.core
	_, playing := pm.timeline_beat(&c.m.engine)
	return {
		armed = c.capture.armed, recording = c.capture.armed && playing, sampling = c.rec.active,
		sample_pad = i64(c.rec.pad) if c.rec.active else -1, latency = i64(pm.record_latency(&c.m.engine)),
	}, .Ok
}

// Arms Rec (or disarms it). Armed while stopped, it starts playing, after
// the count-in if there is one (transport_set_count_in).
recording_record :: proc(api: ^Api, on: bool) -> Result {
	c := api.core
	pm.capture_arm(&c.m, &c.capture, on)
	if _, playing := pm.timeline_beat(&c.m.engine); on && !playing do transport_play(api, count_in = true)
	return .Ok
}

// Records a sample into pad `pad` from its input (its strip's In), by
// `method` (Threshold: from `threshold_db`, -80..0; Bars: `bars`, 1..16).
// It lands on the pad (one undo step) when it stops. Unsupported when the
// pad has no input or there is no audio input.
recording_sample_start :: proc(api: ^Api, pad: i64, method: Sampling, threshold_db: f32 = -40, bars: i64 = 1) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	if method < min(Sampling) || method > max(Sampling) do return fail(api, .Invalid_Argument, "no such method")
	if !(threshold_db >= -80 && threshold_db <= 0) || bars < 1 || bars > 16 do return fail(api, .Invalid_Argument, "a threshold is -80..0 dB, bars 1..16")
	c := api.core
	m := method if method != .Arm else .Hold
	if pm.record_start(&c.m, &c.rec, int(pad), pm.Sampling(m), threshold_db, int(bars)) != .None {
		return fail(api, .Unsupported, "nothing to record from: the pad's input is none, or there is no audio input")
	}
	return .Ok
}

// Stops the sample being recorded (Hold, Threshold; Bars stop by
// themselves). Not_Found when none is.
recording_sample_stop :: proc(api: ^Api) -> Result {
	c := api.core
	if !c.rec.active do return fail(api, .Not_Found, "no sample is being recorded")
	pm.record_stop(&c.rec)
	c.sample_holding = -1
	return .Ok
}
