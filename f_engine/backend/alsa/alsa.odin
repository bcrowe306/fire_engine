#+build linux
// ALSA driver: playback and capture PCMs (linked, same card) serviced by a
// thread of our own. See /design/backend/.
package alsa

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:thread"
import "core:time"

import "fire:backend"
import "fire:core"
import "fire:rt"
import snd "fire:sys/alsa"

@(private)
PERIODS :: 2         // playback buffer: one period playing, one being filled (sets latency)
@(private)
CAPTURE_PERIODS :: 4 // capture slack; free in latency terms because we read as soon as a period is ready

@(private)
Stream :: struct {
	pcm:      snd.snd_pcm_t,
	format:   snd.snd_pcm_format_t,
	channels: int,
	bytes:    int, // per sample
	buffer:   []u8, // one period, interleaved
}

@(private)
Alsa :: struct {
	driver:     backend.Driver,
	allocator:  mem.Allocator,
	play:       Stream,
	capture:    Stream,
	format:     backend.Device_Format,
	period:     int,
	buffer_len: int, // frames in the hardware buffer
	in_planes:  [1]backend.Driver_Plane,
	out_planes: [1]backend.Driver_Plane,
	is_open:    bool,
	watcher:    ^thread.Thread, // card hot-plug (declared before `thread`, which shadows the package)
	watch_stop: bool,           // atomic
	thread:     ^thread.Thread,

	// Shared with the audio thread.
	stop_flag:   bool, // atomic
	realtime:    bool, // atomic: SCHED_FIFO granted
	recoveries:  u64,  // atomic
	last_error:  i64,  // atomic: last negative ALSA result, for diagnostics
	last_op:     i32,  // atomic: 1 read, 2 write (which call failed)
	states:      [2]i32, // atomic: playback/capture state when it failed

	// Audio thread only.
	xrun_pending: bool,
	lost:         bool,
	clock:        Period_Clock,
}

// Smooths per-period timestamps. A single reading (now ± snd_pcm_delay) jitters
// by the thread's wake-up latency, milliseconds on a busy machine. Like JACK's
// DLL: predict one period ahead, then pull 5% toward each measurement, so
// timestamps advance steadily and follow drift. Reset after every restart.
@(private)
Period_Clock :: struct {
	output_ns, input_ns: f64,
	valid:               bool,
}

@(private)
CLOCK_GAIN :: 0.05

// [rt]
@(private)
clock_update :: proc "contextless" (k: ^Period_Clock, measured_out, measured_in, period_ns: f64) -> (out_ns, in_ns: u64) {
	if !k.valid {
		k.output_ns, k.input_ns, k.valid = measured_out, measured_in, true
	} else {
		k.output_ns += period_ns
		k.input_ns += period_ns
		k.output_ns += (measured_out - k.output_ns) * CLOCK_GAIN
		k.input_ns += (measured_in - k.input_ns) * CLOCK_GAIN
	}
	return u64(k.output_ns), u64(k.input_ns)
}

// Makes an ALSA driver and starts a thread that watches for sound cards being
// added or removed. Free with backend.driver_destroy. Control thread.
create :: proc(allocator := context.allocator) -> ^backend.Driver {
	a := new(Alsa, allocator)
	a.allocator = allocator
	a.driver = {vtable = &alsa_vtable, name = "ALSA", data = a}
	a.watcher = thread.create_and_start_with_data(a, watch_cards)
	return &a.driver
}

// ALSA has no hot-plug notification API short of udev, so a thread compares
// the card list every 500 ms and posts Devices_Changed to the open device.
// (Losing the open device shows up in the audio thread as -ENODEV.)
@(private)
watch_cards :: proc(data: rawptr) {
	a := (^Alsa)(data)
	last := card_signature()
	for !intrinsics.atomic_load(&a.watch_stop) {
		for _ in 0 ..< 10 {
			if intrinsics.atomic_load(&a.watch_stop) do return
			time.sleep(50 * time.Millisecond)
		}
		now := card_signature()
		if now != last {
			last = now
			if host := intrinsics.atomic_load(&a.driver.host); host != nil {
				backend.driver_notify(host, {kind = .Devices_Changed})
			}
		}
		free_all(context.temp_allocator)
	}
}

