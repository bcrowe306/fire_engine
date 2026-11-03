// Realtime-thread utilities. Everything here is [rt]-safe unless noted.
package rt

FP_State :: distinct u64

// [rt] Enable flush-to-zero (and denormals-are-zero on x86) for the calling
// thread. Returns the previous state so it can be restored.
enable_flush_to_zero :: proc "contextless" () -> FP_State {
	prev := fp_control_get()
	fp_control_set(prev | FP_FTZ_BITS)
	return FP_State(prev)
}

// [rt]
restore_fp_state :: proc "contextless" (s: FP_State) {
	fp_control_set(u64(s))
}

// [rt]
flush_to_zero_enabled :: proc "contextless" () -> bool {
	return FP_FTZ_BITS != 0 && fp_control_get() & FP_FTZ_BITS == FP_FTZ_BITS
}
