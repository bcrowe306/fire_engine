#+build darwin
// CoreAudio driver tests. Layout and clock tests always run on macOS. Device
// tests use only BlackHole 2ch (a virtual loopback device) and pass as skipped
// when it is not installed, as on CI. They never open speakers or microphones.
package test_coreaudio

import "base:intrinsics"
import "core:log"
import "core:c"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "fire:backend"
import cad "fire:backend/coreaudio"
import "fire:core"
import ca "fire:sys/coreaudio"
import kit "fire:testkit"

// Device tests share one physical device, so they run one at a time: a mutex
// within this process, and a lock file across processes (test.sh runs the
// package once per optimization level, concurrently). POSIX record locks
// belong to the process, hence both. The OS drops the file lock if we crash.
blackhole_mutex: sync.Mutex

blackhole_lock :: proc() -> posix.FD {
	sync.mutex_lock(&blackhole_mutex)
	fd := posix.open("/tmp/fire_engine_blackhole.lock", {.CREAT, .RDWR}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd >= 0 {
		lock := posix.flock{l_type = .WRLCK, l_whence = c.short(posix.Whence.SET)}
		posix.fcntl(fd, .SETLKW, &lock)
	}
	return fd
}

blackhole_unlock :: proc(fd: posix.FD) {
	if fd >= 0 do posix.close(fd) // closing releases the record lock
	sync.mutex_unlock(&blackhole_mutex)
}

@(test)
struct_layouts_match_sdk :: proc(t: ^testing.T) {
	// Values printed by a C program against the macOS SDK.
	testing.expect_value(t, size_of(ca.AudioTimeStamp), 64)
	testing.expect_value(t, offset_of(ca.AudioTimeStamp, mHostTime), 8)
	testing.expect_value(t, offset_of(ca.AudioTimeStamp, mFlags), 56)
	testing.expect_value(t, size_of(ca.AudioBuffer), 16)
	testing.expect_value(t, size_of(ca.AudioBufferList), 24)
	testing.expect_value(t, offset_of(ca.AudioBufferList, mBuffers), 8)
	testing.expect_value(t, size_of(ca.AudioObjectPropertyAddress), 12)
	testing.expect_value(t, size_of(ca.AudioValueRange), 16)
}

@(test)
host_clock_matches_coreaudio :: proc(t: ^testing.T) {
	ours := backend.host_time_ns()
	theirs := ca.AudioConvertHostTimeToNanos(ca.AudioGetCurrentHostTime())
	diff := abs(i64(theirs) - i64(ours))
	testing.expectf(t, diff < 1_000_000, "host_time_ns and CoreAudio host time differ by %d ns", diff)
}

@(test)
enumerate_devices :: proc(t: ^testing.T) {
	d := cad.create()
	defer backend.driver_destroy(d)
	infos, err := backend.driver_enumerate(d)
	defer backend.device_infos_destroy(infos)
	testing.expect_value(t, err, core.Error.None)
	testing.expect(t, len(infos) > 0, "no audio devices")
	defaults := 0
	for info, i in infos {
		testing.expectf(t, info.id != "", "device %d has no UID", i)
		testing.expectf(t, info.default_sample_rate > 0, "%s: no sample rate", info.name)
		testing.expectf(t, len(info.sample_rates) > 0, "%s: no sample rates", info.name)
		if info.is_default_output do defaults += 1
		for other in infos[i + 1:] do testing.expectf(t, info.id != other.id, "duplicate UID %s", info.id)
		log.infof("%-28s in %2d out %2d  %v Hz  %d frames", info.name, info.input_channels, info.output_channels, info.default_sample_rate, info.default_buffer_frames)
	}
	testing.expect(t, defaults <= 1)
}

// --- BlackHole ------------------------------------------------------------------------

find_blackhole :: proc(t: ^testing.T, d: ^backend.Driver) -> (id: string, rate: f64, ok: bool) {
	infos, _ := backend.driver_enumerate(d, context.temp_allocator)
	for info in infos {
		if strings.contains(info.name, "BlackHole") && info.input_channels >= 2 && info.output_channels >= 2 {
			return info.id, info.default_sample_rate, true
		}
	}
	log.info("BlackHole 2ch not installed; skipping device test")
	return "", 0, false
}

Recorder :: struct {
	play:            []f32, // mono source, played on both outputs
	rec:             [2][]f32,
	next_time:       i64,
	gaps:            int,
	blocks:          u64, // atomic
	xrun_blocks:     int,
	max_entry_skew:  i64, // host_time_ns() at entry − block.callback_ns
	time_order_bad:  int, // input_ns ≤ callback_ns ≤ output_ns violated
	last_output_ns:  u64,
	non_monotonic:   int,
}

// [rt]
recorder_process :: proc(user: rawptr, b: ^backend.Io_Block) {
	r := (^Recorder)(user)
	entry := backend.host_time_ns()
	if b.sample_time != r.next_time do r.gaps += 1
	r.next_time = b.sample_time + i64(b.frames)
	if b.xrun do r.xrun_blocks += 1
	r.max_entry_skew = max(r.max_entry_skew, abs(i64(entry) - i64(b.callback_ns)))
	if !(b.input_ns <= b.callback_ns && b.callback_ns <= b.output_ns) do r.time_order_bad += 1
	if b.output_ns <= r.last_output_ns do r.non_monotonic += 1
	r.last_output_ns = b.output_ns
	for out in b.outputs {
		for &s, i in out {
			t := int(b.sample_time) + i
			s = r.play[t] if t < len(r.play) else 0
		}
	}
	for input, c in b.inputs {
		for s, i in input {
			t := int(b.sample_time) + i
			if c < 2 && t < len(r.rec[c]) do r.rec[c][t] = s
		}
	}
	intrinsics.atomic_add(&r.blocks, 1)
}

recorder_callback :: proc(r: ^Recorder) -> backend.Device_Callback {
	return {process = recorder_process, user = r}
}

wait_for :: proc(cond: proc(user: rawptr) -> bool, user: rawptr, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for !cond(user) {
		if time.tick_since(start) > timeout do return false
		time.sleep(time.Millisecond)
	}
	return true
}

@(test)
blackhole_loopback_is_bit_exact :: proc(t: ^testing.T) {
	lock := blackhole_lock()
	defer blackhole_unlock(lock)
	testing.set_fail_timeout(t, 30 * time.Second)

	d := cad.create()
	defer backend.driver_destroy(d)
	id, rate, found := find_blackhole(t, d)
	if !found do return

	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	trap: kit.Trap_Allocator
	dev.rt_allocator = kit.trap_allocator(&trap)

	setup := backend.Device_Setup{output_device_id = id, input_device_id = id, sample_rate = rate, buffer_frames = 256, input_channels = {0, 1}, output_channels = {0, 1}}
	if err := backend.device_open(&dev, setup, 100); err != .None { // 100: forces uneven splitting
		testing.expectf(t, false, "open BlackHole: %v", err)
		return
	}
	f := dev.format
	log.infof("BlackHole: %v Hz, %d frames, latency in %d out %d", f.sample_rate, f.buffer_frames, f.input_latency_frames, f.output_latency_frames)

	FRAMES :: 72_000 // 1.5 s at 48 kHz
	r: Recorder
	r.play = make([]f32, FRAMES, context.temp_allocator)
	for &c in r.rec do c = make([]f32, FRAMES, context.temp_allocator)
	kit.white_noise(r.play[:FRAMES / 2], 31, 0.5) // noise, then silence

	testing.expect_value(t, backend.device_start(&dev, recorder_callback(&r)), core.Error.None)
	done := wait_for(proc(u: rawptr) -> bool {
		r := (^Recorder)(u)
		return intrinsics.atomic_load(&r.next_time) >= FRAMES
	}, &r, 10 * time.Second)
	backend.device_stop(&dev)
	testing.expect(t, done, "BlackHole did not deliver 1.5 s of audio within 10 s")
	stats := backend.device_stats(&dev)

	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.time_order_bad, 0)
	testing.expect_value(t, r.non_monotonic, 0)
	testing.expectf(t, r.max_entry_skew < 5_000_000, "callback_ns is %d ns from host_time_ns at entry", r.max_entry_skew)
	testing.expectf(t, stats.xruns == 0, "%d xruns (machine busy?)", stats.xruns)

	latency := kit.estimate_latency(r.play[:FRAMES / 2], r.rec[0][:FRAMES / 2], FRAMES / 4)
	log.infof("measured round trip %d frames (%.2f ms); %d callbacks, peak load %.3f", latency, f64(latency) * 1000 / f.sample_rate, stats.callbacks, stats.peak_load)
	testing.expect(t, latency > 0 && latency < FRAMES / 4, "no loopback signal found")
	// BlackHole has its own output and input volume controls (macOS may have
	// turned them down). At 100% the loopback must be bit-exact; otherwise it
	// must be exactly the input times one constant gain.
	unity := volume_scalar(id, ca.kAudioObjectPropertyScopeOutput) == 1 && volume_scalar(id, ca.kAudioObjectPropertyScopeInput) == 1
	n := FRAMES / 2 - latency
	for c in 0 ..< 2 {
		played, recorded := r.play[:n], r.rec[c][latency:][:n]
		pp, pr: f64
		for i in 0 ..< n {
			pp += f64(played[i]) * f64(played[i])
			pr += f64(played[i]) * f64(recorded[i])
		}
		gain := pr / pp
		worst, worst_at := 0.0, 0
		for i in 0 ..< n {
			e := abs(f64(recorded[i]) - gain * f64(played[i]))
			if e > worst do worst, worst_at = e, i
		}
		if c == 0 do log.infof("BlackHole gain %.4f (%.2f dB)%s", gain, kit.linear_to_db(gain), "" if unity else " (its volume controls are below 100%)")
		testing.expectf(t, worst <= 1e-6, "ch%d: recording is not a scaled copy of the input: residual %v at %d", c, worst, worst_at)
		if unity {
			cmp := kit.compare_slices(played, recorded)
			testing.expectf(t, cmp.max_abs_error == 0, "ch%d: loopback at unity volume not bit-exact: %v at %d", c, cmp.max_abs_error, cmp.max_error_at)
		}
	}
}

