/*
Making CLAP plug-ins from Fire Engine nodes: any `core.Node` (yours, or
fire:dsp's) becomes a plug-in other hosts can load, built from Odin as a
shared library (`odin build my_plugin -build-mode:shared`; on macOS, put it
in a .clap bundle).

The library exports `clap_entry`, made of the SDK's procedures and an init
of its own that hands the SDK its plug-ins:

	package my_plugins

	import "fire:clap/sdk"
	import "fire:dsp"
	import c "fire:sys/clap"

	defs := [?]sdk.Plugin_Def{
		{id = "com.example.eq", name = "Example EQ", vendor = "Example", version = "1.0",
		 features = {"audio-effect", "equalizer"}, inputs = 2, outputs = 2,
		 make = proc() -> core.Node { return dsp.eq_create(4) }},
	}

	@(export, link_name = "clap_entry")
	clap_entry := c.Plugin_Entry{c.VERSION, init, sdk.entry_deinit, sdk.entry_get_factory}

	init :: proc "c" (path: cstring) -> bool { return sdk.entry_init(defs[:]) }

The node's parameters are the plug-in's (same ids, ranges and names), its
audio channels its ports, notes and MIDI pass in and out, the host's
transport arrives as `ctx.transport`, its latency is reported, and its state
is its parameter values.
*/
package clap_sdk

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

import "fire:core"
import "fire:rt"
import c "fire:sys/clap"

// A plug-in the library offers.
Plugin_Def :: struct {
	id:          cstring, // reverse-domain, stable forever: "com.example.eq"
	name:        cstring,
	vendor:      cstring,
	version:     cstring,
	description: cstring,
	features:    []cstring, // CLAP feature tags: "instrument", "audio-effect", "synthesizer", ...
	inputs:      int, // audio input channels (one port), 0 for none
	outputs:     int, // audio output channels (one port)
	notes_in:    bool, // takes notes and MIDI
	notes_out:   bool, // sends notes and MIDI
	make:        proc() -> core.Node, // a new node, on the host's main thread
}

@(private) defs: []Plugin_Def
@(private) descriptors: []c.Plugin_Descriptor
@(private) feature_lists: [][]cstring

// The library's init: call it from your `clap_entry.init` with your
// plug-ins (which must stay valid: a global array). Returns true.
entry_init :: proc "c" (plugins: []Plugin_Def) -> bool {
	context = runtime.default_context()
	defs = plugins
	descriptors = make([]c.Plugin_Descriptor, len(plugins))
	feature_lists = make([][]cstring, len(plugins))
	for d, i in plugins {
		feature_lists[i] = make([]cstring, len(d.features) + 1) // nil-terminated
		copy(feature_lists[i], d.features)
		descriptors[i] = {
			clap_version = c.VERSION, id = d.id, name = d.name, vendor = d.vendor,
			url = "", manual_url = "", support_url = "", version = d.version if d.version != nil else "1.0",
			description = d.description if d.description != nil else "", features = raw_data(feature_lists[i]),
		}
	}
	return true
}

// The library's deinit, for `clap_entry.deinit`.
entry_deinit :: proc "c" () {
	context = runtime.default_context()
	for f in feature_lists do delete(f)
	delete(feature_lists)
	delete(descriptors)
	defs, descriptors, feature_lists = nil, nil, nil
}

// The library's factories, for `clap_entry.get_factory`.
entry_get_factory :: proc "c" (id: cstring) -> rawptr {
	return &factory if string(id) == c.PLUGIN_FACTORY_ID else nil
}

@(private)
factory := c.Plugin_Factory {
	get_plugin_count = proc "c" (f: ^c.Plugin_Factory) -> u32 { return u32(len(defs)) },
	get_plugin_descriptor = proc "c" (f: ^c.Plugin_Factory, i: u32) -> ^c.Plugin_Descriptor {
		return &descriptors[i] if int(i) < len(descriptors) else nil
	},
	create_plugin = create_plugin,
}

// One instance.
@(private)
Instance :: struct {
	clap:      c.Plugin,
	def:       ^Plugin_Def,
	host:      ^c.Host,
	node:      core.Node,
	params:    []core.Param_Info,
	values:    []f64, // the parameters' values, as last set
	pending:   rt.Spsc_Queue(core.Param_Value), // main → audio: values set outside processing (a state load)
	active:    bool,
	sample_rate: f64,
	frames:    int,
	ins:       [][]f32,
	outs:      [][]f32,
	events_in: []core.Event,
	events_out: []core.Event,
	transport: core.Transport,
	timeline:  [1]core.Timeline_State,
}

