#+build !arm64
#+build !amd64
#+build !i386
package rt

@(private) FP_FTZ_BITS :: u64(0)

@(private)
fp_control_get :: #force_inline proc "contextless" () -> u64 { return 0 }

@(private)
fp_control_set :: #force_inline proc "contextless" (v: u64) {}