volume_scalar :: proc(uid: string, scope: u32) -> f32 {
	id := device_object(uid)
	a := ca.AudioObjectPropertyAddress{ca.kAudioDevicePropertyVolumeScalar, scope, ca.kAudioObjectPropertyElementMain}
	if ca.AudioObjectHasProperty(id, &a) == 0 do return 1 // no volume control: unity
	v: f32
	size := u32(size_of(v))
	if ca.AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) != ca.NO_ERR do return 1
	return v
}

device_object :: proc(uid: string) -> ca.AudioObjectID {
	a := ca.AudioObjectPropertyAddress{ca.kAudioHardwarePropertyDevices, ca.kAudioObjectPropertyScopeGlobal, ca.kAudioObjectPropertyElementMain}
	ids: [128]ca.AudioObjectID
	size := u32(size_of(ids))
	ca.AudioObjectGetPropertyData(ca.kAudioObjectSystemObject, &a, 0, nil, &size, &ids)
	for id in ids[:size / size_of(ca.AudioObjectID)] {
		ua := ca.AudioObjectPropertyAddress{ca.kAudioDevicePropertyDeviceUID, ca.kAudioObjectPropertyScopeGlobal, ca.kAudioObjectPropertyElementMain}
		ref: ca.CFStringRef
		rs := u32(size_of(ref))
		if ca.AudioObjectGetPropertyData(id, &ua, 0, nil, &rs, &ref) != ca.NO_ERR do continue
		buf: [256]u8
		ok := CF.StringGetCString(ref, &buf[0], len(buf), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8))
		CF.CFRelease(CF.TypeRef(ref))
		if ok && string(cstring(&buf[0])) == uid do return id
	}
	return ca.kAudioObjectUnknown
}

