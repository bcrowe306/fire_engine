#+build amd64, i386
package rt

import "core:simd/x86"

// MXCSR.FTZ (bit 15) | MXCSR.DAZ (bit 6)
@(private) FP_FTZ_BITS :: u64(1) << 15 | u64(1) << 6

@(private, enable_target_feature="sse")
fp_control_get :: proc "contextless" () -> u64 {
	return u64(x86._mm_getcsr())
}

@(private, enable_target_feature="sse")
fp_control_set :: proc "contextless" (v: u64) {
	x86._mm_setcsr(u32(v))
}