@(private)
create_plugin :: proc "c" (f: ^c.Plugin_Factory, host: ^c.Host, id: cstring) -> ^c.Plugin {
	context = runtime.default_context()
	if host == nil || !c.version_is_compatible(host.clap_version) do return nil
	for &d, i in defs do if string(d.id) == string(id) {
		p := new(Instance)
		p.def, p.host = &d, host
		p.clap = {
			desc = &descriptors[i], plugin_data = p,
			init = plugin_init, destroy = plugin_destroy, activate = plugin_activate, deactivate = plugin_deactivate,
			start_processing = proc "c" (pl: ^c.Plugin) -> bool { return true },
			stop_processing = proc "c" (pl: ^c.Plugin) {},
			reset = proc "c" (pl: ^c.Plugin) {
				context = runtime.default_context()
				core.node_reset(&instance(pl).node)
			},
			process = plugin_process, get_extension = plugin_get_extension,
			on_main_thread = proc "c" (pl: ^c.Plugin) {},
		}
		return &p.clap
	}
	return nil
}

@(private)
instance :: #force_inline proc "contextless" (pl: ^c.Plugin) -> ^Instance {
	return (^Instance)(pl.plugin_data)
}

@(private)
plugin_init :: proc "c" (pl: ^c.Plugin) -> bool {
	context = runtime.default_context()
	p := instance(pl)
	p.node = p.def.make()
	p.params = core.node_params(&p.node)
	p.values = make([]f64, len(p.params))
	for info, i in p.params do p.values[i] = info.default
	rt.spsc_init(&p.pending, max(4 * len(p.params), 64))
	return true
}

@(private)
plugin_destroy :: proc "c" (pl: ^c.Plugin) {
	context = runtime.default_context()
	p := instance(pl)
	if p.active do plugin_deactivate(pl)
	core.node_destroy(&p.node)
	delete(p.values)
	rt.spsc_destroy(&p.pending)
	free(p)
}

@(private)
plugin_activate :: proc "c" (pl: ^c.Plugin, sample_rate: f64, min_frames, max_frames: u32) -> bool {
	context = runtime.default_context()
	p := instance(pl)
	cfg := core.Prepare_Config{sample_rate = sample_rate, max_block = int(max_frames), in_channels = p.def.inputs, out_channels = p.def.outputs}
	if core.node_prepare(&p.node, cfg) != .None do return false
	p.ins = make([][]f32, p.def.inputs)
	p.outs = make([][]f32, p.def.outputs)
	p.events_in = make([]core.Event, 4096)
	p.events_out = make([]core.Event, 4096)
	p.active, p.sample_rate = true, sample_rate
	// The node starts at its defaults: send it the values set before.
	for info, i in p.params do if p.values[i] != info.default do rt.spsc_push(&p.pending, core.Param_Value{info.id, p.values[i]})
	return true
}

@(private)
plugin_deactivate :: proc "c" (pl: ^c.Plugin) {
	context = runtime.default_context()
	p := instance(pl)
	if !p.active do return
	core.node_release(&p.node)
	delete(p.ins)
	delete(p.outs)
	delete(p.events_in)
	delete(p.events_out)
	p.active = false
}

