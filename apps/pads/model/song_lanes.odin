package pads_model

// A lane plays one clip at a time: an edit that puts a clip over another
// on its lane makes the other make way (`song_make_way`), and a
// controller's edits ripple (`song_ripple_insert`, `song_ripple_remove`,
// `song_ripple_edit`): the lane's later clips move with them, as a video
// editor's ripple edits do.

@(private = "file")
EPS :: 1e-9

// Clip index `i` of a song before an edit, where it went (`to[i]`; -1:
// taken out).
Clip_Map :: [SONG_CLIPS]int

// The clips the clips in `keep` lie over (on their lanes) make way: one
// they cover taken out, one they overlap trimmed (its start moved on, its
// notes staying where they were, or its end brought in), one covering
// one of them cut in two (its tail after). Returns where each clip went.
song_make_way :: proc(s: ^Song, keep: Clip_Set) -> (to: Clip_Map) {
	for &x in to do x = -1
	gone: Clip_Set
	n := s.count
	for k in 0 ..< s.count do if k in keep {
		kc := s.clips[k]
		ka, kb := kc.at, clip_end(kc)
		for i := 0; i < n; i += 1 {
			if i in keep || i in gone do continue
			x := &s.clips[i]
			if x.lane != kc.lane do continue
			xa, xb := x.at, clip_end(x^)
			if xb <= ka + EPS || xa >= kb - EPS do continue
			switch {
			case xa >= ka - EPS && xb <= kb + EPS:
				gone += {i}
			case xa < ka - EPS && xb > kb + EPS:
				if n < SONG_CLIPS {
					tail := x^
					tail.at, tail.length, tail.phase = kb, xb - kb, x.phase + (kb - xa)
					s.clips[n] = tail
					n += 1
				}
				x.length = ka - xa
			case xa < ka - EPS:
				x.length = ka - xa
			case:
				x.phase += kb - xa
				x.at, x.length = kb, xb - kb
			}
		}
	}
	j := 0
	for i in 0 ..< n {
		if i in gone do continue
		s.clips[j] = s.clips[i]
		to[i] = j
		j += 1
	}
	for i in j ..< n do s.clips[i] = {}
	s.count = j
	return
}

// The clips in `keep` (as `to` maps them) after `song_make_way`.
clips_mapped :: proc(keep: Clip_Set, to: Clip_Map) -> (out: Clip_Set) {
	for i in 0 ..< SONG_CLIPS do if i in keep && to[i] >= 0 do out += {to[i]}
	return
}

// The song's clips around those in `keep` make way (`song_make_way`), as
// part of the drag that put them there (`name`: its step; seal after).
// Returns where each clip went.
song_settle :: proc(m: ^Model, keep: Clip_Set, name: string) -> Clip_Map {
	s := m.project.song
	to := song_make_way(&s, keep)
	set_song_drag(m, name, s)
	return to
}

// Where a clip put at song beat `at` on lane `lane` goes when it may not
// split one: `at`, or the end of the clip it falls inside.
lane_insert_point :: proc(s: ^Song, lane: int, at: f64) -> f64 {
	b := at
	for _ in 0 ..< s.count {
		moved := false
		for o in s.clips[:s.count] {
			if int(o.lane) == lane && o.at < b - EPS && clip_end(o) > b + EPS {
				b = clip_end(o)
				moved = true
			}
		}
		if !moved do break
	}
	return b
}

// Puts clip `c` on its lane (at `lane_insert_point`), the lane's clips
// from there on moving later by its length: one undo step. Its index, or
// -1 when the song is full.
song_ripple_insert :: proc(m: ^Model, c: Song_Clip, name := "Insert Clip") -> int {
	s := m.project.song
	if s.count >= SONG_CLIPS || int(c.slot) >= SLOTS do return -1
	x := clip_fit(c)
	x.at = lane_insert_point(&s, int(x.lane), x.at)
	for &o in s.clips[:s.count] do if o.lane == x.lane && o.at >= x.at - EPS do o.at += x.length
	s.clips[s.count] = x
	s.count += 1
	s.lane_count = max(s.lane_count, int(x.lane) + 1)
	set_song(m, name, s)
	return s.count - 1
}

// Removes the clips in `sel`, their lanes' later clips moving earlier by
// what was taken out before them (the gaps closed): one undo step.
song_ripple_remove :: proc(m: ^Model, sel: Clip_Set, name := "Remove from Song") {
	s := m.project.song
	old := s
	for i in 0 ..< s.count do if i not_in sel {
		o := &s.clips[i]
		shift := 0.0
		for k in 0 ..< old.count do if k in sel && old.clips[k].lane == o.lane && clip_end(old.clips[k]) <= o.at + EPS do shift += old.clips[k].length
		o.at = max(o.at - shift, 0)
	}
	n := 0
	for i in 0 ..< s.count do if i not_in sel {
		s.clips[n] = s.clips[i]
		n += 1
	}
	for i in n ..< s.count do s.clips[i] = {}
	s.count = n
	set_song(m, name, s)
}

// Song beat `beat` after `song_ripple_remove` took out `sel` on lane
// `lane` (moved back by what went before it there; one inside a clip taken
// out: that clip's start).
ripple_beat :: proc(s: ^Song, sel: Clip_Set, lane: int, beat: f64) -> f64 {
	b := beat
	for c, k in s.clips[:s.count] do if k in sel && int(c.lane) == lane && c.at < beat - EPS {
		b -= min(beat - c.at, c.length)
	}
	return max(b, 0)
}

// Clip `i` placed at song beat `at` for `length` beats, its lane's later
// clips moving with its end (not before the clip ahead of it ends): part
// of a drag (`name`; seal when it ends).
song_ripple_edit :: proc(m: ^Model, i: int, at, length: f64, name: string) {
	s := m.project.song
	if i < 0 || i >= s.count do return
	c := s.clips[i]
	lo := 0.0
	for o, k in s.clips[:s.count] do if k != i && o.lane == c.lane && clip_end(o) <= c.at + EPS do lo = max(lo, clip_end(o))
	na, nl := max(at, lo), max(length, 1.0 / 16)
	d := na + nl - clip_end(c)
	for &o, k in s.clips[:s.count] do if k != i && o.lane == c.lane && o.at >= clip_end(c) - EPS do o.at += d
	s.clips[i].at, s.clips[i].length = na, nl
	set_song_drag(m, name, s)
}

// The clips on lane `lane` in order of where they start.
lane_clips :: proc(s: ^Song, lane: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, s.count, allocator)
	for c, i in s.clips[:s.count] do if int(c.lane) == lane {
		j := len(out)
		append(&out, i)
		for j > 0 && s.clips[out[j - 1]].at > c.at {
			out[j] = out[j - 1]
			j -= 1
		}
		out[j] = i
	}
	return out[:]
}
