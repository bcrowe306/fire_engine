package timebase

import "core:math"
import "core:mem"

// A tempo segment starts at `start` beats with `bpm_start` and ramps linearly
// (in beats) to the next segment's start, reaching `bpm_end`. If bpm_end == bpm_start
// the tempo is constant. The last segment extends forever at bpm_start, and any
// ramp on it is ignored.
Tempo_Point :: struct {
	start:     Beats,
	bpm_start: f64,
	bpm_end:   f64, // tempo reached at the *next* point's start
}

Meter :: struct {
	numerator:   i32,
	denominator: i32, // 2, 4, 8, 16 ...
}

// Meter changes happen on bar boundaries.
Meter_Point :: struct {
	bar:   i64, // 0-based bar index where this meter begins
	meter: Meter,
}

Bar_Beat_Tick :: struct {
	bar:  i64, // 0-based
	beat: i64, // 0-based, in units of the meter denominator
	tick: i64, // 0 ..< ticks per denominator beat
}

// Built and edited on the control thread. The audio thread may read a map that
// is no longer being mutated (publish a new one with an atomic swap).
Tempo_Map :: struct {
	tempos: [dynamic]Tempo_Point,
	meters: [dynamic]Meter_Point,
	// Derived: seconds at each tempo point. Rebuilt by `tempo_map_rebuild`.
	seconds_at: [dynamic]Seconds,
	// Derived: start beat of each meter point.
	meter_beats: [dynamic]Beats,
}

tempo_map_init :: proc(m: ^Tempo_Map, bpm: f64 = 120, meter := Meter{4, 4}, allocator := context.allocator) -> mem.Allocator_Error {
	m.tempos      = make([dynamic]Tempo_Point, allocator) or_return
	m.meters      = make([dynamic]Meter_Point, allocator) or_return
	m.seconds_at  = make([dynamic]Seconds, allocator) or_return
	m.meter_beats = make([dynamic]Beats, allocator) or_return
	append(&m.tempos, Tempo_Point{0, bpm, bpm}) or_return
	append(&m.meters, Meter_Point{0, meter}) or_return
	tempo_map_rebuild(m)
	return nil
}

tempo_map_destroy :: proc(m: ^Tempo_Map) {
	delete(m.tempos)
	delete(m.meters)
	delete(m.seconds_at)
	delete(m.meter_beats)
	m^ = {}
}

// Inserts or replaces a tempo point. `ramp_to` < 0 means constant until the next point.
tempo_map_set_tempo :: proc(m: ^Tempo_Map, at: Beats, bpm: f64, ramp_to: f64 = -1) -> mem.Allocator_Error {
	assert(bpm > 0)
	p := Tempo_Point{at, bpm, ramp_to > 0 ? ramp_to : bpm}
	i := 0
	for i < len(m.tempos) && m.tempos[i].start < at do i += 1
	if i < len(m.tempos) && m.tempos[i].start == at {
		m.tempos[i] = p
	} else {
		inject_at(&m.tempos, i, p) or_return
	}
	tempo_map_rebuild(m)
	return nil
}

tempo_map_set_meter :: proc(m: ^Tempo_Map, bar: i64, meter: Meter) -> mem.Allocator_Error {
	assert(meter.numerator > 0 && meter.denominator > 0)
	p := Meter_Point{bar, meter}
	i := 0
	for i < len(m.meters) && m.meters[i].bar < bar do i += 1
	if i < len(m.meters) && m.meters[i].bar == bar {
		m.meters[i] = p
	} else {
		inject_at(&m.meters, i, p) or_return
	}
	tempo_map_rebuild(m)
	return nil
}

tempo_map_rebuild :: proc(m: ^Tempo_Map) {
	resize(&m.seconds_at, len(m.tempos))
	t := Seconds(0)
	for i in 0 ..< len(m.tempos) {
		m.seconds_at[i] = t
		if i + 1 < len(m.tempos) {
			t += segment_seconds(m.tempos[i], m.tempos[i + 1].start - m.tempos[i].start, m.tempos[i + 1].start - m.tempos[i].start)
		}
	}
	resize(&m.meter_beats, len(m.meters))
	b := Beats(0)
	for i in 0 ..< len(m.meters) {
		m.meter_beats[i] = b
		if i + 1 < len(m.meters) {
			bars := m.meters[i + 1].bar - m.meters[i].bar
			b += Beats(f64(bars) * beats_per_bar(m.meters[i].meter))
		}
	}
}

beats_per_bar :: #force_inline proc "contextless" (meter: Meter) -> f64 {
	return f64(meter.numerator) * 4.0 / f64(meter.denominator)
}

// --- tempo-map conversions ([rt]-safe: read-only, no allocation) -------------

// [rt]
tempo_at :: proc "contextless" (m: ^Tempo_Map, b: Beats) -> f64 {
	i := tempo_index(m, b)
	p := m.tempos[i]
	if i + 1 >= len(m.tempos) do return p.bpm_start
	return p.bpm_start + ramp_slope(p, m.tempos[i + 1].start - p.start) * f64(b - p.start)
}

