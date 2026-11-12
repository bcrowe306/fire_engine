package pads_model

import "core:math"
import "core:slice"

import "fire:clip"
import tb "fire:timebase"

// MIDI files out: a sequence, or the whole song (its steps one after
// another, each its repeats, its part of the sequence, its transpose; muted
// steps silent), as a type 1 file: a track a pad, named after it, each
// note on the pad's General MIDI drum key (A1 the kick on 36, A2 on 37...:
// what `Midi_Import.Drums` reads back, and drum software expects), pitched
// notes that many keys off it; the tempo (the song's: each step's own).

// Exports sequence `slot` (or, -1, the song) to the MIDI file at `path`.
// Returns how many notes it wrote, or -1 if it couldn't write the file.
export_midi :: proc(m: ^Model, path: string, slot: int) -> int {
	p := &m.project
	per_pad: [PADS][dynamic]clip.Note
	for &l in per_pad do l = make([dynamic]clip.Note, context.temp_allocator)
	tm: tb.Tempo_Map
	tb.tempo_map_init(&tm, sequence_tempo(p, max(slot, 0)) if slot >= 0 else song_tempo_at(p, 0), {i32(p.transport.time_sig.num), i32(p.transport.time_sig.den)}, context.temp_allocator)
	put :: proc(m: ^Model, per_pad: ^[PADS][dynamic]clip.Note, n: Seq_Note, at: f64, transpose: int) {
		k := GM_KICK + int(n.pad) + int(n.pitch) + transpose
		if k < 0 || k > 127 do return // (past the keys: pads after the 92nd, unpitched)
		append(&per_pad[n.pad], clip.Note{start = tb.Beats(at), length = tb.Beats(max(n.length, 1.0 / 64)), key = u8(k), velocity = n.velocity, probability = 1})
	}
	total: f64 = 0
	if slot >= 0 {
		s := &p.sequences[slot]
		for n in s.notes do if !n.muted do put(m, &per_pad, n, n.start, 0)
		total = seq_beats(p, s^)
	} else {
		pts := song_tempo_points(p)
		for pt, i in pts do if i > 0 do tb.tempo_map_set_tempo(&tm, tb.Beats(pt.beat), pt.bpm, pts[i + 1].bpm if pt.ramp && i + 1 < len(pts) else -1)
		if len(pts) > 0 && pts[0].ramp && len(pts) > 1 do tb.tempo_map_set_tempo(&tm, 0, pts[0].bpm, pts[1].bpm)
		for c, i in p.song.clips[:p.song.count] {
			if !clip_heard(&p.song, i) do continue
			period := clip_period(p, c)
			if period <= 0 do continue
			for off := -math.mod(c.phase, period); off < c.length - 1e-9; off += period {
				for n in p.sequences[c.slot].notes {
					x := off + n.start - c.start
					if n.muted || n.start < c.start || n.start >= c.start + period || x < -1e-9 || x >= c.length - 1e-9 do continue
					put(m, &per_pad, n, c.at + off + n.start - c.start, int(c.transpose))
				}
			}
		}
		total = song_beats(p)
	}
	tracks := make([dynamic]clip.Midi_File_Track, context.temp_allocator)
	count := 0
	for &l, pad in per_pad {
		if len(l) == 0 do continue
		slice.sort_by(l[:], proc(a, b: clip.Note) -> bool { return a.start < b.start || (a.start == b.start && a.key < b.key) })
		c := new(clip.Midi_Clip, context.temp_allocator)
		c.length = tb.Beats(total)
		c.loop_end = c.length
		c.notes = l[:]
		name := pad_name(&p.pads[pad])
		append(&tracks, clip.Midi_File_Track{name = name if name != "" else pad_label(pad), clip = c})
		count += len(l)
	}
	if clip.midi_file_write(path, tracks[:], &tm) != .None do return -1
	return count
}
