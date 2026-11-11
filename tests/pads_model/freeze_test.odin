package test_pads_model

import "core:math"
import "core:testing"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import kit "fire:testkit"
import pm "../../apps/pads/model"

@(test)
a_frozen_pad_plays_its_rendering :: proc(t: ^testing.T) {
	r := blips(t, "freeze")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1})
	pd := p.pads[0]
	pd.volume = -12
	pm.set_pad(m, 0, .Volume, "Set Volume", pd)
	app.seal(&m.history)
	render(r, 4800) // (the fader glides there)
	play_level :: proc(r: ^Rig) -> f64 {
		render(r, 4800) // (a fader just made glides to where it is)
		pm.play(&r.m.engine)
		out := render_synced(r, 48_000 * 2, 480)
		pm.stop(&r.m.engine)
		render(r, 480)
		return kit.peak(out[0])
	}
	before := play_level(r)
	testing.expect(t, pm.can_freeze(p, 0) && !pm.can_freeze(p, 1), "pad 1 has no notes")
	m.engine.metronome = true // (never into a rendering)
	x: pm.Export
	if !testing.expect(t, pm.freeze_begin(m, &x, 0)) do return
	defer pm.export_destroy(&x)
	for !x.finished && !x.failed do pm.export_step(m, &x)
	pm.export_finish(m, &x)
	m.engine.metronome = false
	testing.expect(t, p.pads[0].frozen && p.freezes[0][0].sample != 0, "frozen, with its rendering")
	testing.expect_value(t, m.history.undo[len(m.history.undo) - 1].name, "Freeze")
	// The rendering: before its fader (12 dB up), the sequence's length,
	// no click (nothing between the notes' blips but silence).
	if s := app.store_get(&p.samples, p.freezes[0][0].sample); testing.expect(t, s != nil) {
		rd, err := audiofile.open(s.path)
		if testing.expect(t, err == nil) {
			info := audiofile.info(rd)
			testing.expect_value(t, info.frames, 96_000)
			buf := kit.buffer_make(2, int(info.frames), 48_000, context.temp_allocator)
			audiofile.read(rd, buf.channels, int(info.frames))
			audiofile.close(rd)
			pk := kit.peak(buf.channels[0])
			testing.expectf(t, abs(20 * math.log10(pk / before) - 12) < 1, "12 dB above its fader (%v vs %v)", pk, before)
			testing.expectf(t, kit.peak(buf.channels[0][int(0.6 * 24_000):int(0.95 * 24_000)]) < 1e-4, "silent between its blips (no click)")
		}
	}
	// Played frozen: as it was (its fader still works).
	after := play_level(r)
	testing.expectf(t, abs(20 * math.log10(after / before)) < 1, "frozen, it sounds the same (%v, %v)", after, before)
	// Saved and opened again: still frozen.
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "freeze_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	testing.expect(t, r2.m.project.pads[0].frozen && r2.m.project.freezes[0][0].sample == p.freezes[0][0].sample)
	// Unfrozen by undo; frozen again by redo; flattened to an audio pad.
	app.undo(&m.history)
	testing.expect(t, !p.pads[0].frozen)
	app.redo(&m.history)
	pm.flatten(m, 0)
	testing.expect(t, p.pads[0].kind == .Audio && !p.pads[0].frozen && p.clips[0][0].sample == p.freezes[0][0].sample)
	flat := play_level(r)
	testing.expectf(t, abs(20 * math.log10(flat / before)) < 1, "flattened, the same (%v)", flat)
}