// [rt]
@(private)
plugin_process :: proc "c" (pl: ^c.Plugin, pr: ^c.Process) -> c.Process_Status {
	context = runtime.default_context()
	p := instance(pl)
	n := int(pr.frames_count)
	// Audio: the ports' channels in order.
	fill :: proc "contextless" (dst: [][]f32, bufs: [^]c.Audio_Buffer, count: u32, n: int) {
		k := 0
		for b in 0 ..< count do for ch in 0 ..< bufs[b].channel_count {
			if k < len(dst) do dst[k] = bufs[b].data32[ch][:n]
			k += 1
		}
	}
	fill(p.ins, pr.audio_inputs, pr.audio_inputs_count, n)
	fill(p.outs, pr.audio_outputs, pr.audio_outputs_count, n)
	// Events: pending values first, then the host's.
	k := 0
	for v in rt.spsc_pop(&p.pending) do if k < len(p.events_in) {
		p.events_in[k] = {offset = 0, payload = v}
		k += 1
	}
	if pr.in_events != nil {
		count := pr.in_events.size(pr.in_events)
		for i in 0 ..< count {
			h := pr.in_events.get(pr.in_events, i)
			if h == nil || h.space_id != c.CORE_EVENT_SPACE_ID || k == len(p.events_in) do continue
			if payload, ok := from_clap(p, h); ok {
				p.events_in[k] = {offset = min(h.time, u32(max(n - 1, 0))), payload = payload}
				k += 1
			}
		}
	}
	writer := core.Event_Writer{buffer = p.events_out}
	ctx := core.Process_Context{inputs = p.ins, outputs = p.outs, frames = n, events_in = p.events_in[:k], events_out = &writer}
	if pr.transport != nil do ctx.transport = transport_from(p, pr.transport)
	core.node_process(&p.node, &ctx)
	if pr.out_events != nil do for e in core.event_writer_events(&writer) do to_clap(pr.out_events, e)
	return c.PROCESS_CONTINUE
}

// [rt] A CLAP event as a Fire Engine one.
@(private)
from_clap :: proc "contextless" (p: ^Instance, h: ^c.Event_Header) -> (payload: core.Event_Payload, ok: bool) {
	switch h.type {
	case c.EVENT_NOTE_ON:
		e := (^c.Event_Note)(h)
		return core.Note_On{id = core.Note_Id(e.note_id), channel = u8(max(e.channel, 0)), key = u8(max(e.key, 0)), velocity = f32(e.velocity)}, true
	case c.EVENT_NOTE_OFF, c.EVENT_NOTE_CHOKE:
		e := (^c.Event_Note)(h)
		return core.Note_Off{id = core.Note_Id(e.note_id), channel = u8(max(e.channel, 0)), key = u8(max(e.key, 0)), velocity = f32(e.velocity)}, true
	case c.EVENT_NOTE_EXPRESSION:
		e := (^c.Event_Note_Expression)(h)
		kind: core.Note_Expression_Kind
		switch e.expression_id {
		case c.NOTE_EXPRESSION_VOLUME:     kind = .Volume
		case c.NOTE_EXPRESSION_PAN:        kind = .Pan
		case c.NOTE_EXPRESSION_TUNING:     kind = .Tuning
		case c.NOTE_EXPRESSION_VIBRATO:    kind = .Vibrato
		case c.NOTE_EXPRESSION_BRIGHTNESS: kind = .Brightness
		case c.NOTE_EXPRESSION_PRESSURE:   kind = .Pressure
		case: return nil, false
		}
		return core.Note_Expression{id = core.Note_Id(e.note_id), channel = u8(max(e.channel, 0)), key = u8(max(e.key, 0)), kind = kind, value = e.value}, true
	case c.EVENT_PARAM_VALUE:
		e := (^c.Event_Param_Value)(h)
		for info, i in p.params do if info.id == core.Param_Id(e.param_id) do p.values[i] = e.value
		return core.Param_Value{param = core.Param_Id(e.param_id), value = e.value}, true
	case c.EVENT_MIDI:
		e := (^c.Event_Midi)(h)
		return core.Midi_Raw{bytes = e.data, port = u8(e.port_index)}, true
	}
	return nil, false
}

// [rt] A Fire Engine event the node sent, to the host.
@(private)
to_clap :: proc "contextless" (out: ^c.Output_Events, e: core.Event) {
	head :: proc "contextless" (t: u32, type: u16, $T: typeid) -> c.Event_Header {
		return {size = size_of(T), time = t, space_id = c.CORE_EVENT_SPACE_ID, type = type}
	}
	#partial switch v in e.payload {
	case core.Note_On:
		x := c.Event_Note{head(e.offset, c.EVENT_NOTE_ON, c.Event_Note), i32(v.id), 0, i16(v.channel), i16(v.key), f64(v.velocity)}
		out.try_push(out, &x.header)
	case core.Note_Off:
		x := c.Event_Note{head(e.offset, c.EVENT_NOTE_OFF, c.Event_Note), i32(v.id), 0, i16(v.channel), i16(v.key), f64(v.velocity)}
		out.try_push(out, &x.header)
	case core.Param_Value:
		x := c.Event_Param_Value{head(e.offset, c.EVENT_PARAM_VALUE, c.Event_Param_Value), c.Id(v.param), nil, -1, -1, -1, -1, v.value}
		out.try_push(out, &x.header)
	case core.Midi_Raw:
		x := c.Event_Midi{head(e.offset, c.EVENT_MIDI, c.Event_Midi), u16(v.port), v.bytes}
		out.try_push(out, &x.header)
	}
}

