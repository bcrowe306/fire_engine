package test_sampler

import "core:log"
import "core:math"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:core"
import "fire:dsp"
import "fire:sampler"
import "fire:stream"
import tb "fire:timebase"
import kit "fire:testkit"

// 200 Hz and 6 kHz together, 2 s at 48 kHz: a dark and a bright part.
two_tone :: proc(l: ^Lab) -> ^stream.Source {
	path, _ := filepath.join({l.dir, "two.wav"}, context.temp_allocator)
	n := int(2 * SR)
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x do v = f32(0.3 * math.sin(math.TAU * 200 * f64(i) / SR) + 0.3 * math.sin(math.TAU * 6000 * f64(i) / SR))
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SR, 1))
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	src, _ := stream.source_open(l.streamer, path)
	for stream.source_state(src) == .Loading do time.sleep(time.Millisecond)
	return src
}

set :: proc(id: core.Param_Id, v: f64, at := 0) -> kit.Timed_Event {
	return {tb.Sample_Time(at), core.Param_Value{id, v}}
}

// The bright part's level over its dark part's in a window.
brightness :: proc(x: []f32) -> f64 {
	return kit.tone_amplitude(x, SR, 6000) / max(kit.tone_amplitude(x, SR, 200), 1e-9)
}

@(test)
the_filter_darkens_and_24_db_is_steeper :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	src := two_tone(l)
	defer stream.source_release(src)
	zone := []sampler.Sample_Zone{{source = src, root_key = 60}}
	open := play(t, zone, 9600, {on(0, 60)})
	lp12 := play(t, zone, 9600, {set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 1000), on(0, 60)})
	lp24 := play(t, zone, 9600, {set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_SLOPE, 1), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 1000), on(0, 60)})
	hp := play(t, zone, 9600, {set(sampler.SAMPLER_PARAM_FILTER_TYPE, 2), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 1000), on(0, 60)})
	w := 4800
	b0, b12, b24, bhp := brightness(open.channels[0][w:]), brightness(lp12.channels[0][w:]), brightness(lp24.channels[0][w:]), brightness(hp.channels[0][w:])
	testing.expectf(t, b12 < b0 * 0.1, "a lowpass at 1 kHz takes 6 kHz down (%v → %v)", b0, b12)
	testing.expectf(t, b24 < b12 * 0.2, "24 dB more (%v vs %v)", b24, b12)
	testing.expectf(t, bhp > b0 * 10, "a highpass keeps the top (%v → %v)", b0, bhp)
}

@(test)
the_filter_envelope_opens_and_closes :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	src := two_tone(l)
	defer stream.source_release(src)
	zone := []sampler.Sample_Zone{{source = src, root_key = 60}}
	out := play(t, zone, int(SR), {
		set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 300),
		set(sampler.SAMPLER_PARAM_FILTER_ENV, 100), set(sampler.SAMPLER_PARAM_FILTER_DECAY, 1), set(sampler.SAMPLER_PARAM_FILTER_SUSTAIN, 0),
		on(0, 60),
	})
	early, late := brightness(out.channels[0][480:][:2400]), brightness(out.channels[0][int(SR) - 4800:])
	testing.expectf(t, early > late * 20, "bright at first, dark after the decay (%v, %v)", early, late)
}

@(test)
velocity_and_key_track_the_cutoff :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	src := two_tone(l)
	defer stream.source_release(src)
	zone := []sampler.Sample_Zone{{source = src, root_key = 60, key_lo = 0, key_hi = 127}}
	base := []kit.Timed_Event{set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 1500), set(sampler.SAMPLER_PARAM_FILTER_VELOCITY, 100), set(sampler.SAMPLER_PARAM_PITCH_KEYTRACK, 0)}
	ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
	append(&ev, ..base)
	append(&ev, on(0, 60, 1))
	hard := play(t, zone, 9600, ev[:])
	ev[len(ev) - 1] = on(0, 60, 0.3)
	soft := play(t, zone, 9600, ev[:])
	testing.expectf(t, brightness(soft.channels[0][4800:]) < brightness(hard.channels[0][4800:]) * 0.3, "softer is darker")
	// Key tracking (the pitch held at the root, so only the cutoff moves).
	append(&ev, set(sampler.SAMPLER_PARAM_FILTER_KEYTRACK, 100))
	ev[len(base)] = on(0, 84, 1)
	up := play(t, zone, 9600, ev[:])
	testing.expectf(t, brightness(up.channels[0][4800:]) > brightness(hard.channels[0][4800:]) * 3, "two octaves up opens it two octaves")
}

