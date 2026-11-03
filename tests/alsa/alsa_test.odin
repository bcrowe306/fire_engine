#+build linux
// ALSA driver tests. Device tests use only the snd-aloop loopback card
// (`modprobe snd-aloop`; scripts/cloud/linux.sh loads it) and pass as skipped
// without it. Playback on Loopback device 0 reappears as capture on device 1.
package test_alsa

import "base:intrinsics"
import "core:log"
import "core:testing"
import "core:time"

import "fire:backend"
import alsad "fire:backend/alsa"
import "fire:core"
import snd "fire:sys/alsa"
import kit "fire:testkit"

OUT_ID :: "hw:CARD=Loopback,DEV=0,SUBDEV=0"
IN_ID  :: "hw:CARD=Loopback,DEV=1,SUBDEV=0"

@(test)
constants_match_headers :: proc(t: ^testing.T) {
	// Values printed by a C program against <alsa/asoundlib.h>.
	testing.expect_value(t, int(snd.snd_pcm_format_t.S16_LE), 2)
	testing.expect_value(t, int(snd.snd_pcm_format_t.S24_LE), 6)
	testing.expect_value(t, int(snd.snd_pcm_format_t.S32_LE), 10)
	testing.expect_value(t, int(snd.snd_pcm_format_t.FLOAT_LE), 14)
	testing.expect_value(t, int(snd.snd_pcm_format_t.FLOAT64_LE), 16)
	testing.expect_value(t, int(snd.snd_pcm_format_t.S24_3LE), 32)
	testing.expect_value(t, int(snd.snd_pcm_access_t.RW_INTERLEAVED), 3)
	testing.expect_value(t, int(snd.snd_pcm_state_t.DISCONNECTED), 8)
	testing.expect_value(t, size_of(snd.snd_pcm_uframes_t), 8)
}

has_loopback :: proc(d: ^backend.Driver) -> bool {
	infos, _ := backend.driver_enumerate(d, context.temp_allocator)
	for info in infos do if info.id == "hw:CARD=Loopback,DEV=0" do return true
	log.info("snd-aloop not loaded; skipping device test")
	return false
}

open_loopback :: proc(t: ^testing.T, dev: ^backend.Device, d: ^backend.Driver, period: int, max_block: int) -> bool {
	backend.device_init(dev, d)
	setup := backend.Device_Setup {
		output_device_id = OUT_ID, input_device_id = IN_ID,
		sample_rate = 48_000, buffer_frames = period,
		input_channels = {0, 1}, output_channels = {0, 1},
	}
	err := backend.device_open(dev, setup, max_block)
	testing.expectf(t, err == .None, "open loopback: %v", err)
	return err == .None
}

@(test)
enumerate_lists_loopback :: proc(t: ^testing.T) {
	lock := kit.device_lock("aloop")
	defer kit.device_unlock(lock)
	d := alsad.create()
	defer backend.driver_destroy(d)
	infos, err := backend.driver_enumerate(d)
	defer backend.device_infos_destroy(infos)
	testing.expect_value(t, err, core.Error.None)
	for info in infos {
		log.infof("%-34s %-40s in %2d out %2d  rates %v  sizes %v", info.id, info.name, info.input_channels, info.output_channels, info.sample_rates, info.buffer_sizes)
		if info.id == "hw:CARD=Loopback,DEV=0" {
			testing.expect(t, info.output_channels >= 2 && info.input_channels >= 2)
			found_48k := false
			for r in info.sample_rates do found_48k ||= r == 48_000
			testing.expect(t, found_48k, "loopback should offer 48 kHz")
		}
	}
}

@(test)
loopback_is_exact :: proc(t: ^testing.T) {
	lock := kit.device_lock("aloop")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d := alsad.create()
	defer backend.driver_destroy(d)
	if !has_loopback(d) do return

	dev: backend.Device
	defer backend.device_destroy(&dev)
	// 1024-frame periods: the test droplet is a shared VM whose host stalls it for
	// 20–35 ms at times; a plain C loop sees xruns below 1024 there too.
	// max_block 100 still forces uneven splitting.
	if !open_loopback(t, &dev, d, 1024, 100) do return
	trap: kit.Trap_Allocator
	dev.rt_allocator = kit.trap_allocator(&trap)
	f := dev.format

	FRAMES :: 72_000
	r := kit.loop_recorder_make(FRAMES, context.temp_allocator)
	kit.white_noise(r.play[:FRAMES / 2], 77, 0.5)
	testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
	done := kit.loop_recorder_wait(r, FRAMES, 10 * time.Second)
	realtime := alsad.has_realtime_priority(d)
	backend.device_stop(&dev)
	testing.expect(t, done, "loopback did not deliver 1.5 s within 10 s")
	stats := backend.device_stats(&dev)

	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.time_order_bad, 0)
	testing.expect_value(t, r.non_monotonic, 0)
	testing.expectf(t, r.max_entry_skew < 5_000_000, "callback_ns is %d ns from host_time_ns at entry", r.max_entry_skew)
	testing.expectf(t, stats.xruns == 0, "%d xruns", stats.xruns)

	// Quantization: the loop passes through the device format once each way.
	lsb := 0.0
	#partial switch f.output_format {
	case .I16:             lsb = 1.0 / 32768
	case .I24, .I24_In_32: lsb = 1.0 / 8388608
	case .I32:             lsb = 1.0 / 2147483648
	}
	for c in 0 ..< 2 {
		res := kit.analyze_loopback(r.play[:FRAMES / 2], r.rec[c][:], 8192)
		testing.expectf(t, res.found, "ch%d: no loopback signal", c)
		if c == 0 do log.infof("format %v/%v, period %d: round trip %d frames (%.2f ms), gain %v, residual %v; SCHED_FIFO %v; peak load %.3f",
			f.output_format, f.input_format, f.buffer_frames, res.latency, f64(res.latency) * 1000 / f.sample_rate, res.gain, res.residual, realtime, stats.peak_load)
		testing.expectf(t, abs(res.gain - 1) < 1e-6 && res.residual <= lsb * 0.5 + 1e-7, "ch%d: not an exact copy: gain %v residual %v at %d", c, res.gain, res.residual, res.at)
	}
}

