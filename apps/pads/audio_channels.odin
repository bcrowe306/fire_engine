package pads

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import app "app:core"
import "fire:backend"
import im "deps:imgui"
import "app:ui"
import pm "model"
import "fire:backend/fake"

// Which of an interface's channels Pads opens, remembered per interface:
// its inputs and outputs, the pair main plays on, the cue pair, and names
// you give its channels. In settings.ini, a section per interface
// ([audio.device.<id>]; "default" for the system's default device).

// One interface's channel choice.
Interface_Config :: struct {
	id:      string, // the device id ("default": the system's)
	inputs:  backend.Channel_Mask, // physical channels, 0-based
	outputs: backend.Channel_Mask,
	main:    int, // the first channel of the pair main plays on (0: 1/2)
	cue:     int, // the cue pair's first channel (-1: none)
	aliases: [dynamic]Channel_Alias,
}

// A name given to a channel.
Channel_Alias :: struct {
	output:  bool,
	channel: int,
	name:    string,
}

// The interface settings use for device id `id` ("" = the system's
// default: its entry is "default").
interface_key :: proc(id: string) -> string {
	return id if id != "" else "default"
}

// The entry for device `id`, made with the defaults (inputs 1–2, outputs
// 1–2, main on 1/2, no cue) if there is none yet.
interface_for :: proc(c: ^Audio_Config, id: string) -> ^Interface_Config {
	key := interface_key(id)
	for &f in c.interfaces do if f.id == key do return &f
	append(&c.interfaces, Interface_Config{id = strings.clone(key), inputs = {0, 1}, outputs = {0, 1}, main = 0, cue = -1, aliases = make([dynamic]Channel_Alias)})
	return &c.interfaces[len(c.interfaces) - 1]
}

// The entry for device `id`, or nil when it has none (not changed).
interface_find :: proc(c: ^Audio_Config, id: string) -> ^Interface_Config {
	key := interface_key(id)
	for &f in c.interfaces do if f.id == key do return &f
	return nil
}

// A channel's alias ("" if none).
channel_alias :: proc(f: ^Interface_Config, output: bool, channel: int) -> string {
	if f == nil do return ""
	for al in f.aliases do if al.output == output && al.channel == channel do return al.name
	return ""
}

// Names channel `channel` (an empty name: no alias).
set_channel_alias :: proc(f: ^Interface_Config, output: bool, channel: int, name: string) {
	trimmed := strings.trim_space(name)
	for &al, k in f.aliases do if al.output == output && al.channel == channel {
		delete(al.name)
		if trimmed == "" {
			ordered_remove(&f.aliases, k)
		} else {
			al.name = strings.clone(trimmed)
		}
		return
	}
	if trimmed != "" do append(&f.aliases, Channel_Alias{output, channel, strings.clone(trimmed)})
}

// How a channel shows: "In 3 · Kick mic" (its alias), "In 3 · Line 3" (the
// driver's name), or "In 3".
channel_label :: proc(f: ^Interface_Config, dev: ^backend.Device_Info, output: bool, channel: int, allocator := context.temp_allocator) -> string {
	num := fmt.tprintf("%s %d", "Out" if output else "In", channel + 1)
	if al := channel_alias(f, output, channel); al != "" do return fmt.aprintf("%s · %s", num, al, allocator = allocator)
	if dev != nil {
		names := dev.output_channel_names if output else dev.input_channel_names
		if channel < len(names) && names[channel] != "" do return fmt.aprintf("%s · %s", num, names[channel], allocator = allocator)
	}
	return strings.clone(num, allocator)
}

// A pair's label: "Out 3/4", with an alias or name when either half has one.
pair_label :: proc(f: ^Interface_Config, dev: ^backend.Device_Info, output: bool, first: int, allocator := context.temp_allocator) -> string {
	num := fmt.tprintf("%s %d/%d", "Out" if output else "In", first + 1, first + 2)
	name := channel_alias(f, output, first)
	if name == "" && dev != nil {
		names := dev.output_channel_names if output else dev.input_channel_names
		if first < len(names) do name = names[first]
	}
	if name != "" do return fmt.aprintf("%s · %s", num, name, allocator = allocator)
	return strings.clone(num, allocator)
}

