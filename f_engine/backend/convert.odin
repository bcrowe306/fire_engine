package backend

import "base:intrinsics"

// Integer full-scale values. Float → int conversion rounds to nearest and clips
// to [-full_scale, full_scale - 1]; int → float divides by full_scale, so
// -full_scale maps to exactly -1.
@(private) I16_SCALE :: 32768.0
@(private) I24_SCALE :: 8388608.0
@(private) I32_SCALE :: 2147483648.0

// [rt] Reads len(dst) samples starting at `src`, `stride` bytes apart.
read_samples :: proc "contextless" (dst: []f32, src: rawptr, stride: int, format: Sample_Format) {
	p := ([^]u8)(src)
	switch format {
	case .F32:
		for &d, i in dst do d = intrinsics.unaligned_load((^f32)(&p[i * stride]))
	case .F64:
		for &d, i in dst do d = f32(intrinsics.unaligned_load((^f64)(&p[i * stride])))
	case .I16:
		for &d, i in dst do d = f32(f64(intrinsics.unaligned_load((^i16)(&p[i * stride]))) / I16_SCALE)
	case .I24:
		for &d, i in dst {
			b := p[i * stride:]
			u := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16
			d = f32(f64(i32(u << 8) >> 8) / I24_SCALE)
		}
	case .I32:
		for &d, i in dst do d = f32(f64(intrinsics.unaligned_load((^i32)(&p[i * stride]))) / I32_SCALE)
	case .I24_In_32:
		for &d, i in dst {
			u := intrinsics.unaligned_load((^u32)(&p[i * stride]))
			d = f32(f64(i32(u << 8) >> 8) / I24_SCALE)
		}
	}
}

// [rt] Writes len(src) samples starting at `dst`, `stride` bytes apart.
write_samples :: proc "contextless" (src: []f32, dst: rawptr, stride: int, format: Sample_Format) {
	p := ([^]u8)(dst)
	switch format {
	case .F32:
		for s, i in src do intrinsics.unaligned_store((^f32)(&p[i * stride]), s)
	case .F64:
		for s, i in src do intrinsics.unaligned_store((^f64)(&p[i * stride]), f64(s))
	case .I16:
		for s, i in src do intrinsics.unaligned_store((^i16)(&p[i * stride]), i16(quantize(s, I16_SCALE)))
	case .I24:
		for s, i in src {
			v := u32(i32(quantize(s, I24_SCALE)))
			b := p[i * stride:]
			b[0] = u8(v)
			b[1] = u8(v >> 8)
			b[2] = u8(v >> 16)
		}
	case .I32:
		for s, i in src do intrinsics.unaligned_store((^i32)(&p[i * stride]), i32(quantize(s, I32_SCALE)))
	case .I24_In_32:
		for s, i in src do intrinsics.unaligned_store((^i32)(&p[i * stride]), i32(quantize(s, I24_SCALE)))
	}
}

// [rt] Rounds to nearest, clips to the integer range. NaN becomes 0.
@(private)
quantize :: #force_inline proc "contextless" (s: f32, scale: f64) -> i64 {
	x := f64(s) * scale
	if !(x == x) do return 0
	x = clamp(x, -scale, scale - 1)
	return i64(x + 0.5 if x >= 0 else x - 0.5)
}
