// JACK driver tests. Each test starts a private jackd (dummy driver, its own
// server name) so a user's JACK server is never touched. Skipped where libjack
// or jackd is missing (macOS and Windows unless JACK is installed; CI).
package test_jack

import "base:intrinsics"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import "fire:backend"
import jd "fire:backend/jack"
import "fire:core"
import kit "fire:testkit"

RATE   :: 48_000
PERIOD :: 1024 // the test VM's scheduling stalls cause xruns below this (as with ALSA)

Server :: struct {
	name:    string,
	pidfile: string,
	lock:    kit.Device_Lock,
}

// Starts `jackd -d dummy` under a unique name and waits until a client can
// connect. ok = false (skip) if JACK is not available here.
server_start :: proc(t: ^testing.T, tag: string) -> (s: Server, d: ^backend.Driver, ok: bool) {
	s.lock = kit.device_lock("jack") // one jackd at a time (the tests run in parallel)
	defer if !ok do kit.device_unlock(s.lock)
	when ODIN_OS != .Linux {
		log.info("JACK tests run on Linux only; skipping")
		return
	}
	s.name = fmt.tprintf("fire_%s_%d", tag, os.get_pid())
	s.pidfile = fmt.tprintf("/tmp/%s.pid", s.name)
	opts := jd.default_options()
	opts.server_name, opts.auto_connect = s.name, false
	err: core.Error
	if d, err = jd.create(opts); err != .None {
		log.info("libjack not installed; skipping")
		return
	}
	cmd := fmt.ctprintf("JACK_NO_AUDIO_RESERVATION=1 jackd -n %s -d dummy -r %d -p %d >/tmp/%s.log 2>&1 & echo $! > %s", s.name, RATE, PERIOD, s.name, s.pidfile)
	if libc.system(cmd) != 0 {
		backend.driver_destroy(d)
		log.info("jackd not available; skipping")
		return s, nil, false
	}
	// A slow, loaded VM can take seconds to start jackd.
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		infos, _ := backend.driver_enumerate(d, context.temp_allocator)
		if len(infos) == 1 do return s, d, true
		time.sleep(50 * time.Millisecond)
	}
	out, _ := os.read_entire_file(fmt.tprintf("/tmp/%s.log", s.name), context.temp_allocator)
	testing.expectf(t, false, "jackd %s did not come up; it said:\n%s", s.name, string(out))
	server_stop(s)
	backend.driver_destroy(d)
	return s, nil, false
}

// Stops the server and waits (up to 5 s) for it to exit, so the next one
// doesn't start while it still holds its shared memory.
server_stop :: proc(s: Server) {
	libc.system(fmt.ctprintf("p=$(cat %s); kill $p 2>/dev/null; for i in $(seq 100); do kill -0 $p 2>/dev/null || break; sleep 0.05; done; rm -f %s /tmp/%s.log", s.pidfile, s.pidfile, s.name))
}

server_release :: proc(s: Server) {
	kit.device_unlock(s.lock)
}

wait_event :: proc(dev: ^backend.Device, kind: backend.Device_Event_Kind, timeout := 3 * time.Second) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		for e in backend.device_poll_event(dev) do if e.kind == kind do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

open_stereo :: proc(t: ^testing.T, dev: ^backend.Device, d: ^backend.Driver, max_block: int) -> bool {
	backend.device_init(dev, d)
	err := backend.device_open(dev, {input_channels = {0, 1}, output_channels = {0, 1}}, max_block)
	testing.expectf(t, err == .None, "open: %v", err)
	return err == .None
}