// The stereo pairs (first channels: 0, 2, 4...) both of whose channels are
// in `m`. Temporary allocator.
mask_pairs :: proc(m: backend.Channel_Mask) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for c := 0; c + 1 < 64; c += 2 do if c in m && c + 1 in m do append(&out, c)
	return out[:]
}

// "1,2,5,6": a mask's channels, 1-based.
mask_text :: proc(m: backend.Channel_Mask, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	first := true
	for c in m {
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_int(&b, c + 1)
	}
	return strings.to_string(b)
}

// A mask from "1,2,5,6" (1-based; out of range and junk skipped).
mask_parse :: proc(text: string) -> (m: backend.Channel_Mask) {
	for part in strings.split(text, ",", context.temp_allocator) {
		n, ok := strconv.parse_int(strings.trim_space(part))
		if ok && n >= 1 && n <= 64 do m += {n - 1}
	}
	return
}

// Reads every [audio.device.*] section into `c.interfaces`.
interfaces_load :: proc(c: ^Audio_Config, ini: ^app.Ini) {
	PREFIX :: "audio.device."
	for &sec in ini.sections do if strings.has_prefix(sec.name, PREFIX) {
		f := interface_for(c, sec.name[len(PREFIX):])
		g :: proc(sec: ^app.Ini_Section, key: string) -> (string, bool) {
			for e in sec.entries do if e.key == key do return e.value, true
			return "", false
		}
		if v, ok := g(&sec, "inputs"); ok do f.inputs = mask_parse(v)
		if v, ok := g(&sec, "outputs"); ok do f.outputs = mask_parse(v)
		if v, ok := g(&sec, "main"); ok do f.main = max((strconv.parse_int(v) or_else 1) - 1, 0) &~ 1
		if v, ok := g(&sec, "cue"); ok {
			n := strconv.parse_int(v) or_else 0
			f.cue = (n - 1) &~ 1 if n >= 1 else -1
		}
		for e in sec.entries {
			out := strings.has_prefix(e.key, "out.")
			if !out && !strings.has_prefix(e.key, "in.") do continue
			n, ok := strconv.parse_int(e.key[4 if out else 3:])
			if ok && n >= 1 && n <= 64 do set_channel_alias(f, out, n - 1, e.value)
		}
	}
}

// Writes `c.interfaces` as [audio.device.*] sections.
interfaces_save :: proc(c: ^Audio_Config, ini: ^app.Ini) {
	for &f in c.interfaces {
		sec := fmt.tprintf("audio.device.%s", f.id)
		app.ini_set(ini, sec, "inputs", mask_text(f.inputs))
		app.ini_set(ini, sec, "outputs", mask_text(f.outputs))
		app.ini_set_int(ini, sec, "main", f.main + 1)
		app.ini_set_int(ini, sec, "cue", f.cue + 1 if f.cue >= 0 else 0)
		// (Aliases: those set; any taken off are emptied.)
		s := app.ini_section(ini, sec)
		for &e in s.entries do if strings.has_prefix(e.key, "in.") || strings.has_prefix(e.key, "out.") {
			delete(e.value, ini.allocator)
			e.value = strings.clone("", ini.allocator)
		}
		for al in f.aliases do app.ini_set(ini, sec, fmt.tprintf("%s.%d", "out" if al.output else "in", al.channel + 1), al.name)
	}
}

// A deep copy (for the staged settings).
interfaces_clone :: proc(src: [dynamic]Interface_Config) -> [dynamic]Interface_Config {
	out := make([dynamic]Interface_Config, 0, len(src))
	for f in src {
		g := f
		g.id = strings.clone(f.id)
		g.aliases = make([dynamic]Channel_Alias, 0, len(f.aliases))
		for al in f.aliases do append(&g.aliases, Channel_Alias{al.output, al.channel, strings.clone(al.name)})
		append(&out, g)
	}
	return out
}

// Frees them.
interfaces_free :: proc(list: ^[dynamic]Interface_Config) {
	for &f in list {
		delete(f.id)
		for al in f.aliases do delete(al.name)
		delete(f.aliases)
	}
	delete(list^)
	list^ = nil
}

// Whether two lists say the same (the Apply button's "changed").
interfaces_equal :: proc(a, b: [dynamic]Interface_Config) -> bool {
	if len(a) != len(b) do return false
	for x, k in a {
		y := b[k]
		if x.id != y.id || x.inputs != y.inputs || x.outputs != y.outputs || x.main != y.main || x.cue != y.cue || len(x.aliases) != len(y.aliases) do return false
		for al, j in x.aliases do if al != y.aliases[j] do return false
	}
	return true
}

