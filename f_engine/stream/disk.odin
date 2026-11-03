package stream

import "base:intrinsics"
import "core:time"

import "fire:audiofile"

// How long an idle disk thread sleeps before looking again. The audio
// thread never wakes it (that would be a system call); 2 ms is far below
// any read-ahead.
@(private)
IDLE :: 2 * time.Millisecond

// A disk thread: loads pending sources into memory, decodes cues, and tops
// up whichever stream has the least buffered, one block at a time.
@(private)
disk_main :: proc(data: rawptr) {
	d := (^Disk_Thread)(data)
	s := d.streamer
	for intrinsics.atomic_load(&s.running) {
		intrinsics.atomic_add(&d.epoch, 1) // holds no stream pointer here
		if !load_one_source(s) && !serve_neediest(s) do time.sleep(IDLE)
	}
}

// Takes one pending source and decodes it into memory. The swap out of
// `pending` gives this thread the job; the source then belongs to it until
// it sets `state`.
@(private)
load_one_source :: proc(s: ^Streamer) -> bool {
	for &p in s.pending {
		if intrinsics.atomic_load(&p) == nil do continue
		src := intrinsics.atomic_exchange(&p, nil)
		if src == nil do continue
		load_source(src)
		return true
	}
	return false
}

@(private)
load_source :: proc(src: ^Source) {
	n, err := audiofile.read(src.reader, src.ram, int(src.info.frames))
	audiofile.close(src.reader)
	src.reader = nil
	ok := err == .None && i64(n) == src.info.frames
	intrinsics.atomic_store(&src.state, Source_State.Ready if ok else .Failed) // last touch
}

// Claims the stream that most needs data and does one unit of work on it:
// decode a cue, or fill one block. Returns false when nothing needs doing.
@(private)
serve_neediest :: proc(s: ^Streamer) -> bool {
	best: ^Stream
	best_need := 0
	for i in 0 ..< len(s.slots) {
		st := intrinsics.atomic_load(&s.slots[i])
		if st == nil || st.reader == nil || intrinsics.atomic_load(&st.busy) do continue
		need := needs(st)
		if need > best_need do best, best_need = st, need
	}
	if best == nil do return false
	// `best` stays allocated until this loop ends (see stream_destroy), but
	// two threads may pick it: only one may work on it.
	if _, ok := intrinsics.atomic_compare_exchange_strong(&best.busy, false, true); !ok do return true
	did := work(best)
	intrinsics.atomic_store(&best.busy, false)
	return did
}

// How urgently a stream needs the disk: undecoded cues first, then empty
// blocks (more empty = more urgent). 0 = nothing to do.
@(private)
needs :: proc(st: ^Stream) -> int {
	for i in 0 ..< st.cue_count do if !intrinsics.atomic_load(&st.cues[i].ready) do return 1 << 30
	if intrinsics.atomic_load(&st.finished) == intrinsics.atomic_load(&st.request) do return 0 // read to the end
	return rt_free_blocks(st)
}

// Returns whether there was anything to do.
@(private)
work :: proc(st: ^Stream) -> bool {
	for i in 0 ..< st.cue_count {
		c := &st.cues[i]
		if intrinsics.atomic_load(&c.ready) do continue
		if audiofile.seek(st.reader, c.frame) == .None {
			audiofile.read(st.reader, c.data, c.frames)
		}
		// Even on a read error the cue is marked ready (holding what was
		// read, else silence), so a broken file can't stall the stream.
		intrinsics.atomic_store(&c.ready, true)
		return true
	}
	request := intrinsics.atomic_load(&st.request)
	gen, frame := unpack(request)
	if gen != st.prod_gen {
		st.prod_gen, st.prod_pos = gen, frame
	}
	if st.prod_pos >= st.source.info.frames {
		intrinsics.atomic_store(&st.finished, request)
		return false
	}
	index, ok := spsc_pop_free(st)
	if !ok do return false
	b := &st.blocks[index]
	if audiofile.position(st.reader) != st.prod_pos do audiofile.seek(st.reader, st.prod_pos)
	n, _ := audiofile.read(st.reader, b.data, int(min(BLOCK_FRAMES, st.source.info.frames - st.prod_pos)))
	b.gen, b.start, b.frames = gen, st.prod_pos, n
	st.prod_pos += i64(n)
	spsc_push_filled(st, index)
	return true
}
