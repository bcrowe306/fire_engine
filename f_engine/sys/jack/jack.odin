// JACK client API (jack/jack.h), loaded at run time so programs work where
// JACK is not installed. Only what fire:backend/jack uses. No logic.
package jack_sys

import "core:c"
import "core:dynlib"

jack_nframes_t :: u32
jack_time_t    :: u64 // microseconds

JackNullOption    :: c.int(0x00)
JackNoStartServer :: c.int(0x01)
JackServerName    :: c.int(0x04) // the next vararg is the server name

JackPortIsInput    :: c.ulong(0x1)
JackPortIsOutput   :: c.ulong(0x2)
JackPortIsPhysical :: c.ulong(0x4)

JACK_DEFAULT_AUDIO_TYPE :: "32 bit float mono audio"

Process_Callback      :: #type proc "c" (nframes: jack_nframes_t, arg: rawptr) -> c.int
Xrun_Callback         :: #type proc "c" (arg: rawptr) -> c.int
Shutdown_Callback     :: #type proc "c" (arg: rawptr)
Registration_Callback :: #type proc "c" (port_id: u32, register: c.int, arg: rawptr)
Buffer_Size_Callback  :: #type proc "c" (nframes: jack_nframes_t, arg: rawptr) -> c.int
Client_Registration_Callback :: #type proc "c" (name: cstring, register: c.int, arg: rawptr)
Message_Function      :: #type proc "c" (message: cstring)

Api :: struct {
	lib: dynlib.Library,

	client_open:     proc "c" (name: cstring, options: c.int, status: ^c.int, #c_vararg args: ..any) -> rawptr,
	client_close:    proc "c" (client: rawptr) -> c.int,
	get_sample_rate: proc "c" (client: rawptr) -> jack_nframes_t,
	get_buffer_size: proc "c" (client: rawptr) -> jack_nframes_t,
	activate:        proc "c" (client: rawptr) -> c.int,
	deactivate:      proc "c" (client: rawptr) -> c.int,

	port_register:   proc "c" (client: rawptr, name: cstring, type: cstring, flags: c.ulong, buffer_size: c.ulong) -> rawptr,
	port_unregister: proc "c" (client: rawptr, port: rawptr) -> c.int,
	port_get_buffer: proc "c" (port: rawptr, nframes: jack_nframes_t) -> rawptr,
	port_name:       proc "c" (port: rawptr) -> cstring,
	get_ports:       proc "c" (client: rawptr, name_pattern: cstring, type_pattern: cstring, flags: c.ulong) -> [^]cstring,
	connect:         proc "c" (client: rawptr, source: cstring, destination: cstring) -> c.int,
	free:            proc "c" (ptr: rawptr),

	set_process_callback:           proc "c" (client: rawptr, cb: Process_Callback, arg: rawptr) -> c.int,
	set_xrun_callback:              proc "c" (client: rawptr, cb: Xrun_Callback, arg: rawptr) -> c.int,
	on_shutdown:                    proc "c" (client: rawptr, cb: Shutdown_Callback, arg: rawptr),
	set_port_registration_callback: proc "c" (client: rawptr, cb: Registration_Callback, arg: rawptr) -> c.int,
	set_buffer_size_callback:       proc "c" (client: rawptr, cb: Buffer_Size_Callback, arg: rawptr) -> c.int,
	set_client_registration_callback: proc "c" (client: rawptr, cb: Client_Registration_Callback, arg: rawptr) -> c.int,
	set_error_function:             proc "c" (fn: Message_Function),
	set_info_function:              proc "c" (fn: Message_Function),

	get_time:        proc "c" () -> jack_time_t,
	get_cycle_times: proc "c" (client: rawptr, current_frames: ^jack_nframes_t, current_usecs: ^jack_time_t, next_usecs: ^jack_time_t, period_usecs: ^f32) -> c.int,
}

when ODIN_OS == .Windows {
	LIBRARY_NAMES :: []string{"libjack64.dll"}
} else when ODIN_OS == .Darwin {
	LIBRARY_NAMES :: []string{"libjack.0.dylib", "/usr/local/lib/libjack.0.dylib", "/opt/homebrew/lib/libjack.0.dylib"}
} else {
	LIBRARY_NAMES :: []string{"libjack.so.0", "libjack.so"}
}

// Loads libjack and resolves every function. False if JACK is not installed.
load :: proc(api: ^Api) -> bool {
	for name in LIBRARY_NAMES {
		if lib, ok := dynlib.load_library(name); ok {
			api.lib = lib
			break
		}
	}
	if api.lib == nil do return false
	sym :: proc(api: ^Api, name: string) -> rawptr { return dynlib.symbol_address(api.lib, name) }
	api.client_open = auto_cast sym(api, "jack_client_open")
	api.client_close = auto_cast sym(api, "jack_client_close")
	api.get_sample_rate = auto_cast sym(api, "jack_get_sample_rate")
	api.get_buffer_size = auto_cast sym(api, "jack_get_buffer_size")
	api.activate = auto_cast sym(api, "jack_activate")
	api.deactivate = auto_cast sym(api, "jack_deactivate")
	api.port_register = auto_cast sym(api, "jack_port_register")
	api.port_unregister = auto_cast sym(api, "jack_port_unregister")
	api.port_get_buffer = auto_cast sym(api, "jack_port_get_buffer")
	api.port_name = auto_cast sym(api, "jack_port_name")
	api.get_ports = auto_cast sym(api, "jack_get_ports")
	api.connect = auto_cast sym(api, "jack_connect")
	api.free = auto_cast sym(api, "jack_free")
	api.set_process_callback = auto_cast sym(api, "jack_set_process_callback")
	api.set_xrun_callback = auto_cast sym(api, "jack_set_xrun_callback")
	api.on_shutdown = auto_cast sym(api, "jack_on_shutdown")
	api.set_port_registration_callback = auto_cast sym(api, "jack_set_port_registration_callback")
	api.set_buffer_size_callback = auto_cast sym(api, "jack_set_buffer_size_callback")
	api.set_client_registration_callback = auto_cast sym(api, "jack_set_client_registration_callback")
	api.set_error_function = auto_cast sym(api, "jack_set_error_function")
	api.set_info_function = auto_cast sym(api, "jack_set_info_function")
	api.get_time = auto_cast sym(api, "jack_get_time")
	api.get_cycle_times = auto_cast sym(api, "jack_get_cycle_times")
	ok := api.client_open != nil && api.client_close != nil && api.activate != nil && api.port_register != nil &&
	      api.port_get_buffer != nil && api.set_process_callback != nil && api.get_ports != nil && api.connect != nil &&
	      api.get_time != nil && api.get_cycle_times != nil && api.free != nil
	if !ok {
		dynlib.unload_library(api.lib)
		api^ = {}
	}
	return ok
}
