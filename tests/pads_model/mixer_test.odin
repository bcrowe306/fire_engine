package test_pads_model

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:math"

import app "app:core"
import fc "fire:core"
import pm "../../apps/pads/model"
import "fire:dsp"
import "fire:synth"
import "fire:fx"
import kit "fire:testkit"

// A rig with a long 1 kHz tone on pad 0, played: its level after `frames`.
@(private)
tone_rig :: proc(t: ^testing.T, name: string, hz := 1000.0) -> ^Rig {
	r := rig_make(t, name)
	pm.load_onto_pad(&r.m, 0, tone(r, "t.wav", hz, 4))
	render(r, 256)
	return r
}

@(private)
level :: proc(r: ^Rig, frames := 9600) -> (l, rr: f64) {
	out := render(r, frames)
	return kit.peak(out[0][frames / 2:]), kit.peak(out[1][frames / 2:])
}

@(test)
pads_go_through_buses_with_faders_mute_and_solo :: proc(t: ^testing.T) {
	r := tone_rig(t, "mix_bus")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 1, tone(r, "u.wav", 1500, 4))
	pm.hit(&m.engine, 0, true)
	full, _ := level(r)
	testing.expectf(t, abs(full - 0.5) < 0.02, "main, unity (%v)", full)
	// Bus A at -12 dB.
	pm.set_pad_bus(m, 0, 1)
	b := m.project.buses[0]
	b.volume = -12
	pm.set_bus(m, 0, 0, "Set Volume", b)
	pm.sync(&m.engine)
	render(r, 4800)
	quiet, _ := level(r)
	testing.expectf(t, abs(quiet / full - 0.251) < 0.02, "bus A at -12 dB (%v)", quiet / full)
	// Muted bus: silent. Undo: back.
	b.mute = true
	pm.set_bus(m, 0, 1, "Mute", b)
	pm.sync(&m.engine)
	render(r, 4800)
	silent, _ := level(r)
	testing.expectf(t, silent < 1e-4, "muted (%v)", silent)
	app.undo(&m.history)
	pm.sync(&m.engine)
	render(r, 4800)
	back, _ := level(r)
	testing.expectf(t, back > 0.1, "unmuted (%v)", back)
	// Solo pad 1: pad 0 goes quiet.
	pm.hit(&m.engine, 1, true)
	pad := m.project.pads[1]
	pad.solo = true
	pm.set_pad(m, 1, .Solo, "Solo", pad)
	pm.sync(&m.engine)
	out := render(r, 9600)
	x := out[0][4800:]
	testing.expectf(t, kit.tone_amplitude(x, SR, 1000) < 1e-3 && kit.tone_amplitude(x, SR, 1500) > 0.3, "only the soloed pad")
}

@(test)
inserts_shape_a_pad_and_undo :: proc(t: ^testing.T) {
	r := tone_rig(t, "mix_insert", 4000)
	defer rig_destroy(r)
	m := &r.m
	pm.hit(&m.engine, 0, true)
	open, _ := level(r)
	lp := pm.new_effect(.Low_Pass) // (the synth's filter now, as a low-pass)
	testing.expect_value(t, lp.kind, pm.Effect_Kind.Filter)
	pm.slot_set(&lp, synth.effect_param(.Filter, synth.Fx_Filter_Field.Cutoff), f32(69 + 12 * math.log2(300.0 / 440)))
	pm.set_insert(m, 0, 0, lp)
	pm.sync(&m.engine)
	render(r, 4800)
	dark, _ := level(r)
	testing.expectf(t, dark < open * 0.05, "a low-pass at 300 Hz cuts 4 kHz (%v → %v)", open, dark)
	// Switched off: through (a short fade, no new node).
	lp.on = false
	pm.set_insert(m, 0, 0, lp, "Bypass")
	pm.sync(&m.engine)
	render(r, 4800)
	through, _ := level(r)
	testing.expectf(t, abs(through - open) < 0.01, "bypassed (%v)", through)
	// Two inserts in a row, then all undone.
	lp.on = true
	pm.set_insert(m, 0, 0, lp)
	pm.set_insert(m, 0, 1, pm.new_effect(.Bitcrush))
	pm.sync(&m.engine)
	render(r, 4800)
	app.undo(&m.history)
	app.undo(&m.history)
	app.undo(&m.history)
	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[0].inserts[0].kind, pm.Effect_Kind.None)
	pm.sync(&m.engine)
	render(r, 4800)
	again, _ := level(r)
	testing.expectf(t, abs(again - open) < 0.01, "no inserts again (%v)", again)
}