@(test)
the_pitch_envelope_and_fine_tune :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	zone := []sampler.Sample_Zone{{source = l.high, root_key = 60}} // 1 kHz
	out := play(t, zone, int(SR), {set(sampler.SAMPLER_PARAM_PITCH_ENV, 12), set(sampler.SAMPLER_PARAM_PITCH_DECAY, 0.15), set(sampler.SAMPLER_PARAM_PITCH_SUSTAIN, 0), on(0, 60)})
	first := f64(cycles(out.channels[0][:960])) / 0.02
	last := f64(cycles(out.channels[0][24_000:][:4800])) / 0.1
	testing.expectf(t, first > 1300, "up at the start, falling (%v Hz)", first)
	testing.expectf(t, abs(last - 1000) < 15, "back at its pitch (%v Hz)", last)
	fine := play(t, zone, int(SR), {set(sampler.SAMPLER_PARAM_FINE_TUNE, 100), on(0, 60)})
	hz := f64(cycles(fine.channels[0][4800:][:24000])) / 0.5
	testing.expectf(t, abs(hz - 1059.5) < 6, "100 cents: a semitone up (%v Hz)", hz)
}

@(test)
lfos_wobble_what_they_are_routed_to :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	zone := []sampler.Sample_Zone{{source = l.high, root_key = 60}}
	// LFO 1 at 4 Hz on volume (route 1), 100%: a tremolo.
	trem := play(t, zone, int(SR / 2), {
		set(sampler.SAMPLER_PARAM_LFO_RATE, 4), set(sampler.SAMPLER_PARAM_LFO_MODE, 1),
		set(sampler.SAMPLER_PARAM_ROUTE_DEST, f64(sampler.Mod_Dest.Volume)), set(sampler.SAMPLER_PARAM_ROUTE_AMOUNT, 100), on(0, 60),
	})
	lo, hi: f64 = 1e9, 0
	for k in 0 ..< 20 {
		r := kit.rms(trem.channels[0][k * 1200:][:1200])
		lo, hi = min(lo, r), max(hi, r)
	}
	testing.expectf(t, lo < hi * 0.3, "it swells and dips (%v .. %v)", lo, hi)
	// LFO 2 (route 4) on pitch, a square at 2 Hz, ±1 semitone (amount 1/12).
	vib := play(t, zone, int(SR), {
		set(sampler.sampler_lfo_param(1, sampler.SAMPLER_PARAM_LFO_SHAPE), f64(sampler.Lfo_Shape.Square)),
		set(sampler.sampler_lfo_param(1, sampler.SAMPLER_PARAM_LFO_RATE), 2), set(sampler.sampler_lfo_param(1, sampler.SAMPLER_PARAM_LFO_MODE), 1),
		set(sampler.sampler_route_param(3, sampler.SAMPLER_PARAM_ROUTE_DEST), f64(sampler.Mod_Dest.Pitch)),
		set(sampler.sampler_route_param(3, sampler.SAMPLER_PARAM_ROUTE_AMOUNT), 100.0 / 12), on(0, 60),
	})
	up := f64(cycles(vib.channels[0][1200:][:9600])) / 0.2
	down := f64(cycles(vib.channels[0][13200:][:9600])) / 0.2
	testing.expectf(t, abs(up - 1059.5) < 12 && abs(down - 943.9) < 12, "a semitone up, then down (%v, %v)", up, down)
}

@(test)
a_synced_lfo_follows_the_beat :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	zone := []sampler.Sample_Zone{{source = l.high, root_key = 60}}
	node, s := sampler.sampler_create({})
	defer core.node_destroy(&node)
	m, _ := sampler.sample_map_create(zone)
	sampler.sampler_set_map(s, m)
	sampler.sample_map_release(m)
	cfg := kit.default_render_config()
	cfg.tempo_bpm = 120
	// A 1/4 square on volume at 120 BPM: on for an eighth (0.25 s), off for one.
	cfg.events = {
		set(sampler.SAMPLER_PARAM_LFO_SHAPE, f64(sampler.Lfo_Shape.Square)), set(sampler.SAMPLER_PARAM_LFO_MODE, f64(sampler.Lfo_Mode.Sync)),
		set(sampler.SAMPLER_PARAM_LFO_SYNC_RATE, 4), set(sampler.SAMPLER_PARAM_ROUTE_DEST, f64(sampler.Mod_Dest.Volume)), set(sampler.SAMPLER_PARAM_ROUTE_AMOUNT, 100),
		on(0, 60),
	}
	out, r := kit.render(&node, kit.buffer_length_only(int(SR), SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	on_ := kit.rms(out.channels[0][1200:][:9600]) // 0.025..0.225 s: the first half beat
	off_ := kit.rms(out.channels[0][13200:][:9600])
	testing.expectf(t, on_ > 0.2 && off_ < 0.01, "on, then off, with the beat (%v, %v)", on_, off_)
}

@(test)
modulation_is_block_invariant :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	cfg := kit.default_render_config()
	cfg.tempo_bpm = 128
	cfg.events = {
		set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_SLOPE, 1), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 800),
		set(sampler.SAMPLER_PARAM_FILTER_RESONANCE, 60), set(sampler.SAMPLER_PARAM_FILTER_ENV, 70), set(sampler.SAMPLER_PARAM_PITCH_ENV, -5),
		set(sampler.SAMPLER_PARAM_LFO_MODE, f64(sampler.Lfo_Mode.Trigger)), set(sampler.SAMPLER_PARAM_LFO_RATE, 5),
		set(sampler.SAMPLER_PARAM_ROUTE_DEST, f64(sampler.Mod_Dest.Cutoff)), set(sampler.SAMPLER_PARAM_ROUTE_AMOUNT, 40),
		set(sampler.sampler_lfo_param(1, sampler.SAMPLER_PARAM_LFO_MODE), f64(sampler.Lfo_Mode.Sync)),
		set(sampler.sampler_lfo_param(1, sampler.SAMPLER_PARAM_LFO_SHAPE), f64(sampler.Lfo_Shape.Sample_Hold)),
		set(sampler.sampler_route_param(3, sampler.SAMPLER_PARAM_ROUTE_DEST), f64(sampler.Mod_Dest.Pan)),
		set(sampler.sampler_route_param(3, sampler.SAMPLER_PARAM_ROUTE_AMOUNT), 80),
		on(0, 69), on(1_000, 62, 0.4), on(7_000, 50), off(12_000, 69), on(15_000, 40),
	}
	patterns := kit.standard_block_patterns(cfg.max_block)
	for quality in ([]sampler.Sampler_Quality{.Cubic, .Sinc_Medium}) {
		args := Factory_Args{l, quality}
		factory := sampler_factory
		factory.user = &args
		kit.expect_block_invariant(t, factory, kit.buffer_length_only(30_000, SR), cfg, patterns[:], 0, "modulated sampler")
	}
}