// [rt] The host's transport, as a Fire Engine clock with one timeline.
@(private)
transport_from :: proc "contextless" (p: ^Instance, tr: ^c.Event_Transport) -> ^core.Transport {
	t := &p.transport
	beats := f64(tr.song_pos_beats) / f64(c.BEATTIME_FACTOR)
	id := core.Timeline_Id{0, 1}
	p.timeline[0] = {
		id = id, playing = tr.flags & c.TRANSPORT_IS_PLAYING != 0, position = auto_cast beats, rate = 1,
		looping = tr.flags & c.TRANSPORT_IS_LOOP_ACTIVE != 0,
		loop_start = auto_cast (f64(tr.loop_start_beats) / f64(c.BEATTIME_FACTOR)),
		loop_end = auto_cast (f64(tr.loop_end_beats) / f64(c.BEATTIME_FACTOR)),
	}
	t^ = {
		sample_rate = p.sample_rate, tempo_bpm = tr.tempo if tr.tempo > 0 else 120,
		grid = auto_cast beats, bar = i64(tr.bar_number), bar_start = auto_cast (f64(tr.bar_start) / f64(c.BEATTIME_FACTOR)),
		leader = id, timelines = p.timeline[:],
	}
	t.meter.numerator, t.meter.denominator = i32(tr.tsig_num), i32(tr.tsig_denom)
	return t
}

@(private)
plugin_get_extension :: proc "c" (pl: ^c.Plugin, id: cstring) -> rawptr {
	switch string(id) {
	case c.EXT_PARAMS:      return &params_ext
	case c.EXT_AUDIO_PORTS: return &audio_ports_ext
	case c.EXT_NOTE_PORTS:  return &note_ports_ext
	case c.EXT_LATENCY:     return &latency_ext
	case c.EXT_STATE:       return &state_ext
	}
	return nil
}

@(private)
params_ext := c.Plugin_Params {
	count = proc "c" (pl: ^c.Plugin) -> u32 { return u32(len(instance(pl).params)) },
	get_info = proc "c" (pl: ^c.Plugin, index: u32, info: ^c.Param_Info) -> bool {
		p := instance(pl)
		if int(index) >= len(p.params) do return false
		src := p.params[index]
		info^ = {id = c.Id(src.id), min_value = src.min, max_value = src.max, default_value = src.default}
		if .Automatable in src.flags do info.flags |= c.PARAM_IS_AUTOMATABLE
		if .Stepped in src.flags do info.flags |= c.PARAM_IS_STEPPED
		if .Hidden in src.flags do info.flags |= c.PARAM_IS_HIDDEN
		n := min(len(src.name), c.NAME_SIZE - 1)
		intrinsics.mem_copy(&info.name[0], raw_data(src.name), n)
		return true
	},
	get_value = proc "c" (pl: ^c.Plugin, id: c.Id, out: ^f64) -> bool {
		p := instance(pl)
		for info, i in p.params do if info.id == core.Param_Id(id) {
			out^ = p.values[i]
			return true
		}
		return false
	},
	value_to_text = proc "c" (pl: ^c.Plugin, id: c.Id, value: f64, buf: [^]u8, capacity: u32) -> bool {
		context = runtime.default_context()
		p := instance(pl)
		for info in p.params do if info.id == core.Param_Id(id) {
			units := [core.Param_Unit]string{.None = "", .Decibels = " dB", .Hertz = " Hz", .Milliseconds = " ms", .Percent = " %", .Semitones = " st", .Ratio = ":1"}
			s := fmt.bprintf(buf[:capacity], "%.2f%s", value, units[info.unit])
			if int(capacity) > len(s) do buf[len(s)] = 0
			return true
		}
		return false
	},
	text_to_value = proc "c" (pl: ^c.Plugin, id: c.Id, text: cstring, out: ^f64) -> bool {
		context = runtime.default_context()
		t := strings.trim_space(string(text))
		if i := strings.index_byte(t, ' '); i >= 0 do t = t[:i] // "−6.00 dB" → "−6.00"
		v, ok := strconv.parse_f64(t)
		if ok do out^ = v
		return ok
	},
	flush = proc "c" (pl: ^c.Plugin, in_events: ^c.Input_Events, out_events: ^c.Output_Events) {
		// Parameter changes while not processing: record them; an active node
		// gets them through a zero-frame process.
		p := instance(pl)
		if in_events == nil do return
		count := in_events.size(in_events)
		k := 0
		for i in 0 ..< count {
			h := in_events.get(in_events, i)
			if h == nil || h.type != c.EVENT_PARAM_VALUE || h.space_id != c.CORE_EVENT_SPACE_ID do continue
			if payload, ok := from_clap(p, h); ok && p.active && k < len(p.events_in) {
				p.events_in[k] = {payload = payload}
				k += 1
			}
		}
		if p.active && k > 0 {
			writer := core.Event_Writer{buffer = p.events_out}
			ctx := core.Process_Context{inputs = p.ins, outputs = p.outs, events_in = p.events_in[:k], events_out = &writer}
			context = runtime.default_context()
			core.node_process(&p.node, &ctx)
		}
	},
}