@(test)
performance_effects_work_while_held :: proc(t: ^testing.T) {
	r := tone_rig(t, "mix_perf")
	defer rig_destroy(r)
	m := &r.m
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	// The ring modulator (slot 10) moves 1 kHz away while held.
	pm.hold_perf_fx(m, 10, true)
	pm.sync(&m.engine)
	render(r, 4800)
	out := render(r, 9600)
	testing.expectf(t, kit.tone_amplitude(out[0][:], SR, 1000) < 0.02, "held: the tone is moved")
	pm.hold_perf_fx(m, 10, false)
	pm.sync(&m.engine)
	render(r, 4800)
	out = render(r, 9600)
	testing.expectf(t, kit.tone_amplitude(out[0][:], SR, 1000) > 0.45, "let go: the tone again")
	// Their settings are edits (undoable); holding is not.
	fx := m.project.perf_fx[10]
	pm.slot_set(&fx, dsp.RING_PARAM_HZ, 50)
	pm.set_perf_fx(m, 10, 0, "Set Frequency", fx)
	testing.expect_value(t, app.undo_name(&m.history), "Set Frequency")
	testing.expect_value(t, pm.perf_label(m.project.perf_fx[6]), "Stutter 1/32")
	testing.expect_value(t, pm.perf_label(m.project.perf_fx[5]), "Stutter 1/16")
}

@(test)
bus_pan_and_meters :: proc(t: ^testing.T) {
	r := tone_rig(t, "mix_meter")
	defer rig_destroy(r)
	m := &r.m
	pm.set_pad_bus(m, 0, 2)
	b := m.project.buses[1]
	b.pan = -1
	pm.set_bus(m, 1, 2, "Set Pan", b)
	pm.sync(&m.engine)
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	pm.pad_level(&m.engine, 0)
	pm.bus_level(&m.engine, pm.BUSES)
	l, rr := level(r)
	testing.expectf(t, l > 0.6 && rr < 1e-4, "hard left: +3 dB left, nothing right (%v %v)", l, rr)
	peak, rms := pm.pad_level(&m.engine, 0)
	testing.expectf(t, abs(peak[0] - 0.5) < 0.02 && rms[0] > 0.3, "the pad's meter (%v %v)", peak[0], rms[0])
	mp, _ := pm.bus_level(&m.engine, pm.BUSES)
	testing.expectf(t, abs(mp[0] - 0.707) < 0.03 && mp[1] < 1e-4, "main's meter (%v)", mp)
	bp, _ := pm.bus_level(&m.engine, 0)
	testing.expect_value(t, bp[0], 0) // bus A has nothing
}

@(test)
a_clap_plugin_in_a_slot :: proc(t: ^testing.T) {
	path, _ := filepath.abs("../../.build/clap/FireOdin.clap", context.temp_allocator)
	if !os.exists(path) {
		path, _ = filepath.abs(".build/clap/FireOdin.clap", context.temp_allocator)
	}
	if !os.exists(path) {
		log_skip(t, "no test plug-ins (./scripts/clap.sh builds them)")
		return
	}
	r := tone_rig(t, "mix_clap")
	defer rig_destroy(r)
	m := &r.m
	pm.hit(&m.engine, 0, true)
	full, _ := level(r)
	b := m.project.main
	b.slots[0] = pm.new_plugin_effect(&m.project, path, "dev.fire-engine.odin.gain", "Gain")
	pm.slot_set(&b.slots[0], dsp.GAIN_PARAM_DB, -20)
	pm.set_bus(m, pm.BUSES, 10, "Add Plug-in", b)
	pm.sync(&m.engine)
	testing.expect(t, pm.slot_plugin(&m.engine, -1, pm.BUSES, 0) != nil, "the plug-in loaded")
	render(r, 9600)
	cut, _ := level(r)
	testing.expectf(t, abs(cut / full - 0.1) < 0.01, "-20 dB through the plug-in (%v)", cut / full)
	// A plug-in that is gone: the slot is skipped, and says so.
	b.slots[1] = pm.new_plugin_effect(&m.project, "/nowhere/missing.clap", "x", "Missing")
	pm.set_bus(m, pm.BUSES, 11, "Add Plug-in", b)
	pm.sync(&m.engine)
	testing.expect(t, pm.slot_failed(&m.engine, -1, pm.BUSES, 1), "missing")
	render(r, 4800)
	still, _ := level(r)
	testing.expectf(t, abs(still - cut) < 0.01, "the chain still plays (%v)", still)
}

