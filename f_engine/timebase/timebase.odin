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

// Absolute position in frames since transport zero. The engine's source of truth for time.
Sample_Time :: distinct i64 // frames since transport zero
// A time in seconds.
Seconds     :: distinct f64
// Musical time in quarter notes, whatever the time signature.
Beats       :: distinct f64 // quarter notes
// Musical time in whole ticks; `ppq` ticks make one quarter note.
Ticks       :: distinct i64

// Default tick resolution, in pulses (ticks) per quarter note.
DEFAULT_PPQ :: 960

// --- samples <-> seconds -----------------------------------------------------

// [rt] Converts frames to seconds at `sample_rate` (Hz).
samples_to_seconds :: #force_inline proc "contextless" (s: Sample_Time, sample_rate: f64) -> Seconds {
	return Seconds(f64(s) / sample_rate)
}

// [rt] Converts seconds to frames at `sample_rate` (Hz), rounding to the nearest frame.
seconds_to_samples :: #force_inline proc "contextless" (t: Seconds, sample_rate: f64) -> Sample_Time {
	return Sample_Time(math.round(f64(t) * sample_rate))
}

// --- beats <-> ticks ---------------------------------------------------------

// [rt] Converts beats to ticks at `ppq` ticks per quarter note, rounding to the nearest tick.
beats_to_ticks :: #force_inline proc "contextless" (b: Beats, ppq: i64 = DEFAULT_PPQ) -> Ticks {
	return Ticks(math.round(f64(b) * f64(ppq)))
}

// [rt] Converts ticks to beats at `ppq` ticks per quarter note.
ticks_to_beats :: #force_inline proc "contextless" (t: Ticks, ppq: i64 = DEFAULT_PPQ) -> Beats {
	return Beats(f64(t) / f64(ppq))
}

// --- constant-tempo helpers (no map needed) ----------------------------------

// [rt] Duration of `b` beats at a constant tempo of `bpm`.
beats_to_seconds_at :: #force_inline proc "contextless" (b: Beats, bpm: f64) -> Seconds {
	return Seconds(f64(b) * 60.0 / bpm)
}

// [rt] Beats elapsed in `t` seconds at a constant tempo of `bpm`.
seconds_to_beats_at :: #force_inline proc "contextless" (t: Seconds, bpm: f64) -> Beats {
	return Beats(f64(t) * bpm / 60.0)
}

// [rt] Frames per quarter note at a constant tempo of `bpm` and `sample_rate` (Hz). Not rounded.
samples_per_beat :: #force_inline proc "contextless" (bpm, sample_rate: f64) -> f64 {
	return sample_rate * 60.0 / bpm
}

// --- ramps -------------------------------------------------------------------

// [rt] Beats travelled in `t` seconds from a tempo of `bpm` that changes by
// `slope` bpm per beat (a linear ramp in beats, as in `Tempo_Map`). `slope` 0
// is a constant tempo.
ramp_beats :: proc "contextless" (bpm, slope: f64, t: Seconds) -> Beats {
	if abs(slope) < 1e-12 do return Beats(f64(t) * bpm / 60.0)
	// tempo(b) = bpm + slope·b and dt/db = 60/tempo  ⇒  b(t) = bpm·(e^(slope·t/60) − 1)/slope
	return Beats(bpm * (math.exp(slope * f64(t) / 60.0) - 1) / slope)
}

// [rt] Seconds taken to travel `b` beats from a tempo of `bpm` changing by
// `slope` bpm per beat. Inverse of `ramp_beats`.
ramp_seconds :: proc "contextless" (bpm, slope: f64, b: Beats) -> Seconds {
	if abs(slope) < 1e-12 do return Seconds(f64(b) * 60.0 / bpm)
	return Seconds(60.0 / slope * math.ln(1.0 + slope * f64(b) / bpm))
}

// --- quantization ------------------------------------------------------------

// A musical grid length for quantizing launches and edits. `_T` is a triplet
// (2/3 of the length), `_D` dotted (3/2). Bar lengths follow the meter.
Quantize :: enum u8 {
	None,
	Bars_8,
	Bars_4,
	Bars_2,
	Bar,
	Half_T,
	Half,
	Half_D,
	Quarter_T,
	Quarter,
	Quarter_D,
	Eighth_T,
	Eighth,
	Eighth_D,
	Sixteenth_T,
	Sixteenth,
	Sixteenth_D,
	Thirty_Second_T,
	Thirty_Second,
	Thirty_Second_D,
}

// [rt] The length of `q` as whole bars (`bars` > 0; `beats` is 0), or as
// quarter notes (`bars` is 0). `.None` gives both 0.
quantize_length :: proc "contextless" (q: Quantize) -> (bars: int, beats: Beats) {
	switch q {
	case .None:            return 0, 0
	case .Bars_8:          return 8, 0
	case .Bars_4:          return 4, 0
	case .Bars_2:          return 2, 0
	case .Bar:             return 1, 0
	case .Half_T:          return 0, 4.0 / 3
	case .Half:            return 0, 2
	case .Half_D:          return 0, 3
	case .Quarter_T:       return 0, 2.0 / 3
	case .Quarter:         return 0, 1
	case .Quarter_D:       return 0, 1.5
	case .Eighth_T:        return 0, 1.0 / 3
	case .Eighth:          return 0, 0.5
	case .Eighth_D:        return 0, 0.75
	case .Sixteenth_T:     return 0, 1.0 / 6
	case .Sixteenth:       return 0, 0.25
	case .Sixteenth_D:     return 0, 0.375
	case .Thirty_Second_T: return 0, 1.0 / 12
	case .Thirty_Second:   return 0, 0.125
	case .Thirty_Second_D: return 0, 0.1875
	}
	return 0, 0
}
