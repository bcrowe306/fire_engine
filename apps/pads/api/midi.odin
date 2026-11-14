package pads_api

import app "app:core"
import pm "../model"

// What MIDI plays a pad.
Midi_In_Mode :: enum i32 {
	All,  // any port: the MIDI map (note N plays the pad mapped to it)
	None, // none
	Port, // one port (and channel), played chromatically while armed
}

// A MIDI port the system has.
Midi_Port :: struct {
	input:  bool, // a source (else a destination)
	open:   bool, // an input Pads listens to
}

// A pad's MIDI input and output.
Pad_Midi :: struct {
	in_mode:     Midi_In_Mode,
	in_channel:  i64,  // 0: any; 1..16
	out:         bool, // its hits also go out as MIDI
	out_channel: i64,  // 0..15
	out_key:     i64,  // the note it sends
}

// MIDI ports there are now (midi_port_name lists them; in the system's
// order: open ports may come and go).
midi_port_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(app.host_midi_ports(&api.core.host, context.temp_allocator))), .Ok
}

// MIDI port `index`: an input or an output, and whether it is open.
midi_port :: proc(api: ^Api, index: i64) -> (Midi_Port, Result) {
	ps := app.host_midi_ports(&api.core.host, context.temp_allocator)
	if index < 0 || index >= i64(len(ps)) do return {}, fail(api, .Not_Found, "no such port")
	p := ps[index]
	inp := p.direction == .Input
	open := false
	if inp do for id in app.host_midi_open_inputs(&api.core.host) do if id == p.id do open = true
	return {input = inp, open = open}, .Ok
}

// MIDI port `index`'s name. Temporary.
midi_port_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	ps := app.host_midi_ports(&api.core.host, context.temp_allocator)
	if index < 0 || index >= i64(len(ps)) do return "", fail(api, .Not_Found, "no such port")
	return ps[index].name, .Ok
}

// MIDI port `index`'s id (stable across runs where the system allows it:
// what pad inputs and outputs keep). Temporary.
midi_port_id :: proc(api: ^Api, index: i64) -> (string, Result) {
	ps := app.host_midi_ports(&api.core.host, context.temp_allocator)
	if index < 0 || index >= i64(len(ps)) do return "", fail(api, .Not_Found, "no such port")
	return ps[index].id, .Ok
}

// Plays a MIDI message (`status`, `data1`, `data2`) into Pads as if it came
// in on input `port` (its index among the open inputs): a note-on plays
// what it is mapped to, recorded while recording. Any thread but the audio
// thread.
midi_send :: proc(api: ^Api, status, data1, data2: i64, port: i64 = 0) -> Result {
	if status < 0x80 || status > 0xff || data1 < 0 || data1 > 127 || data2 < 0 || data2 > 127 || port < 0 || port > 255 {
		return fail(api, .Invalid_Argument, "a status 0x80..0xFF, data 0..127, a port 0..255")
	}
	app.host_midi_inject(&api.core.host, {u8(status), u8(data1), u8(data2)}, u8(port))
	return .Ok
}

// Makes MIDI key `key` (0..127) play pad `pad` (-1: nothing) in the MIDI
// map, undoably.
midi_learn :: proc(api: ^Api, key: i64, pad: i64) -> Result {
	if key < 0 || key > 127 do return fail(api, .Invalid_Argument, "a key is 0..127")
	if pad != -1 {
		if _, r := pad_of(api, pad); r != .Ok do return r
	}
	pm.learn_midi(&api.core.m, int(key), int(pad))
	return .Ok
}

// The MIDI key that plays pad `pad` (the lowest, if several), or -1.
midi_key_of :: proc(api: ^Api, pad: i64) -> (i64, Result) {
	if _, r := pad_of(api, pad); r != .Ok do return -1, r
	return i64(pm.midi_key_of(&api.core.m, int(pad))), .Ok
}

// Pad `pad`'s MIDI input and output.
midi_pad :: proc(api: ^Api, pad: i64) -> (Pad_Midi, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return {}, r
	return {in_mode = Midi_In_Mode(p.midi_in.mode), in_channel = i64(p.midi_in.channel), out = p.midi_out.on, out_channel = i64(p.midi_out.channel), out_key = i64(p.midi_out.key)}, .Ok
}

// What MIDI plays pad `pad`: all ports (the map), none, or port `port_id`
// (its id: midi_port_id) on `channel` (0: any; 1..16). Undoably.
midi_set_pad_input :: proc(api: ^Api, pad: i64, mode: Midi_In_Mode, port_id: string, channel: i64) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if mode < min(Midi_In_Mode) || mode > max(Midi_In_Mode) || channel < 0 || channel > 16 do return fail(api, .Invalid_Argument, "no such mode, or a channel 0..16")
	if mode == .Port && port_id == "" do return fail(api, .Invalid_Argument, "a port's id")
	m := &api.core.m
	n := p^
	n.midi_in = {mode = pm.Midi_In_Mode(mode), channel = u8(channel)}
	if mode == .Port do n.midi_in.port = pm.intern(&m.project, port_id)
	return set_pad(api, pad, .Midi_In, "MIDI In", n)
}

// Pad `pad`'s hits also go out as MIDI (`on`): note `key` (0..127) on
// `channel` (0..15) of output port `port_id` ("": the default output).
// Undoably.
midi_set_pad_output :: proc(api: ^Api, pad: i64, on: bool, channel: i64, key: i64, port_id: string) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if channel < 0 || channel > 15 || key < 0 || key > 127 do return fail(api, .Invalid_Argument, "a channel 0..15, a key 0..127")
	m := &api.core.m
	n := p^
	n.midi_out = {on = on, channel = u8(channel), key = u8(key), port = pm.intern(&m.project, port_id) if port_id != "" else ""}
	return set_pad(api, pad, .Midi_Out, "MIDI Out", n)
}

