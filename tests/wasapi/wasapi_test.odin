#+build windows
// WASAPI driver tests. Device tests use only VB-CABLE (a virtual cable:
// "CABLE Input" playback reappears on "CABLE Output" recording;
// scripts/cloud/windows.sh installs it) and pass as skipped without it.
package test_wasapi

import "base:intrinsics"
import "core:fmt"
import "core:c/libc"
import "core:log"
import "core:strings"
import "core:testing"
import "core:time"

import "fire:backend"
import wd "fire:backend/wasapi"
import "fire:core"
import kit "fire:testkit"

Cable :: struct {
	out_id, in_id: string,
	rate:          f64,
	period:        int,
}

find_cable :: proc(d: ^backend.Driver) -> (c: Cable, ok: bool) {
	infos, _ := backend.driver_enumerate(d, context.temp_allocator)
	for info in infos {
		if strings.contains(info.name, "CABLE Input") && info.output_channels >= 2 {
			c.out_id, c.rate, c.period = info.id, info.default_sample_rate, info.default_buffer_frames
		}
		if strings.contains(info.name, "CABLE Output") && info.input_channels >= 2 do c.in_id = info.id
	}
	ok = c.out_id != "" && c.in_id != ""
	if !ok do log.info("VB-CABLE not installed; skipping device test")
	return
}

open_cable :: proc(t: ^testing.T, dev: ^backend.Device, d: ^backend.Driver, c: Cable, max_block: int) -> bool {
	backend.device_init(dev, d)
	setup := backend.Device_Setup {
		output_device_id = c.out_id, input_device_id = c.in_id,
		input_channels = {0, 1}, output_channels = {0, 1},
	}
	err := backend.device_open(dev, setup, max_block)
	testing.expectf(t, err == .None, "open VB-CABLE: %v (last HRESULT %x)", err, u32(wd.diagnostics(d).last_error))
	return err == .None
}

make_driver :: proc(t: ^testing.T) -> (^backend.Driver, bool) {
	d, err := wd.create()
	testing.expect_value(t, err, core.Error.None)
	return d, err == .None
}

@(test)
enumerate_devices :: proc(t: ^testing.T) {
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	infos, err := backend.driver_enumerate(d)
	defer backend.device_infos_destroy(infos)
	testing.expect_value(t, err, core.Error.None)
	for info in infos {
		log.infof("%-60s in %d out %d  %v Hz  period %d  sizes %v  default in %v out %v",
			info.name, info.input_channels, info.output_channels, info.default_sample_rate,
			info.default_buffer_frames, info.buffer_sizes, info.is_default_input, info.is_default_output)
		testing.expectf(t, info.id != "", "%s: no endpoint ID", info.name)
		testing.expectf(t, (info.input_channels > 0) != (info.output_channels > 0), "%s: endpoints have one direction", info.name)
	}
}