@(test)
blackhole_start_stop_cycles :: proc(t: ^testing.T) {
	lock := blackhole_lock()
	defer blackhole_unlock(lock)
	testing.set_fail_timeout(t, 30 * time.Second)

	d := cad.create()
	defer backend.driver_destroy(d)
	id, _, found := find_blackhole(t, d)
	if !found do return

	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	setup := backend.Device_Setup{output_device_id = id, buffer_frames = 128, output_channels = {0, 1}}
	if err := backend.device_open(&dev, setup, 512); err != .None {
		testing.expectf(t, false, "open BlackHole: %v", err)
		return
	}
	r: Recorder
	for cycle in 0 ..< 10 {
		r.next_time = 0
		before := intrinsics.atomic_load(&r.blocks)
		testing.expect_value(t, backend.device_start(&dev, recorder_callback(&r)), core.Error.None)
		ok := wait_for(proc(u: rawptr) -> bool {
			r := (^Recorder)(u)
			return intrinsics.atomic_load(&r.next_time) >= 128 * 10
		}, &r, 5 * time.Second)
		backend.device_stop(&dev)
		testing.expectf(t, ok, "cycle %d: no callbacks", cycle)
		after := intrinsics.atomic_load(&r.blocks)
		time.sleep(20 * time.Millisecond)
		testing.expectf(t, intrinsics.atomic_load(&r.blocks) == after, "cycle %d: callback after stop", cycle)
		testing.expect(t, after > before)
	}
	testing.expect_value(t, r.gaps, 0)
}

