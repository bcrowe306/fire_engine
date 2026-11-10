#+build darwin
// CoreAudio driver tests. Layout and clock tests always run on macOS. Device
// tests use only BlackHole 2ch (a virtual loopback device) and pass as skipped
// when it is not installed, as on CI. They never open speakers or microphones.
package test_coreaudio

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import "core:testing"
import "core:time"

import "fire:backend"
import cad "fire:backend/coreaudio"
import "fire:core"
import "fire:rt"
import ca "fire:sys/coreaudio"
import kit "fire:testkit"

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

// CoreAudio's clock, read between two reads of ours, must fall inside that
// bracket (± a tick of rounding). A preempted read only widens the bracket,
// so the tightest of ten tries is used: no timing assumption.
@(test)
host_clock_matches_coreaudio :: proc(t: ^testing.T) {
	best_width := max(i64)
	inside := false
	for _ in 0 ..< 10 {
		before := rt.host_time_ns()
		theirs := ca.AudioConvertHostTimeToNanos(ca.AudioGetCurrentHostTime())
		after := rt.host_time_ns()
		if width := i64(after - before); width < best_width {
			best_width = width
			inside = theirs + 100 >= before && theirs <= after + 100
		}
	}
	testing.expectf(t, inside, "CoreAudio host time is outside [before, after] of rt.host_time_ns (bracket %d ns)", best_width)
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

@(test)
blackhole_loopback_is_bit_exact :: proc(t: ^testing.T) {
	lock := kit.device_lock("blackhole")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)

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
	r := kit.loop_recorder_make(FRAMES, context.temp_allocator)
	kit.white_noise(r.play[:FRAMES / 2], 31, 0.5) // noise, then silence

	testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
	done := kit.loop_recorder_wait(r, FRAMES, 10 * time.Second)
	backend.device_stop(&dev)
	testing.expect(t, done, "BlackHole did not deliver 1.5 s of audio within 10 s")
	stats := backend.device_stats(&dev)

	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.time_order_bad, 0)
	testing.expect_value(t, r.non_monotonic, 0)
	// A wrong clock domain is off by seconds; a busy machine (the suite runs
	// packages in parallel) can preempt the callback for a few milliseconds.
	testing.expectf(t, r.max_entry_skew < 50_000_000, "callback_ns is %d ns from host_time_ns at entry", r.max_entry_skew)
	testing.expectf(t, stats.xruns == 0, "%d xruns (machine busy?)", stats.xruns)

	// BlackHole has its own output and input volume controls (macOS may have
	// turned them down). At 100% the loopback must be bit-exact; otherwise it
	// must be exactly the input times one constant gain.
	unity := volume_scalar(id, ca.kAudioObjectPropertyScopeOutput) == 1 && volume_scalar(id, ca.kAudioObjectPropertyScopeInput) == 1
	for c in 0 ..< 2 {
		res := kit.analyze_loopback(r.play[:FRAMES / 2], r.rec[c][:], 8192)
		testing.expectf(t, res.found, "ch%d: no loopback signal found", c)
		if c == 0 do log.infof("round trip %d frames (%.2f ms; driver reports %d, timestamps %d), gain %.4f (%.2f dB)%s; %d callbacks, peak load %.3f",
			res.latency, f64(res.latency) * 1000 / f.sample_rate, f.input_latency_frames + f.output_latency_frames, stats.round_trip_frames, res.gain, kit.linear_to_db(res.gain),
			"" if unity else " (BlackHole volume below 100%)", stats.callbacks, stats.peak_load)
		testing.expectf(t, res.residual <= 1e-6, "ch%d: recording is not a scaled copy of the input: residual %v at %d", c, res.residual, res.at)
		if unity do testing.expectf(t, res.gain == 1 && res.residual == 0, "ch%d: loopback at unity volume not bit-exact (gain %v)", c, res.gain)
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
	lock := kit.device_lock("blackhole")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)

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
	r := kit.loop_recorder_make(0, context.temp_allocator)
	for cycle in 0 ..< 10 {
		intrinsics.atomic_store(&r.next_time, 0)
		before := intrinsics.atomic_load(&r.blocks)
		testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
		ok := kit.loop_recorder_wait(r, 128 * 10, 5 * time.Second)
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
	lock := kit.device_lock("blackhole")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)

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

// --- hot-plug ---------------------------------------------------------------------------