@(private)
log_skip :: proc(t: ^testing.T, why: string) {
	log.infof("skipped: %s", why)
	_ = t
}

@(test)
sends_reach_buses_before_or_after_the_fader :: proc(t: ^testing.T) {
	r := tone_rig(t, "mix_sends")
	defer rig_destroy(r)
	m := &r.m
	pm.hit(&m.engine, 0, true)
	settle :: proc(r: ^Rig) -> f64 {
		pm.sync(&r.m.engine)
		render(r, 4800)
		l, _ := level(r)
		return l
	}
	direct := settle(r)
	testing.expectf(t, abs(direct - 0.5) < 0.02, "no sends: main only (%v)", direct)
	// A post-fader send to bus A at 0 dB: the same signal twice into main.
	pm.set_send_db(m, 0, 1, 0)
	app.seal(&m.history)
	both := settle(r)
	testing.expectf(t, abs(both / direct - 2) < 0.04, "send at 0 dB doubles it (%v)", both / direct)
	// The fader at -6 dB moves both paths.
	pad := m.project.pads[0]
	pad.volume = -6.0206
	pm.set_pad(m, 0, .Volume, "Set Volume", pad)
	app.seal(&m.history)
	post := settle(r)
	testing.expectf(t, abs(post / direct - 1) < 0.03, "post-fader: both halved (%v)", post / direct)
	// Pre-fader: the send ignores the fader (0.5 direct + 1 send).
	pm.set_send_pre(m, 0, 1, true)
	pre := settle(r)
	testing.expectf(t, abs(pre / direct - 1.5) < 0.04, "pre-fader (%v)", pre / direct)
	testing.expect_value(t, m.project.pads[0].sends[0].pre, true)
	// A stem of bus A hears only the send.
	m.engine.export_solo = {kind = .Bus, index = 1}
	stem := settle(r)
	testing.expectf(t, abs(stem / direct - 1) < 0.03, "bus A's stem: the send (%v)", stem / direct)
	m.engine.export_solo = {}
	// Muted: the sends go quiet too.
	pad = m.project.pads[0]
	pad.mute = true
	pm.set_pad(m, 0, .Mute, "Mute", pad)
	app.seal(&m.history)
	muted := settle(r)
	testing.expectf(t, muted < 1e-4, "muted (%v)", muted)
	// Undo: unmuted, post-fader, fader back, send off.
	app.undo(&m.history)
	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[0].sends[0].pre, false)
	app.undo(&m.history)
	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[0].sends[0].level, f32(0))
	back := settle(r)
	testing.expectf(t, abs(back - direct) < 0.01, "all undone (%v)", back)
	// Its dB and level agree; the knob's bottom is off.
	testing.expect(t, pm.send_level(pm.SEND_MIN_DB) == 0 && abs(pm.send_db({level = 0.5}) + 6.0206) < 0.01)
}

@(test)
a_watched_effect_feeds_the_tap :: proc(t: ^testing.T) {
	r := rig_make(t, "watch_tap")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "a.wav", 440, 0.5))
	fx := pm.Fx_Target{.Pad, 0, 0}
	pm.set_target_slot(m, fx, pm.new_effect(.Delay), "Add Effect")
	buf: [1024]f32
	testing.expect(t, !pm.watch_read(&m.engine, buf[:]), "nothing watched yet")
	pm.watch_slot(&m.engine, fx)
	pm.hit(&m.engine, 0, true)
	render(r, 9600)
	testing.expect(t, pm.watch_read(&m.engine, buf[:]), "watched")
	testing.expectf(t, kit.peak(buf[:]) > 0.05, "it hears the delay's output (%v)", kit.peak(buf[:]))
	// Watching nothing lets go of it.
	pm.watch_slot(&m.engine, {})
	render(r, 256)
	testing.expect(t, !pm.watch_read(&m.engine, buf[:]), "let go")
}

