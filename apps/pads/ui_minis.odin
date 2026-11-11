package pads

import "core:slice"

import "app:ui"
import pm "model"

// A sequence's notes, small (for its pad in Perform and its song steps):
// across, where each starts and ends in the sequence; up, its row (the
// pads, and pitches, it plays, lowest at the bottom). Temporary allocator.
seq_minis :: proc(a: ^App, slot: int) -> []ui.Mini_Note {
	p := &a.m.project
	s := &p.sequences[slot]
	if len(s.notes) == 0 do return nil
	length := max(pm.seq_beats(p, s^), 1e-6)
	// Its rows: each pad and pitch it plays, in order.
	keys := make([dynamic]int, context.temp_allocator)
	key :: proc(n: pm.Seq_Note) -> int { return int(n.pad) * 256 + int(n.pitch) + 128 }
	for n in s.notes {
		k := key(n)
		if !slice.contains(keys[:], k) do append(&keys, k)
	}
	slice.sort(keys[:])
	rows := max(len(keys) - 1, 1)
	out := make([]ui.Mini_Note, len(s.notes), context.temp_allocator)
	for n, i in s.notes {
		r, _ := slice.linear_search(keys[:], key(n))
		y: f32 = 0.5 if len(keys) == 1 else f32(r) / f32(rows)
		out[i] = {f32(n.start / length), f32((n.start + n.length) / length), y}
	}
	return out
}
