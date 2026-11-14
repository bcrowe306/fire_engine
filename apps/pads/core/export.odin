package pads_core

import pm "../model"

// An export under way (a mixdown, stems, a resample, a bounce, a freeze):
// it renders a slice a frame (`export_frame`).
Job :: struct {
	export:   pm.Export,
	busy:     bool,
	progress: f64, // 0..1
}

// What the export that finished did: its export (files, the pad it made),
// whether it failed. Valid until the next starts.
job_result :: proc(c: ^Core) -> ^pm.Export {
	return &c.job.export
}

@(private)
job_begin :: proc(c: ^Core) -> bool {
	if c.job.busy do return false
	pm.export_destroy(&c.job.export)
	return true
}

@(private)
job_started :: proc(c: ^Core, ok: bool, why: string) -> Outcome {
	if !ok do return outcome(c, .Invalid, why)
	c.job.busy, c.job.progress = true, 0
	return .Ok
}

// Exports as `settings` say into `path` (a file, or with stems a folder).
export_start :: proc(c: ^Core, settings: pm.Export_Settings, path: string) -> Outcome {
	if !job_begin(c) do return outcome(c, .Busy, "an export is under way")
	return job_started(c, pm.export_begin(&c.m, &c.job.export, settings, path), "nothing to export")
}

// Resamples the current sequence onto the next empty pad.
export_resample :: proc(c: ^Core) -> Outcome {
	if !job_begin(c) do return outcome(c, .Busy, "an export is under way")
	return job_started(c, pm.export_to_pad(&c.m, &c.job.export), "no empty pad to resample onto")
}

// Bounces pads `pads` (what they play in the current sequence, after their
// faders) onto the next empty pad.
export_bounce_pads :: proc(c: ^Core, pads: bit_set[0 ..< pm.PADS; u128]) -> Outcome {
	if !job_begin(c) do return outcome(c, .Busy, "an export is under way")
	return job_started(c, pm.bounce_pads(&c.m, &c.job.export, pads), "nothing to bounce, or no empty pad")
}

// Bounces bus `b` (0-based) onto the next empty pad.
export_bounce_bus :: proc(c: ^Core, b: int) -> Outcome {
	if !job_begin(c) do return outcome(c, .Busy, "an export is under way")
	return job_started(c, pm.bounce_bus(&c.m, &c.job.export, b), "nothing on that bus to bounce, or no empty pad")
}

// Bounces pad `i` in place: an audio track of its sound, the pad muted.
export_bounce_in_place :: proc(c: ^Core, i: int) -> Outcome {
	if !job_begin(c) do return outcome(c, .Busy, "an export is under way")
	return job_started(c, pm.bounce_in_place_begin(&c.m, &c.job.export, i), "it can't be bounced in place (no notes, an audio track, or no empty pad)")
}

// Freezes pad `i`: its sound rendered in each sequence, played instead.
export_freeze :: proc(c: ^Core, i: int) -> Outcome {
	if !job_begin(c) do return outcome(c, .Busy, "an export is under way")
	return job_started(c, pm.freeze_begin(&c.m, &c.job.export, i), "nothing to freeze (no notes, or an audio pad)")
}

// Renders the export under way's next slice (once a frame): true when it
// finished this frame (`job_result` says how).
export_frame :: proc(c: ^Core) -> (finished: bool) {
	j := &c.job
	if !j.busy do return false
	j.progress = pm.export_step(&c.m, &j.export, 96_000)
	if j.export.finished || j.export.failed {
		pm.export_finish(&c.m, &j.export)
		j.busy = false
		return true
	}
	return false
}

// Exports as `settings` say into `path` at once (blocking: scripts and
// the remote): the files written. Busy while one is under way.
export_now :: proc(c: ^Core, settings: pm.Export_Settings, path: string) -> (files: int, o: Outcome) {
	if !job_begin(c) do return 0, outcome(c, .Busy, "an export is under way")
	n := len(pm.export_all(&c.m, settings, path, &c.job.export))
	if n == 0 do return 0, outcome(c, .Invalid, "nothing exported")
	return n, .Ok
}