// Up to 16 buses: added, named, routed into each other (never round in a
// loop), sound going through a chain of them; deleted (what went to it
// goes to main, the ones after move up a letter); saved and loaded.
@(test)
buses_added_routed_and_deleted :: proc(t: ^testing.T) {
	r := tone_rig(t, "mix_buses")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	testing.expect_value(t, p.bus_count, pm.DEFAULT_BUSES)
	testing.expect_value(t, pm.add_bus(m), 5)
	testing.expect_value(t, pm.add_bus(m), 6)
	pm.rename_bus(m, 6, "Drums")
	testing.expect_value(t, pm.bus_name(p, 6), "Drums")
	testing.expect_value(t, pm.bus_name(p, 5), "Bus E")
	// Pad 0 into E, E into Drums (F), Drums into A: the tone through all.
	pm.set_pad_bus(m, 0, 5)
	testing.expect(t, pm.set_bus_dest(m, 5, 6), "E to Drums")
	testing.expect(t, pm.set_bus_dest(m, 6, 1), "Drums to A")
	testing.expect(t, !pm.set_bus_dest(m, 1, 5), "not A to E: a loop")
	testing.expect(t, !pm.set_bus_dest(m, 6, 6), "not to itself")
	b := p.buses[0]
	b.volume = -6
	pm.set_bus(m, 0, 0, "Set Volume", b)
	pm.sync(&m.engine)
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	l, _ := level(r)
	testing.expectf(t, abs(l - 0.5 * 0.501) < 0.02, "through E, Drums and A (-6 dB there): %v", l)
	// Muting the bus in the middle silences it.
	d := p.buses[5]
	d.mute = true
	pm.set_bus(m, 5, 1, "Mute", d)
	pm.sync(&m.engine)
	render(r, 4800)
	l, _ = level(r)
	testing.expectf(t, l < 1e-3, "Drums muted: nothing (%v)", l)
	app.undo(&m.history)
	// Saved and loaded: the buses, their names and routes, a send to F.
	pm.set_send_db(m, 0, 6, -3)
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "mix_buses_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	q := &r2.m.project
	testing.expect_value(t, q.bus_count, 6)
	testing.expect_value(t, pm.bus_name(q, 6), "Drums")
	testing.expect(t, q.buses[4].dest == 6 && q.buses[5].dest == 1 && q.pads[0].bus == 5, "the routes")
	testing.expectf(t, abs(pm.send_db(q.pads[0].sends[5]) + 3) < 0.01, "the send to F (%v)", pm.send_db(q.pads[0].sends[5]))
	// Deleting E: pad 0 goes to main; Drums becomes E (still into A).
	pm.delete_bus(m, 5)
	testing.expect_value(t, p.bus_count, 5)
	testing.expect_value(t, pm.bus_name(p, 5), "Drums")
	testing.expect(t, p.pads[0].bus == 0 && p.buses[4].dest == 1, "what went to E goes to main; Drums moved up")
	testing.expectf(t, abs(pm.send_db(p.pads[0].sends[4]) + 3) < 0.01, "the send moved with it")
	app.undo(&m.history)
	testing.expect(t, p.bus_count == 6 && p.pads[0].bus == 5 && pm.bus_name(p, 6) == "Drums", "one undo step")
}