@(test)
the_live_state_shows_the_modulated_filter :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	node, s := sampler.sampler_create({})
	defer core.node_destroy(&node)
	m, _ := sampler.sample_map_create({{source = l.high, root_key = 60}})
	sampler.sampler_set_map(s, m)
	sampler.sample_map_release(m)
	cfg := kit.default_render_config()
	cfg.events = {set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_CUTOFF, 500), set(sampler.SAMPLER_PARAM_FILTER_ENV, 100), set(sampler.SAMPLER_PARAM_FILTER_SUSTAIN, 50), on(0, 60)}
	out, r := kit.render(&node, kit.buffer_length_only(24_000, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	_ = out
	live := sampler.sampler_live(s)
	testing.expect(t, live.sounding, "a voice sounds")
	// Sustaining at half: 3 octaves over 500 Hz.
	testing.expectf(t, abs(live.cutoff - 4000) < 200, "the cutoff with its envelope (%v Hz)", live.cutoff)
	testing.expectf(t, abs(live.filter_env - 0.5) < 0.01, "the envelope at its sustain (%v)", live.filter_env)
	// The response a UI draws: −3 dB at the cutoff for a flat 12 dB lowpass.
	c, n := sampler.voice_filter_design(.Lowpass, false, 1000, 0, SR)
	g, _ := dsp.svf_response(&c[0], 1000, SR)
	testing.expect_value(t, n, 1)
	testing.expectf(t, abs(20 * math.log10(g) + 3) < 0.1, "−3 dB at 1 kHz (%v)", 20 * math.log10(g))
}

// How much the voice's filter and LFOs cost: 32 voices for a second, plain
// and modulated (logged; the numbers are in the guide).
@(test)
modulation_cost :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	run :: proc(t: ^testing.T, l: ^Lab, modulated: bool) -> f64 {
		node, s := sampler.sampler_create({voices = 32})
		defer core.node_destroy(&node)
		m, _ := sampler.sample_map_create({{source = l.sine, root_key = 69, loop = true, loop_start = 1000, loop_end = 40_000}})
		sampler.sampler_set_map(s, m)
		sampler.sample_map_release(m)
		cfg := kit.default_render_config()
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		if modulated {
			append(&ev, set(sampler.SAMPLER_PARAM_FILTER_TYPE, 1), set(sampler.SAMPLER_PARAM_FILTER_SLOPE, 1), set(sampler.SAMPLER_PARAM_FILTER_ENV, 50), set(sampler.SAMPLER_PARAM_PITCH_ENV, 2),
				set(sampler.SAMPLER_PARAM_LFO_MODE, 1), set(sampler.SAMPLER_PARAM_ROUTE_DEST, f64(sampler.Mod_Dest.Cutoff)), set(sampler.SAMPLER_PARAM_ROUTE_AMOUNT, 30),
				set(sampler.sampler_route_param(3, sampler.SAMPLER_PARAM_ROUTE_DEST), f64(sampler.Mod_Dest.Pitch)), set(sampler.sampler_route_param(3, sampler.SAMPLER_PARAM_ROUTE_AMOUNT), 5))
		}
		for k in 0 ..< 32 do append(&ev, on(0, u8(40 + k)))
		cfg.events = ev[:]
		t0 := time.tick_now()
		_, r := kit.render(&node, kit.buffer_length_only(int(SR), SR), cfg, context.temp_allocator)
		defer kit.render_report_destroy(&r)
		kit.expect_clean_render(t, r)
		return time.duration_milliseconds(time.tick_since(t0))
	}
	plain, modulated := run(t, l, false), run(t, l, true)
	log.infof("32 voices for 1 s: plain %.1f ms, with a 24 dB filter, envelopes and LFOs %.1f ms (%.0f%% of real time)", plain, modulated, modulated / 10)
}
