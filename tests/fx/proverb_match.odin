package test_fx

import "core:encoding/json"
import "core:math"
import "core:mem/virtual"

import "fire:core"
import "fire:fx"
import kit "fire:testkit"

// The reference's measurements (scripts/proverb_probe: the reference
// reverb rendered and measured as a black box), and ProVerb measured the
// same way for the same settings.

@(private = "file")
REFERENCE :: #load("../proverb/reference.json", string)

// One measured job (the fields the match uses).
Pv_Measured :: struct {
	name:        string,
	params:      map[string]f64,
	signal:      string,
	rt60:        [7]f64,
	rt60_wide:   f64,
	density_90:  f64,
	correlation: f64,
	spread_hz:   f64,
	level_db:    f64,
	first_ms:    f64,
	band_db:     [7]f64,
}

PV_BANDS :: [7]f64{125, 250, 500, 1000, 2000, 4000, 8000}

// The reference's measurements, parsed into `arena` (the caller's: freed
// with it), so each job's renders can go from the temp allocator as the
// test goes (they are megabytes each).
pv_reference :: proc(arena: ^virtual.Arena) -> []Pv_Measured {
	out: []Pv_Measured
	if err := json.unmarshal_string(REFERENCE, &out, allocator = virtual.arena_allocator(arena)); err != nil do return nil
	return out
}

// A reference job's settings as ProVerb's (`fx.proverb_reference_values`).
pv_settings :: proc(p: map[string]f64) -> fx.Proverb_Values { return fx.proverb_reference_values(p) }

// ProVerb (at `quality`) at settings `v`, measured as the reference was:
// an impulse (or a second of a 1 kHz sine) through it, `seconds` long.
pv_measure :: proc(v: fx.Proverb_Values, signal: string, seconds: f64, quality := fx.Proverb_Quality.Normal) -> (m: Pv_Measured, out: kit.Audio_Buffer) {
	SRR :: 48_000.0
	frames := int(seconds * SRR)
	x := make([]f32, frames, context.temp_allocator)
	if signal == "sine:1000" {
		for i in 0 ..< min(frames, 48_000) do x[i] = f32(0.5 * math.sin(2 * math.PI * 1000 * f64(i) / SRR))
	} else {
		x[0] = 1
	}
	node, _, _ := fx.proverb_create({quality = quality})
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
	for p in fx.proverb_params do if p.id != fx.PV_PARAM_QUALITY do append(&ev, kit.Timed_Event{0, core.Param_Value{p.id, f64(v[p.id])}})
	cfg.events = ev[:]
	r: kit.Render_Report
	input := kit.buffer_make(2, frames, SRR, context.temp_allocator)
	copy(input.channels[0], x)
	copy(input.channels[1], x)
	out, r = kit.render(&node, input, cfg, context.temp_allocator)
	kit.render_report_destroy(&r)
	l, rr := out.channels[0], out.channels[1]
	mono := make([]f32, len(l), context.temp_allocator)
	for s, i in l do mono[i] = 0.5 * (s + rr[i])
	if signal == "sine:1000" {
		a, z := int(1.05 * SRR), min(int(1.05 * SRR) + 32_768, len(mono))
		m.spread_hz = kit.spectral_spread(mono[a:z], SRR, 1000)
		m.correlation = kit.correlation(l[a:z], rr[a:z])
		return
	}
	bands := PV_BANDS
	for hz, k in bands {
		m.rt60[k] = kit.band_decay_time(mono, SRR, hz)
		band := kit.octave_band(mono[:min(len(mono), 48_000)], SRR, hz, context.temp_allocator)
		e := 0.0
		for s in band do e += f64(s) * f64(s)
		m.band_db[k] = 10 * math.log10(max(e, 1e-30))
	}
	m.rt60_wide = kit.decay_time(mono, SRR)
	d := kit.echo_density(l[:min(len(l), int(0.3 * SRR) + 960)], SRR, allocator = context.temp_allocator)
	m.density_90 = -1
	for s, k in d do if m.density_90 < 0 && s >= 0.9 do m.density_90 = f64(k) * 5
	a, z := int(0.05 * SRR), min(int(SRR), len(l))
	m.correlation = kit.correlation(l[a:z], rr[a:z])
	s2 := 0.0
	for s in mono[:min(len(mono), 48_000)] do s2 += f64(s) * f64(s)
	m.level_db = 10 * math.log10(max(s2 / SRR, 1e-30))
	peak: f32 = 0
	for s in mono do peak = max(peak, abs(s))
	for s, i in mono do if abs(s) >= peak * 0.01 {
		m.first_ms = f64(i) * 1000 / SRR
		break
	}
	return
}
