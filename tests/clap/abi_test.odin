package test_clap

import "core:dynlib"
import "core:testing"

import c "fire:sys/clap"

// The test plug-in's binary inside its bundle (macOS) or the file itself.
plugin_binary :: proc() -> string {
	when ODIN_OS == .Darwin {
		return #directory + "/../../.build/clap/FireTest.clap/Contents/MacOS/FireTest"
	} else {
		return #directory + "/../../.build/clap/FireTest.clap"
	}
}

// What Odin makes of each struct and field the C plug-in reports.
Layout :: struct { name: string, value: uintptr }

odin_layouts := [?]Layout {
	{"clap_version_t", size_of(c.Version)},
	{"clap_plugin_entry_t", size_of(c.Plugin_Entry)},
	{"clap_plugin_factory_t", size_of(c.Plugin_Factory)},
	{"clap_plugin_descriptor_t", size_of(c.Plugin_Descriptor)},
	{"clap_plugin_descriptor_t.features", offset_of(c.Plugin_Descriptor, features)},
	{"clap_host_t", size_of(c.Host)},
	{"clap_host_t.get_extension", offset_of(c.Host, get_extension)},
	{"clap_host_t.request_callback", offset_of(c.Host, request_callback)},
	{"clap_plugin_t", size_of(c.Plugin)},
	{"clap_plugin_t.process", offset_of(c.Plugin, process)},
	{"clap_plugin_t.on_main_thread", offset_of(c.Plugin, on_main_thread)},
	{"clap_process_t", size_of(c.Process)},
	{"clap_process_t.transport", offset_of(c.Process, transport)},
	{"clap_process_t.audio_outputs_count", offset_of(c.Process, audio_outputs_count)},
	{"clap_process_t.out_events", offset_of(c.Process, out_events)},
	{"clap_audio_buffer_t", size_of(c.Audio_Buffer)},
	{"clap_audio_buffer_t.constant_mask", offset_of(c.Audio_Buffer, constant_mask)},
	{"clap_event_header_t", size_of(c.Event_Header)},
	{"clap_event_note_t", size_of(c.Event_Note)},
	{"clap_event_note_t.key", offset_of(c.Event_Note, key)},
	{"clap_event_note_t.velocity", offset_of(c.Event_Note, velocity)},
	{"clap_event_note_expression_t", size_of(c.Event_Note_Expression)},
	{"clap_event_note_expression_t.value", offset_of(c.Event_Note_Expression, value)},
	{"clap_event_param_value_t", size_of(c.Event_Param_Value)},
	{"clap_event_param_value_t.cookie", offset_of(c.Event_Param_Value, cookie)},
	{"clap_event_param_value_t.value", offset_of(c.Event_Param_Value, value)},
	{"clap_event_param_mod_t", size_of(c.Event_Param_Mod)},
	{"clap_event_param_gesture_t", size_of(c.Event_Param_Gesture)},
	{"clap_event_transport_t", size_of(c.Event_Transport)},
	{"clap_event_transport_t.tempo_inc", offset_of(c.Event_Transport, tempo_inc)},
	{"clap_event_transport_t.bar_number", offset_of(c.Event_Transport, bar_number)},
	{"clap_event_transport_t.tsig_denom", offset_of(c.Event_Transport, tsig_denom)},
	{"clap_event_midi_t", size_of(c.Event_Midi)},
	{"clap_event_midi_t.data", offset_of(c.Event_Midi, data)},
	{"clap_event_midi_sysex_t", size_of(c.Event_Midi_Sysex)},
	{"clap_event_midi2_t", size_of(c.Event_Midi2)},
	{"clap_input_events_t", size_of(c.Input_Events)},
	{"clap_output_events_t", size_of(c.Output_Events)},
	{"clap_istream_t", size_of(c.Istream)},
	{"clap_ostream_t", size_of(c.Ostream)},
	{"clap_param_info_t", size_of(c.Param_Info)},
	{"clap_param_info_t.cookie", offset_of(c.Param_Info, cookie)},
	{"clap_param_info_t.module", offset_of(c.Param_Info, module)},
	{"clap_param_info_t.default_value", offset_of(c.Param_Info, default_value)},
	{"clap_plugin_params_t", size_of(c.Plugin_Params)},
	{"clap_host_params_t", size_of(c.Host_Params)},
	{"clap_audio_port_info_t", size_of(c.Audio_Port_Info)},
	{"clap_audio_port_info_t.port_type", offset_of(c.Audio_Port_Info, port_type)},
	{"clap_audio_port_info_t.in_place_pair", offset_of(c.Audio_Port_Info, in_place_pair)},
	{"clap_plugin_audio_ports_t", size_of(c.Plugin_Audio_Ports)},
	{"clap_note_port_info_t", size_of(c.Note_Port_Info)},
	{"clap_plugin_note_ports_t", size_of(c.Plugin_Note_Ports)},
	{"clap_plugin_latency_t", size_of(c.Plugin_Latency)},
	{"clap_plugin_tail_t", size_of(c.Plugin_Tail)},
	{"clap_plugin_state_t", size_of(c.Plugin_State)},
	{"clap_window_t", size_of(c.Window)},
	{"clap_gui_resize_hints_t", size_of(c.Gui_Resize_Hints)},
	{"clap_gui_resize_hints_t.aspect_ratio_width", offset_of(c.Gui_Resize_Hints, aspect_ratio_width)},
	{"clap_plugin_gui_t", size_of(c.Plugin_Gui)},
	{"clap_plugin_gui_t.hide", offset_of(c.Plugin_Gui, hide)},
	{"clap_host_gui_t", size_of(c.Host_Gui)},
	{"clap_host_thread_check_t", size_of(c.Host_Thread_Check)},
	{"clap_host_log_t", size_of(c.Host_Log)},
}

// Every struct and field the C compiler lays out from CLAP's headers has the
// same size and offset in fire:sys/clap.
@(test)
bindings_match_the_c_abi :: proc(t: ^testing.T) {
	lib, ok := dynlib.load_library(plugin_binary())
	if !testing.expectf(t, ok, "load %s", plugin_binary()) do return
	defer dynlib.unload_library(lib)
	layout := cast(proc "c" (index: i32, name: ^cstring, is_offset: ^i32, value: ^u64) -> i32)dynlib.symbol_address(lib, "fire_clap_layout")
	if !testing.expect(t, layout != nil, "fire_clap_layout") do return
	checked := 0
	for i: i32 = 0; ; i += 1 {
		name: cstring
		is_offset: i32
		value: u64
		if layout(i, &name, &is_offset, &value) == 0 do break
		odin, known := uintptr(0), false
		for l in odin_layouts do if l.name == string(name) do odin, known = l.value, true
		if !testing.expectf(t, known, "%s: not in the Odin table", name) do continue
		testing.expectf(t, u64(odin) == value, "%s: C says %d, Odin %d", name, value, odin)
		checked += 1
	}
	testing.expect_value(t, checked, len(odin_layouts))
}
