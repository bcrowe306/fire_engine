// Raw bindings to our C wrapper around Signalsmith Stretch
// (f_engine/sys/signalsmith/wrapper.cpp, vendor/signalsmith). No logic.
// Build the library with scripts/stretch.sh.
package signalsmith_sys

when ODIN_OS == .Windows {
	foreign import lib "lib/fire_signalsmith.lib"
} else when ODIN_OS == .Darwin {
	foreign import lib {"lib/libfire_signalsmith.a", "system:c++"}
} else {
	foreign import lib {"lib/libfire_signalsmith.a", "system:stdc++", "system:m"}
}

// One stretcher instance (opaque).
Stretch :: struct {}

@(default_calling_convention = "c", link_prefix = "fss_")
foreign lib {
	create         :: proc(channels: i32, sample_rate: f32, max_rate: f32) -> ^Stretch ---
	destroy        :: proc(s: ^Stretch) ---
	input_latency  :: proc(s: ^Stretch) -> i32 ---
	output_latency :: proc(s: ^Stretch) -> i32 ---
	reset          :: proc(s: ^Stretch) ---
	output_seek    :: proc(s: ^Stretch, input: [^][^]f32, frames: i32) ---
	process        :: proc(s: ^Stretch, input: [^][^]f32, in_frames: i32, output: [^][^]f32, out_frames: i32) ---
}