foreign import CoreAudioFw "system:CoreAudio.framework"
foreign import CoreFoundationFw "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign CoreAudioFw {
	AudioHardwareCreateAggregateDevice :: proc(description: rawptr, out_device: ^ca.AudioObjectID) -> ca.OSStatus ---
	AudioHardwareDestroyAggregateDevice :: proc(device: ca.AudioObjectID) -> ca.OSStatus ---
}

@(default_calling_convention = "c")
foreign CoreFoundationFw {
	CFDictionaryCreate :: proc(alloc: rawptr, keys: [^]rawptr, values: [^]rawptr, count: int, key_callbacks: rawptr, value_callbacks: rawptr) -> rawptr ---
	CFNumberCreate :: proc(alloc: rawptr, type: int, value: rawptr) -> rawptr ---
	CFStringCreateWithCString :: proc(alloc: rawptr, s: cstring, encoding: u32) -> rawptr ---
	kCFTypeDictionaryKeyCallBacks: [6]rawptr
	kCFTypeDictionaryValueCallBacks: [5]rawptr
}

// A private aggregate device (visible to this process only; your system is
// untouched) is created and destroyed while BlackHole is open: each must be
// reported as Devices_Changed.
@(test)
device_hotplug_is_reported :: proc(t: ^testing.T) {
	lock := kit.device_lock("blackhole")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d := cad.create()
	defer backend.driver_destroy(d)
	id, _, found := find_blackhole(t, d)
	if !found do return
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	if err := backend.device_open(&dev, {output_device_id = id, output_channels = {0, 1}}, 512); err != .None {
		testing.expectf(t, false, "open BlackHole: %v", err)
		return
	}
	time.sleep(100 * time.Millisecond)
	for _ in backend.device_poll_event(&dev) {}

	utf8 :: 0x08000100
	uid := fmt.ctprintf("fire.test.aggregate.%d", os.get_pid())
	keys := [3]rawptr{CFStringCreateWithCString(nil, "uid", utf8), CFStringCreateWithCString(nil, "name", utf8), CFStringCreateWithCString(nil, "private", utf8)}
	one: i32 = 1
	values := [3]rawptr{CFStringCreateWithCString(nil, uid, utf8), CFStringCreateWithCString(nil, "Fire Test Aggregate", utf8), CFNumberCreate(nil, 3 /* kCFNumberSInt32Type */, &one)}
	desc := CFDictionaryCreate(nil, &keys[0], &values[0], 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer {
		CF.CFRelease(CF.TypeRef(desc))
		for k in keys do CF.CFRelease(CF.TypeRef(k))
		for v in values do CF.CFRelease(CF.TypeRef(v))
	}
	agg: ca.AudioObjectID
	status := AudioHardwareCreateAggregateDevice(desc, &agg)
	testing.expectf(t, status == ca.NO_ERR, "create aggregate device: OSStatus %d", status)
	if status != ca.NO_ERR do return
	testing.expect(t, wait_device_event(&dev, .Devices_Changed), "no Devices_Changed after adding a device")
	testing.expect_value(t, AudioHardwareDestroyAggregateDevice(agg), ca.NO_ERR)
	testing.expect(t, wait_device_event(&dev, .Devices_Changed), "no Devices_Changed after removing a device")
}

wait_device_event :: proc(dev: ^backend.Device, kind: backend.Device_Event_Kind, timeout := 3 * time.Second) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		for e in backend.device_poll_event(dev) do if e.kind == kind do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
latency_probe_measures_blackhole :: proc(t: ^testing.T) {
	lock := kit.device_lock("blackhole")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d := cad.create()
	defer backend.driver_destroy(d)
	id, rate, found := find_blackhole(t, d)
	if !found do return
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	setup := backend.Device_Setup{output_device_id = id, input_device_id = id, sample_rate = rate, buffer_frames = 256, input_channels = {0, 1}, output_channels = {0, 1}}
	if err := backend.device_open(&dev, setup, 256); err != .None {
		testing.expectf(t, false, "open BlackHole: %v", err)
		return
	}
	frames, quality, ok := kit.run_latency_probe(&dev)
	log.infof("probe: %d frames, quality %.4f; device timestamps %d", frames, quality, backend.round_trip_latency_frames(&dev))
	testing.expect(t, ok, "the probe never finished")
	testing.expectf(t, quality > 0.99, "quality %v", quality)
	testing.expect_value(t, frames, 2 * dev.format.buffer_frames) // as the loopback test measures
}