@(test)
start_stop_cycles :: proc(t: ^testing.T) {
	lock := kit.device_lock("aloop")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d := alsad.create()
	defer backend.driver_destroy(d)
	if !has_loopback(d) do return

	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_loopback(t, &dev, d, 128, 512) do return
	r := kit.loop_recorder_make(0, context.temp_allocator)
	for cycle in 0 ..< 10 {
		intrinsics.atomic_store(&r.next_time, 0)
		testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
		ok := kit.loop_recorder_wait(r, 128 * 10, 5 * time.Second)
		backend.device_stop(&dev)
		testing.expectf(t, ok, "cycle %d: no callbacks", cycle)
		after := intrinsics.atomic_load(&r.blocks)
		time.sleep(20 * time.Millisecond)
		testing.expectf(t, intrinsics.atomic_load(&r.blocks) == after, "cycle %d: callback after stop", cycle)
	}
	testing.expect_value(t, r.gaps, 0)
}

// A callback that overruns its deadline: the driver recovers, the next block
// is flagged, an Xrun event is posted, and audio keeps flowing.
@(test)
stall_causes_reported_xrun_and_recovery :: proc(t: ^testing.T) {
	lock := kit.device_lock("aloop")
	defer kit.device_unlock(lock)
	testing.set_fail_timeout(t, 60 * time.Second)
	d := alsad.create()
	defer backend.driver_destroy(d)
	if !has_loopback(d) do return

	dev: backend.Device
	defer backend.device_destroy(&dev)
	if !open_loopback(t, &dev, d, 256, 256) do return
	r := kit.loop_recorder_make(0, context.temp_allocator)
	testing.expect_value(t, backend.device_start(&dev, kit.loop_recorder_callback(r)), core.Error.None)
	kit.loop_recorder_wait(r, 48_00, 5 * time.Second)
	intrinsics.atomic_store(&r.stall_ns, i64(50 * time.Millisecond)) // buffer is ~10.7 ms
	ok := kit.loop_recorder_wait(r, 48_000, 5 * time.Second)
	backend.device_stop(&dev)
	testing.expect(t, ok, "audio did not resume after the stall")

	testing.expectf(t, r.xrun_blocks >= 1, "no block was flagged as following an xrun")
	xruns := 0
	for e in backend.device_poll_event(&dev) do if e.kind == .Xrun do xruns += e.count
	testing.expectf(t, xruns >= 1, "no Xrun event")
	testing.expect_value(t, r.gaps, 0) // sample_time stays continuous for the engine
}

@(test)
bad_setups_are_rejected :: proc(t: ^testing.T) {
	lock := kit.device_lock("aloop")
	defer kit.device_unlock(lock)
	d := alsad.create()
	defer backend.driver_destroy(d)
	if !has_loopback(d) do return
	dev: backend.Device
	backend.device_init(&dev, d)
	defer backend.device_destroy(&dev)

	cases := []struct {
		setup: backend.Device_Setup,
		want:  core.Error,
	} {
		{{output_device_id = "hw:CARD=NoSuchCard,DEV=0", output_channels = {0, 1}}, .Invalid_Argument},
		{{output_device_id = OUT_ID, input_device_id = "hw:CARD=Other,DEV=0", output_channels = {0}, input_channels = {0}}, .Unsupported},
		{{output_device_id = OUT_ID, sample_rate = 1_000_000, output_channels = {0, 1}}, .Unsupported},
		{{output_device_id = OUT_ID, output_channels = {40}}, .Invalid_Argument},
	}
	for c, i in cases {
		err := backend.device_open(&dev, c.setup, 256)
		testing.expectf(t, err == c.want, "case %d: got %v want %v", i, err, c.want)
		if err == .None do backend.device_close(&dev)
	}
}