// Our outputs patched to our inputs: an exact copy, delayed by whole periods.
@(test)
loopback_is_exact :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	s, d, ok := server_start(t, "loop")
	if !ok do return
	defer server_release(s)
	defer server_stop(s)
	defer backend.driver_destroy(d)
	dev: backend.Device
	trap: kit.Trap_Allocator
	FRAMES :: RATE * 3 / 2
	r: ^kit.Loop_Recorder
	stats: backend.Device_Stats
	// A dropout says the machine was busy (the suite runs packages in
	// parallel), not that the backend is wrong: try again, up to 3 times.
	for attempt in 0 ..< 3 {
		if attempt > 0 do backend.device_destroy(&dev)
		if !open_stereo(t, &dev, d, 100) do return // max_block 100: uneven splitting
		dev.rt_allocator = kit.trap_allocator(&trap)
		r = kit.loop_recorder_make(FRAMES, context.temp_allocator)
		kit.white_noise(r.play[:FRAMES / 2], 5, 0.5)
		testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
		for ch in 0 ..< 2 {
			testing.expect_value(t, jd.connect(d, jd.port_name(d, true, ch), jd.port_name(d, false, ch)), core.Error.None)
		}
		done := kit.loop_recorder_wait(r, FRAMES, 10 * time.Second)
		backend.device_stop(&dev)
		testing.expect(t, done, "JACK did not deliver 1.5 s within 10 s")
		stats = backend.device_stats(&dev)
		if stats.xruns == 0 do break
		log.warnf("attempt %d: %d xruns (a busy machine); trying again", attempt + 1, stats.xruns)
		backend.device_close(&dev)
	}
	defer backend.device_destroy(&dev)

	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.time_order_bad, 0)
	testing.expect_value(t, r.non_monotonic, 0)
	testing.expectf(t, stats.xruns == 0, "%d xruns", stats.xruns)
	for ch in 0 ..< 2 {
		res := kit.analyze_loopback(r.play[:FRAMES / 2], r.rec[ch][:], 8192)
		testing.expectf(t, res.found, "ch%d: no loopback signal", ch)
		if ch == 0 do log.infof("round trip %d frames (%d periods; driver reports %d, timestamps %d), gain %v, residual %v; peak load %.3f", res.latency, res.latency / PERIOD, dev.format.input_latency_frames + dev.format.output_latency_frames, stats.round_trip_frames, res.gain, res.residual, stats.peak_load)
		testing.expectf(t, res.gain == 1 && res.residual == 0, "ch%d: not bit-exact: gain %v residual %v at %d", ch, res.gain, res.residual, res.at)
		testing.expectf(t, res.latency % PERIOD == 0, "ch%d: latency %d is not whole periods", ch, res.latency)
	}
}

// Another client registering ports → Devices_Changed; the server dying →
// Device_Lost.
@(test)
registration_and_shutdown_are_reported :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	s, d, ok := server_start(t, "events")
	if !ok do return
	defer server_release(s)
	stopped := false
	defer if !stopped do server_stop(s)
	defer backend.driver_destroy(d)
	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_stereo(t, &dev, d, 512) do return
	r := kit.loop_recorder_make(0, context.temp_allocator)
	testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
	kit.loop_recorder_wait(r, RATE / 10, 5 * time.Second)
	for _ in backend.device_poll_event(&dev) {}

	opts := jd.default_options()
	opts.server_name, opts.client_name, opts.auto_connect = s.name, "Fire Other", false
	other, err := jd.create(opts)
	testing.expect_value(t, err, core.Error.None)
	if err == .None {
		odev: backend.Device
		backend.device_init(&odev, other)
		testing.expect_value(t, backend.device_open(&odev, {output_channels = {0}}, 512), core.Error.None)
		testing.expect(t, wait_event(&dev, .Devices_Changed), "no Devices_Changed when another client registered a port")
		backend.device_destroy(&odev)
		backend.driver_destroy(other)
	}

	server_stop(s)
	stopped = true
	testing.expect(t, wait_event(&dev, .Device_Lost, 5 * time.Second), "no Device_Lost when the server went away")
	_ = intrinsics.atomic_load(&r.blocks)
}

@(test)
server_owns_rate_and_period :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	s, d, ok := server_start(t, "fmt")
	if !ok do return
	defer server_release(s)
	defer server_stop(s)
	defer backend.driver_destroy(d)
	infos, _ := backend.driver_enumerate(d, context.temp_allocator)
	testing.expect_value(t, len(infos), 1)
	if len(infos) == 1 {
		testing.expect_value(t, infos[0].default_sample_rate, RATE)
		testing.expect_value(t, infos[0].default_buffer_frames, PERIOD)
	}
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = {0, 1}, sample_rate = 44_100}, 512), core.Error.Unsupported)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = {0, 1}, buffer_frames = 128}, 512), core.Error.Unsupported)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = {0, 1}, sample_rate = RATE, buffer_frames = PERIOD}, 512), core.Error.None)
	testing.expect_value(t, dev.format.device_output_channels, 2)
}
