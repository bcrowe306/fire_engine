package link

import "core:math"

// Points kept by the host-time filter (about 3 s of 512-frame blocks at 48 kHz).
@(private)
FILTER_POINTS :: 256

// A least-squares line through recent (frame, host time) pairs. Devices
// timestamp blocks with some jitter; asking Link for the beat at a jittery
// time would shake the grid by the same amount. Restarts after a jump of more
// than 2 ms (an xrun or a device restart).
@(private)
Host_Time_Filter :: struct {
	frame0: i64, // origin, so the sums stay well inside f64 precision
	ns0:    i64,
	xs:     [FILTER_POINTS]f64,
	ys:     [FILTER_POINTS]f64,
	count:  int,
	next:   int,
}

// [rt] Adds a measurement and returns the filtered host time of `frame`.
@(private)
filter_add :: proc "contextless" (f: ^Host_Time_Filter, frame: i64, host_ns: u64) -> u64 {
	if f.count == 0 do f.frame0, f.ns0 = frame, i64(host_ns)
	x := f64(frame - f.frame0)
	y := f64(i64(host_ns) - f.ns0)
	if f.count >= 8 {
		if fit := filter_fit(f, x); abs(y - fit) > 2e6 {
			f.count, f.next = 0, 0
			return filter_add(f, frame, host_ns)
		}
	}
	f.xs[f.next], f.ys[f.next] = x, y
	f.next = (f.next + 1) % FILTER_POINTS
	f.count = min(f.count + 1, FILTER_POINTS)
	if f.count < 8 do return host_ns
	return u64(f.ns0 + i64(math.round(filter_fit(f, x))))
}

@(private)
filter_fit :: proc "contextless" (f: ^Host_Time_Filter, x: f64) -> f64 {
	n := f64(f.count)
	mx, my: f64
	for i in 0 ..< f.count do mx, my = mx + f.xs[i], my + f.ys[i]
	mx, my = mx / n, my / n
	sxy, sxx: f64
	for i in 0 ..< f.count {
		dx := f.xs[i] - mx
		sxy += dx * (f.ys[i] - my)
		sxx += dx * dx
	}
	if sxx == 0 do return my
	return my + sxy / sxx * (x - mx)
}