@(test)
loopback_through_cable :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	c, found := find_cable(d)
	if !found do return

	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_cable(t, &dev, d, c, 100) do return // max_block 100: uneven splitting
	trap: kit.Trap_Allocator
	dev.rt_allocator = kit.trap_allocator(&trap)
	f := dev.format

	// VB-CABLE settles its own latency during the first ~50 ms of a stream,
	// inserting a few hundred frames (measured: the delay jumps once, then
	// holds; the driver's sample count stays continuous). So the noise starts
	// after 0.25 s of silence; any glitch after that fails the test.
	frames := int(f.sample_rate * 1.5)
	settle := int(f.sample_rate * 0.25)
	r := kit.loop_recorder_make(frames, context.temp_allocator)
	kit.white_noise(r.play[settle:frames / 2], 91, 0.5)
	testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
	done := kit.loop_recorder_wait(r, i64(frames), 10 * time.Second)
	diag := wd.diagnostics(d)
	backend.device_stop(&dev)
	testing.expect(t, done, "VB-CABLE did not deliver 1.5 s within 10 s")
	stats := backend.device_stats(&dev)

	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.time_order_bad, 0)
	testing.expect_value(t, r.non_monotonic, 0)
	testing.expectf(t, r.max_entry_skew < 5_000_000, "callback_ns is %d ns from host_time_ns at entry", r.max_entry_skew)
	testing.expectf(t, stats.xruns == 0, "%d xruns", stats.xruns)

	// The Windows audio engine applies endpoint volume, so require an exact
	// scaled copy rather than unity gain (as with BlackHole).
	for ch in 0 ..< 2 {
		res := kit.analyze_loopback(r.play[:frames / 2], r.rec[ch][:], 8192)
		testing.expectf(t, res.found, "ch%d: no loopback signal", ch)
		if ch == 0 do log.infof("%v Hz %v/%v, period %d, buffer %d: round trip %d frames (%.2f ms; driver reports %d, timestamps %d), gain %v (%.2f dB), residual %v; %v; peak load %.3f",
			f.sample_rate, f.output_format, f.input_format, f.buffer_frames, f.max_driver_frames, res.latency, f64(res.latency) * 1000 / f.sample_rate, f.input_latency_frames + f.output_latency_frames, stats.round_trip_frames,
			res.gain, kit.linear_to_db(res.gain), res.residual, diag, stats.peak_load)
		testing.expectf(t, res.residual <= 1e-5, "ch%d: not a scaled copy: gain %v residual %v at %d", ch, res.gain, res.residual, res.at)
		if res.found && res.residual > 1e-5 && ch == 0 {
			// Where does it go wrong? Latency per 2048-frame window: a jump
			// means samples were dropped or inserted downstream of the driver.
			sb := strings.builder_make(context.temp_allocator)
			for start := 0; start + 2048 <= frames / 2; start += 2048 {
				lat := kit.estimate_latency(r.play[start:][:2048], r.rec[ch][start:], 8192)
				strings.write_string(&sb, fmt.tprintf("%d:%d ", start, lat))
			}
			log.infof("window latencies: %s", strings.to_string(sb))
			n := min(frames / 2, frames - res.latency)
			expected := kit.buffer_make(1, n, f.sample_rate, context.temp_allocator)
			actual := kit.buffer_make(1, n, f.sample_rate, context.temp_allocator)
			for i in 0 ..< n do expected.channels[0][i] = f32(res.gain) * r.play[i]
			copy(actual.channels[0], r.rec[0][res.latency:][:n])
			kit.dump_comparison("wasapi_loopback", expected, actual, kit.compare_slices(expected.channels[0], actual.channels[0]))
		}
	}
}

@(test)
start_stop_cycles :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	c, found := find_cable(d)
	if !found do return

	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_cable(t, &dev, d, c, 512) do return
	r := kit.loop_recorder_make(0, context.temp_allocator)
	for cycle in 0 ..< 10 {
		intrinsics.atomic_store(&r.next_time, 0)
		testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
		got := kit.loop_recorder_wait(r, 4_800, 5 * time.Second)
		backend.device_stop(&dev)
		testing.expectf(t, got, "cycle %d: no callbacks", cycle)
		after := intrinsics.atomic_load(&r.blocks)
		time.sleep(30 * time.Millisecond)
		testing.expectf(t, intrinsics.atomic_load(&r.blocks) == after, "cycle %d: callback after stop", cycle)
	}
	testing.expect_value(t, r.gaps, 0)
}

// A callback that overruns its deadline: capture overflows, the next block is
// flagged, an Xrun event is posted, and audio keeps flowing.
@(test)
stall_causes_reported_xrun_and_recovery :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	c, found := find_cable(d)
	if !found do return

	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_cable(t, &dev, d, c, 512) do return
	r := kit.loop_recorder_make(0, context.temp_allocator)
	testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
	kit.loop_recorder_wait(r, 4_800, 5 * time.Second)
	intrinsics.atomic_store(&r.stall_ns, i64(500 * time.Millisecond)) // longer than any endpoint buffer
	ok = kit.loop_recorder_wait(r, i64(c.rate * 2), 10 * time.Second)
	backend.device_stop(&dev)
	testing.expect(t, ok, "audio did not resume after the stall")
	testing.expectf(t, r.xrun_blocks >= 1, "no block was flagged as following an xrun")
	xruns := 0
	for e in backend.device_poll_event(&dev) do if e.kind == .Xrun do xruns += e.count
	testing.expectf(t, xruns >= 1, "no Xrun event")
	testing.expect_value(t, r.gaps, 0)
}

