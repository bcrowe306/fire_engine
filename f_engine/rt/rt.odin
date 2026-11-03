// Realtime-thread utilities. Everything here is [rt]-safe unless noted.
package rt

// Saved floating-point control register state, returned by
// `enable_flush_to_zero` and passed back to `restore_fp_state`.
FP_State :: distinct u64

// [rt] Enable flush-to-zero (and denormals-are-zero on x86) for the calling
// thread. Returns the previous state so it can be restored.
enable_flush_to_zero :: proc "contextless" () -> FP_State {
	prev := fp_control_get()
	fp_control_set(prev | FP_FTZ_BITS)
	return FP_State(prev)
}

// [rt] Restores the calling thread's floating-point control state saved by
// `enable_flush_to_zero`.
restore_fp_state :: proc "contextless" (s: FP_State) {
	fp_control_set(u64(s))
}

// [rt] Reports whether flush-to-zero (and DAZ on x86) is on for the calling
// thread. Always false on architectures without support.
flush_to_zero_enabled :: proc "contextless" () -> bool {
	return FP_FTZ_BITS != 0 && fp_control_get() & FP_FTZ_BITS == FP_FTZ_BITS
}