// The app's old effects, as saved: each converted to the synth effect
// nearest it (a delay's time, feedback and mix; a low-pass's cutoff);
// a swapped insert plays (a reverb rings on after its pad stops).
@(test)
old_effects_convert_and_play :: proc(t: ^testing.T) {
	old := pm.Effect_Slot{kind = .Delay, on = true}
	pm.slot_set(&old, dsp.DELAY_PARAM_TIME_MS, 250)
	pm.slot_set(&old, dsp.DELAY_PARAM_FEEDBACK, 60)
	pm.slot_set(&old, dsp.DELAY_PARAM_MIX, 40)
	pm.slot_set(&old, dsp.DELAY_PARAM_PING_PONG, 1)
	testing.expect(t, pm.slot_is_legacy(old), "old settings seen")
	d := pm.convert_slot(old)
	f :: synth.Delay_Field
	hz := math.pow(2, pm.slot_value(d, synth.effect_param(.Delay, f.Hz), 0))
	testing.expectf(t, abs(hz - 4) < 1e-3, "250 ms: 4 repeats a second (%v)", hz)
	testing.expect_value(t, pm.slot_value(d, synth.effect_param(.Delay, f.Feedback), 0), 0.6)
	testing.expect_value(t, pm.slot_value(d, synth.effect_param(.Delay, f.Wet), 0), 0.4)
	testing.expect_value(t, pm.slot_value(d, synth.effect_param(.Delay, f.Style), 0), f32(fx.Delay_Style.Ping_Pong))
	testing.expect(t, !pm.slot_is_legacy(d) && d.on, "converted, still on")
	lp := pm.Effect_Slot{kind = .Low_Pass, on = true}
	pm.slot_set(&lp, dsp.FILTER_PARAM_CUTOFF_HZ, 880)
	c := pm.convert_slot(lp)
	testing.expect_value(t, c.kind, pm.Effect_Kind.Filter)
	testing.expectf(t, abs(pm.slot_value(c, synth.effect_param(.Filter, synth.Fx_Filter_Field.Cutoff), 0) - 81) < 1e-3, "880 Hz: key 81")

	r := rig_make(t, "mix_synth_fx")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "short.wav", 1000, 0.2)) // (a fifth of a second)
	render(r, 256)
	rv := pm.new_effect(.Reverb)
	pm.slot_set(&rv, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.6)
	pm.slot_set(&rv, synth.effect_param(.Reverb, synth.Reverb_Field.Decay), 2)
	pm.set_insert(m, 0, 0, rv)
	pm.sync(&m.engine)
	pm.hit(&m.engine, 0, true)
	render(r, 9_600)
	pm.hit(&m.engine, 0, false)
	out := render(r, 24_000) // from 0.2 s on: the sound over
	testing.expectf(t, kit.rms(out[0][12_000:]) > 1e-3, "a reverb tail after the pad stops (%v)", kit.rms(out[0][12_000:]))
	// Saved and loaded: the same slot.
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "mix_synth_fx_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	got := r2.m.project.pads[0].inserts[0]
	testing.expect(t, got.kind == .Reverb && pm.slot_value(got, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0) == 0.6, "saved")
}

@(test)
main_measures_its_loudness_and_stereo :: proc(t: ^testing.T) {
	r := rig_make(t, "main_loudness")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "long.wav", 440, 1.5))
	render(r, 256)
	mom, _, _, _ := pm.main_loudness(&m.engine)
	testing.expect_value(t, mom, f32(-144)) // nothing yet
	pm.hit(&m.engine, 0, true)
	render(r, 48_000) // a second of it
	short, integ, tp: f32
	mom, short, integ, tp = pm.main_loudness(&m.engine)
	testing.expectf(t, mom > -40 && mom < 0 && short > -40 && integ > -40, "a level (%v %v %v)", mom, short, integ)
	testing.expectf(t, tp > 0.05 && tp <= 1.2, "a true peak (%v)", tp)
	pts: [8][2]f32
	corr, n := pm.main_stereo(&m.engine, pts[:])
	testing.expectf(t, corr > 0.95 && n == 8, "a centred pad: in phase (%v)", corr)
	pm.main_loudness_reset(&m.engine)
	render(r, 2400)
	_, _, integ, _ = pm.main_loudness(&m.engine)
	testing.expect_value(t, integ, f32(-144))
}

@(test)
a_pads_eq_is_off_until_turned_on :: proc(t: ^testing.T) {
	r := rig_make(t, "eq_on")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "low.wav", 80, 1.5))
	testing.expect(t, !m.project.pads[0].eq_on, "off on a new pad")
	p := m.project.pads[0]
	p.eq[0] = 12 // the low shelf up 12 dB, but off
	pm.set_pad(m, 0, .Eq_Low, "EQ", p)
	level :: proc(r: ^Rig) -> f64 {
		pm.sync(&r.m.engine)
		render(r, 2400)
		pm.hit(&r.m.engine, 0, true)
		out := render(r, 24_000)
		pm.hit(&r.m.engine, 0, false)
		render(r, 24_000)
		return kit.rms(out[0][4800:])
	}
	flat := level(r)
	p = m.project.pads[0]
	p.eq_on = true
	pm.set_pad(m, 0, .Eq_Low, "EQ", p)
	up := level(r)
	testing.expectf(t, up > flat * 2, "on: the low shelf lifts it (%v → %v)", flat, up)
}