@(test)
bad_setups_are_rejected :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	c, found := find_cable(d)
	if !found do return
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)

	cases := []struct {
		setup: backend.Device_Setup,
		want:  core.Error,
	} {
		{{output_device_id = "{0.0.0.00000000}.{00000000-0000-0000-0000-000000000000}", output_channels = {0, 1}}, .Invalid_Argument},
		{{output_device_id = c.out_id, sample_rate = 12_345, output_channels = {0, 1}}, .Unsupported},
		{{output_device_id = c.out_id, buffer_frames = 7, output_channels = {0, 1}}, .Unsupported},
		{{output_device_id = c.out_id, output_channels = {40}}, .Invalid_Argument},
	}
	for tc, i in cases {
		log.infof("case %d: %v", i, tc.setup)
		err := backend.device_open(&dev, tc.setup, 256)
		testing.expectf(t, err == tc.want, "case %d: got %v want %v", i, err, tc.want)
		if err == .None do backend.device_close(&dev)
	}
}

// Disables and re-enables VB-CABLE (pnputil-style, via PowerShell) while its
// render endpoint is open: Devices_Changed and Device_Lost, then
// Devices_Changed again. Needs an elevated session (the test machine's SSH).
@(test)
endpoint_hotplug_is_reported :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 90 * time.Second)
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	c, found := find_cable(d)
	if !found do return
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)
	if err := backend.device_open(&dev, {output_device_id = c.out_id, output_channels = {0, 1}}, 512); err != .None {
		testing.expectf(t, false, "open: %v", err)
		return
	}
	for _ in backend.device_poll_event(&dev) {}

	PS :: "powershell -NoProfile -Command \"Get-PnpDevice -FriendlyName 'VB-Audio Virtual Cable' | %s-PnpDevice -Confirm:$false\""
	enable := fmt.ctprintf(PS, "Enable")
	defer libc.system(enable) // never leave the cable disabled
	if libc.system(fmt.ctprintf(PS, "Disable")) != 0 {
		// Windows Server editions (the EC2 test machine) refuse to disable
		// devices ("not supported on this OS product"); so do non-elevated runs.
		log.info("this Windows cannot disable VB-CABLE (Server edition, or not elevated); skipping")
		return
	}
	lost, changed := false, false
	start := time.tick_now()
	for !(lost && changed) && time.tick_since(start) < 10 * time.Second {
		for e in backend.device_poll_event(&dev) {
			lost ||= e.kind == .Device_Lost
			changed ||= e.kind == .Devices_Changed
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, changed, "no Devices_Changed after disabling the cable")
	testing.expect(t, lost, "no Device_Lost for the open endpoint")
	testing.expect_value(t, libc.system(enable), 0)
	back := false
	start = time.tick_now()
	for !back && time.tick_since(start) < 10 * time.Second {
		for e in backend.device_poll_event(&dev) do back ||= e.kind == .Devices_Changed
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, back, "no Devices_Changed after re-enabling the cable")
}

@(test)
latency_probe_measures_the_cable :: proc(t: ^testing.T) {
	lock := kit.device_lock("vbcable")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d, ok := make_driver(t)
	if !ok do return
	defer backend.driver_destroy(d)
	c, found := find_cable(d)
	if !found do return
	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_cable(t, &dev, d, c, 256) do return
	frames, quality, done := kit.run_latency_probe(&dev)
	log.infof("probe: %d frames, quality %.4f; device timestamps %d", frames, quality, backend.round_trip_latency_frames(&dev))
	testing.expect(t, done, "the probe never finished")
	testing.expectf(t, quality > 0.99, "quality %v", quality)
	testing.expectf(t, frames > dev.format.buffer_frames, "%d frames is less than a period", frames) // VB-CABLE's own delay varies by stream
}