_ :: slice.sort

// The simulated driver's devices with --fake-interface: its own 2-in/2-out
// one, and an 8-in/8-out interface with named channels (for tests).
fake_interfaces := [?]fake.Device_Spec{
	{id = "fake:default", name = "Fake Device", input_channels = 2, output_channels = 2, sample_rates = FAKE_RATES[:], buffer_sizes = FAKE_SIZES[:], default_sample_rate = 48_000, default_buffer_frames = 256},
	{id = "fake:8x8", name = "Test Interface 8x8", input_channels = 8, output_channels = 8, sample_rates = FAKE_RATES[:], buffer_sizes = FAKE_SIZES[:], default_sample_rate = 48_000, default_buffer_frames = 256,
		input_names = {"Mic 1", "Mic 2", "Line 3", "Line 4", "", "", "S/PDIF L", "S/PDIF R"},
		output_names = {"Main L", "Main R", "Phones L", "Phones R", "", "", "", ""}},
}

@(private) FAKE_RATES := [?]f64{44_100, 48_000, 96_000}
@(private) FAKE_SIZES := [?]int{64, 128, 256, 512, 1024}

// The output interface's entry and its device (for names).
@(private)
output_interface :: proc(a: ^App) -> (^Interface_Config, ^backend.Device_Info) {
	s := &a.settings
	return interface_find(&s.audio, s.audio.output), find_device(s, s.audio.output, true)
}

// Whether route `d` is a direct out to a pair that isn't open now.
route_missing :: proc(a: ^App, d: int) -> bool {
	if !pm.is_out_dest(d) do return false
	first := 2 * (d - pm.OUT_DEST)
	return app.host_output_channel(&a.host, first) < 0 || app.host_output_channel(&a.host, first + 1) < 0
}

// A route's name: main, a bus, or a direct out by its pair's name ("Out
// 3/4 · Monitor B"); `long`: and what happens when its pair isn't open.
route_name :: proc(a: ^App, d: int, long := false) -> string {
	if !pm.is_out_dest(d) do return pm.bus_name(&a.m.project, d)
	f, dev := output_interface(a)
	name := pair_label(f, dev, true, 2 * (d - pm.OUT_DEST))
	if route_missing(a, d) do return fmt.tprintf("%s (not open%s)", name, ": it plays in main" if long else "")
	return name
}

// The output pairs open on the interface (not main's or the cue's), for a
// route menu; the one picked, if any.
out_pairs_menu :: proc(a: ^App, cur: int) -> (pick: int, ok: bool) {
	f, dev := output_interface(a)
	main_first, cue_first := 0, -1
	if f != nil do main_first, cue_first = f.main, f.cue
	pairs := mask_pairs(a.host.open_outputs)
	shown := 0
	for p in pairs do if p != main_first && p != cue_first do shown += 1
	missing := route_missing(a, cur)
	if shown == 0 && !missing do return
	im.SeparatorText("Direct outs")
	for p in pairs do if p != main_first && p != cue_first {
		d := pm.out_dest(p / 2)
		if im.MenuItem(fmt.ctprintf("%s###od%d", pair_label(f, dev, true, p), p), nil, d == cur) do pick, ok = d, true
	}
	if missing do im.MenuItem(fmt.ctprintf("%s###odmissing", route_name(a, cur)), nil, true, false)
	return
}

// Devices came or went: the list again; and when the interface the
// settings name was missing (the system's playing instead) and is back,
// it opens again, and says so.
on_devices_changed :: proc(a: ^App) {
	refresh_devices(a)
	s := &a.settings
	if !a.audio_fallback do return
	out_back := s.audio.output == "" || find_device(s, s.audio.output, true) != nil
	in_back := s.audio.input == "" || find_device(s, s.audio.input, false) != nil
	if !out_back || !in_back do return
	if audio_reopen(a) {
		a.audio_fallback = false
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s is back: playing through it", device_label(s, s.audio.output)))
	}
}

// A device's name ("System default" for "", its id if not listed).
@(private)
device_label :: proc(s: ^App_Settings, id: string) -> string {
	if id == "" do return "System default"
	if d := find_device(s, id, true); d != nil do return d.name
	if d := find_device(s, id, false); d != nil do return d.name
	return id
}
