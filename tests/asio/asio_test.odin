#+build windows
// ASIO driver tests, through FlexASIO configured for VB-CABLE (see
// REQUIRES): output channel k comes back on input channel k.
package test_asio

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "core:time"

import "fire:backend"
import "fire:backend/asio"
import "fire:core"
import kit "fire:testkit"

flexasio :: proc(t: ^testing.T, d: ^backend.Driver) -> (info: backend.Device_Info, ok: bool) {
	infos, err := backend.driver_enumerate(d, context.temp_allocator)
	testing.expect_value(t, err, core.Error.None)
	for i in infos do if strings.contains(i.name, "FlexASIO") do return i, true
	testing.expect(t, false, "FlexASIO not in the registry")
	return
}

@(test)
lists_flexasio :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	d, err := asio.create()
	if !testing.expect_value(t, err, core.Error.None) do return
	defer backend.driver_destroy(d)
	info, ok := flexasio(t, d)
	if !ok do return
	log.infof("%s (%s): in %d out %d, %v Hz, buffers %v (default %d)", info.name, info.id, info.input_channels, info.output_channels, info.sample_rates, info.buffer_sizes, info.default_buffer_frames)
	testing.expect(t, strings.has_prefix(info.id, asio.ID_PREFIX))
	testing.expect(t, info.input_channels >= 2 && info.output_channels >= 2)
	found := false
	for r in info.sample_rates do found ||= r == 48_000
	testing.expect(t, found, "48 kHz")
}

open_flexasio :: proc(t: ^testing.T, dev: ^backend.Device, d: ^backend.Driver, frames, max_block: int) -> bool {
	info, ok := flexasio(t, d)
	if !ok do return false
	backend.device_init(dev, d)
	err := backend.device_open(dev, {output_device_id = info.id, sample_rate = 48_000, buffer_frames = frames, input_channels = {0, 1}, output_channels = {0, 1}}, max_block)
	testing.expectf(t, err == .None, "open FlexASIO: %v", err)
	return err == .None
}

// One capture: 0.25 s to settle, then 0.5 s of noise out, 1.5 s recorded.
Capture :: struct {
	r:     ^kit.Loop_Recorder,
	done:  bool,
	stats: backend.Device_Stats,
}

capture :: proc(dev: ^backend.Device, frames, settle: int) -> (c: Capture) {
	c.r = kit.loop_recorder_make(frames, context.temp_allocator)
	kit.white_noise(c.r.play[settle:frames / 2], 91, 0.5)
	if backend.device_start(dev, kit.loop_recorder_callback(c.r)) != .None do return
	c.done = kit.loop_recorder_wait(c.r, i64(frames), 10 * time.Second)
	backend.device_stop(dev)
	c.stats = backend.device_stats(dev)
	return
}

// Latency per 2048-frame window of the noise, and whether it is the same in
// every window. A step means samples were dropped or inserted downstream of
// the driver (VB-CABLE's shared-mode stream does this now and then).
window_latencies :: proc(c: Capture, ch, frames, settle: int) -> (text: string, steady: bool) {
	sb := strings.builder_make(context.temp_allocator)
	first := -1
	steady = true
	for start := settle; start + 2048 <= frames / 2; start += 2048 {
		l := kit.estimate_latency(c.r.play[start:][:2048], c.r.rec[ch][start:], 8192)
		if first < 0 do first = l
		steady &&= l == first
		strings.write_string(&sb, fmt.tprintf("%d:%d ", start, l))
	}
	return strings.to_string(sb), steady
}

@(test)
loopback_through_flexasio :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 120 * time.Second)
	d, _ := asio.create()
	defer backend.driver_destroy(d)
	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_flexasio(t, &dev, d, 480, 100) do return // max_block 100: uneven splitting
	trap: kit.Trap_Allocator
	dev.rt_allocator = kit.trap_allocator(&trap)
	f := dev.format

	frames := int(f.sample_rate * 1.5)
	settle := int(f.sample_rate * 0.25) // VB-CABLE settles its latency at first
	// A capture whose latency steps part-way lost samples outside our code:
	// try again (up to 3 captures). Anything else wrong fails at once.
	c: Capture
	for attempt in 1 ..= 3 {
		c = capture(&dev, frames, settle)
		if !c.done || c.r.gaps != 0 do break
		res := kit.analyze_loopback(c.r.play[:frames / 2], c.r.rec[0][:], 8192)
		if !res.found || res.residual <= 1e-5 do break
		text, steady := window_latencies(c, 0, frames, settle)
		if steady || attempt == 3 do break
		log.warnf("capture %d: latency stepped downstream of the driver (window latencies %s); capturing again", attempt, text)
	}
	testing.expect(t, c.done, "FlexASIO did not deliver 1.5 s within 10 s")
	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, c.r.gaps, 0)
	for ch in 0 ..< 2 {
		res := kit.analyze_loopback(c.r.play[:frames / 2], c.r.rec[ch][:], 8192)
		testing.expectf(t, res.found, "ch%d: no loopback signal", ch)
		if ch == 0 do log.infof("%v Hz %v/%v, buffer %d: round trip %d frames (%.2f ms; driver reports %d, timestamps %d), gain %v, residual %v; %d callbacks, %d xruns, peak load %.3f",
			f.sample_rate, f.output_format, f.input_format, f.buffer_frames, res.latency, f64(res.latency) * 1000 / f.sample_rate,
			f.input_latency_frames + f.output_latency_frames, c.stats.round_trip_frames, res.gain, res.residual, c.stats.callbacks, c.stats.xruns, c.stats.peak_load)
		testing.expectf(t, res.residual <= 1e-5, "ch%d: not a scaled copy: gain %v residual %v", ch, res.gain, res.residual)
		if res.found && res.residual > 1e-5 {
			text, _ := window_latencies(c, ch, frames, settle)
			log.infof("ch%d window latencies: %s", ch, text)
		}
	}
}

@(test)
latency_probe_through_flexasio :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d, _ := asio.create()
	defer backend.driver_destroy(d)
	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_flexasio(t, &dev, d, 480, 480) do return
	// A low quality is a measurement spoiled outside our code (VB-CABLE
	// dropping or inserting samples during the burst): measure again, as an
	// app would, up to 3 times.
	frames: int
	quality: f64
	ok: bool
	for attempt in 1 ..= 3 {
		frames, quality, ok = kit.run_latency_probe(&dev)
		if !ok || quality > 0.99 do break
		if attempt < 3 do log.warnf("probe %d: quality %.4f; measuring again", attempt, quality)
	}
	log.infof("probe: %d frames, quality %.4f; device timestamps %d, reported %d", frames, quality, backend.round_trip_latency_frames(&dev), dev.format.input_latency_frames + dev.format.output_latency_frames)
	testing.expect(t, ok, "the probe never finished")
	testing.expectf(t, quality > 0.99, "quality %v", quality)
}

@(test)
opens_and_closes_repeatedly :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d, _ := asio.create()
	defer backend.driver_destroy(d)
	for size in ([]int{256, 512, 1024}) {
		dev: backend.Device
		if !open_flexasio(t, &dev, d, size, 512) do return
		r := kit.loop_recorder_make(0, context.temp_allocator)
		testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
		time.sleep(100 * time.Millisecond)
		backend.device_stop(&dev)
		testing.expectf(t, backend.device_stats(&dev).callbacks > 0, "buffer %d: no callbacks", size)
		backend.device_close(&dev)
		backend.device_destroy(&dev)
	}
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	testing.expect(t, backend.device_open(&dev, {output_device_id = "asio:No Such Driver", output_channels = {0}}, 512) != .None)
}
