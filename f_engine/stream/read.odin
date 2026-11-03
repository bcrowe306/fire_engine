package stream

import "base:intrinsics"

import "fire:rt"

// [rt] Reads `frames` frames from the stream's position into `out` (one
// slice per channel of the source, each at least `frames` long; extra
// slices are left alone, missing ones skipped) and advances. Frames past the
// end of the file are silence. Frames the disk has not delivered yet are
// silence too, and are counted as underruns; time keeps moving. Returns how
// many frames came from the file (the rest of `frames` is silence). One
// audio thread only; never allocates or blocks.
stream_read :: proc "contextless" (st: ^Stream, out: [][]f32, frames: int) -> (from_file: int) {
	src := st.source
	channels := min(len(out), src.info.channels)
	done := 0
	for done < frames {
		left := frames - done
		if st.position >= src.info.frames {
			silence(out[:channels], done, left)
			break
		}
		left = int(min(i64(left), src.info.frames - st.position))
		n := 0
		if src.ram != nil {
			if intrinsics.atomic_load(&src.state) == .Ready {
				n = left
				for c in 0 ..< channels do copy(out[c][done:done + n], src.ram[c][st.position:st.position + i64(n)])
			}
		} else {
			n = read_streamed(st, out[:channels], done, left)
		}
		if n == 0 { // nothing available: silence for the rest of this call
			silence(out[:channels], done, left)
			intrinsics.atomic_add(&st.underruns, u64(left))
			intrinsics.atomic_add(&st.streamer.underruns, u64(left))
			st.position += i64(left)
			done += left
			continue
		}
		from_file += n
		st.position += i64(n)
		done += n
	}
	return
}

// [rt] Jumps to `frame`. If a cue covers it (from the cue up to
// `Settings.cue_seconds` after) and is decoded, playback continues from
// memory at once while the disk catches up; otherwise there is silence until
// the disk delivers (see `stream_ready`). One audio thread only.
stream_seek :: proc "contextless" (st: ^Stream, frame: i64) {
	st.position = max(frame, 0)
	if st.source.ram != nil do return
	st.gen = (st.gen + 1) & 0xFFFFFF
	if st.gen == 0 do st.gen = 1
	// Hand back everything buffered for the old position at once, so the
	// disk has blocks to fill for the new one.
	if st.current >= 0 {
		rt.spsc_push(&st.free, st.current)
		st.current = -1
	}
	for index in rt.spsc_pop(&st.filled) do rt.spsc_push(&st.free, index)
	st.cue = -1
	next := st.position
	for i in 0 ..< st.cue_count {
		c := &st.cues[i]
		if st.position >= c.frame && st.position < c.frame + i64(c.frames) && intrinsics.atomic_load(&c.ready) {
			st.cue = i
			next = c.frame + i64(c.frames) // the disk continues after the cue
			break
		}
	}
	intrinsics.atomic_store(&st.request, pack(st.gen, next))
}

// [rt] The frame the next `stream_read` starts at.
stream_position :: proc "contextless" (st: ^Stream) -> i64 {
	return st.position
}

// Copies what is available at the position from the cue in use or the
// buffered blocks; 0 if nothing is.
@(private)
read_streamed :: proc "contextless" (st: ^Stream, out: [][]f32, at, frames: int) -> int {
	if st.cue >= 0 {
		c := &st.cues[st.cue]
		end := c.frame + i64(c.frames)
		if st.position >= c.frame && st.position < end {
			n := int(min(i64(frames), end - st.position))
			off := int(st.position - c.frame)
			for ch in 0 ..< len(out) do copy(out[ch][at:at + n], c.data[ch][off:off + n])
			return n
		}
		st.cue = -1
	}
	for {
		if st.current < 0 {
			index, ok := rt.spsc_pop(&st.filled)
			if !ok do return 0
			st.current = index
		}
		b := &st.blocks[st.current]
		if b.gen != st.gen || st.position >= b.start + i64(b.frames) {
			// From before a seek, or already passed (after an underrun).
			rt.spsc_push(&st.free, st.current)
			st.current = -1
			continue
		}
		if st.position < b.start do return 0 // not reached yet (can't happen within one generation)
		off := int(st.position - b.start)
		n := min(frames, b.frames - off)
		for ch in 0 ..< len(out) do copy(out[ch][at:at + n], b.data[ch][off:off + n])
		if off + n == b.frames {
			rt.spsc_push(&st.free, st.current)
			st.current = -1
		}
		return n
	}
}

@(private)
silence :: proc "contextless" (out: [][]f32, at, frames: int) {
	for ch in out do for &s in ch[at:at + frames] do s = 0
}

// --- disk-side queue access (one producer) ---------------------------------------------------

@(private)
rt_free_blocks :: proc "contextless" (st: ^Stream) -> int {
	return rt.spsc_len(&st.free)
}

@(private)
spsc_pop_free :: proc "contextless" (st: ^Stream) -> (i32, bool) {
	return rt.spsc_pop(&st.free)
}

@(private)
spsc_push_filled :: proc "contextless" (st: ^Stream, index: i32) {
	rt.spsc_push(&st.filled, index)
}
