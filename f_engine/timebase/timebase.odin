// Time representations and conversions.
//
// The engine's source of truth is `Sample_Time` (i64 frames since transport zero).
// Every other representation is derived from it:
//
//   Sample_Time <-> Seconds          via sample rate
//   Seconds     <-> Beats            via Tempo_Map (supports linear tempo ramps)
//   Beats       <-> Ticks            via PPQ
//   Beats       <-> Bar_Beat_Tick    via Tempo_Map meter changes
//
// "Beat" always means a quarter note, whatever the time signature. Musical
// beats in the meter's denominator are computed in BBT.
package timebase

import "core:math"

Sample_Time :: distinct i64 // frames since transport zero
Seconds     :: distinct f64
Beats       :: distinct f64 // quarter notes
Ticks       :: distinct i64

DEFAULT_PPQ :: 960

// --- samples <-> seconds -----------------------------------------------------

samples_to_seconds :: #force_inline proc "contextless" (s: Sample_Time, sample_rate: f64) -> Seconds {
	return Seconds(f64(s) / sample_rate)
}

// Rounds to the nearest frame.
seconds_to_samples :: #force_inline proc "contextless" (t: Seconds, sample_rate: f64) -> Sample_Time {
	return Sample_Time(math.round(f64(t) * sample_rate))
}

// --- beats <-> ticks ---------------------------------------------------------

beats_to_ticks :: #force_inline proc "contextless" (b: Beats, ppq: i64 = DEFAULT_PPQ) -> Ticks {
	return Ticks(math.round(f64(b) * f64(ppq)))
}

ticks_to_beats :: #force_inline proc "contextless" (t: Ticks, ppq: i64 = DEFAULT_PPQ) -> Beats {
	return Beats(f64(t) / f64(ppq))
}

// --- constant-tempo helpers (no map needed) ----------------------------------

beats_to_seconds_at :: #force_inline proc "contextless" (b: Beats, bpm: f64) -> Seconds {
	return Seconds(f64(b) * 60.0 / bpm)
}

seconds_to_beats_at :: #force_inline proc "contextless" (t: Seconds, bpm: f64) -> Beats {
	return Beats(f64(t) * bpm / 60.0)
}

samples_per_beat :: #force_inline proc "contextless" (bpm, sample_rate: f64) -> f64 {
	return sample_rate * 60.0 / bpm
}