// [rt]
beats_to_seconds :: proc "contextless" (m: ^Tempo_Map, b: Beats) -> Seconds {
	i := tempo_index(m, b)
	p := m.tempos[i]
	length := i + 1 < len(m.tempos) ? m.tempos[i + 1].start - p.start : 0
	return m.seconds_at[i] + segment_seconds(p, b - p.start, length)
}

// [rt]
seconds_to_beats :: proc "contextless" (m: ^Tempo_Map, t: Seconds) -> Beats {
	i := len(m.tempos) - 1
	for i > 0 && m.seconds_at[i] > t do i -= 1
	p := m.tempos[i]
	dt := f64(t - m.seconds_at[i])
	if i + 1 >= len(m.tempos) {
		return p.start + Beats(dt * p.bpm_start / 60.0)
	}
	k := ramp_slope(p, m.tempos[i + 1].start - p.start)
	if abs(k) < 1e-12 {
		return p.start + Beats(dt * p.bpm_start / 60.0)
	}
	// Inverse of t = 60/k * ln(tempo(b)/t0): b = (t0 * e^(k t / 60) - t0) / k
	return p.start + Beats((p.bpm_start * math.exp(k * dt / 60.0) - p.bpm_start) / k)
}

// [rt]
samples_to_beats :: proc "contextless" (m: ^Tempo_Map, s: Sample_Time, sample_rate: f64) -> Beats {
	return seconds_to_beats(m, samples_to_seconds(s, sample_rate))
}

// [rt]
beats_to_samples :: proc "contextless" (m: ^Tempo_Map, b: Beats, sample_rate: f64) -> Sample_Time {
	return seconds_to_samples(beats_to_seconds(m, b), sample_rate)
}

// [rt]
meter_at_beat :: proc "contextless" (m: ^Tempo_Map, b: Beats) -> (meter: Meter, bar_start: i64, beat_start: Beats) {
	i := len(m.meters) - 1
	for i > 0 && m.meter_beats[i] > b do i -= 1
	return m.meters[i].meter, m.meters[i].bar, m.meter_beats[i]
}

// [rt]
beats_to_bbt :: proc "contextless" (m: ^Tempo_Map, b: Beats, ppq: i64 = DEFAULT_PPQ) -> Bar_Beat_Tick {
	meter, bar0, beat0 := meter_at_beat(m, b)
	quarters_per_unit := 4.0 / f64(meter.denominator)
	ticks_per_unit := i64(math.round(f64(ppq) * quarters_per_unit))
	units_per_bar := i64(meter.numerator)
	total_ticks := i64(math.round(f64(b - beat0) / quarters_per_unit * f64(ticks_per_unit)))
	ticks_per_bar := units_per_bar * ticks_per_unit
	bar := total_ticks / ticks_per_bar
	rem := total_ticks % ticks_per_bar
	return {bar0 + bar, rem / ticks_per_unit, rem % ticks_per_unit}
}

// [rt]
bbt_to_beats :: proc "contextless" (m: ^Tempo_Map, bbt: Bar_Beat_Tick, ppq: i64 = DEFAULT_PPQ) -> Beats {
	i := len(m.meters) - 1
	for i > 0 && m.meters[i].bar > bbt.bar do i -= 1
	meter := m.meters[i].meter
	quarters_per_unit := 4.0 / f64(meter.denominator)
	ticks_per_unit := f64(ppq) * quarters_per_unit
	b := f64(m.meter_beats[i])
	b += f64(bbt.bar - m.meters[i].bar) * beats_per_bar(meter)
	b += f64(bbt.beat) * quarters_per_unit
	b += f64(bbt.tick) / ticks_per_unit * quarters_per_unit
	return Beats(b)
}

// --- internals ---------------------------------------------------------------

@(private)
tempo_index :: proc "contextless" (m: ^Tempo_Map, b: Beats) -> int {
	i := len(m.tempos) - 1
	for i > 0 && m.tempos[i].start > b do i -= 1
	return i
}

// bpm per beat across a segment of `length` beats. Zero for the open-ended last segment.
@(private)
ramp_slope :: #force_inline proc "contextless" (p: Tempo_Point, length: Beats) -> f64 {
	if length <= 0 do return 0
	return (p.bpm_end - p.bpm_start) / f64(length)
}

// Seconds elapsed `db` beats into segment `p` (whose total length is `length` beats).
// dt/db = 60/tempo(b), tempo(b) = t0 + k*b  =>  t = 60/k * ln(1 + k*b/t0)
@(private)
segment_seconds :: proc "contextless" (p: Tempo_Point, db: Beats, length: Beats) -> Seconds {
	k := ramp_slope(p, length)
	if abs(k) < 1e-12 {
		return Seconds(f64(db) * 60.0 / p.bpm_start)
	}
	return Seconds(60.0 / k * math.ln(1.0 + k * f64(db) / p.bpm_start))
}