@(test)
blackhole_rate_change_is_reported :: proc(t: ^testing.T) {
	lock := blackhole_lock()
	defer blackhole_unlock(lock)
	testing.set_fail_timeout(t, 30 * time.Second)

	d := cad.create()
	defer backend.driver_destroy(d)
	id, original_rate, found := find_blackhole(t, d)
	if !found do return
	other_rate := 44_100.0 if original_rate != 44_100 else 48_000
	defer cad_set_rate(t, id, original_rate) // leave BlackHole as we found it

	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)

	// Opening at another rate changes the device (and leaves it changed).
	setup := backend.Device_Setup{output_device_id = id, sample_rate = other_rate, output_channels = {0, 1}}
	if err := backend.device_open(&dev, setup, 512); err != .None {
		testing.expectf(t, false, "open BlackHole at %v: %v", other_rate, err)
		return
	}
	testing.expect_value(t, dev.format.sample_rate, other_rate)

	// Someone else changes it back while we have it open: Format_Changed.
	cad_set_rate(t, id, original_rate)
	got := false
	start := time.tick_now()
	for !got && time.tick_since(start) < 3 * time.Second {
		for e in backend.device_poll_event(&dev) do got ||= e.kind == .Format_Changed
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, got, "no Format_Changed event after an external rate change")
	backend.device_close(&dev)
}

// Sets a device's nominal rate behind the driver's back, as another app would.
cad_set_rate :: proc(t: ^testing.T, uid: string, rate: f64) {
	other := cad.create()
	defer backend.driver_destroy(other)
	dev: backend.Device
	backend.device_init(&dev, other)
	defer backend.device_destroy(&dev)
	err := backend.device_open(&dev, {output_device_id = uid, sample_rate = rate, output_channels = {0}}, 64)
	testing.expectf(t, err == .None, "restore rate %v: %v", rate, err)
}