// "0:Loopback;1:PCH;" — card numbers and IDs, in order.
@(private)
card_signature :: proc() -> u64 {
	h: u64 = 14695981039346656037 // FNV-1a over the list
	card: c.int = -1
	for snd.snd_card_next(&card) == 0 && card >= 0 {
		ctl: snd.snd_ctl_t
		id := ""
		if snd.snd_ctl_open(&ctl, fmt.ctprintf("hw:%d", card), 0) >= 0 {
			info: snd.snd_ctl_card_info_t
			snd.snd_ctl_card_info_malloc(&info)
			if snd.snd_ctl_card_info(ctl, info) >= 0 do id = strings.clone(string(snd.snd_ctl_card_info_get_id(info)), context.temp_allocator)
			snd.snd_ctl_card_info_free(info)
			snd.snd_ctl_close(ctl)
		}
		for b in transmute([]u8)fmt.tprintf("%d:%s;", card, id) do h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

// Audio-thread health counters, for debugging driver problems. See diagnostics.
Diagnostics :: struct {
	recoveries: u64, // xrun/suspend restarts
	last_error: i64, // last negative ALSA result (-EPIPE = -32: xrun)
	last_op:    i32, // 1 read, 2 write
	states:     [2]i32, // playback, capture snd_pcm_state_t at the failure
	realtime:   bool, // the audio thread got SCHED_FIFO
}

// Snapshot of the driver's Diagnostics. `d` must come from create. Safe from
// any thread while the device runs.
diagnostics :: proc(d: ^backend.Driver) -> Diagnostics {
	a := (^Alsa)(d.data)
	return {
		recoveries = intrinsics.atomic_load(&a.recoveries),
		last_error = intrinsics.atomic_load(&a.last_error),
		last_op    = intrinsics.atomic_load(&a.last_op),
		states     = {intrinsics.atomic_load(&a.states[0]), intrinsics.atomic_load(&a.states[1])},
		realtime   = intrinsics.atomic_load(&a.realtime),
	}
}

// Whether the audio thread got realtime scheduling (valid while running).
has_realtime_priority :: proc(d: ^backend.Driver) -> bool {
	return intrinsics.atomic_load(&(^Alsa)(d.data).realtime)
}

@(private)
alsa_vtable := backend.Driver_VTable {
	destroy   = alsa_destroy,
	enumerate = alsa_enumerate,
	open      = alsa_open,
	start     = alsa_start,
	stop      = alsa_stop,
	close     = alsa_close,
}

@(private)
alsa_destroy :: proc(d: ^backend.Driver) {
	a := (^Alsa)(d.data)
	alsa_stop(d)
	alsa_close(d)
	if a.watcher != nil {
		intrinsics.atomic_store(&a.watch_stop, true)
		thread.join(a.watcher)
		thread.destroy(a.watcher)
	}
	free(a, a.allocator)
}

// --- enumeration ----------------------------------------------------------------------

@(private)
STANDARD_RATES := [?]u32{22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000}

// Devices are hardware PCMs, named "hw:CARD=<id>,DEV=<n>" (stable across
// reboots, unlike card numbers). Any ALSA PCM name ("default", "plughw:0")
// also works as a device ID in open.
@(private)
alsa_enumerate :: proc(d: ^backend.Driver, allocator: mem.Allocator) -> ([]backend.Device_Info, core.Error) {
	infos := make([dynamic]backend.Device_Info, allocator)
	card: c.int = -1
	for snd.snd_card_next(&card) == 0 && card >= 0 {
		ctl: snd.snd_ctl_t
		if snd.snd_ctl_open(&ctl, fmt.ctprintf("hw:%d", card), 0) < 0 do continue
		defer snd.snd_ctl_close(ctl)
		card_info: snd.snd_ctl_card_info_t
		snd.snd_ctl_card_info_malloc(&card_info)
		defer snd.snd_ctl_card_info_free(card_info)
		if snd.snd_ctl_card_info(ctl, card_info) < 0 do continue
		card_id := string(snd.snd_ctl_card_info_get_id(card_info))
		card_name := string(snd.snd_ctl_card_info_get_name(card_info))

		dev: c.int = -1
		for snd.snd_ctl_pcm_next_device(ctl, &dev) == 0 && dev >= 0 {
			id := fmt.tprintf("hw:CARD=%s,DEV=%d", card_id, dev)
			info := backend.Device_Info {
				id   = strings.clone(id, allocator),
				name = fmt.aprintf("%s: %s", card_name, pcm_name(ctl, dev), allocator = allocator),
			}
			probe(id, &info, allocator)
			append(&infos, info)
		}
	}
	return infos[:], .None
}

@(private)
pcm_name :: proc(ctl: snd.snd_ctl_t, dev: c.int) -> string {
	info: snd.snd_pcm_info_t
	snd.snd_pcm_info_malloc(&info)
	defer snd.snd_pcm_info_free(info)
	for stream in snd.snd_pcm_stream_t {
		snd.snd_pcm_info_set_device(info, c.uint(dev))
		snd.snd_pcm_info_set_subdevice(info, 0)
		snd.snd_pcm_info_set_stream(info, stream)
		if snd.snd_ctl_pcm_info(ctl, info) >= 0 do return strings.clone(string(snd.snd_pcm_info_get_name(info)), context.temp_allocator)
	}
	return ""
}

// Opens each direction briefly (non-blocking) to read its capabilities.
@(private)
probe :: proc(id: string, info: ^backend.Device_Info, allocator: mem.Allocator) {
	rates := make([dynamic]f64, allocator)
	sizes := make([dynamic]int, allocator)
	for stream in snd.snd_pcm_stream_t {
		pcm: snd.snd_pcm_t
		if snd.snd_pcm_open(&pcm, strings.clone_to_cstring(id, context.temp_allocator), stream, snd.SND_PCM_NONBLOCK) < 0 do continue
		defer snd.snd_pcm_close(pcm)
		hw: snd.snd_pcm_hw_params_t
		snd.snd_pcm_hw_params_malloc(&hw)
		defer snd.snd_pcm_hw_params_free(hw)
		if snd.snd_pcm_hw_params_any(pcm, hw) < 0 do continue
		max_ch: c.uint
		snd.snd_pcm_hw_params_get_channels_max(hw, &max_ch)
		if stream == .PLAYBACK do info.output_channels = int(min(max_ch, core.MAX_CHANNELS))
		else do info.input_channels = int(min(max_ch, core.MAX_CHANNELS))
		if len(rates) == 0 {
			for r in STANDARD_RATES do if snd.snd_pcm_hw_params_test_rate(pcm, hw, c.uint(r), 0) == 0 do append(&rates, f64(r))
			lo, hi: snd.snd_pcm_uframes_t
			snd.snd_pcm_hw_params_get_period_size_min(hw, &lo, nil)
			snd.snd_pcm_hw_params_get_period_size_max(hw, &hi, nil)
			for n := 16; n <= 4096; n *= 2 do if snd.snd_pcm_uframes_t(n) >= lo && snd.snd_pcm_uframes_t(n) <= hi do append(&sizes, n)
		}
	}
	info.sample_rates = rates[:]
	info.buffer_sizes = sizes[:]
	info.default_sample_rate = 48_000 if contains(rates[:], 48_000) else (rates[0] if len(rates) > 0 else 0)
	info.default_buffer_frames = 256 if contains(sizes[:], 256) else (sizes[0] if len(sizes) > 0 else 0)
}

// --- open / close -----------------------------------------------------------------------

@(private)
FORMAT_PREFERENCE := [?]snd.snd_pcm_format_t{.FLOAT_LE, .S32_LE, .S24_3LE, .S24_LE, .S16_LE}

@(private)
to_sample_format :: proc(f: snd.snd_pcm_format_t) -> backend.Sample_Format {
	#partial switch f {
	case .FLOAT_LE:   return .F32
	case .FLOAT64_LE: return .F64
	case .S32_LE:     return .I32
	case .S24_3LE:    return .I24
	case .S24_LE:     return .I24_In_32
	}
	return .I16
}

@(private)
alsa_open :: proc(d: ^backend.Driver, setup: backend.Device_Setup) -> (backend.Device_Format, core.Error) {
	a := (^Alsa)(d.data)
	if a.is_open do return {}, .Invalid_State
	out_id := setup.output_device_id if setup.output_device_id != "" else "default"
	in_id := setup.input_device_id if setup.input_device_id != "" else out_id
	if setup.input_channels != {} && setup.output_channels != {} && card_of(in_id) != card_of(out_id) {
		return {}, .Unsupported // different cards run on different clocks
	}
	rate := u32(setup.sample_rate) if setup.sample_rate > 0 else 48_000
	period := setup.buffer_frames if setup.buffer_frames > 0 else 256

	err: core.Error
	if setup.output_channels != {} {
		if a.play, period, err = open_stream(out_id, .PLAYBACK, highest(setup.output_channels) + 1, rate, period, PERIODS); err != .None {
			close_streams(a)
			return {}, err
		}
	}
	if setup.input_channels != {} {
		got: int
		if a.capture, got, err = open_stream(in_id, .CAPTURE, highest(setup.input_channels) + 1, rate, period, CAPTURE_PERIODS); err != .None {
			close_streams(a)
			return {}, err
		}
		if a.play.pcm != nil && got != period {
			close_streams(a)
			return {}, .Unsupported // the two directions must share a period size
		}
		period = got
	}
	a.period = period
	a.buffer_len = period * PERIODS
	if alloc_err := alloc_buffers(a); alloc_err != nil {
		close_streams(a)
		return {}, .Out_Of_Memory
	}
	a.format = {
		sample_rate            = f64(rate),
		buffer_frames          = period,
		max_driver_frames      = period,
		input_channels         = setup.input_channels,
		output_channels        = setup.output_channels,
		device_input_channels  = a.capture.channels,
		device_output_channels = a.play.channels,
		input_format           = to_sample_format(a.capture.format),
		output_format          = to_sample_format(a.play.format),
		output_latency_frames  = a.buffer_len - period, // queued ahead of the period being written
	}
	a.is_open = true
	return a.format, .None
}

@(private)
open_stream :: proc(id: string, dir: snd.snd_pcm_stream_t, channels: int, rate: u32, period: int, periods: int) -> (s: Stream, got_period: int, err: core.Error) {
	if snd.snd_pcm_open(&s.pcm, strings.clone_to_cstring(id, context.temp_allocator), dir, snd.SND_PCM_NONBLOCK) < 0 {
		return {}, 0, .Invalid_Argument
	}
	hw: snd.snd_pcm_hw_params_t
	snd.snd_pcm_hw_params_malloc(&hw)
	defer snd.snd_pcm_hw_params_free(hw)
	fail :: proc(s: ^Stream, e: core.Error) -> (Stream, int, core.Error) {
		snd.snd_pcm_close(s.pcm)
		return {}, 0, e
	}
	if snd.snd_pcm_hw_params_any(s.pcm, hw) < 0 do return fail(&s, .Device_Error)
	snd.snd_pcm_hw_params_set_rate_resample(s.pcm, hw, 0) // exact rate or nothing
	if snd.snd_pcm_hw_params_set_access(s.pcm, hw, .RW_INTERLEAVED) < 0 do return fail(&s, .Unsupported)

	s.format = .UNKNOWN
	for f in FORMAT_PREFERENCE do if snd.snd_pcm_hw_params_test_format(s.pcm, hw, f) == 0 {
		s.format = f
		break
	}
	if s.format == .UNKNOWN || snd.snd_pcm_hw_params_set_format(s.pcm, hw, s.format) < 0 do return fail(&s, .Unsupported)

	min_ch, max_ch: c.uint
	snd.snd_pcm_hw_params_get_channels_min(hw, &min_ch)
	snd.snd_pcm_hw_params_get_channels_max(hw, &max_ch)
	if c.uint(channels) > max_ch do return fail(&s, .Invalid_Argument)
	s.channels = max(channels, int(min_ch))
	if snd.snd_pcm_hw_params_set_channels(s.pcm, hw, c.uint(s.channels)) < 0 do return fail(&s, .Unsupported)

	if snd.snd_pcm_hw_params_test_rate(s.pcm, hw, c.uint(rate), 0) < 0 do return fail(&s, .Unsupported)
	snd.snd_pcm_hw_params_set_rate(s.pcm, hw, c.uint(rate), 0)
	frames := snd.snd_pcm_uframes_t(period)
	n_periods := c.uint(periods)
	snd.snd_pcm_hw_params_set_period_size_near(s.pcm, hw, &frames, nil)
	snd.snd_pcm_hw_params_set_periods_near(s.pcm, hw, &n_periods, nil)
	if snd.snd_pcm_hw_params(s.pcm, hw) < 0 do return fail(&s, .Unsupported)
	snd.snd_pcm_hw_params_get_period_size(hw, &frames, nil)
	got_period = int(frames)
	if got_period != period do return fail(&s, .Unsupported) // asked for a size the device can't do

	sw: snd.snd_pcm_sw_params_t
	snd.snd_pcm_sw_params_malloc(&sw)
	defer snd.snd_pcm_sw_params_free(sw)
	snd.snd_pcm_sw_params_current(s.pcm, sw)
	snd.snd_pcm_sw_params_set_avail_min(s.pcm, sw, frames)
	// Never start on our own: we start explicitly (playback once prefilled).
	snd.snd_pcm_sw_params_set_start_threshold(s.pcm, sw, max(snd.snd_pcm_uframes_t)/2)
	if snd.snd_pcm_sw_params(s.pcm, sw) < 0 do return fail(&s, .Device_Error)

	s.bytes = backend.sample_format_bytes(to_sample_format(s.format))
	return s, got_period, .None
}

@(private)
alloc_buffers :: proc(a: ^Alsa) -> (err: mem.Allocator_Error) {
	if a.play.pcm != nil do a.play.buffer = make([]u8, a.period * a.play.channels * a.play.bytes, a.allocator) or_return
	if a.capture.pcm != nil do a.capture.buffer = make([]u8, a.period * a.capture.channels * a.capture.bytes, a.allocator) or_return
	return nil
}

@(private)
close_streams :: proc(a: ^Alsa) {
	for s in ([]^Stream{&a.play, &a.capture}) {
		if s.pcm != nil do snd.snd_pcm_close(s.pcm)
		delete(s.buffer, a.allocator)
		s^ = {}
	}
}

@(private)
alsa_close :: proc(d: ^backend.Driver) {
	a := (^Alsa)(d.data)
	if !a.is_open do return
	close_streams(a)
	a.is_open = false
}

// --- start / stop -------------------------------------------------------------------------

@(private)
alsa_start :: proc(d: ^backend.Driver) -> core.Error {
	a := (^Alsa)(d.data)
	if !a.is_open || a.thread != nil do return .Invalid_State
	intrinsics.atomic_store(&a.stop_flag, false)
	intrinsics.atomic_store(&a.realtime, false)
	a.xrun_pending, a.lost = false, false
	a.clock = {}
	if restart(a) < 0 do return .Device_Error
	a.thread = thread.create_and_start_with_data(a, audio_thread)
	return .None if a.thread != nil else .Device_Error
}

// The thread waits at most 100 ms per wake, so this returns promptly.
@(private)
alsa_stop :: proc(d: ^backend.Driver) {
	a := (^Alsa)(d.data)
	if a.thread == nil do return
	intrinsics.atomic_store(&a.stop_flag, true)
	thread.join(a.thread)
	thread.destroy(a.thread)
	a.thread = nil
	if a.play.pcm != nil do snd.snd_pcm_drop(a.play.pcm)
	if a.capture.pcm != nil do snd.snd_pcm_drop(a.capture.pcm)
}

// Prepare, prefill playback with silence, start. Linked streams prepare and
// start together. Used at start and after every xrun.
@(private)
restart :: proc "contextless" (a: ^Alsa) -> c.int {
	for pcm in ([]snd.snd_pcm_t{a.play.pcm, a.capture.pcm}) {
		if pcm == nil do continue
		snd.snd_pcm_drop(pcm)
		if r := snd.snd_pcm_prepare(pcm); r < 0 do return r
	}
	if a.play.pcm != nil {
		intrinsics.mem_zero(raw_data(a.play.buffer), len(a.play.buffer))
		for _ in 0 ..< PERIODS {
			if r := write_all(a, a.play.buffer); r < 0 do return c.int(r)
		}
	}
	if a.capture.pcm != nil {
		if r := snd.snd_pcm_start(a.capture.pcm); r < 0 do return r
	}
	if a.play.pcm != nil do return snd.snd_pcm_start(a.play.pcm)
	return 0
}

// --- audio thread ----------------------------------------------------------------------------

@(private)
audio_thread :: proc(data: rawptr) {
	a := (^Alsa)(data)
	intrinsics.atomic_store(&a.realtime, rt.set_realtime_priority(80))
	ns_per_frame := 1e9 / a.format.sample_rate

	for !intrinsics.atomic_load(&a.stop_flag) {
		if a.lost {
			snd.snd_pcm_wait(a.play.pcm if a.play.pcm != nil else a.capture.pcm, 100)
			continue
		}
		// Pace on playback space when there is playback, then read the matching
		// capture period. Capture wake-ups alone are not reliable: snd-aloop
		// signals capture periods late and playback underruns meanwhile.
		if a.play.pcm != nil {
			r := wait_play_space(a)
			if r == -snd.EAGAIN do continue // timed out; check stop and try again
			if r < 0 {
				intrinsics.atomic_store(&a.last_op, 2)
				handle_error(a, r)
				continue
			}
		}
		if a.capture.pcm != nil {
			r := read_all(a)
			if r == -snd.EAGAIN do continue
			if r < 0 {
				intrinsics.atomic_store(&a.last_op, 1)
				handle_error(a, r)
				continue
			}
		}

		now := rt.host_time_ns()
		buf := backend.Driver_Buffers {
			frames      = a.period,
			callback_ns = now,
			xrun        = a.xrun_pending,
		}
		if a.xrun_pending do a.clock.valid = false
		a.xrun_pending = false
		// Output: what we write now is heard after everything already queued.
		// Input: the period just read started `period + still buffered` frames ago.
		measured_out, measured_in := f64(now), f64(now)
		if a.play.pcm != nil {
			delay: snd.snd_pcm_sframes_t
			snd.snd_pcm_delay(a.play.pcm, &delay)
			measured_out += f64(max(delay, 0)) * ns_per_frame
			a.out_planes[0] = {raw_data(a.play.buffer), a.play.channels}
			buf.output = a.out_planes[:]
		}
		if a.capture.pcm != nil {
			delay: snd.snd_pcm_sframes_t
			snd.snd_pcm_delay(a.capture.pcm, &delay)
			measured_in -= f64(a.period + int(max(delay, 0))) * ns_per_frame
			a.in_planes[0] = {raw_data(a.capture.buffer), a.capture.channels}
			buf.input = a.in_planes[:]
		}
		out_ns, in_ns := clock_update(&a.clock, measured_out, measured_in, f64(a.period) * ns_per_frame)
		if a.play.pcm != nil do buf.output_ns = out_ns
		if a.capture.pcm != nil do buf.input_ns = in_ns
		backend.driver_process(a.driver.host, &buf)

		if a.play.pcm != nil {
			if r := write_all(a, a.play.buffer); r < 0 {
				intrinsics.atomic_store(&a.last_op, 2)
				handle_error(a, r)
			}
		}
	}
}

// [rt] Waits until playback has room for a period. Returns frames available,
// -EAGAIN after 100 ms without room, or a negative ALSA error (xrun).
@(private)
wait_play_space :: proc "contextless" (a: ^Alsa) -> c.long {
	for {
		avail := snd.snd_pcm_avail(a.play.pcm)
		if avail < 0 || int(avail) >= a.period do return avail
		if intrinsics.atomic_load(&a.stop_flag) do return -snd.EAGAIN
		if snd.snd_pcm_wait(a.play.pcm, 100) == 0 do return -snd.EAGAIN
	}
}

// [rt] Reads one period into capture.buffer. Returns frames, -EAGAIN after
// waiting 100 ms with nothing ready, or another negative ALSA error.
@(private)
read_all :: proc "contextless" (a: ^Alsa) -> c.long {
	got := 0
	frame_bytes := a.capture.channels * a.capture.bytes
	for got < a.period {
		r := snd.snd_pcm_readi(a.capture.pcm, &a.capture.buffer[got * frame_bytes], snd.snd_pcm_uframes_t(a.period - got))
		if r == -snd.EAGAIN {
			if snd.snd_pcm_wait(a.capture.pcm, 100) == 0 && got == 0 do return -snd.EAGAIN
			if intrinsics.atomic_load(&a.stop_flag) do return -snd.EAGAIN
			continue
		}
		if r < 0 do return r
		if r == 0 {
			if intrinsics.atomic_load(&a.stop_flag) do return -snd.EAGAIN
			snd.snd_pcm_wait(a.capture.pcm, 100)
		}
		got += int(r)
	}
	return c.long(got)
}

// [rt] Writes a whole period, waiting for space as needed.
@(private)
write_all :: proc "contextless" (a: ^Alsa, data: []u8) -> c.long {
	done := 0
	frame_bytes := a.play.channels * a.play.bytes
	frames := len(data) / frame_bytes
	for done < frames {
		r := snd.snd_pcm_writei(a.play.pcm, &data[done * frame_bytes], snd.snd_pcm_uframes_t(frames - done))
		if r == -snd.EAGAIN {
			snd.snd_pcm_wait(a.play.pcm, 100)
			if intrinsics.atomic_load(&a.stop_flag) do return c.long(done)
			continue
		}
		if r < 0 do return r
		if r == 0 {
			if intrinsics.atomic_load(&a.stop_flag) do return c.long(done)
			snd.snd_pcm_wait(a.play.pcm, 100)
		}
		done += int(r)
	}
	return c.long(done)
}

// Xrun or suspend: restart and flag the next block. Device gone: report it and
// idle until stopped. (driver_notify takes a mutex; acceptable here because
// the stream is already broken.)
@(private)
handle_error :: proc(a: ^Alsa, r: c.long) {
	intrinsics.atomic_store(&a.last_error, i64(r))
	if a.play.pcm != nil do intrinsics.atomic_store(&a.states[0], i32(snd.snd_pcm_state(a.play.pcm)))
	if a.capture.pcm != nil do intrinsics.atomic_store(&a.states[1], i32(snd.snd_pcm_state(a.capture.pcm)))
	if r == -snd.ENODEV || r == -snd.EBADFD {
		a.lost = true
		backend.driver_notify(a.driver.host, {kind = .Device_Lost})
		return
	}
	intrinsics.atomic_add(&a.recoveries, 1)
	a.xrun_pending = true
	if restart(a) < 0 {
		a.lost = true
		backend.driver_notify(a.driver.host, {kind = .Error, error = .Device_Error})
	}
}

// --- helpers --------------------------------------------------------------------------------

// "hw:CARD=Loopback,DEV=0" → "Loopback"; "hw:1,0" → "1"; other names as is.
@(private)
card_of :: proc(id: string) -> string {
	s := id
	if i := strings.index_byte(s, ':'); i >= 0 do s = s[i + 1:]
	s = strings.trim_prefix(s, "CARD=")
	if i := strings.index_byte(s, ','); i >= 0 do s = s[:i]
	return s
}

@(private)
highest :: proc(mask: backend.Channel_Mask) -> int {
	h := -1
	for ch in mask do h = max(h, ch)
	return h
}

@(private)
contains :: proc(xs: []$T, x: T) -> bool {
	for v in xs do if v == x do return true
	return false
}
