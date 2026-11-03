#+build arm64
package rt

// FPCR.FZ: flush denormal inputs and outputs to zero.
@(private) FP_FTZ_BITS :: u64(1) << 24

@(private)
fp_control_get :: #force_inline proc "contextless" () -> u64 {
	return asm() -> (r: u64) { mrs r, %fpcr }()
}

@(private)
fp_control_set :: #force_inline proc "contextless" (v: u64) {
	asm(v: u64) [#volatile] { msr %fpcr, v }(v)
}