@(private)
audio_ports_ext := c.Plugin_Audio_Ports {
	count = proc "c" (pl: ^c.Plugin, is_input: bool) -> u32 {
		d := instance(pl).def
		return 1 if (d.inputs if is_input else d.outputs) > 0 else 0
	},
	get = proc "c" (pl: ^c.Plugin, index: u32, is_input: bool, info: ^c.Audio_Port_Info) -> bool {
		d := instance(pl).def
		ch := d.inputs if is_input else d.outputs
		if index != 0 || ch == 0 do return false
		info^ = {id = 0 if is_input else 1, flags = c.AUDIO_PORT_IS_MAIN, channel_count = u32(ch), in_place_pair = c.INVALID_ID}
		info.port_type = "stereo" if ch == 2 else "mono" if ch == 1 else nil
		name := "In" if is_input else "Out"
		intrinsics.mem_copy(&info.name[0], raw_data(name), len(name))
		return true
	},
}

@(private)
note_ports_ext := c.Plugin_Note_Ports {
	count = proc "c" (pl: ^c.Plugin, is_input: bool) -> u32 {
		d := instance(pl).def
		return 1 if (d.notes_in if is_input else d.notes_out) else 0
	},
	get = proc "c" (pl: ^c.Plugin, index: u32, is_input: bool, info: ^c.Note_Port_Info) -> bool {
		d := instance(pl).def
		if index != 0 || !(d.notes_in if is_input else d.notes_out) do return false
		info^ = {id = 2 if is_input else 3, supported_dialects = c.NOTE_DIALECT_CLAP | c.NOTE_DIALECT_MIDI, preferred_dialect = c.NOTE_DIALECT_CLAP}
		name := "Notes"
		intrinsics.mem_copy(&info.name[0], raw_data(name), len(name))
		return true
	},
}

@(private)
latency_ext := c.Plugin_Latency {
	get = proc "c" (pl: ^c.Plugin) -> u32 {
		context = runtime.default_context()
		return u32(core.node_latency(&instance(pl).node))
	},
}

// The state: "FIRE" then, per parameter, its id (u32) and value (f64),
// little-endian.
@(private)
state_ext := c.Plugin_State {
	save = proc "c" (pl: ^c.Plugin, s: ^c.Ostream) -> bool {
		p := instance(pl)
		magic := [4]u8{'F', 'I', 'R', 'E'}
		if s.write(s, &magic, 4) != 4 do return false
		for info, i in p.params {
			id := u32(info.id)
			v := p.values[i]
			if s.write(s, &id, 4) != 4 || s.write(s, &v, 8) != 8 do return false
		}
		return true
	},
	load = proc "c" (pl: ^c.Plugin, s: ^c.Istream) -> bool {
		context = runtime.default_context()
		p := instance(pl)
		magic: [4]u8
		if s.read(s, &magic, 4) != 4 || magic != {'F', 'I', 'R', 'E'} do return false
		for {
			id: u32
			v: f64
			if s.read(s, &id, 4) != 4 || s.read(s, &v, 8) != 8 do break
			for info, i in p.params do if u32(info.id) == id {
				p.values[i] = v
				rt.spsc_push(&p.pending, core.Param_Value{info.id, v})
			}
		}
		return true
	},
}

